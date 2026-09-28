"""Даты файлов для программ (2026-09-26).

* API 58 (NXTETY2), бит 6 маски: в полях битов 4 и 3 — время и дата ИЗМЕНЕНИЯ
  (+22/+24), а не создания (+14/+16). Прежде плагин получал только дату
  создания, а панель WC показывает и сортирует по дате изменения; у файлов,
  скопированных с ПК, они разные. Раскладка вывода прежняя: [размер][дата]
  [время][признак][имя,0]; без бита 6 — всё как было.
* FILEX GET_METADATA (операция 8): атрибут и времена последнего FENTRY — та
  же 16-байтовая структура, что у SET_METADATA, без записи на диск.
* Штамп FAT (время и дата), которого нет в календаре, программа получает как
  2026-01-01 00:00 (API 58 и GET_METADATA; сама запись не меняется), а
  SET_METADATA вместо него пишет текущий штамп часов. Проверка — CHECK_STAMP
  расширения: месяц 1..12, день 1..длина месяца (февраль года, кратного 4, —
  29 дней), часы до 23, минуты и секунды до 59; год FAT любой.

Исполняются собранные ядро, расширение и FILEX; подменён только драйвер
сектора (диск в памяти).
"""
import calendar
import unittest

import core32_machine as p
import test_fat_allocator_hint as h
from test_fat_stream_cache import Machine, put32
from test_filex_time import ClockVolume, MODIFY_DATE, MODIFY_TIME

FX = p.FX
OUT = 0xA000
C_TIME, C_DATE, M_TIME, M_DATE, ACCESS = 0x1111, 0x2222, 0x3333, 0x4444, 0x5555
FALLBACK_DATE = (2026 - 1980) << 9 | 1 << 5 | 1         # 2026-01-01
GOOD_DATE = (2021 - 1980) << 9 | 5 << 5 | 6             # 2021-05-06
BAD_DATE = (2021 - 1980) << 9 | 4 << 5 | 31             # 31.04 — такого дня нет
BAD_TIME = 24 << 11                                     # 24:00:00


def in_calendar(time, date):
    """Эталон проверки штампа. 2100-й ядро считает високосным (точный счёт
    до него), поэтому год для calendar.isleap берётся как есть, кроме 2100."""
    day, month, year = date & 31, date >> 5 & 15, 1980 + (date >> 9)
    if not 1 <= month <= 12 or day == 0:
        return False
    days = calendar.monthrange(year, month)[1]
    if month == 2 and year == 2100:
        days = 29
    if day > days:
        return False
    return time >> 11 <= 23 and time >> 5 & 63 <= 59 and time & 31 <= 29


class CheckStamp(unittest.TestCase):
    """CHECK_STAMP расширения на всех датах и всех временах FAT."""

    def check(self, pairs):
        harness, wrong = None, []
        for index, (time, date) in enumerate(pairs):
            if index % 400 == 0:                # стенду Z80 нужен свежий счёт тактов
                harness = h.ExtensionHarness()
            harness.machine.hl, harness.machine.de = time, date
            harness.invoke('CHECK_STAMP')
            got = (harness.machine.f & 1, harness.machine.hl, harness.machine.de)
            good = in_calendar(time, date)
            expected = (0, time, date) if good else (1, 0, FALLBACK_DATE)
            if got != expected:
                wrong.append((hex(time), hex(date), got, expected))
        self.assertEqual(wrong[:10], [])

    def test_every_date(self):
        self.check([(0, date) for date in range(65536)])

    def test_every_time(self):
        self.check([(time, GOOD_DATE) for time in range(65536)])

    def test_counts(self):
        # 128 лет FAT, из них 32 високосных (1980..2104 и 2100 по правилу ядра).
        self.assertEqual(sum(in_calendar(0, d) for d in range(65536)), 128 * 365 + 32)
        self.assertEqual(sum(in_calendar(t, GOOD_DATE) for t in range(65536)), 24 * 60 * 30)


def record(short, attr, size, shift):
    """Короткая запись: времена создания и изменения различимы и сдвинуты на
    shift, чтобы записи не путались."""
    data = bytearray(32)
    data[:11] = short
    data[11] = attr
    data[14:16] = (C_TIME + shift).to_bytes(2, 'little')
    data[16:18] = (C_DATE + shift).to_bytes(2, 'little')
    data[18:20] = (ACCESS + shift).to_bytes(2, 'little')
    data[22:24] = (M_TIME + shift).to_bytes(2, 'little')
    data[24:26] = (M_DATE + shift).to_bytes(2, 'little')
    data[28:32] = size.to_bytes(4, 'little')
    return bytes(data)


ENTRIES = [
    (b'FILE1   TXT', 0x20, 1234, 0),
    (b'SUBDIR     ', 0x10, 0, 1),
    (b'FILE2   BIN', 0x21, 70000, 2),
]


def listing(mask, records=None):
    m = Machine(spc=1, fat_sectors=4)
    m.make_chain([2])
    sector = b''.join(records or [record(*e) for e in ENTRIES])
    m.sectors[m.cluster_lba(2)] = sector.ljust(512, b'\0')
    m.mem[m.core('CGFL'):m.core('CGFL') + 2] = b'\0\0'
    put32(m.mem, m.core('LSTCAT'), 0)
    result = []
    while True:
        a, f, _, de = m.call(0x405A, a=mask, de=OUT)          # API 58 — NXTETY2
        if f & 0x40:
            return result
        result.append(bytes(m.mem[OUT:de]))


def fields(raw, mask):
    """Разобрать вывод: размер, дата, время по битам 2/3/4, затем признак."""
    at, out = 0, {}
    if mask & 0x04:
        out['size'] = int.from_bytes(raw[at:at + 4], 'little')
        at += 4
    if mask & 0x08:
        out['date'] = int.from_bytes(raw[at:at + 2], 'little')
        at += 2
    if mask & 0x10:
        out['time'] = int.from_bytes(raw[at:at + 2], 'little')
        at += 2
    out['attr'] = raw[at]
    out['name'] = raw[at + 1:].rstrip(b'\0')
    return out


class ListingDates(unittest.TestCase):

    def check(self, mask, expected_entries):
        rows = listing(mask)
        self.assertEqual(len(rows), len(expected_entries), rows)
        modified = bool(mask & 0x40)
        for raw, (short, attr, size, shift) in zip(rows, expected_entries):
            got = fields(raw, mask)
            self.assertEqual(got['attr'], attr, raw)
            if mask & 0x04:
                self.assertEqual(got['size'], size)
            if mask & 0x08:
                self.assertEqual(got['date'], (M_DATE if modified else C_DATE) + shift)
            if mask & 0x10:
                self.assertEqual(got['time'], (M_TIME if modified else C_TIME) + shift)

    def test_creation_without_bit_6_as_before(self):
        for mask in (0x08, 0x10, 0x18, 0x1C, 0x9C):
            with self.subTest(mask=hex(mask)):
                self.check(mask, ENTRIES)

    def test_modification_with_bit_6(self):
        for mask in (0x48, 0x50, 0x58, 0x5C, 0xDC):
            with self.subTest(mask=hex(mask)):
                self.check(mask, ENTRIES)

    def test_bit_6_alone_changes_nothing_else(self):
        # Без битов 3/4 бит 6 не добавляет полей.
        self.assertEqual(listing(0x44), listing(0x04))
        self.assertEqual(listing(0x40), listing(0x00))

    def test_type_filters_with_bit_6(self):
        files = [e for e in ENTRIES if not e[1] & 0x10]
        dirs = [e for e in ENTRIES if e[1] & 0x10]
        self.check(0x59, files)
        self.check(0x5A, dirs)

    def test_names_are_the_same(self):
        for mask in (0x18, 0x58, 0x98, 0xD8):
            with self.subTest(mask=hex(mask)):
                names = [fields(raw, mask)['name'] for raw in listing(mask)]
                self.assertEqual(names, [fields(raw, mask & ~0x40)['name']
                                         for raw in listing(mask & ~0x40)])


def stamped(short, *, c_time=C_TIME, c_date=C_DATE, m_time=M_TIME, m_date=M_DATE):
    data = bytearray(record(short, 0x20, 100, 0))
    for offset, value in ((14, c_time), (16, c_date), (22, m_time), (24, m_date)):
        data[offset:offset + 2] = value.to_bytes(2, 'little')
    return bytes(data)


class ListingBadStamps(unittest.TestCase):
    """API 58: штамп, которого нет в календаре, — 2026-01-01 00:00; соседний
    штамп той же записи и штампы других записей — как на носителе."""

    RECORDS = [
        stamped(b'NODATE  TXT', c_date=0),                 # создание: даты нет
        stamped(b'BADDAY  TXT', m_date=BAD_DATE),          # изменение: 31.04
        stamped(b'BADHOUR TXT', c_time=BAD_TIME, m_time=BAD_TIME),
        stamped(b'GOOD    TXT', c_time=0, c_date=GOOD_DATE, m_date=GOOD_DATE),
    ]

    def stamps(self, mask):
        return [(fields(raw, mask)['time'], fields(raw, mask)['date'])
                for raw in listing(mask, self.RECORDS)]

    def test_creation(self):
        self.assertEqual(self.stamps(0x18), [
            (0, FALLBACK_DATE), (C_TIME, C_DATE), (0, FALLBACK_DATE), (0, GOOD_DATE)])

    def test_modification(self):
        self.assertEqual(self.stamps(0x58), [
            (M_TIME, M_DATE), (0, FALLBACK_DATE), (0, FALLBACK_DATE), (M_TIME, GOOD_DATE)])

    def test_single_fields(self):
        # Бит 3 без бита 4 и наоборот: поле берётся из проверенного штампа.
        dates = [fields(raw, 0x48)['date'] for raw in listing(0x48, self.RECORDS)]
        times = [fields(raw, 0x10)['time'] for raw in listing(0x10, self.RECORDS)]
        self.assertEqual(dates, [M_DATE, FALLBACK_DATE, FALLBACK_DATE, GOOD_DATE])
        self.assertEqual(times, [0, C_TIME, 0, 0])

    def test_names_and_sizes_stay(self):
        rows = listing(0x5C, self.RECORDS)
        plain = listing(0x04, self.RECORDS)
        self.assertEqual(len(rows), 4)
        self.assertEqual([fields(raw, 0x5C)['name'] for raw in rows],
                         [fields(raw, 0x04)['name'] for raw in plain])
        self.assertEqual({fields(raw, 0x5C)['size'] for raw in rows}, {100})


class AuditVolume:
    """Диск в памяти с часами и контекстом FENTRY файла AUDIT.BIN."""

    ATTR = 0x22                                                 # скрытый, архив
    OFFSETS = dict(c_time=14, c_date=16, access=18, m_time=22, m_date=24)

    def volume(self, tenth=0x77, **words):
        volume = ClockVolume(original=1536, free=20)
        entry = bytearray(volume.entry())
        entry[11] = self.ATTR
        entry[14:26] = record(b'AUDIT   BIN', self.ATTR, 0, 0)[14:26]
        entry[13] = tenth                                       # доли секунды создания
        for name, value in words.items():
            entry[self.OFFSETS[name]:self.OFFSETS[name] + 2] = value.to_bytes(2, 'little')
        start = volume.data_start * 512
        volume.disk[start:start + 32] = entry
        ext = volume.pages[0xE8]
        offset = volume.ext('APPEND_ENTRY') - 0xC000
        ext[offset:offset + 32] = entry
        volume.mem[volume.core('ENTRY'):volume.core('ENTRY') + 32] = entry
        return volume, bytes(entry)


class Metadata(AuditVolume, unittest.TestCase):
    """FILEX GET_METADATA по контексту AUDIT.BIN, заданному стендом."""

    def test_structure(self):
        volume, entry = self.volume()
        before, writes = bytes(volume.disk), volume.writes
        status = volume.run_block(FX['FILEX_OP_GET_METADATA'], 0, bytes(16))
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        self.assertEqual((bytes(volume.disk), volume.writes), (before, writes), 'GET писал на диск')
        out = bytes(volume.mem[0xA000:0xA010])
        self.assertEqual(out[0], 16)
        self.assertEqual(out[1], FX['FILEX_META_ALLOWED_ATTRS'])
        self.assertEqual(out[2], self.ATTR)
        self.assertEqual(out[3], 0x07)
        self.assertEqual(out[4:9], entry[13:18], 'создание: доли, время, дата')
        self.assertEqual(out[9:11], entry[18:20], 'дата доступа')
        self.assertEqual(out[11:15], entry[22:26], 'изменение: время, дата')
        self.assertEqual(out[15], self.ATTR)
        self.assertEqual(p.h.get32(volume.mem, 0x9000 + FX['FILEX_P_RESULT_COUNT']), 16)
        self.assertEqual(volume.mem[0x9000 + FX['FILEX_P_RESULT_FLAGS']], self.ATTR)

    def test_short_buffer(self):
        volume, _ = self.volume()
        status = volume.run_block(FX['FILEX_OP_GET_METADATA'], 0, bytes(15))
        self.assertEqual(status, FX['FILEX_STATUS_BAD_LENGTH'])

    def test_capability_bit(self):
        volume, _ = self.volume()
        self.assertEqual(volume.run_block(FX['FILEX_OP_QUERY_CAPS'], 0), FX['FILEX_STATUS_OK'])
        caps = p.h.get32(volume.mem, 0x9000 + FX['FILEX_P_RESULT_COUNT'])
        self.assertEqual(caps & 0xFF, 0xFF, 'прежние возможности')
        self.assertEqual(caps >> 8 & 0xFF, FX['FILEX_CAP2_GET_METADATA'])

    def test_round_trip_into_set_metadata(self):
        # Структуру GET можно отдать в SET без правки: запись та же.
        volume, entry = self.volume()
        volume.run_block(FX['FILEX_OP_GET_METADATA'], 0, bytes(16))
        data = bytes(volume.mem[0xA000:0xA010])
        entry_before = bytes(volume.disk[volume.data_start * 512:volume.data_start * 512 + 32])
        status = volume.run_block(FX['FILEX_OP_SET_METADATA'], 0, data)
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        entry_after = bytes(volume.disk[volume.data_start * 512:volume.data_start * 512 + 32])
        self.assertEqual(entry_after, entry_before)


def words(data, *offsets):
    return tuple(data[o] | data[o + 1] << 8 for o in offsets)


class MetadataBadStamps(AuditVolume, unittest.TestCase):
    """С 2026-09-26: GET отдаёт вместо штампа, которого нет в календаре,
    2026-01-01 00:00 (запись не меняется); SET пишет вместо него текущий
    штамп часов (стенд — 2026-09-25 01:30:40)."""

    def disk_entry(self, volume):
        at = volume.data_start * 512
        return bytes(volume.disk[at:at + 32])

    def get(self, **changes):
        volume, _ = self.volume(**changes)
        before, writes = self.disk_entry(volume), volume.writes
        status = volume.run_block(FX['FILEX_OP_GET_METADATA'], 0, bytes(16))
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        self.assertEqual((self.disk_entry(volume), volume.writes), (before, writes),
                         'GET менял запись')
        return bytes(volume.mem[0xA000:0xA010])

    def test_get_bad_stamps(self):
        out = self.get(c_date=0, access=BAD_DATE, m_time=BAD_TIME)
        self.assertEqual(out[4], 0, 'доли секунды заменённого создания')
        self.assertEqual(words(out, 5, 7, 9, 11, 13),
                         (0, FALLBACK_DATE, FALLBACK_DATE, 0, FALLBACK_DATE))

    def test_get_bad_modification_only(self):
        out = self.get(m_date=BAD_DATE)
        self.assertEqual(out[4], 0x77)
        self.assertEqual(words(out, 5, 7, 9, 11, 13),
                         (C_TIME, C_DATE, ACCESS, 0, FALLBACK_DATE))

    def test_get_tenth_over_199(self):
        for tenth, expected in ((199, 199), (200, 0), (255, 0)):
            with self.subTest(tenth):
                self.assertEqual(self.get(tenth=tenth)[4], expected)

    def set(self, mask, tenth=50, c_time=C_TIME, c_date=C_DATE, access=ACCESS,
            m_time=M_TIME, m_date=M_DATE):
        volume, _ = self.volume()
        block = bytes([16, 0, 0, mask, tenth]) + b''.join(
            v.to_bytes(2, 'little') for v in (c_time, c_date, access, m_time, m_date)) + b'\0'
        status = volume.run_block(FX['FILEX_OP_SET_METADATA'], 0, block)
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        self.assertEqual(bytes(volume.mem[0xA000:0xA00F]), block[:15],
                         'структура программы не меняется (кроме +15)')
        return self.disk_entry(volume)

    def test_set_good_stamps_as_given(self):
        entry = self.set(0x07, tenth=50, c_time=0, c_date=GOOD_DATE, access=GOOD_DATE,
                         m_time=0xBF7D, m_date=GOOD_DATE)          # 23:59:58
        self.assertEqual(entry[13], 50)
        self.assertEqual(words(entry, 14, 16, 18, 22, 24),
                         (0, GOOD_DATE, GOOD_DATE, 0xBF7D, GOOD_DATE))

    def test_set_bad_modification_takes_the_clock(self):
        for label, time, date in (('дата 0', 0, 0), ('31.04', 0, BAD_DATE),
                                  ('24:00', BAD_TIME, GOOD_DATE)):
            with self.subTest(label):
                entry = self.set(0x04, m_time=time, m_date=date)
                self.assertEqual(words(entry, 22, 24), (MODIFY_TIME, MODIFY_DATE))
                self.assertEqual(words(entry, 14, 16, 18), (C_TIME, C_DATE, ACCESS),
                                 'поля вне маски — прежние')

    def test_set_bad_creation_takes_the_clock_and_zero_tenth(self):
        entry = self.set(0x01, tenth=50, c_time=C_TIME, c_date=0)
        self.assertEqual(entry[13], 0)
        self.assertEqual(words(entry, 14, 16), (MODIFY_TIME, MODIFY_DATE))
        self.assertEqual(words(entry, 22, 24), (M_TIME, M_DATE))

    def test_set_bad_access_takes_the_clock_date(self):
        entry = self.set(0x02, access=BAD_DATE)
        self.assertEqual(words(entry, 18), (MODIFY_DATE,))

    def test_set_tenth_over_199(self):
        self.assertEqual(self.set(0x01, tenth=250)[13], 0)
        self.assertEqual(self.set(0x01, tenth=199)[13], 199)


if __name__ == '__main__':
    unittest.main(verbosity=2)
