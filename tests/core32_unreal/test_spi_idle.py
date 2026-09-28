"""Шина SPI в покое до первого обращения WC (2026-09-26).

SD-карта и FT812 платы VDAC2 делят шину Z-Controller: #77 — выбор устройств,
#57 — данные. Аппаратный сброс TS-Config её не нормализует: защёлка #77 может
остаться с выбранным FT812 (#07) или SD. Установщик WildDOS (сразу после INIT,
до FINI, где WC впервые читает карту) выполняет последовательность SpiBusIdle
порта Zuma Deluxe для VDAC2/FT812: #77=#03, 16 байт #FF в #57, снова #77=#03.
Здесь исполняется настоящий установщик из собранного boot.$C: сверяется запись
в порты, её место до распаковки расширения и то, что установка не изменилась.
"""
from pathlib import Path
import unittest

import runtime_image
import test_boot_resources as br

ROOT = Path(__file__).resolve().parents[2]
SPI_PORTS = (0x0077, 0x0057)
EXT_PAGE = 0xE8                             # WC_PHYS_CORE32_EXT_PAGE
IDLE = [(0x0077, 0x03)] + [(0x0057, 0xFF)] * 16 + [(0x0077, 0x03)]


class SpiIdleAtStart(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.m = br.Machine()
        cls.m.call(cls.m.sym['WDOS.INSTALL_WILDDOS'], ix=0x4321)

    def test_idle_sequence(self):
        spi = [p for p in self.m.ports if p[0] in SPI_PORTS]
        self.assertEqual(spi, IDLE)

    def test_idle_before_any_other_port(self):
        # Первые записи установщика в порты — шина SPI, затем окно #C000.
        self.assertEqual(self.m.ports[:len(IDLE)], IDLE)
        # Часть 1 расширения, загрузочная страница, часть 2 (с 2026-09-27).
        self.assertEqual(self.m.ports[len(IDLE):],
                         [(0x13AF, EXT_PAGE), (0x13AF, 0x03), (0x13AF, EXT_PAGE), (0x13AF, 0x03)])

    def test_install_unchanged(self):
        m, sym = self.m, self.m.sym
        start, end = sym['WDOS.START'], sym['WDOS.END']
        runtime = (ROOT / 'Build/CORE32_EXT.bin').read_bytes()
        ext_sym = br.ext_symbols()
        core, page = runtime_image.expected_pages(m.boot, runtime, sym, ext_sym)
        self.assertEqual(bytes(m.cpu.memory[start:end]), core,
                         'ядро по #4000 и резидентный блок на месте драйверов')
        self.assertEqual(m.page(EXT_PAGE)[:len(runtime)], page,
                         'расширение и драйверы в странице #E8')
        self.assertEqual(m.mapped, 0x03, 'окно #C000 возвращено')
        self.assertEqual(m.cpu.ix, 0x4321, 'IX сохранён')
        self.assertEqual(m.cpu.sp, 0x5FFE, 'стек сбалансирован')


if __name__ == '__main__':
    unittest.main(verbosity=2)
