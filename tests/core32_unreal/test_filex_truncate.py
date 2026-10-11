"""FILEX SET_EOF32: отказы носителя при усечении.

Порядок (с 2026-10-10): ссылка хвоста цепочки читается до публикации, затем
пишется ENTRY с новым размером, затем конец цепочки и освобождение хвоста,
FSInfo, и лишь потом обнуляется хвост последнего сохраняемого сектора — когда
за концом файла уже мёртвые данные. Прежде хвост обнулялся до публикации с
копией сектора, и отказ записи при неудачном возврате копии терял живые
данные файла (драйвер FAT32, R8-3). Отказ записи самой ENTRY, после которой
она всё же легла, доводит усечение (аудит, А.5); не легла — контекст
FENTRY/APPEND снят (драйвер, R3-4). Исполняются настоящие FILEX, ядро и
расширение на диске в памяти; отказы — в драйвере сектора.
"""
import unittest

import core32_machine as p
from test_filex_time import ClockVolume

ORIGINAL, TARGET = 1536, 513
FX = p.FX


class FaultyVolume(ClockVolume):
    """Файл AUDIT.BIN из 1536 байт #A5, кластер — один сектор. fail_writes —
    номера записей, которые откажут; из них applied — сектор всё же ляжет.
    fail_reads — номера чтений, которые откажут (read_log — их секторы)."""

    def __init__(self, fail_writes=(), applied=(), fail_reads=()):
        super().__init__(original=ORIGINAL, free=20)
        self.fail_writes, self.applied = set(fail_writes), set(applied)
        self.fail_reads = set(fail_reads)
        self.write_log, self.read_log = [], []
        self.callbacks[self.core('RDDSE')] = self.read_io
        self.callbacks[self.core('SDDSE')] = self.write_io

    def write_io(self):
        self.write_log.append(self.position)
        number = len(self.write_log)
        if number in self.fail_writes:
            if number in self.applied:
                start, size = self.position * 512, (self.cpu.a or 256) * 512
                self.disk[start:start + size] = self.mem[self.cpu.hl:self.cpu.hl + size]
            self.mem[self.core('ABT')] = 1
            p.ret(self.cpu)
            return
        self.transfer(True)

    def read_io(self):
        self.read_log.append(self.position)
        if len(self.read_log) in self.fail_reads:
            self.mem[self.core('ABT')] = 1
            p.ret(self.cpu)
            return
        self.transfer(False)

    def append_valid(self):
        """Контекст FENTRY/APPEND ядра (APPEND_VALID в странице расширения)."""
        ext = self.mem[0xC000:] if self.page == 0xE8 else self.pages[0xE8]
        return ext[self.ext('APPEND_VALID') - 0xC000]

    def data(self):
        start = (self.data_start + 1) * 512
        return bytes(self.disk[start:start + ORIGINAL])

    def size(self):
        return p.h.get32(self.entry(), 28)

    def truncate(self, target=TARGET):
        return self.run_block(FX['FILEX_OP_SET_EOF32'], target)


class Truncate(unittest.TestCase):

    def test_plain_truncation(self):
        volume = FaultyVolume()
        self.assertEqual(volume.truncate(), FX['FILEX_STATUS_OK'])
        self.assertEqual(volume.size(), TARGET)
        data = volume.data()
        self.assertEqual(data[:TARGET], b'\xA5' * TARGET)
        self.assertEqual(data[TARGET:1024], bytes(1024 - TARGET), 'хвост сектора за концом не обнулён')

    def test_order_entry_first_tail_zeroed_last(self):
        # До ENTRY на диск не пишется ничего; хвост сектора — последней записью.
        volume = FaultyVolume()
        self.assertEqual(volume.truncate(), FX['FILEX_STATUS_OK'])
        self.assertEqual(volume.write_log[0], volume.data_start, 'первая запись — не ENTRY')
        self.assertEqual(volume.write_log[-1], volume.data_start + 2, 'последняя запись — не хвост сектора')

    def test_fat_read_failure_before_commit_keeps_the_file(self):
        # Отказ чтения ссылки хвоста — до публикации: ни одной записи.
        volume = FaultyVolume(fail_reads={5})
        status = volume.truncate()
        self.assertEqual(volume.read_log[4], volume.fat_start, 'сценарий не тот')
        self.assertEqual(status, FX['FILEX_STATUS_MEDIA'])
        self.assertEqual(volume.write_log, [], 'запись до публикации')
        self.assertEqual((volume.size(), volume.data()), (ORIGINAL, b'\xA5' *ORIGINAL))

    def test_tail_zero_write_failure_is_committed_cleanup(self):
        # Размер уже новый, хвост цепочки освобождён; отказ обнуления хвоста
        # сектора — служебная очистка, живые данные целы.
        volume = FaultyVolume(fail_writes={5})
        status = volume.truncate()
        self.assertEqual(volume.write_log[4], volume.data_start + 2, 'сценарий не тот')
        self.assertEqual(status, FX['FILEX_STATUS_COMMITTED_CLEANUP'])
        self.assertEqual(volume.size(), TARGET)
        self.assertEqual(volume.state()['chain_bytes'], 1024)
        self.assertEqual(volume.data()[:TARGET], b'\xA5' *TARGET)

    def test_tail_read_failure_is_committed_cleanup(self):
        volume = FaultyVolume(fail_reads={12})
        status = volume.truncate()
        self.assertEqual(volume.read_log[11], volume.data_start + 2, 'сценарий не тот')
        self.assertEqual(status, FX['FILEX_STATUS_COMMITTED_CLEANUP'])
        self.assertEqual(volume.size(), TARGET)
        self.assertEqual(volume.data()[:TARGET], b'\xA5' *TARGET)

    def test_entry_applied_but_reported_failure_completes(self):
        # ENTRY с новым размером легла, драйвер вернул отказ (аудит, А.5;
        # 2026-09-26): прежде MEDIA при уже новом размере и неотсоединённом
        # хвосте цепочки. Теперь ENTRY перечитывается, и усечение доводится.
        volume = FaultyVolume(fail_writes={1}, applied={1})
        status = volume.truncate()
        self.assertEqual(volume.write_log[0], volume.data_start, 'первая запись — не ENTRY')
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        self.assertEqual(volume.size(), TARGET)
        self.assertEqual(volume.state()['chain_bytes'], 1024, 'хвост цепочки не отсоединён')
        self.assertEqual(volume.append_valid(), 1, 'легшая ENTRY не взяла контекст заново')

    def test_zero_size_entry_applied_but_reported_failure_frees_the_chain(self):
        # Размер 0: ENTRY (кластер 0) легла с ответом «ошибка». Прежде цепочка
        # оставалась занятой без единой ссылки.
        volume = FaultyVolume(fail_writes={1}, applied={1})
        status = volume.truncate(0)
        self.assertEqual(volume.write_log[0], volume.data_start, 'первая запись — не ENTRY')
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        self.assertEqual(volume.size(), 0)
        self.assertEqual([volume.fat(cluster) for cluster in (3, 4, 5)], [0, 0, 0],
                         'цепочка без ссылок осталась занятой')

    def test_entry_failed_keeps_the_file(self):
        volume = FaultyVolume(fail_writes={1})
        self.assertEqual(volume.truncate(), FX['FILEX_STATUS_MEDIA'])
        self.assertEqual((volume.size(), volume.data()), (ORIGINAL, b'\xA5' *ORIGINAL))
        self.assertEqual(volume.state()['chain_bytes'], ORIGINAL)
        self.assertEqual(volume.write_log, [volume.data_start], 'после отказа ENTRY писали ещё')
        # Исход записи неизвестен — контекст FENTRY/APPEND снят (драйвер, R3-4).
        self.assertEqual(volume.append_valid(), 0, 'контекст после неизвестного исхода записи')


if __name__ == '__main__':
    unittest.main(verbosity=2)
