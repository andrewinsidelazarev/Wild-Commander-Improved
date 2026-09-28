"""Время изменения при записи внутри файла и усечении через FILEX.

Исполняются настоящие FILEX, ядро и расширение на диске в памяти
(core32_ramdisk.Volume). Порты CMOS отвечают как часы, стоящие на
2026-09-25 01:30:40. Усечение и запись целиком внутри файла проходили мимо
APPEND и время изменения не трогали; теперь они ставят время и дату
изменения и дату доступа, а время и дата создания остаются прежними.
"""
import unittest

import core32_machine as p
import core32_ramdisk as rd


def bcd(value):
    return value // 10 << 4 | value % 10


RTC = {0: bcd(40), 2: bcd(30), 4: bcd(1), 7: bcd(25), 8: bcd(9), 9: bcd(26)}
MODIFY_TIME = 1 << 11 | 30 << 5 | 40 // 2
MODIFY_DATE = (2026 - 1980) << 9 | 9 << 5 | 25
BLOCK, BUFFER = 0x9000, 0xA000


class ClockVolume(rd.Volume):
    """Диск в памяти, у которого порты CMOS отвечают часами."""

    def __init__(self, **options):
        super().__init__(**options)
        self.selected = None
        self.cpu.set_input_callback(self.inp)

    def inp(self, port):
        if port == 0x13AF:
            return self.page
        if port == 0xBFF7:
            return RTC.get(self.selected, 0xFF)
        return 255

    def output(self, port, value):
        if port == 0xDFF7:
            self.selected = value
            return
        super().output(port, value)

    def entry(self):
        at = self.data_start * 512
        return bytes(self.disk[at:at + 32])

    def run_block(self, operation, offset, data=b''):
        cpu, mem = self.cpu, self.mem
        mem[BLOCK:BLOCK + 32] = bytes(32)
        mem[BLOCK + p.FX['FILEX_P_SIZE']] = 32
        mem[BLOCK + p.FX['FILEX_P_VERSION']] = p.FX['FILEX_API_VERSION']
        mem[BLOCK + p.FX['FILEX_P_OPERATION']] = operation
        p.h.put32(mem, BLOCK + p.FX['FILEX_P_OFFSET'], offset)
        if data:
            mem[BUFFER:BUFFER + len(data)] = data
            p.h.put16(mem, BLOCK + p.FX['FILEX_P_BUFFER'], BUFFER)
            p.h.put16(mem, BLOCK + p.FX['FILEX_P_LENGTH'], len(data))
        cpu.hl, cpu.pc, cpu.sp = BLOCK, p.FX['FILEX_ENTRY'], p.STACK
        p.h.put16(mem, p.STACK, p.STOP)
        stops = {p.STOP, *self.callbacks}
        for address in stops:
            cpu.set_breakpoint(address)
        try:
            for _ in range(200000):
                cpu.ticks_to_stop = 1000000
                if not cpu.run() & 2:
                    continue
                if cpu.pc == p.STOP:
                    return mem[BLOCK + p.FX['FILEX_P_STATUS']]
                if cpu.pc in self.callbacks:
                    self.callbacks[cpu.pc]()
        finally:
            for address in stops:
                cpu.clear_breakpoint(address)
        raise AssertionError('FILEX не вернулся')


def word(entry, offset):
    return entry[offset] | entry[offset + 1] << 8


class ModifiedTime(unittest.TestCase):

    def check_stamped(self, entry):
        self.assertEqual((word(entry, 22), word(entry, 24), word(entry, 18)),
                         (MODIFY_TIME, MODIFY_DATE, MODIFY_DATE), 'время изменения и доступ')
        self.assertEqual((word(entry, 14), word(entry, 16)), (0, 0), 'создание не трогается')

    def test_truncation_stamps_modification(self):
        volume = ClockVolume(original=2048, free=64)
        status = volume.run_block(p.FX['FILEX_OP_SET_EOF32'], 1024)
        self.assertEqual(status, 0)
        entry = volume.entry()
        self.assertEqual(p.h.get32(entry, 28), 1024)
        self.check_stamped(entry)

    def test_write_inside_file_stamps_modification(self):
        volume = ClockVolume(original=2048, free=64)
        status = volume.run_block(p.FX['FILEX_OP_WRITE_AT'], 100, b'Z' * 10)
        self.assertEqual(status, 0)
        entry = volume.entry()
        self.assertEqual(p.h.get32(entry, 28), 2048, 'размер прежний')
        start = (volume.data_start + 1) * 512 + 100
        self.assertEqual(bytes(volume.disk[start:start + 10]), b'Z' * 10, 'данные на месте')
        self.check_stamped(entry)


if __name__ == '__main__':
    unittest.main(verbosity=2)
