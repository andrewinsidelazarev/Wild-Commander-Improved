"""Реальный FDI2FDD.WMF на z80; API WC заменён контрактными заглушками.

Запуск на готовом WMF без пересборки: python -B tests/run.py.
Обычные проверки исполняют неизменный WMF. Отрицательные контроли
test_regressions явно меняют отдельные инструкции только в RAM своего CPU.
"""
import copy
from pathlib import Path
import re
import unittest
import zipfile
import z80
from fdi import Sector, make_fdi, parse_fdi
from wd1793 import WD1793, crc16, decode_track
from wc_keyboard import Keyboard

ROOT = Path(__file__).resolve().parents[1]
SYMS = {m[1]: int(m[2], 16) for m in re.finditer(
    r'^([^:\n]+): EQU 0x([0-9A-Fa-f]+)', (ROOT / 'build/FDI2FDD.sym').read_text(), re.M)}
STOP, STACK, WLD, COUNT = 0x7000, 0x5F00, 0x6006, 0x6009
EVIDENCE = {'reading': {}, 'rotation': {}}

class WaitingForKey(Exception):
    """API 47 остановлен: тест проверяет настоящий ожидающий Z80-код."""


class Plugin:
    def __init__(self, blob, **model_args):
        self.cpu = z80.Z80Machine()
        self.cpu.memory[:] = bytes(65536)
        code = (ROOT / 'build/FDI2FDD.WMF').read_bytes()[512:]
        self.cpu.memory[0x8000:0x8000 + len(code)] = code
        self.pages = {1: bytearray([0xA5] * 16384), 2: bytearray([0x5A] * 16384),
                      254: bytearray(16384), 253: bytearray([0xCC] * 16384)}
        self.mapped, self.mask, self.nvreg = 254, 0x85, 0
        self.blob, self.api_calls, self.messages, self.windows = blob, [], [], []
        self.window_records, self.ui_events = [], []
        self.window_rows, self.window_colours, self.last_print = {}, {}, None
        self.poll_count, self.read_count, self.escaped = 0, 0, False
        self.option_keys, self.key, self.started = [], 'enter', False
        self.warning_key, self.error_keys, self.final_key = 'y', ['a'], 'space'
        self.stage, self.window_open = 'drive', False
        self.wait_events, self.controller_outputs, self.reads = [], [], []
        self.trace_io = model_args.pop('trace_io', False)
        self.io_events = []             # полная шина только для коротких I/O-проверок
        self.streams, self.active_stream = [0, 0], 0
        self.on_wait = lambda stage: None
        self.on_api = lambda api: None
        self.api_ticks = 1000            # задержка диспетчера вне DI/DRQ
        self.elapsed, self.budget = 0, 0
        self.frame_phase = 0
        # WC вызывает плагин с разрешёнными INT. int_disabled у библиотеки
        # означает только задержку после EI, а состояние DI хранится в IFF1.
        self.cpu._Z80State__iff1[0] = self.cpu._Z80State__iff2[0] = 1
        # Часы FDC выражены в тактах 3,5 МГц. При API 14 меняется скорость
        # CPU, а физические часы мотора/DRQ сохраняются. На 3,5 МГц один T
        # модели Z80 равен одному такту этих часов, без старого множителя WAIT.
        self.tick_scale = model_args.pop('tick_scale', 1)
        self.cpu_frequency = model_args.pop('saved_cpu_hz', 3_500_000)
        self.cache = model_args.pop('saved_cache', 2)
        self.saved_cpu_settings = self.cpu_frequency, self.cache
        self.frequency_events = []
        self.fdc_access_count = 0
        self.fdc_cpu_settings = set()
        self.keyboard = Keyboard(self.cpu.memory)
        self.key = None
        self.key_frames = 0
        self.key_delays = {}
        self.delivered = {'warning': False, 'done': False, 'error': False}
        self.frame_count = 0
        self.hooks = {}
        self.instruction_observers = {}  # повторяемый контроль HL до INI/OUTI
        self.file_fault_at, self.file_short_at = None, None
        self.model = WD1793(now=self.now, **model_args)
        self.cpu.set_input_callback(self.input)
        self.cpu.set_output_callback(self.output)
        self.cpu.memory[0x6100:0x610A] = b'TEST.FDI\0\0'
        self.cpu.memory[0x600E] = 25
        self.cpu.memory[0x6003] = 254
        self.cpu.memory[0x6004] = 0xBC    # WC не инициализирует ABT при входе
        self.cpu.memory[0x38:0x3B] = b'\xfb\xed\x4d'  # EI / RETI, выход INT
        self.cpu.set_breakpoint(STOP)
        self.cpu.set_breakpoint(WLD)
        self.halts = {SYMS['Options.loop'] + 1, SYMS['ReadKey.wait'] + 1}
        for address in self.halts:
            assert self.cpu.memory[address] == 0x76
            self.cpu.set_breakpoint(address)
        # Разделяем учёт тактов на границах DI/EI и ДО чтения счётчика WC.
        # Берём только начала инструкций из готового листинга: библиотека
        # замечает breakpoint и при чтении операнда с отмеченного адреса.
        self.clock_breakpoints = {0x38}
        listing = (ROOT / 'build/FDI2FDD.lst').read_text(encoding='utf-8')
        for match in re.finditer(r'^\s*\d+\+?\s+([0-9A-F]{4})\s+'
                                 r'(F3|FB|2A 09 60)\s+(?:\.\w+:\s*)?'
                                 r'(?:DI|EI|LD HL,\(#6009\))(?:\s|$)', listing, re.M):
            address = int(match[1], 16)
            assert bytes(self.cpu.memory[address:address + len(bytes.fromhex(match[2]))]) == bytes.fromhex(match[2])
            self.clock_breakpoints.add(address)
        for address in self.clock_breakpoints:
            self.cpu.set_breakpoint(address)

    def now(self):
        # После breakpoint остаток предыдущего кванта больше не часть часов.
        return self.elapsed + (self.budget - self.remaining()) * self.cycle_scale if self.budget else self.elapsed

    @property
    def cycle_scale(self):
        return self.tick_scale * self.model.frequency / self.cpu_frequency

    @property
    def interrupts_enabled(self):
        return bool(self.cpu._Z80State__iff1[0])

    def advance_ticks(self, ticks, enabled=None):
        """Общие часы WC/FDC: физическое время идёт и при DI, _COUNT — нет.

        Фаза 50 Гц сохраняется при DI; пропущенные кадры не догоняются после EI.
        FDC получает те же часы, но решает остановку/раскрутку самостоятельно.
        """
        assert ticks >= 0
        if enabled is None:
            enabled = self.interrupts_enabled
        self.elapsed += ticks
        phase = self.frame_phase + ticks * 50 / self.model.frequency
        frames = int(phase + 1e-9)
        self.frame_phase = phase - frames
        if enabled and frames:
            count = (self.word(COUNT) + frames) & 0xFFFF
            self.cpu.memory[COUNT:COUNT + 2] = count.to_bytes(2, 'little')
            for _ in range(frames):
                self.keyboard.frame()

    def advance_time(self, seconds):
        self.advance_ticks(round(seconds * self.model.frequency))

    def frame(self, deliver=True):
        assert self.interrupts_enabled, 'WC key wait requires EI'
        self.advance_time(1 / 50)
        self.frame_count += 1
        if self.key_frames:
            self.key_frames -= 1
            if not self.key_frames:
                self.keyboard.release()
                self.key = None
            elif self.key is not None and not self.keyboard.held:
                self.keyboard.press(self.key)  # make-повтор удержанной клавиши
            return
        if not deliver or self.keyboard.held:
            return
        if self.stage == 'drive':
            key = self.option_keys.pop(0) if self.option_keys else 'enter'
        elif self.stage == 'warning':
            if self.delivered['warning']:
                raise AssertionError('warning key was swallowed by repeat counter')
            key = self.warning_key
        elif self.stage == 'choice':
            key = self.error_keys.pop(0) if self.error_keys else 'a'
        elif self.stage in ('done', 'error'):
            key = self.final_key
            if key is None:
                raise WaitingForKey(self.stage)
        else:
            return
        if self.frame_count > 1000:
            raise AssertionError('keyboard loop swallowed first press')
        self.wait_events.append(self.stage)
        self.on_wait(self.stage)
        self.advance_time(self.key_delays.get(self.stage, 0))
        self.keyboard.press(key)
        if key == 'escape':
            self.cpu.memory[0x6004] = 1  # ABTF резидентного INT WC
        self.key, self.key_frames = key, 2
        if self.stage in self.delivered:
            self.delivered[self.stage] = True

    def release_keys(self):
        # USPO_SAFE вызывает ANYK каждый кадр; после 75 кадров очищает TAB
        # и даёт 10 кадров grace. В обычном сценарии приходит настоящий break.
        # Его .frame содержит EI/HALT даже при входе в API с IFF=0.
        self.cpu._Z80State__iff1[0] = self.cpu._Z80State__iff2[0] = 1
        for _ in range(75):
            self.frame(deliver=False)
            self.keyboard.release_frames += 1
            if not self.keyboard.any():
                return
        self.keyboard.release()
        self.cpu.memory[0x76CD] = 0       # USPO_SAFE сбрасывает также префикс E0
        for _ in range(10):
            self.frame(deliver=False)
            if self.keyboard.any():
                return self.release_keys()

    def remaining(self):
        # z80 1.0: getter ticks_to_stop содержит опечатку tick_to_stop.
        value = int.from_bytes(self.cpu._StateBase__ticks_to_stop, 'little')
        return value if value < 0x80000000 else value - 0x100000000

    def word(self, name):
        p = SYMS[name] if isinstance(name, str) else name
        return int.from_bytes(self.cpu.memory[p:p + 2], 'little')

    def poke(self, name, value, size=1):
        self.cpu.memory[SYMS[name]:SYMS[name] + size] = value.to_bytes(size, 'little')

    def map(self, page):
        self.pages[self.mapped][:] = self.cpu.memory[0xC000:]
        self.cpu.memory[0xC000:] = self.pages[page]
        self.mapped = page
        self.cpu.memory[0x6003] = page

    def input(self, port):
        if port == 0xBFF7:
            assert self.nvreg == 0xB0
            value = 0x85
        else:
            assert self.mask == 0x80, f'FDC ports closed: {port:04x}'
            self.record_fdc_access()
            value = self.model.input(port)
        if self.trace_io:
            self.io_events.append(('in', port, value))
        return value

    def output(self, port, value):
        if self.trace_io:
            self.io_events.append(('out', port, value))
        if port == 0xDFF7:
            self.nvreg = value
        elif port == 0x29AF:
            self.mask = value
            if value == 0x80:
                self.model.begin_probe()
        else:
            assert self.mask == 0x80, f'FDC ports closed: {port:04x}'
            self.record_fdc_access()
            self.controller_outputs.append((port & 255, value))
            self.model.output_port(port, value)

    def record_fdc_access(self):
        self.fdc_access_count += 1
        self.fdc_cpu_settings.add((self.cpu_frequency, self.cache))

    def api(self):
        c = self.cpu
        api, hl, ix = c.a, c.hl, c.ix
        self.api_calls.append(api)
        self.advance_ticks(self.api_ticks)
        self.on_api(api)
        if api == 59:
            c.hl, c.de, c.f = len(self.blob) & 65535, len(self.blob) >> 16, 0
            return
        if api == 77:
            self.read_count += 1
            block = bytes(c.memory[hl:hl + 32])
            assert block[:4] == b'\x20\x01\x01\x00'
            off, dst, length = int.from_bytes(block[4:8], 'little'), self.word(hl + 8), self.word(hl + 10)
            assert self.active_stream == 1, 'FILEX damaged sequential stream'
            self.streams[1] = off + length
            self.reads.append(('READ_AT', off, length))
            assert 0x8000 <= dst and dst + length <= 0xB000
            assert not (dst < hl + 32 and dst + length > hl)
            chunk = self.blob[off:off + length]
            c.memory[dst:dst + len(chunk)] = chunk
            c.memory[hl + 24:hl + 28] = len(chunk).to_bytes(4, 'little')
            status = 0 if len(chunk) == length else 1
            if self.read_count == self.file_fault_at:
                status = 0x21
            if self.read_count == self.file_short_at:
                c.memory[hl + 24:hl + 28] = (len(chunk) - 1).to_bytes(4, 'little')
            c.memory[hl + 28] = status
            c.memory[0xB000:0xC000] = bytes([0xCE]) * 4096
            c.a, c.f = status, 0x40 if status == 0 else 0
            c.bc, c.de, c.hl, c.ix = 0xDDDD, 0xDDDD, 0xDDDD, 0xDDDD
            return
        if api in (48, 61):
            self.read_count += 1
            off, length = self.streams[self.active_stream], c.b * 512
            assert self.active_stream == 0 and c.b, 'wrong sequential stream'
            self.reads.append(('LOAD512' if api == 48 else 'LOADNONE', off, length))
            self.streams[0] += length
            if api == 48:
                assert hl == 0xA800 and length == 512
                c.memory[hl:hl + length] = self.blob[off:off + length].ljust(length, b'\xcc')
                c.hl = hl + length - (1 if self.read_count == self.file_short_at else 0)
            c.a, c.f = (0x0F if off + length >= len(self.blob) else 0), 0
            if off >= len(self.blob) or self.read_count == self.file_fault_at:
                c.a, c.f = 0xFF, 1
            c.memory[0xB000:0xC000] = b'\xce' * 4096
            c.bc, c.de, c.ix = 0xDDDD, 0xDDDD, 0xDDDD
            return
        if api == 62:
            self.streams[self.active_stream] = 0
        elif api == 57:
            if c.d == 0xFE:
                self.streams = [self.streams[self.active_stream]] * 2
                self.active_stream = 0
            else:
                assert c.d in (0, 1) and c.bc == 65535
                self.active_stream = c.d
        elif api == 0:
            alt_a = c._Z80State__alt_af[1]
            assert alt_a in (1, 2, 254)
            self.map(alt_a)
        elif api == 1:
            assert not self.window_open
            self.window_open = True
            descriptor = bytes(c.memory[ix:ix + 22])
            title_address = self.word(ix + 12)
            title_end = title_address
            while c.memory[title_end]:
                title_end += 1
            title = bytes(c.memory[title_address:title_end])
            self.window_records.append({'descriptor': descriptor, 'title': title})
            if title == b'\x0e\x09REAL DRIVE':
                self.stage, self.started = 'drive', False
                self.delivered = dict.fromkeys(self.delivered, False)
                self.frame_count = 0
            width, height = c.memory[ix + 4:ix + 6]
            self.window_rows = {row: [' '] * (width - 2) for row in range(1, height - 1)}
            self.window_colours = {row: [c.memory[ix + 6]] * (width - 2)
                                   for row in self.window_rows}
            self.last_print = None
            textheight = c.memory[0x600E]
            textwidth = 90 if textheight == 36 else 80
            c.memory[ix + 2] = (textwidth - width) // 2
            c.memory[ix + 3] = (textheight - height) // 2
            c.memory[ix + 8:ix + 10] = b'\x00\x20'
            self.windows.append((c.memory[ix + 2], c.memory[ix + 3], width, height))
            self.map(254)
        elif api == 2:
            assert self.window_open
            self.window_open = False
            self.map(254)
        elif api == 3:
            assert self.window_open
            assert ix == SYMS['Window']
            text = bytes(c.memory[hl:hl + c.bc]).decode('cp866')
            self.messages.append((c.d, c.e, text))
            row, x, length = c.d, c.e, c.bc
            assert row in self.window_rows and 1 <= x <= x + length - 1 <= len(self.window_rows[row])
            self.window_rows[row][x - 1:x - 1 + length] = list(text)
            self.last_print = row, x, length
            self.ui_events.append({'api': 3, 'window': len(self.windows) - 1,
                                   'row': row, 'x': x, 'text': text,
                                   'frame': self.frame_count})
            if 'Continue?' in text:
                self.stage = 'warning'
            elif 'Checking FDI' in text:
                self.stage = 'writing'
                self.started = True
            elif 'Retry / Ignore / Abort' in text:
                self.stage = 'choice'
            elif text.strip().startswith('Done'):
                self.stage = 'done'
            elif c.d == 2 and any(s in text for s in ('failed', 'protected', 'Drive not found',
                    'No disk in drive', 'Floppy disk controller not found', 'Invalid',
                    'beyond EOF', 'capacity', 'Unsupported', 'timeout')):
                self.stage = 'error'
            elif self.stage == 'choice' and c.d == 2:
                self.stage = 'writing'
            self.map(254)
        elif api == 4:
            # PRIAT красит сохранённый PRSRW диапазон, а не текущие BC/DE.
            assert self.window_open and self.last_print is not None
            assert self.api_calls[-2] == 3, 'PRIAT must follow PRSRW immediately'
            row, x, length = self.last_print
            colour = c._Z80State__alt_af[1]
            self.window_colours[row][x - 1:x - 1 + length] = [colour] * length
            self.ui_events.append({'api': 4, 'window': len(self.windows) - 1,
                                   'row': row, 'x': x, 'length': length, 'colour': colour,
                                   'text': ''.join(self.window_rows[row]),
                                   'colours': list(self.window_colours[row]),
                                   'frame': self.frame_count})
            self.map(254)
        elif api == 14:
            self.frequency_events.append({'b': c.b, 'c': c.c, 'time': self.now(),
                                          'fdc_io_count': len(self.controller_outputs),
                                          'fdc_access_count': self.fdc_access_count,
                                          'io_count': len(self.io_events)})
            if c.b == 0:
                assert c.c == 0
                self.cpu_frequency, self.cache = 3_500_000, 0
            else:
                assert c.b == 255
                self.cpu_frequency, self.cache = self.saved_cpu_settings
        elif api in (6, 7, 15):
            pass
        elif api == 46:
            self.release_keys()
        elif api == 47:
            c._Z80State__iff1[0] = c._Z80State__iff2[0] = 1 # NUSP: EI/HALT
            while True:                  # NUSP: HALT / ANYK, побочный эффект ARR
                self.frame()
                if self.keyboard.any():
                    break
        elif api == 45:
            c.a = self.keyboard.any()
            c.f = 0 if c.a else 0x40
            return
        elif api == 42:
            assert c._Z80State__alt_af[1] == 1
            c.a = self.keyboard.character()
            c.f = 0 if c.a else 0x40
            return
        elif api in (16, 17, 18, 19, 20, 22, 23):
            key = {16: 'space', 17: 'up', 18: 'down', 19: 'left',
                   20: 'right', 22: 'enter', 23: 'escape'}[api]
            if api == 23 and self.escaped:
                self.keyboard.press('escape')
                c.memory[0x6004] = 1
            pressed = self.keyboard.check(key)
            c.f = 0 if pressed else 0x40
            return
        else:
            raise AssertionError(f'unexpected API {api}')
        # Реальный диспетчер разрушает альтернативный BC. Остальные регистры
        # здесь также считаем volatile, кроме FILEX IY по публичному контракту.
        c.alt_bc = 0xBEEF

    def call(self, label='Entry', **regs):
        c = self.cpu
        c.pc, c.sp = SYMS[label] if isinstance(label, str) else label, STACK
        c.memory[STACK:STACK + 2] = STOP.to_bytes(2, 'little')
        c.a, c.bc, c.hl, c.de, c.ix = 0, 0x6100, len(self.blob) & 65535, len(self.blob) >> 16, 0x6200
        for reg, value in regs.items():
            setattr(c, reg, value)
        return self.run()

    def resume(self):
        c = self.cpu
        assert c.pc == WLD and c.a == 47
        self.api()
        c.pc = self.word(c.sp)
        c.sp += 2
        return self.run()

    def run(self):
        c = self.cpu
        for _ in range(300000):
            if c.pc == STOP:
                assert c.sp == STACK + 2
                return c.a
            if c.pc in self.halts and c.memory[c.pc] == 0x76:
                # Исполняем настоящий HALT и принимаем INT после EI.
                address = c.pc
                c.clear_breakpoint(address)
                self.run_cpu(1)
                c.set_breakpoint(address)
                assert c.halted and not c.int_disabled
                self.frame()
                assert c.on_handle_active_int()
                self.advance_ticks(13 * self.cycle_scale, enabled=False)
                continue
            if c.pc in self.hooks:
                address = c.pc
                self.hooks.pop(address)()
                c.clear_breakpoint(address)
                continue
            if c.pc in self.instruction_observers:
                address = c.pc
                self.instruction_observers[address]()
                c.clear_breakpoint(address)
                self.run_cpu(1)          # исполнить целую INI/OUTI, не менять код
                c.set_breakpoint(address)
                continue
            if c.pc in self.clock_breakpoints:
                address = c.pc
                c.clear_breakpoint(address)
                self.run_cpu(1)          # одна настоящая инструкция, включая DI/EI
                c.set_breakpoint(address)
                continue
            if c.pc == WLD:
                self.api()
                c.pc = self.word(c.sp)
                c.sp += 2
                continue
            # z80 также выдаёт breakpoint, когда JR перескочил через
            # отмеченный адрес. Обрабатываем только фактический PC выше.
            self.run_cpu(1_000_000)
        raise AssertionError('Z80 did not return (hang)')

    def run_cpu(self, ticks):
        enabled = self.interrupts_enabled
        self.budget = ticks
        self.cpu.ticks_to_stop = ticks
        event = self.cpu.run()
        used = (ticks - self.remaining()) * self.cycle_scale
        self.budget = 0
        self.advance_ticks(used, enabled=enabled)
        return event

    @property
    def result(self):
        return self.cpu.memory[SYMS['Result']]

    def exceptions(self, source):
        out = []
        for key, sectors in source.items():
            for s in sectors:
                if not s.good_crc and any(x in s.data for x in (0xF5, 0xF6, 0xF7)):
                    out.append((key, s.id, 'F5/F6/F7 -> E5/E6/E7, bad CRC retained'))
        return out


class PluginTests(unittest.TestCase):
    def check_disk(self, p, blob, window_pairs=1):
        tracks, _ = parse_fdi(blob)
        exceptions = p.exceptions(tracks)
        expected = copy.deepcopy(tracks)
        for key, sectors in expected.items():
            for sector in sectors:
                if not sector.good_crc and any(x in sector.data for x in (0xF5, 0xF6, 0xF7)):
                    sector.data = bytes(x - 0x10 if x in (0xF5, 0xF6, 0xF7) else x for x in sector.data)
            self.assertEqual(p.model.tracks[(p.cpu.memory[SYMS['Drive']], *key)], sectors, key)
        self.assertEqual(p.word('TracksDone'), len(tracks))
        self.assertEqual(p.word('ApproxDone'), len(exceptions))
        self.assertEqual(p.word('ApproxExpected'), len(exceptions))
        self.assertEqual(p.result, 0)
        self.assertEqual(p.mask, 0x85)
        self.assertFalse(p.model.busy)
        self.assertLessEqual(p.model.max_expanded, p.model.capacity)
        self.assertEqual(p.api_calls.count(1), 2 * window_pairs)
        self.assertEqual(p.api_calls.count(2), 2 * window_pairs)
        self.assertNotIn(49, p.api_calls)
        if exceptions:
            self.assertTrue(any(text.strip() == 'Done' for row, x, text in p.messages))
            self.assertTrue(any('CRC changed: ' + f'{len(exceptions):04}' in text
                                for row, x, text in p.messages))
        return exceptions

    def test_real_images(self):
        for name in ('IS_BASE.FDI', 'voron1/voron1.fdi', 'voron1/voron2.fdi'):
            with self.subTest(image=name):
                blob = (ROOT / name).read_bytes()
                p = Plugin(blob)
                p.call()
                exceptions = self.check_disk(p, blob)
                EVIDENCE['reading'][name] = {
                    'file_bytes': len(blob),
                    'calls': {kind: sum(k == kind for k, off, size in p.reads)
                              for kind in ('LOAD512', 'LOADNONE', 'READ_AT')},
                    'bytes': {kind: sum(size for k, off, size in p.reads if k == kind)
                              for kind in ('LOAD512', 'LOADNONE', 'READ_AT')},
                    'crc_changed_sectors': p.word('ApproxDone'),
                    'crc_changed_bytes': int.from_bytes(p.cpu.memory[SYMS['ApproxBytes']:SYMS['ApproxBytes'] + 4], 'little')}
                sequential = [off for k, off, size in p.reads if k == 'LOAD512']
                self.assertEqual(sequential, list(range(0, len(blob), 512)))
                self.assertEqual(sum(k == 'READ_AT' for k, off, size in p.reads), len(exceptions))
                for key, ident, reason in exceptions:
                    print(f'\nEXCEPTION {name} physical={key} ID={ident}: {reason}')
                if name.endswith('voron1.fdi'):
                    self.assertEqual(len(exceptions), 1)
                    self.assertFalse(p.model.tracks[(0, 59, 1)][0].good_crc)
                    self.assertTrue(any(cmd == 0x18 and key == (0, 59, 1) and c == 59
                                        for cmd, key, c, r in p.model.commands))

    def test_bad_crc_and_deleted(self):
        sectors = [Sector(7, 4, 192 + n, n, bytes([n + 1]) * (128 << n), bool(n & 1), False)
                   for n in range(4)]
        blob = make_fdi({(0, 0): sectors})
        p = Plugin(blob)
        p.call()
        self.check_disk(p, blob)
        self.assertFalse(p.model.written)  # плохой CRC сохраняется, WRITE SECTOR его не исправляет

    def test_crc_zero_corner(self):
        data = b'\0' * 126
        suffix = crc16(b'\xa1' * 3 + b'\xfb' + data).to_bytes(2, 'big')
        self.assertEqual(crc16(b'\xa1' * 3 + b'\xfb' + data + suffix), 0)
        self.assertFalse(any(x in suffix for x in (0xF5, 0xF6, 0xF7)))
        blob = make_fdi({(0, 0): [Sector(0, 0, 1, 0, data + suffix, False, False)]})
        p = Plugin(blob)
        p.call()
        self.check_disk(p, blob)

    def test_crc_flag_for_applicable_size_only(self):
        for n, flags in ((1, 8), (3, 2), (2, 0x80)):
            blob = bytearray(make_fdi({(0, 0): [Sector(0, 0, 1, n, b'X' * (128 << n))]}))
            blob[25] = flags
            p = Plugin(bytes(blob))
            p.call()
            self.check_disk(p, bytes(blob))
            self.assertFalse(p.model.tracks[(0, 0, 0)][0].good_crc)

    def test_unformatted_erases_old_ids(self):
        blob = make_fdi({(0, 0): []})
        p = Plugin(blob)
        p.model.tracks[(0, 0, 0)] = [Sector(0, 0, 1, 1, b'Z' * 256)]
        p.call()
        self.check_disk(p, blob)
        self.assertEqual(p.model.tracks[(0, 0, 0)], [])

    def test_horizontal_drive_enter_select_bits_and_ui_modes(self):
        blob = make_fdi({(0, 0): [Sector(0, 0, 9, 1, bytes(range(256)))]})
        for height in (25, 30, 36):
            for drive in range(4):
                with self.subTest(height=height, drive=drive):
                    self.check_drive_mode(blob, height, drive)

    def check_drive_mode(self, blob, height, drive):
        p = Plugin(blob)
        p.cpu.memory[0x600E] = height
        p.option_keys = ['right'] * drive + ['enter']
        p.call()
        self.check_disk(p, blob)
        self.assertEqual(p.cpu.memory[SYMS['Drive']], drive)
        width = 90 if height == 36 else 80
        self.assertEqual(p.windows, [((width - 42) // 2, (height - 7) // 2, 42, 7)] * 2)
        w = SYMS['Window']
        self.assertEqual(bytes(p.cpu.memory[w + 4:w + 8]), b'\x2a\x07\x5f\x00')
        self.assertEqual(p.cpu.memory[w], 0x84)
        self.assertEqual(bytes(p.cpu.memory[SYMS['Title']:SYMS['Title'] + 10]),
                         b'\x0e\x09FDI2FDD\0')
        self.assertEqual([w['title'] for w in p.window_records],
                         [b'\x0e\x09REAL DRIVE', b'\x0e\x09FDI2FDD'])
        self.assertEqual(p.window_records[0]['descriptor'][:12],
                         b'\x84\x00\xff\xff\x2a\x07\x5f\x00\x00\x00\x00\x00')
        self.assertNotIn(6, p.api_calls)
        self.assertNotIn(7, p.api_calls)
        self.assertNotIn(47, p.api_calls[:p.api_calls.index(59)])
        selects = [value for port, value in p.controller_outputs if port == 0xFF]
        self.assertEqual(selects[-1], 0x04)  # CloseFDC отключает HLT/head load
        self.assertTrue(selects[:-1])
        self.assertTrue(all(value & 3 == drive for value in selects if value != 0x04))
        self.assertIn(0x3C | drive, selects[:-1])
        reads = [c for c, *rest in p.model.commands if c == 0x80]
        self.assertTrue(reads)
        self.assertTrue(all(key[0] == drive for cmd, key, c, r in p.model.commands))
        for row, x, text in p.messages:
            if len(text) == 3:   # три клетки выделения не являются CenterText
                continue
            self.assertEqual(x, 1)
            if text.strip() and set(text) - {'█', '▒', ' '}:
                self.assertEqual(len(text) - len(text.lstrip()),
                                 (40 - len(text.strip())) // 2)

    def test_horizontal_drive_moves_both_ways_and_stops_at_edges(self):
        blob = make_fdi({(0, 0): [Sector(0, 0, 1, 0, b'X' * 128)]})
        p = Plugin(blob)
        p.poke('Drive', 3)              # Entry должен снова начать с A
        keys = ['left'] + ['right'] * 5 + ['left'] * 4 + ['escape']
        p.option_keys = list(keys)
        observed = []
        def waiting(stage):
            self.assertEqual(stage, 'drive')
            observed.append(p.cpu.memory[SYMS['Drive']])
        p.on_wait = waiting
        p.call()
        self.assertEqual(observed, [0, 0, 1, 2, 3, 3, 3, 2, 1, 0, 0])
        highlights = [e for e in p.ui_events if e['api'] == 4 and e['colour'] == 0xF0]
        self.assertEqual([e['x'] for e in highlights], [9, 16, 23, 30, 23, 16, 9])
        self.assertEqual(p.result, 9)
        self.assertFalse(p.controller_outputs)
        EVIDENCE['horizontal_menu'] = {'keys': keys[:-1],
                                      'drive_after_key': observed[1:],
                                      'highlight_x': [e['x'] for e in highlights]}

    def test_horizontal_drive_cells_colours_and_previous_highlight_removed(self):
        p = Plugin(make_fdi({(0, 0): []}))
        p.option_keys = ['right'] * 3 + ['left'] * 3 + ['escape']
        p.call()
        row_text = ' ' * 9 + 'A      B      C      D' + ' ' * 9
        self.assertEqual(len(row_text), 40)
        self.assertEqual([i + 1 for i, ch in enumerate(row_text) if ch != ' '], [10, 17, 24, 31])
        self.assertEqual(len(p.ui_events), 7 * 4)
        for index, drive in enumerate((0, 1, 2, 3, 2, 1, 0)):
            with self.subTest(drive=drive, redraw=index):
                full, reset, mark, highlight = p.ui_events[index * 4:index * 4 + 4]
                self.assertEqual([e['api'] for e in (full, reset, mark, highlight)], [3, 4, 3, 4])
                self.assertTrue(all(e['window'] == 0 and e['row'] == 3 for e in (full, reset, mark, highlight)))
                self.assertEqual((full['x'], full['text']), (1, row_text))
                self.assertEqual((reset['x'], reset['length'], reset['colour']), (1, 40, 0x5F))
                self.assertEqual(reset['colours'], [0x5F] * 40)
                x = 9 + 7 * drive
                self.assertEqual((mark['x'], mark['text']), (x, ' ' + chr(65 + drive) + ' '))
                self.assertEqual((highlight['x'], highlight['length'], highlight['colour']), (x, 3, 0xF0))
                self.assertEqual(highlight['text'], row_text)
                expected = [0x5F] * 40
                expected[x - 1:x + 2] = [0xF0] * 3
                self.assertEqual(highlight['colours'], expected)
                self.assertEqual(sum(ch in 'ABCD' and colour == 0xF0
                                     for ch, colour in zip(highlight['text'], highlight['colours'])), 1)

    def test_horizontal_drive_up_down_ignored_and_polled_once_per_frame(self):
        for drive in range(4):
            with self.subTest(drive=drive):
                p = Plugin(make_fdi({(0, 0): []}))
                p.option_keys = ['right'] * drive + ['up', 'down', 'up', 'down', 'escape']
                observed, polls = [], []
                p.on_wait = lambda stage: observed.append(p.cpu.memory[SYMS['Drive']])
                def api(number):
                    if number in (19, 20, 22, 23):
                        polls.append((p.frame_count, number))
                p.on_api = api
                p.call()
                self.assertEqual(observed[-5:], [drive] * 5)
                self.assertEqual(len([e for e in p.ui_events if e['api'] == 4 and e['colour'] == 0xF0]), drive + 1)
                self.assertNotIn(17, p.api_calls)
                self.assertNotIn(18, p.api_calls)
                self.assertNotIn(47, p.api_calls)
                self.assertNotIn(6, p.api_calls)
                self.assertNotIn(7, p.api_calls)
                frames = sorted(set(frame for frame, number in polls))
                self.assertTrue(frames)
                self.assertEqual(frames, list(range(frames[0], frames[-1] + 1)))
                for frame in frames:
                    numbers = [number for tick, number in polls if tick == frame]
                    self.assertEqual(numbers, [23, 22, 19, 20][:len(numbers)])

    def test_horizontal_drive_escape_returns_without_controller_writes(self):
        for drive in range(4):
            with self.subTest(drive=drive):
                p = Plugin(make_fdi({(0, 0): []}))
                p.option_keys = ['right'] * drive + ['escape']
                self.assertEqual(p.call(), 0)
                self.assertEqual(p.result, 9)
                self.assertEqual(p.cpu.memory[SYMS['Drive']], drive)
                self.assertFalse(p.controller_outputs)
                self.assertFalse(p.model.commands)
                self.assertFalse(p.reads)
                self.assertEqual(len(p.windows), 1)
                self.assertFalse(p.window_open)
                self.assertFalse(p.keyboard.held)
                self.assertEqual(p.mask, 0x85)
                self.assertEqual(p.cpu.ix, 0x6200)
                self.assertEqual(p.api_calls[-2:], [46, 2])

    def test_warning_symmetric_rows_and_question_cleared_before_progress(self):
        blob = make_fdi({(0, 0): [Sector(0, 0, 1, 0, b'X' * 128)]})
        for drive in range(4):
            for key in ('y', 'Y', 'n'):
                with self.subTest(drive=drive, key=key):
                    p = Plugin(blob)
                    p.option_keys = ['right'] * drive + ['enter']
                    p.warning_key = key
                    snapshots = []
                    def waiting(stage):
                        if stage == 'warning':
                            snapshots.append({row: ''.join(text) for row, text in p.window_rows.items()})
                            self.assertEqual(p.window_colours[2], [0x2F] * 40)
                            for row in (1, 3, 4, 5):
                                self.assertEqual(p.window_colours[row], [0x5F] * 40)
                            self.assertEqual([e['b'] for e in p.frequency_events], [0, 255])
                            self.assertEqual((p.cpu_frequency, p.cache), p.saved_cpu_settings)
                            self.assertEqual(p.mask, 0x85)
                            self.assertFalse(p.model.writes)
                            self.assertFalse(p.reads)
                    p.on_wait = waiting
                    p.call()
                    self.assertEqual(len(snapshots), 1)
                    rows = snapshots[0]
                    warning = 'All data on disk ' + chr(65 + drive) + ' will be destroyed!'
                    self.assertEqual(rows[2], warning.center(40))
                    self.assertEqual(rows[4], 'Continue? (Y/N)'.center(40))
                    for row in (1, 3, 5):
                        self.assertEqual(rows[row], ' ' * 40)
                    work = [e for e in p.ui_events if e['window'] == 1]
                    self.assertEqual((work[0]['api'], work[0]['row'], work[0]['x'], work[0]['text']),
                                     (3, 2, 1, 'Checking drive...'.center(40)))
                    self.assertEqual(work[1]['text'], rows[2])
                    self.assertEqual((work[2]['api'], work[2]['row'], work[2]['x'],
                                      work[2]['length'], work[2]['colour']), (4, 2, 1, 40, 0x2F))
                    self.assertEqual(work[2]['text'], rows[2])
                    self.assertEqual(work[2]['colours'], [0x2F] * 40)
                    question = next(i for i, e in enumerate(work) if 'Continue?' in e.get('text', ''))
                    self.assertEqual(question, 3)
                    if key.lower() == 'y':
                        clear, reset, clear_question, checking = work[question + 1:question + 5]
                        self.assertEqual((clear['api'], clear['row'], clear['x'], clear['text']),
                                         (3, 2, 1, ' ' * 40))
                        self.assertEqual((reset['api'], reset['row'], reset['x'], reset['length'],
                                          reset['colour'], reset['text']), (4, 2, 1, 40, 0x5F, ' ' * 40))
                        self.assertEqual(reset['colours'], [0x5F] * 40)
                        self.assertEqual((clear_question['api'], clear_question['row'],
                                          clear_question['x'], clear_question['text']),
                                         (3, 4, 1, ' ' * 40))
                        self.assertIn('Checking FDI', checking['text'])
                        progress = [i for i, e in enumerate(work) if e['row'] == 3 and e['text'].strip().startswith('<')]
                        self.assertTrue(progress)
                        self.assertTrue(all(i > question + 3 for i in progress))
                        self.check_disk(p, blob)
                    else:
                        self.assertEqual(p.result, 9)
                        self.assertEqual([e['b'] for e in p.frequency_events], [0, 255])
                        self.assertFalse(p.model.writes)
                        self.assertFalse(p.reads)
                        self.assertEqual(question, len(work) - 1)

    def test_invalid_images_only_probe_fdc_without_disk_writes(self):
        original = make_fdi({(0, 0): [Sector(0, 0, 1, 1, b'X' * 256)]})
        cases = {}
        def mutated(name, offset, data):
            b = bytearray(original)
            b[offset:offset + len(data)] = data
            cases[name] = bytes(b)
        mutated('signature', 0, b'BAD')
        mutated('truncated table', 10, (21).to_bytes(2, 'little'))
        mutated('truncated sector entries', 20, b'\x02')
        mutated('huge track offset', 14, b'\xff' * 4)
        mutated('sector offset outside file', 26, b'\xff\xff')
        mutated('unsupported N', 24, b'\x04')
        mutated('track reserved', 18, b'\x01')
        mutated('flags reserved', 25, b'\x40')
        mutated('format control in R', 23, b'\xf5')
        mutated('zero cylinders', 4, b'\0\0')
        mutated('wrong side count', 6, b'\x03\0')
        mutated('oversized predata', 10, b'\xff\xff')
        mutated('header description out of range', 8, b'\xff\xff')
        mutated('description at data start', 8, original[10:12])
        cases['short header'] = original[:13]
        cases['truncated data'] = original[:-1]
        cases['track cannot fit'] = make_fdi({(0, 0): [Sector(0, 0, n, 3, b'X' * 1024) for n in range(6)]})
        cases['duplicate C/R'] = make_fdi({(0, 0): [Sector(0, h, 1, 1, b'X' * 256) for h in (0, 1)]})
        for name, blob in cases.items():
            with self.subTest(case=name):
                p = Plugin(blob)
                p.call()
                self.assertEqual(p.result, 1)
                self.assertEqual(p.model.writes, 0)
                self.assertEqual([cmd for cmd, *_ in p.model.commands], [0xD0, 0x08, 0xD0])
                self.assertEqual([e['b'] for e in p.frequency_events], [0, 255])
                self.assertEqual(p.mask, 0x85)

    def test_late_invalid_track_is_atomic(self):
        blob = bytearray(make_fdi({(0, 0): [Sector(0, 0, 1, 1, b'X' * 256)],
                                  (1, 0): [Sector(1, 0, 1, 1, b'Y' * 256)]}, 2))
        blob[38] = 4  # второй N
        p = Plugin(bytes(blob))
        p.call()
        self.assertEqual(p.result, 1)
        self.assertFalse(p.model.formatted)

    def test_error_paths(self):
        blob = make_fdi({(0, 0): [Sector(0, 0, 1, 1, bytes(range(256)))]})
        for args, result in (({'drive': False}, 3), ({'disk': False}, 4),
                             ({'disk': False, 'protected': True}, 4), ({'protected': True}, 5),
                             ({'fault': 'write'}, 7), ({'fault': 'write_sector'}, 9),
                             ({'fault': 'mismatch'}, 9), ({'fault': 'seek'}, 6),
                             ({'fault': 'stall'}, 10), ({'fault': 'read_crc'}, 9),
                             ({'fault': 'rnf'}, 9), ({'fault': 'id_mismatch'}, 9)):
            with self.subTest(args=args):
                p = Plugin(blob, **args)
                if result in (3, 4, 5):
                    p.final_key = None
                    with self.assertRaisesRegex(WaitingForKey, 'error'):
                        p.call()
                    self.assertEqual(p.result, result)
                    self.assertEqual(''.join(p.window_rows[4]).strip(), 'Press any key to select drive')
                    self.assertFalse(p.reads or p.model.writes)
                    p.option_keys, p.final_key = ['escape'], 'space'
                    p.resume()
                    self.assertEqual(p.result, 9)
                    self.assertEqual(p.mask, 0x85)
                    self.assertEqual(p.api_calls.count(1), 3)
                    self.assertEqual(p.api_calls.count(2), 3)
                    continue
                p.call()
                self.assertEqual(p.result, result)
                self.assertEqual(p.mask, 0x85)
                self.assertFalse(p.model.busy)
                self.assertEqual(p.api_calls.count(1), 2)
                self.assertEqual(p.api_calls.count(2), 2)
                self.assertEqual(p.cpu.a, 0)

    def test_file_errors_and_short_reads(self):
        blob = make_fdi({(0, 0): [Sector(0, 0, 1, 3, b'X' * 1024)]})
        for read_number, short in ((1, False), (1, True), (2, False)):
            p = Plugin(blob)
            if short:
                p.file_short_at = read_number
            else:
                p.file_fault_at = read_number
            p.call()
            self.assertEqual(p.result, 2)
            self.assertEqual(p.model.writes, 0)
            self.assertEqual(p.mask, 0x85)

    def test_interrupt_and_panel_state_restored(self):
        blob = make_fdi({(0, 0): []})
        for iff in (0, 1):
            p = Plugin(blob)
            p.cpu._Z80State__iff1[0] = iff
            p.cpu._Z80State__iff2[0] = iff
            p.call()
            self.assertEqual(p.cpu._Z80State__iff1[0], iff)
            self.assertEqual(p.cpu.ix, 0x6200)
            self.assertEqual(p.cpu.a, 0)

    def test_real_z80_drq_deadlines(self):
        # Исполняем те же инструкции, модель видит реальные такты на I/O.
        # DRQ идут каждые 32 us, обслуживание WRITE/READ — 23,5/27 us.
        # F7 занимает два физических байта.
        for n in range(4):
            sectors = [Sector(0, 0, 1, n, bytes(range(128)) * (1 << n)),
                       Sector(0, 0, 2, n, bytes([n]) * (128 << n), True, False)]
            blob = make_fdi({(0, 0): sectors})
            p = Plugin(blob, timed=True)
            p.call()
            self.check_disk(p, blob)
        for n, count in ((1, 16), (2, 9), (3, 5)):
            blob = make_fdi({(0, 0): [Sector(0, 0, r, n, bytes([r]) * (128 << n))
                                      for r in range(count)]})
            p = Plugin(blob, timed=True)
            p.call()
            self.check_disk(p, blob)

    def test_escape_before_start_and_during_work(self):
        blob = make_fdi({(0, 0): [Sector(0, 0, 1, 1, b'X' * 256)]})
        p = Plugin(blob)
        p.option_keys = ['escape']
        p.call()
        self.assertEqual(p.result, 9)
        self.assertEqual(p.model.writes, 0)
        p = Plugin(blob)
        def escape(cmd):
            if cmd & 0xF0 == 0xF0:
                p.escaped = True
        p.model.on_command = escape
        p.call()
        self.assertEqual(p.result, 9)
        self.assertEqual(p.mask, 0x85)
        self.assertFalse(p.model.busy)

        p = Plugin(blob, fault='stall')
        def latched_escape(cmd):
            if cmd & 0xF0 == 0xF0:
                p.cpu.memory[0x6004] = 1
                p.escaped = True
        p.model.on_command = latched_escape
        p.call()
        self.assertEqual(p.result, 9)
        self.assertEqual(p.mask, 0x85)

    def test_hard_track_capacity(self):
        blob = make_fdi({(0, 0): [Sector(0, 0, r, 3, b'Z' * 1024) for r in range(5)]})
        p = Plugin(blob, capacity=5700)
        p.call()
        self.assertEqual(p.result, 7)
        self.assertEqual(p.model.max_expanded, 5700)
        for capacity in (6000, 6250, 6375):
            p = Plugin(blob, capacity=capacity)
            p.call()
            self.check_disk(p, blob)

    def test_relaunch_with_poisoned_pages(self):
        blob = make_fdi({(0, 0): [Sector(0, 0, 1, 1, b'X' * 256)]})
        p = Plugin(blob)
        p.call()
        self.check_disk(p, blob)
        # PLM вернул другие физические страницы и не загрузил пустые страницы.
        p.map(254)
        p.pages[1][:] = b'\xff' * 16384
        p.pages[2][:] = b'\xf7' * 16384
        p.windows.clear()
        p.api_calls.clear()
        p.started = False
        p.call()
        self.check_disk(p, blob)

    def test_zip_reference_preflight(self):
        with zipfile.ZipFile(ROOT / 'ISDOS.ZIP') as archive:
            for name in archive.namelist():
                if not name.upper().endswith('.FDI'):
                    continue
                with self.subTest(image=name):
                    p = Plugin(archive.read(name))
                    p.call('OpenInput')
                    result = p.call('Validate')
                    self.assertEqual(result, 0)
                    self.assertFalse(p.cpu.f & 1)
                    self.assertFalse(p.model.commands)

    def test_file_only_header(self):
        header = (ROOT / 'build/FDI2FDD.WMF').read_bytes()[:512]
        self.assertEqual(header[33], 0)
        self.assertEqual(header[63], 1)
        self.assertEqual(header[64:67], b'FDI')
        self.assertEqual(header[197], 0)

    def test_warning_every_other_key_only_probes_without_disk_writes(self):
        blob = make_fdi({(0, 0): [Sector(0, 0, 1, 1, b'X' * 256)]})
        keys = [chr(n) for n in range(128) if chr(n) not in ('Y', 'y')]
        keys += ['enter', 'escape', 'space', 'up', 'down', 'left', 'right', 'f1', 'delete']
        for key in keys:
            with self.subTest(key=repr(key)):
                p = Plugin(blob)
                p.warning_key = key
                p.call()
                self.assertEqual(p.result, 9)
                self.assertEqual([cmd for cmd, *_ in p.model.commands], [0xD0, 0x08, 0xD0])
                self.assertEqual([e['b'] for e in p.frequency_events], [0, 255])
                self.assertFalse(p.model.writes)
                self.assertFalse(p.reads)
                self.assertEqual(p.wait_events, ['drive', 'warning'])
                colours = [e for e in p.ui_events if e['window'] == 1 and e['api'] == 4]
                self.assertEqual([(e['row'], e['x'], e['length'], e['colour']) for e in colours],
                                 [(2, 1, 40, 0x2F)])  # не-Y не очищает и не перекрашивает окно
                self.assertEqual(p.window_colours[2], [0x2F] * 40)
                self.assertEqual(p.window_colours[4], [0x5F] * 40)
        for key in ('Y', 'y'):
            p = Plugin(blob)
            p.warning_key = key
            p.call()
            self.check_disk(p, blob)
            self.assertTrue(p.model.writes)

    def test_retry_ignore_abort_write_and_verify(self):
        sectors = [Sector(0, 0, r, 1, bytes([r]) * 256) for r in (1, 2, 3)]
        blob = make_fdi({(0, 0): sectors})
        for kind in ('write_sector', 'mismatch'):
            for choice in ('r', 'i', 'a'):
                with self.subTest(fault=kind, choice=choice):
                    p = Plugin(blob)
                    p.error_keys = [choice]
                    active = [True]
                    def fault(cmd):
                        target = (cmd & 0xE0 == (0xA0 if kind == 'write_sector' else 0x80)
                                  and p.model.sector == 1 and active[0])
                        p.model.fault = kind if target else None
                    def waiting(stage):
                        if stage == 'choice':
                            attempts = [cmd for cmd, key, c, r in p.model.commands
                                        if cmd & 0xE0 == (0xA0 if kind == 'write_sector' else 0x80) and r == 1]
                            self.assertEqual(len(attempts), 3 if kind == 'write_sector' else 7)
                            if choice == 'r':
                                active[0] = False
                    p.model.on_command, p.on_wait = fault, waiting
                    p.call()
                    self.assertEqual(p.wait_events.count('choice'), 1)
                    self.assertEqual(p.api_calls.count(1), 2)  # выбор + рабочее окно
                    self.assertEqual(p.api_calls.count(2), 2)
                    self.assertEqual(p.mask, 0x85)
                    self.assertFalse(p.model.busy or p.model.drq)
                    self.assertEqual(p.model.track, p.cpu.memory[SYMS['Physical']])
                    if choice == 'a':
                        self.assertEqual(p.result, 9)
                        self.assertNotIn('done', p.wait_events)
                        self.assertEqual(p.word('TracksDone'), 0)
                    else:
                        self.assertEqual(p.result, 0)
                        self.assertEqual(p.word('TracksDone'), 1)
                        self.assertEqual(p.word('IgnoredDone'), int(choice == 'i'))
                        self.assertIn('done', p.wait_events)
                        self.assertEqual(p.model.tracks[(0, 0, 0)][1:], sectors[1:])
                        if choice == 'r':
                            self.check_disk(p, blob)
                        else:
                            self.assertTrue(any('Ignored 0001' in s for y, x, s in p.messages))

    def check_summary(self, p, message, stats=''):
        expected = {1: '', 2: message, 3: stats, 4: 'Press any key to exit', 5: ''}
        rows = {row: (' ' * ((40 - len(text)) // 2) + text).ljust(40)
                for row, text in expected.items()}
        self.assertEqual({row: ''.join(text) for row, text in p.window_rows.items()}, rows)
        self.assertEqual(p.window_colours, {row: [0x5F] * 40 for row in rows})
        tail = p.ui_events[-4:]
        self.assertEqual([(e['api'], e['window'], e['row'], e['x'], e['text']) for e in tail],
                         [(3, 1, row, 1, rows[row]) for row in range(2, 6)])
        self.assertTrue(p.window_open)
        self.assertEqual(p.cpu.pc, WLD)
        self.assertEqual(p.cpu.a, 47)
        self.assertEqual(p.mask, 0x85)
        self.assertFalse(p.model.busy)
        self.assertEqual(p.cpu.memory[SYMS['FdcOpen']], 0)
        self.assertEqual(p.api_calls.count(1), 2)
        self.assertEqual(p.api_calls.count(2), 1)
        EVIDENCE.setdefault('final_screens', {})[message + ('; ' + stats if stats else '')] = {
            'result': p.result, 'rows': rows, 'colour': '5F',
            'wait_api': 47, 'controller_closed_before_key': True}

    def check_summary_exit(self, p, key):
        events, outputs = len(p.ui_events), list(p.controller_outputs)
        p.final_key = key
        self.assertEqual(p.resume(), 0)
        self.assertFalse(p.window_open or p.keyboard.held)
        self.assertEqual(p.cpu.ix, 0x6200)
        self.assertTrue(p.interrupts_enabled)
        self.assertEqual(p.api_calls.count(2), 2)
        self.assertEqual(p.api_calls[-2:], [46, 2])
        self.assertEqual(len(p.ui_events), events)
        self.assertEqual(p.controller_outputs, outputs)
        self.assertEqual(p.mask, 0x85)

    def test_done_wait_clears_counter_bar_and_any_key_exits(self):
        blob = make_fdi({(c, 0): [Sector(c, 0, 1, 1, b'X' * 256)] for c in range(3)}, 3)
        p = Plugin(blob)
        p.final_key = None
        with self.assertRaisesRegex(WaitingForKey, 'done'):
            p.call()
        self.check_summary(p, 'Done')
        self.assertEqual(p.word('TracksDone'), 3)
        self.assertEqual(p.api_calls.count(2), 1)
        bars = [s for y, x, s in p.messages if y == 5]
        self.assertEqual(bars[0], '▒' * 40)
        self.assertEqual(bars[-2], '█' * 40)
        self.assertEqual(bars[-1], ' ' * 40)
        self.assertEqual([s.count('█') for s in bars[:-1]], sorted(s.count('█') for s in bars[:-1]))
        self.assertTrue(any(y == 3 and s.strip() == '<0003 of 0003>' for y, x, s in p.messages))
        self.assertTrue(any(s.strip() == 'Done' for y, x, s in p.messages))
        self.check_summary_exit(p, 'space')
        self.check_disk(p, blob)

    def test_summary_success_with_ignored_sectors(self):
        blob = make_fdi({(0, 0): [Sector(0, 0, r, 0, bytes([r]) * 128) for r in (1, 2)]})
        p = Plugin(blob)
        p.model.on_command = lambda cmd: setattr(p.model, 'fault',
            'write_sector' if cmd & 0xE0 == 0xA0 and p.model.sector == 1 else None)
        p.error_keys, p.final_key = ['i'], None
        with self.assertRaisesRegex(WaitingForKey, 'done'):
            p.call()
        self.assertEqual(p.result, 0)
        self.assertEqual(p.word('IgnoredDone'), 1)
        self.assertEqual(p.word('TracksDone'), 1)
        self.check_summary(p, 'Done; Ignored 0001')
        self.check_summary_exit(p, 'enter')

    def test_summary_success_with_changed_bad_crc_sectors(self):
        sectors = [Sector(0, 0, 1, 0, b'\xf5\xf6\xf7' + b'X' * 125, False, False),
                   Sector(0, 0, 2, 0, b'\xf7' + b'Z' * 127, True, False)]
        blob = make_fdi({(0, 0): sectors})
        p = Plugin(blob)
        p.final_key = None
        with self.assertRaisesRegex(WaitingForKey, 'done'):
            p.call()
        self.assertEqual(p.word('ApproxDone'), 2)
        self.assertEqual(p.word('ApproxBytes'), 4)
        self.check_summary(p, 'Done', 'CRC changed: 0002 / 000004 bytes')
        self.assertTrue(all(not s.good_crc for s in p.model.tracks[(0, 0, 0)]))
        self.check_summary_exit(p, 'escape')
        self.check_disk(p, blob)

    def test_summary_bad_crc_without_changed_bytes_has_empty_row3(self):
        blob = make_fdi({(0, 0): [Sector(0, 0, 1, 0, b'X' * 128, False, False)]})
        p = Plugin(blob)
        p.final_key = None
        with self.assertRaisesRegex(WaitingForKey, 'done'):
            p.call()
        self.assertEqual(p.word('ApproxDone'), 0)
        self.assertFalse(p.model.tracks[(0, 0, 0)][0].good_crc)
        self.check_summary(p, 'Done')
        self.check_summary_exit(p, 'f1')
        self.check_disk(p, blob)

    def test_summary_errors_renamed_messages_and_any_key_exits(self):
        blob = make_fdi({(0, 0): [Sector(0, 0, 1, 0, b'X' * 128)]})
        cases = [({'disk': False}, 4, 'No disk in drive', 'left'),
                 ({'drive': False}, 3, 'Drive not found', 'delete'),
                 ({'protected': True}, 5, 'Disk is write protected', 'q')]
        for args, result, message, key in cases:
            with self.subTest(message=message):
                # Эти сообщения после успешного ProbeDisk должны вести в WC.
                # Ошибки самого ProbeDisk и возврат в меню проверены отдельно.
                p = Plugin(blob)
                address = SYMS['RunDisk']
                p.cpu.set_breakpoint(address)
                p.hooks[address] = lambda: [setattr(p.model, {'disk': 'has_disk',
                    'drive': 'has_drive', 'protected': 'protected'}[k], v) for k, v in args.items()]
                p.final_key = None
                with self.assertRaisesRegex(WaitingForKey, 'error'):
                    p.call()
                self.assertEqual(p.result, result)
                self.assertEqual(p.word('TracksDone'), 0)
                self.check_summary(p, message)
                self.assertFalse(any(s.strip() in ('No disk', 'No drive') for row, x, s in p.messages))
                self.check_summary_exit(p, key)

    def test_summary_error_hides_previous_bad_crc_statistics_and_progress(self):
        blob = make_fdi({(0, 0): [Sector(0, 0, 1, 0, b'\xf5' + b'X' * 127, False, False)],
                         (1, 0): [Sector(1, 0, 2, 0, b'Z' * 128)]}, 2)
        p = Plugin(blob)
        def removed(cmd):
            if cmd & 0xF0 == 0xF0 and p.model.positions[0] == 1:
                p.model.has_disk = False
        p.model.on_command, p.final_key = removed, None
        with self.assertRaisesRegex(WaitingForKey, 'error'):
            p.call()
        self.assertEqual(p.result, 4)
        self.assertEqual(p.word('ApproxDone'), 1)
        self.assertEqual(p.word('ApproxBytes'), 1)
        self.assertEqual(p.word('TracksDone'), 1)
        self.assertTrue(any(e['row'] == 5 and '█' in e.get('text', '') for e in p.ui_events))
        self.check_summary(p, 'No disk in drive')
        self.check_summary_exit(p, 'up')

    def test_summary_all_reported_errors_have_exit_prompt(self):
        cases = [(1, 'Invalid or unsupported FDI'), (2, 'File read failed'),
                 (3, 'Drive not found'), (4, 'No disk in drive'), (5, 'Disk is write protected'),
                 (6, 'Seek failed'), (7, 'Write failed'), (8, 'Verification failed'),
                 (10, 'Controller timeout'), (11, 'Floppy disk controller not found')]
        reasons = [('MsgOffset', 'FDI offset beyond EOF'),
                   ('MsgCapacity', 'Track exceeds safe DD capacity'),
                   ('MsgSizeCode', 'Unsupported sector size')]
        for result, message, reason in ([(code, text, None) for code, text in cases]
                                       + [(1, text, symbol) for symbol, text in reasons]):
            with self.subTest(message=message):
                p = Plugin(make_fdi({(0, 0): []}))
                p.call('Options')
                p.call('CloseWindow')
                p.call('ShowWindow')
                p.poke('Result', result)
                p.poke('ApproxDone', 2, 2)
                p.poke('ApproxBytes', 123456, 4)
                if reason:
                    p.poke('ImageReason', SYMS[reason], 2)
                for row in (2, 3, 4, 5):
                    p.window_rows[row][:] = list('█' * 40)  # грязные строки должны очиститься целиком
                p.call('Summary')
                expected = {1: '', 2: message, 3: '', 4: 'Press any key to exit', 5: ''}
                self.assertEqual({row: ''.join(text) for row, text in p.window_rows.items()},
                    {row: (' ' * ((40 - len(text)) // 2) + text).ljust(40) for row, text in expected.items()})
                self.assertEqual([e['row'] for e in p.ui_events[-4:]], [2, 3, 4, 5])

    def check_controller_absent(self, bus, key):
        p = Plugin(make_fdi({(0, 0): [Sector(0, 0, 9, 0, b'X' * 128)]}),
                   absent_bus=bus, trace_io=True)
        p.final_key = None
        with self.assertRaisesRegex(WaitingForKey, 'error'):
            p.call()
        self.assertEqual(SYMS['ERR_NOFDC'], 11)
        self.assertEqual(p.result, 11)
        self.check_summary(p, 'Floppy disk controller not found')
        self.assertEqual([value for port, value in p.controller_outputs if port == 0x1F], [0xD0, 0xD0])
        self.assertFalse(p.model.commands or p.model.formatted or p.model.written or p.model.writes)
        self.assertEqual(p.word('TracksDone'), 0)
        self.assertFalse(p.model.motor_starts)
        # Все порты шины, в том числе не прочитанные этим кодом, отвечают константой.
        for port in (0x1F, 0x3F, 0x5F, 0x7F, 0xFF):
            self.assertEqual(p.model.input(port), bus)
        trace = [(op, port if port in (0xDFF7, 0xBFF7, 0x29AF) else port & 255, value)
                 for op, port, value in p.io_events]
        probe = [('out', 0x5F, 0x55), ('in', 0x5F, bus)]
        if bus == 0x55:
            probe += [('out', 0x5F, 0xAA), ('in', 0x5F, bus)]
        self.assertEqual(trace, [('out', 0xDFF7, 0xB0), ('in', 0xBFF7, 0x85),
                                ('out', 0x29AF, 0x80), ('out', 0xFF, 0x3C), ('out', 0x1F, 0xD0)]
                         + probe * 8 + [('out', 0x1F, 0xD0), ('out', 0x3F, 0),
                                    ('out', 0xFF, 4), ('out', 0x29AF, 0x85)])
        self.check_summary_exit(p, key)
        EVIDENCE.setdefault('controller_absent', {})[f'{bus:02X}'] = {
            'result': p.result, 'message': 'Floppy disk controller not found',
            'bus_trace': trace, 'exit_key': key, 'saved29_restored_before_key': True}

    def test_controller_absent_ff_stops_before_restore(self):
        self.check_controller_absent(0xFF, 'enter')

    def test_controller_absent_zero_stops_before_restore(self):
        self.check_controller_absent(0x00, 'escape')

    def test_controller_second_probe_mismatch_stops_before_restore(self):
        self.check_controller_absent(0x55, 'f1')

    def test_controller_present_probe_and_sector_reload_before_every_command(self):
        tracks = {(c, 0): [Sector(55 + c, 0, r, 0, bytes([r]) * 128) for r in (9, 17, 33)]
                  for c in range(2)}
        blob = make_fdi(tracks, 2)
        p = Plugin(blob, trace_io=True, timed=True)
        p.call()
        self.check_disk(p, blob)
        trace = [(op, port & 255, value) for op, port, value in p.io_events if
                 port not in (0xDFF7, 0xBFF7, 0x29AF) and port & 255 in (0x1F, 0x5F)]
        self.assertEqual(trace[:6], [('out', 0x1F, 0xD0), ('out', 0x5F, 0x55), ('in', 0x5F, 0x55),
                                    ('out', 0x5F, 0xAA), ('in', 0x5F, 0xAA), ('out', 0x1F, 0x08)])
        previous, reloads = -1, []
        sector_commands = [cmd for cmd in p.model.commands if cmd[0] & 0xE0 in (0x80, 0xA0)]
        for index, (op, port, cmd) in enumerate(trace):
            if op != 'out' or port != 0x1F:
                continue
            if cmd & 0xE0 in (0x80, 0xA0):
                between = [(j, e) for j, e in enumerate(trace[previous + 1:index], previous + 1)
                           if e[0] == 'out' and e[1] == 0x5F]
                self.assertEqual(len(between), 1, 'каждая READ/WRITE SECTOR заново загружает #5F')
                value = between[0][1][2]
                self.assertEqual(value, sector_commands[len(reloads)][3])
                self.assertIn(value, (9, 17, 33))
                reloads.append((cmd, value))
            previous = index
        self.assertEqual(len(reloads), len(sector_commands))
        self.assertEqual(sum(cmd & 0xE0 == 0xA0 for cmd, value in reloads), 6)
        self.assertEqual(sum(cmd & 0xE0 == 0x80 for cmd, value in reloads), 6)
        self.assertFalse(p.model.unsafe_commands)
        EVIDENCE['controller_present'] = {'probe': trace[:6], 'sector_reload_commands': reloads,
                                          'tracks_written_and_verified': p.word('TracksDone')}

    def test_preflight_reads_only_table_and_bad_crc(self):
        for name in ('IS_BASE.FDI', 'voron1/voron1.fdi', 'voron1/voron2.fdi'):
            blob = (ROOT / name).read_bytes()
            p = Plugin(blob)
            p.call('OpenInput')
            p.call('Validate')
            self.assertFalse(p.cpu.f & 1)
            self.assertFalse(p.controller_outputs)
            dataoff = int.from_bytes(blob[10:12], 'little')
            seq = [(off, size) for k, off, size in p.reads if k == 'LOAD512']
            self.assertEqual(seq, [(off, 512) for off in range(0, dataoff, 512)])
            positional = [(off, size) for k, off, size in p.reads if k == 'READ_AT']
            self.assertEqual(len(positional), 1 if name.endswith('voron1.fdi') else 0)
            self.assertEqual(p.word('ApproxExpected'), len(positional))
            self.assertEqual(p.word('ExpectedBytes'), 7 if positional else 0)

    def test_backward_offsets_use_isolated_filex_fallback(self):
        blob = bytearray(make_fdi({(0, 0): [Sector(0, 0, 1, 3, b'X' * 1024)],
                                  (1, 0): [Sector(1, 0, 1, 3, b'Y' * 1024)],
                                  (2, 0): [Sector(2, 0, 1, 3, b'Z' * 1024)]}, 3))
        blob[14:18], blob[28:32] = blob[28:32], blob[14:18]
        p = Plugin(bytes(blob))
        p.call()
        self.check_disk(p, bytes(blob))
        self.assertEqual(sum(k == 'READ_AT' for k, off, size in p.reads), 1)
        self.assertTrue(any(k == 'LOADNONE' for k, off, size in p.reads))
        offsets = [off for k, off, size in p.reads if k in ('LOAD512', 'LOADNONE')]
        self.assertEqual(offsets, sorted(set(offsets)))

    def test_crc_control_bytes_are_changed_without_fixing_crc(self):
        data = (b'\xf5\xf6\xf7\xf4\xf8' * 205)[:1024]
        blob = make_fdi({(0, 0): [Sector(55, 1, 192, 3, data, True, False)]})
        p = Plugin(blob, timed=True)
        p.call()
        self.check_disk(p, blob)
        self.assertFalse(p.model.written)
        self.assertFalse(p.model.tracks[(0, 0, 0)][0].good_crc)
        self.assertEqual(p.word('ApproxBytes'), sum(x in (0xF5, 0xF6, 0xF7) for x in data))
        self.assertTrue(any('CRC changed: 0001' in s and '000615 bytes' in s for y, x, s in p.messages))

    def test_angular_budget_and_tight_speed_tolerance(self):
        layouts = [(1, 16), (2, 9), (3, 5), ('tight', 6)]
        for n, count in layouts:
            capacities = (6188, 6250, 6313) if n == 'tight' else (6250,)
            sectors = [Sector(0, 0, r + 1, 3 if n == 'tight' and r < 5 else 2 if n == 'tight' else n,
                              bytes([r + 1]) * (1024 if n == 'tight' and r < 5 else 512 if n == 'tight' else 128 << n))
                       for r in range(count)]
            for capacity in capacities:
                with self.subTest(layout=n, capacity=capacity):
                    p = Plugin(make_fdi({(0, 0): sectors}), timed=True, capacity=capacity)
                    p.call()
                    self.check_disk(p, p.blob)
                    start, finish = p.model.track_times[(0, 0, 0)]
                    turns = (finish - start) / p.model.period
                    self.assertEqual(p.now(), p.elapsed)
                    self.assertAlmostEqual(p.model.revolutions, p.elapsed / p.model.period)
                    self.assertLessEqual(turns, 7)  # включая ожидание форматного индекса
                    self.assertEqual(len(p.model.written), count)
                    write_start = min(t for cmd, key, t, pos in p.model.command_times if cmd & 0xE0 == 0xA0)
                    write_end = max(t for cmd, key, t, status in p.model.command_finishes if cmd & 0xE0 == 0xA0)
                    self.assertLessEqual((write_end - write_start) / p.model.period, 1)
                    self.assertEqual(len(p.model.read_ids), count)
                    self.assertEqual([s[1][2] for s in p.model.read_sectors],
                                     [s.r for s in sectors[::2] + sectors[1::2]])
                    format_time = next(t for cmd, key, t, pos in p.model.command_times if cmd == 0xF4)
                    self.assertTrue(all(t > format_time + p.model.period
                                        for cmd, key, t, pos in p.model.command_times if cmd == 0x80))
                    if n == 'tight':
                        self.assertEqual(p.cpu.memory[SYMS['Tight']], 1)
                        self.assertEqual(p.cpu.memory[SYMS['Gap3']], 24)
                        ids = p.model.layouts[(0, 0, 0)]
                        self.assertEqual(ids[0][0], 40)  # 32 gap + 8 zeros
                        self.assertNotIn(b'\xc2\xc2\xc2\xfc', p.model.track_raw[(0, 0, 0)][0])
                    EVIDENCE['rotation'][f'{n}x{count}@{capacity}'] = {
                        'track_revolutions': round(turns, 6), 'seconds': round((finish - start) / p.model.frequency, 6),
                        'budget_revolutions': 7, 'write_commands': len(p.model.written),
                        'id_commands': len(p.model.read_ids), 'data_commands': len(p.model.read_sectors)}

    def test_fast_verify_failure_rewrites_track_before_fast_order(self):
        sectors = [Sector(0, 0, r, 3, bytes([r]) * 1024) for r in range(1, 6)]
        p = Plugin(make_fdi({(0, 0): sectors}), timed=True)
        count = [0]
        def fault(cmd):
            if cmd == 0x80:
                count[0] += 1
                p.model.fault = 'mismatch' if count[0] == 1 else None
        p.model.on_command = fault
        p.call()
        self.check_disk(p, p.blob)
        self.assertEqual([s[1][2] for s in p.model.read_sectors], [1, 1, 3, 5, 2, 4])
        self.assertEqual(len(p.model.formatted), 2)
        self.assertNotIn('choice', p.wait_events)

    def test_disk_removed_during_verify_is_fatal_message(self):
        p = Plugin(make_fdi({(0, 0): [Sector(0, 0, 1, 1, b'X' * 256)]}))
        def removed(cmd):
            if cmd == 0x80:
                p.model.has_disk = False
        p.model.on_command = removed
        p.call()
        self.assertEqual(p.result, 4)
        self.assertNotIn('choice', p.wait_events)
        self.assertIn('error', p.wait_events)
        self.assertEqual(p.mask, 0x85)

    def test_steady_disk_rotation_estimate(self):
        for n, count in ((3, 5), (2, 9), (1, 16)):
            tracks = {(c, 0): [Sector(c, 0, r, n, bytes([r]) * (128 << n))
                               for r in range(1, count + 1)] for c in range(6)}
            p = Plugin(make_fdi(tracks, 6), timed=True)
            p.call()
            self.check_disk(p, p.blob)
            first = next(t for cmd, key, t, pos in p.model.command_times if cmd == 0xF4)
            finish = p.model.track_times[(0, 5, 0)][1]
            average = (finish - first) / 6 / p.model.frequency
            self.assertLessEqual(average, 1.4)
            EVIDENCE['rotation'][f'{count}x{128 << n}-six-tracks'] = {
                'seconds_per_track': round(average, 6),
                'estimated_160_tracks_seconds': round(average * 160, 3),
                'includes_host_api_stub_ticks': p.api_ticks,
                'hardware': False}

    def test_is_hum1_is_written_and_verified(self):
        with zipfile.ZipFile(ROOT / 'ISDOS.ZIP') as archive:
            blob = archive.read('IS-HUM1.FDI')
        p = Plugin(blob)
        p.call()
        self.check_disk(p, blob)
        self.assertEqual(len(p.model.tracks), 162)
        self.assertEqual(sum(len(s) == 6 for s in p.model.tracks.values()), 20)


class ControllerTests(unittest.TestCase):
    def stream(self, data=b'Z' * 128, mark=0xFB, cylinder=0, n=0):
        return (b'\x4e' * 80 + b'\0' * 12 + b'\xf6' * 3 + b'\xfc' + b'\x4e' * 50
                + b'\0' * 12 + b'\xf5' * 3 + b'\xfe' + bytes([cylinder, 0, 1, n]) + b'\xf7'
                + b'\x4e' * 22 + b'\0' * 12 + b'\xf5' * 3 + bytes([mark]) + data + b'\xf7')

    def test_crc_known_answer(self):
        self.assertEqual(crc16(b'123456789'), 0x29B1)
        self.assertEqual(crc16(b'\xa1' * 3), 0xCDB4)

    def test_format_controls_and_capacity(self):
        for mark in range(0xF8, 0xFC):
            m = WD1793(capacity=600)
            for token in self.stream(mark=mark):
                m.token(token)
            result = decode_track(m.raw, m.clocks, m.capacity)
            self.assertEqual(result, [Sector(0, 0, 1, 0, b'Z' * 128, mark < 0xFA)])
            self.assertEqual(m.raw[92:96], b'\xc2\xc2\xc2\xfc')
            while len(m.raw) < m.capacity:
                m.token(0x4E)
            with self.assertRaisesRegex(AssertionError, 'capacity'):
                m.token(0x4E)
            with self.assertRaisesRegex(AssertionError, 'overflow'):
                decode_track(m.raw + b'\x4e', m.clocks + [0], m.capacity)

    def test_track_register_side_and_length(self):
        m = WD1793()
        m.positions[0] = 59
        m.tracks[(0, 59, 0)] = [Sector(55, 1, 192, 2, bytes(range(256)) * 2)]
        m.track, m.sector = 59, 192
        m.start(0x80)
        for _ in range(3): m.input(0xFF)
        self.assertEqual(m.status, 0x10)
        m.track = 55
        m.load_head()
        m.motor_since[0] -= 5 * m.period
        m.start(0x80)
        result = bytearray()
        while not m.intrq:
            if m.input(0xFF) & 64:
                result.append(m.input(0x7F))
        self.assertEqual(result, bytes(range(256)) * 2)
        self.assertFalse(m.input(0x1F) & 8)
        m.start(0x88)                    # сравнение H=0: сектор H=1 не найдётся
        for _ in range(3): m.input(0xFF)
        self.assertEqual(m.status, 0x10)

    def test_type1_force_interrupt_and_write_protect(self):
        m = WD1793(protected=True)
        m.track, m.data = 0, 3
        m.start(0x18)
        self.assertFalse(m.intrq)
        for _ in range(3): m.input(0xFF)
        self.assertEqual((m.positions[0], m.track), (3, 3))
        self.assertTrue(m.intrq)
        m.input(0x1F)
        self.assertFalse(m.intrq)
        m.start(0xF0)
        for _ in range(3): m.input(0xFF)
        self.assertEqual(m.status, 64)
        self.assertFalse(m.tracks)
        m.start(0xD0)
        self.assertFalse(m.busy or m.drq or m.intrq)


if __name__ == '__main__':
    unittest.main()
