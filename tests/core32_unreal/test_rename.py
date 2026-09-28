"""RENAME: откат, если прежнюю запись удалить не удалось.

RENAME создаёт запись с новым именем (SVHDFL) и удаляет прежнюю (DELEN). Если
DELEN отказал, раньше на одной цепочке оставались две записи, и удаление любой
из них потом освобождало данные другой. Теперь только что созданная запись
удаляется — если короткая запись прежней на носителе не помечена удалённой:
её сектор (место запомнено при первом поиске) читается заново. Не удался и
откат — обе записи могут остаться. Код в A после отказа — для окна F6
(FEEM): удачный откат — 0, неясный исход — #FF.
Исполняется собранное расширение (RENAME_ENTRY); SRHDRN, SVHDFL и DELEN ядра
подменены: они записывают вызовы и отвечают, как задаёт тест. Те же пути на
настоящем ядре — test_crash_paths.
"""
import unittest

import test_fat_allocator_hint as h

OLD, NEW = 0xF000, 0xF100
Z, C = 0x40, 0x01
# Выход настоящего DELEN: (A, Z, CF). Удалено — A=1/NZ; отказ записи — A=0/Z;
# записи нет — A=8/Z; поиск не прочитал каталог (FIND_IO_ERROR) — A=8/Z, CF=1.
DELEN_OUTCOME = {True: (1, False, False), False: (0, True, False),
                 'missing': (8, True, False), 'unreadable': (8, True, True)}


def text(memory, address):
    end = address
    while memory[end]:
        end += 1
    return bytes(memory[address:end])


LBA = 0x5555                              # сектор каталога с новой записью
SLOT = 64                                 # её место в секторе
OLD_LBA = 0x6666                          # сектор с короткой записью прежней
OLD_SLOT = 96 + 256                       # её место: вторая половина сектора


def old_sector(still_there):
    """Сектор прежней записи при повторном чтении: цела либо помечена #E5."""
    sector = bytearray(bytes(range(256)) * 2)
    sector[OLD_SLOT:OLD_SLOT + 32] = b'WC      NEW' + bytes([0x20]) + bytes(20)
    if not still_there:
        sector[OLD_SLOT] = 0xE5
    return bytes(sector)


def dir_sector(attr, name=b'WC      INI'):
    """Сектор каталога: соседи до и после и новая запись по SLOT."""
    sector = bytearray(bytes(range(256)) * 2)            # «чужие» байты вокруг
    sector[SLOT:SLOT + 32] = name + bytes([attr]) + bytes(20)
    return bytes(sector)


class Rename(unittest.TestCase):

    def rename(self, found=True, created=True, deleted=(True, True), attr=0x20,
               cut=None, on_disk=None, old_still_there=True, old_unreadable=False, landed=True):
        """cut — атрибут, который оставил ENTREZ; on_disk — сектор новой записи;
        old_still_there — цела ли короткая запись прежней при повторном чтении
        её сектора после отказа DELEN; old_unreadable — сектор не читается."""
        harness = h.ExtensionHarness()
        machine, memory = harness.machine, harness.memory
        self.harness = harness
        harness.sector_overrides[OLD_LBA] = old_sector(old_still_there)
        plain_read = harness.callouts[harness.core['RDDSE']]

        def read():
            if old_unreadable and harness.position == OLD_LBA:
                harness.read_calls.append((OLD_LBA, machine.a, machine.hl))
                memory[harness.core['ABT']] = 1                 # отказ драйвера
                harness._return()
                return
            plain_read()

        harness.callouts[harness.core['RDDSE']] = read
        memory[OLD:OLD + 8] = bytes([0]) + b'wc.new' + bytes(1)
        memory[NEW:NEW + 7] = b'wc.ini' + bytes(1)
        entry = harness.core['ENTRY']
        memory[entry + 11] = attr
        calls = []
        results = iter(deleted)
        searches = []
        harness.callouts[harness.core['PROZ']] = harness._position
        machine.set_breakpoint(harness.core['PROZ'])
        if on_disk is not None:
            harness.sector_overrides[LBA] = on_disk

        def srhdrn():
            calls.append(('SRHDRN', memory[machine.hl], text(memory, machine.hl + 1)))
            searches.append(1)
            if len(searches) == 1:                               # прежняя: её место
                machine.bc = harness.core['LOBU'] + OLD_SLOT
                memory[harness.core['LLHL']:harness.core['LLHL'] + 4] = OLD_LBA.to_bytes(4, 'little')
            if len(searches) == 2 and on_disk is not None:   # поиск новой записи:
                lobu = harness.core['LOBU']                     # её сектор в LOBU,
                memory[lobu:lobu + 512] = dir_sector(cut if cut is not None else attr)
                memory[entry:entry + 32] = memory[lobu + SLOT:lobu + SLOT + 32]
                machine.bc = lobu + SLOT                        # BC — на запись,
                memory[harness.core['LLHL']:harness.core['LLHL'] + 4] = LBA.to_bytes(4, 'little')
            ok = found
            if len(searches) > 1 and text(memory, machine.hl + 1) == b'wc.new':
                ok = old_still_there                              # проверка перед откатом
            if created == 'media' and len(searches) == 2:
                ok = landed                                       # легла ли новая
            machine.f = machine.f & ~Z if ok else machine.f | Z
            machine.hl, machine.de = 0x1234, 0
            harness._return()

        def svhdfl():
            calls.append(('SVHDFL', text(memory, machine.hl)))
            name = text(memory, machine.hl)
            nxtbu = harness.core['NXTBU']                        # как ENTREZ:
            memory[nxtbu] = memory[entry + 11] & 0x10           # [тип, имя, 0]
            memory[nxtbu + 1:nxtbu + 2 + len(name)] = name + b'\0'
            if cut is not None:
                memory[entry + 11] = cut                         # как ENTREZ
            memory[harness.core['ABT']] = 1 if created == 'media' else 0
            machine.f = machine.f | Z if created is True else machine.f & ~Z
            harness._return()

        def delen():
            calls.append(('DELEN', memory[machine.hl], text(memory, machine.hl + 1)))
            machine.a, zero, carry = DELEN_OUTCOME[next(results)]
            machine.f = (machine.f & ~(Z | C)) | (Z if zero else 0) | (C if carry else 0)
            harness._return()

        for name, handler in (('SRHDRN', srhdrn), ('SVHDFL', svhdfl), ('DELEN', delen)):
            harness.callouts[harness.core[name]] = handler
            machine.set_breakpoint(harness.core[name])
        machine.hl, machine.de = OLD, NEW
        harness.invoke('RENAME_ENTRY')
        return not machine.f & Z, calls, machine.a

    def test_rename_creates_new_and_deletes_old(self):
        done, calls, _ = self.rename()
        self.assertTrue(done)
        self.assertEqual(calls, [('SRHDRN', 0, b'wc.new'), ('SVHDFL', b'wc.ini'),
                                 ('DELEN', 0, b'wc.new'), ('SRHDRN', 0, b'wc.ini')])
        self.assertEqual(self.harness.written_sectors, [], 'атрибут цел — писать нечего')

    def test_attributes_come_back_after_entrez(self):
        # «только чтение», «скрытый», «системный», «архив»: ENTREZ оставил 0
        done, _, _ = self.rename(attr=0x27, cut=0x00, on_disk=dir_sector(0x00))
        self.assertTrue(done)
        written = self.harness.written_sectors
        self.assertEqual(len(written), 1, 'один сектор каталога')
        expect = bytearray(dir_sector(0x00))
        expect[SLOT + 11] = 0x27
        self.assertEqual(written[0], bytes(expect), 'изменён ровно байт атрибута')
        self.assertEqual(self.harness.memory[self.harness.core['ENTRY'] + 11], 0x27)

    def test_foreign_entry_at_the_place_stays(self):
        # На диске по вычисленному месту уже не та запись — ничего не пишем.
        done, _, _ = self.rename(attr=0x27, cut=0x00,
                                 on_disk=dir_sector(0x00, name=b'OTHER   BIN'))
        self.assertTrue(done)
        self.assertEqual(self.harness.written_sectors, [])

    def test_directory_rename_writes_nothing(self):
        done, _, _ = self.rename(attr=0x10, cut=0x10, on_disk=dir_sector(0x10))
        self.assertTrue(done)
        self.assertEqual(self.harness.written_sectors, [], 'у каталога бит и так на месте')

    def test_missing_old_entry(self):
        done, calls, a = self.rename(found=False)
        self.assertFalse(done)
        self.assertEqual((calls, a), ([('SRHDRN', 0, b'wc.new')], 8))

    def test_failed_create_touches_nothing(self):
        done, calls, _ = self.rename(created=False)
        self.assertFalse(done)
        self.assertEqual([call[0] for call in calls], ['SRHDRN', 'SVHDFL'])

    def test_failed_delete_removes_the_new_entry(self):
        done, calls, a = self.rename(deleted=(False, True))
        self.assertFalse(done)
        self.assertEqual(calls[2:], [('DELEN', 0, b'wc.new'), ('DELEN', 0, b'wc.ini')],
                         'прежняя на месте — новая удалена, двух записей на цепочке нет')
        self.assertIn(OLD_LBA, [call[0] for call in self.harness.read_calls],
                      'сектор прежней записи не перечитан')
        # Код для FEEM: A=1 от удачного DELEN показал бы в окне F6 «Long Name
        # is not valid!»; прежнее ядро при отказе DELEN давало A=0.
        self.assertEqual(a, 0, 'после отката — «UNKNOWN ERROR!!», как у прежнего ядра')

    def test_failed_rollback_reports_unknown_state(self):
        # Новую удалить тоже не удалось: на цепочке могут остаться обе — A=#FF.
        done, _, a = self.rename(deleted=(False, False))
        self.assertFalse(done)
        self.assertEqual(a, 0xFF)

    def test_rollback_search_unreadable_reports_unknown_state(self):
        # DELEN новой: поиск не прочитал каталог и вернул A=8 с CF=1. Это не
        # «новой нет» (A=8 — «Source file is not found!»), а неизвестность.
        done, _, a = self.rename(deleted=(False, 'unreadable'))
        self.assertFalse(done)
        self.assertEqual(a, 0xFF, 'ошибка чтения при откате выдана за «записи нет»')

    def test_rollback_with_new_entry_missing(self):
        # Новой при откате не нашлось: прежняя на месте — не переименовано.
        done, _, a = self.rename(deleted=(False, 'missing'))
        self.assertFalse(done)
        self.assertEqual(a, 0)

    def test_old_gone_despite_error_keeps_the_new_entry(self):
        # DELEN вернул ошибку, но прежняя запись уже удалена на носителе: откат
        # снёс бы последнюю ссылку на цепочку. Новая остаётся, переименовано.
        done, calls, _ = self.rename(deleted=(False,), old_still_there=False)
        self.assertTrue(done, 'прежней нет — переименование состоялось')
        self.assertNotIn(('DELEN', 0, b'wc.ini'), calls, 'удалена последняя ссылка на цепочку')

    def test_unreadable_old_sector_removes_the_new_entry(self):
        # Сектор прежней не читается — состояние неизвестно: откат. Потерянная
        # цепочка лучше двух записей на одной (аудит Codex, п. 5).
        done, calls, _ = self.rename(deleted=(False, True), old_unreadable=True)
        self.assertFalse(done)
        self.assertEqual(calls[-1], ('DELEN', 0, b'wc.ini'))

    def test_media_failure_new_entry_landed_completes_the_rename(self):
        # SVHDFL: запись нового имени легла, драйвер вернул отказ (ABT≠0).
        # Прежде — «не переименовано», и на цепочке оставались обе записи
        # (аудит Codex, п. 5). Теперь поиск NXTBU находит новую с цепочкой
        # прежней — прежняя удаляется, переименовано.
        done, calls, _ = self.rename(created='media', landed=True)
        self.assertTrue(done)
        self.assertEqual(calls[:4], [('SRHDRN', 0, b'wc.new'), ('SVHDFL', b'wc.ini'),
                                     ('SRHDRN', 0, b'wc.ini'), ('DELEN', 0, b'wc.new')])

    def test_media_failure_new_entry_absent_is_not_renamed(self):
        done, calls, _ = self.rename(created='media', landed=False)
        self.assertFalse(done)
        self.assertNotIn(('DELEN', 0, b'wc.new'), calls, 'прежняя удалена, хотя новой нет')

    def test_rollback_for_a_directory_uses_directory_type(self):
        done, calls, _ = self.rename(deleted=(False, True), attr=0x10)
        self.assertFalse(done)
        self.assertEqual(calls[-1], ('DELEN', 0x10, b'wc.ini'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
