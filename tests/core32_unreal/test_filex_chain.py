"""FILEX: исправления, перенесённые из драйвера FAT32 (2026-10-10).

Исполняются настоящие FILEX, ядро и расширение на диске в памяти
(core32_ramdisk.Volume): файл AUDIT.BIN из 1536 байт #A5 на кластерах 3, 4, 5,
корень — кластер 2, кластер — один сектор.

* Цепочка выбранного файла проверяется до конца (FILEX_FILE_CHAIN_GUARD):
  цикл уводил чтение и WRITE_AT в начало файла, а усечение освобождало
  оставляемые кластеры; кластер корня в цепочке вёл запись в корень.
  Проверенная запись не обходится повторно.
* Переход по цепочке (FILEX_NEXT_CLUSTER) отвергает кластер корня и после
  проверки: FAT могли изменить между вызовами.
* WRITE_AT за концом файла при отказе роста отвечал OK: FILEX_CLEAR_RESULT
  затирал код (R5-1).
* GET_FS_INFO: сектор FSInfo — только внутри резервной области, нули перед
  #55AA, подсказка следующего свободного — кластер этого тома (R6-4); флаг
  REFRESH_FREE пересчитывает свободные кластеры по FAT (R6-3).
"""
import unittest

import core32_machine as p
from test_filex_time import ClockVolume
from test_filex_truncate import FaultyVolume

FX = p.FX
BLOCK, BUFFER = 0x9000, 0xA000
ORIGINAL = 1536


def call(volume, operation, offset=0, data=b'', length=None, flags=0):
    """Блок API 77: данные data — в BUFFER; length — длина без данных."""
    cpu, mem = volume.cpu, volume.mem
    mem[BLOCK:BLOCK + 32] = bytes(32)
    mem[BLOCK + FX['FILEX_P_SIZE']] = 32
    mem[BLOCK + FX['FILEX_P_VERSION']] = FX['FILEX_API_VERSION']
    mem[BLOCK + FX['FILEX_P_OPERATION']] = operation
    mem[BLOCK + FX['FILEX_P_FLAGS']] = flags
    p.h.put32(mem, BLOCK + FX['FILEX_P_OFFSET'], offset)
    if data:
        mem[BUFFER:BUFFER + len(data)] = data
    size = len(data) if length is None else length
    if size:
        p.h.put16(mem, BLOCK + FX['FILEX_P_BUFFER'], BUFFER)
        p.h.put16(mem, BLOCK + FX['FILEX_P_LENGTH'], size)
    cpu.hl, cpu.pc, cpu.sp = BLOCK, FX['FILEX_ENTRY'], p.STACK
    p.h.put16(mem, p.STACK, p.STOP)
    stops = {p.STOP, *volume.callbacks}
    for address in stops:
        cpu.set_breakpoint(address)
    try:
        for _ in range(200000):
            cpu.ticks_to_stop = 1000000
            if not cpu.run() & 2:
                continue
            if cpu.pc == p.STOP:
                return mem[BLOCK + FX['FILEX_P_STATUS']]
            if cpu.pc in volume.callbacks:
                volume.callbacks[cpu.pc]()
    finally:
        for address in stops:
            cpu.clear_breakpoint(address)
    raise AssertionError('FILEX не вернулся')


def read_at(volume, offset=0, length=512):
    return call(volume, FX['FILEX_OP_READ_AT'], offset, length=length)


class FileChain(unittest.TestCase):

    def volume(self):
        return ClockVolume(original=ORIGINAL, free=20)

    def test_plain_read(self):
        volume = self.volume()
        self.assertEqual(read_at(volume, 1024), FX['FILEX_STATUS_OK'])
        self.assertEqual(bytes(volume.mem[BUFFER:BUFFER + 512]), bytes([0xA5]) * 512)

    def test_cycle_inside_the_data_is_refused(self):
        # 3 → 4 → 3: чтение третьего сектора прежде молча давало первый.
        volume = self.volume()
        volume.set_fat(4, 3)
        self.assertEqual(read_at(volume, 1024), FX['FILEX_STATUS_FAT'])

    def test_root_cluster_in_the_chain_is_refused(self):
        volume = self.volume()
        volume.set_fat(4, 2)                                 # 4 → корень
        self.assertEqual(read_at(volume, 0), FX['FILEX_STATUS_FAT'])

    def test_truncation_of_a_cycle_past_the_data_frees_nothing(self):
        # 3 → 4 → 5 → 4: длина данных цела, цикл — за ней. Усечение до двух
        # кластеров прежде ставило EOC у 4 и освобождало хвост 5 → 4: кластер
        # 4 файла уходил в свободные.
        volume = FaultyVolume()
        volume.set_fat(5, 4)
        before = bytes(volume.disk)
        self.assertEqual(volume.truncate(513), FX['FILEX_STATUS_FAT'])
        self.assertEqual(bytes(volume.disk), before, 'усечение испорченной цепочки писало на диск')

    def test_chain_is_walked_once_per_entry(self):
        # Проверенная запись повторно не обходится: цикл, появившийся за
        # концом данных после первой проверки, второе чтение не замечает.
        volume = self.volume()
        self.assertEqual(read_at(volume, 0), FX['FILEX_STATUS_OK'])
        volume.set_fat(5, 4)
        self.assertEqual(read_at(volume, 0), FX['FILEX_STATUS_OK'])

    def test_root_link_after_the_check_is_refused(self):
        # Цепочка проверена и запомнена, затем ссылка 4 ушла в корень: переход
        # по ней прежде читал корень как данные файла.
        volume = self.volume()
        self.assertEqual(read_at(volume, 0), FX['FILEX_STATUS_OK'])
        volume.set_fat(4, 2)
        self.assertEqual(read_at(volume, 1024), FX['FILEX_STATUS_FAT'])

    def test_empty_file_without_cluster_is_accepted(self):
        volume = self.volume()
        start = volume.data_start * 512
        volume.disk[start + 26:start + 28] = bytes(2)
        volume.disk[start + 28:start + 32] = bytes(4)
        ext = volume.pages[0xE8]
        offset = volume.ext('APPEND_ENTRY') - 0xC000
        ext[offset:offset + 32] = volume.disk[start:start + 32]
        self.assertEqual(call(volume, FX['FILEX_OP_SET_EOF32'], 0), FX['FILEX_STATUS_OK'])


class WriteAfterEnd(unittest.TestCase):

    def test_growth_failure_is_reported(self):
        # Отказ первой записи роста (нули промежутка): прежде FILEX_CLEAR_RESULT
        # затирал код, и WRITE_AT отвечал OK (R5-1).
        volume = FaultyVolume(fail_writes={1})
        status = call(volume, FX['FILEX_OP_WRITE_AT'], ORIGINAL + 1000, b'Z' * 10)
        self.assertNotEqual(status, FX['FILEX_STATUS_OK'])
        self.assertEqual(p.h.get32(volume.mem, BLOCK + FX['FILEX_P_RESULT_COUNT']), 0,
                         'счётчик результата не обнулён')

    def test_plain_write_after_end(self):
        volume = FaultyVolume()
        status = call(volume, FX['FILEX_OP_WRITE_AT'], ORIGINAL + 1000, b'Z' * 10)
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        self.assertEqual(volume.size(), ORIGINAL + 1010)


def bpb(volume):
    sector = bytearray(512)
    p.h.put16(sector, 11, 512)
    sector[13] = 1
    p.h.put16(sector, 14, volume.fat_start)
    sector[16] = 1
    p.h.put32(sector, 32, len(volume.disk) // 512)
    p.h.put32(sector, 36, volume.fat_sectors)
    p.h.put32(sector, 44, 2)
    p.h.put16(sector, 48, 1)
    p.h.put32(sector, 67, 0x12345678)
    sector[71:82] = b'NO NAME    '
    sector[510:512] = b'\x55\xAA'
    return bytes(sector)


class FsInfo(unittest.TestCase):

    def volume(self, free_count=None):
        volume = ClockVolume(original=ORIGINAL, free=300)
        volume.disk[0:512] = bpb(volume)
        p.h.put16(volume.mem, volume.core('BREZS'), volume.fat_start)
        if free_count is not None:
            p.h.put32(volume.disk, 512 + 488, free_count)
        return volume

    def info(self, volume, flags=0):
        status = call(volume, FX['FILEX_OP_GET_FS_INFO'], length=FX['FILEX_FS_SIZE'], flags=flags)
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        out = bytes(volume.mem[BUFFER:BUFFER + FX['FILEX_FS_SIZE']])
        return (out[FX['FILEX_FS_O_FLAGS']],
                p.h.get32(out, FX['FILEX_FS_O_FREE_CLUSTERS']),
                p.h.get32(out, FX['FILEX_FS_O_NEXT_FREE']))

    def free_in_fat(self, volume):
        return sum(volume.fat(n) == 0 for n in range(2, volume.limit))

    def test_plain_fsinfo(self):
        volume = self.volume(free_count=100)
        flags, free, hint = self.info(volume)
        self.assertTrue(flags & FX['FILEX_FS_FLAG_FREE_KNOWN'])
        self.assertEqual((free, hint), (100, 3 + ORIGINAL // 512))

    def test_fsinfo_outside_reserved_area_is_ignored(self):
        # BPB_FSInfo указывает в область данных, где лежит сектор с подписями
        # FSInfo: прежде его байты выдавались за число свободных кластеров.
        volume = self.volume(free_count=100)
        fake = volume.data_start + 10
        volume.disk[fake * 512:fake * 512 + 512] = volume.disk[512:1024]
        p.h.put32(volume.mem, volume.core('FSINF'), fake)
        flags, free, hint = self.info(volume)
        self.assertFalse(flags & FX['FILEX_FS_FLAG_FREE_KNOWN'])
        self.assertEqual((free, hint), (0xFFFFFFFF, 0xFFFFFFFF))

    def test_nonzero_bytes_before_signature_are_refused(self):
        volume = self.volume(free_count=100)
        volume.disk[512 + 508] = 1
        flags, free, hint = self.info(volume)
        self.assertFalse(flags & FX['FILEX_FS_FLAG_FREE_KNOWN'])
        self.assertEqual(hint, 0xFFFFFFFF)

    def test_next_free_outside_the_volume_is_refused(self):
        volume = self.volume(free_count=100)
        p.h.put32(volume.disk, 512 + 492, volume.limit + 5)
        flags, free, hint = self.info(volume)
        self.assertEqual(free, 100)
        self.assertEqual(hint, 0xFFFFFFFF, 'подсказка за концом тома отдана как есть')

    def test_refresh_counts_free_clusters(self):
        # Флаг REFRESH_FREE прежде принимался и ничего не менял (R6-3).
        volume = self.volume()
        volume.set_fat(volume.limit - 1, 0x0FFFFFFF)
        flags, free, _ = self.info(volume, flags=FX['FILEX_FLAG_REFRESH_FREE'])
        self.assertTrue(flags & FX['FILEX_FS_FLAG_FREE_KNOWN'])
        self.assertEqual(free, self.free_in_fat(volume))

    def test_refresh_with_bad_fsinfo_still_counts(self):
        volume = self.volume(free_count=100)
        p.h.put32(volume.mem, volume.core('FSINF'), 0)
        flags, free, _ = self.info(volume, flags=FX['FILEX_FLAG_REFRESH_FREE'])
        self.assertTrue(flags & FX['FILEX_FS_FLAG_FREE_KNOWN'])
        self.assertEqual(free, self.free_in_fat(volume))


class TimedVolume(ClockVolume):
    """Часы CMOS свои у каждого диска: время между вызовами можно сдвинуть."""

    def __init__(self, **options):
        from test_filex_time import RTC
        self.rtc = dict(RTC)
        super().__init__(**options)

    def inp(self, port):
        if port == 0xBFF7:
            return self.rtc.get(self.selected, 0xFF)
        return super().inp(port)


class LocateCache(unittest.TestCase):
    """Claude - 2026-10-11: READ_AT/WRITE_AT искали кластер от начала файла
    (FILEX_LOCATE_OFFSET) и читали сектор FAT на каждую ссылку цепочки: окно
    SMB на глубине 100 МБ — около 3200 чтений. Теперь обход идёт от последнего
    найденного кластера, пока не сменилось поколение FAT ядра, и сектор FAT
    читается один раз на 128 ссылок. Файл — 400 кластеров по одному сектору,
    у каждого кластера свой байт данных."""

    CLUSTERS = 400

    def volume(self):
        volume = TimedVolume(original=self.CLUSTERS * 512, free=20)
        for cluster in range(3, 3 + self.CLUSTERS):
            at = (volume.data_start + cluster - 2) * 512
            volume.disk[at:at + 512] = bytes([cluster & 0xFF]) * 512
        return volume

    def read(self, volume, index):
        """Сектор номер index файла; сколько секторов прочитано с диска."""
        before = volume.reads
        self.assertEqual(read_at(volume, index * 512), FX['FILEX_STATUS_OK'])
        return bytes(volume.mem[BUFFER:BUFFER + 512]), volume.reads - before

    def bump(self, volume):
        """Запись FAT ядром (SAVE_FAT_SECTOR) меняет поколение FAT."""
        at = volume.core('FAT_CACHE_GENERATION')
        volume.mem[at] = (volume.mem[at] + 1) & 0xFF

    def test_deep_read_reads_fat_once_per_sector(self):
        volume = self.volume()
        data, reads = self.read(volume, self.CLUSTERS - 1)
        self.assertEqual(data, bytes([(2 + self.CLUSTERS) & 0xFF]) * 512)
        self.assertLess(reads, 20, 'обход цепочки читал сектор FAT на каждую ссылку')

    def test_next_window_walks_from_the_last_cluster(self):
        volume = self.volume()
        self.read(volume, 300)
        data, reads = self.read(volume, 301)
        self.assertEqual(data, bytes([304 & 0xFF]) * 512)
        self.assertLessEqual(reads, 5, 'второе окно снова шло от первого кластера')

    def test_earlier_offset_walks_from_the_start(self):
        volume = self.volume()
        self.read(volume, 300)
        data, _ = self.read(volume, 10)
        self.assertEqual(data, bytes([13]) * 512)
        data, _ = self.read(volume, 11)
        self.assertEqual(data, bytes([14]) * 512)

    def test_new_fat_generation_drops_the_position(self):
        # Кластер 103 вынут из цепочки: сектор 150 — теперь кластер 154.
        volume = self.volume()
        self.read(volume, 150)
        volume.set_fat(102, 104)
        self.bump(volume)
        data, _ = self.read(volume, 150)
        self.assertEqual(data, bytes([154]) * 512)

    def test_write_inside_then_read_on(self):
        volume = self.volume()
        status = call(volume, FX['FILEX_OP_WRITE_AT'], 200 * 512, b'\x5A' * 512)
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        data, reads = self.read(volume, 201)
        self.assertEqual(data, bytes([204]) * 512)
        self.assertLessEqual(reads, 5)
        data, _ = self.read(volume, 200)
        self.assertEqual(data, b'\x5A' * 512)

    def test_new_modify_time_does_not_walk_the_chain_again(self):
        # Проверенная цепочка не обходится, когда в записи сменилось только
        # время изменения: цикл за концом данных, появившийся после первой
        # проверки, вторая запись в другое время не замечает. Прежде каждая
        # новая отметка времени (раз в 2 с) запускала обход всей цепочки.
        volume = self.volume()
        status = call(volume, FX['FILEX_OP_WRITE_AT'], 0, b'A' * 512)
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        volume.set_fat(2 + self.CLUSTERS, 300)
        volume.rtc[0] = 0x50                            # 50 секунд вместо 40
        status = call(volume, FX['FILEX_OP_WRITE_AT'], 512, b'B' * 512)
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        entry = volume.entry()
        self.assertEqual(p.h.get16(entry, 22) & 0x1F, 50 // 2, 'время изменения не сменилось')


if __name__ == '__main__':
    unittest.main(verbosity=2)
