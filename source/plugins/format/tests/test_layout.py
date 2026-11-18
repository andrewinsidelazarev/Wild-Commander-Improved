"""Расчёт разметки FORMAT.WMF на Z80 (layout.inc) против эталона fat32_layout.py.

Обвязку layout_harness.asm собирает build.ps1 плагина (build/layout_harness.bin
и .sym). Перебираются виды устройств (SD, IDE с LBA и без), ёмкости от
меньше допустимого до 2 ТиБ, все размеры кластера и «авто»; сверяются все
выходные поля и коды отказа.
"""
from pathlib import Path
import random
import re
import unittest

import z80

import fat32_layout as ref

HERE = Path(__file__).resolve().parent
BUILD = HERE.parent / 'build'
KIND = {ref.SD: 0, ref.IDE_LBA: 1, ref.IDE_CHS: 2}
ERRORS = {'device too small': 1, 'too small for FAT32': 1, 'too few clusters for FAT32': 2,
          'too many clusters for FAT32': 3, 'reserved area too long': 4}


def symbols():
    text = (BUILD / 'layout_harness.sym').read_text(encoding='utf-8')
    return {m[1]: int(m[2], 16) for line in text.splitlines()
            if (m := re.match(r'^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$', line))}


class Z80Layout:
    def __init__(self):
        path = BUILD / 'layout_harness.bin'
        if not path.exists():
            raise unittest.SkipTest('нет build/layout_harness.bin: сначала build.ps1 плагина')
        self.code = path.read_bytes()
        self.sym = symbols()

    def run(self, kind, device, spc=None, heads=0, spt=0):
        cpu = z80.Z80Machine()
        cpu.set_memory_block(0x8000, self.code)
        s, m = self.sym, cpu.memory
        m[s['DevKind']] = KIND[kind]
        m[s['DevSize']:s['DevSize'] + 4] = device.to_bytes(4, 'little')
        m[s['DevHeads']], m[s['DevSpt']] = heads, spt
        m[s['SpcReq']] = spc or 0
        cpu.pc, cpu.sp = s['Run'], 0x7F00
        for _ in range(200):
            cpu.ticks_to_stop = 1000000
            cpu.run()
            if cpu.halted:
                break
        else:
            raise AssertionError('Layout не вернулся')
        get = lambda name, size=4: int.from_bytes(m[s[name]:s[name] + size], 'little')
        result = m[s['Result']]
        if result:
            return result
        return dict(start=get('PartStart'), length=get('PartLength'), spc=m[s['Spc']],
                    reserved=get('Reserved', 2), fat=get('FatSize'), clusters=get('Clusters'),
                    data=get('DataStart'), heads=m[s['GeoHeads']], spt=m[s['GeoSpt']])


def expected(kind, device, spc=None, heads=None, spt=None):
    try:
        lay = ref.layout(kind, device, spc, heads, spt)
    except ref.LayoutError as error:
        return ERRORS[str(error)]
    return dict(start=lay.start, length=lay.length, spc=lay.spc, reserved=lay.reserved, fat=lay.fat,
                clusters=lay.clusters, data=lay.data, heads=lay.heads, spt=lay.spt)


GIB = 1 << 21
SIZES = [40000, 66600 + 8192, 66601 + 8192, 70000, 131072, 262144, 532480 + 8192, 532481 + 8192,
         1 << 20, 2 * GIB - 1, 2 * GIB, 7741440, 15523840, 8 * GIB, 16 * GIB + 8192, 16 * GIB + 8193,
         31116288, 32 * GIB + 8193, 62521344, 64 * GIB, 124735488, 128 * GIB, 250069680, 512 * GIB,
         (1 << 32) - 1]


class LayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.z = Z80Layout()

    def check(self, kind, device, spc=None, heads=None, spt=None):
        got = self.z.run(kind, device, spc, heads or 0, spt or 0)
        want = expected(kind, device, spc, heads, spt)
        self.assertEqual(got, want, (kind, device, spc, heads, spt))
        return got

    def test_sd_auto(self):
        for size in SIZES:
            with self.subTest(size=size):
                self.check(ref.SD, size)

    def test_ide_lba_auto_and_lba28(self):
        for size in SIZES:
            with self.subTest(size=size):
                got = self.check(ref.IDE_LBA, size)
                if isinstance(got, dict):
                    self.assertLessEqual(got['start'] + got['length'], ref.LBA28)

    def test_every_cluster_size(self):
        for kind in (ref.SD, ref.IDE_LBA):
            for size in (200000, 1 << 20, 15523840, 62521344, 250069680):
                for spc in (1, 2, 4, 8, 16, 32, 64):
                    with self.subTest(kind=kind, size=size, spc=spc):
                        self.check(kind, size, spc)

    def test_chs(self):
        for c, h, s in ((615, 4, 17), (1024, 16, 63), (980, 10, 17), (1001, 15, 17), (782, 16, 63),
                        (2100, 16, 63), (16383, 16, 63), (65535, 16, 63), (1024, 1, 1)):
            for spc in (None, 1, 8, 64):
                with self.subTest(c=c, h=h, s=s, spc=spc):
                    self.check(ref.IDE_CHS, c * h * s, spc, h, s)

    def test_random(self):
        rnd = random.Random(20261117)
        for _ in range(300):
            kind = rnd.choice([ref.SD, ref.IDE_LBA, ref.IDE_CHS])
            spc = rnd.choice([None, None, 1, 2, 4, 8, 16, 32, 64])
            if kind == ref.IDE_CHS:
                h, s = rnd.randint(1, 16), rnd.randint(1, 63)
                c = rnd.randint(1, 65535)
                with self.subTest(kind=kind, c=c, h=h, s=s, spc=spc):
                    self.check(kind, c * h * s, spc, h, s)
            else:
                size = rnd.choice([rnd.randint(1, 1 << 24), rnd.randint(1, 1 << 32) - 1])
                with self.subTest(kind=kind, size=size, spc=spc):
                    self.check(kind, size, spc)


if __name__ == '__main__':
    unittest.main()
