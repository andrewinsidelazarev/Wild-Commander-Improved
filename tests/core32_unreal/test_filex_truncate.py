"""FILEX SET_EOF32: отказ носителя после обнуления хвоста сектора (2026-09-26).

Усечение сначала обнуляет хвост последнего сохраняемого сектора, затем читает
FAT (ссылку хвоста) и лишь потом публикует новый размер. Отказ чтения FAT
после обнуления выходил, минуя возврат сектора из копии: размер оставался
прежним, а байты за новым концом уже были нулями (аудит Codex, десятый
заход). Отказ самой записи обнуления, после которой сектор всё же лёг, тоже
не возвращал копию: признак «хвост обнулён» ставился лишь после удачной
записи. Отказ записи самой ENTRY, после которой она всё же легла, давал
MEDIA при уже новом размере и неотсоединённом хвосте (аудит, А.5): теперь
ENTRY перечитывается, и усечение доводится. Исполняются настоящие FILEX,
ядро и расширение на диске в памяти; отказы — в драйвере сектора.
"""
import unittest

import core32_machine as p
from test_filex_time import ClockVolume

ORIGINAL, TARGET = 1536, 513
FX = p.FX


class FaultyVolume(ClockVolume):
    """Файл AUDIT.BIN из 1536 байт #A5, кластер — один сектор. fail_writes —
    номера записей, которые откажут; из них applied — сектор всё же ляжет.
    fail_read_after_write — первое чтение после первой записи откажет."""

    def __init__(self, fail_writes=(), applied=(), fail_read_after_write=False):
        super().__init__(original=ORIGINAL, free=20)
        self.fail_writes, self.applied = set(fail_writes), set(applied)
        self.fail_read_after_write = fail_read_after_write
        self.write_log = []
        self.read_failed = False
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
        if self.fail_read_after_write and self.write_log and not self.read_failed:
            self.read_failed = True
            self.mem[self.core('ABT')] = 1
            p.ret(self.cpu)
            return
        self.transfer(False)

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

    def test_fat_read_failure_after_zeroing_restores_the_tail(self):
        volume = FaultyVolume(fail_read_after_write=True)
        status = volume.truncate()
        self.assertTrue(volume.read_failed, 'сценарий не тот')
        self.assertEqual(status, FX['FILEX_STATUS_MEDIA'])
        self.assertEqual(volume.size(), ORIGINAL)
        self.assertEqual(volume.data(), b'\xA5' * ORIGINAL,
                         'размер прежний, а байты за новым концом обнулены')

    def test_zeroing_write_applied_but_reported_failure_restores_the_tail(self):
        volume = FaultyVolume(fail_writes={1}, applied={1})
        status = volume.truncate()
        self.assertEqual(status, FX['FILEX_STATUS_MEDIA'])
        self.assertEqual(volume.size(), ORIGINAL)
        self.assertEqual(volume.data(), b'\xA5' * ORIGINAL,
                         'обнуление легло, а сектор не возвращён из копии')

    def test_zeroing_write_failed_keeps_the_data(self):
        volume = FaultyVolume(fail_writes={1})
        self.assertEqual(volume.truncate(), FX['FILEX_STATUS_MEDIA'])
        self.assertEqual((volume.size(), volume.data()), (ORIGINAL, b'\xA5' * ORIGINAL))

    def test_entry_applied_but_reported_failure_completes(self):
        # ENTRY с новым размером легла, драйвер вернул отказ (аудит, А.5;
        # 2026-09-26): прежде MEDIA при уже новом размере и неотсоединённом
        # хвосте цепочки. Теперь ENTRY перечитывается, и усечение доводится.
        volume = FaultyVolume(fail_writes={2}, applied={2})
        status = volume.truncate()
        self.assertEqual(volume.write_log[1], volume.data_start, 'вторая запись — не ENTRY')
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        self.assertEqual(volume.size(), TARGET)
        self.assertEqual(volume.state()['chain_bytes'], 1024, 'хвост цепочки не отсоединён')

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
        volume = FaultyVolume(fail_writes={2})
        self.assertEqual(volume.truncate(), FX['FILEX_STATUS_MEDIA'])
        self.assertEqual((volume.size(), volume.data()), (ORIGINAL, b'\xA5' * ORIGINAL))
        self.assertEqual(volume.state()['chain_bytes'], ORIGINAL)

    def test_failed_restore_is_reported_as_rollback(self):
        # Обнуление легло с ответом «ошибка», возврат копии тоже отказал:
        # сектор, может быть, так и остался с нулями — это не MEDIA, а ROLLBACK.
        volume = FaultyVolume(fail_writes={1, 2}, applied={1})
        self.assertEqual(volume.truncate(), FX['FILEX_STATUS_ROLLBACK'])
        self.assertEqual(volume.size(), ORIGINAL)


if __name__ == '__main__':
    unittest.main(verbosity=2)
