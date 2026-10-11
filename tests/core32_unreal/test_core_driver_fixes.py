"""Ядро WC: исправления, перенесённые из драйвера FAT32 (2026-10-10).

Исполняются собранные CORE32 и CORE32_EXT, FAT32-том — в памяти Python
(стенд test_fat_stream_cache и test_overwrite_path). Сборка — Build/ или пути
из WC_BOOT, WC_CORE, WC_EXT, WC_BOOT_SYM, WC_EXT_SYM (сравнение с прежней).

* Монтирование: резерв, кратный 256, — не отказ (прежде проверялся младший
  байт); том без кластеров данных или кончающийся до области данных, FAT от
  2^24 секторов и номера кластеров от 2^28 — отказ; запасной путь FHDD (запись
  1 любого типа, superfloppy) — как прежде.
* Поток, остановленный ошибкой, и на следующем вызове отвечает CF=1.
* Чтение FAT не переставляет базу потока LTHL (PROZ вместо XPOZI).
* Голова освобождаемой цепочки (1, за томом) — не подсказка распределителю,
  а поиск с недопустимой подсказки проходит и кластеры от 2.
* CHTOSE при отказе чтения FAT останавливается, а не берёт мусор.
* APPEND: «только чтение» — #28; цикл в цепочке или ссылка в корень — #25,
  ничего не пишется; неизвестный исход записи каталога снимает контекст.
"""
import unittest

from test_fat_stream_cache import BUFFER, CLUSTER_SLOT, EOC, Machine, put32, get32
from test_overwrite_path import Volume, DIR_CLUSTER, same_name

HDD = 0x4009
Z, C = 0x40, 0x01


def bpb(reserved=32, fat=None, total=4096, spc=1, fsinfo=1):
    # Claude - 2026-10-10: FAT по умолчанию держит записи на все номера
    # кластеров (короткую FAT монтирование теперь отвергает).
    if fat is None:
        fat = -(-(total // spc + 2) // 128)
    sector = bytearray(512)
    sector[11:13] = (512).to_bytes(2, 'little')
    sector[13] = spc
    sector[14:16] = reserved.to_bytes(2, 'little')
    sector[16] = 1
    sector[32:36] = total.to_bytes(4, 'little')
    sector[36:40] = fat.to_bytes(4, 'little')
    sector[44:48] = (2).to_bytes(4, 'little')
    sector[48:50] = fsinfo.to_bytes(2, 'little')
    sector[510:512] = b'\x55\xAA'
    return bytes(sector)


def mbr(kind=0x0C, start=1, second=None, length=0x00FFFFFF):
    sector = bytearray(512)
    sector[446 + 4] = kind
    sector[446 + 8:446 + 12] = start.to_bytes(4, 'little')
    sector[446 + 12:446 + 16] = length.to_bytes(4, 'little')   # Claude - 2026-10-10
    if second is not None:
        sector[462 + 4] = second
        sector[462 + 8:462 + 12] = (100).to_bytes(4, 'little')
    sector[510:512] = b'\x55\xAA'
    return bytes(sector)


class Mount(unittest.TestCase):

    def mount(self, boot, at=1, table=None, machine=None):
        m = machine or Machine(spc=1)
        m.sectors[0] = table if table is not None else mbr(start=at)
        if at:
            m.sectors[at] = boot
        a, f, _, _ = m.call(HDD)
        self.machine = m
        return bool(f & Z)

    def test_plain_volume_mounts(self):
        self.assertTrue(self.mount(bpb()))

    def test_reserve_multiple_of_256_mounts(self):
        for reserved in (256, 512, 8192):
            with self.subTest(reserved=reserved):
                self.assertTrue(self.mount(bpb(reserved=reserved, total=reserved + 4096)),
                                'ложный отказ: проверялся младший байт резерва')

    def test_volume_without_data_clusters_is_refused(self):
        for total in (32 + 8, 32 + 8 - 1, 100 - 70):
            with self.subTest(total=total):
                self.assertFalse(self.mount(bpb(fat=8, total=total)))

    def test_fat_of_2_24_sectors_is_refused(self):
        self.assertFalse(self.mount(bpb(fat=1 << 24, total=(1 << 24) + 100000)))

    def test_cluster_numbers_from_2_28_are_refused(self):
        # Claude - 2026-10-10: граница номеров (кластеров + 2) — не дальше
        # #0FFFFFF0, точно: #0FFFFFF0..#0FFFFFF6 ссылки FAT — зарезервированы.
        fat = 1 << 21                                   # 128 записей на сектор
        table = mbr(length=0xFFFFFFFE)
        def total(limit):
            return 32 + fat + limit - 2
        self.assertFalse(self.mount(bpb(fat=fat, total=total(1 << 28)), table=table))
        self.assertFalse(self.mount(bpb(fat=fat, total=total(0x0FFFFFF1)), table=table),
                         'граница #0FFFFFF1 принята')
        self.assertTrue(self.mount(bpb(fat=fat, total=total(0x0FFFFFF0)), table=table))

    # Claude - 2026-10-10 - begin
    def test_fat_shorter_than_the_clusters_is_refused(self):
        need = -(-(4096 - 32 + 2) // 128)                   # с запасом: FAT меньше
        self.assertFalse(self.mount(bpb(fat=8)), 'FAT в 8 секторов на 4060 кластеров')
        self.assertTrue(self.mount(bpb(fat=need)))

    def test_volume_longer_than_its_partition_is_refused(self):
        self.assertFalse(self.mount(bpb(total=4096), table=mbr(length=4095)))
        self.assertTrue(self.mount(bpb(total=4096), table=mbr(length=4096)))
        self.assertFalse(self.mount(bpb(total=4096), table=mbr(length=0)), 'пустой раздел')

    def test_volume_end_beyond_2_32_is_refused(self):
        # Раздел почти у конца 32-битного LBA: начало + длина тома > 2^32.
        start = 0xFFFFF000
        m = Machine(spc=1)
        m.sectors[0] = mbr(start=start, length=0x2000)
        m.sectors[start] = bpb(total=0x1000)
        a, f, _, _ = m.call(HDD)
        self.assertTrue(f & Z, 'ровно до 2^32 — можно')
        m = Machine(spc=1)
        m.sectors[0] = mbr(start=start, length=0x2000)
        m.sectors[start] = bpb(total=0x1001)
        a, f, _, _ = m.call(HDD)
        self.assertFalse(f & Z, 'конец тома за 2^32 принят')

    def test_fsinfo_outside_the_reserve_is_not_used(self):
        # BPB_FSInfo вне резерва (0 — сектор загрузки; не меньше резерва):
        # FSInfo не читается, подсказка — холодная. В резерве — читается.
        for fsinfo, used in ((1, True), (0, False), (32, False), (500, False)):
            with self.subTest(fsinfo=fsinfo):
                self.assertTrue(self.mount(bpb(fsinfo=fsinfo)))
                read = [lba for kind, lba in self.machine.log if kind == 'R']
                # Сектор загрузки (LBA 1) HDD читает сам — один раз.
                self.assertEqual(read.count(1 + fsinfo) - (fsinfo == 0), int(used))
    # Claude - 2026-10-10 - end

    def test_fallback_partition_of_any_type(self):
        # Запись 1 не FAT32 по типу (#83), запись 2 пуста — запасной путь
        # пробует начало записи 1 (как прежде, FHDD_EXTENDED).
        self.assertTrue(self.mount(bpb(), table=mbr(kind=0x83)))
        self.assertEqual(get32(self.machine.mem, self.machine.core('ADDTOP')), 1)

    def test_superfloppy(self):
        self.assertTrue(self.mount(bpb(), at=0, table=bpb()))
        self.assertEqual(get32(self.machine.mem, self.machine.core('ADDTOP')), 0)

    def test_second_entry_used_falls_to_superfloppy(self):
        self.assertFalse(self.mount(bpb(), table=mbr(kind=0x83, second=0x83)))


class Stream(unittest.TestCase):

    def test_stopped_stream_reports_the_error_again(self):
        m = Machine(spc=1)
        m.make_chain([3])
        m.set_fat(3, 1)                                 # испорченная ссылка
        a, f = m.open(3)
        self.assertTrue(f & Z)
        a, cf, _ = m.load(2)
        self.assertEqual((a, cf), (0xFF, 1))
        a, cf, _ = m.load(1)
        self.assertEqual((a, cf), (0xFF, 1), 'остановленный ошибкой поток ответил как конец')

    def test_plain_end_stays_without_carry(self):
        m = Machine(spc=1)
        m.make_chain([3])
        m.open(3)
        m.load(2)
        a, cf, _ = m.load(1)
        self.assertEqual((a, cf), (0x0F, 0))

    def test_fat_read_keeps_the_stream_base(self):
        m = Machine(spc=1)
        m.make_chain([3, 4])
        put32(m.mem, m.core('LTHL'), 0x1234)
        put32(m.mem, CLUSTER_SLOT, 3)
        m.call(m.core('CURIT'), hl=3, de=0)
        self.assertEqual(get32(m.mem, m.core('LTHL')), 0x1234, 'CURIT переставил базу потока на FAT')


class FreeHint(unittest.TestCase):

    def test_freed_chain_with_bad_head_is_not_a_hint(self):
        m = Machine(spc=1)
        put32(m.mem, m.core('FSTFRC'), 7)
        put32(m.mem, m.core('LOBU'), 1)
        put32(m.mem, CLUSTER_SLOT, 1)
        m.call(m.core('DLSG'), hl=CLUSTER_SLOT)
        self.assertEqual(get32(m.mem, m.core('FSTFRC')), 7, 'подсказка стала 1')

    def test_invalid_hint_still_searches_from_2(self):
        v = Volume(spc=1, fat_sectors=4)
        for cluster in range(3, v.clusters):
            v.set_fat(cluster, EOC)
        v.set_fat(10, 0)                                # единственный свободный
        put32(v.mem, v.core('FSTFRC'), 1)
        self.assertEqual(v.mkfile('a.bin', 512), (0, True), 'свободный кластер 10 не найден')
        (entry,) = [e for e in v.entries() if same_name(e[0], 'a.bin')]
        self.assertEqual(entry[1], 10)


class Chtose(unittest.TestCase):

    def test_fat_read_failure_stops_the_table(self):
        m = Machine(spc=1)
        m.make_chain([3, 4])
        m.fail_lbas = {m.fat_lba(3)}
        put32(m.mem, CLUSTER_SLOT, 3)
        table = 0x9000
        m.mem[table:table + 64] = b'\xCC' * 64
        m.call(m.core('CHTOSE'), hl=CLUSTER_SLOT, de=table, bc=table + 64)
        self.assertEqual(get32(m.mem, table), m.cluster_lba(3))
        self.assertEqual(bytes(m.mem[table + 4:table + 8]), b'\xCC' * 4, 'за отказом FAT — мусорный сектор')
        self.assertEqual(m.mem[m.core('ABT')], 0xFE)


class Append(unittest.TestCase):

    def volume(self, size=1536):
        v = Volume(spc=1, fat_sectors=4)
        self.assertEqual(v.mkfile('A.BIN', size), (0, True))
        (entry,) = [e for e in v.entries() if same_name(e[0], 'A.BIN')]
        self.cluster = entry[1]
        return v

    def append(self, v, data=b'xyz'):
        v.find('A.BIN')
        return v.append(data)

    def test_plain_append(self):
        v = self.volume()
        self.assertEqual(self.append(v), 0)

    def test_read_only_is_refused(self):
        v = self.volume()
        lba = v.cluster_lba(DIR_CLUSTER)
        sector = bytearray(v.read_sector(lba))
        for offset in range(0, 512, 32):
            if sector[offset:offset + 5] == b'A    ':
                sector[offset + 11] |= 0x01
        v.sectors[lba] = bytes(sector)
        before = dict(v.sectors)
        self.assertEqual(self.append(v), 0x28)
        self.assertEqual(dict(v.sectors), before)

    def test_cycle_is_refused(self):
        v = self.volume()
        v.set_fat(self.cluster + 2, self.cluster + 1)   # 3 → 4 → 5 → 4
        before = dict(v.sectors)
        self.assertEqual(self.append(v), 0x25)
        self.assertEqual(dict(v.sectors), before, 'APPEND по циклу писал на диск')

    def test_cycle_inside_the_data_is_refused(self):
        v = self.volume(2048)
        v.set_fat(self.cluster + 1, self.cluster)        # 3 → 4 → 3
        before = dict(v.sectors)
        self.assertEqual(self.append(v), 0x25)
        self.assertEqual(dict(v.sectors), before)

    def test_root_link_is_refused(self):
        v = self.volume()
        v.set_fat(self.cluster + 1, DIR_CLUSTER)
        before = dict(v.sectors)
        self.assertEqual(self.append(v), 0x25)
        self.assertEqual(dict(v.sectors), before, 'APPEND писал в корень')

    def test_unknown_outcome_forgets_the_context(self):
        # Запись каталога при фиксации отказала, и перечесть его не удаётся:
        # исход неизвестен — контекст снят (прежде следующий APPEND писал
        # данные по старому EOF).
        v = self.volume()
        v.find('A.BIN')
        directory = v.cluster_lba(DIR_CLUSTER)
        state = {'failed': False}
        read, write = v.handlers[v.core('RDDSE')], v.handlers[v.core('SDDSE')]

        def failing_write():
            if v.position == directory:
                state['failed'] = True
                v.mem[v.core('ABT')] = 1
                v._ret()
                return
            write()

        def failing_read():
            if state['failed'] and v.position == directory:
                v.mem[v.core('ABT')] = 1
                v._ret()
                return
            read()

        v.handlers[v.core('RDDSE')], v.handlers[v.core('SDDSE')] = failing_read, failing_write
        self.assertNotEqual(v.append(b'abc'), 0)
        self.assertTrue(state['failed'], 'сценарий не тот')
        v.handlers[v.core('RDDSE')], v.handlers[v.core('SDDSE')] = read, write
        self.assertEqual(v.append(b'def'), 0x20, 'контекст после неизвестного исхода остался')


if __name__ == '__main__':
    unittest.main(verbosity=2)
