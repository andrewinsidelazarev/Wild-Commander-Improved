"""Машинные проверки менеджера плагинов PLM.WMF.

Менеджер живёт не в исходниках WC, а поверх них: он переписывает в RAM пять
известных кусков кода коммандера. Поэтому здесь две группы проверок.

1. Эталоны перехватов побайтово сверяются с собранным runtime WC. Если код
   коммандера в этих местах изменится, менеджер молча перестанет ставиться —
   тест ловит это на сборке, а не на железе.
2. Рабочие подпрограммы исполняются настоящим Z80 на модели страниц TS-Conf:
   окна #4000/#8000/#C000, подмена MNG8/MNGC/MNGC_PL и DMA-перенос страниц.
   Проверяются фильтр меню, удаление записи и вытеснение по давности.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

import z80

ROOT = Path(__file__).resolve().parents[2]
WMF = ROOT / 'Build/PLM.WMF'
PAYLOAD = ROOT / 'Build/boot.payload.bin'
PAYLOAD_BASE = 0x6011
SYMBOL_RE = re.compile(r'^([^:]+):\s+EQU\s+0x([0-9A-Fa-f]+)$')

WC_PAGE = 0x02                  # верхняя половина WC в окне #8000
VARS_PAGE = 0x05                # переменные загрузчика в окне #4000
STOP = 0xFF00
STACK = 0x5F00
HOOKS = ('GATEWAY', 'WALK', 'MENUBUILD', 'MENUPICK')


def symbols(path: Path) -> dict[str, int]:
    out = {}
    for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
        match = SYMBOL_RE.match(line.strip())
        if match:
            out[match.group(1)] = int(match.group(2), 16)
    return out


S = symbols(ROOT / 'Build/PLM.sym')
B = symbols(ROOT / 'Build/boot.sym')
IMAGE = WMF.read_bytes()[512:]                  # страница плагина без заголовка


def template(name: str) -> bytes:
    """Эталон перехвата из собранного плагина."""
    start = S['ORIGINAL_' + name] & 0x3FFF
    return IMAGE[start:start + S[name + '_LENGTH']]


def runtime(address: int, length: int) -> bytes:
    """Тот же участок в собранном runtime коммандера."""
    data = PAYLOAD.read_bytes()
    return data[address - PAYLOAD_BASE:address - PAYLOAD_BASE + length]


class Hooks(unittest.TestCase):
    """Перехваты ставятся только поверх известного кода WC."""

    def test_hook_addresses_follow_wc_symbols(self):
        self.assertEqual(S['GATEWAY'], B['L6011_241'])
        self.assertEqual(S['WALK'], B['WCVW.WALK'])
        self.assertEqual(S['MENUBUILD'], B['WCVW.MNU'])

    def test_templates_match_built_runtime(self):
        for name in HOOKS:
            with self.subTest(hook=name):
                self.assertEqual(template(name), runtime(S[name], S[name + '_LENGTH']),
                                 f'код WC по #{S[name]:04X} разошёлся с эталоном {name}')

    def test_patch_fits_the_place_it_overwrites(self):
        # WALK кончается переходом, поэтому его заплата короче перекрываемого куска.
        for name in HOOKS:
            with self.subTest(hook=name):
                self.assertLessEqual(S[name + '_END'] - S[name + '_CODE'], S[name + '_LENGTH'])

    def test_pool_limit_is_whole_pool(self):
        self.assertEqual(S['POOL_LIMIT'], S['PLEPG'] - S['PLGPG'],
                         'поставляемая сборка не должна ограничивать пул')

    def test_plugin_is_one_page_resident(self):
        header = WMF.read_bytes()[:512]
        self.assertEqual(header[16:32], b'WildCommanderMDL')
        self.assertEqual(header[34], 1, 'менеджер обязан занимать одну страницу')
        self.assertEqual(header[197], 0x06, 'менеджер — резидент, тип #06')


class Stand:
    """Модель страниц TS-Conf: окна #4000/#8000/#C000 и DMA между страницами."""

    def __init__(self, records, *, own=1, restop=2, ppgm=2, usage=0):
        self.pages = {page: bytearray(0x4000) for page in
                      (VARS_PAGE, WC_PAGE, S['PLHPG'])}
        for page in range(S['PLGPG'], S['PLGPG'] + 64):
            self.pages[page] = bytearray(bytes([page]) * 0x4000)   # страницы различимы
        self.own = S['PLGPG'] + own
        self.pages[self.own][:len(IMAGE)] = IMAGE
        self.records = records
        self.fill_headers(records)

        self.cpu = z80.Z80Machine()
        self.cpu.memory[:] = bytes(0x10000)
        self.window = {0x4000: VARS_PAGE, 0x8000: self.own, 0xC000: S['PLHPG']}
        for window, page in self.window.items():
            self.cpu.memory[window:window + 0x4000] = self.pages[page]
        self.dma = {}
        self.file_calls = []
        self.cpu.set_output_callback(self.out)
        self.cpu.set_input_callback(lambda port: 0x00)

        self.poke(S['OWN'], self.own)
        self.poke(S['RESTOP'], restop)
        self.poke16(S['USAGE'], usage)
        self.poke(S['PPGM'], ppgm)
        self.poke(S['PPGP'], own)
        self.poke16(S['PHED'], 0xC000 + 512 * len(records))

    # --- страницы и окна ---
    def flush(self):
        for window, page in self.window.items():
            self.pages[page][:] = self.cpu.memory[window:window + 0x4000]

    def reload(self):
        for window, page in self.window.items():
            self.cpu.memory[window:window + 0x4000] = self.pages[page]

    def map(self, window, page):
        # Одна и та же физическая страница бывает видна сразу в двух окнах,
        # поэтому при каждом переключении окна синхронизируются целиком.
        self.flush()
        self.window[window] = page
        self.reload()

    # --- память ---
    def poke(self, address, value):
        self.cpu.memory[address] = value & 0xFF

    def poke16(self, address, value):
        self.cpu.memory[address] = value & 0xFF
        self.cpu.memory[address + 1] = value >> 8 & 0xFF

    def peek(self, address):
        return self.cpu.memory[address]

    def peek16(self, address):
        return self.cpu.memory[address] | self.cpu.memory[address + 1] << 8

    def fill_headers(self, records):
        page = self.pages[S['PLHPG']]
        page[:] = bytes(0x4000)
        for index, record in enumerate(records):
            start = index * 512
            page[start + S['REC_BASE']] = record.get('base', 0xFF)
            page[start + S['REC_PAGES']] = record.get('pages', 1)
            page[start + S['REC_TYPE']] = record.get('type', 0x03)
            stamp = record.get('stamp', 0)
            page[start + S['REC_STAMP']] = stamp & 0xFF
            page[start + S['REC_STAMP'] + 1] = stamp >> 8 & 0xFF
            name = record['name'].encode('cp866').ljust(32, b' ')
            page[start + S['REC_NAME']:start + S['REC_NAME'] + 32] = name

    def headers(self):
        page = (self.pages[S['PLHPG']] if self.window[0xC000] != S['PLHPG']
                else self.cpu.memory[0xC000:0x10000])
        end = self.peek16(S['PHED'])
        out = []
        for index in range((end - 0xC000) // 512):
            start = index * 512
            out.append(dict(base=page[start], pages=page[start + S['REC_PAGES']],
                            type=page[start + S['REC_TYPE']],
                            name=bytes(page[start + S['REC_NAME']:
                                            start + S['REC_NAME'] + 32]).decode('cp866').strip()))
        return out

    # --- DMA TS-Conf: перенос 16 КиБ между физическими страницами ---
    def out(self, port, value):
        self.dma[port & 0xFF00] = value
        if port & 0xFF00 == 0x2700 and value & 1:
            source = self.dma.get(0x1C00, 0)
            target = self.dma.get(0x1F00, 0)
            self.flush()
            self.pages[target][:] = self.pages[source]
            self.reload()

    # --- вызовы WC ---
    def mng8(self, cpu):
        self.map(0x8000, cpu.a)
        self.poke(0x6002, cpu.a)
        cpu.bc = 0x12AF                         # настоящий MNG8 разрушает BC
        self.ret(cpu)

    def mngc(self, cpu):
        self.map(0xC000, cpu.a)
        self.poke(0x6003, cpu.a)
        self.ret(cpu)

    def mngc_pl(self, cpu):
        value = cpu.a
        if value == 0xFE:
            page = 0
        elif value == 0xFF:
            page = 1
        elif value >= 0x40:
            self.ret(cpu)
            return
        else:
            page = S['PLGPG'] + value + self.peek(S['PPGP'])
        self.map(0xC000, page)
        self.poke(0x6003, page)
        self.ret(cpu)

    def file_call(self, name):
        def handler(cpu):
            self.file_calls.append(name)
            self.ret(cpu)
        return handler

    def ret(self, cpu):
        cpu.pc = self.peek16(cpu.sp)
        cpu.sp = (cpu.sp + 2) & 0xFFFF

    def run(self, start, budget=200000):
        cpu = self.cpu
        cpu.pc, cpu.sp = start, STACK
        self.poke16(STACK, STOP)
        handlers = {S['MNG8']: self.mng8, S['MNGC']: self.mngc, S['MNGC_PL']: self.mngc_pl,
                    S['GIPAG']: self.file_call('GIPAG'),
                    S['LOAD512']: self.file_call('LOAD512'),
                    S['SRHDRN']: self.file_call('SRHDRN')}
        for address in list(handlers) + [STOP]:
            cpu.set_breakpoint(address)
        for _ in range(budget):
            cpu.ticks_to_stop = 100000
            if not cpu.run() & 2:
                continue
            if cpu.pc == STOP:
                self.flush()
                return
            handlers[cpu.pc](cpu)
        raise AssertionError(f'подпрограмма не завершилась, pc=#{cpu.pc:04X}')


MIXED = [
    dict(name='ZIP unpacker', type=0x00, pages=3),
    dict(name='ChkDsk FAT32', type=0x03, pages=5),
    dict(name='Text&HEX Viewer', type=0x05, pages=1),
    dict(name='BMP&TGA Viewer', type=0x00, pages=1),
    dict(name='TXT Editor', type=0x15, pages=2),
    dict(name='Wild Player', type=0x04, pages=3),
    dict(name='Create File', type=0x11, pages=2),
    dict(name='MaxiClock', type=0x02, pages=6),
]
LAUNCHABLE = ['ChkDsk FAT32', 'Text&HEX Viewer', 'TXT Editor', 'Create File', 'MaxiClock']


class Menu(unittest.TestCase):
    """В меню F10 попадают только те типы, которые из него запускаются."""

    def setUp(self):
        self.stand = Stand(MIXED)
        self.stand.run(S['MENU_WORK'])
        self.page = self.stand.pages[self.stand.own]

    def names(self):
        count = self.stand.peek16(S['COUNT'])
        start = S['LIST'] - 0x8000
        return [bytes(self.page[start + i:start + i + 32]).decode('cp866').strip()
                for i in range(0, count, 32)]

    def test_only_launchable_types_are_listed(self):
        self.assertEqual(self.names(), LAUNCHABLE)

    def test_line_table_points_at_the_same_records(self):
        table = S['INDEX'] - 0x8000
        expected = [0xC0 + 2 * index for index, record in enumerate(MIXED)
                    if record['name'] in LAUNCHABLE]
        self.assertEqual(list(self.page[table + 1:table + 1 + len(expected)]), expected)
        self.assertEqual(self.page[table + 1 + len(expected)], 0,
                         'хвост таблицы обязан быть пуст')

    def test_menu_build_reads_no_files(self):
        self.assertEqual(self.stand.file_calls, [])


class Scroll(unittest.TestCase):
    """Окно меню постоянной высоты: список прокручивается, полоса показывает где."""

    def height(self, screen_rows, count):
        stand = Stand(MIXED)
        stand.poke(0x600E, screen_rows)
        stand.poke(S['MCOUNT'], count)
        stand.run(S['MENU_HEIGHT'])
        return stand.cpu.a

    def knob(self, count, rows, top):
        stand = Stand(MIXED)
        stand.poke(S['MCOUNT'], count)
        stand.poke(S['MROWS'], rows)
        stand.poke(S['MTOP'], top)
        stand.run(S['MENU_KNOB'])
        return stand.cpu.a

    def test_window_fits_the_text_screen(self):
        self.assertEqual(self.height(25, 32), 20, 'в 80x25 помещается 20 строк')
        self.assertEqual(self.height(36, 32), 31, 'в 90x36 помещается 31 строка')
        self.assertEqual(self.height(36, 7), 7, 'короткий список показывается целиком')

    def test_knob_walks_the_whole_bar(self):
        self.assertEqual(self.knob(count=10, rows=5, top=0), 0)
        self.assertEqual(self.knob(count=10, rows=5, top=5), 4, 'внизу списка — внизу полосы')
        self.assertEqual(self.knob(count=32, rows=8, top=12), 3)
        self.assertEqual(self.knob(count=32, rows=8, top=24), 7)


class Footer(unittest.TestCase):
    """Подвал окна меню показывает, сколько памяти пула ещё свободно."""

    def footer(self, waterline):
        stand = Stand(MIXED, ppgm=waterline)
        stand.run(S['MENU_FOOTER'])
        stand.flush()
        page = stand.pages[stand.own]
        start = S['FOOTER_TEXT'] - 0x8000
        text = bytes(page[start:start + 16])
        return text[3:text.index(0)].decode('cp866')

    def test_free_pages_turn_into_kilobytes(self):
        self.assertEqual(self.footer(2), 'Free:  976K')      # 61 страница по 16 КиБ
        self.assertEqual(self.footer(19), 'Free:  704K')
        self.assertEqual(self.footer(0), 'Free: 1008K', 'пустой пул — весь объём')

    def test_full_pool_shows_zero(self):
        self.assertEqual(self.footer(S['POOL_LIMIT']), 'Free:    0K')
        self.assertEqual(self.footer(S['POOL_LIMIT'] + 5), 'Free:    0K',
                         'ниже нуля счётчик не уходит')


class Eviction(unittest.TestCase):
    """Место в пуле освобождает самый давно использованный плагин."""

    def stand_with_loaded(self, needed):
        records = [dict(item) for item in MIXED]
        records[1].update(base=2, pages=5, stamp=7)       # старше всех
        records[4].update(base=7, pages=2, stamp=9)
        records[7].update(base=9, pages=6, stamp=11)
        stand = Stand(records, ppgm=15, usage=12)
        stand.poke(S['NEEDED'], needed)
        return stand

    def test_oldest_plugin_is_unloaded_and_the_pool_is_packed(self):
        stand = self.stand_with_loaded(0x3F - 15 + 1)     # не хватает одной страницы
        stand.run(S['ENSURE_SPACE'])
        table = {item['name']: item for item in stand.headers()}
        self.assertEqual(table['ChkDsk FAT32']['base'], 0xFF, 'выгружается самый давний')
        self.assertEqual(table['TXT Editor']['base'], 2)
        self.assertEqual(table['MaxiClock']['base'], 4)
        self.assertEqual(stand.peek(S['PPGM']), 10)

    def test_residents_below_the_waterline_are_untouched(self):
        stand = self.stand_with_loaded(1)
        stand.run(S['ENSURE_SPACE'])
        self.assertEqual(stand.peek(S['PPGM']), 15, 'места хватает — ничего не двигаем')
        self.assertEqual([item['base'] for item in stand.headers()][1], 2)


if __name__ == '__main__':
    unittest.main()
