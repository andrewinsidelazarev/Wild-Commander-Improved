"""VIDEO_PL: звук MP3 из TGV — только с NeoGS и только если влезает в память.

Процессор ZX исполняет собранный Build/VIDEO_PL.WMF (пакет z80), WC API —
модель на точке входа #6006. GS — модель из тестов FTView (gsemu.py):
настоящее ПЗУ GS (1.04 или 1.05a) на своём Z80, порты #B3/#BB, время GS идёт
вместе со временем ZX. У обычного GS незанятый порт #0F читается как #FF;
у NeoGS там регистр конфигурации GSCFG0.

Проверяется путь LOADMP3 (заголовок TGV со звуковым блоком): найден ли NeoGS,
влезает ли MP3, как выглядит предупреждение и куда ушёл звуковой блок — в GS
или мимо него.
"""
from pathlib import Path
import os
import re
import sys
import unittest

import z80

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / 'source/plugins/ftview/tests'))
from gsemu import GS, find_rom  # noqa: E402

# Каталог сборки (VIDEO_PL.WMF и VIDEO_PL.sym); другой — для проверки старой.
BUILD = Path(os.environ.get('VIDEO_PL_BUILD', ROOT / 'Build'))
FRAME = 4 * 71680            # такты ZX на кадр при 14 МГц
WARNING = b'NeoGS not found. No sound.'
TOO_BIG = b'MP3 too large. No sound.'
KEY = b'Press any key...'
RED = 0b01110010             # красные буквы на сером фоне окна
RETURN = 0x7000              # адрес возврата из вызванной подпрограммы
INNER = range(1, 33)         # окна 34 колонки: рамка в колонках 0 и 33


def symbols():
    text = (BUILD / 'VIDEO_PL.sym').read_text()
    return {m[1]: int(m[2], 16) for m in re.finditer(r'^(\w+):\s+EQU\s+0x([0-9A-Fa-f]+)', text, re.M)}


class ClassicGS(GS):
    """Обычный GS: готов, когда ПЗУ после теста памяти начало опрашивать
    порты команды и статуса."""
    ready = False

    def _in(self, port):
        if port & 0xFF in (1, 4):
            self.ready = True
        return super()._in(port)


class NeoGS(ClassicGS):
    """GS с регистром конфигурации NeoGS: GSCFG0 (#0F) читается."""
    def _in(self, port):
        if port & 0xFF == 0x0F:
            return 0x10          # 12 МГц, остальные биты сброшены
        return super()._in(port)


class ScriptedNeoGS:
    """NeoGS без процессора: команды исполняются сразу. #11 читает GSCFG0,
    #23 отвечает заданным числом страниц — так проверяется предел страниц,
    которого не даёт ПЗУ модели."""
    def __init__(self, pages):
        self.pages, self.data_in, self.data_out = pages, 0, 0xFF

    def run(self, ticks):
        pass

    def zx_out(self, port, value):
        if port & 0xFF == 0xB3:
            self.data_in = value
        elif port & 0xFF == 0xBB and value == 0x11:
            self.data_out = 0x10 if self.data_in == 0x0F else 0xFF
        elif port & 0xFF == 0xBB and value == 0x23:
            self.data_out = self.pages

    def zx_in(self, port):
        return 0x7E if port & 0xFF == 0xBB else self.data_out


def booted(cls, rom, pages):
    gs = cls(rom, pages=pages)
    while not gs.ready:
        gs.run(12000)
    return gs


class Player:
    """Z80 плагина с моделью WC API и, по желанию, моделью GS."""

    def __init__(self, gs=None, sectors=8):
        self.s = symbols()
        wmf = (BUILD / 'VIDEO_PL.WMF').read_bytes()
        self.cpu = m = z80.Z80Machine()
        m.set_memory_block(0x8000, wmf[512:])
        # IM 1, обработчик — EI:RET: HALT плагина просыпается раз в кадр.
        m.set_memory_block(0x0038, b'\xFB\xC9')
        m._Z80State__int_mode[0] = 1
        m.set_input_callback(self.input)
        m.set_output_callback(self.output)
        m.set_breakpoint(0x6006)
        m.set_breakpoint(RETURN)
        self.gs, self.gs_ticks = gs, 0
        self.data = bytes((i * 7 + 3) & 255 for i in range(sectors * 512))
        self.pos = 0
        self.reset_log()

    def reset_log(self):
        self.calls, self.windows, self.commands = [], [], []
        self.prints = []        # (окно IX, строка, колонка, текст)
        self.colors = []        # (текст, цвет PRIAT)
        self.loaded = self.skipped = 0

    def input(self, port):
        if port & 0xFF in (0xBB, 0xB3):
            if not self.gs:
                return 0xFF
            if port & 0xFF == 0xBB:
                # Опрос ZX (~30 тактов 14 МГц) — 26 тактов GS.
                self.gs.run(26)
                self.gs_ticks += 26
            return self.gs.zx_in(port)
        return 0xFF

    def output(self, port, value):
        if port & 0xFF == 0xBB:
            self.commands.append(value)
        if port & 0xFF in (0xBB, 0xB3) and self.gs:
            self.gs.zx_out(port, value)

    def sync(self, zx_ticks):
        if self.gs:
            due = zx_ticks * 6 // 7 - self.gs_ticks
            if due > 0:
                self.gs.run(due)
        self.gs_ticks = 0

    def api(self):
        m = self.cpu
        f = m.a
        self.calls.append(f)
        if f == 1:                        # PRWOW: окно IX
            self.windows.append(m.ix)
        elif f == 3:                      # PRSRW: строка HL длиной BC в D/E
            self.prints.append((m.ix, m.d, m.e, bytes(m.memory[m.hl:m.hl + m.bc])))
        elif f == 4:                      # PRIAT: цвет в A'
            self.colors.append((self.prints[-1][3], bytes(m._Z80State__alt_af)[1]))
        elif f == 48:                     # LOAD512: B секторов в HL
            size = 512 * m.b
            m.set_memory_block(m.hl, self.data[self.pos:self.pos + size])
            self.pos += size
            self.loaded += m.b
        elif f == 61:                     # LOADNON: пропустить B секторов
            self.pos += 512 * m.b
            self.skipped += m.b
        m.a = 0                           # не конец файла
        m.pc = m.memory[m.sp] | m.memory[m.sp + 1] << 8
        m.sp = (m.sp + 2) & 0xFFFF

    def call(self, name, hl=0, ix=None, frames=3000):
        m = self.cpu
        m.sp = 0x5D00
        m.set_memory_block(m.sp, RETURN.to_bytes(2, 'little'))
        m.pc = self.s[name]
        m.hl = hl
        if ix is not None:
            m.ix = ix
        for _ in range(frames):
            left = FRAME
            while left:
                m.ticks_to_stop = left
                event = m.run()
                rest = int.from_bytes(bytes(m._StateBase__ticks_to_stop), 'little')
                self.sync(left - rest)
                left = rest
                if m.pc == RETURN:
                    return
                if event & 2 and m.pc == 0x6006:
                    self.api()
                    # Хвостовой переход в API (JP PRIAT) возвращает прямо
                    # на RETURN; с точки останова run() не остановился бы.
                    if m.pc == RETURN:
                        return
            m.on_handle_active_int()
        raise AssertionError(('Execution limit', name, hex(m.pc)))

    def gsena(self):
        return self.cpu.memory[self.s['GSENA']]

    def shown(self, text):
        return [p for p in self.prints if text in p[3]]


class Sound(unittest.TestCase):
    def assert_centered(self, printed):
        """Видимый текст внутри рамки, пробелов слева и справа поровну."""
        _, _, column, text = printed
        self.assertIn(column, INNER)
        self.assertIn(column + len(text) - 1, INNER)
        body = text.strip(b' ')
        left = column - INNER.start + (len(text) - len(text.lstrip(b' ')))
        right = INNER.stop - column - len(text) + (len(text) - len(text.rstrip(b' ')))
        self.assertEqual(left, right, (text, left, right))
        self.assertTrue(body)

    def assert_warned_and_skipped(self, p, sectors, text=WARNING):
        # Одно окно: сообщение в окне плеера на месте «Please Wait...»,
        # красным и по центру, строкой ниже — подсказка; отдельных окон нет.
        wnd = p.s['PLWND']
        (message,) = p.shown(text)
        self.assertEqual(message[:2], (wnd, 1))
        self.assert_centered(message)
        self.assertIn((message[3], RED), p.colors)
        (hint,) = p.shown(KEY)
        self.assertEqual(hint[:2], (wnd, 2))
        self.assert_centered(hint)
        self.assertNotIn(p.s['ERWND'], p.windows)
        # Клавиша: отпускание, нажатие, отпускание; затем окно рисуется
        # заново — с заголовком и «Please Wait...» — и идёт пропуск звука.
        after = p.calls[p.calls.index(46):]
        self.assertEqual(after[:5], [46, 47, 46, 2, 1])
        self.assertEqual(p.windows, [wnd])
        self.assertTrue(p.shown(b'Please Wait...'))
        self.assertEqual((p.skipped, p.loaded), (sectors, 0))
        self.assertNotIn(0x14, p.commands)    # код драйвера MP3 в GS не грузился
        self.assertNotIn(0x13, p.commands)

    def test_classic_gs_warns_and_skips_mp3(self):
        # Обычный GS 1 МБ с ПЗУ 1.04 и 1.05a: команда #11 читает порт #0F
        # как #FF. Раньше плеер принимал его за NeoGS и заливал MP3.
        for name in ('gs104.rom', 'gs105a.rom'):
            rom = find_rom(name)
            if not rom:
                self.skipTest(f'{name} not found; set GS_ROM_DIR')
            with self.subTest(rom=name):
                p = Player(booted(ClassicGS, rom, 32), sectors=40)
                p.call('LOADMP3', hl=40)
                self.assertIn(0x11, p.commands)
                self.assertEqual(p.gsena(), 1)
                self.assert_warned_and_skipped(p, 40)

    def test_neogs_gets_mp3_without_warning(self):
        rom = find_rom('gs105a.rom')
        if not rom:
            self.skipTest('gs105a.rom not found; set GS_ROM_DIR')
        gs = booted(NeoGS, rom, 16)
        p = Player(gs, sectors=8)
        p.call('LOADMP3', hl=8)
        self.assertEqual(p.gsena(), 0)
        self.assertFalse(p.shown(WARNING) or p.shown(TOO_BIG))
        self.assertIn(0x14, p.commands)
        self.assertIn(0x13, p.commands)
        self.assertEqual((p.loaded, p.skipped), (8, 0))
        # Драйвер MP3 в GS принял весь блок в страницу 2.
        self.assertEqual(gs.ring()[:len(p.data)], p.data)

    def test_without_gs_warns_and_skips_mp3(self):
        p = Player(None, sectors=16)
        p.call('LOADMP3', hl=16)
        self.assertEqual(p.gsena(), 1)
        self.assert_warned_and_skipped(p, 16)

    def test_page_budget_is_capped_by_driver_ring(self):
        # Драйвер играет по кольцу страниц 2..63: даже у NeoGS 4 МБ (#23 =
        # 126) под MP3 не больше 62 страниц; меньше трёх — не NeoGS.
        for pages, budget in ((126, 62), (62, 62), (40, 40), (3, 3)):
            with self.subTest(pages=pages):
                p = Player(ScriptedNeoGS(pages))
                p.call('GSFET')
                self.assertEqual(p.gsena(), 0)
                self.assertEqual(p.cpu.memory[p.s['GSPGS']], budget)
        p = Player(ScriptedNeoGS(2))
        p.call('GSFET')
        self.assertEqual(p.gsena(), 1)

    def test_mp3_over_budget_warns_and_skips(self):
        # 40 страниц по 64 сектора: на сектор больше — звук не грузится.
        p = Player(ScriptedNeoGS(40))
        p.call('LOADMP3', hl=40 * 64 + 1)
        self.assertEqual(p.gsena(), 0)
        self.assertFalse(p.shown(WARNING))
        self.assert_warned_and_skipped(p, 40 * 64 + 1, TOO_BIG)

    def test_mp3_at_budget_loads_one_over_is_skipped(self):
        # Настоящее ПЗУ GS с регистром NeoGS; предел занижен до одной
        # страницы, чтобы не гнать через модель 2 МБ.
        rom = find_rom('gs105a.rom')
        if not rom:
            self.skipTest('gs105a.rom not found; set GS_ROM_DIR')
        gs = booted(NeoGS, rom, 16)
        p = Player(gs, sectors=8 + 65 + 64)
        p.call('LOADMP3', hl=8)
        self.assertEqual(p.gsena(), 0)
        self.assertGreaterEqual(p.cpu.memory[p.s['GSPGS']], 3)
        p.cpu.memory[p.s['GSPGS']] = 1
        p.reset_log()
        p.call('LOADMP3', hl=65)
        self.assert_warned_and_skipped(p, 65, TOO_BIG)
        p.reset_log()
        p.call('LOADMP3', hl=64)
        self.assertFalse(p.shown(WARNING) or p.shown(TOO_BIG))
        self.assertIn(0x14, p.commands)
        self.assertEqual((p.loaded, p.skipped), (64, 0))
        start = (8 + 65) * 512
        self.assertEqual(gs.ring()[:64 * 512], p.data[start:start + 64 * 512])

    def test_player_window_texts_centered(self):
        # Заголовок и «Please Wait...» окна плеера (WNDPL).
        p = Player()
        p.call('WNDPL')
        self.assertEqual(p.windows, [p.s['PLWND']])
        self.assertEqual(len(p.prints), 2)
        for printed in p.prints:
            self.assert_centered(printed)

    def test_sd_ngs_error_centered(self):
        # Отказ с SD на NeoGS (DEVCHE): своё окно, текст по центру.
        p = Player()
        device = 0x5000
        p.cpu.memory[device + 29] = 2        # драйвер SDngs
        p.call('DEVCHE', ix=device)
        (printed,) = p.shown(b"CAN'T PLAY FROM SD(NGS)!!!")
        self.assertEqual(printed[:2], (p.s['ERWND'], 1))
        self.assert_centered(printed)


if __name__ == '__main__':
    unittest.main(verbosity=2)
