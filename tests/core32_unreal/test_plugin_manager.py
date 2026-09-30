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
PANEL_STREAM = 0xF3                     # поток левой панели: может быть другой диск


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
        self.assertEqual(S['MNG0'], B['MNG0'])
        self.assertEqual(S['INIPG'], B['WCINI.INIPG'], 'поток каталога WC')

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
        self.assertEqual(header[33] & 1, 1, 'ядро должно звать установщик сразу при загрузке')


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
        self.reload()
        self.dma = {}
        self.file_calls = []
        self.file_streams = []                  # поток в окне #0000 при каждом вызове
        self.cpu.set_output_callback(self.out)
        self.cpu.set_input_callback(lambda port: 0x00)

        self.poke(S['OWN'], self.own)
        self.poke(S['RESTOP'], restop)
        self.poke16(S['USAGE'], usage)
        self.poke(S['PPGM'], ppgm)
        self.poke(S['PPGP'], own)
        self.poke16(S['PHED'], 0xC000 + 512 * len(records))
        self.poke(0x6000, PANEL_STREAM)          # в окне #0000 — поток панели

    # --- страницы и окна ---
    def flush(self):
        # Страница, видная сразу в двух окнах, на железе одна: запись через любое
        # окно видна в обоих. Поэтому из такого окна переносим только байты,
        # записанные через него, — иначе копия одного окна затёрла бы другое.
        mapped = list(self.window.values())
        for window, page in self.window.items():
            current = bytes(self.cpu.memory[window:window + 0x4000])
            if mapped.count(page) == 1:
                self.pages[page][:] = current
                continue
            target = self.pages[page]
            for offset, (old, new) in enumerate(zip(self.seen[window], current)):
                if old != new:
                    target[offset] = new

    def reload(self):
        for window, page in self.window.items():
            self.cpu.memory[window:window + 0x4000] = self.pages[page]
        self.seen = {window: bytes(self.pages[page]) for window, page in self.window.items()}

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
            ext = record.get('ext', b'')                # свои расширения, +64
            page[start + S['REC_EXT']:start + S['REC_EXT'] + len(ext)] = ext

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

    # Номер файлового вызова (с нуля), который откажет: GIPAG — NZ, LOAD512 —
    # CF=1. Остальные возвращают успех: Z и CF=0.
    fail_at = None

    def mng0(self, cpu):
        self.poke(0x6000, cpu.a)
        cpu.bc = 0x10AF                         # настоящий MNG0 разрушает BC
        self.ret(cpu)

    def file_call(self, name):
        def handler(cpu):
            self.file_calls.append(name)
            self.file_streams.append(self.peek(0x6000))
            if len(self.file_calls) - 1 == self.fail_at:
                cpu.f = (cpu.f & ~0x40) | 0x01
            else:
                cpu.f = (cpu.f | 0x40) & ~0x01
            self.ret(cpu)
        return handler

    # Поиск wc.ini: None — флаги как были, True — найден (NZ, кластер), False — нет (Z).
    ini = None

    def srhdrn(self, cpu):
        self.file_calls.append('SRHDRN')
        if self.ini is True:
            cpu.f &= ~0x40
            cpu.hl, cpu.de = 0x1234, 0
        elif self.ini is False:
            cpu.f |= 0x40
        self.ret(cpu)

    def ret(self, cpu):
        cpu.pc = self.peek16(cpu.sp)
        cpu.sp = (cpu.sp + 2) & 0xFFFF

    def run(self, start, budget=200000):
        cpu = self.cpu
        cpu.pc, cpu.sp = start, STACK
        self.poke16(STACK, STOP)
        handlers = {S['MNG8']: self.mng8, S['MNGC']: self.mngc, S['MNGC_PL']: self.mngc_pl,
                    S['MNG0']: self.mng0,
                    S['GIPAG']: self.file_call('GIPAG'),
                    S['LOAD512']: self.file_call('LOAD512'),
                    S['SRHDRN']: self.srhdrn}
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
# Что видит пользователь в F10: то же, что WC Setup называет «F10» и «saver»,
# по алфавиту — без учёта регистра и ведущих пробелов. Решает тип: всё, что
# заявило F10, даже со своими расширениями (у Mounter, TRDump, TRDispatcher и
# TXT Editor из F10 свой интерфейс); только по файлу — нет.
F10_SET = [
    dict(name='WC Setup v0.1', type=0x03),
    dict(name='FT812 Viewer', type=0x00, ext=b'JPG'),
    dict(name='SCREEEN SAVER', type=0x02),
    dict(name='TR-DOS Mounter v1.59', type=0x03, ext=b'TRD'),
    dict(name='ChkDsk FAT32', type=0x03),
    dict(name='Text&HEX Viewer', type=0x04, ext=b'TXT'),
    dict(name='  Create File', type=0x11),
    dict(name='TXT Editor', type=0x15),
    dict(name='TRDump v0.83', type=0x05, ext=b'TRD'),
    dict(name='setime v0.1', type=0x03),
    dict(name='F4 only', type=0x14),
    dict(name='ZIP unpacker', type=0x00),
    dict(name='F2 and menu', type=0x11, ext=b'ZZZ'),
    dict(name='F4 and menu', type=0x13),
]
F10_SHOWN = ['ChkDsk FAT32', 'Create File', 'F2 and menu', 'F4 and menu', 'SCREEEN SAVER',
             'setime v0.1', 'TR-DOS Mounter v1.59', 'TRDump v0.83', 'TXT Editor',
             'WC Setup v0.1']


class Menu(unittest.TestCase):
    """Меню F10 — группы «F10» и «saver» из WC Setup, по алфавиту."""

    def setUp(self):
        self.stand = Stand(F10_SET)
        self.stand.run(S['MENU_WORK'])
        self.page = self.stand.pages[self.stand.own]

    def names(self):
        count = self.stand.peek16(S['COUNT'])
        start = S['LIST'] - 0x8000
        return [bytes(self.page[start + i:start + i + 32]).decode('cp866').strip()
                for i in range(0, count, 32)]

    def test_everything_declaring_f10_and_nothing_else(self):
        self.assertEqual(self.names(), F10_SHOWN)

    def test_line_table_follows_the_sorted_names(self):
        table = S['INDEX'] - 0x8000
        record = {item['name'].strip(): 0xC0 + 2 * index for index, item in enumerate(F10_SET)}
        expected = [record[name] for name in F10_SHOWN]
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


# Встроенный минимум ядра на случай, когда wc.ini нет: FILEX и менеджер —
# резиденты, «WC Setup» — пункт меню F10. Ядро уже загрузило все три.
MINIMUM = [
    dict(name='FILEX API provider v1', type=0x06, base=0, pages=1),
    dict(name='Plugin Loader Manager v0.5', type=0x06, base=1, pages=1),
    dict(name='WC Setup v0.1', type=0x03, base=2, pages=1),
]


class Install(unittest.TestCase):
    """Установка: с wc.ini нерезиденты выгружаются, без него пул не трогается."""

    def install(self, ini):
        stand = Stand(MINIMUM, own=1, restop=0, ppgm=3)
        stand.ini = ini
        stand.poke(S['ARRIVAL'], 0x06)                  # прежний путь: из AX_RUN
        stand.run(S['INSTALL_SCAN'])
        return stand

    def test_without_ini_plugins_stay_where_the_core_put_them(self):
        stand = self.install(ini=False)
        self.assertEqual([item['base'] for item in stand.headers()], [0, 1, 2],
                         'файлов взять неоткуда — выгружать нельзя')
        self.assertEqual(stand.peek(S['PPGM']), 3)
        self.assertEqual(stand.peek(S['RESTOP']), 3, 'всё загруженное неподвижно')
        self.assertEqual(stand.file_calls, ['SRHDRN'])

    def test_with_ini_non_residents_are_unloaded(self):
        stand = self.install(ini=True)
        self.assertEqual([item['base'] for item in stand.headers()], [0, 1, 0xFF])
        self.assertEqual(stand.peek(S['PPGM']), 2, 'пул свободен выше резидентов')
        self.assertEqual(stand.peek(S['RESTOP']), 2)
        self.assertEqual(stand.file_calls[:3], ['SRHDRN', 'GIPAG', 'LOAD512'])


class EarlyInstall(unittest.TestCase):
    """Установка сразу при загрузке (A=#07): ядро зовёт менеджер до остальных
    строк [PLUGINS], их потом регистрирует перехват WALK. Читать wc.ini незачем,
    а всё уже загруженное остаётся на месте."""

    def test_nothing_is_read_and_nothing_moves(self):
        stand = Stand(MINIMUM[:2], own=1, restop=0, ppgm=2)
        stand.ini = True                                # wc.ini есть, но не нужен
        stand.poke(S['ARRIVAL'], 0x07)
        stand.run(S['INSTALL_SCAN'])
        self.assertEqual(stand.file_calls, [], 'ранняя установка не читает диск')
        self.assertEqual([item['base'] for item in stand.headers()], [0, 1])
        self.assertEqual(stand.peek(S['RESTOP']), 2, 'загруженное выше менеджера неподвижно')
        self.assertEqual(stand.peek(S['INIPAGE']), 2, 'буфер CORE32 — первая свободная')
        self.assertEqual(stand.peek(S['PPGM']), 2)

    def register_resident(self, restop):
        """Резидент #06 из строки ниже менеджера: база на ватерлинии 2."""
        records = MINIMUM[:2] + [dict(name='Late resident', type=0x06, base=2, pages=2)]
        stand = Stand(records, own=1, restop=restop, ppgm=2)
        stand.poke(S['PPG2'], 4)                        # LDRE: ватерлиния + страницы
        blocks = S['COPY'] + S['REC_BLOCKS']
        for offset, value in enumerate((0, 1, 1, 1, 0, 0)):
            stand.poke(blocks + offset, value)
        stand.run(S['REGISTER'])
        return stand

    def test_late_resident_raises_the_fixed_part(self):
        # AX_RUN сотрёт заголовок резидента, и уплотнение перестанет его видеть:
        # его страницы обязаны уйти под RESTOP сразу при регистрации.
        stand = self.register_resident(restop=2)
        self.assertEqual(stand.peek(S['RESTOP']), 4)
        self.assertEqual(stand.file_calls, ['LOAD512', 'LOAD512'], 'блоки резидента читаются')

    def test_resident_above_movable_plugins_keeps_old_rule(self):
        stand = self.register_resident(restop=1)
        self.assertEqual(stand.peek(S['RESTOP']), 1, 'под ним подвижные — граница прежняя')


class KernelTail(unittest.TestCase):
    """Хвост ALPL в MD20: кого ядро запускает сразу после загрузки плагина."""

    def run_tail(self, kind, c, flag):
        cpu = z80.Z80Machine()
        cpu.set_memory_block(PAYLOAD_BASE, PAYLOAD.read_bytes())
        cpu.memory[0xB000 + 33] = flag                   # LOBU+33
        cpu.pc, cpu.sp, cpu.a, cpu.c = B['ALPL_TAIL'], STACK, kind, c
        cpu.memory[STACK:STACK + 2] = STOP.to_bytes(2, 'little')
        stops = {B['L6011_242']: 'RAJT', B['L6011_243']: 'AJT', STOP: 'RET'}
        for address in stops:
            cpu.set_breakpoint(address)
        for _ in range(100):
            cpu.ticks_to_stop = 10000
            if cpu.run() & 2:
                return stops[cpu.pc], cpu.a
        raise AssertionError('хвост ALPL не завершился')

    def test_wcvw_jumps_to_the_tail(self):
        data = PAYLOAD.read_bytes()
        start = B['WCVW.MIMI'] - PAYLOAD_BASE
        self.assertEqual(data[start:start + 3], bytes([0xC3]) + B['ALPL_TAIL'].to_bytes(2, 'little'))

    def test_flagged_resident_is_installed_at_boot(self):
        self.assertEqual(self.run_tail(0x06, c=1, flag=1), ('AJT', 0x07))

    def test_other_cases_wait_for_ax_run(self):
        self.assertEqual(self.run_tail(0x06, c=1, flag=0)[0], 'RET', 'без признака — как прежде')
        self.assertEqual(self.run_tail(0x06, c=0xFF, flag=1)[0], 'RET', 'ручная загрузка #06')
        self.assertEqual(self.run_tail(0x03, c=1, flag=1)[0], 'RET', 'не резидент')

    def test_manual_type_01_still_runs(self):
        self.assertEqual(self.run_tail(0x01, c=0xFF, flag=0)[0], 'RAJT')


class ManyItems(unittest.TestCase):
    """Меню на все 32 записи таблицы WC: имена не затирают таблицу строк."""

    def test_every_row_points_to_its_record(self):
        records = [dict(name=f'Plugin {n:02d}', type=0x03, pages=1) for n in range(32)]
        stand = Stand(records, own=1, restop=0, ppgm=2)
        stand.run(S['MENU_WORK'])
        self.assertEqual(stand.peek16(S['COUNT']), 32 * 32)
        for row in range(1, 33):
            with self.subTest(строка=row):
                record = 0xC000 + 512 * (row - 1)
                self.assertEqual(stand.peek(S['INDEX'] + row), record >> 8)
                name = bytes(stand.cpu.memory[S['LIST'] + 32 * (row - 1):S['LIST'] + 32 * row])
                self.assertEqual(name.decode('cp866').strip(), f'Plugin {row - 1:02d}')


class ReadError(unittest.TestCase):
    """.WMF не прочитался — полузагруженный плагин не запускается.

    Раньше LOAD_PLUGIN не проверял ни GIPAG, ни LOAD512, и WC исполнял мусор.
    Теперь запись снова «не загружена», страницы возвращены пулу, а WC получает
    страницу самого менеджера — его установщик просто выйдет.
    """

    def load(self, fail_at):
        stand = Stand([dict(item) for item in MIXED], own=1, restop=2, ppgm=2)
        blocks = S['COPY'] + S['REC_BLOCKS']
        for offset, value in enumerate((0, 2, 0, 0)):          # страница 0: два сектора
            stand.poke(blocks + offset, value)
        stand.poke(S['COPY'] + S['REC_ENTRY'], 0x12)
        stand.fail_at = fail_at
        stand.cpu.hl = 0xC000 + 512                             # ChkDsk FAT32, пять страниц
        stand.run(S['LOAD_PLUGIN'])
        return stand

    def test_successful_load_takes_pages(self):
        stand = self.load(None)
        self.assertEqual(stand.file_calls, ['GIPAG', 'LOAD512', 'LOAD512'])
        self.assertEqual(stand.cpu.a, 2)
        self.assertEqual(stand.headers()[1]['base'], 2)
        self.assertEqual(stand.peek(S['PPGM']), 7)
        self.assertEqual(stand.file_streams, [S['INIPG']] * 3, 'читаем в потоке каталога WC')
        self.assertEqual(stand.peek(0x6000), PANEL_STREAM, 'поток панели вернулся')

    def test_any_read_error_cancels_the_launch(self):
        for fail_at, name in enumerate(('GIPAG', 'LOAD512 заголовка', 'LOAD512 блока')):
            with self.subTest(отказ=name):
                stand = self.load(fail_at)
                self.assertEqual(len(stand.file_calls), fail_at + 1, 'после отказа не читаем дальше')
                self.assertEqual(stand.cpu.a, 1, 'WC получает страницу менеджера')
                self.assertEqual(stand.peek(S['COPY'] + S['REC_ENTRY']), 0)
                self.assertEqual(stand.headers()[1]['base'], 0xFF, 'запись снова не загружена')
                self.assertEqual(stand.peek(S['PPGM']), 2, 'страницы вернулись пулу')
                self.assertEqual(stand.peek(S['TRACE']), 4)
                self.assertEqual(stand.peek(0x6000), PANEL_STREAM, 'поток панели вернулся')


class Registers(unittest.TestCase):
    """Шлюз запуска отдаёт плагину DE и IX такими, какими их оставил WC.

    GOPLG кладёт в DE старшее слово размера файла, а L6011_244 после шлюза
    читает по IX описатель панели. Менеджер портил DE копированием заголовка,
    и редактор F4 на любой файл отвечал «Read ERROR»: размер #DCxxxxxx.
    """

    SIZE_HIGH = 0x000A                          # файл больше 640 КиБ
    PANEL = 0x7EC4                              # WINDO2 — правая панель

    def launch(self, base):
        records = [dict(item) for item in MIXED]
        records[4].update(base=base)            # TXT Editor, две страницы
        stand = Stand(records, own=1, restop=2, ppgm=4)
        header = bytearray(512)                 # заголовок в LOBU, как его кладёт GOPLG
        name = S['REC_NAME']
        header[name:name + 32] = 'TXT Editor'.encode('cp866').ljust(32, b' ')
        header[S['REC_PAGES']] = 2
        header[S['REC_BLOCKS']:S['REC_BLOCKS'] + 4] = bytes((0, 2, 0, 0))
        lobu = S['LOBU'] - 0x8000
        stand.pages[WC_PAGE][lobu:lobu + 512] = header
        stand.map(0x8000, WC_PAGE)              # шлюз: WC в #8000, менеджер в #C000
        stand.map(0xC000, stand.own)
        stand.cpu.de = self.SIZE_HIGH
        stand.cpu.ix = self.PANEL
        stand.run(S['PLM_ENTRY'])
        return stand

    def check(self, stand, page):
        self.assertEqual(stand.cpu.a, page, 'страница входа плагина')
        self.assertEqual(stand.cpu.de, self.SIZE_HIGH, 'старшее слово размера файла')
        self.assertEqual(stand.cpu.ix, self.PANEL, 'описатель панели')

    def test_resident_plugin(self):
        stand = self.launch(base=5)
        self.check(stand, S['PLGPG'] + 5)
        self.assertEqual(stand.file_calls, [], 'плагин в памяти — диск не читаем')

    def test_plugin_loaded_from_disk(self):
        stand = self.launch(base=0xFF)
        self.check(stand, S['PLGPG'] + 4)
        self.assertEqual(stand.file_calls, ['GIPAG', 'LOAD512', 'LOAD512'])

    def test_registration_gives_8000_back_to_wc(self):
        # Перехват WALK (#97A4, страница WC) после вызова идёт на JP LGW по
        # #97AC: в окне #8000 к этому времени обязана снова стоять страница WC.
        stand = Stand([dict(item) for item in MIXED], own=1, restop=2, ppgm=2)
        stand.map(0x8000, WC_PAGE)
        stand.map(0xC000, stand.own)
        stand.cpu.de = self.SIZE_HIGH
        stand.cpu.ix = self.PANEL
        stand.run(S['PLM_REGISTER'])
        self.assertEqual(stand.window[0x8000], WC_PAGE, 'возврат в код WC попал бы в менеджер')
        self.assertEqual(stand.cpu.de, self.SIZE_HIGH)
        self.assertEqual(stand.cpu.ix, self.PANEL)
        self.assertEqual(stand.headers()[-1]['base'], 0xFF, 'MaxiClock только зарегистрирован')
        self.assertEqual(stand.file_calls, [], 'нерезидент при регистрации не читается')


if __name__ == '__main__':
    unittest.main()
