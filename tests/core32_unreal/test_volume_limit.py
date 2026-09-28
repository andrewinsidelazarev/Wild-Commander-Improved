"""Граница data-кластеров — своя у каждого тома.

Панели на разных устройствах монтируют разные тома, каждый в своей странице
потока (окно #0000). Граница аллокатора прежде лежала в общей странице
расширения: после монтирования большего тома VALIDATE_FREE_HINT меньшего
пропускал кластеры за концом его раздела, а после меньшего большой том
преждевременно «кончался». Исполняется собранное расширение: страница потока
моделируется областью #3000..#3FFF, которую тест подменяет при «переключении
панели», как это делает FRST.
"""
import unittest

import test_fat_allocator_hint as h

PAGE = slice(0x3000, 0x4000)                 # переменные ядра и буферы страницы потока


def mount(harness, total, first_data, fat_sectors):
    """Смонтировать том: BPB в LOBU, геометрия ядра, затем LOAD_FREE_HINT."""
    m, core = harness.memory, harness.core
    lobu = core['LOBU']
    m[lobu:lobu + 512] = bytes(512)
    h.put16(m, lobu + 19, 0)
    h.put32(m, lobu + 32, total)
    h.put32(m, core['SDFAT'], first_data)
    h.put16(m, core['SFAT'], 32)
    h.put32(m, core['BFTSZ'], fat_sectors)
    m[core['BSECPC']] = 1
    m[core['BFATS']] = 2
    m[core['FATFLAGS']] = 0
    h.put32(m, core['FSINF'], 1)
    harness.read_sector = h.make_fsinfo(0xFFFFFFFF)
    harness.sector_overrides.clear()
    harness.invoke('LOAD_FREE_HINT')
    return total - first_data + 2


def valid(harness, cluster):
    harness.machine.hl, harness.machine.de = cluster & 0xFFFF, cluster >> 16
    harness.invoke('VALIDATE_FREE_HINT')
    return bool(harness.machine.f & h.ZERO_FLAG)


class VolumeLimit(unittest.TestCase):

    def setUp(self):
        self.h = h.ExtensionHarness()
        m = self.h.memory
        # Малый том — как образ стенда: 96 760 кластеров, FAT на 756 секторов
        # (последний сектор FAT описывает ещё и кластеры за концом тома).
        self.small = mount(self.h, 98_304, 1_544, 756)
        self.small_page = bytes(m[PAGE])
        m[PAGE] = bytes(0x1000)
        self.big = mount(self.h, 409_600, 3_200, 3_200)
        self.big_page = bytes(m[PAGE])
        self.probe = self.small + 5          # за концом малого, внутри большого

    def test_small_volume_keeps_its_limit(self):
        self.h.memory[PAGE] = self.small_page
        self.assertTrue(valid(self.h, self.small - 1), 'последний кластер малого тома')
        self.assertFalse(valid(self.h, self.small), 'кластер за концом малого тома')
        self.assertFalse(valid(self.h, self.probe),
                         'граница большого тома пропустила кластер за концом малого')

    def test_big_volume_keeps_its_limit(self):
        self.h.memory[PAGE] = self.small_page
        mount(self.h, 98_304, 1_544, 756)    # малый смонтирован последним
        self.h.memory[PAGE] = self.big_page
        self.assertTrue(valid(self.h, self.probe),
                        'большой том «кончился» на границе малого')
        self.assertFalse(valid(self.h, self.big))


if __name__ == '__main__':
    unittest.main(verbosity=2)
