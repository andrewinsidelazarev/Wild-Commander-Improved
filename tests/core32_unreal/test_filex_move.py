"""FILEX MOVE_RENAME каталога между родителями: откат записи «..» (2026-09-25).

Исполняются настоящие FILEX, ядро и расширение с переключением страниц
(стенд core32_ramdisk); подменён только драйвер сектора. Каталог SUB
переносится из SRC в DST; запись его «..» ложится на носитель, а драйвер
возвращает отказ (аудит Codex, п. 18). Прежде признак «..» изменён» ставился
лишь после успешной записи, и откат удалял новую ссылку, не вернув «..»:
каталог оставался в SRC с «..» на DST — подъём по «..» (F8) искал бы имя в
чужом каталоге. Там же: новая ссылка легла при отказе драйвера, «..» не
удалось вернуть, и имя назначения с пробелом или точкой в конце — отказ до
изменений (SVHDFL записал бы его усечённым, и откат не нашёл бы записи).
Отказ удаления источника с LFN (сектор SFN перечитывается по месту) и
REPLACE: отказ записи перенаправленной SFN назначения откатывается
(аудит, А.3; 2026-09-26).
"""
import time
import unittest

import core32_machine as p
from core32_ramdisk import Volume

FX = p.FX
BLOCK, QUERY_SRC, QUERY_DST = 0x9000, 0x9100, 0x9200


def entry(name, cluster, attr=0x10):
    record = bytearray(32)
    record[:11] = name
    record[11] = attr
    record[20:22] = (cluster >> 16).to_bytes(2, 'little')
    record[26:28] = (cluster & 0xFFFF).to_bytes(2, 'little')
    return bytes(record)


class Tree(Volume):
    """Корень: AUDIT.BIN, SRC, DST; SRC/SUB. Кластер — один сектор."""

    def __init__(self):
        super().__init__(original=512, free=64)
        self.src, self.dst, self.sub = (3 + self.original_clusters + n for n in range(3))
        for cluster in (self.src, self.dst, self.sub):
            self.set_fat(cluster, 0x0FFFFFFF)
        root = self.lba(2) * 512
        self.disk[root + 32:root + 64] = entry(b'SRC        ', self.src)
        self.disk[root + 64:root + 96] = entry(b'DST        ', self.dst)
        self.put_dir(self.src, 0, [entry(b'SUB        ', self.sub)])
        self.put_dir(self.dst, 0, [])
        self.put_dir(self.sub, self.src, [])
        p.h.put32(self.mem, self.core('FSTFRC'), self.sub + 1)
        self.ambiguous = {}                      # LBA -> номера записей: легла, но отказ
        self.failing = {}                        # LBA -> номера записей: не легла, отказ
        self.writes_to = {}
        self.callbacks[self.core('SDDSE')] = self.write_with_faults

    def lba(self, cluster):
        return self.data_start + cluster - 2

    def append_valid(self):
        """Контекст FENTRY/APPEND ядра (APPEND_VALID в странице расширения)."""
        ext = self.mem[0xC000:] if self.page == 0xE8 else self.pages[0xE8]
        return ext[self.ext('APPEND_VALID') - 0xC000]

    def put_dir(self, cluster, parent, records):
        sector = bytearray(512)
        sector[0:32] = entry(b'.          ', cluster)
        sector[32:64] = entry(b'..         ', parent)
        for index, record in enumerate(records):
            sector[64 + 32 * index:96 + 32 * index] = record
        start = self.lba(cluster) * 512
        self.disk[start:start + 512] = sector

    def links(self, cluster, target):
        """Сколько живых коротких записей каталога cluster смотрят на target
        (имя не сравнивается: у «SUB» WC пишет LFN и мангленное 8.3)."""
        start = self.lba(cluster) * 512
        count = 0
        for offset in range(0, 512, 32):
            record = self.disk[start + offset:start + offset + 32]
            if record[0] == 0:
                break
            if record[0] not in (0xE5, 0x2E) and record[11] != 0x0F:
                found = int.from_bytes(record[26:28], 'little') | int.from_bytes(record[20:22], 'little') << 16
                count += found == target
        return count

    def dotdot(self, cluster):
        start = self.lba(cluster) * 512 + 32
        record = self.disk[start:start + 32]
        return int.from_bytes(record[26:28], 'little') | int.from_bytes(record[20:22], 'little') << 16

    def write_with_faults(self):
        lba = self.position
        number = self.writes_to[lba] = self.writes_to.get(lba, 0) + 1
        if number in self.failing.get(lba, ()):
            self.mem[self.core('ABT')] = 1
            p.ret(self.cpu)
            return
        if number in self.ambiguous.get(lba, ()):
            start = lba * 512
            self.disk[start:start + 512] = self.mem[self.cpu.hl:self.cpu.hl + 512]
            self.mem[self.core('ABT')] = 1
            p.ret(self.cpu)
            return
        self.transfer(True)

    def move(self, name=b'SUB', dest=None, flags=0):
        cpu, mem = self.cpu, self.mem
        query = b'\x10' + name + b'\0'
        target = b'\x10' + (name if dest is None else dest) + b'\0'
        mem[QUERY_SRC:QUERY_SRC + len(query)] = query
        mem[QUERY_DST:QUERY_DST + len(target)] = target
        mem[BLOCK:BLOCK + 32] = bytes(32)
        mem[BLOCK + FX['FILEX_P_FLAGS']] = flags
        mem[BLOCK + FX['FILEX_P_SIZE']] = 32
        mem[BLOCK + FX['FILEX_P_VERSION']] = FX['FILEX_API_VERSION']
        mem[BLOCK + FX['FILEX_P_OPERATION']] = FX['FILEX_OP_MOVE_RENAME']
        p.h.put16(mem, BLOCK + FX['FILEX_P_BUFFER'], QUERY_SRC)
        p.h.put16(mem, BLOCK + FX['FILEX_P_LENGTH'], len(query))
        p.h.put16(mem, BLOCK + FX['FILEX_P_AUX'], QUERY_DST)
        p.h.put16(mem, BLOCK + FX['FILEX_P_AUX_LENGTH'], len(target))
        p.h.put32(mem, BLOCK + FX['FILEX_P_SOURCE_DIR'], self.src)
        p.h.put32(mem, BLOCK + FX['FILEX_P_DEST_DIR'], self.dst)
        cpu.hl, cpu.pc, cpu.sp = BLOCK, FX['FILEX_ENTRY'], p.STACK
        p.h.put16(mem, p.STACK, p.STOP)
        for address in {p.STOP, *self.callbacks}:
            cpu.set_breakpoint(address)
        start = time.monotonic()
        while True:
            cpu.ticks_to_stop = 1000000
            event = cpu.run()
            if event & 2:
                if cpu.pc == p.STOP:
                    break
                if cpu.pc in self.callbacks:
                    self.callbacks[cpu.pc]()
            if time.monotonic() - start > 120:
                raise RuntimeError(('timeout', hex(cpu.pc), self.page))
        return mem[BLOCK + FX['FILEX_P_STATUS']]


def lfn_records(name, sfn):
    """Записи LFN имени name (ASCII) перед короткой записью sfn — в порядке на
    диске, от последней части к первой."""
    total = 0
    for byte in sfn:
        total = (((total & 1) << 7) + (total >> 1) + byte) & 0xFF
    units = list(name) + [0]
    units += [0xFFFF] * (-len(units) % 13)
    count = len(units) // 13
    slots = list(range(1, 11, 2)) + list(range(14, 26, 2)) + list(range(28, 32, 2))
    records = []
    for index in range(count):
        record = bytearray(32)
        record[0] = (index + 1) | (0x40 if index == count - 1 else 0)
        for slot, unit in zip(slots, units[index * 13:(index + 1) * 13]):
            record[slot:slot + 2] = unit.to_bytes(2, 'little')
        record[11], record[13] = 0x0F, total
        records.append(bytes(record))
    return records[::-1]


class LongTree(Tree):
    """SRC — два кластера: в первом «.», «..», 12 коротких записей и две записи
    LFN каталога longdirectoryname, во втором — его короткая запись LONGDI~1.
    Удаление пишет сектор LFN раньше сектора SFN. bad_reads — LBA -> сколько
    чтений отказать после первой записи в этот сектор."""

    NAME, SFN = b'longdirectoryname', b'LONGDI~1   '

    def __init__(self):
        super().__init__()
        self.src2 = self.sub + 1
        self.set_fat(self.src, self.src2)
        self.set_fat(self.src2, 0x0FFFFFFF)
        p.h.put32(self.mem, self.core('FSTFRC'), self.src2 + 1)
        fillers = [entry(b'F%02d     BIN' % i, 0, 0x20) for i in range(12)]
        self.put_dir(self.src, 0, fillers + lfn_records(self.NAME, self.SFN))
        start = self.lba(self.src2) * 512
        self.disk[start:start + 512] = entry(self.SFN, self.sub) + bytes(480)
        self.bad_reads = {}
        self.callbacks[self.core('RDDSE')] = self.read_with_faults

    def read_with_faults(self):
        lba = self.position
        if self.bad_reads.get(lba) and self.writes_to.get(lba):
            self.bad_reads[lba] -= 1
            self.mem[self.core('ABT')] = 1
            p.ret(self.cpu)
            return
        self.transfer(False)

    def source_links(self):
        return self.links(self.src, self.sub) + self.links(self.src2, self.sub)


class MoveRollback(unittest.TestCase):

    def test_plain_move(self):
        tree = Tree()
        status = tree.move()
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        self.assertEqual(tree.links(tree.src, tree.sub), 0)
        self.assertEqual(tree.links(tree.dst, tree.sub), 1)
        self.assertEqual(tree.dotdot(tree.sub), tree.dst)

    def test_dotdot_write_applied_but_reported_failure_is_rolled_back(self):
        tree = Tree()
        tree.ambiguous = {tree.lba(tree.sub): {1}}           # первая запись «..»
        status = tree.move()
        self.assertEqual(tree.writes_to.get(tree.lba(tree.sub)), 2, '«..» не возвращён')
        self.assertEqual(tree.dotdot(tree.sub), tree.src,
                         'каталог остался в SRC, а его «..» указывает на DST')
        self.assertEqual(tree.links(tree.src, tree.sub), 1)
        self.assertEqual(tree.links(tree.dst, tree.sub), 0, 'ссылка назначения осталась')
        self.assertNotEqual(status, FX['FILEX_STATUS_OK'])

    def test_destination_link_applied_but_reported_failure(self):
        # Первая запись в DST — ссылка назначения — легла, драйвер вернул
        # отказ. Прежде RET NZ: на каталог смотрели обе ссылки (аудит Codex).
        tree = Tree()
        tree.ambiguous = {tree.lba(tree.dst): {1}}
        status = tree.move()
        self.assertEqual(tree.writes_to.get(tree.lba(tree.dst), 0) >= 1, True)
        self.assertEqual(tree.links(tree.dst, tree.sub), 0, 'ссылка назначения осталась: две ссылки')
        self.assertEqual(tree.links(tree.src, tree.sub), 1)
        self.assertEqual(tree.dotdot(tree.sub), tree.src)
        self.assertNotEqual(status, FX['FILEX_STATUS_OK'])

    def test_destination_with_trailing_space_or_dot_is_refused(self):
        # «NEW »: SVHDFL пишет NEW, а поиск и откат шли по «NEW » и записи не
        # находили — две ссылки на каталог без всякого сбоя (аудит Codex).
        for dest in (b'NEW ', b'NEW.', b'NEW. '):
            with self.subTest(dest=dest):
                tree = Tree()
                before = bytes(tree.disk)
                status = tree.move(dest=dest)
                self.assertEqual(status, FX['FILEX_STATUS_INVALID_NAME'])
                self.assertEqual(bytes(tree.disk), before, 'отказ, а диск изменился')

    def test_plain_new_name_moves(self):
        tree = Tree()
        status = tree.move(dest=b'NEW')
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        self.assertEqual(tree.links(tree.src, tree.sub), 0)
        self.assertEqual(tree.links(tree.dst, tree.sub), 1)

    def test_dotdot_not_restored_keeps_the_destination_link(self):
        # «..» лёг на DST, вернуть не удалось ни одной из трёх попыток:
        # ссылка назначения остаётся — с ней «..» согласован; результат —
        # ROLLBACK, а не тихий успех отката.
        tree = Tree()
        tree.ambiguous = {tree.lba(tree.sub): {1}}
        tree.failing = {tree.lba(tree.sub): {2, 3, 4}}
        status = tree.move()
        self.assertEqual(status, FX['FILEX_STATUS_ROLLBACK'])
        self.assertEqual(tree.writes_to.get(tree.lba(tree.sub)), 4, 'не три попытки возврата «..»')
        self.assertEqual(tree.dotdot(tree.sub), tree.dst)
        self.assertEqual(tree.links(tree.dst, tree.sub), 1,
                         'ссылка назначения удалена, а «..» указывает на DST')
        self.assertEqual(tree.append_valid(), 0, 'контекст после неудачного отката')

    def test_dotdot_restored_on_second_attempt(self):
        # Первая попытка возврата «..» отказала, вторая легла (драйвер, R8):
        # прежде одна попытка — и ROLLBACK с двумя ссылками.
        tree = Tree()
        tree.ambiguous = {tree.lba(tree.sub): {1}}
        tree.failing = {tree.lba(tree.sub): {2}}
        status = tree.move()
        self.assertEqual(status, FX['FILEX_STATUS_MEDIA'])
        self.assertEqual(tree.dotdot(tree.sub), tree.src)
        self.assertEqual((tree.links(tree.src, tree.sub), tree.links(tree.dst, tree.sub)), (1, 0))

    def test_destination_link_delete_retried_by_place(self):
        # Ссылка назначения легла с отказом; её удаление в откате тоже
        # отказало — прежде одна попытка по имени оставляла две ссылки. Теперь
        # запись добивается по месту (ENTRY_KILL_AT).
        tree = Tree()
        tree.ambiguous = {tree.lba(tree.dst): {1}}
        tree.failing = {tree.lba(tree.dst): {2}}
        status = tree.move()
        self.assertEqual(status, FX['FILEX_STATUS_MEDIA'])
        self.assertGreaterEqual(tree.writes_to.get(tree.lba(tree.dst)), 3, 'сценарий не тот')
        self.assertEqual((tree.links(tree.src, tree.sub), tree.links(tree.dst, tree.sub)), (1, 0))
        self.assertEqual(tree.dotdot(tree.sub), tree.src)

    def test_rollback_forgets_the_context(self):
        # Контекст мог быть уже взят по новой ссылке, которую откат удалил:
        # следующий FILEX без FENTRY писал бы по чужой цепочке (драйвер, R9-1).
        tree = Tree()
        self.assertEqual(tree.append_valid(), 1)
        tree.ambiguous = {tree.lba(tree.sub): {1}}           # «..» лёг с отказом
        self.assertNotEqual(tree.move(), FX['FILEX_STATUS_OK'])
        self.assertEqual(tree.append_valid(), 0, 'контекст после отката')

    def test_failure_without_writes_keeps_the_context(self):
        # Отказ до любой записи (имя недопустимо) — контекст прежний, на
        # диске ничего; код — INVALID_NAME, не INTERNAL (драйвер, R10-3).
        tree = Tree()
        before = bytes(tree.disk)
        status = tree.move(dest=b'A?B')
        self.assertEqual(status, FX['FILEX_STATUS_INVALID_NAME'])
        self.assertEqual(bytes(tree.disk), before)
        self.assertEqual(tree.append_valid(), 1)

    def test_full_volume_reports_no_space(self):
        # Каталог назначения полон, свободных кластеров нет: прежде NO_SPACE
        # уходил с Z, MOVE шёл дальше и отвечал NOT_FOUND (драйвер, R10-3).
        tree = Tree()
        names = [entry(b'D%02d        ' % i, 0, 0x20) for i in range(14)]
        tree.put_dir(tree.dst, 0, names)
        for cluster in range(2, tree.limit):
            if tree.fat(cluster) == 0:
                tree.set_fat(cluster, 0x0FFFFFFF)
        before = bytes(tree.disk)
        status = tree.move()
        self.assertEqual(status, FX['FILEX_STATUS_NO_SPACE'])
        self.assertEqual(bytes(tree.disk), before)


class ReplaceCommit(unittest.TestCase):
    """MOVE с REPLACE (аудит, А.3; 2026-09-26): в DST уже есть пустой каталог
    SUB (кластер old). Запись назначения, перенаправленная на цепочку
    источника, — первая запись в сектор DST. Прежде её отказ после того, как
    она легла, возвращал MEDIA без отката: на каталог смотрели обе записи, а
    старая цепочка назначения терялась."""

    def tree(self):
        tree = Tree()
        tree.old = tree.sub + 1
        tree.set_fat(tree.old, 0x0FFFFFFF)
        p.h.put32(tree.mem, tree.core('FSTFRC'), tree.old + 1)
        tree.put_dir(tree.dst, 0, [entry(b'SUB        ', tree.old)])
        tree.put_dir(tree.old, tree.dst, [])
        return tree

    def test_plain_replace(self):
        tree = self.tree()
        status = tree.move(flags=FX['FILEX_FLAG_REPLACE'])
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        self.assertEqual((tree.links(tree.src, tree.sub), tree.links(tree.dst, tree.sub)), (0, 1))
        self.assertEqual(tree.fat(tree.old), 0, 'старая цепочка назначения не освобождена')

    def test_commit_applied_but_reported_failure_is_rolled_back(self):
        tree = self.tree()
        tree.ambiguous = {tree.lba(tree.dst): {1}}
        status = tree.move(flags=FX['FILEX_FLAG_REPLACE'])
        self.assertEqual(tree.links(tree.src, tree.sub), 1)
        self.assertEqual(tree.links(tree.dst, tree.sub), 0, 'на каталог смотрят две записи')
        self.assertEqual(tree.links(tree.dst, tree.old), 1, 'прежняя запись назначения не возвращена')
        self.assertNotEqual(tree.fat(tree.old), 0)
        self.assertEqual(tree.dotdot(tree.sub), tree.src)
        self.assertEqual(status, FX['FILEX_STATUS_MEDIA'])

    def test_commit_failed_needs_no_restore(self):
        tree = self.tree()
        tree.failing = {tree.lba(tree.dst): {1}}
        status = tree.move(flags=FX['FILEX_FLAG_REPLACE'])
        self.assertEqual(tree.writes_to.get(tree.lba(tree.dst)), 1, 'лишняя запись в DST')
        self.assertEqual((tree.links(tree.dst, tree.old), tree.links(tree.src, tree.sub)), (1, 1))
        self.assertEqual(status, FX['FILEX_STATUS_MEDIA'])
        # Исход записи неизвестен — контекст снят (драйвер, R4-7, R3-4).
        self.assertEqual(tree.append_valid(), 0)

    def test_restore_retried(self):
        # Запись назначения легла с отказом, первая попытка вернуть прежнюю
        # тоже отказала: вторая попытка узнаёт новую запись и возвращает
        # прежнюю (прежде — одна попытка, драйвер, R8).
        tree = self.tree()
        tree.ambiguous = {tree.lba(tree.dst): {1}}
        tree.failing = {tree.lba(tree.dst): {2}}
        status = tree.move(flags=FX['FILEX_FLAG_REPLACE'])
        self.assertEqual(tree.writes_to.get(tree.lba(tree.dst)), 3, 'сценарий не тот')
        self.assertEqual(tree.links(tree.dst, tree.old), 1, 'прежняя запись назначения не возвращена')
        self.assertEqual((tree.links(tree.dst, tree.sub), tree.links(tree.src, tree.sub)), (0, 1))
        self.assertEqual(status, FX['FILEX_STATUS_MEDIA'])

    def test_current_directory_is_not_replaced(self):
        # Заменяемый каталог — текущий (LSTCAT): замена освободила бы его, а
        # текущим остался бы свободный кластер (драйвер, R10-1).
        tree = self.tree()
        p.h.put32(tree.mem, tree.core('LSTCAT'), tree.old)
        before = bytes(tree.disk)
        status = tree.move(flags=FX['FILEX_FLAG_REPLACE'])
        self.assertEqual(status, FX['FILEX_STATUS_INVALID_MOVE'])
        self.assertEqual(bytes(tree.disk), before)

    def test_shared_tail_is_refused(self):
        # Цепочки SUB и заменяемого каталога сходятся в общий кластер: замена
        # освобождала его из-под живого источника (драйвер, R2-7).
        tree = self.tree()
        shared = tree.old + 1
        tree.set_fat(tree.sub, shared)
        tree.set_fat(tree.old, shared)
        tree.set_fat(shared, 0x0FFFFFFF)
        before = bytes(tree.disk)
        status = tree.move(flags=FX['FILEX_FLAG_REPLACE'])
        self.assertEqual(status, FX['FILEX_STATUS_FAT'])
        self.assertEqual(bytes(tree.disk), before)

    def test_cyclic_destination_directory_is_refused(self):
        # Цепочка заменяемого каталога замкнута, нулевой записи нет: проверка
        # пустоты прежде не кончалась (драйвер, R7).
        tree = self.tree()
        second = tree.old + 1
        tree.set_fat(tree.old, second)
        tree.set_fat(second, tree.old)
        start = tree.lba(tree.old) * 512
        for offset in range(64, 512, 32):
            tree.disk[start + offset] = 0xE5
        tree.disk[tree.lba(second) * 512:tree.lba(second) * 512 + 512] = bytes([0xE5]) * 512
        before = bytes(tree.disk)
        status = tree.move(flags=FX['FILEX_FLAG_REPLACE'])
        self.assertEqual(status, FX['FILEX_STATUS_FAT'])
        self.assertEqual(bytes(tree.disk), before)


class SourceDelete(unittest.TestCase):
    """Отказ удаления исходной ссылки с LFN: сектор LFN лёг, сектор SFN — нет.
    Прежде FILEX искал источник по длинному имени, не находил (LFN стёрто) и
    фиксировал перенос: на каталог смотрели две живые ссылки (найдено при
    сверке комментариев FILEX, 2026-09-25). Теперь сектор SFN перечитывается
    по месту из контекста, как у RENAME ядра."""

    def test_plain_long_name_moves(self):
        tree = LongTree()
        status = tree.move(name=tree.NAME)
        self.assertEqual(status, FX['FILEX_STATUS_OK'])
        self.assertEqual((tree.source_links(), tree.links(tree.dst, tree.sub)), (0, 1))

    def test_sfn_write_failed_after_lfn_is_completed_by_place(self):
        # Запись SFN источника отказала (LFN уже стёрто): перенос доводится —
        # SFN помечается #E5 по месту (ENTRY_KILL_AT; прежде сразу откат, и
        # отказ уже в откате оставлял две ссылки, драйвер, R8).
        tree = LongTree()
        tree.failing = {tree.lba(tree.src2): {1}}
        status = tree.move(name=tree.NAME)
        self.assertEqual(tree.writes_to.get(tree.lba(tree.src2)), 2, 'сценарий не тот')
        self.assertEqual((tree.source_links(), tree.links(tree.dst, tree.sub)), (0, 1))
        self.assertEqual(tree.dotdot(tree.sub), tree.dst)
        self.assertEqual(status, FX['FILEX_STATUS_COMMITTED_CLEANUP'])

    def test_sfn_never_written_rolls_back(self):
        # Запись SFN источника не ложится ни разу (удаление по имени и три
        # попытки по месту): откат — источник цел, ссылки назначения нет.
        tree = LongTree()
        tree.failing = {tree.lba(tree.src2): {1, 2, 3, 4}}
        status = tree.move(name=tree.NAME)
        self.assertEqual(tree.writes_to.get(tree.lba(tree.src2)), 4, 'сценарий не тот')
        self.assertEqual((tree.source_links(), tree.links(tree.dst, tree.sub)), (1, 0))
        self.assertEqual(tree.dotdot(tree.sub), tree.src)
        self.assertEqual(status, FX['FILEX_STATUS_MEDIA'])
        self.assertEqual(tree.append_valid(), 0)

    def test_sfn_delete_applied_but_reported_failure_commits(self):
        tree = LongTree()
        tree.ambiguous = {tree.lba(tree.src2): {1}}
        status = tree.move(name=tree.NAME)
        self.assertEqual(status, FX['FILEX_STATUS_COMMITTED_CLEANUP'])
        self.assertEqual((tree.source_links(), tree.links(tree.dst, tree.sub)), (0, 1))
        self.assertEqual(tree.dotdot(tree.sub), tree.dst)

    def test_unreadable_source_sector_never_leaves_two_links(self):
        # Сектор SFN после отказа не читается (три попытки перечитать и
        # четыре — у доведения по месту): состояние неизвестно — откат.
        # Удаление не легло — источник цел; легло — ссылок не остаётся
        # (потерянная цепочка лучше общей).
        for applied in (False, True):
            with self.subTest(applied=applied):
                tree = LongTree()
                faults = {tree.lba(tree.src2): {1}}
                if applied:
                    tree.ambiguous = faults
                else:
                    tree.failing = faults
                tree.bad_reads = {tree.lba(tree.src2): 7}
                status = tree.move(name=tree.NAME)
                self.assertEqual(tree.bad_reads[tree.lba(tree.src2)], 0, 'перечитано меньше трёх раз')
                self.assertLessEqual(tree.source_links() + tree.links(tree.dst, tree.sub), 1,
                                     'на каталог смотрят две живые ссылки')
                self.assertEqual(tree.links(tree.dst, tree.sub), 0)
                self.assertEqual(status, FX['FILEX_STATUS_MEDIA'])

    def test_second_read_succeeds(self):
        # Первое чтение отказало, второе прошло: удаление легло — фиксация.
        tree = LongTree()
        tree.ambiguous = {tree.lba(tree.src2): {1}}
        tree.bad_reads = {tree.lba(tree.src2): 1}
        status = tree.move(name=tree.NAME)
        self.assertEqual(status, FX['FILEX_STATUS_COMMITTED_CLEANUP'])
        self.assertEqual((tree.source_links(), tree.links(tree.dst, tree.sub)), (0, 1))


if __name__ == '__main__':
    unittest.main(verbosity=2)
