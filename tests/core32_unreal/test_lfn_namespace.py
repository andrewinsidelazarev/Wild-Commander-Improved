"""Execute built WildDOS: SFN tails, shared namespace, LFN layout and I/O errors.

Directory reads are supplied as sectors. Parsing, matching, formatting, extension
code and the creation-mode lifetime run as real Z80 instructions from boot.$C.
"""
from __future__ import annotations

import re
from pathlib import Path
import runtime_image
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
        core = (BUILD / 'CORE32_RUNTIME.bin').read_bytes()
        assert len(core) == length, (len(core), length)
        self.cpu.set_memory_block(0x4000, core)
        self.cpu.set_memory_block(0xC000, (BUILD / 'CORE32_EXT.bin').read_bytes())
        # Как установщик: драйверы ядра — в #E8, резидентный блок — на их место.
        runtime_image.apply(self.ram, symbols(BUILD / 'CORE32_EXT.sym'))
        self.directory = directory + bytes(512 - len(directory) % 512)
        self.fail_read = fail_read
        self.cursor = 0
        self.reads = 0
        # Поиск и создание с 2026-09-27 сначала проверяют цепочку каталога
        # (DIR_CHAIN): корень — кластер 2, его запись FAT — конец цепочки.
        self.ram[self.addr('BROOTC'):self.addr('BROOTC') + 4] = (2).to_bytes(4, 'little')
        for address in (STOP, self.addr('TOS'), self.addr('LOAD512'), self.addr('CURIT')):
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
            if self.cpu.pc == self.addr('CURIT'):
                eoc = self.addr('SECBU')                     # запись FAT корня
                self.ram[eoc:eoc + 4] = (0x0FFFFFFF).to_bytes(4, 'little')
                self.cpu.hl, self.cpu.f = eoc, 0
                self.ret()
            elif self.cpu.pc == self.addr('TOS'):
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


# Claude - 2026-10-10 - begin
# Исправления имён из драйвера FAT32: начальные пробелы значимы (R11-1), знак
# #FF не совпадает с концом имени, точка в конце — длинное имя (R12-1),
# длинное имя на три сектора находится (R1), псевдографика CP866 в длинное
# имя не переводится (R10-2).
def found(result) -> bool:
    return result[1] is False


def test_leading_spaces_are_significant():
    h = Harness(long_entry('   lead.txt', b'LEAD~1  TXT'))
    assert found(h.find('   lead.txt')), 'имя с пробелами в начале не найдено'
    assert not found(h.find('lead.txt')), '«lead.txt» нашёл «   lead.txt»'
    h = Harness(long_entry('lead name.txt', b'LEADNA~1TXT'))
    assert found(h.find('lead name.txt'))
    assert not found(h.find('  lead name.txt')), '«  lead name.txt» нашёл «lead name.txt»'
    # Соседа с пробелами в начале создание больше не принимает за то же имя.
    h = Harness(long_entry('   lead name.txt', b'LEADNA~1TXT'))
    result, raw = h.create('lead name.txt')
    assert result[1], ('«lead name.txt» не создан рядом с «   lead name.txt»', result)
    assert raw[:11] != b'LEADNA~1TXT', raw[:11]


def test_name_end_is_not_a_character():
    # 12 знаков: конец имени (#0000) — 13-й знак записи LFN. Запрос с лишним
    # знаком #FF прежде совпадал с ним.
    name = 'abcdefghijkl'
    h = Harness(long_entry(name, b'ABCDEF~1   '))
    assert found(h.find(name))
    h.cpu.set_memory_block(0x8000, b'\0' + name.encode() + b'\xFF\0')
    assert not found(h.invoke('SRHDRN', hl=0x8000)), 'запрос «имя+#FF» нашёл «имя»'


def test_trailing_dot_is_a_long_name():
    h = Harness(entry(b'FOO        ') + entry(b'.          ', 16) + entry(b'..         ', 16))
    assert found(h.find('foo'))
    assert not found(h.find('foo.')), '«foo.» нашёл FOO'
    assert not found(h.find('foo..')), '«foo..» нашёл FOO'
    assert found(h.find('.', 16)) and found(h.find('..', 16)), 'служебные «.» и «..» не находятся'
    h = Harness(long_entry('Report.txt', b'REPORT  TXT'))
    assert not found(h.find('REPORT.TXT.')), '«алиас.» нашёл файл с этим алиасом'


def test_long_name_over_three_sectors_is_found():
    # 230 знаков — 18 записей LFN; короткая запись — первой в третьем секторе:
    # две записи LFN в первом секторе, шестнадцать во втором.
    name = ''.join(chr(ord('a') + i % 26) for i in range(230))
    padding = b''.join(entry(f'P{i:07}BIN'.encode()) for i in range(14))
    h = Harness(padding + long_entry(name, b'ABCDEF~1   '))
    assert found(h.find(name)), 'длинное имя на три сектора не найдено'


def lfn_name(h, raw) -> str:
    """Имя из записей LFN, которые ENTREZ собрал за NXTBM (#1000)."""
    words = []
    i = 1
    while True:
        record = bytes(h.ram[0x1000 + i * 32:0x1000 + (i + 1) * 32])
        if record[11] != 15:
            break
        words += [record[p:p + 2] for p in POSITIONS]
        if record[0] & 0x40:
            break
        i += 1
    return b''.join(words).decode('utf-16-le').split('\0')[0].rstrip('\uFFFF')


TABLE = bytes(range(0xB0, 0xE0)) + bytes(range(0xF2, 0xFF))   # без #FF


def test_pseudographics_and_signs_in_long_names():
    # С 2026-10-10 знаки CP866 #B0..#DF и #F2..#FE переводятся по полной
    # таблице: прежде ORU писал их как «ё» («Папка №2» становилась «Папка
    # ё2», драйвер FAT32 R10-2), затем имя с ними отвергалось целиком — и
    # «№2.TXT», 8.3-имя с заглавным расширением, тоже (Codex R1).
    names = ['Папка №2', '№2.TXT', 'a\u2591b long', 'x\u0457 name', 'Є-Ї-Ў °·√¤■',
             '╔═╗║╚╝ box', 'ёжик в тумане', 'Ёлка 2026']
    for name in names:
        h = Harness()
        result, raw = h.create(name)
        assert result[1], (name, result)
        assert lfn_name(h, raw) == name, (name, lfn_name(h, raw))
        # Сравнение имён (UCS): длинное имя на диске находится по нему же.
        h = Harness(long_entry(name, raw[:11]))
        assert found(h.find(name)), name
    # Неразрывный пробел (#FF) — по-прежнему нет: в сравнении имён #FF —
    # конец имени на диске.
    h = Harness()
    h.cpu.set_memory_block(0x8000, b'a\xFFb long' + bytes(257))
    h.cpu.set_memory_block(h.addr('ENTRY'), bytes(32))
    result = h.invoke('ENTREZ_ANY_TYPE', hl=0x8000, a=0)
    assert not result[1] and result[0] == 1, result
    # Короткая запись хранит такие знаки как есть.
    h = Harness()
    result, raw = h.create('№2')
    assert result[1], ('«№2» (короткая запись) не создаётся', result)


def test_every_table_sign_round_trips():
    # Каждый знак таблицы: ORU (запись) -> UTF-16 -> UCS (сравнение) и UCH
    # (список) — обратно тот же знак CP866; кириллица — как прежде.
    signs = TABLE + bytes(range(0x80, 0xB0)) + bytes(range(0xE0, 0xF2))
    h = Harness()
    for sign in signs:
        unit = bytes([sign]).decode('cp866').encode('utf-16-le')
        h.cpu.set_memory_block(0x9000, unit + b'\0\0')
        a, zero, carry = h.invoke('UCS', hl=0x9000)
        assert a == sign, (hex(sign), hex(a))
        h.ram[0xA000] = 0
        a, zero, carry = h.invoke('UCH', hl=0x9000, de=0xA000)
        assert carry and h.ram[0xA000] == sign, (hex(sign), carry, hex(h.ram[0xA000]))
        h.cpu.set_memory_block(0x8000, b'z' + bytes([sign]) + b'z long' + bytes(257))
        h.cpu.set_memory_block(h.addr('ENTRY'), bytes(32))
        result = h.invoke('ENTREZ_ANY_TYPE', hl=0x8000, a=0)
        assert result[1], hex(sign)
        record = bytes(h.ram[0x1000 + 32:0x1000 + 64])
        assert record[3:5] == unit, (hex(sign), record[3:5].hex(), unit.hex())
    # Неизвестный знак (не CP866): UCS — 0, UCH — Z без записи (короткое имя).
    h.cpu.set_memory_block(0x9000, (0x4E2D).to_bytes(2, 'little') + b'\0\0')
    assert h.invoke('UCS', hl=0x9000)[0] == 0
    a, zero, carry = h.invoke('UCH', hl=0x9000, de=0xA000)
    assert zero and not carry
# Claude - 2026-10-10 - end


def main():
    for test in (test_numeric_tails, test_types_and_aliases,
                 test_lfn_encoding_and_formatter, test_io_errors_and_mode_reset,
                 test_leading_spaces_are_significant, test_name_end_is_not_a_character,
                 test_trailing_dot_is_a_long_name, test_long_name_over_three_sectors_is_found,
                 test_pseudographics_and_signs_in_long_names, test_every_table_sign_round_trips):
        test()
        print(test.__name__ + ': PASS')
    print('LFN/SFN namespace: ALL PASS (real Z80 core and extension, mocked sector I/O)')


if __name__ == '__main__':
    main()
