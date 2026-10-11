"""Полная таблица плагинов: 32 заголовка, PHED=#0000 (переход через #FFFF).

Настоящий Z80 исполняет код WC из boot.payload.bin. Прежде перебор заголовков
сравнивал адрес с PHED через SBC (или старший байт PHED с #C2) и полную
таблицу считал пустой: меню F10 и меню просмотрщиков были пусты, заставка по
таймеру, меню F2/F4 и автозапуск #06 не находили ни одного плагина.
Сборка — Build/ или каталог из WC_TEST_BUILD (для проверки на прежней сборке).
"""
import os
from pathlib import Path
import re
import unittest

import z80

ROOT = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ.get('WC_TEST_BUILD', ROOT / 'Build'))
STOP, STACK = 0x5C80, 0x5D80
PHED, LOBU, AJT, PRWOW, GED = 0x7F18, 0xB000, 0x70C3, 0x792C, 0x699F
ENTRY, NYAA, ENV_CODE = 0x7F6B, 0x70A3, 0x7107


def symbols(name):
    return {m[1]: int(m[2], 16) for line in (BUILD / name).read_text().splitlines()
            if (m := re.match(r'^([^:]+):\s+EQU\s+0x([0-9A-Fa-f]+)$', line))}


W = symbols('boot.sym')


def word(buf, pos, value=None):
    if value is None:
        return int.from_bytes(bytes(buf[pos:pos + 2]), 'little')
    buf[pos:pos + 2] = (value & 0xFFFF).to_bytes(2, 'little')


class Stand:
    """Окно #C000 — страницы по порту #13AF; заглушки: AJT и PLGE запоминают вызов."""

    def __init__(self, types, overlay_state=1, universal=True, exts=None):
        self.cpu = z80.Z80Machine()
        self.cpu.set_memory_block(0x6011, (BUILD / 'boot.payload.bin').read_bytes())
        self.cpu.set_memory_block(0x5300, (BUILD / 'WMF_RUNTIME.bin').read_bytes())
        # Claude - 2026-10-10: с оверлеем FILEX AX_RUN сначала зовёт
        # FILEX_REQUIRED резидентного блока — ставим блоки, как установщик, и
        # OVERLAY_STATE (1 — FILEX поставил оверлей).
        self.ext = symbols('CORE32_EXT.sym') if (BUILD / 'CORE32_EXT.sym').exists() else {}
        if 'WDOS_EXT.OVERLAY_STATE' in self.ext:
            import runtime_image
            runtime_image.apply(self.cpu.memory, self.ext, (BUILD / 'CORE32_EXT.bin').read_bytes(),
                                boot=(BUILD / 'CORE32_EXT_BOOT.bin').read_bytes())
            self.cpu.memory[self.ext['WDOS_EXT.OVERLAY_STATE']] = overlay_state
        table = bytearray(0x4000)
        for i, kind in enumerate(types):
            h = bytearray(512)
            h[16:32] = b'WildCommanderMDL'
            h[32], h[34] = 0x10, 1
            h[165:197] = f'Plugin {i:02}'.encode().ljust(32, b' ')
            h[197] = kind
            h[204:228] = f'View {i:02}'.encode().ljust(24, b' ')   # подпись в меню просмотрщиков
            # Claude - 2026-10-11: в меню Shift+F3 — просмотрщик с +33 bit 1
            # (любой файл) или плагин, чей список держит расширение файла.
            if universal and kind in (0x04, 0x05, 0x15):
                h[33] = 2
            if exts and i in exts:
                h[204:228] = bytes(24)
                for n, ext in enumerate(exts[i]):
                    h[64 + 3 * n:67 + 3 * n] = ext
            table[i * 512:(i + 1) * 512] = h
        self.banks = {0x60: table}
        self.mapped = 0x60
        self.cpu.memory[0xC000:] = table
        self.cpu.memory[0x6003] = 0x60
        word(self.cpu.memory, PHED, (0xC000 + 512 * len(types)) & 0xFFFF)
        self.cpu.set_output_callback(self.out)
        self.cpu.set_input_callback(lambda port: 0xFF)
        self.cpu.ix, self.cpu.iy = 0x7EA0, 0x5C3A
        self.launched, self.plge = [], []

    def out(self, port, value):
        if port == 0x13AF:
            self.banks.setdefault(self.mapped, bytearray(0x4000))[:] = bytes(self.cpu.memory[0xC000:])
            self.cpu.memory[0xC000:] = self.banks.setdefault(value, bytearray(0x4000))
            self.mapped = value
            self.cpu.memory[0x6003] = value

    def ret(self):
        self.cpu.pc = word(self.cpu.memory, self.cpu.sp)
        self.cpu.sp = (self.cpu.sp + 2) & 0xFFFF

    def run(self, entry, stops=(), **regs):
        """До STOP или до адреса из stops; AJT/GED — заглушки с возвратом."""
        c = self.cpu
        c.pc, c.sp = entry, STACK
        word(c.memory, STACK, STOP)
        for name, value in regs.items():
            setattr(c, name, value)
        points = {STOP, AJT, GED, *stops}
        for p in points:
            c.set_breakpoint(p)
        try:
            for _ in range(2000):
                c.ticks_to_stop = 200000
                if not c.run() & 2:
                    continue
                if c.pc == AJT:
                    self.launched.append(bytes(c.memory[LOBU + 165:LOBU + 197]).decode('cp866').rstrip())
                    # Как настоящий плагин: в окне #C000 остаётся его страница
                    # (стенд unreal-ng: AX_RUN удалял заголовок в чужой памяти).
                    self.out(0x13AF, 0x61)
                    if len(self.launched) > 64:
                        raise AssertionError('плагины запускаются по кругу')
                    self.ret()
                elif c.pc == GED:
                    self.ret()
                else:
                    return c.pc
            raise AssertionError(f'Z80 timeout at {c.pc:04X}')
        finally:
            for p in points:
                c.clear_breakpoint(p)

    def table(self):
        self.out(0x13AF, 0x60)
        end = word(self.cpu.memory, PHED) or 0x10000
        page = self.cpu.memory
        return [(bytes(page[a + 165:a + 197]).decode('cp866').rstrip(), page[a + 197])
                for a in range(0xC000, end, 512)]


class FullTable(unittest.TestCase):
    def test_timer_plugin_in_the_last_slot_runs(self):
        s = Stand([0] * 31 + [2])
        self.assertEqual(s.run(W['WCVW.RATM']), STOP)
        self.assertEqual(s.launched, ['Plugin 31'])

    def test_f4_editor_in_the_last_slot_is_found(self):
        s = Stand([0] * 31 + [0x14])
        pc = s.run(W['WCFX.EDT'], stops=(W['WCVW.PLGE'],), bc=0x1315 + 1)
        self.assertEqual(pc, W['WCVW.PLGE'])
        self.assertEqual(s.cpu.de, 0xFE00 + 197)

    def test_viewer_menu_choice_in_the_last_slot_is_found(self):
        s = Stand([0] * 31 + [0x04])
        s.out(0x13AF, 0x60)
        pc = s.run(W['WCVW.ESLG'], stops=(W['WCVW.PLGE'],), b=1, de=0xC000 + 197 - 512)
        self.assertEqual(pc, W['WCVW.PLGE'])
        self.assertEqual(s.cpu.de, 0xFE00 + 197)

    def test_f10_menu_lists_all_32_plugins(self):
        s = Stand([3] * 32)
        self.assertEqual(s.run(W['WCVW.F11MENU'], stops=(PRWOW,)), PRWOW)
        names = [bytes(s.cpu.memory[LOBU + 32 * i:LOBU + 32 * i + 32]).decode('cp866').rstrip()
                 for i in range(32)]
        self.assertEqual(names, [f'Plugin {i:02}' for i in range(32)])
        self.assertEqual(s.cpu.memory[s.cpu.ix + 13], 32)

    def test_viewer_menu_lists_viewers_of_a_full_table(self):
        s = Stand([0x04 if i % 8 == 7 else 0 for i in range(32)])
        self.assertEqual(s.run(W['WCVW.EXTSEL'], stops=(PRWOW,)), PRWOW)
        names = [bytes(s.cpu.memory[LOBU + 24 * i:LOBU + 24 * i + 24]).decode('cp866').rstrip()
                 for i in range(4)]
        self.assertEqual(names, [f'View {i:02}' for i in (7, 15, 23, 31)])

    # Claude - 2026-10-11: меню Shift+F3 — по расширению файла и универсальные
    # просмотрщики. Прежде: все #04/#05/#15 для любого файла (Wild Player и
    # для .MID), плагин по расширению (GS Player, #00) — никогда.
    MENU = {3: 0x00, 7: 0x04, 15: 0x04, 23: 0x05, 31: 0x15}

    def menu_stand(self):
        types = [self.MENU.get(i, 3) for i in range(32)]
        s = Stand(types, universal=False, exts={3: [b'PT3', b'MID'], 23: [b'PT3']})
        for i in (15, 31):
            s.cpu.memory[0xC000 + 512 * i + 33] = 2          # любой файл
        s.cpu.memory[ENTRY + 8:ENTRY + 11] = b'MID'
        s.cpu.memory[ENV_CODE] = 0x55
        return s

    def test_viewer_menu_lists_extension_plugins_and_universal_viewers(self):
        s = self.menu_stand()
        self.assertEqual(s.run(W['WCVW.EXTSEL'], stops=(PRWOW,)), PRWOW)
        names = [bytes(s.cpu.memory[LOBU + 24 * i:LOBU + 24 * i + 24]).decode('cp866').rstrip()
                 for i in range(3)]
        self.assertEqual(names, ['Plugin 03', 'View 15', 'View 31'])

    def test_extension_plugin_chosen_from_menu_gets_its_format_code(self):
        s = self.menu_stand()
        s.out(0x13AF, 0x60)
        pc = s.run(W['WCVW.ESLG'], stops=(W['WCVW.PLGE'],), b=1, de=0xC000 + 197 - 512)
        self.assertEqual(pc, W['WCVW.PLGE'])
        self.assertEqual(s.cpu.de, 0xC000 + 512 * 3 + 197)
        self.assertEqual(s.cpu.memory[NYAA], 0x00)               # как по Enter
        self.assertEqual(s.cpu.memory[ENV_CODE], 1)              # MID — второй в списке

    def test_universal_viewer_chosen_from_menu_has_no_format_code(self):
        s = self.menu_stand()
        s.out(0x13AF, 0x60)
        pc = s.run(W['WCVW.ESLG'], stops=(W['WCVW.PLGE'],), b=2, de=0xC000 + 197 - 512)
        self.assertEqual(pc, W['WCVW.PLGE'])
        self.assertEqual(s.cpu.de, 0xC000 + 512 * 15 + 197)
        self.assertEqual(s.cpu.memory[NYAA], 0x04)
        self.assertEqual(s.cpu.memory[ENV_CODE], 0xFF)

    def test_viewer_listing_the_extension_opens_as_viewer(self):
        s = self.menu_stand()
        s.cpu.memory[ENTRY + 8:ENTRY + 11] = b'PT3'
        self.assertEqual(s.run(W['WCVW.EXTSEL'], stops=(PRWOW,)), PRWOW)
        names = [bytes(s.cpu.memory[LOBU + 24 * i:LOBU + 24 * i + 24]).decode('cp866').rstrip()
                 for i in range(4)]
        self.assertEqual(names, ['Plugin 03', 'View 15', 'Plugin 23', 'View 31'])
        s.out(0x13AF, 0x60)
        pc = s.run(W['WCVW.ESLG'], stops=(W['WCVW.PLGE'],), b=3, de=0xC000 + 197 - 512)
        self.assertEqual(pc, W['WCVW.PLGE'])
        self.assertEqual(s.cpu.de, 0xC000 + 512 * 23 + 197)
        self.assertEqual(s.cpu.memory[NYAA], 0x04)
        self.assertEqual(s.cpu.memory[ENV_CODE], 0)

    def test_autostart_runs_every_type_06_and_removes_it(self):
        types = [6 if i in (0, 5, 30, 31) else 3 for i in range(32)]
        s = Stand(types)
        self.assertEqual(s.run(W['AX_RUN']), STOP)
        self.assertEqual(s.launched, ['Plugin 00', 'Plugin 05', 'Plugin 30', 'Plugin 31'])
        self.assertEqual(s.table(), [(f'Plugin {i:02}', 3) for i in range(32) if types[i] != 6])
        self.assertEqual(word(s.cpu.memory, PHED), 0xC000 + 28 * 512)

    def test_autostart_in_a_partial_table_keeps_working(self):
        types = [6, 3, 6, 3]
        s = Stand(types)
        self.assertEqual(s.run(W['AX_RUN']), STOP)
        self.assertEqual(s.launched, ['Plugin 00', 'Plugin 02'])
        self.assertEqual(s.table(), [('Plugin 01', 3), ('Plugin 03', 3)])
        self.assertEqual(word(s.cpu.memory, PHED), 0xC400)

    # Claude - 2026-10-10 - begin
    def halt_lines(self, state):
        """AX_RUN при OVERLAY_STATE=state: строки, выведенные PRSRW, и где встал."""
        s = Stand([6, 3, 6], overlay_state=state)
        if 'WDOS_EXT.FILEX_HALT' not in s.ext:
            self.skipTest('сборка без оверлея FILEX')
        prsrw, halt = W['PRSRW'], s.ext['WDOS_EXT.FILEX_HALT']
        lines = []
        c = s.cpu
        c.pc, c.sp = W['AX_RUN'], STACK
        word(c.memory, STACK, STOP)
        # Точка на самой метке не годится: модель задевает байт за CALL
        # (FILEX_HALT стоит сразу за CALL PRIAT). Ждём HALT.
        for point in (STOP, AJT, prsrw):
            c.set_breakpoint(point)
        for _ in range(200):
            c.ticks_to_stop = 200000
            event = c.run()
            if c.halted:
                break
            if not event & 2:
                continue
            if c.pc == prsrw:
                text = bytes(c.memory[c.hl:c.hl + c.bc]).decode('cp866')
                lines.append((c.d, c.e, text))
                c.clear_breakpoint(prsrw)
                c.ticks_to_stop = 1
                c.run()
                c.set_breakpoint(prsrw)
                continue
            break
        stopped = halt if c.halted and halt <= c.pc <= halt + 2 else c.pc
        return s, stopped, lines

    def test_without_filex_ax_run_halts_with_message(self):
        # FILEX нет: окно с сообщением и останов до первого плагина #06.
        s, pc, lines = self.halt_lines(0)
        self.assertEqual(pc, s.ext['WDOS_EXT.FILEX_HALT'])
        self.assertEqual(s.launched, [])
        self.assertEqual([t for _, _, t in lines], ['Core extension plugin: FILEX.WMF',
                                                    'was not found in folder /WC.',
                                                    'Commander cannot work. HALT.'])
        for row, (y, x, text) in enumerate(lines, 1):
            self.assertEqual(y, row)
            self.assertEqual(2 * x + len(text), 44, f'строка {text!r} не по центру')

    def test_foreign_filex_ax_run_halts_with_message(self):
        # FILEX от другой сборки (штамп не совпал): своя вторая строка.
        s, pc, lines = self.halt_lines(2)
        self.assertEqual(pc, s.ext['WDOS_EXT.FILEX_HALT'])
        self.assertEqual(s.launched, [])
        self.assertEqual(lines[1][2], "in folder /WC doesn't match boot.$C.")
        self.assertEqual(2 * lines[1][1] + len(lines[1][2]), 44)
    # Claude - 2026-10-10 - end

    def test_partial_tables_still_end_at_phed(self):
        s = Stand([0, 2])
        s.run(W['WCVW.RATM'])
        self.assertEqual(s.launched, ['Plugin 01'])
        s = Stand([0, 0])
        s.run(W['WCVW.RATM'])
        self.assertEqual(s.launched, [])
        s = Stand([])
        self.assertEqual(s.run(W['WCVW.F11MENU'], stops=(PRWOW,)), STOP)


class ChainWithoutMenu(unittest.TestCase):
    """Claude - 2026-10-11: плеер просит следующий файл (A=2, NXTFL) или
    предыдущий (A=4, PRVFL); файл, который никто не открывает, — возврат в
    панель (GED). Прежде цепочка шла через F3 и на таком файле открывала меню
    Shift+F3 (EXTSEL). F3 с клавиатуры (VIEWK) меню возвращает."""

    F3ENTFL = 0x6017

    def walk(self, s, entry, stubs=(), stops=()):
        """До первой точки из stops; заглушки stubs возвращаются сразу."""
        c = s.cpu
        c.pc, c.sp = entry, STACK
        word(c.memory, STACK, STOP)
        points = {STOP, *stubs, *stops}
        for p in points:
            c.set_breakpoint(p)
        try:
            for _ in range(200):
                c.ticks_to_stop = 200000
                if not c.run() & 2:
                    continue
                if c.pc in stubs:
                    s.ret()
                else:
                    return c.pc
            raise AssertionError(f'Z80 timeout at {c.pc:04X}')
        finally:
            for p in points:
                c.clear_breakpoint(p)

    def target(self, s):
        return word(s.cpu.memory, W['WCVW.F3NONE'] + 1)

    def test_next_and_previous_file_turn_the_menu_off(self):
        for entry, move in (('WCVW.NXTFL', 'CRDN'), ('WCVW.PRVFL', 'CRUP')):
            with self.subTest(entry=entry):
                s = Stand([])
                stubs = (W[move], W['WCFX.STATUS'])
                self.assertEqual(self.walk(s, W[entry], stubs, (W['WCVW.VIEW'],)), W['WCVW.VIEW'])
                self.assertEqual(self.target(s), GED)

    def test_f3_key_turns_the_menu_back_on(self):
        s = Stand([])
        self.walk(s, W['WCVW.NXTFL'], (W['CRDN'], W['WCFX.STATUS']), (W['WCVW.VIEW'],))
        self.assertEqual(self.walk(s, W['WCVW.VIEWK'], (), (W['WCVW.VIEW'],)), W['WCVW.VIEW'])
        self.assertEqual(self.target(s), W['WCVW.EXTSEL'])

    def test_unknown_file_in_the_chain_returns_to_the_panel(self):
        s = Stand([])
        self.walk(s, W['WCVW.PRVFL'], (W['CRUP'], W['WCFX.STATUS']), (W['WCVW.VIEW'],))
        s.cpu.memory[self.F3ENTFL] = 1
        stops = (GED, W['WCVW.EXTSEL'])
        self.assertEqual(self.walk(s, W['WCVW.VIK'], (), stops), GED)
        self.walk(s, W['WCVW.VIEWK'], (), (W['WCVW.VIEW'],))
        self.assertEqual(self.walk(s, W['WCVW.VIK'], (), stops), W['WCVW.EXTSEL'])

    def test_f3_key_of_the_panel_calls_viewk(self):
        image = (BUILD / 'boot.payload.bin').read_bytes()
        call = lambda target: bytes([0xC4]) + target.to_bytes(2, 'little')    # CALL NZ,nn
        self.assertEqual(image.count(call(W['WCVW.VIEWK'])), 1)
        self.assertEqual(image.count(call(W['WCVW.VIEW'])), 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
