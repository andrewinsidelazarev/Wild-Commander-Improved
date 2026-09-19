"""Реальный MKSG: wrap, нулевой хвост FAT, нехватка места и чужие цепочки."""
import unittest
import core32_machine as p
from core32_ramdisk import Volume


class AllocatorWrapTests(unittest.TestCase):
    def exercise(self, free, tail, no_space=False, count=6571):
        v = Volume(free=free)
        # Реальная FAT имеет нулевой неиспользуемый хвост. Эти записи нельзя
        # выделять: соответствующих секторов данных на устройстве нет.
        for cluster in range(v.limit, v.fat_sectors * 128):
            v.set_fat(cluster, 0)
        guards = tuple(c for c in (0xFEFF, 0xFF00, 0xFFFF, 0x10000, v.limit - 4)
                       if 3 + v.original_clusters <= c < v.limit)
        for cluster in guards:
            v.set_fat(cluster, 0x0FFFFFFF)
            start = (v.data_start + cluster - 2) * 512
            v.disk[start:start + 512] = bytes([cluster & 255]) * 512
        before = bytes(v.disk)
        hint = v.limit - tail
        p.h.put32(v.mem, v.core('FSTFRC'), hint)
        count = free - len(guards) + 1 if no_space else count
        size = count * 512 - 17
        v.cpu.hl, v.cpu.de = size & 65535, size >> 16
        p.run(v.cpu, v.core('MKSG'), {a: lambda cpu, f=f: f() for a, f in v.callbacks.items()})
        if no_space:
            self.assertEqual(v.cpu.a, 16)
            self.assertFalse(v.cpu.f & 0x40)
            self.assertEqual(bytes(v.disk), before, 'failed allocation must restore FAT and preserve all data')
        else:
            self.assertTrue(v.cpu.f & 0x40, (v.cpu.a, v.cpu.f, free, tail))
            cursor = p.h.get32(v.mem, v.core('FCTS'))
            chain = set()
            while cursor < 0x0FFFFFF8:
                self.assertTrue(3 + v.original_clusters <= cursor < v.limit, hex(cursor))
                self.assertNotIn(cursor, chain)
                self.assertNotIn(cursor, guards)
                chain.add(cursor)
                cursor = v.fat(cursor)
            self.assertEqual(len(chain), count)
            self.assertTrue(any(c < hint for c in chain), 'test must actually cross the end of the volume')
            for cluster in range(v.fat_sectors * 128):
                if cluster not in chain:
                    offset = v.fat_start * 512 + cluster * 4
                    self.assertEqual(v.disk[offset:offset + 4], before[offset:offset + 4], cluster)
            self.assertEqual(v.disk[v.data_start * 512:], before[v.data_start * 512:])

    def test_partial_and_exact_fat_sector_end(self):
        for free in (66000, 66301):
            for tail in (1, 1002):
                with self.subTest(free=free, tail=tail):
                    self.exercise(free, tail)

    def test_full_scan_rolls_back_without_touching_foreign_data(self):
        for free in (66000, 66301):
            with self.subTest(free=free):
                self.exercise(free, 1002, no_space=True)

    def test_buffer_and_32_bit_count_boundaries(self):
        for count in (2048, 2049, 0xFF01, 0xFFFF, 0x10000, 0x10001):
            with self.subTest(count=count):
                self.exercise(70000, 1, count=count)

    def test_full_disk_before_first_buffer_flush(self):
        for free in (0, 1, 3, 2048):
            with self.subTest(free=free):
                self.exercise(free, 1, no_space=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
