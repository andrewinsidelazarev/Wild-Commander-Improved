"""Драйверы IDE Nemo и SMUC с адресацией CHS (source/IDE_CHS.INC, 2026-11-17).

Исполняются собранные варианты Build/driver-runtime/DIDENEMO_CHS.bin и
DIDESMUC_CHS.bin (build.ps1, ключ IDE_CHS) по #3800, порты обслуживает модель
диска ATA. Диск с LBA (слово 49 IDENTIFY, бит 9) драйвер ведёт как прежде:
регистры — LBA28 и бит LBA в drive/head. Диск без LBA получает свою штатную
геометрию командой #91, а позиция — цилиндр, головку и сектор; обмен через
границы дорожек и цилиндров ведёт сам диск. Повторный DEVINI (панель
перемонтируется) снова проходит; неверная геометрия — отказ DEVINI.

Модель старого диска понимает регистры только как CHS: забытый бит LBA или
не та геометрия дают чужой сектор, и сверка данных это ловит. Штатные образы
(Build/driver-runtime/DIDENEMO.bin, DIDESMUC.bin) прогоняются на диске с LBA
тем же сценарием — поведение пути LBA у вариантов одинаковое.
"""
from pathlib import Path
import unittest

import z80

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / 'Build/driver-runtime'
STOP, STACK = 0xFF00, 0x5F00
BUFFER = 0x8000
DRVR = 0x3800
SELDEV, DEVINI, XPOZI, RDDSE, SDDSE = (DRVR + 3 * i for i in (0, 1, 3, 5, 6))


class Disk:
    """ATA-диск: регистры, IDENTIFY, #91, чтение #20 и запись #30 по секторам."""

    def __init__(self, cylinders, heads, spt, lba, sectors=None):
        self.cylinders, self.heads, self.spt, self.lba = cylinders, heads, spt, lba
        self.total = sectors or cylinders * heads * spt
        self.written = {}
        self.cur_heads, self.cur_spt = heads, spt          # штатный перевод
        self.reg = {'count': 1, 'sector': 1, 'cyll': 0, 'cylh': 0, 'drv': 0xA0}
        self.status, self.error = 0x50, 0
        self.buffer, self.pos, self.mode, self.left, self.address = bytearray(), 0, None, 0, 0
        self.latch = 0
        self.commands, self.addresses, self.init_params = [], [], []

    def identify(self):
        w = [0] * 256
        w[1], w[3], w[6] = self.cylinders, self.heads, self.spt
        w[49] = 0x0200 if self.lba else 0
        if self.lba:
            w[60], w[61] = self.total & 0xFFFF, self.total >> 16
        return b''.join(v.to_bytes(2, 'little') for v in w)

    def position(self):
        r = self.reg
        if self.lba and r['drv'] & 0x40:
            return ((r['drv'] & 15) << 24) | (r['cylh'] << 16) | (r['cyll'] << 8) | r['sector']
        # Старый диск: регистры — всегда CHS по текущему переводу.
        cylinder, head, sector = (r['cylh'] << 8) | r['cyll'], r['drv'] & 15, r['sector']
        if not 1 <= sector <= self.cur_spt or head >= self.cur_heads:
            return None
        return (cylinder * self.cur_heads + head) * self.cur_spt + sector - 1

    def command(self, value):
        self.commands.append(value)
        if value == 0xEC:
            self.buffer, self.pos, self.mode, self.left = bytearray(self.identify()), 0, 'read', 1
            self.status = 0x58
        elif value == 0x91:
            self.cur_heads = (self.reg['drv'] & 15) + 1
            self.cur_spt = self.reg['count'] or 256
            self.init_params.append((self.cur_heads, self.cur_spt))
            self.status = 0x50
        elif value in (0x20, 0x30):
            start = self.position()
            count = self.reg['count'] or 256
            self.addresses.append((value, start, count))
            if start is None or start + count > self.total:
                self.status, self.error = 0x51, 0x10            # IDNF
                return
            self.address, self.left = start, count
            if value == 0x20:
                self.mode = 'read'
                self.load()
            else:
                self.mode, self.buffer, self.pos = 'write', bytearray(), 0
            self.status = 0x58
        else:
            self.status, self.error = 0x51, 0x04                # ABRT

    def sector(self, lba):
        """Содержимое сектора: записанное или своё у каждого номера."""
        if lba in self.written:
            return self.written[lba]
        return bytes((lba * 131 + (lba >> 8) * 17 + i * 7) & 255 for i in range(512))

    def span(self, lba, count):
        return b''.join(self.sector(n) for n in range(lba, lba + count))

    def load(self):
        self.buffer = bytearray(self.sector(self.address))
        self.pos = 0

    def read_word(self):
        word = self.buffer[self.pos] | self.buffer[self.pos + 1] << 8
        self.pos += 2
        if self.pos == 512:
            self.left -= 1
            if self.mode == 'read' and self.left and self.buffer is not None and self.commands[-1] == 0x20:
                self.address += 1
                self.load()
            else:
                self.status, self.mode = 0x50, None
        return word

    def write_word(self, word):
        self.buffer += word.to_bytes(2, 'little')
        if len(self.buffer) == 512:
            self.written[self.address] = bytes(self.buffer)
            self.address += 1
            self.left -= 1
            self.buffer = bytearray()
            if not self.left:
                self.status, self.mode = 0x50, None


class Ports:
    """Порты интерфейса: Nemo — младший байт адреса, SMUC — #xxBE и #FFBA."""

    NEMO = {'data_lo': 0x10, 'data_hi': 0x11, 'count': 0x50, 'sector': 0x70, 'cyll': 0x90,
            'cylh': 0xB0, 'drv': 0xD0, 'cmd': 0xF0}
    SMUC = {'data_lo': 0xF8BE, 'data_hi': 0xD8BE, 'count': 0xFABE, 'sector': 0xFBBE, 'cyll': 0xFCBE,
            'cylh': 0xFDBE, 'drv': 0xFEBE, 'cmd': 0xFFBE}

    def __init__(self, disk, smuc):
        self.disk, self.smuc = disk, smuc
        table = self.SMUC if smuc else self.NEMO
        self.by_port = {v: k for k, v in table.items()}

    def key(self, port):
        if self.smuc:
            return self.by_port.get(port)
        return self.by_port.get(port & 0xFF)

    def read(self, port):
        if port == 0x00AF:
            return 3                                   # нет DMA TS-Conf: портовый путь
        name, d = self.key(port), self.disk
        if name == 'data_lo':
            word = d.read_word()
            d.latch = word >> 8
            return word & 0xFF
        if name == 'data_hi':
            return d.latch
        if name == 'cmd':
            return d.status
        if name in d.reg:
            return d.reg[name]
        return 0xFF

    def write(self, port, value):
        name, d = self.key(port), self.disk
        if self.smuc and port == 0xFFBA:
            return
        if name == 'cmd':
            d.command(value)
        elif name == 'data_hi':
            d.latch = value
        elif name == 'data_lo':
            d.write_word(value | d.latch << 8)
        elif name in d.reg:
            d.reg[name] = value


class Driver:
    def __init__(self, image, disk, smuc=False, slave=False):
        self.cpu = z80.Z80Machine()
        self.cpu.set_memory_block(DRVR, image)
        self.ports = Ports(disk, smuc)
        self.cpu.set_input_callback(self.ports.read)
        self.cpu.set_output_callback(self.ports.write)
        self.disk = disk
        self.call(SELDEV, a=1 if slave else 0)

    def call(self, address, a=0, hl=0, de=0):
        cpu = self.cpu
        cpu.a, cpu.hl, cpu.de = a, hl, de
        cpu.pc, cpu.sp = address, STACK
        cpu.memory[STACK:STACK + 2] = STOP.to_bytes(2, 'little')
        cpu.set_breakpoint(STOP)
        for _ in range(4000):
            cpu.ticks_to_stop = 200000
            if cpu.run() & 2 and cpu.pc == STOP:
                return cpu.f
            if cpu.halted:
                raise AssertionError(f'HALT в драйвере, #{cpu.pc:04X}')
        raise AssertionError(f'драйвер не вернулся, #{cpu.pc:04X}')

    def devini(self):
        return not self.call(DEVINI) & 0x40              # True — NZ (отказ)

    def read(self, lba, count):
        self.call(XPOZI, hl=lba & 0xFFFF, de=lba >> 16)
        self.call(RDDSE, a=count, hl=BUFFER)
        return bytes(self.cpu.memory[BUFFER:BUFFER + 512 * count])

    def write(self, lba, payload):
        count = len(payload) // 512
        self.cpu.memory[BUFFER:BUFFER + len(payload)] = payload
        self.call(XPOZI, hl=lba & 0xFFFF, de=lba >> 16)
        self.call(SDDSE, a=count, hl=BUFFER)


def image(name):
    path = RUNTIME / f'{name}.bin'
    if not path.exists():
        raise unittest.SkipTest(f'нет {path}: сначала build.ps1')
    return path.read_bytes()


class ChsCase:
    NAME, SMUC = None, False

    def disk(self, **kw):
        return Disk(**kw)

    def driver(self, disk, name=None, slave=False):
        return Driver(image(name or self.NAME), disk, self.SMUC, slave)

    def test_lba_disk_stays_lba(self):
        for name in (self.NAME, self.NAME.replace('_CHS', '')):
            disk = self.disk(cylinders=1024, heads=16, spt=63, lba=True, sectors=1 << 21)
            drv = self.driver(disk, name)
            self.assertFalse(drv.devini(), name)
            self.assertNotIn(0x91, disk.commands, name)
            for lba, count in ((0, 1), (62, 3), (1008, 2), ((1 << 21) - 2, 2)):
                self.assertEqual(drv.read(lba, count), disk.span(lba, count), (name, lba))
                self.assertTrue(disk.reg['drv'] & 0x40, name)   # бит LBA
            self.assertEqual([a[1] for a in disk.addresses], [0, 62, 1008, (1 << 21) - 2])

    def test_chs_disk_reads(self):
        disk = self.disk(cylinders=97, heads=16, spt=63, lba=False)
        drv = self.driver(disk)
        self.assertFalse(drv.devini())
        self.assertEqual(disk.init_params, [(16, 63)])
        self.assertFalse(disk.reg['drv'] & 0x40)
        last = disk.total - 1
        for lba, count in ((0, 1), (62, 1), (63, 1), (1007, 1), (1008, 1), (61, 4), (1006, 5), (last - 2, 3)):
            self.assertEqual(drv.read(lba, count), disk.span(lba, count), lba)
        self.assertEqual([a[1] for a in disk.addresses], [0, 62, 63, 1007, 1008, 61, 1006, last - 2])

    def test_chs_registers(self):
        disk = self.disk(cylinders=615, heads=4, spt=17, lba=False)
        drv = self.driver(disk, slave=True)
        self.assertFalse(drv.devini())
        lba = 614 * 4 * 17 + 3 * 17 + 16                    # последний сектор
        drv.read(lba, 1)
        r = disk.reg
        self.assertEqual((r['cylh'] << 8 | r['cyll'], r['drv'], r['sector']), (614, 0xB0 | 3, 17))

    def test_chs_disk_writes(self):
        disk = self.disk(cylinders=40, heads=8, spt=35, lba=False)
        drv = self.driver(disk)
        self.assertFalse(drv.devini())
        payload = bytes((i * 7 + 3) & 255 for i in range(512 * 6))
        start = 8 * 35 - 3                                   # через границу цилиндра
        drv.write(start, payload)
        self.assertEqual(sorted(disk.written), list(range(start, start + 6)))
        self.assertEqual(disk.span(start, 6), payload)
        self.assertEqual(drv.read(start - 1, 8), disk.sector(start - 1) + payload + disk.sector(start + 6))

    def test_devini_again(self):
        disk = self.disk(cylinders=97, heads=16, spt=63, lba=False)
        drv = self.driver(disk)
        self.assertFalse(drv.devini())
        self.assertFalse(drv.devini())                      # перемонтирование панели
        self.assertEqual(disk.init_params, [(16, 63), (16, 63)])
        self.assertEqual(drv.read(5000, 2), disk.span(5000, 2))

    def test_bad_geometry(self):
        for heads, spt in ((0, 63), (17, 63), (16, 0), (16, 200)):
            disk = self.disk(cylinders=10, heads=heads, spt=spt or 1, lba=False)
            disk.spt = spt
            drv = self.driver(disk)
            self.assertTrue(drv.devini(), (heads, spt))
            self.assertNotIn(0x91, disk.commands, (heads, spt))


class NemoChs(ChsCase, unittest.TestCase):
    NAME = 'DIDENEMO_CHS'


class SmucChs(ChsCase, unittest.TestCase):
    NAME, SMUC = 'DIDESMUC_CHS', True


if __name__ == '__main__':
    unittest.main()
