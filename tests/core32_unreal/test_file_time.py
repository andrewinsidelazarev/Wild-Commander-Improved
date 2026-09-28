"""Время новой записи каталога: часы CMOS с проверкой, сбитые часы — 2026-01-01.

GENTRY (перенос шаблона обёртки MKFILE/MKDIR в ENTRY) исполняется настоящим
Z80 из собранного расширения. Порты часов подменены: #DFF7 выбирает регистр,
#BFF7 возвращает его значение в BCD.
"""
from __future__ import annotations

import unittest

import test_fat_allocator_hint as h

TEMPLATE = 0x9000


def bcd(value: int) -> int:
    return (value // 10) << 4 | value % 10


def fat_time(hours: int, minutes: int, seconds: int) -> int:
    return hours << 11 | minutes << 5 | seconds // 2


def fat_date(year: int, month: int, day: int) -> int:
    return (year - 1980) << 9 | month << 5 | day


def clock(year=2026, month=9, day=24, hours=21, minutes=47, seconds=58) -> dict:
    return {0: bcd(seconds), 2: bcd(minutes), 4: bcd(hours),
            7: bcd(day), 8: bcd(month), 9: bcd(year - 2000)}


class Clock:
    def __init__(self, registers: dict):
        self.registers = registers
        self.selected = None
        self.reads = []

    def out(self, port: int, value: int) -> None:
        assert port == 0xDFF7, f'запись в порт #{port:04X}'
        self.selected = value

    def inp(self, port: int) -> int:
        assert port == 0xBFF7, f'чтение порта #{port:04X}'
        self.reads.append(self.selected)
        return self.registers.get(self.selected, 0xFF)


class Ticking(Clock):
    """Часы, которые шагают после заданного числа чтений регистров."""

    def __init__(self, first: dict, then: dict, after: int):
        super().__init__(first)
        self.then, self.after = then, after

    def inp(self, port: int) -> int:
        value = super().inp(port)
        if len(self.reads) == self.after:
            self.registers = self.then
        return value


class Running(Clock):
    """Секунды идут при каждом их чтении: двух одинаковых снимков не выйдет."""

    def inp(self, port: int) -> int:
        value = super().inp(port)
        if self.selected == 0:
            seconds = (value >> 4) * 10 + (value & 15)
            self.registers[0] = bcd((seconds + 1) % 60)
        return value


def stamp(registers, template: bytes = bytes(range(0x40, 0x60)), *,
          found: bytes | None = None, found_stream: int = 0xF3, stream: int = 0xF4,
          param: int = 0xF800, memory: dict | None = None, found_name: int = 0,
          found_text: bytes = b''):
    """GENTRY: шаблон — в ENTRY, в DE — параметр MKFILE/MKDIR (param).
    found — последняя запись, найденная FENTRY в потоке found_stream по
    имени found_text, лежавшему по адресу found_name; stream — поток, в
    котором создаётся запись; memory — содержимое буферов на момент GENTRY."""
    harness = h.ExtensionHarness()
    rtc = registers if isinstance(registers, Clock) else Clock(registers)
    harness.machine.set_output_callback(rtc.out)
    harness.machine.set_input_callback(rtc.inp)
    harness.memory[TEMPLATE:TEMPLATE + 32] = template
    for address, data in (memory or {}).items():
        harness.memory[address:address + len(data)] = data
    if found is not None:
        at = harness.ext['WDOS_EXT.APPEND_ENTRY']
        harness.memory[at:at + 32] = found
        harness.memory[harness.ext['WDOS_EXT.FOUND_STREAM']] = found_stream
        h.put16(harness.memory, harness.ext['WDOS_EXT.FOUND_NAME'], found_name)
        text = harness.ext['WDOS_EXT.FOUND_TEXT']
        harness.memory[text:text + len(found_text) + 1] = found_text + bytes(1)
    harness.memory[0x6000] = stream
    harness.machine.hl = TEMPLATE
    harness.machine.de = param
    harness.invoke('CREATE_ENTRY')
    entry = harness.core['ENTRY']
    return bytes(harness.memory[entry:entry + 32]), template, rtc


def fields(entry: bytes) -> dict:
    word = lambda offset: entry[offset] | entry[offset + 1] << 8
    return dict(tenth=entry[13], create_time=word(14), create_date=word(16),
                access_date=word(18), modify_time=word(22), modify_date=word(24))


FALLBACK = dict(tenth=0, create_time=0, create_date=fat_date(2026, 1, 1),
                access_date=fat_date(2026, 1, 1), modify_time=0,
                modify_date=fat_date(2026, 1, 1))


class Gentry(unittest.TestCase):
    """GENTRY (#4033) — простой перенос 32 байт, как было всегда: его зовут внешние
    плагины. Время новой записи ставит только CREATE_ENTRY (API 72/73 WC)."""

    def test_plain_copy_without_clock(self):
        harness = h.ExtensionHarness()
        rtc = Clock(clock())
        harness.machine.set_output_callback(rtc.out)
        harness.machine.set_input_callback(rtc.inp)
        template = bytes(range(0x40, 0x60))
        harness.memory[TEMPLATE:TEMPLATE + 32] = template
        harness.machine.hl = TEMPLATE
        harness.invoke('COPY_TO_ENTRY')
        entry = harness.core['ENTRY']
        self.assertEqual(bytes(harness.memory[entry:entry + 32]), template)
        self.assertEqual(rtc.reads, [], 'часы не читаются')


class Stamp(unittest.TestCase):

    def test_running_clock_goes_into_all_time_fields(self):
        entry, template, rtc = stamp(clock())
        time, date = fat_time(21, 47, 58), fat_date(2026, 9, 24)
        self.assertEqual(fields(entry), dict(tenth=0, create_time=time, create_date=date,
                                             access_date=date, modify_time=time,
                                             modify_date=date))
        self.assertEqual(sorted(set(rtc.reads)), [0, 2, 4, 7, 8, 9])

    def test_other_fields_come_from_the_template(self):
        entry, template, _ = stamp(clock())
        for offset in list(range(13)) + [20, 21] + list(range(26, 32)):
            self.assertEqual(entry[offset], template[offset], f'байт +{offset}')

    def test_edge_values_are_accepted(self):
        entry, _, _ = stamp(clock(2099, 12, 31, 23, 59, 59))
        self.assertEqual(fields(entry)['create_date'], fat_date(2099, 12, 31))
        self.assertEqual(fields(entry)['create_time'], fat_time(23, 59, 59))
        entry, _, _ = stamp(clock(2026, 1, 1, 0, 0, 0))
        self.assertEqual(fields(entry)['modify_date'], fat_date(2026, 1, 1))
        self.assertEqual(fields(entry)['modify_time'], 0)
        entry, _, _ = stamp(clock(2026, 3, 5, 12, 0, 0))
        self.assertEqual(fields(entry)['create_time'], fat_time(12, 0, 0),
                         'настоящее время 2026 года — не запасное')

    def test_year_before_2026_means_broken_clock(self):
        for year in (2000, 2025):
            with self.subTest(year):
                entry, _, _ = stamp(clock(year, 6, 15, 10, 30, 0))
                self.assertEqual(fields(entry), FALLBACK)

    def test_tick_during_reading_takes_a_fresh_snapshot(self):
        # Полночь посреди чтения: время прочитано старое, день — уже новый.
        rtc = Ticking(clock(2026, 9, 24, 23, 59, 59), clock(2026, 9, 25, 0, 0, 0), after=3)
        entry, _, _ = stamp(rtc)
        self.assertEqual(fields(entry)['create_date'], fat_date(2026, 9, 25))
        self.assertEqual(fields(entry)['create_time'], 0)

    def test_clock_that_never_settles_is_broken(self):
        entry, _, _ = stamp(Running(clock()))
        self.assertEqual(fields(entry), FALLBACK)

    def test_day_must_exist_in_its_month(self):
        broken = [(2026, 2, 29), (2026, 2, 30), (2026, 2, 31), (2026, 4, 31), (2026, 6, 31),
                  (2026, 9, 31), (2026, 11, 31), (2027, 2, 29)]
        for year, month, day in broken:
            with self.subTest(f'{day:02d}.{month:02d}.{year}'):
                entry, _, _ = stamp(clock(year, month, day, 10, 0, 0))
                self.assertEqual(fields(entry), FALLBACK)
        good = [(2028, 2, 29), (2096, 2, 29), (2026, 2, 28), (2026, 4, 30),
                (2026, 1, 31), (2026, 12, 31)]
        for year, month, day in good:
            with self.subTest(f'{day:02d}.{month:02d}.{year}'):
                entry, _, _ = stamp(clock(year, month, day, 10, 0, 0))
                self.assertEqual(fields(entry)['create_date'], fat_date(year, month, day))

    def test_uninitialised_clock_gives_2026_01_01(self):
        entry, _, _ = stamp({})                 # все регистры читаются как #FF
        self.assertEqual(fields(entry), FALLBACK)

    def test_each_broken_field_gives_2026_01_01(self):
        cases = {
            'месяц 0': (8, 0x00), 'месяц 13': (8, 0x13), 'день 0': (7, 0x00),
            'день 32': (7, 0x32), 'часы 24': (4, 0x24), 'минуты 60': (2, 0x60),
            'секунды 60': (0, 0x60), 'единицы не BCD': (2, 0x3A),
            'десятки не BCD': (9, 0xA5),
        }
        for label, (register, value) in cases.items():
            with self.subTest(label):
                registers = clock()
                registers[register] = value
                entry, _, _ = stamp(registers)
                self.assertEqual(fields(entry), FALLBACK)


def record(name: bytes, attr: int, cluster: int, size: int, *, tenth: int,
           created: tuple, accessed: tuple, modified: tuple) -> bytes:
    """32-байтовая запись каталога FAT."""
    word = lambda value: value.to_bytes(2, 'little')
    return (name + bytes([attr, 0x18, tenth]) + word(fat_time(*created[3:]))
            + word(fat_date(*created[:3])) + word(fat_date(*accessed))
            + word(cluster >> 16) + word(fat_time(*modified[3:]))
            + word(fat_date(*modified[:3])) + word(cluster & 0xFFFF)
            + size.to_bytes(4, 'little'))


ORIGINAL = record(b'TCOPY   TXT', 0x20, 0x12345, 15, tenth=7,
                  created=(2020, 1, 2, 3, 4, 0), accessed=(2020, 1, 3),
                  modified=(2021, 5, 6, 7, 8, 10))


def wiped(entry: bytes) -> bytes:
    """Шаблон обёртки: запись найденного файла, время затёрто часами WC."""
    out = bytearray(entry)
    for offset in (14, 16, 18, 22, 24):
        out[offset:offset + 2] = b'\x55\x55'
    return bytes(out)


FOLDER = record(b'GAMES      ', 0x10, 0x345, 0, tenth=0,
                created=(2019, 2, 3, 4, 5, 6), accessed=(2019, 2, 3),
                modified=(2019, 2, 3, 4, 5, 6))

# Буфер WC (LOBU): COPYF и DIRCOPY ищут источник по [тип,имя,0] с LOBU+4 и
# создают копию из того же буфера — MKFILE по LOBU ([атрибут][размер][имя]),
# MKDIR по LOBU+5 ([имя,0]).
LOBU = 0xB000
NAME = b'WC_History.txt'                        # длинное имя тоже узнаётся


def copyf(name=NAME, found=ORIGINAL, **options):
    """COPYF: MKFILE из LOBU после FENTRY по LOBU+4 в другой панели."""
    memory = {LOBU: bytes([0]) + (15).to_bytes(4, 'little') + name + b'\0'}
    defaults = dict(found=found, param=LOBU, found_name=LOBU + 5, found_text=NAME,
                    memory=memory)
    defaults.update(options)
    return stamp(clock(), wiped(found), **defaults)


NOW_TIME, NOW_DATE = fat_time(21, 47, 58), fat_date(2026, 9, 24)     # clock()


def copied(original: dict) -> dict:
    """Поля копии: штампы создания и изменения — оригинала, дата доступа —
    текущая (копию только что записали; с 2026-09-26)."""
    return dict(original, access_date=NOW_DATE)


class Copy(unittest.TestCase):
    """Копия в другую панель сохраняет время оригинала, остальное — часы."""

    def test_file_copy_keeps_original_time(self):
        entry, _, _ = copyf()
        self.assertEqual(fields(entry), copied(fields(ORIGINAL)))

    def test_directory_copy_keeps_original_time(self):
        entry, _, _ = stamp(clock(), wiped(FOLDER), found=FOLDER, param=LOBU + 5,
                            found_name=LOBU + 5, found_text=b'GAMES',
                            memory={LOBU + 5: b'GAMES\0'})
        self.assertEqual(fields(entry), copied(fields(FOLDER)))

    def test_new_folder_in_other_panel_takes_the_clock(self):
        # Стенд: F5 нашёл TCOPY.TXT в левой панели, затем F7 в правой создал
        # каталог из своего буфера — это не копия.
        entry, _, _ = stamp(clock(), wiped(ORIGINAL), found=ORIGINAL, param=0xB400,
                            found_name=LOBU + 5, found_text=NAME,
                            memory={0xB400: b'A\0', LOBU + 5: NAME + b'\0'})
        self.assertEqual(fields(entry)['create_time'], fat_time(21, 47, 58))

    def test_recreating_in_the_same_stream_takes_the_clock(self):
        entry, _, _ = copyf(stream=0xF3)
        self.assertEqual(fields(entry)['modify_date'], fat_date(2026, 9, 24))

    def test_other_name_in_the_same_buffer_takes_the_clock(self):
        entry, _, _ = copyf(name=b'WC_Histori.txt')        # та же длина, другая сумма
        self.assertEqual(fields(entry)['create_time'], fat_time(21, 47, 58))

    def test_permuted_name_is_not_a_copy(self):
        # Пример аудита: у WC_History.txt и CW_History.txt одинаковые длина и
        # сумма байтов — прежний отпечаток принимал новое имя за прежнее.
        entry, _, _ = copyf(name=b'CW_History.txt')
        self.assertEqual(fields(entry)['create_time'], fat_time(21, 47, 58))

    def test_type_must_match(self):
        entry, _, _ = copyf(found=FOLDER)                     # MKFILE по найденному каталогу
        self.assertEqual(fields(entry)['create_time'], fat_time(21, 47, 58))
        entry, _, _ = stamp(clock(), wiped(ORIGINAL), found=ORIGINAL, param=LOBU + 5,
                            found_name=LOBU + 5, found_text=NAME,
                            memory={LOBU + 5: NAME + b'\0'})  # MKDIR по найденному файлу
        self.assertEqual(fields(entry)['create_time'], fat_time(21, 47, 58))

    def test_found_entry_remembers_stream_and_name(self):
        harness = h.ExtensionHarness()
        entry = harness.core['ENTRY']
        harness.memory[entry:entry + 32] = ORIGINAL
        harness.memory[LOBU + 4:LOBU + 5 + len(NAME) + 1] = b'\0' + NAME + b'\0'
        h.put16(harness.memory, harness.core['CGDE'], LOBU + 4)
        harness.memory[0x6000] = 0xF4
        harness.machine.de = 0x9100
        harness.invoke('COPY_ENTRY_AND_CAPTURE')
        self.assertEqual(harness.memory[harness.ext['WDOS_EXT.FOUND_STREAM']], 0xF4)
        self.assertEqual(h.get16(harness.memory, harness.ext['WDOS_EXT.FOUND_NAME']), LOBU + 5)
        text = harness.ext['WDOS_EXT.FOUND_TEXT']
        self.assertEqual(bytes(harness.memory[text:text + len(NAME) + 1]), NAME + bytes(1),
                         'имя запомнено целиком')
        at = harness.ext['WDOS_EXT.APPEND_ENTRY']
        self.assertEqual(bytes(harness.memory[at:at + 32]), ORIGINAL)
        self.assertEqual(bytes(harness.memory[0x9100:0x9120]), ORIGINAL)


def with_stamps(entry: bytes, **words) -> bytes:
    """Запись с заменёнными полями: tenth — байт, остальные — слова FAT."""
    offsets = dict(create_time=14, create_date=16, access_date=18, modify_time=22,
                   modify_date=24)
    out = bytearray(entry)
    for name, value in words.items():
        if name == 'tenth':
            out[13] = value
        else:
            out[offsets[name]:offsets[name] + 2] = value.to_bytes(2, 'little')
    return bytes(out)


# Штампы, которых нет в календаре: (время, дата). Год FAT любой — 1980..2107.
BAD_STAMPS = {
    'дата 0': (0, 0),
    'месяц 0': (0, (2021 - 1980) << 9 | 0 << 5 | 6),
    'месяц 13': (0, (2021 - 1980) << 9 | 13 << 5 | 6),
    'месяц 15': (0, (2021 - 1980) << 9 | 15 << 5 | 6),
    'день 0': (0, (2021 - 1980) << 9 | 5 << 5 | 0),
    '31.04': (0, fat_date(2021, 4, 31)),
    '30.02.2024': (0, fat_date(2024, 2, 30)),
    '29.02.2021': (0, fat_date(2021, 2, 29)),
    'часы 24': (24 << 11, fat_date(2021, 5, 6)),
    'часы 31': (31 << 11 | 59 << 5, fat_date(2021, 5, 6)),
    'минуты 60': (12 << 11 | 60 << 5, fat_date(2021, 5, 6)),
    'минуты 63': (12 << 11 | 63 << 5, fat_date(2021, 5, 6)),
    'секунды 60': (12 << 11 | 30, fat_date(2021, 5, 6)),
    'всё #FFFF': (0xFFFF, 0xFFFF),
}
# Крайние штампы, которые в календаре есть.
GOOD_STAMPS = {
    '1980-01-01 00:00:00': (0, fat_date(1980, 1, 1)),
    '2107-12-31 23:59:58': (fat_time(23, 59, 58), fat_date(2107, 12, 31)),
    '29.02.2024': (fat_time(12, 0, 0), fat_date(2024, 2, 29)),
    '29.02.2000': (fat_time(12, 0, 0), fat_date(2000, 2, 29)),
    '31.12.2099 23:59:58': (fat_time(23, 59, 58), fat_date(2099, 12, 31)),
    '30.11.2021': (fat_time(1, 2, 4), fat_date(2021, 11, 30)),
}


class CopyDates(unittest.TestCase):
    """С 2026-09-26: у копии каждый штамп оригинала (изменения, создания) —
    только если он есть в календаре; иначе — текущий по часам."""

    def test_bad_modification_takes_the_clock(self):
        for label, (time, date) in BAD_STAMPS.items():
            with self.subTest(label):
                found = with_stamps(ORIGINAL, modify_time=time, modify_date=date)
                entry, _, _ = copyf(found=found)
                self.assertEqual(fields(entry), copied(dict(
                    fields(ORIGINAL), modify_time=NOW_TIME, modify_date=NOW_DATE)))

    def test_bad_creation_takes_the_clock_and_drops_tenth(self):
        for label, (time, date) in BAD_STAMPS.items():
            with self.subTest(label):
                found = with_stamps(ORIGINAL, create_time=time, create_date=date)
                entry, _, _ = copyf(found=found)
                self.assertEqual(fields(entry), copied(dict(
                    fields(ORIGINAL), tenth=0, create_time=NOW_TIME,
                    create_date=NOW_DATE)))

    def test_both_bad_is_a_new_file(self):
        found = with_stamps(ORIGINAL, create_date=0, modify_date=0)
        entry, _, _ = copyf(found=found)
        self.assertEqual(fields(entry), dict(tenth=0, create_time=NOW_TIME,
                                             create_date=NOW_DATE, access_date=NOW_DATE,
                                             modify_time=NOW_TIME, modify_date=NOW_DATE))

    def test_edge_stamps_are_kept(self):
        for label, (time, date) in GOOD_STAMPS.items():
            with self.subTest(label):
                found = with_stamps(ORIGINAL, create_time=time, create_date=date,
                                    modify_time=time, modify_date=date)
                entry, _, _ = copyf(found=found)
                self.assertEqual(fields(entry), copied(fields(found)))

    def test_access_date_of_the_original_is_not_taken(self):
        found = with_stamps(ORIGINAL, access_date=fat_date(2025, 3, 4))
        entry, _, _ = copyf(found=found)
        self.assertEqual(fields(entry)['access_date'], NOW_DATE)

    def test_tenth_over_199_is_dropped(self):
        for tenth, expected in ((0, 0), (199, 199), (200, 0), (255, 0)):
            with self.subTest(tenth):
                entry, _, _ = copyf(found=with_stamps(ORIGINAL, tenth=tenth))
                self.assertEqual(fields(entry)['tenth'], expected)

    def test_bad_source_with_broken_clock_gives_2026_01_01(self):
        found = with_stamps(ORIGINAL, modify_date=0)
        memory = {LOBU: bytes([0]) + (15).to_bytes(4, 'little') + NAME + b'\0'}
        entry, _, _ = stamp({}, wiped(found), found=found, param=LOBU,
                            found_name=LOBU + 5, found_text=NAME, memory=memory)
        self.assertEqual(fields(entry)['modify_date'], fat_date(2026, 1, 1))
        self.assertEqual(fields(entry)['modify_time'], 0)
        self.assertEqual(fields(entry)['create_date'], fields(ORIGINAL)['create_date'])


class Append(unittest.TestCase):
    """Дозапись меняет файл: время и дата изменения и дата доступа — по часам."""

    def append(self, registers):
        harness = h.ExtensionHarness()
        rtc = Clock(registers)
        harness.machine.set_output_callback(rtc.out)
        harness.machine.set_input_callback(rtc.inp)
        proz = harness.core['PROZ']                     # позиционирование на LBA
        harness.callouts[proz] = harness._position
        harness.machine.set_breakpoint(proz)
        sector = bytearray(512)
        sector[64:96] = ORIGINAL
        harness.sector_overrides[1000] = bytes(sector)
        ext = lambda name: harness.ext['WDOS_EXT.' + name]
        h.put32(harness.memory, ext('APPEND_DIRECTORY_LBA'), 1000)
        h.put16(harness.memory, ext('APPEND_DIRECTORY_OFFSET'), 64)
        harness.memory[ext('APPEND_ENTRY'):ext('APPEND_ENTRY') + 32] = ORIGINAL
        h.put32(harness.memory, ext('APPEND_WORK_SIZE'), 100)
        h.put32(harness.memory, ext('APPEND_WORK_FIRST'), 0x12345)
        harness.invoke('APPEND_UPDATE_DIRECTORY')
        self.assertTrue(harness.machine.f & h.ZERO_FLAG, 'запись каталога не удалась')
        return harness.written_sectors[-1][64:96]

    def test_append_stamps_modification(self):
        slot = self.append(clock())
        now_time, now_date = fat_time(21, 47, 58), fat_date(2026, 9, 24)
        self.assertEqual(fields(slot), dict(fields(ORIGINAL), modify_time=now_time,
                                            modify_date=now_date, access_date=now_date))
        self.assertEqual(int.from_bytes(slot[28:32], 'little'), 100)
        self.assertEqual(slot[26] | slot[27] << 8 | slot[20] << 16 | slot[21] << 24, 0x12345)

    def test_append_with_broken_clock(self):
        slot = self.append({})
        fallback = fat_date(2026, 1, 1)
        self.assertEqual(fields(slot), dict(fields(ORIGINAL), modify_time=0,
                                            modify_date=fallback, access_date=fallback))


class StatusLine(unittest.TestCase):
    """Строка информации под панелью: размер или <DIR>, дата и время."""

    WC_LOBU, WC_ARRR = 0xB000, 0x7F2C
    WINDOW = 0x1234                         # окно панели: +4 — ширина, 40 или 45

    def line(self, size=0, date=0, time=0, directory=False, width=40):
        harness = h.ExtensionHarness()
        name = b'tcopy   .txt '
        harness.memory[self.WC_LOBU:self.WC_LOBU + 13] = name
        harness.memory[self.WC_LOBU + 13:self.WC_LOBU + 44] = b'#' * 31     # мусор
        h.put16(harness.memory, self.WC_LOBU + 44, time)    # элемент: время, затем дата
        h.put16(harness.memory, self.WC_LOBU + 46, date)
        h.put32(harness.memory, self.WC_ARRR, size)
        harness.memory[self.WINDOW + 4] = width
        harness.machine.ix = self.WINDOW
        harness.machine.f = h.ZERO_FLAG if directory else 0
        harness.invoke('STATUS_TAIL')
        self.assertEqual(harness.machine.ix, self.WINDOW, 'IX нужен STATUS для печати')
        text = bytes(harness.memory[self.WC_LOBU:self.WC_LOBU + width - 2]).decode()
        self.assertTrue(text.startswith(name.decode()))
        self.assertNotIn('#', text, 'строка заполнена во всю ширину панели')
        return text[13:]

    def test_file_with_date(self):
        self.assertEqual(self.line(15, fat_date(2026, 9, 24), fat_time(21, 47, 0)),
                         '        15 24.09.26 21:47')

    def test_thousands_are_spaced(self):
        self.assertEqual(self.line(25600, fat_date(2024, 3, 1), fat_time(12, 5, 0)),
                         '    25 600 01.03.24 12:05')
        self.assertEqual(self.line(78643200, fat_date(2026, 9, 24), fat_time(22, 10, 0)),
                         '78 643 200 24.09.26 22:10')

    def test_long_sizes_have_no_spaces(self):
        self.assertEqual(self.line(123456789)[:10], ' 123456789')
        self.assertEqual(self.line(0xFFFFFFFF)[:10], '4294967295')

    def test_zero_size(self):
        self.assertEqual(self.line(0)[:10], '         0')

    def test_directory(self):
        self.assertEqual(self.line(0, fat_date(2020, 1, 2), fat_time(3, 4, 0), directory=True),
                         '<DIR>      02.01.20 03:04')

    def test_record_without_time_shows_no_date(self):
        self.assertEqual(self.line(15), '        15' + ' ' * 15)

    def test_years_around_the_century(self):
        self.assertEqual(self.line(1, fat_date(1999, 12, 31), 0)[11:19], '31.12.99')
        self.assertEqual(self.line(1, fat_date(2107, 1, 1), 0)[11:19], '01.01.07')

    # Режим 90 колонок: окно панели шириной 45, строка — 43 знака.
    def test_wide_panel_spaces_every_size_and_shows_full_year(self):
        self.assertEqual(self.line(0xFFFFFFFF, fat_date(2026, 9, 24), fat_time(21, 47, 0), width=45),
                         '4 294 967 295 24.09.2026 21:47')
        self.assertEqual(self.line(123456789, width=45)[:13], '  123 456 789')
        self.assertEqual(self.line(15, width=45), ' ' * 11 + '15' + ' ' * 17)

    def test_wide_panel_directory_and_centuries(self):
        self.assertEqual(self.line(0, fat_date(1999, 12, 31), fat_time(23, 59, 0),
                                   directory=True, width=45),
                         '<DIR>' + ' ' * 9 + '31.12.1999 23:59')
        self.assertEqual(self.line(1, fat_date(1980, 1, 1), 0, width=45)[14:24], '01.01.1980')
        self.assertEqual(self.line(1, fat_date(2107, 12, 31), 0, width=45)[14:24], '31.12.2107')


if __name__ == '__main__':
    unittest.main(verbosity=2)
