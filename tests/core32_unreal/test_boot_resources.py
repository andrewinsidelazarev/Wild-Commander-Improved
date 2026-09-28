"""Ресурсы запуска из HR-потоков boot.$C (2026-09-26).

Шрифт FONT32L3 и пара распаковщиков MLZ50F+DEHR1M лежат в образе упакованными,
а VDAC (блок VDAC_RESOURCES) распаковывает их DEHR ядра (#5AAA): шрифт — в
страницы #01 и #09 с #C000, пару — в #01 с #FE00. Здесь исполняются настоящие
установщик WildDOS (он ставит ядро с DEHR) и сам блок VDAC с переключением
окна #C000 через порт #13AF; байты страниц сверяются с исходными файлами.
"""
from pathlib import Path
import re
import unittest

import z80

ROOT = Path(__file__).resolve().parents[2]
STOP = 0xFF00
FILL = {0x01: 0x5A, 0x09: 0x3C, 0xE8: 0xCC}


def symbols():
    text = (ROOT / 'Build/boot.sym').read_text(encoding='utf-8')
    return {m[1]: int(m[2], 16) for line in text.splitlines()
            if (m := re.match(r'^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$', line))}


def ext_symbols():
    text = (ROOT / 'Build/CORE32_EXT.sym').read_text(encoding='utf-8')
    return {m[1]: int(m[2], 16) for line in text.splitlines()
            if (m := re.match(r'^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$', line))}


def run_until(cpu, address):
    cpu.set_breakpoint(address)
    for _ in range(2000):
        cpu.ticks_to_stop = 100000
        if not cpu.run() & 2:
            continue
        if cpu.pc == address:
            cpu.clear_breakpoint(address)
            return
        raise AssertionError(('неожиданная остановка', hex(cpu.pc)))
    raise AssertionError(('не дошли', hex(cpu.pc), hex(address)))


class Machine:
    """Z80 с окном #C000 по страницам; прочие порты страниц записываются."""

    def __init__(self):
        self.sym = symbols()
        self.boot = (ROOT / 'exe/boot.$C').read_bytes()
        self.cpu = z80.Z80Machine()
        self.cpu.set_memory_block(0x6011, self.boot[17:])
        self.banks = {3: bytes(self.cpu.memory[0xC000:])}
        for page, value in FILL.items():
            self.banks[page] = bytes([value]) * 0x4000
        self.mapped = 3
        self.ports = []
        self.cpu.set_input_callback(self.inp)
        self.cpu.set_output_callback(self.out)

    def inp(self, port):
        assert port == 0x13AF, hex(port)
        return self.mapped

    def out(self, port, value):
        self.ports.append((port, value))
        if port != 0x13AF:
            return
        self.banks[self.mapped] = bytes(self.cpu.memory[0xC000:])
        self.cpu.set_memory_block(0xC000, self.banks[value])
        self.mapped = value

    def call(self, address, sp=0x5FFC, ix=0x1234):
        cpu = self.cpu
        cpu.sp, cpu.pc, cpu.ix = sp, address, ix
        cpu.memory[sp:sp + 2] = STOP.to_bytes(2, 'little')
        run_until(cpu, STOP)
        self.banks[self.mapped] = bytes(cpu.memory[0xC000:])

    def page(self, number):
        return self.banks[number]


class BootResources(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.m = Machine()
        m = cls.m
        m.call(m.sym['WDOS.INSTALL_WILDDOS'])           # ядро с DEHR и расширение
        assert m.mapped == 3
        cls.page2_before = bytes(m.cpu.memory[0x8000:0xC000])
        m.ports.clear()
        m.call(m.sym['WCINI.VDAC_RESOURCES'], sp=0x5FF0, ix=0x4321)
        cls.font = (ROOT / 'source/FONT32L3.CDB').read_bytes()
        cls.mlz = (ROOT / 'source/MLZ50F.CCB').read_bytes()
        cls.dehr = (ROOT / 'source/DEHR1M.CCB').read_bytes()

    def test_font_in_both_pages(self):
        for page in (0x01, 0x09):
            with self.subTest(page=hex(page)):
                self.assertEqual(self.m.page(page)[:0x800], self.font)

    def test_decoders_at_fe00(self):
        page = self.m.page(0x01)
        self.assertEqual(page[0x3E00:0x3EE9], self.mlz, 'MLZ50F по #FE00')
        self.assertEqual(page[0x3EE9:0x4000], self.dehr, 'DEHR1M по #FEE9')

    def test_both_extension_parts_installed(self):
        # С 2026-09-27 расширение — две части: вторая лежит в хвосте файла
        # (загрузочная страница окна #C000), установщик переносит её поток на
        # место потока части 1 и распаковывает в #E8, затем драйверы ядра — в
        # #E8, резидентный блок — на их место. Страница #E8 и ядро — побайтно.
        import runtime_image
        runtime = (ROOT / 'Build/CORE32_EXT.bin').read_bytes()
        core, page = runtime_image.expected_pages(self.m.boot, runtime, self.m.sym, ext_symbols())
        self.assertEqual(self.m.page(0xE8)[:len(runtime)], page)
        self.assertEqual(self.m.page(0xE8)[len(runtime):], bytes([FILL[0xE8]]) * (0x4000 - len(runtime)))
        self.assertEqual(bytes(self.m.cpu.memory[0x4000:0x4000 + len(core)]), core)

    def test_nothing_else_touched(self):
        self.assertEqual(self.m.page(0x01)[0x800:0x3E00], bytes([FILL[0x01]]) * (0x3E00 - 0x800))
        self.assertEqual(self.m.page(0x09)[0x800:], bytes([FILL[0x09]]) * (0x4000 - 0x800))
        self.assertEqual(bytes(self.m.cpu.memory[0x8000:0xC000]), self.page2_before,
                         'источники в окне #8000 не меняются')

    def test_registers_and_pages(self):
        cpu = self.m.cpu
        self.assertEqual(cpu.ix, 0x4321, 'IX сохранён')
        self.assertEqual(cpu.sp, 0x5FF2, 'стек сбалансирован')
        self.assertEqual(self.m.mapped, 0x09, 'в #C000 — последняя страница шрифта, как прежде')
        self.assertEqual([p for p in self.m.ports if p[0] == 0x13AF], [(0x13AF, 0x01), (0x13AF, 0x09)])
        self.assertIn((0x10AF, 0xF0), self.m.ports, 'MNG0: окно #0000 — PNLPG')

    def test_packed_streams_are_smaller(self):
        sym = self.m.sym
        font = sym['DECODERS_PACKED'] - sym['FONT32L3_PACKED']
        decoders = sym['LB59F'] - sym['DECODERS_PACKED']
        self.assertLess(font, 0x800)
        self.assertLess(decoders, 0x200)
        self.assertLessEqual(sym['WDOS_EXTENSION_PACKED_END'], 0xBF60)


class TruncatedLoad(unittest.TestCase):
    """Файл дочитан не до конца (2026-09-27): загрузчик с прежним пределом
    в 124 сектора оставил бы на месте части 2 расширения чужие байты, и DEHR
    развернул бы их в #E8. Установщик сверяет метку сборки за потоком части 2
    (WDOS_EXTENSION2_MARK): нет её — красный бордюр (порт #FE, 2) и DI:HALT;
    часть 2 не распаковывается, резидентный блок не ставится."""

    def install(self, sectors):
        m = Machine()
        m.cpu.memory[0x6011:0x10000] = bytes(0x10000 - 0x6011)
        m.cpu.set_memory_block(0x6011, m.boot[17:17 + sectors * 256])
        m.banks[3] = bytes(m.cpu.memory[0xC000:])
        cpu = m.cpu
        halt = m.sym['WDOS_TAIL_MISSING'] + 5                  # DI, LD A,2, OUT (#FE),A — HALT
        cpu.sp, cpu.pc, cpu.ix = 0x5FFC, m.sym['WDOS.INSTALL_WILDDOS'], 0x1234
        cpu.memory[0x5FFC:0x5FFE] = STOP.to_bytes(2, 'little')
        for point in (halt, STOP):
            cpu.set_breakpoint(point)
        for _ in range(2000):
            cpu.ticks_to_stop = 100000
            if cpu.run() & 2 and cpu.pc in (halt, STOP):
                break
        return m, cpu.pc == halt

    def test_whole_file_installs(self):
        # Последний сектор Hobeta не добит (boot.$C — до 32768 байт): весь файл —
        # это и неполный последний сектор.
        m, halted = self.install(-(-(len(Machine().boot) - 17) // 256))
        self.assertFalse(halted)
        self.assertNotIn((0x02FE, 2), m.ports)

    def test_short_file_stops(self):
        # С 2026-09-27 метка сверяется до любой распаковки: у недочитанного
        # файла чужие байты и на месте потока кода ядра — не ставится ничего.
        whole = -(-(len(Machine().boot) - 17) // 256)
        for sectors in (whole - 4, whole - 1):                   # без хвоста потока и без метки
            with self.subTest(sectors=sectors):
                m, halted = self.install(sectors)
                self.assertTrue(halted, 'установщик не остановился')
                self.assertIn((0x02FE, 2), m.ports, 'бордюр не красный')
                self.assertEqual(bytes(m.cpu._Z80State__iff1)[0], 0, 'остановка без DI')
                self.assertEqual(m.page(0xE8), bytes([FILL[0xE8]]) * 0x4000,
                                 'расширение распаковано из чужих байт')
                packed = m.sym['WDOS_EXTENSION_PACKED']
                self.assertEqual(bytes(m.cpu.memory[packed:packed + 256]),
                                 m.boot[packed - 0x6000:packed - 0x6000 + 256],
                                 'чужой хвост перенесён на место потока части 1')
                self.assertEqual(bytes(m.cpu.memory[0x4000:0x5BF2]), bytes(0x1BF2),
                                 'ядро поставлено из недочитанного файла')


class ClusterLoad(unittest.TestCase):
    """boot.$C не длиннее 32768 байт (2026-09-27). BIOS TS-Conf читает файл
    целыми кластерами с #6000: при кластере 32 КиБ второй кластер (64 КиБ с
    #6000) через #FFFF затирал #0000..#5FFF — экран, системные переменные и
    стек BIOS в странице 5, и машина падала до старта WC (стенд combo64:
    35345 байт, два кластера; опыт с меткой в остатке второго кластера нашёл
    её и за концом файла, и в #4000..#5FFF). Граница частей расширения — по
    месту: поток части 1 занимает всё до #BF60, остаток — в хвосте."""

    def test_file_fits_one_32k_cluster(self):
        boot = (ROOT / 'exe/boot.$C').read_bytes()
        self.assertLessEqual(len(boot), 0x8000)
        for size in (512 << k for k in range(7)):              # 512 байт .. 32 КиБ
            with self.subTest(кластер=size):
                loaded = -(-len(boot) // size) * size
                self.assertLessEqual(0x6000 + loaded, 0xE000, 'загрузка вышла за #DFFF')

    def test_header_counts_the_partial_sector(self):
        boot = (ROOT / 'exe/boot.$C').read_bytes()
        sym = symbols()
        length = sym['WDOS_BOOT_TAIL_END'] - 0x6011
        self.assertEqual(len(boot), 17 + length, 'последний сектор добит или файл обрезан')
        self.assertEqual(int.from_bytes(boot[11:13], 'little'), length)
        self.assertEqual(boot[14], -(-length // 256))
        self.assertEqual(int.from_bytes(boot[15:17], 'little'), (sum(boot[:15]) * 257 + 105) & 0xFFFF)

    def test_part1_stream_fills_its_room(self):
        # Граница — наибольшая, при которой поток части 1 ещё влезает до #BF60:
        # иначе хвост был бы длиннее, чем нужно.
        sym = symbols()
        room = 0xBF60 - sym['WDOS_EXTENSION_PACKED_END']
        self.assertGreaterEqual(room, 0)
        self.assertLess(room, 64, 'поток части 1 не занял своё место')
        self.assertLessEqual(sym['WDOS_BOOT_TAIL_END'], 0xE000)


class PackedCore(unittest.TestCase):
    """Код ядра CORE32 в boot.$C — HR-потоком (2026-09-27): драйверы DR1..DR4 и
    DEHR лежат как есть, код #4000..DR1 разворачивает DEHR при установке. Так
    файл короче на ~1,1 КиБ — место под предел 32768 байт (ClusterLoad)."""

    def test_layout(self):
        import runtime_image
        m = Machine()
        sym, boot, core = m.sym, m.boot, runtime_image.core_image()
        raw = sym['WDOS.DR1'] - 0x4000
        at = sym['WDOS.CORE32'] - 0x6000
        self.assertEqual(boot[at:at + len(core) - raw], core[raw:], 'драйверы и DEHR — как есть')
        packed = sym['WDOS_CORE_PACKED'] - 0x6000
        self.assertEqual(boot[packed:packed + 2], b'HR')
        self.assertLess(sym['WDOS_EXTENSION2_PACKED'] - sym['WDOS_CORE_PACKED'], raw - 1000,
                        'поток кода ядра не короче кода')

    def test_installer_unpacks_the_code(self):
        import runtime_image
        m = Machine()
        m.call(m.sym['WDOS.INSTALL_WILDDOS'])
        code = sym_code = m.sym['WDOS.DR1'] - 0x4000
        self.assertEqual(bytes(m.cpu.memory[0x4000:0x4000 + code]), runtime_image.core_image()[:sym_code])


class DriverSwap(unittest.TestCase):
    """DOS_SWP (2026-09-27): упакованные драйверы DR1..DR4 установщик
    переносит в страницу #E8 (DRIVERS_E8), на их место в ядре — резидентный
    блок расширения. ID_UNPACK_DRIVER распаковывает из #E8 тот же поток, что
    прежде из ядра: драйвер по #3800 (DRVR) побайтно как DEHR прежних байт DRx
    из файла, SELDEV получает прежний A (0 — master, 1 — slave). Исполняются
    настоящие установщик, шлюз, DOS_SWP и DEHR; SELDEV (#3800 — вход только
    что распакованного драйвера) подменён."""

    FILL = 0xEE

    @classmethod
    def setUpClass(cls):
        cls.m = Machine()
        cls.m.call(cls.m.sym['WDOS.INSTALL_WILDDOS'])
        cls.e8 = cls.m.page(0xE8)

    def reference(self, name):
        """DEHR прежнего потока DRx ядра — без установщика и расширения."""
        import runtime_image
        sym = self.m.sym
        cpu = z80.Z80Machine()
        cpu.set_memory_block(0x4000, runtime_image.core_image())
        cpu.memory[0x3800:0x4000] = bytes([self.FILL]) * 0x800
        cpu.sp, cpu.pc, cpu.hl, cpu.de = 0x5FFC, sym['WDOS.DEHR'], sym['WDOS.' + name], 0x3800
        cpu.memory[0x5FFC:0x5FFE] = STOP.to_bytes(2, 'little')
        run_until(cpu, STOP)
        return bytes(cpu.memory[0x3800:0x4000])

    def swap(self, a):
        m, cpu = self.m, self.m.cpu
        cpu.memory[0x3800:0x4000] = bytes([self.FILL]) * 0x800
        cpu.sp, cpu.pc, cpu.a, cpu.ix = 0x5FFC, m.sym['WDOS.DOS_SWP'], a, 0x4321
        cpu.memory[0x5FFC:0x5FFE] = STOP.to_bytes(2, 'little')
        seldev = m.sym['WDOS.SELDEV']
        for point in (seldev, STOP):
            cpu.set_breakpoint(point)
        selected, driver = [], None
        try:
            for _ in range(2000):
                cpu.ticks_to_stop = 100000
                if not cpu.run() & 2:
                    continue
                if cpu.pc == STOP:
                    break
                assert cpu.pc == seldev, hex(cpu.pc)
                selected.append((cpu.a, m.mapped))
                driver = bytes(cpu.memory[0x3800:0x4000])
                sp = cpu.sp                               # RET из подменённого SELDEV
                cpu.pc, cpu.sp = cpu.memory[sp] | cpu.memory[sp + 1] << 8, sp + 2
            else:
                raise AssertionError('DOS_SWP не вернулся')
        finally:
            for point in (seldev, STOP):
                cpu.clear_breakpoint(point)
        return selected, driver

    def test_every_device_gets_the_same_driver(self):
        cases = ((0, 'DR1', 0), (1, 'DR2', 0), (2, 'DR3', 0), (3, 'DR4', 0),
                 (4, 'DR4', 1), (5, 'DR1', 1), (6, 'DR2', 1))
        references = {}
        for a, name, slave in cases:
            with self.subTest(a=a, driver=name):
                if name not in references:
                    references[name] = self.reference(name)
                    self.assertNotEqual(references[name], bytes([self.FILL]) * 0x800)
                selected, driver = self.swap(a)
                self.assertEqual(selected, [(slave, 3)], 'SELDEV: A и страница #C000')
                self.assertEqual(driver, references[name], 'драйвер по #3800')
                self.assertEqual((self.m.cpu.ix, self.m.cpu.sp), (0x4321, 0x5FFE), 'IX и стек')
                self.assertEqual(self.m.mapped, 3, 'страница вызывающего не возвращена')
                self.assertEqual(self.m.page(0xE8), self.e8, 'страница #E8 изменилась')

    def test_drivers_moved_whole(self):
        # Все четыре потока — в DRIVERS_E8 подряд, как были в ядре; в ядре на их
        # месте теперь только резидентный блок и его остаток прежних байт.
        ext = ext_symbols()
        sym = self.m.sym
        start, count = sym['WDOS.DR1'], sym['WDOS.DEHR'] - sym['WDOS.DR1']
        self.assertEqual(ext['WDOS_EXT.DRIVERS_LENGTH'], count)
        import runtime_image
        core = runtime_image.core_image()
        drivers = ext['WDOS_EXT.DRIVERS_E8'] - 0xC000
        self.assertEqual(self.e8[drivers:drivers + count], core[start - 0x4000:start - 0x4000 + count])


if __name__ == '__main__':
    unittest.main(verbosity=2)
