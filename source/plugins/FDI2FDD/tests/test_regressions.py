"""Третий–седьмой заходы: воспроизведения стендовых дефектов на текущем WMF.

Отрицательные контроли меняют только RAM тестового Z80. Источники, WMF и
образы на диске не откатываются. Мутации отдельных исправлений не выдаются
за побайтную копию полного второго артефакта.
"""
import unittest
import test_plugin as harness
from test_plugin import Plugin, SYMS, EVIDENCE, COUNT, ROOT
from wc_keyboard import Keyboard, TAB, ARR, ARK
from wd1793 import WD1793
from fdi import Sector, make_fdi, parse_fdi


def tiny():
    return make_fdi({(0, 0): [Sector(0, 0, r, 0, bytes([r]) * 128) for r in (1, 2)]})


def remove_latch_clear(p, label):
    start = SYMS[label]
    old = bytes(p.cpu.memory[start:start + 16])
    offset = old.index(b'\x32\x04\x60')   # LD (#6004),A
    p.cpu.memory[start + offset:start + offset + 3] = b'\0' * 3


def nusp_before_checks(p, options=False):
    """Восстановить NUSP ПЕРЕД прежними проверками, не трогая их ветки."""
    address = SYMS['Options.loop' if options else 'ReadKey.wait']
    assert bytes(p.cpu.memory[address:address + 2]) == b'\xfb\x76'
    p.cpu.clear_breakpoint(address + 1)
    assert bytes(p.cpu.memory[address + 2:address + 4]) == b'\x3e\x17'
    restore, size = b'\x3e\x17', 4
    p.cpu.memory[address:address + size] = b'\xcd\x00\xb4' + bytes(size - 3)
    code = b'\x3e\x2f\xcd\x06\x60' + restore + b'\xc9'
    p.cpu.memory[0xB400:0xB400 + len(code)] = code


class KeyboardTests(unittest.TestCase):
    def test_ps2_table_first_repeat_last_key_and_anyk(self):
        memory = bytearray(65536)
        k = Keyboard(memory)
        for key, scan in (('enter', 0x5A), ('escape', 0x76), ('up', 0x75), ('down', 0x72),
                          ('left', 0x6B), ('right', 0x74)):
            k.release()
            k.press(key)
            self.assertEqual((memory[ARK], memory[ARR]), (scan, 0xFF))
            self.assertTrue(k.check(key))
            self.assertEqual(memory[ARR], 25)
            self.assertFalse(k.check(key))
            for _ in range(24): k.frame()
            self.assertFalse(k.check(key))
            k.frame()
            self.assertTrue(k.check(key))
            for _ in range(30):
                k.frame()
                self.assertEqual(k.any(), 25)
                self.assertFalse(k.check(key))
        k.release()
        k.press('y')
        self.assertEqual(k.character(), ord('y'))
        self.assertEqual(k.character(), 0)
        k.release()
        k.press('Y')                     # KBSCN(1) = TAIE1, без Shift/RUS
        k.any()
        self.assertEqual(k.character(), 0)
        k.release()
        self.assertEqual(k.any(), 0)
        self.assertEqual(memory[ARK], 0x35)
        k.press('up')
        k.press('down')                  # удержанная Up уже не последняя
        self.assertFalse(k.check('up'))
        self.assertTrue(k.check('down'))
        self.assertTrue(memory[TAB + 5] and memory[TAB + 7])
        k.release('up')
        self.assertFalse(memory[TAB + 5])
        self.assertTrue(memory[TAB + 7])
        k.release()
        k.press('y')
        k.press('n')
        k.release('y')
        self.assertEqual(k.character(), ord('n'))
        self.assertEqual(memory[ARK], 0x31)

    def test_readkey_special_printable_and_other(self):
        for key, expected in (('escape', 27), ('enter', 13), ('Y', ord('y')),
                              ('y', ord('y')), ('N', ord('n')), ('n', ord('n')),
                              ('up', 0), ('f1', 0), ('r', ord('r')),
                              ('i', ord('i')), ('a', ord('a'))):
            with self.subTest(key=key):
                p = Plugin(tiny())
                p.warning_key, p.stage = key, 'warning'
                self.assertEqual(p.call('ReadKey'), expected)
                self.assertGreater(p.keyboard.frames, 0)
                self.assertNotIn(47, p.api_calls)
                self.assertEqual(p.api_calls[-1] == 45, expected == 0)

    def test_nusp_then_check_negative_control(self):
        p = Plugin(tiny())
        p.option_keys = ['right', 'enter']
        p.call('Options')
        self.assertEqual(p.cpu.memory[SYMS['Drive']], 1)
        bad = Plugin(tiny())
        bad.option_keys = ['right', 'enter']
        nusp_before_checks(bad, options=True)
        with self.assertRaisesRegex(AssertionError, 'swallowed first press'):
            bad.call('Options')
        for key in ('Y', 'y', 'r', 'i', 'a', 'enter', 'escape'):
            p = Plugin(tiny())
            p.stage, p.warning_key = 'warning', key
            nusp_before_checks(p)
            self.assertEqual(p.call('ReadKey'), 0)  # NUSP замолчал Esc/Enter/символ
        bad = Plugin(tiny())
        nusp_before_checks(bad)
        bad.call()
        self.assertEqual(bad.result, 9)
        self.assertEqual([cmd for cmd, *_ in bad.model.commands], [0xD0, 0x08, 0xD0])
        self.assertEqual([e['b'] for e in bad.frequency_events], [0, 255])
        self.assertFalse(bad.reads or bad.model.writes)
        EVIDENCE.setdefault('negative_controls', {})['F1'] = 'NUSP before checks: movement and ReadKey fail'

    def test_uspo_release_and_return_to_wc(self):
        p = Plugin(tiny())
        p.keyboard.press('enter')
        p.key_frames = 2
        p.call()
        self.assertEqual(p.result, 0)
        self.assertFalse(p.keyboard.held)
        self.assertGreaterEqual(p.keyboard.release_frames, 2)
        self.assertEqual(p.api_calls[-2:], [46, 2])
        p = Plugin(tiny())
        p.keyboard.press('enter')        # потерянный break: USPO_SAFE очистит TAB
        p.release_keys()
        self.assertFalse(p.keyboard.held)
        self.assertEqual(p.keyboard.release_frames, 75)
        p = Plugin(tiny())
        p.keyboard.press('enter')
        p.key, p.key_frames = 'enter', 100
        p.release_keys()                 # настоящая зажатая клавиша переживает grace
        self.assertGreaterEqual(p.keyboard.frames, 100)
        self.assertFalse(p.keyboard.held)

    def test_errorchoice_all_keys_and_unknown_then_retry(self):
        for keys, ignored, aborted in ((['r'], 0, False), (['R'], 0, False),
                (['enter'], 0, False), (['i'], 1, False), (['I'], 1, False),
                (['a'], 0, True), (['A'], 0, True), (['escape'], 0, True),
                (['x', 'r'], 0, False)):
            with self.subTest(keys=keys):
                p = Plugin(tiny(), fault='write_sector')
                p.error_keys = list(keys)
                def wait(stage):
                    if stage == 'choice': p.model.fault = None
                p.on_wait = wait
                p.call()
                self.assertEqual(p.result, 9 if aborted else 0)
                self.assertEqual(p.word('IgnoredDone'), ignored)
                self.assertFalse(p.keyboard.held)


class StandTests(unittest.TestCase):
    def test_wc_frame_counter_file_api_and_di(self):
        p = Plugin(tiny(), timed=True, frequency=3_500_000)
        p.cpu.memory[COUNT:COUNT + 2] = (65530).to_bytes(2, 'little')
        p.api_ticks = 0
        samples = []
        def file_pause(api):
            if api == 48:
                before, time = p.word(COUNT), p.now()
                p.advance_time(60)
                samples.append((p.interrupts_enabled, before, p.word(COUNT), p.now() - time))
        p.on_api = file_pause
        load = b'\x3e\x30\x06\x01\x21\x00\xa8\xcd\x06\x60'
        code = load + b'\xf3' + load + b'\xfb\xc9'
        address = 0x7200             # FILEX затирает B000..BFFF
        p.cpu.memory[address:address + len(code)] = code
        for offset in (len(load), 2 * len(load) + 1):
            p.clock_breakpoints.add(address + offset)
            p.cpu.set_breakpoint(address + offset)
        p.cpu.pc, p.cpu.sp = address, harness.STACK
        p.cpu.memory[harness.STACK:harness.STACK + 2] = harness.STOP.to_bytes(2, 'little')
        p.run()
        self.assertEqual([(enabled, (after - before) & 0xFFFF)
                          for enabled, before, after, ticks in samples], [(True, 3000), (False, 0)])
        self.assertEqual(samples[0][2], 2994)  # 16-битное переполнение счётчика WC
        self.assertTrue(all(ticks == 60 * p.model.frequency for _, _, _, ticks in samples))
        self.assertEqual(p.word(COUNT), 2994) # пропущенные под DI кадры не догоняются

    def test_wc_frame_counter_actual_cpu_and_key_wait(self):
        p = Plugin(tiny(), timed=True, frequency=3_500_000)
        # Настоящий цикл Z80 занимает несколько кадров: EI/DI разделяют часы,
        # LD HL,(6009) должен увидеть их ДО исполнения инструкции чтения.
        loop = b'\x01\xff\xff\x0b\x78\xb1\x20\xfb'
        read = b'\x2a\x09\x60'
        code = (loop + read + b'\x22\x00\xb5\xf3' +
                loop + read + b'\x22\x02\xb5\xfb' +
                loop + read + b'\x22\x04\xb5\xc9')
        address = 0xB400
        p.cpu.memory[address:address + len(code)] = code
        for offset in (8, 14, 23, 29, 38):
            p.clock_breakpoints.add(address + offset)
            p.cpu.set_breakpoint(address + offset)
        p.cpu.pc, p.cpu.sp = address, harness.STACK
        p.cpu.memory[harness.STACK:harness.STACK + 2] = harness.STOP.to_bytes(2, 'little')
        p.run()
        first, under_di, after_ei = (p.word(a) for a in (0xB500, 0xB502, 0xB504))
        self.assertGreater(first, 0)
        self.assertEqual(under_di, first)
        self.assertGreater(after_ei, first)
        self.assertLess(p.word(COUNT), int(p.elapsed * 50 / p.model.frequency))
        before, time, phase = p.word(COUNT), p.now(), p.frame_phase
        p.stage, p.warning_key = 'warning', 'y'
        p.key_delays = {'warning': 6}
        self.assertEqual(p.call('ReadKey'), ord('y'))
        self.assertEqual((p.word(COUNT) - before) & 0xFFFF,
                         int(phase + (p.now() - time) * 50 / p.model.frequency + 1e-9))
        self.assertGreaterEqual((p.word(COUNT) - before) & 0xFFFF, 301) # HALT + 6 секунд
        EVIDENCE['wc_frame_counter'] = {'address': '0x6009', 'hz': 50,
                                       'file_pause_60s_frames': 3000, 'di_frames': 0,
                                       'wraparound': True, 'actual_cpu_and_key_wait': True}

    def test_motor_idle_threshold_and_track_register_restoration(self):
        rows = []
        for frames in (0, 74, 75, 300, 3000):
            with self.subTest(frames=frames):
                p = Plugin(tiny(), timed=True, frequency=3_500_000)
                p.cpu.memory[0x6004] = 0 # прямой OpenFDC минует очистку RunDisk
                self.assertEqual(p.call('OpenFDC'), 0)
                p.model.track = 55
                p.cpu.memory[COUNT:COUNT + 2] = (65530).to_bytes(2, 'little')
                p.poke('LastCmd', p.word(COUNT), 2)
                p.advance_time(frames / 50)
                before, count = p.now(), len(p.model.commands)
                p.call('EnsureMotor')
                turns = (p.now() - before) / p.model.period
                seeks = [cmd for cmd, key, track, sector in p.model.commands[count:] if cmd == 0x18]
                self.assertFalse(p.cpu.f & 1)
                self.assertEqual(p.model.track, 55)
                self.assertEqual(p.model.positions[0], 0)
                self.assertEqual(len(seeks), int(frames >= 75))
                if frames >= 75:
                    self.assertGreaterEqual(turns, 5)
                    self.assertLess(turns, 6.05)
                    self.assertEqual(p.word('LastCmd'), p.word(COUNT))
                else:
                    self.assertLess(turns, .01) # ни SEEK, ни добавочных оборотов
                rows.append({'idle_frames': frames, 'restart_seeks': len(seeks),
                             'ensure_motor_revolutions': round(turns, 6)})
        EVIDENCE['motor_idle_threshold'] = rows

    def test_retry_ignore_restart_after_short_and_six_second_prompts(self):
        for seconds in (0, 6):
            for choice in ('r', 'i', 'a'):
                with self.subTest(seconds=seconds, choice=choice):
                    p = Plugin(tiny(), timed=True)
                    p.model.fault = 'write_sector'
                    p.error_keys, p.key_delays = [choice], {'choice': seconds}
                    prompt_end = []
                    def wait(stage):
                        if stage == 'choice':
                            p.model.fault = None
                            prompt_end.append(p.now() + seconds * p.model.frequency)
                    p.on_wait = wait
                    p.call()
                    self.assertEqual(p.result, 9 if choice == 'a' else 0)
                    self.assertFalse(p.model.unsafe_commands)
                    after = [(cmd, t) for cmd, key, t, pos in p.model.command_times if t >= prompt_end[0]]
                    seeks = [t for cmd, t in after if cmd == 0x18]
                    data = [t for cmd, t in after if cmd >= 0x80 and cmd & 0xF0 != 0xD0]
                    if choice == 'a':
                        self.assertFalse(seeks or data)
                    else:
                        self.assertEqual(len(seeks), 1)
                        self.assertTrue(data)
                        self.assertGreaterEqual((data[0] - seeks[0]) / p.model.period, 5)
                        self.assertLess((data[0] - seeks[0]) / p.model.period, 6.1)
                        self.assertEqual(p.word('IgnoredDone'), int(choice == 'i'))
                        if choice == 'r': harness.PluginTests().check_disk(p, p.blob)

    def test_boot_esc_latch_and_negative_control(self):
        p = Plugin(tiny())
        self.assertEqual(p.cpu.memory[0x6004], 0xBC)
        p.call()
        harness.PluginTests().check_disk(p, p.blob)
        bad = Plugin(tiny())
        remove_latch_clear(bad, 'StartFDC')
        # Общее StartFDC очищает мусор и при ProbeDisk, и при RunDisk.
        bad.call()
        self.assertEqual(bad.result, 9)
        self.assertEqual(bad.word('TracksDone'), 0)
        EVIDENCE.setdefault('negative_controls', {})['F2_boot'] = 'removed StartFDC clear: ERR_BREAK'

    def test_choice_esc_latch_retry_ignore_negative_controls(self):
        for key, label in (('r', 'ErrorChoice.retry'), ('i', 'ErrorChoice.ignore')):
            for mutant in (False, True):
                with self.subTest(key=key, mutant=mutant):
                    p = Plugin(tiny(), fault='write_sector')
                    p.error_keys = [key]
                    def wait(stage):
                        if stage == 'choice':
                            p.cpu.memory[0x6004] = 0xBC
                            p.model.fault = None
                    p.on_wait = wait
                    if mutant: remove_latch_clear(p, label)
                    p.call()
                    self.assertEqual(p.result, 9 if mutant else 0)
                    self.assertEqual(p.word('IgnoredDone'), int(key == 'i'))
        EVIDENCE.setdefault('negative_controls', {})['F2_choice'] = 'removed Retry/Ignore clear: ERR_BREAK'

    def test_real_esc_latched_and_released_aborts_at_boundary(self):
        p = Plugin(tiny())
        def escape(cmd):
            if cmd & 0xE0 == 0xA0:
                p.cpu.memory[0x6004] = 1
                p.keyboard.release()    # API 23 уже не видит короткий Esc
        p.model.on_command = escape
        p.call()
        self.assertEqual(p.result, 9)
        self.assertFalse(p.keyboard.held or p.model.busy)
        self.assertEqual(p.mask, 0x85)
        self.assertNotIn('done', p.wait_events)

    def test_spinup_index_and_old_time_pause_negative_control(self):
        p = Plugin(tiny(), timed=True, frequency=3_500_000)
        p.call()
        self.assertEqual(p.result, 0)
        self.assertFalse(p.model.unsafe_commands)
        bad = Plugin(tiny(), timed=True)
        address = SYMS['SpinUpFromIndex']
        bad.cpu.set_breakpoint(address)
        bad.hooks = {address: lambda: bad.advance_time(3)}
        bad.final_key = None
        with self.assertRaisesRegex(harness.WaitingForKey, 'error'):
            bad.call()
        self.assertEqual(bad.result, 4)
        bad.option_keys, bad.final_key = ['escape'], 'space'
        bad.resume()
        self.assertFalse(bad.model.writes)
        EVIDENCE.setdefault('negative_controls', {})['F3_initial'] = 'idle > motor timeout: no INDEX / ERR_DISK'

    def test_minute_choice_restart_write_read_ids_and_abort(self):
        sectors = [Sector(55, 1, r, 0, bytes([r]) * 128) for r in (1, 2)]
        blob = make_fdi({(1, 0): sectors}, cylinders=2)
        for kind in ('write_sector', 'mismatch', 'id_mismatch'):
            for choice in ('r', 'i', 'a'):
                with self.subTest(fault=kind, choice=choice):
                    p = Plugin(blob, timed=True)
                    p.error_keys, p.key_delays = [choice], {'choice': 60}
                    active = [True]
                    def fault(cmd):
                        if cmd >= 0x80 and cmd & 0xF0 != 0xD0:
                            p.model.fault = kind if p.model.positions[0] == 1 and active[0] else None
                    def wait(stage):
                        if stage == 'choice': active[0] = False
                    p.model.on_command, p.on_wait = fault, wait
                    p.call()
                    self.assertEqual(p.result, 9 if choice == 'a' else 0)
                    self.assertEqual(p.wait_events.count('choice'), 1)
                    self.assertFalse(p.model.unsafe_commands)
                    self.assertEqual(p.model.track, p.cpu.memory[SYMS['Physical']])
                    if choice != 'a':
                        self.assertEqual(p.word('TracksDone'), 2)
                        self.assertGreaterEqual(len(p.model.motor_starts), 2)
                        restarts = [t for cmd, key, t, pos in p.model.command_times
                                    if cmd == 0x18 and t > 60 * p.model.frequency]
                        self.assertTrue(restarts)
                        next_data = next(t for cmd, key, t, pos in p.model.command_times
                                         if cmd >= 0x80 and cmd & 0xF0 != 0xD0 and t > restarts[0])
                        self.assertGreaterEqual((next_data - restarts[0]) / p.model.period, 5)
                        # VerifyIDs после раскрутки дополнительно синхронизирует
                        # начало порядка ID по INDEX: ещё до одного оборота.
                        self.assertLess((next_data - restarts[0]) / p.model.period, 7.1)
                        self.assertEqual([s.id for s in p.model.tracks[(0, 1, 0)]], [s.id for s in sectors])
                        if choice == 'r':
                            harness.PluginTests().check_disk(p, blob)
                        else:
                            self.assertEqual(p.model.tracks[(0, 1, 0)][1].data, sectors[1].data)
                    else:
                        self.assertFalse(any(cmd >= 0x80 and cmd & 0xF0 != 0xD0
                                             and t > 60 * p.model.frequency
                                             for cmd, key, t, pos in p.model.command_times))

    def test_minute_file_pause_restart_and_no_restart_negative_control(self):
        blob = make_fdi({(c, 0): [Sector(c, 0, 1, 3, b'X' * 1024)] for c in range(2)}, 2)
        for mutant in (False, True):
            p = Plugin(blob, timed=True)
            paused = [False]
            def api(number):
                if number == 48 and p.model.formatted and not paused[0]:
                    paused[0] = True
                    p.advance_time(60)
            p.on_api = api
            if mutant:
                address = SYMS['EnsureMotor']
                code = b'\xcd' + SYMS['ForceIdle'].to_bytes(2, 'little') + b'\xaf\xc9'
                p.cpu.memory[address:address + len(code)] = code
            p.call()
            self.assertTrue(paused[0])
            if mutant:
                self.assertTrue(p.model.unsafe_commands)
                self.assertNotEqual(p.result, 0)
            else:
                harness.PluginTests().check_disk(p, blob)
                self.assertFalse(p.model.unsafe_commands)
        EVIDENCE.setdefault('negative_controls', {})['F3_resume'] = 'EnsureMotor disabled: early write is corrupted'

    def test_hld_not_reported_after_d0_only_changes_status(self):
        time = [0]
        m = WD1793(timed=True, frequency=3_500_000, now=lambda: time[0],
                   report_head_loaded_after_d0=False)
        m.start(0x18)
        for _ in range(3): m.input(0xFF)
        self.assertTrue(m.input(0x1F) & 32) # type I команда сообщает HLD
        time[0] += 5 * m.period
        m.start(0xD0)
        self.assertFalse(m.input(0x1F) & 32)
        self.assertTrue(m.head_loaded and m.at_speed and m.index)
        self.assertEqual(len(m.motor_starts), 1)
        time[0] += 11 * m.period
        self.assertFalse(m.head_loaded or m.index) # физический timeout сохранён

    def test_hld_status_restart_negative_control(self):
        bad = Plugin(tiny(), timed=True, report_head_loaded_after_d0=False)
        start, spin, ready = (SYMS[name] for name in ('EnsureMotor', 'EnsureMotor.spin', 'EnsureMotor.ready'))
        # Только в RAM: старое решение по bit 5 после D0, остальная раскрутка
        # и сохранение Physical/чужого track register остаются текущими.
        code = (b'\xc5\xd5\xe5\xcd' + SYMS['ForceIdle'].to_bytes(2, 'little') +
                b'\xdb\x1f\xe6\x20\xc2' + ready.to_bytes(2, 'little') +
                b'\xc3' + spin.to_bytes(2, 'little'))
        self.assertLessEqual(len(code), spin - start)
        bad.cpu.memory[start:spin] = code.ljust(spin - start, b'\0')
        bad.call()
        self.assertNotEqual(bad.result, 0)
        self.assertTrue(any('Verification failed' in text for row, x, text in bad.messages))
        ids = [ident for key, ident in bad.model.read_ids]
        self.assertGreaterEqual(len(ids), 2)
        self.assertEqual(ids[0], ids[1]) # повторная раскрутка снова выбирает первый ID
        self.assertGreater(sum(cmd == 0x18 for cmd, key, track, sector in bad.model.commands), 3)
        EVIDENCE.setdefault('negative_controls', {})['F3_hld_status'] = (
            'HLD decision after D0 restored in RAM: extra spinups, repeated ID, Verification failed')

    def test_real_images_without_hld_after_d0_normal_revolution_budget(self):
        rows = {}
        for name in ('IS_BASE.FDI', 'voron1/voron1.fdi', 'voron1/voron2.fdi'):
            with self.subTest(image=name):
                blob = (ROOT / name).read_bytes()
                source, _ = parse_fdi(blob)
                p = Plugin(blob, timed=True, report_head_loaded_after_d0=False)
                p.call()
                harness.PluginTests().check_disk(p, blob)
                self.assertFalse(p.model.unsafe_commands)
                self.assertNotIn('choice', p.wait_events)
                self.assertEqual(len(p.model.motor_starts), 2)  # проба и работа, CloseFDC между ними
                self.assertEqual(sum(cmd == 0x18 for cmd, key, track, sector in p.model.commands),
                                 p.word('TracksDone')) # только штатный SEEK на дорожку
                turns, empty_turns = [], []
                for (drive, cylinder, side), (start, finish) in p.model.track_times.items():
                    value = (finish - start) / p.model.period
                    empty = not source[(cylinder, side)]
                    # Пустую дорожку проверяет один READ ADDRESS с RNF через
                    # 5 оборотов. До FORMAT есть ещё 30 мс head settle (0,15
                    # оборота при 300 rpm), затем ожидание индекса, FORMAT,
                    # синхронизация ID и RNF: до 8,15 + запас на инструкции.
                    self.assertLessEqual(value, 8.2 if empty else 7, (name, cylinder, side))
                    (empty_turns if empty else turns).append(value)
                rows[name] = {'tracks': p.word('TracksDone'), 'motor_starts': 2,
                              'restart_seeks': 0, 'max_track_revolutions': round(max(turns), 6),
                              'max_empty_track_revolutions': round(max(empty_turns, default=0), 6),
                              'empty_tracks': len(empty_turns),
                              'budget_revolutions': {'with_sectors': 7, 'empty': 8.2},
                              'seconds': round(p.now() / p.model.frequency, 6),
                              'head_loaded_bit_after_d0': False}
                print(f'\nHLD после D0=0: {name}, {p.word("TracksDone")} дорожек, '
                      f'с секторами ≤{max(turns):.6f}, пустые ≤{max(empty_turns, default=0):.6f} '
                      'оборота, дополнительных раскруток 0', flush=True)
        EVIDENCE['real_images_without_hld_after_d0'] = rows

    def test_motor_stops_no_index_no_drq_and_d0_does_not_restart(self):
        for turns in (10, 15):
            time = [0]
            m = WD1793(timed=True, frequency=3_500_000, now=lambda: time[0],
                       motor_idle_revolutions=turns)
            self.assertFalse(m.index)
            m.start(0x18)
            for _ in range(3): m.input(0xFF)
            self.assertTrue(m.input(0x1F) & 32)
            time[0] += (turns + 1) * m.period
            self.assertFalse(m.input(0x1F) & 32)
            self.assertFalse(m.index)
            m.start(0xD0)
            self.assertFalse(m.head_loaded or m.input(0xFF) & 64)
            time[0] += m.frequency / 1000 # тихое время после D0
            m.start(0xF4)
            m.drq = True                 # остановка извне при уже активном DRQ
            m.output_port(0xFF, 0x34)
            self.assertFalse(m.index or m.input(0xFF) & 64)

    def test_model_corrupts_a_write_before_speed(self):
        m = WD1793()
        sector = Sector(0, 0, 1, 0, b'Z' * 128)
        m.tracks[(0, 0, 0)] = [sector]
        m.start(0xA0)
        for _ in range(128):
            self.assertTrue(m.input(0xFF) & 64)
            m.output_port(0x7F, ord('X'))
        self.assertTrue(m.unsafe_commands)
        self.assertNotEqual(sector.data, b'X' * 128)

    def test_maxstream_filler_reaches_payload(self):
        p = Plugin(tiny(), capacity=6500)
        p.call()
        harness.PluginTests().check_disk(p, p.blob)
        self.assertEqual(SYMS['MAXSTREAM'], 6656)
        self.assertEqual(SYMS['STREAM'] + SYMS['MAXSTREAM'], SYMS['PAYLOAD'])
        self.assertEqual(p.model.track_raw[(0, 0, 0)][0][-100:], b'\x4e' * 100)
        bad = Plugin(tiny(), capacity=6500)
        start = SYMS['BuildStream'] + 9
        self.assertEqual(bytes(bad.cpu.memory[start:start + 3]), b'\x01\xff\x19')
        bad.cpu.memory[start + 1:start + 3] = (6400 - 1).to_bytes(2, 'little')
        start = SYMS['RunDisk.format']
        code = bytes(bad.cpu.memory[start:start + 24])
        offset = code.index(b'\x11\x00\x1a')
        bad.cpu.memory[start + offset + 1:start + offset + 3] = (6400).to_bytes(2, 'little')
        bad.call()
        self.assertEqual(bad.result, 7)
        self.assertEqual(bad.word('TracksDone'), 0)
        EVIDENCE.setdefault('negative_controls', {})['F4_buffer'] = 'MAXSTREAM 6400: format exceeds transfer limit'

    def test_moonsound_port_conflict_is_lost_data(self):
        p = Plugin(tiny(), timed=True, moonsound=True)
        p.call()
        self.assertEqual(p.result, 7)
        self.assertTrue(p.model.sound_bytes)
        self.assertFalse(p.model.formatted)
        self.assertTrue(any(status & 4 for cmd, key, t, status in p.model.command_finishes))


class TransferTests(unittest.TestCase):
    def probe(self, read, phase, slow=False, extra=0, tick_scale=1,
              counter=0x0101, stream=False, stall_after_byte=False):
        p = Plugin(tiny(), timed=True, frequency=3_500_000, tick_scale=tick_scale)
        p.cpu._Z80State__iff1[0] = p.cpu._Z80State__iff2[0] = 0 # вход прямо в DI-цикл
        m = p.model
        p.mask = 0x80
        p.cpu.memory[0x6004] = 0
        m.load_head()
        m.motor_since[0] -= 5 * m.period
        m.busy, m.intrq, m.drq = True, False, False
        m.command = 0x80 if read else 0xA0
        m.operation = 'read' if read else 'write'
        m.queue = b'X' * (1 + extra)
        m.active = Sector(0, 0, 1, 0, b'Z')
        m.length = 1 + extra
        m.ready_at = phase * p.tick_scale
        m.write_data_at = m.ready_at
        m.deadline = m.ready_at + m.service_ticks()
        if stall_after_byte:
            original_consumed = m.consumed
            def consumed(expansion=1):
                original_consumed(expansion)
                m.operation = 'stall'    # один байт принят; дальше нет DRQ/INTRQ
            m.consumed = consumed
        p.poke('TransferStart', 0xAC00, 2)
        p.poke('TransferLimit', 1, 2)
        p.poke('TransferKind', 8 if read else 7)
        p.cpu.alt_bc = 0x0401
        label = 'ReadBytes.wait' if read else 'WriteBytes.wait'
        polls = []
        original_input = m.input
        def input_port(port):
            if port & 255 == 0xFF:
                polls.append(p.now())
            return original_input(port)
        m.input = input_port
        p.transfer_polls = polls
        if slow:
            # 36 NOP + 3*LD A,0 + JP = 175 T дополнительно: холостой путь
            # ровно 214 T, как во втором заходе. Lost Data выводит FDC по часам.
            address = SYMS[label]
            assert p.cpu.memory[address + 7] == 0xC2
            p.cpu.memory[address + 8:address + 10] = b'\x00\xb4'
            code = b'\0' * 36 + b'\x3e\0' * 3 + b'\xc3' + address.to_bytes(2, 'little')
            p.cpu.memory[0xB400:0xB400 + len(code)] = code
        if stream:
            # Первый из пяти IN после байта; адрес выводим из WMF, не ASM.
            start = SYMS['ReadBytes.stream' if read else 'WriteBytes.stream']
            self.assertEqual(bytes(p.cpu.memory[start:start + 2]), b'\xdb\xff')
            label = start
        p.call(label, bc=0x017F, de=0x0202 if slow else counter, hl=0xAC00)
        return p

    def test_3500khz_drq_phase_budgets_measured_by_cpu(self):
        import math
        rows = {}
        for read in (False, True):
            kind = 'read' if read else 'write'
            for path, counter, stream, phases, expected in (
                    ('stream', 0x0202, True, range(12, 111), 67 if read else 60),
                    ('stream_to_wait', 0x0202, True, range(112, 147), 77 if read else 70),
                    ('waiting', 0x0202, False, range(12, 151), 81 if read else 74),
                    ('second_counter', 0x0201, False, range(12, 89), 81 if read else 74),
                    ('third_counter', 0x0101, False, range(90, 137), 89 if read else 82)):
                values = []
                for phase in phases:
                    # epsilon после такта IN приближает непрерывную худшую фазу.
                    p = self.probe(read, phase - .999, counter=counter, stream=stream)
                    self.assertFalse(p.cpu.f & 1)
                    self.assertEqual(p.cpu.hl, 0xAC01)
                    self.assertEqual(p.word('TransferLeft'), 0)
                    self.assertEqual(p.model.status, 0)
                    self.assertEqual(p.model.byte_index if read else len(p.model.output), 1)
                    values.extend(p.model.drq_latencies[kind])
                maximum = math.ceil(max(values))
                self.assertEqual(maximum, expected, (kind, path, max(values)))
                rows[f'{kind}/{path}'] = {'max_t': maximum, 'sample_max_t': round(max(values), 3),
                                        'microseconds': round(maximum / 3.5, 6)}
            p = self.probe(read, 200, counter=0x0101)
            self.assertEqual([b - a for a, b in zip(p.transfer_polls, p.transfer_polls[1:])][:3],
                             [39, 39, 47])
            p = self.probe(read, 250, counter=0x0202, stream=True)
            self.assertEqual([b - a for a, b in zip(p.transfer_polls, p.transfer_polls[1:])][:6],
                             [25, 25, 25, 25, 35, 39])
        EVIDENCE['drq'] = {'cpu_hz': 3_500_000, 'tick_scale': 1, 'paths': rows,
                           'read_comment_difference_t': 1,
                           'write_budget_us': 23.5, 'read_budget_us': 27}

    def test_3500khz_long_idle_poll_negative_control(self):
        for read in (False, True):
            p = self.probe(read, 12, slow=True)
            self.assertEqual(p.model.status, 4)
            self.assertEqual(p.cpu.hl, 0xAC00)
        EVIDENCE.setdefault('negative_controls', {})['F4'] = 'real slow-poll instructions: Lost Data, zero bytes'

    def test_transfer_amount_detects_short_and_over_limit(self):
        for read in (False, True):
            p = self.probe(read, 1, extra=1)
            self.assertTrue(p.cpu.f & 1)
            self.assertEqual(p.cpu.a, 8 if read else 7)
            self.assertEqual(p.cpu.hl, 0xAC01)  # лишний DRQ уже не читает буфер
            p = self.probe(read, 1)
            p.poke('TransferLimit', 2, 2)
            p.call('TransferDone', hl=0xAC01)
            self.assertFalse(p.cpu.f & 1)
            self.assertEqual(p.word('TransferLeft'), 1)

    def test_3500khz_watchdog_ends_never_ready_transfer(self):
        for read in (False, True):
            p = self.probe(read, 100_000_000, counter=0)
            # Защита модели DRQ не должна завершать команду вместо сторожа CPU.
            self.assertTrue(p.cpu.f & 1)
            self.assertEqual(p.cpu.a, SYMS['ERR_TIMEOUT'])
            self.assertEqual(len(p.transfer_polls), 4 * (65536 + 256 + 1))
            self.assertEqual(p.cpu.alt_bc >> 8, 0)
            self.assertEqual(p.cpu.hl, 0xAC00)
            self.assertTrue(p.interrupts_enabled)
            self.assertFalse(p.model.busy or p.model.drq)
            self.assertGreater(p.elapsed / p.model.frequency, 2.9)
            self.assertLess(p.elapsed / p.model.frequency, 3)
            EVIDENCE.setdefault('watchdog_3500khz', {})['read' if read else 'write'] = {
                'polls': len(p.transfer_polls), 'seconds': round(p.elapsed / p.model.frequency, 6)}

    def test_3500khz_watchdog_ends_transfer_stalled_after_one_byte(self):
        for read in (False, True):
            p = self.probe(read, 1, extra=1, counter=0, stall_after_byte=True)
            self.assertTrue(p.cpu.f & 1)
            self.assertEqual(p.cpu.a, SYMS['ERR_TIMEOUT'])
            self.assertEqual(p.cpu.hl, 0xAC01)
            self.assertEqual(p.model.byte_index if read else len(p.model.output), 1)
            self.assertEqual(p.cpu.alt_bc >> 8, 0)
            self.assertTrue(p.interrupts_enabled)
            self.assertFalse(p.model.busy or p.model.drq)
            self.assertGreater(p.elapsed / p.model.frequency, 2.9)
            self.assertLess(p.elapsed / p.model.frequency, 3)
            EVIDENCE.setdefault('watchdog_after_byte_3500khz', {})['read' if read else 'write'] = {
                'polls': len(p.transfer_polls), 'seconds': round(p.elapsed / p.model.frequency, 6),
                'transferred': 1}
