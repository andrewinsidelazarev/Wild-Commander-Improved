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
               cut=None, on_disk=None, old_still_there=True, old_unreadable=False, landed=True,
               dot=False, old_writes_fail=False, landed_unreadable=0):
        """cut — атрибут, который оставил ENTREZ; on_disk — сектор новой записи;
        old_still_there — цела ли короткая запись прежней при повторном чтении
        её сектора после отказа DELEN; old_unreadable — сектор не читается."""
        harness = h.ExtensionHarness()
        machine, memory = harness.machine, harness.memory
        self.harness = harness
        self.landed_unreadable_left = landed_unreadable
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
        plain_write = harness.callouts[harness.core['SDDSE']]
        self.old_writes = 0

        def write():
            # Claude - 2026-10-10: запись сектора прежней SFN (доведение
            # удаления по месту) — отказ, если задан old_writes_fail.
            if harness.position == OLD_LBA:
                self.old_writes += 1
                if old_writes_fail:
                    memory[harness.core['ABT']] = 1
                    harness._return()
                    return
            plain_write()

        harness.callouts[harness.core['SDDSE']] = write
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
                memory[machine.bc] = ord('.') if dot else ord('W')   # её первый байт
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
            # Claude - 2026-10-10: настоящий SRHDRN без ошибки чтения — CF=0.
            unreadable = len(searches) == 2 and landed_unreadable > 0
            if unreadable:
                self.landed_unreadable_left -= 1
            machine.f = machine.f | C if unreadable and self.landed_unreadable_left >= 0 else machine.f & ~C
            if unreadable and self.landed_unreadable_left >= 0:
                searches.pop()                                   # повтор — снова второй поиск
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
                                 ('DELEN', 0, b'wc.new')])
        self.assertEqual(self.harness.written_sectors, [], 'атрибут цел — писать нечего')

    def test_attribute_is_not_rewritten_separately(self):
        # Claude - 2026-10-10: полный атрибут пишет сам SVHDFL ядра вместе с
        # новой записью (test_crash_paths.Attributes); прежде RENAME искал
        # новую запись ещё раз и правил её сектор отдельной записью уже после
        # удаления прежнего имени — её отказ оставлял файл без «только чтения».
        done, calls, _ = self.rename(attr=0x27, cut=0x00, on_disk=dir_sector(0x00))
        self.assertTrue(done)
        self.assertEqual(self.harness.written_sectors, [])
        self.assertEqual([c[0] for c in calls], ['SRHDRN', 'SVHDFL', 'DELEN'])

    def test_dot_entries_are_not_renamed(self):
        # Claude - 2026-10-10: «..» → «x» создавал подкаталог, указывающий на
        # родителя (драйвер FAT32, R9). Отказ до SVHDFL, A=8.
        done, calls, a = self.rename(dot=True)
        self.assertFalse(done)
        self.assertEqual((calls, a), ([('SRHDRN', 0, b'wc.new')], 8))

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

    def test_failed_delete_is_completed_by_place(self):
        # Claude - 2026-10-10: DELEN прежней отказал, её короткая запись на
        # месте — она помечается #E5 по месту (драйвер FAT32, R8-1), и
        # переименование доводится: прежде сразу шёл откат одной попыткой.
        done, calls, _ = self.rename(deleted=(False,))
        self.assertTrue(done)
        self.assertNotIn(('DELEN', 0, b'wc.ini'), calls, 'новая удалена, хотя прежнюю можно добить')
        self.assertEqual(self.old_writes, 1)
        (sector,) = self.harness.written_sectors
        self.assertEqual(sector[OLD_SLOT], 0xE5)
        expect = bytearray(old_sector(True))
        expect[OLD_SLOT] = 0xE5
        self.assertEqual(sector, bytes(expect), 'изменён не один байт')

    def test_failed_delete_removes_the_new_entry(self):
        # Прежнюю не пометить и тремя записями — откат.
        done, calls, a = self.rename(deleted=(False, True), old_writes_fail=True)
        self.assertEqual(self.old_writes, 3, 'не три попытки записи')
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
        done, _, a = self.rename(deleted=(False, False), old_writes_fail=True)
        self.assertFalse(done)
        self.assertEqual(a, 0xFF)

    def test_rollback_search_unreadable_reports_unknown_state(self):
        # DELEN новой: поиск не прочитал каталог и вернул A=8 с CF=1. Это не
        # «новой нет» (A=8 — «Source file is not found!»), а неизвестность.
        # Claude - 2026-10-10: три попытки — каталог так и не прочитался.
        done, calls, a = self.rename(deleted=(False, 'unreadable', 'unreadable', 'unreadable'),
                                     old_writes_fail=True)
        self.assertFalse(done)
        self.assertEqual(a, 0xFF, 'ошибка чтения при откате выдана за «записи нет»')
        self.assertEqual(calls.count(('DELEN', 0, b'wc.ini')), 3)

    # Claude - 2026-10-10 - begin
    def test_rollback_search_retried_after_a_read_failure(self):
        # Одиночный отказ чтения при откате: вторая попытка удаляет новую
        # запись — не переименовано, A=0, на цепочке одна запись.
        done, calls, a = self.rename(deleted=(False, 'unreadable', True), old_writes_fail=True)
        self.assertFalse(done)
        self.assertEqual(a, 0)
        self.assertEqual(calls.count(('DELEN', 0, b'wc.ini')), 2)

    def test_media_failure_then_unreadable_search_is_retried(self):
        # Двойной отказ (Codex, круг 1): запись нового имени легла с ошибкой,
        # первый поиск после неё не прочитал каталог. Прежде — A=#FF и две
        # записи на одной цепочке; теперь повтор находит новую, прежняя
        # удаляется — переименовано.
        done, calls, _ = self.rename(created='media', landed=True, landed_unreadable=1)
        self.assertTrue(done)
        self.assertEqual(calls.count(('SRHDRN', 0, b'wc.ini')), 2)
        self.assertIn(('DELEN', 0, b'wc.new'), calls)

    def test_media_failure_search_never_readable_is_unknown(self):
        done, calls, a = self.rename(created='media', landed=True, landed_unreadable=3)
        self.assertFalse(done)
        self.assertEqual(a, 0xFF)
        self.assertEqual(calls.count(('SRHDRN', 0, b'wc.ini')), 3)
        self.assertNotIn(('DELEN', 0, b'wc.new'), calls, 'прежняя удалена при неизвестном исходе')
    # Claude - 2026-10-10 - end

    def test_rollback_with_new_entry_missing(self):
        # Новой при откате не нашлось: прежняя на месте — не переименовано.
        done, _, a = self.rename(deleted=(False, 'missing'), old_writes_fail=True)
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
        reads = [c for c in self.harness.read_calls if c[0] == OLD_LBA]
        self.assertEqual(len(reads), 4, 'не четыре попытки чтения')

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

    # Claude - 2026-10-10 - begin
    def test_entry_landed_on_a_damaged_directory_says_no_entry(self):
        # SVHDFL отказал с ABT=#FE — цепочка каталога испорчена, обнаружено до
        # записи: записи нет, каталог не ищется (прежде поиск отказывал, исход
        # «неизвестен», и цепочка MKFILE/MKDIR оставалась потерянной).
        harness = h.ExtensionHarness()
        machine, memory = harness.machine, harness.memory
        searched = []

        def srhdrn():
            searched.append(1)
            machine.f |= C
            harness._return()

        harness.callouts[harness.core['SRHDRN']] = srhdrn
        machine.set_breakpoint(harness.core['SRHDRN'])
        for abt, expect in ((0xFE, (True, False, 0)), (0x01, (False, True, 3))):
            with self.subTest(abt=hex(abt)):
                searched.clear()
                memory[harness.core['ABT']] = abt
                harness.invoke('ENTRY_LANDED')
                self.assertEqual((bool(machine.f & Z), bool(machine.f & C), len(searched)), expect)
    # Claude - 2026-10-10 - end

    def test_rollback_for_a_directory_uses_directory_type(self):
        done, calls, _ = self.rename(deleted=(False, True), attr=0x10, old_writes_fail=True)
        self.assertFalse(done)
        self.assertEqual(calls[-1], ('DELEN', 0x10, b'wc.ini'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
