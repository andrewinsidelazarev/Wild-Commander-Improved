"""Процедуры FORMAT.WMF на Z80 против эталона fat32_layout.py.

Обвязку sectors_harness.asm собирает build.ps1 плагина. Проверяются:
* ParseIdentify — ёмкость и геометрия по ответу IDENTIFY: LBA28 и диск без
  LBA (цилиндры * головки * секторы), неверная геометрия — отказ;
* ReadCsd — ёмкость SD по CSD v1 и v2 (порт SPI подставной), v3 — отказ;
* BuildMbr, BuildBoot, BuildFsinfo, BuildFatHead, BuildRootLabel после
  Layout — побайтно как эталон, для SD, IDE с LBA и без (тип #0B, поля CHS
  по геометрии диска), с меткой и без.
"""
from pathlib import Path
import re
import unittest

import z80

import fat32_layout as ref

HERE = Path(__file__).resolve().parent
BUILD = HERE.parent / 'build'
STACK = 0x7F00
KIND = {ref.SD: 0, ref.IDE_LBA: 1, ref.IDE_CHS: 2}


def symbols():
    text = (BUILD / 'sectors_harness.sym').read_text(encoding='utf-8')
    return {m[1]: int(m[2], 16) for line in text.splitlines()
            if (m := re.match(r'^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$', line))}


class Plugin:
    def __init__(self):
        path = BUILD / 'sectors_harness.bin'
        if not path.exists():
            raise unittest.SkipTest('нет build/sectors_harness.bin: сначала build.ps1 плагина')
        self.sym = symbols()
        self.cpu = z80.Z80Machine()
        self.cpu.set_memory_block(0x8000, path.read_bytes())
        self.spi = []
        self.cpu.set_input_callback(self.port_in)
        self.cpu.set_output_callback(lambda port, value: None)

    def port_in(self, port):
        if port & 0xFF == 0x57:
            return self.spi.pop(0) if self.spi else 0xFF
        return 0xFF

    def call(self, name):
        cpu, s = self.cpu, self.sym
        cpu.pc, cpu.sp = s[name], STACK
        cpu.memory[STACK:STACK + 2] = s['Stop'].to_bytes(2, 'little')
        cpu.set_breakpoint(s['Stop'])
        for _ in range(500):
            cpu.ticks_to_stop = 1000000
            if cpu.run() & 2 and cpu.pc == s['Stop']:
                return bool(cpu.f & 1)                       # CF
        raise AssertionError(f'{name} не вернулся')

    def put(self, name, value, size):
        a = self.sym[name]
        self.cpu.memory[a:a + size] = value.to_bytes(size, 'little') if isinstance(value, int) else value

    def get(self, name, size):
        a = self.sym[name]
        return bytes(self.cpu.memory[a:a + size])

    def num(self, name, size=4):
        return int.from_bytes(self.get(name, size), 'little')

    def sector(self):
        return bytes(self.cpu.memory[0xAE00:0xB000])


def identify(lba=None, chs=None, model=b'TEST DISK'):
    w = [0] * 256
    m = model.ljust(40)
    for i in range(20):
        w[27 + i] = m[2 * i] << 8 | m[2 * i + 1]
    if lba is not None:
        w[49] = 0x0200
        w[60], w[61] = lba & 0xFFFF, lba >> 16
        w[1], w[3], w[6] = 16383, 16, 63
    else:
        w[1], w[3], w[6] = chs
    return b''.join(v.to_bytes(2, 'little') for v in w)


def csd_v2(sectors):
    c_size = sectors // 1024 - 1
    b = bytearray(16)
    b[0] = 0x40
    b[7], b[8], b[9] = (c_size >> 16) & 0x3F, (c_size >> 8) & 0xFF, c_size & 0xFF
    return bytes(b)


def csd_v1(c_size, mult, bl_len):
    v = 0
    v |= (bl_len & 15) << 80
    v |= (c_size & 0xFFF) << 62
    v |= (mult & 7) << 47
    return v.to_bytes(16, 'big')


class SectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.p = Plugin()

    def test_identify_lba(self):
        p = self.p
        for total in (262144, 1 << 21, 0x0FFFFFFF):
            p.cpu.memory[0xAA00:0xAC00] = identify(lba=total, model=b'UNREAL HDD')
            self.assertFalse(p.call('ParseIdentify'))
            self.assertEqual((p.num('DevKind', 1), p.num('DevSize')), (1, total))
            self.assertEqual(p.get('Model', p.num('ModelLen', 1)), b'UNREAL HDD')

    def test_identify_chs(self):
        p = self.p
        for c, h, s in ((615, 4, 17), (1024, 16, 63), (65535, 16, 63), (200, 16, 127), (1, 1, 1)):
            p.cpu.memory[0xAA00:0xAC00] = identify(chs=(c, h, s))
            self.assertFalse(p.call('ParseIdentify'), (c, h, s))
            got = (p.num('DevKind', 1), p.num('DevSize'), p.num('DevHeads', 1), p.num('DevSpt', 1),
                   p.num('Cylinders', 2))
            self.assertEqual(got, (2, c * h * s, h, s, c))

    def test_identify_bad(self):
        p = self.p
        for c, h, s in ((100, 0, 63), (100, 17, 63), (100, 16, 0), (100, 16, 128), (0, 16, 63)):
            p.cpu.memory[0xAA00:0xAC00] = identify(chs=(c, h, s))
            self.assertTrue(p.call('ParseIdentify'), (c, h, s))

    def test_csd(self):
        p = self.p
        cases = [(csd_v2(15523840), 15523840), (csd_v2(62521344), 62521344), (csd_v2(1024), 1024),
                 (csd_v1(4095, 7, 10), 4096 * 512 * 1024 // 512), (csd_v1(3871, 7, 9), 3872 * 512),
                 (csd_v1(1000, 3, 9), 1001 * 32)]
        for dev in (1, 6):
            for csd, sectors in cases:
                p.put('Dev', dev, 1)
                p.spi = [0xFF, 0x00, 0xFF, 0xFF, 0xFE] + list(csd) + [0x12, 0x34]
                self.assertFalse(p.call('ReadCsd'), csd.hex())
                self.assertEqual(p.num('DevSize'), sectors, csd.hex())
        p.spi = [0xFF, 0x00, 0xFE, 0x80] + [0] * 17                         # CSD v3
        self.assertTrue(p.call('ReadCsd'))
        p.spi = [0xFF] * 40                                                  # нет R1
        self.assertTrue(p.call('ReadCsd'))
        p.spi = [0x05]                                                       # R1 с ошибкой
        self.assertTrue(p.call('ReadCsd'))

    def test_sd_type(self):
        p = self.p
        line2 = p.sym['Line2']
        for csd, sectors, name in ((0x00, 3970048, b'SDSC card'), (0x40, 15523840, b'SDHC card'),
                                   (0x40, 0x04000000, b'SDHC card'), (0x40, 0x04000001, b'SDXC card'),
                                   (0x40, 250069680, b'SDXC card')):
            p.put('DevKind', 0, 1)
            p.put('CsdVersion', csd, 1)
            p.put('DevSize', sectors, 4)
            p.call('InfoLine')
            got = bytes(p.cpu.memory[line2:line2 + 16]).split(b'\0')[0]
            self.assertEqual(got, name, (csd, sectors))

    def test_progress_bar(self):
        p = self.p
        p.cpu.memory[0x6006] = 0xC9                                 # API WC — заглушка RET
        bar_at = p.sym['Line'] + (50 - 40) // 2
        for total in (37, 1000, 16422, 8 * 1024 * 1024):
            p.put('BarPct', 0xFF, 1)
            p.put('Total', total, 4)
            last = -1
            for step in range(0, 101, 5):
                done = total * step // 100
                p.put('Done', done, 4)
                p.call('DrawBar')
                pct = p.num('BarPct', 1)
                p.cpu.a = pct
                p.call('BarLine')
                bar = bytes(p.cpu.memory[bar_at:bar_at + 40])
                cells = bar.count(0xDB)
                with self.subTest(total=total, step=step):
                    self.assertGreaterEqual(pct, last)                 # не назад
                    self.assertLessEqual(abs(pct - done * 100 // total), 1)
                    self.assertEqual(bar, b'\xDB' * cells + b'\xB1' * (40 - cells))
                    self.assertEqual(cells, pct * 2 // 5)
                last = pct
            self.assertEqual((last, cells), (100, 40))

    def test_label_chars(self):
        p = self.p
        allowed = set(b'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_')
        for code in range(256):
            p.cpu.a = code
            bad = p.call('LabelChar')
            want = code - 32 if 0x61 <= code <= 0x7A else code
            self.assertEqual(bad, want not in allowed, hex(code))
            if not bad:
                self.assertEqual(p.cpu.a, want, hex(code))

    def build(self, kind, device, spc=None, chs=None, label=b''):
        p = self.p
        p.put('DevKind', KIND[kind], 1)
        p.put('DevSize', device, 4)
        heads = spt = None
        if chs:
            heads, spt = chs
            p.put('DevHeads', heads, 1)
            p.put('DevSpt', spt, 1)
        p.put('SpcReq', spc or 0, 1)
        self.assertFalse(p.call('Layout'))
        lay = ref.layout(kind, device, spc, heads, spt)
        serial = 0x1234ABCD ^ device
        p.put('Serial', serial, 4)
        p.put('Label', label.ljust(11, b'\0'), 11)
        p.put('LabelLen', len(label), 1)
        padded = label.ljust(11) if label else b'NO NAME    '
        p.call('BuildMbr')
        self.assertEqual(p.sector(), ref.mbr(lay, serial), 'MBR')
        p.call('BuildBoot')
        self.assertEqual(p.sector(), ref.boot_sector(lay, serial, padded), 'загрузочный')
        p.call('BuildFsinfo')
        self.assertEqual(p.sector(), ref.fsinfo(lay), 'FSInfo')
        p.call('BuildFatHead')
        self.assertEqual(p.sector(), ref.fat_head(), 'FAT')
        if label:
            p.call('BuildRootLabel')
            self.assertEqual(p.sector()[:32], ref.label_entry(padded))
            self.assertEqual(p.sector()[32:], bytes(480))

    def test_sectors(self):
        for kind, device, spc, chs, label in (
                (ref.SD, 15523840, None, None, b''), (ref.SD, 62521344, 64, None, b'EVO'),
                (ref.SD, 250069680, None, None, b'BIG CARD 01'),
                (ref.IDE_LBA, 262144, None, None, b'EVO TEST'), (ref.IDE_LBA, 0x10000000, None, None, b''),
                (ref.IDE_CHS, 615 * 4 * 17 * 3, None, (4, 17), b'OLD'),
                (ref.IDE_CHS, 1024 * 16 * 63, None, (16, 63), b''),
                (ref.IDE_CHS, 1600 * 16 * 63, 8, (16, 63), b'CYL1023 CAP'),
                (ref.IDE_CHS, 980 * 10 * 17, 1, (10, 17), b'A')):
            with self.subTest(kind=kind, device=device, spc=spc, label=label):
                self.build(kind, device, spc, chs, label)


if __name__ == '__main__':
    unittest.main()
