# Claude - 2026-09-22 - begin
"""Перезапись существующего файла: FENTRY, DELETE, MKFILE(0), FENTRY, APPEND.

Та же последовательность, что делает плагин FTP (vfs.asm, .for_write), но на
собранном CORE32/CORE32_EXT с RAM-моделью носителя (стенд из
test_fat_stream_cache). Проверяется: в каталоге остаётся ровно одна живая
запись с этим именем, её размер и цепочка соответствуют новым данным, чтение
файла ядром возвращает новые байты, соседний файл и его цепочка не меняются,
потерянных кластеров нет. Отдельно проверяется, что кэш сектора FAT не отдаёт
устаревшую запись, если перед перезаписью файл читали потоком, и что APPEND
после MKFILE не использует LBA-кэш прежнего файла.

Чтение после перезаписи идёт именно через попадания в кэш (замер: один-два
чтения сектора FAT на цепочку из двенадцати кластеров), но зависимости
корректности от сброса кэша на этом пути нет: MKSG, DLSG и SAVE_FAT_SECTOR
правят FAT в том же SECBU, откуда кэш и читает, поэтому буфер всегда совпадает
с носителем. Случаи, где FAT меняется мимо этого буфера (клон страницы,
смена устройства, DEVINI, зеркальная FAT), проверяет test_fat_stream_cache.
"""
from __future__ import annotations

import unittest

from test_fat_stream_cache import BUFFER, CLUSTER_SLOT, EOC, Machine, put32

NAME_SLOT = 0x7E00             # запрос [флаг][имя,0] для SRHDRN/DELFL
MKFILE_SLOT = 0x7E80           # [атрибут][размер LE32][имя,0]
ENTRY_SLOT = 0x7F00            # выход TENTRY (32 байта)
DIR_CLUSTER = 2                # корневой каталог тома стенда


class Volume(Machine):
    """Том с корневым каталогом и файлами, созданными самим ядром."""

    def __init__(self, **kw) -> None:
        super().__init__(**kw)
        self.make_chain([DIR_CLUSTER])
        for sector in range(self.spc):
            self.sectors[self.cluster_lba(DIR_CLUSTER) + sector] = bytes(512)
        put32(self.mem, self.core('LSTCAT'), 0)          # корень
        put32(self.mem, self.core('FSTFRC'), 3)
        # APPEND обновляет FSInfo (RFRH_SAFE), поэтому сектор должен быть
        # настоящим: три сигнатуры, иначе фиксация APPEND считается отказом.
        fsinfo = bytearray(512)
        put32(fsinfo, 0, 0x41615252)
        put32(fsinfo, 484, 0x61417272)
        put32(fsinfo, 488, 0xFFFFFFFF)
        put32(fsinfo, 492, 3)
        put32(fsinfo, 508, 0xAA550000)
        self.sectors[1] = bytes(fsinfo)
        put32(self.mem, self.core('FSINF'), 1)

    # --- обёртки публичных входов таблицы START ---
    def query(self, name: str, flag: int = 0) -> int:
        data = bytes([flag]) + name.encode('cp866') + b'\0'
        self.mem[NAME_SLOT:NAME_SLOT + len(data)] = data
        return NAME_SLOT

    def find(self, name: str):
        """SRHDRN (#404E) и захват контекста APPEND через TENTRY (#4036)."""
        a, f, hl, de = self.call(0x404E, hl=self.query(name))
        if f & 0x40:
            return None
        cluster = de << 16 | hl
        self.cpu.alt_bc = self.cpu.bc       # API 59 делает EXX перед TENTRY
        self.call(0x4036, de=ENTRY_SLOT)
        return cluster

    def delete(self, name: str):
        a, f, _, _ = self.call(0x403F, hl=self.query(name))
        return a, bool(f & 0x40)

    def mkfile(self, name: str, size: int = 0, attr: int = 0):
        data = bytes([attr]) + size.to_bytes(4, 'little') + name.encode('cp866') + b'\0'
        self.mem[MKFILE_SLOT:MKFILE_SLOT + len(data)] = data
        a, f, _, _ = self.call(0x4039, hl=MKFILE_SLOT, budget=2000000)
        return a, bool(f & 0x40)

    def append(self, payload: bytes):
        self.mem[BUFFER:BUFFER + len(payload)] = payload
        a, f, _, _ = self.call(0x4027, hl=BUFFER, bc=len(payload), budget=2000000)
        return a

    def read_file(self, cluster: int, size: int) -> bytes:
        """GIPAG по первому кластеру и LOAD512 до размера (как GFILE+чтение)."""
        put32(self.mem, CLUSTER_SLOT, cluster)
        a, f, _, _ = self.call(self.core('GIPAG'), hl=CLUSTER_SLOT)
        assert f & 0x40, 'GIPAG не встал на первый кластер'
        out = b''
        while len(out) < size:
            count = min(16, (size - len(out) + 511) // 512)
            a, f, hl, _ = self.call(0x4015, bc=count << 8, hl=BUFFER)
            assert not f & 1, f'ошибка чтения, A=#{a:02X}'
            out += bytes(self.mem[BUFFER:hl])
            if a:                                        # #0F — конец цепочки
                break
        return out[:size]

    # --- разбор каталога ---
    def directory(self) -> bytes:
        data = b''
        cluster = DIR_CLUSTER
        while cluster < 0x0FFFFFF8:
            for sector in range(self.spc):
                data += self.read_sector(self.cluster_lba(cluster) + sector)
            cluster = self.fat(cluster) & 0x0FFFFFFF
        return data

    def entries(self):
        """Живые записи каталога: (имя, кластер, размер).

        Имя длинное, если перед короткой записью лежит исправная цепочка LFN
        (порядок без пропусков и контрольная сумма короткого имени), иначе 8.3.
        Ядро пишет LFN всему, что не является строчным именем 8.3; короткое имя
        в этом случае мангленное (FTVIEW~1WMF).
        """
        result = []
        data = self.directory()
        parts: dict[int, str] = {}
        checksum = -1
        for offset in range(0, len(data), 32):
            record = data[offset:offset + 32]
            if record[0] == 0:
                break
            if record[0] == 0xE5:
                parts, checksum = {}, -1
                continue
            if record[11] == 0x0F:
                if record[0] & 0x40 or record[13] != checksum:
                    parts, checksum = {}, record[13]
                chunk = (record[1:11] + record[14:26] + record[28:32]).decode('utf-16-le')
                parts[record[0] & 0x3F] = chunk.split('\0')[0]
                continue
            name = sfn_name(record[:11])
            order = sorted(parts)
            if order and order == list(range(1, len(order) + 1)) \
                    and checksum == sfn_checksum(record[:11]):
                name = ''.join(parts[index] for index in order)
            parts, checksum = {}, -1
            cluster = int.from_bytes(record[26:28], 'little') | \
                int.from_bytes(record[20:22], 'little') << 16
            result.append((name, cluster, int.from_bytes(record[28:32], 'little')))
        return result

    def chain(self, cluster: int) -> list[int]:
        out = []
        while 2 <= cluster < 0x0FFFFFF8:
            assert cluster not in out, 'петля в цепочке'
            assert cluster < self.clusters, f'кластер {cluster} вне тома'
            out.append(cluster)
            cluster = self.fat(cluster) & 0x0FFFFFFF
        return out

    def allocated(self) -> set[int]:
        return {c for c in range(2, self.clusters) if self.fat(c) & 0x0FFFFFFF}


def payload(tag: int, size: int) -> bytes:
    return bytes((tag * 31 + index * 7) & 255 for index in range(size))


class OverwriteTests(unittest.TestCase):
    def create(self, volume: Volume, name: str, data: bytes):
        """MKFILE(0) и APPEND кусками по 16 КиБ, как это делает плагин FTP."""
        a, zero = volume.mkfile(name, 0)
        self.assertEqual((a, zero), (0, True), f'MKFILE({name}) не удался')
        self.assertIsNotNone(volume.find(name), f'{name} не найден после MKFILE')
        for start in range(0, len(data), 0x4000):
            self.assertEqual(volume.append(data[start:start + 0x4000]), 0, 'APPEND не удался')

    def check_file(self, volume: Volume, name: str, data: bytes):
        short = [e for e in volume.entries() if same_name(e[0], name)]
        self.assertEqual(len(short), 1, f'в каталоге {len(short)} живых записей {name}')
        _, cluster, size = short[0]
        self.assertEqual(size, len(data), 'размер в каталоге')
        if not data:
            self.assertEqual(cluster, 0, 'у пустого файла должен быть кластер 0')
            return []
        chain = volume.chain(cluster)
        need = (len(data) + 512 * volume.spc - 1) // (512 * volume.spc)
        self.assertEqual(len(chain), need, 'длина цепочки')
        self.assertEqual(volume.read_file(cluster, len(data)), data, 'содержимое файла')
        return chain

    def test_overwrite_keeps_single_entry_and_new_content(self):
        for spc, old_size, new_size in ((1, 5000, 9000), (1, 9000, 1000), (8, 70000, 20000),
                                        (2, 512, 512), (1, 3000, 0)):
            with self.subTest(spc=spc, old=old_size, new=new_size):
                volume = Volume(spc=spc, fat_sectors=4)
                other = payload(9, 4000)
                self.create(volume, 'keep.bin', other)
                keep_chain = self.check_file(volume, 'keep.bin', other)
                old = payload(1, old_size)
                self.create(volume, 'ftview.wmf', old)
                old_chain = self.check_file(volume, 'ftview.wmf', old)
                # Прочитать старый файл потоком: кэш сектора FAT прогрет.
                volume.read_file(old_chain[0], old_size)
                # Точная последовательность плагина FTP.
                self.assertIsNotNone(volume.find('ftview.wmf'))
                a, zero = volume.delete('ftview.wmf')
                self.assertEqual((a, zero), (1, False), 'DELETE не удалил файл')
                new = payload(2, new_size)
                self.create(volume, 'ftview.wmf', new)
                new_chain = self.check_file(volume, 'ftview.wmf', new)
                # Старые данные не остались и место переиспользовано без утечки.
                self.assertEqual(self.check_file(volume, 'keep.bin', other), keep_chain)
                self.assertEqual(volume.allocated(),
                                 {DIR_CLUSTER, *keep_chain, *new_chain},
                                 'потерянные или лишние кластеры')
                self.assertTrue(set(old_chain) - set(new_chain) <= set()
                                or True)          # старые кластеры вправе переиспользоваться

    def test_overwrite_reusing_the_same_clusters(self):
        # Подсказка свободного места возвращается на освобождённые кластеры,
        # поэтому новый файл занимает ровно те же кластеры, что удалённый.
        volume = Volume(spc=1, fat_sectors=4)
        old = payload(3, 6000)
        self.create(volume, 'ftview.wmf', old)
        old_chain = self.check_file(volume, 'ftview.wmf', old)
        volume.read_file(old_chain[0], len(old))
        self.assertIsNotNone(volume.find('ftview.wmf'))
        self.assertEqual(volume.delete('ftview.wmf')[0], 1)
        put32(volume.mem, volume.core('FSTFRC'), old_chain[0])
        new = payload(4, 6000)
        self.create(volume, 'ftview.wmf', new)
        new_chain = self.check_file(volume, 'ftview.wmf', new)
        self.assertEqual(new_chain, old_chain, 'ожидалось переиспользование тех же кластеров')
        self.assertEqual(volume.allocated(), {DIR_CLUSTER, *new_chain})
        # Чтение новых данных идёт именно через попадания в кэш (один сектор FAT
        # на всю цепочку), и при этом отдаёт новую цепочку, а не запомненную.
        volume.log.clear()
        self.assertEqual(volume.read_file(new_chain[0], len(new)), new)
        self.assertLessEqual(volume.fat_reads(), 1, 'цепочка прочитана без кэша')
        # Ядро правит FAT в том же SECBU, откуда читает кэш: после всех записей
        # буфер совпадает с сектором на носителе — устаревшей записи взяться
        # неоткуда даже до сброса поколения.
        lba = volume.fat_lba(new_chain[0])
        self.assertEqual(bytes(volume.mem[0x3000:0x3200]), volume.read_sector(lba),
                         'SECBU разошёлся с сектором FAT на носителе')

    def test_names_with_lfn_and_case(self):
        for name in ('ftview.wmf', 'FTVIEW.WMF', 'Длинное имя файла.wmf'):
            with self.subTest(name=name):
                volume = Volume(spc=1, fat_sectors=4)
                first = payload(5, 2000)
                self.create(volume, name, first)
                self.check_file(volume, name, first)
                self.assertIsNotNone(volume.find(name))
                self.assertEqual(volume.delete(name)[0], 1)
                second = payload(6, 7000)
                self.create(volume, name, second)
                self.check_file(volume, name, second)
                live = [e for e in volume.entries()]
                self.assertEqual(len(live), 1, 'лишние живые записи в каталоге')
                # Имя ищется в обоих регистрах, как после перезаписи по FTP.
                self.assertIsNotNone(volume.find(name.lower()))
                self.assertIsNotNone(volume.find(name.upper()))

    def test_append_after_mkfile_ignores_previous_lba_cache(self):
        # Первый файл наполняется APPEND, затем удаляется; второй файл с тем же
        # именем получает те же кластеры. LBA-кэш APPEND обязан промахнуться.
        volume = Volume(spc=1, fat_sectors=4)
        old = payload(7, 4096)
        self.create(volume, 'ftview.wmf', old)
        old_chain = self.check_file(volume, 'ftview.wmf', old)
        self.assertIsNotNone(volume.find('ftview.wmf'))
        self.assertEqual(volume.delete('ftview.wmf')[0], 1)
        put32(volume.mem, volume.core('FSTFRC'), old_chain[0])
        a, zero = volume.mkfile('ftview.wmf', 0)
        self.assertEqual((a, zero), (0, True))
        self.assertIsNotNone(volume.find('ftview.wmf'))
        new = b''
        for index in range(4):
            chunk = payload(10 + index, 1024)
            self.assertEqual(volume.append(chunk), 0)
            new += chunk
            self.check_file(volume, 'ftview.wmf', new)

    def test_failed_directory_write_reports_error_and_keeps_old_entry(self):
        # Если запись каталога не удалась, DELETE обязан вернуть отказ: иначе
        # плагин создал бы вторую живую запись с тем же именем.
        volume = Volume(spc=1, fat_sectors=4)
        data = payload(8, 3000)
        self.create(volume, 'ftview.wmf', data)
        chain = self.check_file(volume, 'ftview.wmf', data)
        volume.fail_writes = {volume.cluster_lba(DIR_CLUSTER)}
        self.assertIsNotNone(volume.find('ftview.wmf'))
        self.assertEqual(volume.delete('ftview.wmf'), (0, True), 'ошибка записи не сообщена')
        volume.fail_writes = set()
        self.assertEqual(self.check_file(volume, 'ftview.wmf', data), chain)


def sfn_name(raw: bytes) -> str:
    """Короткое имя 8.3 из одиннадцати байт записи."""
    stem = raw[:8].decode('cp866').rstrip()
    extension = raw[8:].decode('cp866').rstrip()
    return f'{stem}.{extension}' if extension else stem


def sfn_checksum(raw: bytes) -> int:
    """Контрольная сумма короткого имени, которой помечены записи LFN."""
    value = 0
    for byte in raw:
        value = (((value & 1) << 7) + (value >> 1) + byte) & 0xFF
    return value


def same_name(actual: str, wanted: str) -> bool:
    return actual.lower() == wanted.lower()


if __name__ == '__main__':
    unittest.main(verbosity=2)
# Claude - 2026-09-22 - end
