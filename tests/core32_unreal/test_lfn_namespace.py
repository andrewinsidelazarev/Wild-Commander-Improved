"""Execute built WildDOS: SFN tails, shared namespace, LFN layout and I/O errors.

Directory reads are supplied as sectors. Parsing, matching, formatting, extension
code and the creation-mode lifetime run as real Z80 instructions from boot.$C.
"""
from __future__ import annotations

import re
from pathlib import Path
import z80

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build'
STOP, STACK = 0xFF00, 0x5F00
POSITIONS = (1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)


def symbols(path: Path) -> dict[str, int]:
    return {m[1]: int(m[2], 16) for line in path.read_text().splitlines()
            if (m := re.match(r'^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$', line))}


def checksum(short: bytes) -> int:
    result = 0
    for value in short:
        result = (((result & 1) << 7) + (result >> 1) + value) & 255
    return result


def entry(short: bytes, attr: int = 0) -> bytes:
    assert len(short) == 11
    return short + bytes([attr]) + bytes(20)


def long_entry(name: str, short: bytes, attr: int = 0) -> bytes:
    units = list(name.encode('utf-16-le'))
    units = [bytes(units[i:i+2]) for i in range(0, len(units), 2)]
    chunks = [units[i:i+13] for i in range(0, len(units), 13)]
    result = []
    for i in range(len(chunks), 0, -1):
        record = bytearray(b'\xFF' * 32)
        record[0] = i | (0x40 if i == len(chunks) else 0)
        record[11:14] = bytes([15, 0, checksum(short)])
        record[26:28] = b'\0\0'
        words = chunks[i-1]
        if len(words) < 13:
            words = words + [b'\0\0']
        words = words + [b'\xFF\xFF'] * (13-len(words))
        for offset, word in zip(POSITIONS, words):
            record[offset:offset+2] = word
        result.append(bytes(record))
    return b''.join(result) + entry(short, attr)


class Harness:
    def __init__(self, directory: bytes = b'', fail_read: int | None = None):
        self.sym = symbols(BUILD / 'boot.sym')
        self.cpu = z80.Z80Machine()
        self.ram = self.cpu.memory
        boot = (ROOT / 'exe' / 'boot.$C').read_bytes()
        length = self.addr('END') - 0x4000
        self.cpu.set_memory_block(0x4000, boot[0x600C:0x600C+length])
        self.cpu.set_memory_block(0xC000, (BUILD / 'CORE32_EXT.bin').read_bytes())
        self.directory = directory + bytes(512 - len(directory) % 512)
        self.fail_read = fail_read
        self.cursor = 0
        self.reads = 0
        for address in (STOP, self.addr('TOS'), self.addr('LOAD512')):
            self.cpu.set_breakpoint(address)

    def addr(self, name: str) -> int:
        return self.sym['WDOS.' + name]

    def ret(self):
        self.cpu.pc = self.ram[self.cpu.sp] | self.ram[self.cpu.sp+1] << 8
        self.cpu.sp += 2

    def invoke(self, name: str, *, hl: int = 0, de: int = 0, a: int = 0):
        self.cpu.sp = STACK
        self.ram[STACK:STACK+2] = STOP.to_bytes(2, 'little')
        self.cpu.pc, self.cpu.hl, self.cpu.de, self.cpu.a = self.addr(name), hl, de, a
        for _ in range(100000):
            self.cpu.ticks_to_stop = 1000000
            event = self.cpu.run()
            if not event & 2:
                continue
            if self.cpu.pc == STOP:
                return self.cpu.a, bool(self.cpu.f & 64), bool(self.cpu.f & 1)
            if self.cpu.pc == self.addr('TOS'):
                self.cursor = 0
                self.ram[self.addr('EOC')] = self.ram[self.addr('NSDC')] = 0
                self.cpu.a, self.cpu.f = 0, 64
                self.ret()
            elif self.cpu.pc == self.addr('LOAD512'):
                self.reads += 1
                if self.cursor == self.fail_read:
                    self.ram[self.addr('EOC')] = 255
                    self.ram[self.addr('ABT')] = 255
                    self.cpu.a, self.cpu.f = 255, 1
                else:
                    block = self.directory[self.cursor*512:(self.cursor+1)*512]
                    if not block:
                        self.ram[self.addr('EOC')] = 15
                        self.cpu.a, self.cpu.f = 15, 0
                    else:
                        self.cpu.set_memory_block(self.cpu.hl, block)
                        self.cpu.hl += 512
                        self.ram[self.addr('ABT')] = self.ram[self.addr('EOC')] = 0
                        self.cpu.a, self.cpu.f = 0, 64
                    self.cursor += 1
                self.ret()
            else:
                raise AssertionError(hex(self.cpu.pc))
        raise AssertionError('Z80 operation did not terminate')

    def create(self, name: str, attr: int = 0):
        self.cpu.set_memory_block(0x8000, name.encode('cp866') + bytes(257))
        self.cpu.set_memory_block(self.addr('ENTRY'), bytes(32))
        result = self.invoke('ENTREZ_ANY_TYPE', hl=0x8000, a=attr)
        assert self.ram[self.addr('FIND_TYPE_MASK')+1] == 16, 'Creation mode leaked'
        raw = bytes(self.ram[self.addr('NXTBM'):self.addr('NXTBM')+32])
        return result, raw

    def find(self, name: str, attr: int = 0):
        self.cpu.set_memory_block(0x8000, bytes([attr]) + name.encode('cp866') + b'\0')
        return self.invoke('SRHDRN', hl=0x8000)


def test_numeric_tails():
    h = Harness()
    h.cpu.set_breakpoint(h.addr('FNDSN'))
    occupied = set()
    for n in range(1, 1001):
        h.cpu.set_memory_block(0x1000, entry(b'2026-09-TXT'))
        h.cpu.set_memory_block(0xFE0, b'00000')
        h.cpu.sp = STACK
        h.ram[STACK:STACK+2] = STOP.to_bytes(2, 'little')
        h.cpu.pc = h.addr('BURA')
        while True:
            h.cpu.ticks_to_stop = 1000000
            event = h.cpu.run()
            if not event & 2:
                continue
            if h.cpu.pc == STOP:
                assert n == 1000 and h.cpu.a == 2 and not h.cpu.f & 64
                break
            assert h.cpu.pc == h.addr('FNDSN')
            actual = bytes(h.ram[h.addr('ENTRY'):h.addr('ENTRY')+11])
            if actual not in occupied:
                tail = '~' + str(n)
                expected = ('2026-09-'[:8-len(tail)] + tail + 'TXT').encode()
                assert actual == expected, (n, actual, expected)
                occupied.add(actual)
                break
            h.cpu.a, h.cpu.f = 1, 0
            h.ret()
    assert len(occupied) == 999


def test_types_and_aliases():
    for old_type in (0, 16):
        for new_type in (0, 16):
            h = Harness(long_entry('2026-09-01', b'2026-0~1   ', old_type))
            result, raw = h.create('2026-09-02', new_type)
            assert result == (0, True, False), result
            assert raw[:11] == b'2026-0~2   ' and raw[11] == new_type
            assert h.find('2026-09-01', old_type)[1] is False
            assert h.find('2026-09-01', old_type ^ 16)[1] is True
            result, _ = h.create('2026-09-01', new_type)
            assert not result[1], 'Duplicate LFN accepted'
    # Existing LFN equals the proposed SFN but has a different SFN of its own.
    h = Harness(long_entry('2026-0~1.txt', b'OTHER   TXT', 16))
    result, raw = h.create('2026-09-02.txt')
    assert result[1] and raw[:11] == b'2026-0~2TXT', (result, raw[:11])
    # Existing SFN equals the requested name, including cross-type collisions.
    h = Harness(long_entry('a different name', b'2026-0~1TXT', 16))
    assert not h.create('2026-0~1.txt')[0][1]
    h = Harness(long_entry('Report.txt', b'REPORT~1TXT', 16))
    assert not h.create('report.TXT')[0][1], 'Case-insensitive LFN collision missed'
    h = Harness(entry(b'2026-0~1TXT'))
    assert h.create('2026-09-02.bin')[1][:11] == b'2026-0~1BIN'


def test_lfn_encoding_and_formatter():
    for name in ['a' * n for n in (13, 14, 26, 27, 255)] + ['2026-09-Ёж.txt']:
        h = Harness()
        result, raw = h.create(name)
        assert result == (0, True, False), (name, result)
        count = (len(name)+12)//13
        assert h.cpu.hl == 0x1000+count*32
        words = []
        for i in range(1, count+1):
            record = bytes(h.ram[0x1000+i*32:0x1000+(i+1)*32])
            assert record[0] == i | (0x40 if i == count else 0)
            assert record[11:14] == bytes([15, 0, checksum(raw[:11])])
            assert record[26:28] == b'\0\0'
            words += [record[p:p+2] for p in POSITIONS]
        encoded = b''.join(words).decode('utf-16-le')
        assert encoded.split('\0')[0].rstrip('\uFFFF') == name
    for short, expected in [(b'BOOT    $C ', 'boot.$c'), (b'FILE    C  ', 'file.c'),
                            (b'FILE    GZ ', 'file.gz'), (b'FILE    BIN', 'file.bin'),
                            (b'DIR        ', 'dir')]:
        h = Harness()
        h.cpu.set_memory_block(0x9000, entry(short))
        h.invoke('Snm', hl=0x9000, de=0xA000)
        value = bytes(h.ram[0xA000:0xA020]).split(b'\0')[0].decode()
        assert value == expected, (value, expected)


def test_io_errors_and_mode_reset():
    directory = b''.join(entry(f'F{i:07}BIN'.encode()) for i in range(32))
    h = Harness()
    h.directory = directory  # Full sectors with no #00 directory terminator.
    result = h.find('missing.txt')
    assert result[1] and not result[2], 'Normal EOC was treated as an I/O error'
    assert h.create('2026-09-new.txt')[0][1], 'Full directory search did not stop at EOC'
    for sector in (0, 1):
        h = Harness(directory, fail_read=sector)
        result, _ = h.create('2026-09-new.txt')
        assert not result[1] and result[2], (sector, result)
        assert h.reads == sector+1, 'Alias retries continued after read failure'
        result = h.find('missing.txt')
        assert result[1] and result[2], 'Ordinary lookup reported a false match'
    for invalid in ('', 'bad:name', 'x' * 256):
        h = Harness()
        assert not h.create(invalid)[0][1]
        assert h.ram[h.addr('FIND_TYPE_MASK')+1] == 16


def main():
    for test in (test_numeric_tails, test_types_and_aliases,
                 test_lfn_encoding_and_formatter, test_io_errors_and_mode_reset):
        test()
        print(test.__name__ + ': PASS')
    print('LFN/SFN namespace: ALL PASS (real Z80 core and extension, mocked sector I/O)')


if __name__ == '__main__':
    main()
