"""Машинные проверки SETUP.WMF: правка текста wc.ini без WC.

Всё состояние плагина — текст wc.ini в памяти: отметки и флаги плагинов
вписываются в него сразу, а список заново читает текст. Здесь настоящий Z80
исполняет подпрограммы собранного плагина на плоской памяти: разбор секций,
связывание записей списка со строками, пересборку секции [PLUGINS], строку
версии и переполнение буфера. Вызов API WC (#6006) в этих путях — ошибка;
только проверка курсора разрешает его: там API — пустышка с журналом вызовов.
"""
from __future__ import annotations

import re
import unittest
from collections import defaultdict
from pathlib import Path

import z80

ROOT = Path(__file__).resolve().parents[2]
WMF = ROOT / 'Build/SETUP.WMF'
SYMBOL_RE = re.compile(r'^([^:]+):\s+EQU\s+0x([0-9A-Fa-f]+)$')
STOP = 0xFF00
STACK = 0x7F00
WLD = 0x6006
VERSION = re.search(rb'DEFINE\s+WC_VERSION\s+"([^"]+)"',
                    (ROOT / 'source/VERSION.ASM').read_bytes()).group(1)


def alt_a(cpu) -> int:
    """A' — подкоманда API WC (PRIAT, YN): у z80 нет открытого свойства."""
    return cpu._Z80State__alt_af[1]


def symbols(path: Path) -> dict[str, int]:
    out = {}
    for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
        match = SYMBOL_RE.match(line.strip())
        if match:
            out[match.group(1)] = int(match.group(2), 16)
    return out


S = symbols(ROOT / 'Build/SETUP.sym')

INI = (VERSION + b'\r\r[SETUP]\rCPU_FREQ=2\rTextMode=1\r\r'
       b'[PLUGINS]\r'
       b'FILEX.WMF\r'
       b';MOUNTER.WMF -memory=128 -cpu=3,5\r'
       b'TXTEDIT.WMF -highlight=auto; auto,on,off\r'
       b'CLOCK.WMF;PLASMATW.WMF;SCRSAVER.WMF\r'
       b'\r[LPANEL]\rDRV=3\rINFO=1\r\r[RPANEL]\rDRV=5\rINFO=0\rCSORT=2\r')
NAMES = ('FILEX.WMF', 'MOUNTER.WMF', 'TXTEDIT.WMF', 'CLOCK.WMF', 'PLASMATW.WMF', 'NEWPLUG.WMF')


class Plugin:
    """Страница плагина в окне #8000 на плоской памяти Z80."""

    def __init__(self, text: bytes):
        self.cpu = z80.Z80Machine()
        self.cpu.memory[:] = bytes(0x10000)
        image = WMF.read_bytes()[512:]
        self.cpu.memory[0x8000:0x8000 + len(image)] = image
        self.set_text(text)
        self.poke(S['PCOUNT'], 0)
        self.poke16(S['EDITREC'], 0)
        self.call('TEXT_CHANGED')

    # --- память ---
    def poke(self, address, value):
        self.cpu.memory[address] = value & 0xFF

    def poke16(self, address, value):
        self.poke(address, value)
        self.poke(address + 1, value >> 8)

    def peek16(self, address):
        return self.cpu.memory[address] | self.cpu.memory[address + 1] << 8

    def text(self) -> bytes:
        end = self.peek16(S['INI_SIZE'])
        return bytes(self.cpu.memory[S['INIBUF']:end])

    def set_text(self, text: bytes):
        self.cpu.memory[S['INIBUF']:S['INIBUF'] + len(text) + 1] = text + b'\0'
        self.poke16(S['INI_SIZE'], S['INIBUF'] + len(text))

    def new_text(self) -> bytes:
        return bytes(self.cpu.memory[S['NEWBUF']:self.peek16(S['NEWPTR'])])

    # --- вызовы ---
    def call(self, name, **regs):
        cpu = self.cpu
        for reg, value in regs.items():
            setattr(cpu, reg, value)
        cpu.pc, cpu.sp = S[name], STACK
        cpu.memory[STACK:STACK + 2] = STOP.to_bytes(2, 'little')
        cpu.set_breakpoint(STOP)
        cpu.set_breakpoint(WLD)
        try:
            for _ in range(200):
                cpu.ticks_to_stop = 1_000_000
                if not cpu.run() & 2:
                    continue
                assert cpu.pc != WLD, f'{name} позвал API WC'
                assert cpu.sp == STACK + 2, hex(cpu.sp)
                return cpu.f & 1                # CF
        finally:
            cpu.clear_breakpoint(STOP)
            cpu.clear_breakpoint(WLD)
        raise AssertionError(f'{name} не вернулся')

    def call_api(self, name, **regs) -> list[tuple[int, int]]:
        """Как call, но API WC — пустышка: журнал (номер функции, IX+12 окна)."""
        cpu = self.cpu
        for reg, value in regs.items():
            setattr(cpu, reg, value)
        cpu.pc, cpu.sp = S[name], STACK
        cpu.memory[STACK:STACK + 2] = STOP.to_bytes(2, 'little')
        cpu.set_breakpoint(STOP)
        cpu.set_breakpoint(WLD)
        log = []
        try:
            for _ in range(2000):
                cpu.ticks_to_stop = 1_000_000
                if not cpu.run() & 2:
                    continue
                if cpu.pc == WLD:
                    log.append((cpu.a, cpu.memory[S['WND'] + 12]))
                    cpu.pc = self.peek16(cpu.sp)        # RET из пустышки
                    cpu.sp += 2
                    if cpu.pc != STOP:                  # JP WLD в хвосте вернёт прямо в STOP
                        continue
                assert cpu.sp == STACK + 2, hex(cpu.sp)
                return log
        finally:
            cpu.clear_breakpoint(STOP)
            cpu.clear_breakpoint(WLD)
        raise AssertionError(f'{name} не вернулся')

    def call_scripted(self, name, replies, stop_at=None, or_return=False, **regs) -> int | None:
        """Как call_api, но ответы API задаёт тест: replies[номер функции](cpu).
        Вызовы пишутся в api_calls как (номер, HL, DE). Выполнение кончается на
        адресе stop_at (или обычным возвратом, если он не задан); результат — HL.
        or_return — обычный возврат тоже конец, тогда результат None."""
        cpu = self.cpu
        for reg, value in regs.items():
            setattr(cpu, reg, value)
        cpu.pc, cpu.sp = S[name], STACK
        cpu.memory[STACK:STACK + 2] = STOP.to_bytes(2, 'little')
        self.api_calls = []
        stops = [STOP, WLD] + ([stop_at] if stop_at is not None else [])
        for address in stops:
            cpu.set_breakpoint(address)
        try:
            for _ in range(2000):
                cpu.ticks_to_stop = 1_000_000
                if not cpu.run() & 2:
                    continue
                if cpu.pc == stop_at or (stop_at is None and cpu.pc == STOP):
                    return cpu.hl
                if cpu.pc == STOP:
                    if or_return:
                        return None
                    raise AssertionError(f'{name} вернулся, не дойдя до точки остановки')
                if cpu.pc != WLD:
                    # Ложное событие пакета z80: точка останова сразу за JP
                    # срабатывает на выборке, а pc — уже адрес перехода.
                    continue
                self.api_calls.append((cpu.a, cpu.hl, cpu.de))
                replies[cpu.a](cpu)
                cpu.pc = self.peek16(cpu.sp)        # RET из пустышки
                cpu.sp += 2
                if cpu.pc == STOP:                  # JP WLD в хвосте вернул прямо в STOP
                    if stop_at is None:
                        return cpu.hl
                    if or_return:
                        return None
                    raise AssertionError(f'{name} вернулся, не дойдя до точки остановки')
        finally:
            for address in stops:
                cpu.clear_breakpoint(address)
        raise AssertionError(f'{name} не дошёл до точки остановки')

    # --- список плагинов ---
    def add_plugins(self, names):
        self.poke16(S['PLPTR'], S['PLIST'])
        self.poke(S['PCOUNT'], 0)
        scratch = 0xF000
        for name in names:
            self.cpu.memory[scratch:scratch + len(name) + 1] = name.encode() + b'\0'
            self.call('ADD_PLUGIN', hl=scratch)

    def record(self, name) -> int:
        for index in range(self.cpu.memory[S['PCOUNT']]):
            address = S['PLIST'] + index * S['PITEM']
            stored = bytes(self.cpu.memory[address + 1:address + 14]).split(b'\0')[0]
            if stored == name.encode():
                return address
        raise KeyError(name)

    def mark(self, name) -> int:
        return self.cpu.memory[self.record(name)] & 1

    def set_mark(self, name, value):
        address = self.record(name)
        self.cpu.memory[address] = self.cpu.memory[address] & 0xFE | value

    def line(self, name) -> bytes:
        start = self.peek16(self.record(name) + S['PLINE'])
        if not start:
            return b''
        return bytes(self.cpu.memory[start:start + 80]).split(b'\r')[0]

    def flags(self, name) -> bytes:
        start = self.peek16(self.record(name) + S['PFLAGS'])
        if not start:
            return b''
        return bytes(self.cpu.memory[start:start + 80]).split(b'\r')[0].split(b';')[0]

    def edit(self, name, flags: bytes):
        self.poke16(S['EDITREC'], self.record(name))
        self.cpu.memory[S['EDITBUF']:S['EDITBUF'] + len(flags)] = flags
        self.poke(S['EDITLEN'], len(flags))

    def rebuild(self) -> bytes:
        """Как APPLY без перерисовки: новый текст — на место прежнего."""
        assert not self.call('BUILD_NEW_INI'), 'текст не поместился'
        self.call('COPY_NEW')
        return self.text()


def plugin_lines(text: bytes) -> list[bytes]:
    return text.split(b'[PLUGINS]\r', 1)[1].split(b'[', 1)[0].split(b'\r')


class Linking(unittest.TestCase):
    """Запись списка видит свою строку — включённую или выключенную «;»."""

    def setUp(self):
        self.plugin = Plugin(INI)
        self.plugin.add_plugins(NAMES)

    def test_marks_follow_text(self):
        p = self.plugin
        self.assertEqual([p.mark(n) for n in NAMES], [1, 0, 1, 1, 0, 0])

    def test_disabled_line_keeps_its_flags(self):
        p = self.plugin
        self.assertEqual(p.line('MOUNTER.WMF'), b';MOUNTER.WMF -memory=128 -cpu=3,5')
        self.assertEqual(p.flags('MOUNTER.WMF'), b' -memory=128 -cpu=3,5')

    def test_name_only_at_line_start(self):
        # PLASMATW стоит в строке CLOCK после «;» — это подсказка, не строка плагина.
        p = self.plugin
        self.assertEqual(p.line('PLASMATW.WMF'), b'')
        self.assertEqual(p.line('CLOCK.WMF'), b'CLOCK.WMF;PLASMATW.WMF;SCRSAVER.WMF')
        self.assertEqual(p.flags('CLOCK.WMF'), b'')

    def test_unchanged_state_rebuilds_same_text(self):
        self.assertEqual(self.plugin.rebuild(), INI)


class Rebuild(unittest.TestCase):
    """Отметки и флаги переходят в текст, остальное остаётся байт в байт."""

    def setUp(self):
        self.plugin = Plugin(INI)
        self.plugin.add_plugins(NAMES)

    def test_toggles_comment_and_uncomment_lines(self):
        p = self.plugin
        p.set_mark('MOUNTER.WMF', 1)
        p.set_mark('CLOCK.WMF', 0)
        text = p.rebuild()
        self.assertIn(b'\rMOUNTER.WMF -memory=128 -cpu=3,5\r', text)
        self.assertIn(b'\r;CLOCK.WMF;PLASMATW.WMF;SCRSAVER.WMF\r', text)
        self.assertEqual([p.mark(n) for n in NAMES], [1, 1, 1, 0, 0, 0])

    def test_new_plugin_goes_after_last_line_not_after_blank(self):
        p = self.plugin
        p.set_mark('NEWPLUG.WMF', 1)
        text = p.rebuild()
        self.assertIn(b'CLOCK.WMF;PLASMATW.WMF;SCRSAVER.WMF\rNEWPLUG.WMF\r\r[LPANEL]', text)
        self.assertEqual(p.mark('NEWPLUG.WMF'), 1)
        self.assertEqual(p.line('NEWPLUG.WMF'), b'NEWPLUG.WMF')

    def test_edited_flags_keep_hint_after_semicolon(self):
        p = self.plugin
        p.edit('TXTEDIT.WMF', b'-highlight=on -x')
        text = p.rebuild()
        self.assertIn(b'\rTXTEDIT.WMF -highlight=on -x; auto,on,off\r', text)
        self.assertEqual(p.peek16(S['EDITREC']), 0, 'правка уже в тексте')

    def test_flags_can_be_cleared(self):
        p = self.plugin
        p.edit('TXTEDIT.WMF', b'')
        self.assertIn(b'\rTXTEDIT.WMF; auto,on,off\r', p.rebuild())

    def test_flags_of_disabled_plugin_stay_disabled(self):
        p = self.plugin
        p.edit('MOUNTER.WMF', b'-memory=512')
        self.assertIn(b'\r;MOUNTER.WMF -memory=512\r', p.rebuild())
        self.assertEqual(p.mark('MOUNTER.WMF'), 0)

    def test_flags_of_plugin_without_line_add_disabled_line(self):
        p = self.plugin
        p.edit('PLASMATW.WMF', b'-p')
        text = p.rebuild()
        self.assertIn(b'SCRSAVER.WMF\r;PLASMATW.WMF -p\r\r[LPANEL]', text)
        self.assertEqual(p.line('PLASMATW.WMF'), b';PLASMATW.WMF -p')
        self.assertEqual(p.mark('PLASMATW.WMF'), 0)

    def test_other_sections_untouched(self):
        p = self.plugin
        p.set_mark('NEWPLUG.WMF', 1)
        p.set_mark('FILEX.WMF', 0)
        text = p.rebuild()
        self.assertEqual(text.split(b'[PLUGINS]')[0], INI.split(b'[PLUGINS]')[0])
        self.assertEqual(text.split(b'[LPANEL]')[1], INI.split(b'[LPANEL]')[1])

    def test_missing_section_is_appended(self):
        p = Plugin(VERSION + b'\r\r[SETUP]\rCPU_FREQ=2\r')
        p.add_plugins(('FILEX.WMF',))
        p.set_mark('FILEX.WMF', 1)
        self.assertEqual(p.rebuild(),
                         VERSION + b'\r\r[SETUP]\rCPU_FREQ=2\r\r[PLUGINS]\rFILEX.WMF\r')
        self.assertEqual(p.mark('FILEX.WMF'), 1)

    def test_overflow_leaves_text_and_buffers_alone(self):
        capacity = S['NEWBUF'] - S['INIBUF'] - 1    # текст и ноль за ним
        filler = b';' + b'x' * (capacity - 4 - len(INI)) + b'\r'
        big = INI.replace(b'[LPANEL]', filler + b'[LPANEL]')
        self.assertEqual(len(big), capacity - 2)
        p = Plugin(big)
        p.add_plugins(NAMES)
        p.set_mark('NEWPLUG.WMF', 1)                # «\rNEWPLUG.WMF» — 12 байт
        records = bytes(p.cpu.memory[S['PLIST']:S['PLIST'] + len(NAMES) * S['PITEM']])
        guard = S['NEWEND'] - 1                     # последний байт NEWBUF — под ноль
        p.cpu.memory[guard] = 0xAA
        self.assertTrue(p.call('BUILD_NEW_INI'), 'переполнение не замечено')
        self.assertLessEqual(p.peek16(S['NEWPTR']), guard)
        self.assertEqual(p.cpu.memory[guard], 0xAA, 'записан байт за пределом')
        self.assertEqual(bytes(p.cpu.memory[S['PLIST']:S['PLIST'] + len(records)]), records)
        self.assertEqual(p.text(), big, 'прежний текст должен остаться')


class Settings(unittest.TestCase):
    """Параметры ищутся в своих секциях, цифра правится на месте."""

    def value(self, plugin, index):
        return plugin.cpu.memory[S['VALUES'] + index]

    def place(self, plugin, index):
        return plugin.peek16(S['PLACES'] + 2 * index)

    def test_panel_keys_are_scoped_by_section(self):
        p = Plugin(INI)
        # 0 CPU, 3 TextMode, 6 левый DRV, 9 правый DRV, 10 правый INFO.
        self.assertEqual(self.value(p, 0), 2)
        self.assertEqual(self.value(p, 3), 1)
        self.assertEqual(self.value(p, 6), 3)
        self.assertEqual(self.value(p, 9), 5)
        self.assertEqual(self.value(p, 10), 0)

    def test_key_missing_in_own_section_is_not_taken_from_next(self):
        p = Plugin(INI)
        # В [LPANEL] нет CSORT= — он есть только в [RPANEL].
        self.assertEqual(self.place(p, 8), 0)
        self.assertNotEqual(self.place(p, 11), 0)

    def test_key_missing_in_setup_is_absent(self):
        p = Plugin(INI)
        self.assertEqual(self.place(p, 1), 0)       # SavePaths= в тексте нет


class Version(unittest.TestCase):
    """Первая строка wc.ini — версия WC: ядро узнаёт по ней свой файл."""

    def test_old_version_line_is_replaced(self):
        p = Plugin(b'Wild Commander v1.1\r\r[SETUP]\rCPU_FREQ=2\r')
        self.assertFalse(p.call('STAMP_VERSION'))
        self.assertEqual(p.text(), VERSION + b'\r\r[SETUP]\rCPU_FREQ=2\r')

    def test_missing_version_line_is_inserted(self):
        p = Plugin(b'[SETUP]\rCPU_FREQ=2\r')
        self.assertFalse(p.call('STAMP_VERSION'))
        self.assertEqual(p.text(), VERSION + b'\r\r[SETUP]\rCPU_FREQ=2\r')

    def test_template_starts_with_version_and_lists_core_plugins(self):
        image = WMF.read_bytes()[512:]
        start = S['DEFAULT_INI'] - 0x8000
        template = image[start:start + S['DEFAULT_SIZE']]
        self.assertTrue(template.startswith(VERSION + b'\r\r[SETUP]\r'))
        self.assertEqual([line for line in plugin_lines(template) if line],
                         [b'FILEX.WMF', b'PLM.WMF', b'SETUP.WMF'])
        self.assertEqual(template.count(b'INFO=1'), 2, 'строка информации включена в обеих панелях')


class Cursor(unittest.TestCase):
    """Строку курсора (IX+12) плагин меняет, только погасив полосу (API 7),
    и сразу зажигает её на новой строке (API 6).

    API 6 зажигает полосу в текущей строке и помнит прежний цвет строки; без
    API 7 каждая пройденная строка оставалась подсвеченной. Зажигать новую
    полосу только в цикле после HALT нельзя: при автоповторе шаг идёт каждый
    кадр, и полоса, горевшая лишь миг до следующего шага, не держалась.
    """

    CURSOR, CURSER, PRSRW, PRIAT = 6, 7, 3, 4

    def plugin(self, row, shown, count):
        p = Plugin(INI)
        p.poke(S['SCREEN_NO'], 0)
        p.poke(S['COUNT'], count)
        p.poke(S['SHOWN'], shown)
        p.poke(S['TOP'], 0)
        p.poke(S['WND'] + 12, row)
        p.poke(S['WND'] + 13, shown)
        return p

    def test_step_moves_the_bar_at_once(self):
        p = self.plugin(row=3, shown=12, count=12)
        self.assertEqual(p.call_api('DOWN_BY', b=1), [(self.CURSER, 3), (self.CURSOR, 4)])
        self.assertEqual(p.call_api('UP_BY', b=2), [(self.CURSER, 4), (self.CURSOR, 2)])

    def test_scroll_hides_the_bar_before_repaint(self):
        p = self.plugin(row=5, shown=5, count=12)
        log = p.call_api('DOWN_BY', b=1)
        self.assertEqual(log[0], (self.CURSER, 5))
        self.assertEqual([call for call, _ in log[1:3]], [self.PRSRW, self.PRIAT], 'заголовок')
        # Строки — с цветом окна, кроме строки курсора: её цвет ведут API 6/7.
        self.assertEqual([call for call, _ in log[3:12]], [self.PRSRW, self.PRIAT] * 4 + [self.PRSRW],
                         'строки перепечатаны вместе с цветом окна')
        self.assertEqual([call for call, _ in log[12:17]], [self.PRSRW] * 5, 'полоса прокрутки')
        self.assertEqual(log[17:], [(self.CURSOR, 5)], 'полоса курсора — сразу, после перерисовки')
        self.assertEqual(p.cpu.memory[S['TOP']], 1)

    def test_change_keeps_the_bar_lit(self):
        # Пробел перерисовывает список при горящей полосе: строку курсора
        # PAINT не перекрашивает, иначе полоса гасла бы до следующего кадра.
        p = self.plugin(row=4, shown=12, count=12)
        rows = []
        p.api_calls = []
        p.call_scripted('CHANGE', defaultdict(lambda: noop, {
            self.PRSRW: lambda cpu: rows.append(cpu.d),
            self.PRIAT: lambda cpu: rows.append(('цвет', rows[-1]))}))
        colored = {row for item in rows if isinstance(item, tuple) for row in item[1:]}
        self.assertEqual(colored, set(range(0, 13)) - {4})


class ScrollBar(unittest.TestCase):
    """Полоса прокрутки на правой рамке окна: дорожка и ползунок, как в F10."""

    def bar(self, top, shown, count):
        p = Plugin(INI)
        p.poke(S['COUNT'], count)
        p.poke(S['SHOWN'], shown)
        p.poke(S['TOP'], top)
        cells = []
        p.api_calls = []

        def prsrw(cpu):
            if cpu.bc == 1:                             # символ полосы
                cells.append((cpu.d, cpu.e, cpu.memory[cpu.hl]))
        p.call_scripted('BAR', {3: prsrw})
        return cells

    def test_no_bar_when_the_list_fits(self):
        self.assertEqual(self.bar(top=0, shown=12, count=12), [])

    def test_bar_on_the_right_border(self):
        cells = self.bar(top=0, shown=5, count=12)
        self.assertEqual([(d, e) for d, e, _ in cells], [(row, S['LINEW'] + 1) for row in range(1, 6)])

    def test_knob_walks_the_whole_track(self):
        def knob(top):
            return [c for _, _, c in self.bar(top=top, shown=5, count=12)].index(S['BAR_KNOB'])
        self.assertEqual(knob(0), 0, 'начало списка — вверху')
        self.assertEqual(knob(7), 4, 'конец списка — внизу')
        self.assertEqual(knob(3), 1)


CR = bytes([13])


class Groups(unittest.TestCase):
    """Группа из заголовка: просмотрщик со своими расширениями — «file», даже
    когда тип #03 ставит его и в меню F10; заставка (#02) — своя группа."""

    def group(self, name, kind, first_ext=0):
        p = Plugin(INI)
        p.add_plugins((name,))
        record = p.record(name)
        p.poke(record + S['PTYPE'], kind)
        p.poke(S['SECTOR'] + 64, first_ext)     # первое расширение заголовка
        p.poke16(S['TITLEPTR'], record)
        p.call('SET_GROUP')
        return p.cpu.memory[record + S['PGROUP']]

    def test_group_by_header(self):
        cases = (('FTVIEW.WMF', 0x03, ord('J'), 'GROUP_FILE'),
                 ('MOUNTER.WMF', 0x03, ord('T'), 'GROUP_FILE'),
                 ('TRDUMP.WMF', 0x05, ord('T'), 'GROUP_FILE'),
                 ('TXTEDIT.WMF', 0x15, 0, 'GROUP_FILE'),
                 ('BMPV.WMF', 0x00, ord('B'), 'GROUP_FILE'),
                 ('CHKDSK.WMF', 0x03, 0, 'GROUP_MENU'),
                 ('FILE_CR.WMF', 0x11, 0, 'GROUP_MENU'),
                 ('CLOCK.WMF', 0x02, 0, 'GROUP_SAVER'),
                 ('NEWAUTO.WMF', 0x06, 0, 'GROUP_AUTO'),
                 ('FILEX.WMF', 0x06, 0, 'GROUP_CORE'),
                 ('PLM.WMF', 0x06, 0, 'GROUP_CORE'))
        for name, kind, ext, group in cases:
            with self.subTest(name=name):
                self.assertEqual(self.group(name, kind, ext), S[group])


class Savers(unittest.TestCase):
    """Заставку WC держит одну: включённая заставка выключает остальные."""

    SAVERS = ('CLOCK.WMF', 'PLASMATW.WMF', 'SCRSAVER.WMF')
    ALL = NAMES + ('SCRSAVER.WMF',)

    def setUp(self):
        self.plugin = p = Plugin(INI)
        p.add_plugins(self.ALL)
        for name in self.ALL:
            group = 'GROUP_SAVER' if name in self.SAVERS else 'GROUP_FILE'
            p.poke(p.record(name) + S['PGROUP'], S[group])
        p.poke(S['SHOWN'], 0)                   # без перерисовки окна
        p.poke(S['TOP'], 0)

    def toggle(self, name):
        p = self.plugin
        p.poke(S['WND'] + 12, (p.record(name) - S['PLIST']) // S['PITEM'] + 1)
        p.call_api('TOGGLE_PLUGIN')
        return p.text()

    def marks(self):
        return [self.plugin.mark(name) for name in self.SAVERS]

    def test_enabling_a_saver_disables_the_others(self):
        text = self.toggle('PLASMATW.WMF')
        self.assertEqual(self.marks(), [0, 1, 0])
        self.assertIn(CR + b';CLOCK.WMF;PLASMATW.WMF;SCRSAVER.WMF' + CR + b'PLASMATW.WMF' + CR, text)
        text = self.toggle('CLOCK.WMF')
        self.assertEqual(self.marks(), [1, 0, 0])
        self.assertIn(CR + b'CLOCK.WMF;PLASMATW.WMF;SCRSAVER.WMF' + CR + b';PLASMATW.WMF' + CR, text)

    def test_the_only_saver_can_be_switched_off(self):
        self.toggle('CLOCK.WMF')
        self.assertEqual(self.marks(), [0, 0, 0])

    def test_other_plugins_are_not_exclusive(self):
        self.toggle('MOUNTER.WMF')
        p = self.plugin
        self.assertEqual((p.mark('MOUNTER.WMF'), p.mark('TXTEDIT.WMF')), (1, 1))
        self.assertEqual(self.marks(), [1, 0, 0])

    def test_rows_show_group_and_radio_mark(self):
        p = self.plugin
        rows = {}
        for name in ('CLOCK.WMF', 'PLASMATW.WMF', 'MOUNTER.WMF'):
            record = p.record(name)
            # у MaxiClock и Plasma название в заголовке начинается с пробела
            title = b' ' + name.split('.')[0].encode()
            p.cpu.memory[record + S['PTITLE']:record + S['PTITLE'] + len(title) + 1] = title + bytes(1)
            p.cpu.memory[S['ROWBUF']:S['ROWBUF'] + S['LINEW']] = b' ' * S['LINEW']
            p.call('PLUGIN_ROW', a=(record - S['PLIST']) // S['PITEM'])
            rows[name] = bytes(p.cpu.memory[S['ROWBUF']:S['ROWBUF'] + 20]).rstrip()
        self.assertEqual(rows['CLOCK.WMF'], b'(*) saver CLOCK')
        self.assertEqual(rows['PLASMATW.WMF'], b'( ) saver PLASMATW')
        self.assertEqual(rows['MOUNTER.WMF'], b'[ ] file  MOUNTER')


class SaveResult(unittest.TestCase):
    """«wc.ini saved» — только если новый файл встал на место старого, а при
    отказе прежний wc.ini не теряется: он сначала откладывается в wc.old."""

    Z, C = 0x40, 0x01
    RENAME, DELFL = 74, 75

    def save(self, renames, state=0, files=None, read_errors=(), modified=0, quiet=0, text=INI):
        """files — что лежит в каталоге WC до сохранения: имя → (размер, первый
        кластер) ('ini', 'new', 'old'); по умолчанию — один wc.ini (если
        state=0). Заглушки API ведут этот список: MKFILE заводит wc.new на
        новом кластере, DELFL убирает, RENAME при удаче переносит, FENTRY
        отвечает по нему (размер в DE:HL), TENTRY кладёт в DE запись последнего
        найденного (кластер +20/+26, размер +28). read_errors — имена, чей
        FENTRY по разу не читает каталог (Z и CF=1, как ядро). modified и
        quiet — признак правки и запись по вопросу при выходе; без сообщения
        результат None. Плагин остаётся в self.plugin."""
        self.plugin = p = Plugin(text)
        p.poke(S['INI_STATE'], state)
        p.poke(S['MODIFIED'], modified)
        p.poke(S['QUIET'], quiet)
        results = iter(renames)
        Z, C = self.Z, self.C
        names = {S['INI_QUERY']: 'ini', S['INI_QUERY'] + 1: 'ini', S['NEW_QUERY']: 'new',
                 S['OLD_QUERY']: 'old', S['OLD_QUERY'] + 1: 'old'}
        disk = dict(files) if files is not None else ({'ini': (1, 5)} if state == 0 else {})
        failing = list(read_errors)
        found = []

        def ok(cpu):
            cpu.f = (cpu.f | Z) & ~C

        def mkfile(cpu):
            disk['new'] = (p.peek16(S['NEW_SIZE']), 100)
            ok(cpu)

        def delfl(cpu):
            disk.pop(names[cpu.hl], None)
            ok(cpu)

        def fentry(cpu):
            name = names[cpu.hl]
            if name in failing:
                failing.remove(name)
                cpu.f |= Z | C
                return
            if name not in disk:
                cpu.f = (cpu.f | Z) & ~C
                return
            found.append(name)
            size = disk[name][0]
            cpu.f &= ~(Z | C)
            cpu.hl, cpu.de = size & 0xFFFF, size >> 16

        def tentry(cpu):
            size, cluster = disk[found[-1]]
            entry = bytearray(32)
            entry[20:22] = (cluster >> 16).to_bytes(2, 'little')
            entry[26:28] = (cluster & 0xFFFF).to_bytes(2, 'little')
            entry[28:32] = size.to_bytes(4, 'little')
            p.cpu.memory[cpu.de:cpu.de + 32] = bytes(entry)
            cpu.de = cpu.de + 32 & 0xFFFF

        def rename(cpu):
            result = next(results)
            if result is True:
                source, target = names[cpu.hl], names[cpu.de]
                if source in disk:
                    disk[target] = disk.pop(source)
                cpu.a = 1                                # RENAME ядра: NZ, A=1
                cpu.f &= ~(Z | C)
            else:
                # False — отказ без записи (A=0), 'lost' — исход неизвестен
                # (A=#FF: на цепочке могут остаться обе записи)
                cpu.a = 0xFF if result == 'lost' else 0
                cpu.f = (cpu.f | Z) & ~C

        self.title = []

        def title_text(cpu):
            self.title.append(bytes(p.cpu.memory[cpu.hl:cpu.hl + cpu.bc]))

        def title_color(cpu):
            self.title.append(alt_a(cpu))

        replies = {57: ok, 75: delfl, 72: mkfile, 59: fentry, 51: tentry, 62: ok, 49: ok,
                   74: rename, 3: title_text, 4: title_color}
        shown = p.call_scripted('SAVE_INI', replies, S['SHOW_MESSAGE'], or_return=bool(quiet))
        done = [(names[hl], names[de]) for call, hl, de in p.api_calls if call == self.RENAME]
        deleted = [names[hl] for call, hl, de in p.api_calls if call == self.DELFL]
        return shown, done, deleted

    def test_saved_after_old_is_set_aside_and_new_takes_its_name(self):
        shown, renames, deleted = self.save([True, True])
        self.assertEqual(shown, S['MSG_SAVED'])
        self.assertEqual(renames, [('ini', 'old'), ('new', 'ini')])
        self.assertEqual(deleted, ['new', 'old', 'old'])

    def test_old_that_cannot_be_set_aside_stays_and_nothing_is_saved(self):
        shown, renames, _ = self.save([False])
        self.assertEqual(shown, S['MSG_FAILED'])
        self.assertEqual(renames, [('ini', 'old')], 'дальше не трогаем: прежний wc.ini цел')

    def test_failed_final_rename_brings_the_old_file_back(self):
        # Раньше старый файл удалялся до переименования, и при отказе wc.ini не оставалось.
        shown, renames, deleted = self.save([True, False, True])
        self.assertEqual(shown, S['MSG_FAILED'])
        self.assertEqual(renames, [('ini', 'old'), ('new', 'ini'), ('old', 'ini')])
        self.assertEqual(deleted, ['new', 'old'], 'отложенный прежний файл не удаляется')

    def test_first_save_without_old_file(self):
        shown, renames, _ = self.save([False, True], state=1)
        self.assertEqual(shown, S['MSG_SAVED'])
        self.assertEqual(renames, [('ini', 'old'), ('new', 'ini')])

    def test_unread_or_too_long_file_is_never_written(self):
        for state in (2, 3):
            with self.subTest(состояние=state):
                shown, renames, deleted = self.save([], state=state)
                self.assertEqual(shown, S['MSG_FAILED'])
                self.assertEqual((renames, deleted), ([], []))

    # Аудит Codex, R12-1 (2026-09-26): после двойного сбоя RENAME хвост прошлой
    # попытки (wc.new или wc.old) мог остаться второй записью на цепочке
    # wc.ini, и DELFL хвоста освобождал данные wc.ini. Такой хвост начинается с
    # того же кластера, что wc.ini: его не удаляем, сохранение отказывает.

    def test_leftover_new_on_ini_chain_is_not_deleted(self):
        shown, renames, deleted = self.save([], files={'ini': (300, 5), 'new': (300, 5)})
        self.assertEqual(shown, S['MSG_CHECK'])
        self.assertEqual((renames, deleted), ([], []), 'хвост с цепочкой wc.ini удалён')

    def test_leftover_old_on_ini_chain_is_not_deleted(self):
        shown, renames, deleted = self.save([], files={'ini': (300, 5), 'old': (300, 5)})
        self.assertEqual(shown, S['MSG_CHECK'])
        self.assertEqual(renames, [])
        self.assertNotIn('old', deleted, 'хвост с цепочкой wc.ini удалён')

    def test_leftover_on_ini_chain_with_other_size_is_not_deleted(self):
        # R13-2: после сбоя RENAME обычный APPEND к wc.ini меняет размер
        # только его записи — размеры разные, а цепочка общая.
        for tail in ('new', 'old'):
            with self.subTest(tail):
                shown, _, deleted = self.save([], files={'ini': (301, 5), tail: (300, 5)})
                self.assertEqual(shown, S['MSG_CHECK'])
                self.assertNotIn(tail, deleted)

    def test_cluster_high_word_counts(self):
        shown, _, deleted = self.save([], files={'ini': (300, 0x10005), 'new': (300, 0x10005)})
        self.assertEqual(shown, S['MSG_CHECK'])
        shown, _, deleted = self.save([True, True],
                                      files={'ini': (300, 0x10005), 'new': (300, 0x20005)})
        self.assertEqual(shown, S['MSG_SAVED'])

    def test_leftover_on_own_chain_is_deleted(self):
        # И того же размера: прежняя проверка по размеру отказывала здесь зря.
        shown, renames, deleted = self.save([True, True], files={
            'ini': (300, 5), 'new': (300, 8), 'old': (9, 9)})
        self.assertEqual(shown, S['MSG_SAVED'])
        self.assertEqual(deleted, ['new', 'old', 'old'])

    def test_read_error_while_checking_refuses(self):
        # R13-1: FENTRY при ошибке чтения каталога тоже даёт Z (с CF=1) — это
        # не «хвоста нет»: общую цепочку не исключить.
        for failing, files in ((['new'], {'ini': (300, 5), 'new': (300, 8)}),
                               (['ini'], {'ini': (300, 5), 'new': (300, 8)}),
                               (['old'], {'ini': (300, 5), 'old': (300, 8)})):
            with self.subTest(failing):
                shown, renames, deleted = self.save([True, True], files=files,
                                                    read_errors=failing)
                self.assertEqual(shown, S['MSG_CHECK'])
                self.assertEqual(renames, [])
                self.assertNotIn(failing[0] if failing[0] != 'ini' else 'new', deleted)

    def test_unknown_rename_outcome_asks_to_check_the_disk(self):
        # R14-1: A=#FF — вторая запись на цепочке может потом получить другое
        # имя, и SETUP её не найдёт: том проверить сразу, не «NOT saved».
        for renames, expected in ((['lost'], [('ini', 'old')]),
                                  ([True, 'lost', False], [('ini', 'old'), ('new', 'ini'),
                                                           ('old', 'ini')]),
                                  ([True, False, 'lost'], [('ini', 'old'), ('new', 'ini'),
                                                           ('old', 'ini')]),
                                  ([True, 'lost', True], [('ini', 'old'), ('new', 'ini'),
                                                          ('old', 'ini')])):
            with self.subTest(renames):
                shown, done, deleted = self.save(renames)
                self.assertEqual(shown, S['MSG_CHECK'])
                self.assertEqual(done, expected)
                self.assertEqual(deleted, ['new', 'old'], 'после неясного RENAME ничего не удалять')

    def test_known_rename_failure_is_still_not_saved(self):
        shown, _, _ = self.save([True, False, True])
        self.assertEqual(shown, S['MSG_FAILED'])

    def test_tail_without_ini_is_deleted(self):
        shown, renames, deleted = self.save([False, True], state=1, files={'new': (300, 5)})
        self.assertEqual(shown, S['MSG_SAVED'])
        self.assertEqual(deleted[0], 'new')

    # 2026-09-27: признак правки («*» и красный заголовок) снимает только
    # удачная запись; по вопросу при выходе удача — без «wc.ini saved».

    def modified(self):
        return self.plugin.cpu.memory[S['MODIFIED']]

    def test_success_clears_the_mark(self):
        shown, _, _ = self.save([True, True], modified=1)
        self.assertEqual((shown, self.modified()), (S['MSG_SAVED'], 0))
        # Заголовок обычный уже под «wc.ini saved», а не после клавиши.
        window = self.plugin.cpu.memory[S['WND'] + 6]
        self.assertEqual(len(self.title), 2)
        self.assertEqual(self.title[0][:1], b' ')
        self.assertEqual(self.title[1], (window >> 4 | window << 4) & 0xFF)

    def test_failure_keeps_the_mark(self):
        for renames, files in (([False], None), ([], {'ini': (300, 5), 'new': (300, 5)}),
                               ([True, False, True], None)):
            with self.subTest(renames):
                shown, _, _ = self.save(renames, files=files, modified=1)
                self.assertNotEqual(shown, S['MSG_SAVED'])
                self.assertEqual(self.modified(), 1)
                self.assertEqual(self.title, [], 'заголовок остаётся красным')

    def test_new_version_line_that_was_not_saved_is_a_change(self):
        # Строка версии меняется в тексте перед записью: не записался — текст
        # в памяти уже не тот, что на носителе.
        old = INI.replace(VERSION, VERSION[:14] + b' 0.0', 1)
        shown, _, _ = self.save([False], text=old)
        self.assertEqual((shown, self.modified()), (S['MSG_FAILED'], 1))
        shown, _, _ = self.save([True, True], text=old)
        self.assertEqual((shown, self.modified()), (S['MSG_SAVED'], 0))
        shown, _, _ = self.save([False])
        self.assertEqual((shown, self.modified()), (S['MSG_FAILED'], 0), 'версия та же — текст тот же')

    def test_quiet_save_skips_only_the_success_message(self):
        shown, _, _ = self.save([True, True], modified=1, quiet=1)
        self.assertIsNone(shown, '«wc.ini saved» при выходе не нужно')
        self.assertEqual(self.modified(), 0)
        shown, _, _ = self.save([False], modified=1, quiet=1)
        self.assertEqual(shown, S['MSG_FAILED'], 'об отказе сообщение и при выходе')
        self.assertEqual(self.modified(), 1)


class ReadIni(unittest.TestCase):
    """Чтение wc.ini: отказ чтения делает текст недостоверным, предел размера — точный."""

    Z, C = 0x40, 0x01

    def read(self, size, read_ok=True):
        p = Plugin(INI)
        Z, C = self.Z, self.C

        def ok(cpu):
            cpu.f = (cpu.f | Z) & ~C

        def found(cpu):
            cpu.f &= ~(Z | C)
            cpu.de, cpu.hl = 0, size

        def load(cpu):
            cpu.f = cpu.f & ~C if read_ok else cpu.f | C

        p.call_scripted('READ_INI', {57: ok, 59: found, 62: ok, 48: load})
        return p

    def test_read_error_marks_the_text_unreliable(self):
        p = self.read(100, read_ok=False)
        self.assertEqual(p.cpu.memory[S['INI_STATE']], 3)
        self.assertEqual(p.text(), b'')

    def test_good_read_is_accepted(self):
        p = self.read(100)
        self.assertEqual(p.cpu.memory[S['INI_STATE']], 0)
        self.assertEqual(len(p.text()), 100)

    def test_size_limit_is_exact(self):
        limit = S['NEWBUF'] - S['INIBUF'] - 1                   # место под ноль за текстом
        self.assertEqual(self.read(limit).cpu.memory[S['INI_STATE']], 0)
        self.assertEqual(self.read(limit + 1).cpu.memory[S['INI_STATE']], 2)

    def entry(self, carry):
        p = Plugin(INI)
        Z, C = self.Z, self.C

        def ok(cpu):
            cpu.f = (cpu.f | Z) & ~C

        def fentry(cpu):
            cpu.f = cpu.f | Z | C if carry else (cpu.f | Z) & ~C

        p.call_scripted('READ_INI', {57: ok, 59: fentry})
        return p

    def test_missing_file_gives_the_template(self):
        p = self.entry(carry=False)
        self.assertEqual(p.cpu.memory[S['INI_STATE']], 1)
        self.assertTrue(p.text().startswith(VERSION + b'\r\r[SETUP]'))

    def test_directory_error_is_not_a_missing_file(self):
        # FENTRY при ошибке чтения каталога — Z и CF=1: файл, может быть, есть.
        # Прежде это шло как «файла нет» — шаблон, и F2 записал бы его поверх
        # настоящего wc.ini. Теперь — «не прочитался»: текст пуст, не пишется.
        p = self.entry(carry=True)
        self.assertEqual(p.cpu.memory[S['INI_STATE']], 3)
        self.assertEqual(p.text(), b'')

    def test_template_is_not_a_change(self):
        # Шаблон вместо ненайденного файла пользователь не правил: Esc без
        # правок выходит без вопроса, F2 по-прежнему создаёт файл.
        p = Plugin(INI)
        p.poke(S['MODIFIED'], 1)

        def ok(cpu):
            cpu.f = (cpu.f | self.Z) & ~self.C

        p.call_scripted('SCREEN', {57: ok, 59: ok}, stop_at=S['OPEN_SCREEN'])
        self.assertEqual(p.cpu.memory[S['INI_STATE']], 1)
        self.assertEqual(p.cpu.memory[S['MODIFIED']], 0)


class CommentKeys(unittest.TestCase):
    """Ключ считается только с начала строки: комментарии WC не читает."""

    def parse(self, text):
        p = Plugin(text)
        return p, p.cpu.memory[S['VALUES']], p.peek16(S['PLACES'])     # параметр 0 — CPU_FREQ

    def test_commented_line_before_the_real_one(self):
        # Пример аудита: SETUP показывал 0 и правил закомментированную строку.
        text = VERSION + CR + CR + b'[SETUP]' + CR + b';CPU_FREQ=0' + CR + b'CPU_FREQ=2' + CR
        p, value, place = self.parse(text)
        self.assertEqual(value, 2)
        self.assertEqual(bytes(p.cpu.memory[place - 10:place + 1]), CR + b'CPU_FREQ=2')

    def test_key_mentioned_after_semicolon(self):
        text = VERSION + CR + CR + b'[SETUP]' + CR + b'Logo=1; CPU_FREQ=0 here' + CR + b'CPU_FREQ=1' + CR
        self.assertEqual(self.parse(text)[1], 1)

    def test_key_only_in_comment_is_missing(self):
        text = VERSION + CR + CR + b'[SETUP]' + CR + b';CPU_FREQ=0' + CR
        self.assertEqual(self.parse(text)[2], 0)


class MissingKey(unittest.TestCase):
    """Параметр, которого нет в тексте, при изменении вписывается в свою секцию."""

    def change(self, p, index):
        p.poke(S['SCREEN_NO'], 0)
        p.poke(S['TOP'], 0)
        p.poke(S['SHOWN'], S['PARAM_COUNT'])                    # окно настроек, как в WC
        p.poke(S['WND'] + 12, index + 1)
        return p.call_api('CHANGE')

    def test_missing_key_goes_right_after_its_section_header(self):
        p = Plugin(INI)                                         # SavePaths= в [SETUP] нет
        self.change(p, 1)
        self.assertIn(b'[SETUP]' + CR + b'SavePaths=1' + CR + b'CPU_FREQ=2' + CR, p.text())
        self.assertNotEqual(p.peek16(S['PLACES'] + 2), 0)
        self.assertEqual(p.cpu.memory[S['VALUES'] + 1], 1)

    def test_second_change_edits_the_inserted_line(self):
        p = Plugin(INI)
        self.change(p, 1)
        self.change(p, 1)
        self.assertIn(CR + b'SavePaths=0' + CR, p.text())
        self.assertEqual(p.text().count(b'SavePaths='), 1)

    def test_missing_section_is_appended_with_the_key(self):
        text = VERSION + CR + CR + b'[SETUP]' + CR + b'CPU_FREQ=2' + CR + CR + b'[PLUGINS]' + CR + b'FILEX.WMF' + CR
        p = Plugin(text)
        self.change(p, 6)                                       # левый DRV: секции [LPANEL] нет
        self.assertTrue(p.text().endswith(b'FILEX.WMF' + CR + CR + b'[LPANEL]' + CR + b'DRV=1' + CR),
                        p.text()[-40:])

    def test_plugin_lines_stay_linked_after_insertion(self):
        p = Plugin(INI)
        p.add_plugins(NAMES)
        before = [p.line(name) for name in NAMES]
        self.change(p, 1)
        self.assertEqual([p.line(name) for name in NAMES], before)

    def test_no_room_leaves_text_alone(self):
        size = S['NEWBUF'] - S['INIBUF'] - 1 - 7                  # до предела меньше вставки
        text = INI + b';' + b'x' * (size - len(INI) - 2) + CR
        p = Plugin(text)
        log = self.change(p, 1)
        self.assertEqual(p.text(), text)
        self.assertEqual(p.peek16(S['PLACES'] + 2), 0)
        self.assertIn(47, [call for call, _ in log], 'показано сообщение, ждали клавишу')


def noop(cpu):
    pass


class Modified(unittest.TestCase):
    """Признак правки (2026-09-27): «*» перед названием окна и красный
    заголовок, пока правка не записана. Признак — байт MODIFIED: ставится там,
    где текст на самом деле стал другим, снимается удачной записью. 16-битная
    контрольная сумма вместо него давала совпадения у реальных пар правок
    поставляемого wc.ini (CPU_FREQ 2->1 вместе с другим параметром 1->9):
    заголовок обычный, и Esc выходил без вопроса."""

    def plugin(self, text=INI):
        p = Plugin(text)
        p.poke(S['SCREEN_NO'], 0)
        p.poke(S['TOP'], 0)
        p.poke(S['SHOWN'], S['PARAM_COUNT'])
        return p

    def change(self, p, index):
        p.poke(S['WND'] + 12, index + 1)
        p.call_api('CHANGE')
        return p.cpu.memory[S['MODIFIED']]

    def test_value_change_sets_the_mark(self):
        p = self.plugin()
        self.assertEqual(p.cpu.memory[S['MODIFIED']], 0)
        self.assertEqual(self.change(p, 0), 1)                  # CPU_FREQ — цифра в тексте

    def test_inserted_key_sets_the_mark(self):
        self.assertEqual(self.change(self.plugin(), 1), 1)      # SavePaths= в тексте нет

    def test_no_room_keeps_the_mark_off(self):
        size = S['NEWBUF'] - S['INIBUF'] - 1 - 7
        text = INI + b';' + b'x' * (size - len(INI) - 2) + CR
        p = self.plugin(text)
        self.assertEqual(self.change(p, 1), 0)
        self.assertEqual(p.text(), text)

    def test_value_back_keeps_the_mark(self):
        # «Правили с записи», а не «текст другой»: вернувшееся значение признак
        # не снимает — только запись.
        p = self.plugin()
        values = p.cpu.memory[S['PARAMS'] + 8]                  # значений у CPU_FREQ
        for _ in range(values):
            self.change(p, 0)
        self.assertEqual(p.text(), INI)
        self.assertEqual(p.cpu.memory[S['MODIFIED']], 1)

    def copy_new(self, old, new, modified=0):
        p = Plugin(old)
        p.poke(S['MODIFIED'], modified)
        p.cpu.memory[S['NEWBUF']:S['NEWBUF'] + len(new)] = new
        p.poke16(S['NEWPTR'], S['NEWBUF'] + len(new))
        p.call('COPY_NEW')
        self.assertEqual(p.text(), new)
        return p.cpu.memory[S['MODIFIED']]

    def test_copy_new_marks_only_a_different_text(self):
        self.assertEqual(self.copy_new(INI, INI), 0, 'тот же текст — не правка')
        for at in (0, len(INI) // 2, len(INI) - 1):
            changed = bytearray(INI)
            changed[at] ^= 1
            with self.subTest(байт=at):
                self.assertEqual(self.copy_new(INI, bytes(changed)), 1)
        self.assertEqual(self.copy_new(INI, INI + b'x'), 1, 'длиннее')
        self.assertEqual(self.copy_new(INI, INI[:-1]), 1, 'короче')
        self.assertEqual(self.copy_new(INI, INI, modified=1), 1, 'признак не снимается')

    def test_flags_confirmed_unchanged_are_not_a_change(self):
        p = self.plugin()
        p.add_plugins(NAMES)
        p.edit('TXTEDIT.WMF', b'-highlight=auto')                # поле — без пробела перед
        self.assertEqual(p.rebuild(), INI)
        self.assertEqual(p.cpu.memory[S['MODIFIED']], 0)
        p.edit('TXTEDIT.WMF', b'-highlight=on')
        p.rebuild()
        self.assertEqual(p.cpu.memory[S['MODIFIED']], 1)

    def test_toggle_is_a_change(self):
        p = self.plugin()
        p.add_plugins(NAMES)
        p.poke(p.record('MOUNTER.WMF') + S['PGROUP'], S['GROUP_FILE'])
        p.poke(S['SCREEN_NO'], 1)
        p.poke(S['WND'] + 12, (p.record('MOUNTER.WMF') - S['PLIST']) // S['PITEM'] + 1)
        p.call_api('CHANGE')
        self.assertIn(CR + b'MOUNTER.WMF -memory=128', p.text())
        self.assertEqual(p.cpu.memory[S['MODIFIED']], 1)

    def title(self, modified, screen):
        p = Plugin(INI)
        p.poke(S['MODIFIED'], modified)
        p.poke(S['SCREEN_NO'], screen)
        seen = {}

        def prsrw(cpu):
            seen['text'] = bytes(cpu.memory[cpu.hl:cpu.hl + cpu.bc])
            seen['at'] = (cpu.d, cpu.e)

        def priat(cpu):
            seen['color'] = alt_a(cpu)

        p.call_scripted('DRAW_TITLE', {3: prsrw, 4: priat})
        return p, seen

    def test_title_mark_and_color(self):
        for screen, label in ((0, 'TITLE_SETUP'), (1, 'TITLE_PLUGS')):
            for modified in (0, 1):
                with self.subTest(экран=screen, правили=modified):
                    p, seen = self.title(modified, screen)
                    memory = p.cpu.memory
                    head = bytes(memory[S[label]:S[label] + 2])
                    self.assertEqual(head, b'\x0e\x09', 'по центру, бумага и чернила местами')
                    name = bytes(memory[S[label] + 2:S[label] + 40]).split(b'\0')[0]
                    window = memory[S['WND'] + 6]
                    normal = (window >> 4 | window << 4) & 0xFF
                    # PRWOW ставит название с колонки (ширина-длина)/2, ширина
                    # окна — LINEW+2; «*» или пробел — колонкой левее.
                    column = (S['LINEW'] + 2 - len(name)) // 2 - 1
                    self.assertEqual(seen['at'], (0, column))
                    self.assertEqual(seen['text'], (b'*' if modified else b' ') + name)
                    self.assertEqual(seen['color'], normal & 0xF0 | 2 if modified else normal)


class LeaveAsk(unittest.TestCase):
    """Esc при несохранённой правке — вопрос «Save changed settings?» в том же
    окне и кнопки WC [ YES ]/[ NO ] (API 8). Yes — запись без «wc.ini saved» и
    выход (не записалось — сообщение и назад к списку); No — выход без записи;
    Esc — назад к списку. Выход LEAVE_ASK: Z — закрывать окно."""

    Z = 0x40
    YN, PRSRW, PRIAT = 8, 3, 4

    def ask(self, keys=('enter',), yes=True, saved=True, modified=1):
        p = Plugin(INI)
        shown = S['PARAM_COUNT']
        p.poke(S['SHOWN'], shown)
        p.poke(S['WND'] + 5, shown + 2)
        p.poke(S['WND'] + 12, 1)                                # курсор — на первой строке
        p.poke(S['MODIFIED'], modified)
        # HALT ждёт кадра, а прерываний тут нет: кадры отмеряет подкоманда 0 YN.
        code = bytes(p.cpu.memory[S['LEAVE_ASK']:S['MARK_MODIFIED']])
        self.assertEqual(code.count(b'\xfb\x76'), 1)
        p.poke(S['LEAVE_ASK'] + code.index(b'\xfb\x76') + 1, 0x00)
        # SAVE_INI — заглушка: QUIET — в #F100; удачная запись снимает признак.
        stub = [0x3A, *S['QUIET'].to_bytes(2, 'little'), 0x32, 0x00, 0xF1]
        if saved:
            stub += [0xAF, 0x32, *S['MODIFIED'].to_bytes(2, 'little')]
        p.cpu.memory[S['SAVE_INI']:S['SAVE_INI'] + len(stub) + 1] = bytes(stub + [0xC9])
        p.poke(0xF100, 0xEE)
        frames = iter(keys)
        state = {'key': None}
        self.yn, self.rows = [], []

        def yn(cpu):
            sub = alt_a(cpu)
            self.yn.append(sub)
            if sub == 0:
                state['key'] = next(frames)
            elif sub == 0xFF:
                cpu.f = cpu.f | self.Z if yes else cpu.f & ~self.Z

        def key(name):
            def reply(cpu):
                cpu.f = cpu.f & ~self.Z if state['key'] == name else cpu.f | self.Z
            return reply

        self.colored = []

        def prsrw(cpu):
            self.rows.append((cpu.d, bytes(cpu.memory[cpu.hl:cpu.hl + cpu.bc])))

        def priat(cpu):
            self.colored.append((len(self.yn), self.rows[-1][0], alt_a(cpu)))

        replies = defaultdict(lambda: noop, {self.YN: yn, self.PRSRW: prsrw, self.PRIAT: priat,
                                             S['API_ENTER']: key('enter'),
                                             S['API_ESC']: key('esc')})
        p.call_scripted('LEAVE_ASK', replies)
        self.plugin = p
        return not p.cpu.f & self.Z                             # True — остаться

    def saved_quietly(self):
        return self.plugin.cpu.memory[0xF100]

    def test_no_change_leaves_at_once(self):
        self.assertFalse(self.ask(modified=0))
        self.assertEqual(self.plugin.api_calls, [])

    def test_question_is_centered_above_the_buttons(self):
        self.ask(keys=('esc',))
        asked = [(row, text) for row, text in self.rows if b'Save changed settings?' in text]
        self.assertEqual(len(asked), 1)
        row, text = asked[0]
        left = len(text) - len(text.lstrip(b' '))
        right = len(text) - len(text.rstrip(b' '))
        self.assertEqual(left, right, 'пробелов слева и справа поровну')
        self.assertLess(row, S['PARAM_COUNT'], 'кнопки WC — в строке (IX+5)-2, ниже вопроса')
        self.assertEqual(self.yn[0], 2, 'кнопки Yes/No, выбрана Yes')

    def test_yes_saves_quietly_and_leaves(self):
        self.assertFalse(self.ask(keys=(None, None, 'enter')))
        self.assertEqual(self.yn, [2, 0, 0, 0, 0xFF], 'кадры ждут Enter')
        self.assertEqual(self.saved_quietly(), 1, 'запись без «wc.ini saved»')
        memory = self.plugin.cpu.memory
        self.assertEqual((memory[S['QUIET']], memory[S['MODIFIED']]), (0, 0))

    def test_yes_that_failed_stays(self):
        self.assertTrue(self.ask(saved=False))
        self.assertEqual(self.saved_quietly(), 1)
        self.assertEqual(self.plugin.cpu.memory[S['QUIET']], 0)

    def test_no_leaves_without_saving(self):
        self.assertFalse(self.ask(yes=False))
        self.assertEqual(self.saved_quietly(), 0xEE)
        self.assertEqual(self.plugin.cpu.memory[S['MODIFIED']], 1)

    def test_esc_goes_back_to_the_list(self):
        self.assertTrue(self.ask(keys=('esc',)))
        self.assertEqual(self.saved_quietly(), 0xEE)
        last_yn = max(i for i, call in enumerate(self.plugin.api_calls) if call[0] == self.YN)
        after = [call for call, _, _ in self.plugin.api_calls[last_yn:]]
        self.assertIn(self.PRIAT, after, 'список и заголовок перерисованы')
        # Кнопки WC — в строке (IX+5)-2, последней строке списка: после них
        # каждая строка списка снова в цвете окна, иначе след кнопок остаётся.
        window = self.plugin.cpu.memory[S['WND'] + 6]
        recolored = {row for frames, row, color in self.colored
                     if frames == len(self.yn) and color == window}
        cursor = self.plugin.cpu.memory[S['WND'] + 12]           # её цвет ведут API 6/7
        self.assertEqual(recolored, set(range(1, S['PARAM_COUNT'] + 1)) - {cursor})
        self.assertIn(S['PARAM_COUNT'], recolored, 'строка кнопок')

    def test_rows_under_the_question_get_the_window_color(self):
        self.ask(keys=('esc',))
        window = self.plugin.cpu.memory[S['WND'] + 6]
        cleared = {row for frames, row, color in self.colored if frames == 0 and color == window}
        cursor = self.plugin.cpu.memory[S['WND'] + 12]
        self.assertEqual(cleared, set(range(1, S['PARAM_COUNT'] + 1)) - {cursor})


class LongFlags(unittest.TestCase):
    """Поле флагов вмещает 64 знака (FLAGW). Флаги длиннее SETUP не правит и
    говорит об этом в том же окне: прежде Enter без правки записывал их
    обрезанными до 64 знаков, а F2 сохранял такой текст (аудит Codex R36-3).
    Пробелы за 64-м знаком не в счёт — поле их и так убирает."""

    def enter(self, flags: bytes):
        text = INI.replace(b'TXTEDIT.WMF -highlight=auto; auto,on,off',
                           b'TXTEDIT.WMF ' + flags + b';hint')
        p = Plugin(text)
        p.add_plugins(NAMES)
        p.poke(S['SCREEN_NO'], 1)
        p.poke(S['TOP'], 0)
        p.poke(S['SHOWN'], len(NAMES))
        p.poke(S['WND'] + 12, (p.record('TXTEDIT.WMF') - S['PLIST']) // S['PITEM'] + 1)
        shown = []

        def prsrw(cpu):
            shown.append(bytes(cpu.memory[cpu.hl:cpu.hl + cpu.bc]).strip())

        stopped = p.call_scripted('ENTER_KEY', defaultdict(lambda: noop, {3: prsrw}),
                                  stop_at=S['EDIT_FLAGS.open'], or_return=True)
        return p, stopped is not None, shown, text

    def test_up_to_the_field_width_opens_the_editor(self):
        for flags in (b'-' + b'a' * 63, b'-' + b'a' * 63 + b' ' * 10, b'-x'):
            with self.subTest(длина=len(flags.rstrip())):
                p, opened, _, _ = self.enter(flags)
                self.assertTrue(opened, 'поле правки не открылось')
                self.assertEqual(p.peek16(S['EDITREC']), p.record('TXTEDIT.WMF'))

    def test_longer_flags_are_not_edited(self):
        for flags in (b'-' + b'a' * 64, b'-' + b'a' * 70, b'-' + b'a' * 63 + b' x'):
            with self.subTest(длина=len(flags)):
                p, opened, shown, text = self.enter(flags)
                self.assertFalse(opened, 'поле правки открылось')
                self.assertIn(b'Flags are longer than 64 chars', shown)
                self.assertEqual(p.text(), text, 'текст тронут')
                self.assertEqual(p.peek16(S['EDITREC']), 0, 'правка флагов осталась начатой')
                self.assertEqual(p.cpu.memory[S['MODIFIED']], 0)
                self.assertEqual(p.rebuild(), text, 'пересборка обрезала флаги')


class ShortList(unittest.TestCase):
    """На экране плагинов строк бывает меньше двух: в каталоге WC нашёлся один
    .WMF или ни одного (каталог не читается). Сообщению с подсказкой или
    кнопками там не встать, а при нуле строк SHOW_TEXT считал бы с 256 — за
    окно и за экран. Тогда сообщение — на экране настроек."""

    def test_message_moves_to_the_settings_screen(self):
        for count in (0, 1):
            with self.subTest(строк=count):
                p = Plugin(INI)
                p.poke(S['HEI'], 25)
                p.poke(S['SCREEN_NO'], 1)
                p.poke(S['PCOUNT'], count)
                p.poke(S['COUNT'], count)
                p.poke(S['SHOWN'], count)
                rows = []
                p.call_scripted('SHOW_TEXT', defaultdict(lambda: noop, {
                    3: lambda cpu: rows.append(cpu.d)}), hl=S['MSG_ASK'])
                self.assertEqual(p.cpu.memory[S['SCREEN_NO']], 0)
                self.assertEqual(p.cpu.memory[S['SHOWN']], S['PARAM_COUNT'])
                self.assertEqual(p.cpu.d, (S['PARAM_COUNT'] + 1) // 2)
                self.assertLessEqual(max(rows), S['PARAM_COUNT'])
                self.assertLess(len(rows), 3 * S['PARAM_COUNT'])

    def test_two_rows_are_enough(self):
        p = Plugin(INI)
        p.poke(S['SCREEN_NO'], 1)
        p.poke(S['SHOWN'], 2)
        rows = []
        p.call_scripted('SHOW_TEXT', defaultdict(lambda: noop, {
            3: lambda cpu: rows.append(cpu.d)}), hl=S['MSG_ASK'])
        self.assertEqual(p.cpu.memory[S['SCREEN_NO']], 1, 'экран тот же')
        self.assertEqual(sorted(set(rows)), [1, 2])
        self.assertEqual(p.cpu.d, 1)

    def test_empty_list_ignores_space_and_enter(self):
        # Записи от прошлого перебора остались в памяти, новый ничего не нашёл:
        # курсор не на записи, и пробел и Enter не трогают текст.
        p = Plugin(INI)
        p.add_plugins(('MOUNTER.WMF', 'TXTEDIT.WMF'))            # под курсором — выключенный
        p.poke(p.record('MOUNTER.WMF') + S['PGROUP'], S['GROUP_FILE'])
        p.poke(S['PCOUNT'], 0)
        p.poke(S['SCREEN_NO'], 1)
        p.poke(S['TOP'], 0)
        p.poke(S['WND'] + 12, 1)
        self.assertEqual(p.call_api('CHANGE'), [])
        self.assertEqual(p.call_api('ENTER_KEY'), [])
        self.assertEqual(p.text(), INI)
        self.assertEqual((p.cpu.memory[S['MODIFIED']], p.peek16(S['EDITREC'])), (0, 0))
        self.assertEqual(p.cpu.memory[S['PLIST']] & 1, 0, 'отметка старой записи не тронута')


class Header(unittest.TestCase):

    def test_menu_plugin_one_page(self):
        header = WMF.read_bytes()[:512]
        self.assertEqual(header[16:32], b'WildCommanderMDL')
        self.assertEqual(header[34], 1, 'одна страница')
        self.assertEqual(header[197], 0x03, 'пункт меню F10, тип #03')
        self.assertEqual(header[165:173], b'WC Setup', 'так пункт называет подсказка ядра')
        self.assertEqual(bytes(header[64:160]), bytes(96), 'по расширению не запускается')
        self.assertLessEqual(S['CODE_END'], S['INIBUF'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
