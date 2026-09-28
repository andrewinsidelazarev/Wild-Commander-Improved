"""Короткое имя, LFN, RENAME, MKDIR и MKFILE на настоящем ядре с RAM-носителем
(2026-09-25).

Исполняются собранные CORE32/CORE32_EXT: поиск, создание и удаление записей —
код ядра, подменён только драйвер сектора (стенд test_overwrite_path).

* Короткое имя длинного файла: расширение 8.3 копировалось до трёх знаков без
  остановки на конце имени — у «README.md» оно было «MD»+#00, у однобуквенного
  ещё и байт буфера за концом имени. Недопустимые байты DIR_Name (нашлось
  прогоном на настоящих старых картах). Основа 8.3 так же брала хвост
  прежнего имени из буфера вызывающего (аудит Codex).
* LFN: NXTETY2 собирает длинное имя в поле вызывающего — не больше 255 знаков
  и ноль, даже если записей LFN на диске больше (аудит Codex).
* RENAME (аудит Codex, п. 5): DELETE_ENTRY_WITH_LFN пишет секторы с LFN раньше
  сектора SFN. LFN стёрты, запись сектора SFN отказала — поиск прежнего
  длинного имени не находит живую короткую запись, и прежняя проверка
  оставляла новую: две записи на одной цепочке. Так же при нечитаемом секторе.
  Запись нового имени легла, а драйвер вернул отказ, — переименование
  доводится. Код в A после отката — 0 («UNKNOWN ERROR!!» в окне F6).
* MKDIR (аудит Codex, п. 14) и MKFILE: сектор родителя лёг на носитель, а
  драйвер вернул ошибку — цепочка освобождалась, запись оставалась на
  свободном кластере. Теперь запись ищется по NXTBU (имя в том виде, в каком
  его записал SVHDFL), и цепочка освобождается, только если записи нет.
* SVHDFL (аудит, А.1 и А.2; 2026-09-26): отказ чтения каталога принимался за
  конец цепочки — каталог продлевался за текущим кластером, чужие имена
  пропадали; при продлении полного каталога новый кластер вписывался в
  цепочку до обнуления — отказ записи нулей делал обрывки прежних записей
  живыми (F8 по ним освобождал чужие цепочки).
"""
import random
import unittest

import test_lfn_namespace as ns
from test_overwrite_path import DIR_CLUSTER, Volume, same_name

RENAME, MKDIR = 0x4042, 0x403C
NEW_NAME = 0x7F80
Z = 0x40
BAD_SFN = set(b'"*+,./:;<=>?[\\]|') | set(range(0x20)) | set(range(0x61, 0x7B))


def live_sfn(volume):
    """Живые короткие записи каталога: (смещение, 32 байта)."""
    raw = volume.directory()
    out = []
    for offset in range(0, len(raw), 32):
        record = raw[offset:offset + 32]
        if record[0] == 0:
            break
        if record[0] != 0xE5 and record[11] != 0x0F:
            out.append((offset, record))
    return out


def cluster_of(record):
    return int.from_bytes(record[26:28], 'little') | int.from_bytes(record[20:22], 'little') << 16


class ShortNameExtension(unittest.TestCase):

    def test_short_extensions_end_at_the_name(self):
        for name, extension in (('README.md', b'MD '), ('get_depencies.sh', b'SH '),
                                ('hello world.c', b'C  '), ('Long source name.txt', b'TXT')):
            with self.subTest(name=name):
                volume = Volume(spc=1, fat_sectors=4)
                # Сначала длинное имя: буфер имени за концом следующего не пуст.
                self.assertEqual(volume.mkfile('a much longer previous name.binary', 0), (0, True))
                self.assertEqual(volume.mkfile(name, 10), (0, True))
                _, record = live_sfn(volume)[-1]                 # запись нового файла
                self.assertEqual(record[8:11], extension, f'расширение 8.3: {record[:11]!r}')
                self.assertFalse(set(record[:11]) & BAD_SFN, f'недопустимый байт: {record[:11]!r}')
                self.assertTrue([e for e in volume.entries() if same_name(e[0], name)])

    def test_short_name_base_takes_nothing_after_the_name(self):
        # Основа 8.3 длинного имени читает 8 знаков подряд; за концом короткого
        # имени в буфере вызывающего лежал хвост прежнего — «VATE» из
        # «Xprivate…» попадало в «A_B?VA~1» (аудит Codex, AZPRIV~1).
        volume = Volume(spc=1, fat_sectors=4)
        self.assertEqual(volume.mkfile('Xprivate leaked name.bin', 0), (0, True))
        self.assertEqual(volume.mkfile('A b', 10), (0, True))
        _, record = live_sfn(volume)[-1]
        self.assertEqual(record[:3], b'A_B')
        self.assertNotIn(b'VA', record[:8], f'в основе остаток прежнего имени: {record[:11]!r}')
        nxtbu = volume.core('NXTBU')
        tail = bytes(volume.mem[nxtbu + 5:nxtbu + 0x100])    # [тип]'A b'#00 и дальше
        self.assertEqual(tail, bytes(len(tail)), 'хвост NXTBU за концом имени не обнулён')


class LfnDecodeBound(unittest.TestCase):
    """NXTETY2 собирает LFN в поле вызывающего: 255 знаков и ноль (аудит Codex).
    Повреждённый каталог — 20 записей LFN по 13 букв без терминатора (260)."""

    OUT = 0x9000                        # байт типа, затем поле имени в 256 байт

    def listed(self, length, letter):
        raw = ns.long_entry(letter * length, b'LONGNA~1TXT').ljust(4096, b'\0')
        volume = Volume(spc=8, fat_sectors=4)                # корень — 8 секторов
        for n in range(8):
            volume.sectors[volume.cluster_lba(DIR_CLUSTER) + n] = raw[n * 512:(n + 1) * 512]
        volume.mem[self.OUT:self.OUT + 0x300] = b'\xCC' * 0x300
        volume.call(0x405A, a=0, de=self.OUT)                # NXTETY2
        return bytes(volume.mem[self.OUT + 1:self.OUT + 0x300])

    def test_overlong_lfn_stops_at_255(self):
        for length in (256, 260):
            with self.subTest(length=length):
                data = self.listed(length, 'a')
                self.assertEqual(data[:256], b'a' * 255 + b'\0', 'имя не оборвано на 255')
                self.assertEqual(data[256:272], b'\xCC' * 16, 'запись за 256-байтовым полем имени')

    def test_normal_255_char_name_is_whole(self):
        data = self.listed(255, 'b')
        self.assertEqual(data[:256], b'b' * 255 + b'\0')
        self.assertEqual(data[256:272], b'\xCC' * 16)


class RenameCrash(unittest.TestCase):

    def prepare(self, spc, old, fillers=0):
        volume = Volume(spc=spc, fat_sectors=4)
        for index in range(fillers):
            self.assertEqual(volume.mkfile(f'f{index:02}', 0), (0, True))
        self.assertEqual(volume.mkfile(old, 512), (0, True))
        (_, cluster, _), = [e for e in volume.entries() if same_name(e[0], old)]
        (offset, _), = [(o, r) for o, r in live_sfn(volume) if cluster_of(r) == cluster]
        target = volume.cluster_lba(DIR_CLUSTER) + offset // 512
        return volume, cluster, target

    def rename(self, volume, old, fail_write=None, fail_read_after=False, applied=False):
        """fail_write — номер записи в сектор target, которая откажет (1 — первая).
        applied — сектор при этом всё же лёг на носитель."""
        state = {'writes': 0, 'failed': False, 'read_failed': False}
        sddse, rddse = volume.handlers[volume.core('SDDSE')], volume.handlers[volume.core('RDDSE')]
        target = self.target

        def write():
            if volume.position == target:
                state['writes'] += 1
                if state['writes'] in (fail_write or ()):
                    state['failed'] = True
                    if applied:
                        volume.sectors[target] = bytes(volume.mem[volume.cpu.hl:volume.cpu.hl + 512])
                    volume.mem[volume.core('ABT')] = 1
                    volume._ret()
                    return
            sddse()

        def read():
            if fail_read_after and state['failed'] and not state['read_failed'] \
                    and volume.position == target:
                state['read_failed'] = True
                volume.mem[volume.core('ABT')] = 1
                volume._ret()
                return
            rddse()

        volume.handlers[volume.core('SDDSE')] = write
        volume.handlers[volume.core('RDDSE')] = read
        volume.mem[NEW_NAME:NEW_NAME + 8] = b'new.bin\0'
        a, f, _, _ = volume.call(RENAME, hl=volume.query(old), de=NEW_NAME, budget=20000)
        volume.handlers[volume.core('SDDSE')], volume.handlers[volume.core('RDDSE')] = sddse, rddse
        self.a = a                                  # код для окна F6 (FEEM)
        return not f & Z, state

    def test_partial_lfn_delete_keeps_one_entry(self):
        # 14 коротких записей, затем длинное имя: LFN — в конце первого
        # сектора, SFN — во втором. Первая запись во второй сектор — новая
        # запись new.bin (легла), вторая — удаление прежней SFN (отказ).
        old = 'long-name-with-20-chars.txt'
        volume, cluster, self.target = self.prepare(8, old, fillers=14)
        done, state = self.rename(volume, old, fail_write=(2,))
        self.assertTrue(state['failed'], 'сбой не случился — сценарий не тот')
        owners = [r[:11] for _, r in live_sfn(volume) if cluster_of(r) == cluster]
        self.assertEqual(len(owners), 1, f'на цепочке {cluster} записей: {owners}')
        self.assertFalse(done, 'отказ удаления прежней записи сообщён как успех')
        self.assertFalse([e for e in volume.entries() if same_name(e[0], 'new.bin')])
        self.assertEqual(self.a, 0, 'после отката окно F6 не «UNKNOWN ERROR!!»')

    def test_unreadable_old_sector_keeps_one_entry(self):
        volume, cluster, self.target = self.prepare(1, 'old.bin')
        done, state = self.rename(volume, 'old.bin', fail_write=(2,), fail_read_after=True)
        self.assertTrue(state['read_failed'], 'повторное чтение не понадобилось')
        owners = [r[:11] for _, r in live_sfn(volume) if cluster_of(r) == cluster]
        self.assertEqual(len(owners), 1, f'на цепочке {cluster} записей: {owners}')
        self.assertFalse(done)
        self.assertEqual(self.a, 0, 'после отката окно F6 не «UNKNOWN ERROR!!»')

    def test_applied_old_delete_keeps_the_new_name(self):
        # Удаление прежней легло на носитель, драйвер вернул ошибку: откат
        # снёс бы последнюю ссылку — новая остаётся, переименовано.
        volume, cluster, self.target = self.prepare(1, 'old.bin')
        done, state = self.rename(volume, 'old.bin', fail_write=(2,), applied=True)
        self.assertTrue(state['failed'])
        names = [e[0] for e in volume.entries() if e[1] == cluster]
        self.assertEqual([n.lower() for n in names], ['new.bin'])
        self.assertTrue(done)

    def test_new_entry_applied_but_reported_failure_completes(self):
        # Запись нового имени (первая запись в сектор) легла, драйвер вернул
        # отказ: прежде RENAME сообщал «нет» и оставлял обе записи на цепочке.
        volume, cluster, self.target = self.prepare(1, 'old.bin')
        done, state = self.rename(volume, 'old.bin', fail_write=(1,), applied=True)
        self.assertTrue(state['failed'])
        names = [e[0].lower() for e in volume.entries() if e[1] == cluster]
        self.assertEqual(names, ['new.bin'], f'на цепочке {cluster}: {names}')
        self.assertTrue(done)

    def test_plain_rename_still_works(self):
        volume, cluster, self.target = self.prepare(8, 'long-name-with-20-chars.txt', fillers=14)
        done, _ = self.rename(volume, 'long-name-with-20-chars.txt')
        self.assertTrue(done)
        names = [e[0] for e in volume.entries() if e[1] == cluster]
        self.assertEqual([n.lower() for n in names], ['new.bin'])


class MkdirCrash(unittest.TestCase):

    def mkdir(self, volume, name='new'):
        data = name.encode() + b'\0'
        volume.mem[0x7E00:0x7E00 + len(data)] = data
        volume.mem[volume.core('ENTRY') + 11] = 0x10
        a, f, _, _ = volume.call(MKDIR, hl=0x7E00, budget=20000)
        return a, not f & Z

    def test_parent_write_applied_but_reported_failure(self):
        volume = Volume(spc=1, fat_sectors=4)
        volume.ambiguous_writes = {volume.cluster_lba(DIR_CLUSTER)}
        a, failed = self.mkdir(volume)
        volume.ambiguous_writes = set()
        (entry,) = [e for e in volume.entries() if same_name(e[0], 'new')]
        _, cluster, _ = entry
        self.assertNotEqual(volume.fat(cluster) & 0x0FFFFFFF, 0,
                            'каталог в родителе, а его кластер свободен')
        body = volume.read_sector(volume.cluster_lba(cluster))
        self.assertEqual(body[:11], b'.          ')
        self.assertEqual(body[32:43], b'..         ')
        self.assertFalse(failed, 'каталог создан, а MKDIR сообщил отказ')

    def test_normalized_name_parent_write_applied(self):
        # «new » записан как NEW: поиск по исходному тексту его не находил, и
        # цепочка освобождалась под живой записью (аудит Codex). Теперь поиск
        # идёт по NXTBU — тому, что записал SVHDFL.
        volume = Volume(spc=1, fat_sectors=4)
        volume.ambiguous_writes = {volume.cluster_lba(DIR_CLUSTER)}
        a, failed = self.mkdir(volume, 'new ')
        volume.ambiguous_writes = set()
        (entry,) = [e for e in volume.entries() if same_name(e[0], 'new')]
        self.assertNotEqual(volume.fat(entry[1]) & 0x0FFFFFFF, 0, 'каталог на свободном кластере')
        self.assertFalse(failed)

    def test_parent_write_failed_frees_the_chain(self):
        volume = Volume(spc=1, fat_sectors=4)
        volume.fail_writes = {volume.cluster_lba(DIR_CLUSTER)}
        a, failed = self.mkdir(volume)
        volume.fail_writes = set()
        self.assertTrue(failed)
        self.assertEqual(a, 0xFF, 'отказ носителя назван ошибкой имени')
        self.assertFalse([e for e in volume.entries() if same_name(e[0], 'new')])
        self.assertEqual(volume.allocated(), {DIR_CLUSTER}, 'цепочка несостоявшегося каталога не освобождена')

    def test_existing_name_frees_the_chain(self):
        # Отказ по имени — не носителя: цепочка освобождается, как прежде.
        volume = Volume(spc=1, fat_sectors=4)
        a, failed = self.mkdir(volume)
        self.assertFalse(failed)
        before = volume.allocated()
        a, failed = self.mkdir(volume)
        self.assertTrue(failed)
        self.assertNotEqual(a, 0xFF)
        self.assertEqual(volume.allocated(), before, 'цепочка второго каталога потеряна')

    def test_body_write_failure_reports_media_error(self):
        volume = Volume(spc=1, fat_sectors=4)
        body = volume.cluster_lba(3)                     # первый свободный кластер
        volume.fail_writes = {body}
        a, failed = self.mkdir(volume)
        volume.fail_writes = set()
        self.assertTrue(failed)
        self.assertEqual(a, 0xFF)
        self.assertEqual(volume.allocated(), {DIR_CLUSTER})
        self.assertFalse([e for e in volume.entries() if same_name(e[0], 'new')])


class MkfileCrash(unittest.TestCase):
    """MKFILE ядра (#4039): прежде CALL SVHDFL:JP NZ,DELCHA."""

    def test_parent_write_applied_but_reported_failure(self):
        volume = Volume(spc=1, fat_sectors=4)
        volume.ambiguous_writes = {volume.cluster_lba(DIR_CLUSTER)}
        result = volume.mkfile('NEW.BIN', 512)
        volume.ambiguous_writes = set()
        (entry,) = [e for e in volume.entries() if same_name(e[0], 'NEW.BIN')]
        self.assertNotEqual(volume.fat(entry[1]) & 0x0FFFFFFF, 0, 'запись файла на свободном кластере')
        self.assertEqual(result, (0, True), 'файл создан, а MKFILE сообщил отказ')

    def test_parent_write_failed_frees_the_chain(self):
        volume = Volume(spc=1, fat_sectors=4)
        volume.fail_writes = {volume.cluster_lba(DIR_CLUSTER)}
        a, ok = volume.mkfile('NEW.BIN', 512)
        volume.fail_writes = set()
        self.assertFalse(ok)
        self.assertFalse([e for e in volume.entries() if same_name(e[0], 'NEW.BIN')])
        self.assertEqual(volume.allocated(), {DIR_CLUSTER})

    def test_existing_name_frees_the_chain(self):
        volume = Volume(spc=1, fat_sectors=4)
        self.assertEqual(volume.mkfile('NEW.BIN', 512), (0, True))
        before = volume.allocated()
        a, ok = volume.mkfile('NEW.BIN', 512)
        self.assertFalse(ok)
        self.assertEqual(volume.allocated(), before, 'цепочка второго файла потеряна')


class AllocationFailure(unittest.TestCase):
    """Отказ записи FAT при выделении цепочки (MKSG): MKDIR и MKFILE отдавали
    сырой код драйвера из ABT (1), и F7/F5 писали «Long Name is not valid!»
    (аудит Codex, R12-2; 2026-09-26). Теперь — #FF, «UNKNOWN ERROR!!»."""

    def test_fat_write_failure_is_media_code(self):
        for kind in ('mkfile', 'mkdir'):
            with self.subTest(kind=kind):
                volume = Volume(spc=1, fat_sectors=4)
                volume.fail_writes = set(range(volume.sfat, volume.sdfat))
                if kind == 'mkfile':
                    a, done = volume.mkfile('new.bin', 512)
                else:
                    volume.mem[NEW_NAME:NEW_NAME + 7] = b'newdir\0'
                    volume.mem[volume.core('ENTRY') + 11] = 0x10
                    a, f, _, _ = volume.call(MKDIR, hl=NEW_NAME, budget=2000000)
                    done = bool(f & Z)                      # MKDIR: Z — создан
                volume.fail_writes = set()
                self.assertFalse(done)
                self.assertEqual(a, 0xFF, 'код отказа носителя не #FF')

    def create(self, volume, kind, size=512):
        if kind == 'mkfile':
            return volume.mkfile('new.bin', size)
        volume.mem[NEW_NAME:NEW_NAME + 7] = b'newdir\0'
        volume.mem[volume.core('ENTRY') + 11] = 0x10
        a, f, _, _ = volume.call(MKDIR, hl=NEW_NAME, budget=2000000)
        return a, bool(f & Z)

    def test_fat_read_failure_is_media_code(self):
        # Codex R24-02 (2026-09-27): отказ чтения FAT при поиске свободного
        # кластера MKSG отдавал тем же кодом 16, что и нехватку места, — F5/F7
        # писали «Not Enough Space!» при свободном томе. Теперь #FF.
        for kind in ('mkfile', 'mkdir'):
            with self.subTest(kind=kind):
                volume = Volume(spc=1, fat_sectors=4)
                before = volume.allocated()
                volume.fail_lbas = set(range(volume.sfat, volume.sdfat))
                a, done = self.create(volume, kind)
                volume.fail_lbas = set()
                self.assertEqual((a, done), (0xFF, False))
                self.assertEqual(volume.allocated(), before)

    def test_fat_read_failure_after_partial_allocation(self):
        # Отказ чтения следующего сектора FAT, когда первый кластер цепочки уже
        # найден (ERG2: DLSG освобождает собранное и своим обменом сбрасывает
        # ABT) — тоже #FF, и ничего не занято.
        volume = Volume(spc=1, fat_sectors=4)
        for cluster in range(3, 128):
            if cluster != 100:
                volume.set_fat(cluster, 0x0FFFFFFF)
        before = volume.allocated()
        volume.fail_lbas = {volume.sfat + 1}
        a, done = volume.mkfile('two.bin', 1024)
        volume.fail_lbas = set()
        self.assertEqual((a, done), (0xFF, False))
        self.assertEqual(volume.allocated(), before, 'частичная цепочка не освобождена')

    def test_no_space_is_still_16(self):
        for kind in ('mkfile', 'mkdir'):
            with self.subTest(kind=kind):
                volume = Volume(spc=1, fat_sectors=1)
                for cluster in range(3, volume.clusters):
                    volume.set_fat(cluster, 0x0FFFFFFF)
                self.assertEqual(self.create(volume, kind), (16, False))

class Plan(Volume):
    """plan — номер обмена с носителем (1, 2, …) → 'fail' (не прошёл) или
    'applied' (сектор записан, а драйвер вернул отказ); events — журнал."""

    def __init__(self, **options):
        super().__init__(**options)
        self.plan, self.events = {}, []
        self.handlers[self.core('RDDSE')] = lambda: self.planned(False)
        self.handlers[self.core('SDDSE')] = lambda: self.planned(True)

    def planned(self, write):
        kind = self.plan.get(len(self.events) + 1)
        self.events.append(('W' if write else 'R', self.position))
        if kind is None:
            self._transfer(write)
            return
        if write and kind == 'applied':
            self.sectors[self.position] = bytes(self.mem[self.cpu.hl:self.cpu.hl + 512])
        self.mem[self.core('ABT')] = 1
        self._ret()


def names(volume):
    return sorted(entry[0].lower() for entry in volume.entries())


class DirectoryScan(unittest.TestCase):
    """SVHDFL, поиск места под новую запись (аудит, А.1; 2026-09-26). Корень —
    три кластера по сектору (16 + 16 + 4 записи). Отказ чтения сектора
    каталога прежде принимался за конец цепочки: каталог продлевался за
    текущим кластером, ссылка FAT на остаток затиралась, чужие имена
    пропадали, а MKFILE и MKDIR сообщали успех. Перебираются все одиночные
    отказы чтения."""

    def build(self):
        volume = Plan(spc=1, fat_sectors=4)
        for index in range(36):
            self.assertEqual(volume.mkfile(f'f{index:02}', 512 if index >= 16 else 0), (0, True))
        return volume

    def operation(self, volume, kind):
        if kind == 'mkfile':
            return volume.mkfile('new.bin', 0)
        if kind == 'mkdir':
            volume.mem[NEW_NAME:NEW_NAME + 7] = b'newdir\0'
            volume.mem[volume.core('ENTRY') + 11] = 0x10
            a, f, _, _ = volume.call(MKDIR, hl=NEW_NAME, budget=2000000)
            return a, not f & Z
        volume.mem[NEW_NAME:NEW_NAME + 8] = b'new.bin\0'
        a, f, _, _ = volume.call(RENAME, hl=volume.query('f20'), de=NEW_NAME, budget=2000000)
        return a, not f & Z

    def test_single_read_failure_loses_no_names(self):
        for kind in ('mkfile', 'mkdir', 'rename'):
            control = self.build()
            before, chain = names(control), control.chain(DIR_CLUSTER)
            self.assertEqual(len(chain), 3, 'корень не из трёх кластеров — сценарий не тот')
            control.events = []
            self.operation(control, kind)
            reads = [n for n, (op, _) in enumerate(control.events, 1) if op == 'R']
            for read in reads:
                with self.subTest(kind=kind, read=read):
                    volume = self.build()
                    volume.plan, volume.events = {read: 'fail'}, []
                    self.operation(volume, kind)
                    volume.plan = {}
                    renamed = {'f20'} if kind == 'rename' else set()
                    self.assertEqual(sorted(set(before) - set(names(volume)) - renamed), [],
                                     'пропали чужие имена')
                    self.assertEqual(volume.chain(DIR_CLUSTER)[:3], chain, 'цепочка каталога изменена')


class DirectoryGrowth(unittest.TestCase):
    """SVHDFL, продление полного каталога (аудит, А.2; 2026-09-26). В
    свободных кластерах — обрывок прежнего каталога: запись GHOST.BIN на
    первый кластер живого KEEP.BIN. Новый кластер каталога прежде вписывался
    в цепочку до обнуления: отказ записи нулей делал GHOST.BIN живой записью,
    и F8 по ней освобождал цепочку KEEP.BIN."""

    def prepare(self):
        volume = Plan(spc=1, fat_sectors=4)
        self.assertEqual(volume.mkfile('keep.bin', 1024), (0, True))
        (_, keep, _), = [e for e in volume.entries() if same_name(e[0], 'keep.bin')]
        index = 0
        while len(volume.entries()) < 16:
            self.assertEqual(volume.mkfile(f'f{index:02}', 0), (0, True))
            index += 1
        used = volume.allocated()
        record = bytearray(32)
        record[:11] = b'GHOST   BIN'
        record[11] = 0x20
        record[20:22] = (keep >> 16).to_bytes(2, 'little')
        record[26:28] = (keep & 0xFFFF).to_bytes(2, 'little')
        record[28:32] = (1024).to_bytes(4, 'little')
        free = [cluster for cluster in range(3, 60) if cluster not in used]
        for cluster in free:
            volume.sectors[volume.cluster_lba(cluster)] = bytes(record) + bytes(480)
        return volume, volume.chain(keep), free

    def check(self, volume, keep_chain):
        ghosts = [e for e in volume.entries() if same_name(e[0], 'ghost.bin')]
        self.assertEqual(ghosts, [], 'в каталоге ожил обрывок прежнего каталога')
        self.assertTrue(all(volume.fat(cluster) for cluster in keep_chain), 'цепочка KEEP.BIN свободна')

    def test_plain_growth(self):
        volume, keep_chain, _ = self.prepare()
        self.assertEqual(volume.mkfile('new.bin', 0), (0, True))
        self.assertEqual(len(volume.chain(DIR_CLUSTER)), 2)
        self.assertIn('new.bin', names(volume))
        self.check(volume, keep_chain)

    def test_zeroing_failure_leaves_no_ghost(self):
        volume, keep_chain, free = self.prepare()
        volume.fail_writes = {volume.cluster_lba(cluster) for cluster in free}
        a, done = volume.mkfile('new.bin', 0)
        volume.fail_writes = set()
        self.assertFalse(done)
        self.check(volume, keep_chain)

    def test_every_single_write_failure_leaves_no_ghost(self):
        control, _, _ = self.prepare()
        control.events = []
        control.mkfile('new.bin', 0)
        writes = [n for n, (op, _) in enumerate(control.events, 1) if op == 'W']
        for write in writes:
            for kind in ('fail', 'applied'):
                with self.subTest(write=write, kind=kind):
                    volume, keep_chain, _ = self.prepare()
                    volume.plan, volume.events = {write: kind}, []
                    volume.mkfile('new.bin', 0)
                    volume.plan = {}
                    self.check(volume, keep_chain)


class TreeChild(unittest.TestCase):
    """Проверка каталога перед входом обхода дерева F5/F8 (ID_TREE_CHILD,
    2026-09-27): первый сектор — «.» на этот же кластер и «..» на текущий
    каталог (у корня «..» — 0 или номер корневого кластера). Испорченная
    запись вела обход не туда: кластер 0 GLSTCAT понимает как корень — F8
    одного такого каталога удалял неотмеченные файлы корня; кластер корня —
    так же; кластер чужого каталога — по чужому дереву; кластер файла или
    свободный — по случайным данным."""

    STUB = 0x7D00

    def volume(self):
        from test_io_failures import dot_sector, record
        volume = Volume(spc=1, fat_sectors=4)
        sectors = {10: dot_sector(10, parent=0), 11: dot_sector(11, parent=2),
                   12: dot_sector(12, parent=10), 13: b'hello, file data' * 32,
                   14: dot_sector(14, parent=0)}
        for cluster, data in sectors.items():
            volume.sectors[volume.cluster_lba(cluster)] = data
            if cluster != 14:                                    # 14 — свободен в FAT
                volume.set_fat(cluster, 0x0FFFFFFF)
        volume.sectors[volume.cluster_lba(DIR_CLUSTER)] = record(b'KEEP    BIN', 20, 0x20).ljust(512, b'\0')
        gate = volume.core('EXTENSION_GATE').to_bytes(2, 'little')
        ident = volume.sym['WDOS_EXT.ID_TREE_CHILD']
        volume.mem[self.STUB:self.STUB + 5] = bytes([0xCD]) + gate + bytes([ident, 0xC9])
        return volume

    def child(self, cluster, current=0, fail=False):
        volume = self.volume()
        lstcat = volume.core('LSTCAT')
        volume.mem[lstcat:lstcat + 4] = current.to_bytes(4, 'little')
        if fail:
            volume.fail_lbas = {volume.cluster_lba(cluster)}
        _, f, _, _ = volume.call(self.STUB, hl=cluster & 0xFFFF, de=cluster >> 16)
        return bool(f & Z)

    def test_real_subdirectories(self):
        for cluster, current in ((10, 0), (11, 0), (10, 2), (12, 10)):
            with self.subTest(cluster=cluster, current=current):
                self.assertTrue(self.child(cluster, current), 'настоящий подкаталог не пропущен')

    def test_broken_entries(self):
        for cluster, current, why in ((0, 0, 'кластер 0 — корень'), (2, 0, 'кластер корня'),
                                      (12, 0, '«..» — не текущий каталог'),
                                      (10, 11, 'чужой каталог'), (13, 0, 'данные файла'),
                                      (14, 0, 'свободный кластер'), (1, 0, 'недопустимый кластер')):
            with self.subTest(why=why):
                self.assertFalse(self.child(cluster, current), why)
        self.assertFalse(self.child(10, 0, fail=True), 'отказ чтения')

    def chain(self, links, limit=None, sector=None):
        """Каталог на кластере 10 с цепочкой links (кластер: значение FAT)."""
        volume = self.volume()
        for cluster, value in links.items():
            volume.set_fat(cluster, value)
        if sector is not None:
            volume.sectors[volume.cluster_lba(10)] = sector
        if limit is not None:
            address = volume.extension('FAT_DATA_CLUSTER_LIMIT')
            volume.mem[address:address + 4] = limit.to_bytes(4, 'little')
        _, f, _, _ = volume.call(self.STUB, hl=10)
        return bool(f & Z)

    def test_whole_chain_is_checked(self):
        # Codex R25-02/R25-03 (2026-09-27): замкнутая цепочка каталога
        # перечислялась без конца (F8 висел), кластер за областью данных тома
        # вёл чтение и запись за его границу. Цепочка проверяется целиком.
        from test_io_failures import dot_sector
        self.assertTrue(self.chain({10: 15, 15: 0x0FFFFFFF}), 'каталог из двух кластеров')
        for links, limit, why in (({10: 10}, None, 'цикл на себя'),
                                  ({10: 15, 15: 10}, None, 'цикл через второй кластер'),
                                  ({10: 16, 16: 0}, None, 'ссылка на свободный кластер'),
                                  ({10: 110}, 100, 'ссылка за областью данных'),
                                  ({10: 0x0FFFFFF7}, None, 'плохой кластер в цепочке')):
            with self.subTest(why=why):
                self.assertFalse(self.chain(links, limit), why)
        with self.subTest(why='первый кластер за областью данных'):
            volume = self.volume()
            volume.set_fat(110, 0x0FFFFFFF)
            volume.sectors[volume.cluster_lba(110)] = dot_sector(110, parent=0)
            address = volume.extension('FAT_DATA_CLUSTER_LIMIT')
            volume.mem[address:address + 4] = (100).to_bytes(4, 'little')
            _, f, _, _ = volume.call(self.STUB, hl=110)
            self.assertFalse(f & Z)
        with self.subTest(why='«..» с лишним знаком'):
            sector = bytearray(dot_sector(10, parent=0))
            sector[34] = ord('X')
            self.assertFalse(self.chain({}, sector=bytes(sector)))

    def test_self_reference(self):
        # Codex R26-01: запись подкаталога на сам текущий каталог — отказ.
        self.assertFalse(self.child(12, 12), 'подкаталог — сам текущий каталог')


class FileChain(unittest.TestCase):
    """F5 файла: цепочка источника до создания копии (ID_FILE_CHAIN,
    2026-09-27). Проба на стенде: у файла кластер помечен в FAT свободным (0);
    MKFILE отдавал его копии, цепочки источника и копии сцеплялись, и F5 молча
    копировал часть из чужого кластера. Нужно ⌈размер/(512·SPC)⌉ кластеров:
    каждый обычный и в томе, ссылки допустимы, запись последнего — EOC или
    ссылка в томе; кластер 0 — только у пустого файла."""

    STUB, CLUSTER, SIZE = 0x7D00, 0x7E00, 0x7E10

    def check(self, first, size, links=None, spc=1, limit=None):
        volume = Volume(spc=spc, fat_sectors=4)
        for cluster, value in (links or {}).items():
            volume.set_fat(cluster, value)
        if limit is not None:
            address = volume.extension('FAT_DATA_CLUSTER_LIMIT')
            volume.mem[address:address + 4] = limit.to_bytes(4, 'little')
        return self.portions(volume, first, size)[0]

    def portions(self, volume, first, size, between=None):
        """Весь протокол FILE_CHAIN: первый вызов с A=0, пока CF=1 (порция,
        A=1) — снова с A=1 без HL и DE. between() — между порциями. Выход:
        (цела ли, число порций-пауз)."""
        gate = volume.core('EXTENSION_GATE').to_bytes(2, 'little')
        ident = volume.sym['WDOS_EXT.ID_FILE_CHAIN']
        volume.mem[self.STUB:self.STUB + 5] = bytes([0xCD]) + gate + bytes([ident, 0xC9])
        volume.mem[self.CLUSTER:self.CLUSTER + 4] = first.to_bytes(4, 'little')
        volume.mem[self.SIZE:self.SIZE + 4] = size.to_bytes(4, 'little')
        a, f, _, _ = volume.call(self.STUB, hl=self.CLUSTER, de=self.SIZE)
        pauses = 0
        while f & 1:
            self.assertEqual(a, 1, 'порция — A=1')
            self.assertLess(pauses, 100000, 'порциям нет конца')
            pauses += 1
            if between:
                between()
            a, f, _, _ = volume.call(self.STUB, a=1)
        return bool(f & Z), pauses

    def test_good_files(self):
        eoc = 0x0FFFFFFF
        for first, size, links, spc, why in (
                (0, 0, {}, 1, 'пустой без кластера'),
                (20, 0, {20: eoc}, 1, 'пустой с кластером'),
                (20, 1024, {20: 21, 21: eoc}, 1, 'два кластера'),
                (20, 1000, {20: 21, 21: eoc}, 1, 'хвост во втором кластере'),
                (20, 1024, {20: 21, 21: 22, 22: eoc}, 1, 'цепочка длиннее размера'),
                (20, 8193, {20: 21, 21: 22, 22: eoc}, 8, 'SPC=8, три кластера')):
            with self.subTest(why=why):
                self.assertTrue(self.check(first, size, links, spc), why)

    def test_broken_files(self):
        eoc = 0x0FFFFFFF
        for first, size, links, spc, limit, why in (
                (0, 100, {}, 1, None, 'данные есть, кластера нет'),
                (20, 1024, {20: eoc}, 1, None, 'цепочка короче размера'),
                (20, 1024, {20: 0}, 1, None, 'первый кластер свободен в FAT'),
                (20, 1024, {20: 21, 21: 0}, 1, None, 'последний кластер свободен в FAT'),
                (20, 1536, {20: 21, 21: 0}, 1, None, 'ноль посреди цепочки'),
                (20, 1024, {20: 110, 110: eoc}, 1, 100, 'ссылка за областью данных'),
                (20, 1024, {20: 0x0FFFFFF7}, 1, None, 'плохой кластер'),
                (20, 8193, {20: 21, 21: eoc}, 8, None, 'SPC=8, нужно три, есть два'),
                (20, 0xFFFFFFFF, {20: eoc}, 64, None, 'около 4 ГиБ: сумма не переполняет счёт')):
            with self.subTest(why=why):
                self.assertFalse(self.check(first, size, links, spc, limit), why)

    def test_root_cluster_is_not_file_data(self):
        # Codex R28-01: запись файла на кластере корня (2) проходила проверку —
        # F5 копировал сектор корня. Корень в цепочке файла — порча.
        eoc = 0x0FFFFFFF
        for first, size, links, why in (
                (DIR_CLUSTER, 512, {}, 'первый кластер — корень'),
                (20, 1024, {20: DIR_CLUSTER}, 'ссылка на корень'),
                (20, 512, {20: DIR_CLUSTER}, 'за последним нужным — корень'),
                (20, 512, {20: eoc}, 'исправный рядом (контроль)')):
            with self.subTest(why=why):
                self.assertEqual(self.check(first, size, links), why.endswith('(контроль)'), why)

    def test_long_chains_in_portions(self):
        # Codex R28-02: предобход шёл одним вызовом шлюза, то есть при
        # выключенных прерываниях: файл в гигабайт при SPC=8 — десятки секунд.
        # Теперь, пока остаток кратен 1024 и не 0, — возврат порции.
        rng = random.Random(28)
        for count, shuffle, why in ((1024, False, 'ровно 1024 — без порций'),
                                    (1025, False, 'порция после первого кластера'),
                                    (2048, False, 'две порции'),
                                    (2600, False, 'три порции'),
                                    (2100, True, 'цепочка вразброс')):
            with self.subTest(why=why):
                volume = Volume(spc=1, fat_sectors=24)          # 3072 кластера
                chain = list(range(20, 20 + count))
                if shuffle:
                    rng.shuffle(chain)
                volume.make_chain(chain)
                ok, pauses = self.portions(volume, chain[0], count * 512)
                self.assertTrue(ok, why)
                self.assertEqual(pauses, (count - 1) // 1024, why)

    def test_broken_link_in_a_later_portion(self):
        # Порча в поздней порции ловится так же; число порций до неё — по
        # модели: пауза после k-го кластера, если остаток count−k кратен 1024.
        count = 2100
        for broken in (5, 1076, 1500, 2098):
            with self.subTest(broken=broken):
                volume = Volume(spc=1, fat_sectors=24)
                chain = list(range(20, 20 + count))
                random.Random(broken).shuffle(chain)
                volume.make_chain(chain)
                volume.set_fat(chain[broken], 0)             # кластер помечен свободным
                ok, pauses = self.portions(volume, chain[0], count * 512)
                self.assertFalse(ok)
                expected = sum(1 for k in range(1, min(broken + 2, count)) if (count - k) % 1024 == 0)
                self.assertEqual(pauses, expected)

    def test_sector_is_read_again_after_a_portion(self):
        # Между порциями SECBU мог смениться: продолжение читает сектор FAT
        # заново, а не верит кэшу обхода.
        volume = Volume(spc=1, fat_sectors=24)
        chain = list(range(20, 20 + 2600))
        volume.make_chain(chain)
        secbu = volume.core('SECBU')

        def spoil():
            volume.mem[secbu:secbu + 512] = bytes(512)       # одни «свободные»
        ok, pauses = self.portions(volume, 20, 2600 * 512, between=spoil)
        self.assertEqual((ok, pauses), (True, 2))

    def test_copy_source_through_the_real_loop(self):
        # Настоящие WCINI.CP_SOURCE → WCFX.FC_LOOP → шлюз → FILE_CHAIN. Внутри
        # шлюза прерывания выключены (CURIT видит IFF1=0), между порциями
        # включены: EI перед HALT, шлюз вернул IFF. GFILE — один раз в конце;
        # порча в поздней порции — одно сообщение UNKNOWN ERROR!! и NZ.
        for broken in (None, 1500):
            with self.subTest(broken=broken):
                volume = Volume(spc=1, fat_sectors=24)
                chain = list(range(20, 20 + 2600))
                volume.make_chain(chain)
                if broken is not None:
                    volume.set_fat(chain[broken], 0)
                cpu, events = volume.cpu, []

                def iff():
                    return bytes(cpu._Z80State__iff1)[0]

                def halt():
                    events.append(('HALT', iff()))
                    cpu.pc += 1                               # кадр IM2 прошёл

                def gfile():
                    events.append(('GFILE', int.from_bytes(volume.mem[0x7F30:0x7F34], 'little')))
                    volume._ret()

                def err0():
                    events.append(('ERR0', cpu.hl))
                    volume._ret()

                reads = []
                hooks = {volume.sym['WCFX.FC_WAIT'] + 1: halt, volume.sym['WCFX.GFILE']: gfile,
                         volume.sym['WCFX.ERR0']: err0}
                for address, handler in hooks.items():
                    volume.handlers[address] = handler
                    cpu.set_breakpoint(address)
                rddse = volume.handlers[volume.core('RDDSE')]

                def read_with_iff():
                    reads.append(iff())
                    rddse()
                volume.handlers[volume.core('RDDSE')] = read_with_iff
                volume.mem[0x7F30:0x7F34] = (20).to_bytes(4, 'little')
                lobu = volume.sym['WCINI.LOBU']
                volume.mem[lobu + 1:lobu + 5] = (2600 * 512).to_bytes(4, 'little')
                source = volume.sym['WCINI.CP_SOURCE']
                # «COPYFD»: EI (как в интерфейсе), CALL CP_SOURCE, за ним XOR A
                volume.mem[self.STUB:self.STUB + 6] = bytes(
                    [0xFB, 0xCD, source & 0xFF, source >> 8, 0xAF, 0xC9])
                a, f, _, _ = volume.call(self.STUB, budget=100000)
                self.assertEqual(cpu.sp, 0x5F00 + 2, 'стек')
                self.assertTrue(reads and not any(reads), 'чтение FAT при включённых прерываниях')
                if broken is None:
                    self.assertEqual(events, [('HALT', 1), ('HALT', 1), ('GFILE', 20)])
                    self.assertTrue(f & Z, 'COPYFD продолжился')
                else:                                        # порча — после первой порции
                    self.assertEqual(events, [('HALT', 1), ('ERR0', volume.sym['TER2X'])])
                    self.assertFalse(f & Z, 'F5 файла останавливается')


class AllocationInterrupts(unittest.TestCase):
    """MKSG файла — вне шлюза расширения (Codex R28-02, 2026-09-27): внутри
    ALLOCATE_FILE выделение шло при выключенных прерываниях (~4900 тактов на
    кластер — у файла в гигабайт минута и дольше). Теперь MKFILE зовёт MKSG
    сам: шаг MKSG на каждый кластер (PREPFC) идёт при прерываниях
    вызывающего, в DI — только вложенные вызовы шлюза."""

    def test_mkfile_allocates_with_interrupts(self):
        volume = Volume(spc=1, fat_sectors=24)
        cpu, states = volume.cpu, []
        prepfc = volume.core('PREPFC')                  # только наблюдение
        volume.handlers[prepfc] = lambda: states.append(bytes(cpu._Z80State__iff1)[0])
        cpu.set_breakpoint(prepfc)
        stub = 0x7D00                                   # EI, CALL MKFILE, RET
        data = bytes([0]) + (2600 * 512).to_bytes(4, 'little') + b'big.bin\0'
        volume.mem[0x7E80:0x7E80 + len(data)] = data
        volume.mem[stub:stub + 5] = bytes([0xFB, 0xCD, 0x39, 0x40, 0xC9])
        a, f, _, _ = volume.call(stub, hl=0x7E80, budget=100000)
        self.assertTrue(f & Z, f'MKFILE: A={a}')
        self.assertEqual(len(volume.chain(volume.find('big.bin'))), 2600)
        self.assertEqual(states, [1] * 2600, 'MKSG шёл при выключенных прерываниях')


class ScanOutsideTheGate(unittest.TestCase):
    """Поиск свободного кластера из расширения (Codex R29-01, 2026-09-27):
    MKDIR, APPEND и рост каталога звали MKSG и SRHFCL изнутри шлюза — весь
    просмотр FAT шёл при выключенных прерываниях и со страницей #E8 в окне
    #C000. Теперь — через резидентный блок в странице ядра (CORE_MKSG,
    CORE_SRHFCL): на время просмотра — страница и прерывания вызывающего,
    после — снова #E8 и DI. Порт #13AF моделируется: чтение отдаёт
    включённую страницу. Просмотр — точка WDOS.FC на каждой записи FAT;
    кластеры 3..599 заняты, просмотр идёт через несколько секторов FAT."""

    OUTER, STUB, USED = 0x33, 0x7D00, 600

    def volume(self):
        volume = Volume(spc=1, fat_sectors=24)
        volume.make_chain(list(range(3, self.USED)))
        cpu, state = volume.cpu, {'page': self.OUTER, 'writes': [], 'scans': []}

        def out(port, value):
            if port == 0x13AF:
                state['page'] = value
                state['writes'].append(value)

        cpu.set_output_callback(out)
        cpu.set_input_callback(lambda port: state['page'] if port == 0x13AF else 0xFF)
        fc = volume.core('FC')                           # только наблюдение
        volume.handlers[fc] = lambda: state['scans'].append(
            (bytes(cpu._Z80State__iff1)[0], state['page']))
        cpu.set_breakpoint(fc)
        return volume, state

    def run_stub(self, volume, entry, ei, **registers):
        """EI или DI, CALL entry, RET — как вызывающий с прерываниями и без."""
        volume.mem[self.STUB:self.STUB + 5] = bytes([0xFB if ei else 0xF3, 0xCD,
                                                     entry & 0xFF, entry >> 8, 0xC9])
        return volume.call(self.STUB, budget=100000, **registers)

    def check(self, volume, state, ei):
        iff = 1 if ei else 0
        scans = state['scans']
        self.assertGreater(len(scans), self.USED - 3, 'просмотр не прошёл занятые кластеры')
        self.assertEqual({page for _, page in scans}, {self.OUTER},
                         'во время просмотра в окне #C000 не страница вызывающего')
        self.assertEqual({flag for flag, _ in scans}, {iff},
                         'прерывания во время просмотра — не как у вызывающего')
        self.assertIn(0xE8, state['writes'], 'шлюз расширения не включался')
        self.assertEqual(state['page'], self.OUTER, 'страница вызывающего не возвращена')
        self.assertEqual(bytes(volume.cpu._Z80State__iff1)[0], iff, 'IFF вызывающего не возвращён')

    def test_mkdir(self):
        for ei in (True, False):
            with self.subTest(ei=ei):
                volume, state = self.volume()
                volume.mem[0x7E00:0x7E04] = b'new\0'
                volume.mem[volume.core('ENTRY') + 11] = 0x10
                a, f, _, _ = self.run_stub(volume, MKDIR, ei, hl=0x7E00)
                self.assertTrue(f & Z, f'MKDIR: A={a}')
                (entry,) = [e for e in volume.entries() if same_name(e[0], 'new')]
                self.assertEqual(entry[1], self.USED, 'каталог — на первом свободном кластере')
                self.check(volume, state, ei)

    def test_append(self):
        for ei in (True, False):
            with self.subTest(ei=ei):
                volume, state = self.volume()
                self.assertEqual(volume.mkfile('a.bin', 0), (0, True))
                self.assertIsNotNone(volume.find('a.bin'))
                state['scans'].clear()
                state['writes'].clear()
                data = bytes(range(256)) * 12                 # 3072 байта — 6 кластеров
                volume.mem[0x8000:0x8000 + len(data)] = data
                a, f, _, _ = self.run_stub(volume, 0x4027, ei, hl=0x8000, bc=len(data))
                self.assertEqual(a, 0, 'APPEND не удался')
                (entry,) = [e for e in volume.entries() if same_name(e[0], 'a.bin')]
                self.assertEqual(volume.read_file(entry[1], len(data)), data)
                self.check(volume, state, ei)

    def test_directory_growth(self):
        for ei in (True, False):
            with self.subTest(ei=ei):
                volume, state = self.volume()
                for index in range(16):                       # корень — один сектор, полон
                    self.assertEqual(volume.mkfile(f'f{index:02}', 0), (0, True))
                state['scans'].clear()
                state['writes'].clear()
                data = bytes([0]) + (0).to_bytes(4, 'little') + b'new.bin\0'
                volume.mem[0x7E80:0x7E80 + len(data)] = data
                a, f, _, _ = self.run_stub(volume, 0x4039, ei, hl=0x7E80)
                self.assertTrue(f & Z, f'MKFILE: A={a}')
                self.assertEqual(volume.chain(DIR_CLUSTER), [DIR_CLUSTER, self.USED], 'каталог не продлён')
                self.assertIn('new.bin', names(volume))
                self.check(volume, state, ei)


class RootCluster(unittest.TestCase):
    """Запись файла на кластере корня (Codex R28-01, 2026-09-27): F8 отдавал
    её цепочку DLSG, и тот освобождал FAT[2] — корень пропадал со всеми
    именами. Теперь кластер корня (BROOTC) для DLSG — недопустимая ссылка
    (ID_CLASSIFY_DATA): освобождённое до него записано, корень цел."""

    def test_f8_keeps_the_root(self):
        volume = Volume(spc=1, fat_sectors=4)
        for name in ('keep.bin', 'last.bin'):
            self.assertEqual(volume.mkfile(name, 512), (0, True))
        lba = volume.cluster_lba(DIR_CLUSTER)
        sector = bytearray(volume.read_sector(lba))
        at = sector.find(b'LAST    BIN')
        sector[at + 26:at + 28] = DIR_CLUSTER.to_bytes(2, 'little')
        sector[at + 20:at + 22] = bytes(2)
        volume.sectors[lba] = bytes(sector)
        self.assertEqual(volume.delete('last.bin'), (0, True), 'F8 не сообщил об ошибке')
        self.assertEqual(volume.fat(DIR_CLUSTER), 0x0FFFFFFF, 'корень освобождён')
        self.assertIsNotNone(volume.find('keep.bin'), 'имена корня пропали')

    def test_dlsg_stops_before_the_root(self):
        for chain, why in (([DIR_CLUSTER], 'первый кластер — корень'),
                           ([20, 21, DIR_CLUSTER], 'цепочка заходит в корень')):
            with self.subTest(why=why):
                volume = Volume(spc=1, fat_sectors=4)
                for current, following in zip(chain, chain[1:]):
                    volume.set_fat(current, following)
                slot = 0x7E00
                volume.mem[slot:slot + 4] = chain[0].to_bytes(4, 'little')
                volume.mem[volume.core('ABT')] = 0
                volume.call(volume.core('DLSG'), hl=slot)
                self.assertEqual(volume.fat(DIR_CLUSTER), 0x0FFFFFFF, 'корень освобождён')
                self.assertEqual([volume.fat(c) for c in chain[:-1]], [0] * (len(chain) - 1))
                self.assertEqual(volume.mem[volume.core('ABT')], 0xFE)


def gate_stub(volume, name, address=0x7D00):
    """CALL EXTENSION_GATE, DB ID_name, RET — вызов функции расширения, как из
    ядра или WC."""
    gate = volume.core('EXTENSION_GATE').to_bytes(2, 'little')
    ident = volume.sym['WDOS_EXT.ID_' + name]
    volume.mem[address:address + 5] = bytes([0xCD]) + gate + bytes([ident, 0xC9])
    return address


class RootChain(unittest.TestCase):
    """Вся цепочка корня (Codex R27-04, частичная защита, 2026-09-27). R28-01
    закрыл только первый кластер корня (BROOTC): у корня из нескольких
    кластеров запись файла на втором или цепочка файла, зашедшая в корень,
    давали F8 освободить хвост корня — его имена терялись, кластеры уходили
    новым файлам; подкаталог с хвостом в корне вёл F8 дерева по именам корня,
    F5 копировал секторы корня. Теперь таблица кластеров корня (ROOT_BUILD)
    строится в начале DLSG, FILE_CHAIN и DIR_CHAIN подкаталога. Корень здесь
    — 2 → 30 → 31."""

    ROOT = [DIR_CLUSTER, 30, 31]
    EOC = 0x0FFFFFFF

    def volume(self, root=None, fat_sectors=4):
        volume = Volume(spc=1, fat_sectors=fat_sectors)
        root = root or self.ROOT
        volume.make_chain(root)
        for cluster in root[1:]:
            volume.sectors[volume.cluster_lba(cluster)] = bytes(512)
        return volume

    def dlsg(self, volume, first):
        slot = 0x7E00
        volume.mem[slot:slot + 4] = first.to_bytes(4, 'little')
        volume.mem[volume.core('ABT')] = 0
        volume.call(volume.core('DLSG'), hl=slot)
        return volume.mem[volume.core('ABT')]

    def test_dlsg_stops_at_any_root_cluster(self):
        for links, first, freed, why in (
                ({}, 30, [], 'первый кластер файла — второй кластер корня'),
                ({}, 31, [], 'последний кластер корня'),
                ({20: 21, 21: 31}, 20, [20, 21], 'цепочка файла уходит в хвост корня'),
                ({20: 30}, 20, [20], 'ссылка на второй кластер корня')):
            with self.subTest(why=why):
                volume = self.volume()
                for cluster, value in links.items():
                    volume.set_fat(cluster, value)
                self.assertEqual(self.dlsg(volume, first), 0xFE, 'DLSG не сообщил о порче')
                self.assertEqual(volume.chain(DIR_CLUSTER), self.ROOT, 'цепочка корня изменилась')
                self.assertEqual([volume.fat(c) for c in freed], [0] * len(freed))
        with self.subTest(why='контроль: цепочка вне корня освобождается'):
            volume = self.volume()
            volume.make_chain([20, 21, 22])
            self.assertEqual(self.dlsg(volume, 20), 0)
            self.assertEqual([volume.fat(c) for c in (20, 21, 22)], [0, 0, 0])
            self.assertEqual(volume.chain(DIR_CLUSTER), self.ROOT)

    def test_f8_keeps_the_root_tail(self):
        # Настоящий DELFL: записи файла на втором кластере корня — «UNKNOWN
        # ERROR!!» (A=0), запись снята, корень и соседи на месте.
        volume = self.volume()
        for name in ('keep.bin', 'last.bin'):
            self.assertEqual(volume.mkfile(name, 512), (0, True))
        lba = volume.cluster_lba(DIR_CLUSTER)
        sector = bytearray(volume.read_sector(lba))
        at = sector.find(b'LAST    BIN')
        sector[at + 26:at + 28] = (30).to_bytes(2, 'little')
        volume.sectors[lba] = bytes(sector)
        self.assertEqual(volume.delete('last.bin'), (0, True), 'F8 не сообщил об ошибке')
        self.assertEqual(volume.chain(DIR_CLUSTER), self.ROOT, 'хвост корня освобождён')
        self.assertIsNotNone(volume.find('keep.bin'))

    def test_unreadable_root_fat_frees_nothing(self):
        # Сектор FAT корня не читается — таблицы нет (ROOT_FAILED≠0): DLSG не
        # освобождает ничего, даже цепочку в другом секторе FAT.
        volume = self.volume()
        volume.make_chain([200, 201])                       # второй сектор FAT
        volume.fail_lbas = {volume.fat_lba(DIR_CLUSTER)}
        self.assertEqual(self.dlsg(volume, 200), 0xFE)
        volume.fail_lbas = set()
        self.assertEqual([volume.fat(200), volume.fat(201)], [201, self.EOC])

    def test_long_root(self):
        # Codex 33: корень длиннее прежних 128 кластеров терял хвост. Теперь в
        # таблице до ROOT_MAX=768 — корень FAT32 при кластере от 4 КиБ целиком.
        # Защищены и 129-й, и 768-й; за 768-м — не в таблице (docs/04).
        for length, target, protected in ((300, 290, True), (768, 767, True), (769, 768, False)):
            with self.subTest(length=length, target=target):
                root = [DIR_CLUSTER] + list(range(40, 40 + length - 1))
                volume = self.volume(root, fat_sectors=16)
                self.assertEqual(self.dlsg(volume, root[target]), 0xFE if protected else 0)
                if protected:
                    self.assertEqual(volume.chain(DIR_CLUSTER), root)

    def test_filter_neighbours_are_not_root(self):
        # Фильтр корня — по младшим 11 битам: кластер с теми же битами, но не из
        # корня (30+2048, 31+4096) освобождается, как обычный.
        volume = self.volume(fat_sectors=48)
        for cluster in (30 + 2048, 31 + 4096):
            with self.subTest(cluster=cluster):
                volume.set_fat(cluster, self.EOC)
                self.assertEqual(self.dlsg(volume, cluster), 0)
                self.assertEqual(volume.fat(cluster), 0)
        self.assertEqual(volume.chain(DIR_CLUSTER), self.ROOT)

    def file_chain(self, volume, first, size):
        stub = gate_stub(volume, 'FILE_CHAIN')
        volume.mem[0x7E00:0x7E04] = first.to_bytes(4, 'little')
        volume.mem[0x7E10:0x7E14] = size.to_bytes(4, 'little')
        a, f, _, _ = volume.call(stub, hl=0x7E00, de=0x7E10)
        while f & 1:                                        # порции
            a, f, _, _ = volume.call(stub, a=1)
        return bool(f & Z)

    def test_copy_source_through_the_root(self):
        for links, first, size, good, why in (
                ({}, 30, 512, False, 'первый кластер — второй кластер корня'),
                ({20: 31}, 20, 1024, False, 'цепочка источника заходит в корень'),
                ({20: 30}, 20, 512, False, 'за последним нужным — кластер корня'),
                ({20: 21, 21: self.EOC}, 20, 1024, True, 'контроль: цепочка вне корня')):
            with self.subTest(why=why):
                volume = self.volume()
                for cluster, value in links.items():
                    volume.set_fat(cluster, value)
                self.assertEqual(self.file_chain(volume, first, size), good, why)

    def test_subdirectory_tail_into_the_root(self):
        # Подкаталог 10 («.» и «..» верные), FAT[10] — хвост корня: вход F5/F8
        # дерева (TREE_CHILD) и сама проверка цепочки (DIR_CHAIN — её зовут
        # NXTINI, FNDSN, SVHDFL) отвергают его. Корень сам себе — не порча.
        from test_io_failures import dot_sector
        for tail, good in ((30, False), (31, False), (self.EOC, True), (11, True)):
            with self.subTest(tail=tail):
                volume = self.volume()
                volume.sectors[volume.cluster_lba(10)] = dot_sector(10, parent=0)
                volume.set_fat(10, tail)
                if tail == 11:
                    volume.set_fat(11, self.EOC)
                stub = gate_stub(volume, 'TREE_CHILD')
                _, f, _, _ = volume.call(stub, hl=10)
                self.assertEqual(bool(f & Z), good, 'TREE_CHILD')
                _, f, _, _ = volume.call(volume.extension('DIR_CHAIN'), hl=10)
                self.assertEqual(bool(f & Z), good, 'DIR_CHAIN')
        volume = self.volume()
        for first in (0, DIR_CLUSTER):
            _, f, _, _ = volume.call(volume.extension('DIR_CHAIN'), hl=first)
            self.assertTrue(f & Z, 'цепочка самого корня')


class SameDirectoryAlias(unittest.TestCase):
    """F8: отмеченный объект не делит кластеров с неотмеченной записью того же
    каталога (Codex R27-04, частичная защита, 2026-09-27; WCINI.DL_ALIAS →
    ID_ALIAS_RESET, ID_ALIAS_ADD, ID_ALIAS_SCAN). Пробы Codex: sibling_alias
    (TREE на первом кластере соседнего каталога OUTSIDE), file_alias_root
    (TREE на первом кластере файла KEEP.BIN), directory_tail_alias (цепочка
    TREE проходит через первый кластер OUTSIDE); и два файла на одной цепочке.
    Корень: TREE (10), KEEP.BIN (12), OUTSIDE (20), VICTIM.BIN (22), удалённая
    запись, LFN и метка тома с кластером 12 в полях (не записи — не в счёт)."""

    EOC = 0x0FFFFFFF
    PANEL_IX = 0x7EA0                                       # WINDOW — как у F8

    def volume(self, fat_sectors=4):
        from test_io_failures import dot_sector, record
        volume = Volume(spc=1, fat_sectors=fat_sectors)
        deleted = bytearray(record(b'GONE    BIN', 12, 0x20))
        deleted[0] = 0xE5
        lfn = bytearray(record(b'AB\0\0\0\0\0\0\0\0\0', 12, 0x0F))
        lfn[0] = 0x41
        records = [record(b'TREE       ', 10), record(b'KEEP    BIN', 12, 0x20),
                   record(b'OUTSIDE    ', 20), record(b'VICTIM  BIN', 22, 0x20),
                   bytes(deleted), bytes(lfn), record(b'LABEL      ', 12, 0x08)]
        volume.sectors[volume.cluster_lba(DIR_CLUSTER)] = b''.join(records).ljust(512, b'\0')
        for cluster in (10, 12, 20, 22):
            volume.set_fat(cluster, self.EOC)
        volume.sectors[volume.cluster_lba(10)] = dot_sector(10, parent=0)
        volume.sectors[volume.cluster_lba(20)] = dot_sector(20, parent=0)
        return volume

    def entry_cluster(self, volume, name, cluster, directory=DIR_CLUSTER):
        lba = volume.cluster_lba(directory)
        sector = bytearray(volume.read_sector(lba))
        at = sector.find(name)
        assert at >= 0 and at % 32 == 0, name
        sector[at + 20:at + 22] = (cluster >> 16).to_bytes(2, 'little')
        sector[at + 26:at + 28] = (cluster & 0xFFFF).to_bytes(2, 'little')
        volume.sectors[lba] = bytes(sector)

    def check(self, volume, marked, current=0):
        """Как WCINI.DL_ALIAS: RESET, ADD отмеченных (CF — SCAN, RESET и снова
        тот же), в конце SCAN; SCAN — порциями. Выход: (можно ли удалять,
        сколько раз таблица была полна, сколько было порций)."""
        lstcat = volume.core('LSTCAT')
        volume.mem[lstcat:lstcat + 4] = current.to_bytes(4, 'little')
        reset = gate_stub(volume, 'ALIAS_RESET', 0x7D00)
        add = gate_stub(volume, 'ALIAS_ADD', 0x7D08)
        scan = gate_stub(volume, 'ALIAS_SCAN', 0x7D10)
        state = {'full': 0, 'portions': 0}

        def call(address, **registers):
            # Шлюз возвращает вызывающему IX функции, а у DL_ALIAS IX — описатель
            # панели для GETen (стенд 2026-09-27: испорченный IX давал ложные
            # «отмеченные», ложную тревогу и зависание WC).
            volume.cpu.ix = self.PANEL_IX
            result = volume.call(address, budget=100000, **registers)
            self.assertEqual(volume.cpu.ix, self.PANEL_IX, 'IX вызывающего испорчен')
            return result

        def run_scan():
            a, f, _, _ = call(scan, a=0)
            while f & 1:
                self.assertEqual(a, 1)
                state['portions'] += 1
                a, f, _, _ = call(scan, a=1)
            return bool(f & Z)

        call(reset, a=0)
        index = 0
        while index < len(marked):
            cluster, directory = marked[index]
            a, f, _, _ = call(add, a=0 if directory else 0x20, hl=cluster & 0xFFFF, de=cluster >> 16)
            if f & 1:
                state['full'] += 1
                if not run_scan():
                    return False, state['full'], state['portions']
                call(reset, a=1)                            # хвост каталога продолжится
                continue
            if not f & Z:
                return False, state['full'], state['portions']
            index += 1
        return run_scan(), state['full'], state['portions']

    def test_codex_probes(self):
        for why, prepare, marked, good in (
                ('исправный том', None, [(10, True)], True),
                ('sibling_alias', lambda v: self.entry_cluster(v, b'TREE    ', 20), [(20, True)], False),
                ('file_alias_root', lambda v: self.entry_cluster(v, b'TREE    ', 12), [(12, True)], False),
                ('directory_tail_alias', lambda v: v.set_fat(10, 20), [(10, True)], False),
                # Codex R34-01: отмечены оба — всё равно отказ: первое удаление
                # освободило бы цепочку, и второй каталог остался бы записью на
                # свободном кластере.
                ('отмечены оба соседа', lambda v: self.entry_cluster(v, b'TREE    ', 20),
                 [(20, True), (20, True)], False),
                ('хвост через отмеченного соседа', lambda v: v.set_fat(10, 20),
                 [(10, True), (20, True)], False)):
            with self.subTest(why=why):
                volume = self.volume()
                if prepare:
                    prepare(volume)
                self.assertEqual(self.check(volume, marked)[0], good, why)

    def test_files_on_one_chain(self):
        for marked, good, why in (([(12, False)], False, 'отмечен один из двух'),
                                  ([(12, False), (12, False)], False, 'отмечены оба'),
                                  ([(22, False)], True, 'другой файл')):
            with self.subTest(why=why):
                volume = self.volume()
                self.entry_cluster(volume, b'VICTIM  ', 12)
                if why == 'другой файл':
                    self.entry_cluster(volume, b'VICTIM  ', 22)
                self.assertEqual(self.check(volume, marked)[0], good, why)

    def test_nothing_to_check(self):
        # Кластер 0 (пустой файл) и недопустимый кластер — пропуск; удалённая
        # запись, LFN и метка тома с кластером 12 — не записи каталога.
        volume = self.volume()
        self.assertTrue(self.check(volume, [(0, False), (1, False), (0x0FFFFFF7, False)])[0])
        self.assertTrue(self.check(volume, [])[0])
        volume = self.volume()
        self.entry_cluster(volume, b'KEEP    ', 30)
        self.assertTrue(self.check(volume, [(12, False)])[0], 'на 12 — только не-записи')

    def subdir(self, volume, tail):
        """Каталог панели S (11) в TREE (10): «.», «..», X (15) с FAT[15]=tail."""
        from test_io_failures import dot_sector, record
        sector = bytearray(dot_sector(11, parent=10))
        sector[64:96] = record(b'X          ', 15)
        volume.sectors[volume.cluster_lba(11)] = bytes(sector)
        volume.sectors[volume.cluster_lba(15)] = dot_sector(15, parent=11)
        volume.set_fat(11, self.EOC)
        volume.set_fat(15, tail)

    def test_tail_through_dot_entries(self):
        # Хвост отмеченного каталога через «.» (сам каталог панели) или «..»
        # (его родитель) — F8 освободил бы каталог панели или родителя.
        for tail, good, why in ((11, False, '«.»'), (10, False, '«..»'),
                                (self.EOC, True, 'контроль')):
            with self.subTest(why=why):
                volume = self.volume()
                self.subdir(volume, tail)
                self.assertEqual(self.check(volume, [(15, True)], current=11)[0], good, why)

    def big_directory(self, count):
        """Каталог панели 40.. (цепочка по 16 записей в кластере) из count
        файлов Fnnnn.BIN на кластерах 1000+n."""
        from test_io_failures import record
        volume = Volume(spc=1, fat_sectors=24)
        clusters = list(range(40, 40 + (count + 15) // 16))
        volume.make_chain(clusters)
        raw = b''.join(record(f'F{n:04}   BIN'.encode(), 1000 + n, 0x20) for n in range(count))
        raw = raw.ljust(len(clusters) * 512, b'\0')
        for index, cluster in enumerate(clusters):
            volume.sectors[volume.cluster_lba(cluster)] = raw[index * 512:(index + 1) * 512]
        return volume, clusters

    def test_many_marked_and_portions(self):
        # 600 отмеченных — таблица полна раз-другой (ALIAS_LOAD), проход
        # каталога в 38 секторов — порциями по 16. Псевдоним в последней записи
        # (неотмеченной) ловится, в какой бы заход таблицы он ни попал.
        volume, clusters = self.big_directory(601)
        marked = [(1000 + n, False) for n in range(600)]
        ok, full, portions = self.check(volume, marked, current=clusters[0])
        self.assertTrue(ok)
        self.assertGreaterEqual(full, 1)
        self.assertGreaterEqual(portions, 2 * (full + 1))
        for victim in (1000, 1599):
            with self.subTest(victim=victim):
                volume, clusters = self.big_directory(601)
                lba = volume.cluster_lba(clusters[-1])
                sector = bytearray(volume.read_sector(lba))
                at = 600 % 16 * 32
                sector[at + 26:at + 28] = victim.to_bytes(2, 'little')
                volume.sectors[lba] = bytes(sector)
                self.assertFalse(self.check(volume, marked, current=clusters[0])[0])

    def test_long_directory_tail(self):
        # Codex 33: хвост отмеченного каталога проверялся до 64-го кластера. Теперь
        # целиком: не влез в таблицу — проход, сброс и продолжение с того же места.
        # TREE (10) — цепочка 10, 100..100+n-2; первый кластер OUTSIDE (20) — на
        # позиции target цепочки.
        for length, target in ((70, 66), (300, 290), (600, 590), (600, None)):
            with self.subTest(length=length, target=target):
                volume = self.volume(fat_sectors=8)
                chain = [10] + list(range(100, 100 + length - 1))
                if target is not None:
                    chain[target] = 20
                    volume.set_fat(20, self.EOC)
                for current, following in zip(chain, chain[1:] + [self.EOC]):
                    if current != 20:
                        volume.set_fat(current, following)
                if target is not None:
                    volume.set_fat(20, chain[target + 1] if target + 1 < len(chain) else self.EOC)
                ok, full, _ = self.check(volume, [(10, True)])
                self.assertEqual(ok, target is None)
                if length > 300:
                    self.assertGreaterEqual(full, 1, 'хвост не уместился — продолжение')

    def test_marked_twins(self):
        # Codex 33: «ожидаемо» насыщалось на 255 — при 255 отмеченных на одном
        # кластере неотмеченная запись на нём проходила. Codex R34-01: две
        # записи на одной цепочке — порча, отказ, сколько бы их ни было
        # отмечено. Одна запись на кластере — контроль.
        from test_io_failures import record
        for marked, extra, good in ((1, 0, True), (2, 0, False), (1, 1, False), (254, 0, False),
                                    (255, 0, False), (255, 1, False)):
            with self.subTest(marked=marked, extra=extra):
                volume = Volume(spc=1, fat_sectors=4)
                count = marked + extra
                clusters = list(range(40, 40 + (count + 15) // 16))
                volume.make_chain(clusters)
                raw = b''.join(record(f'T{n:04}   BIN'.encode(), 12, 0x20) for n in range(count))
                raw = raw.ljust(len(clusters) * 512, b'\0')
                for index, cluster in enumerate(clusters):
                    volume.sectors[volume.cluster_lba(cluster)] = raw[index * 512:(index + 1) * 512]
                volume.set_fat(12, self.EOC)
                self.assertEqual(self.check(volume, [(12, False)] * marked, current=clusters[0])[0], good)

    def test_read_failures(self):
        volume = self.volume()
        volume.fail_lbas = {volume.cluster_lba(DIR_CLUSTER)}
        self.assertFalse(self.check(volume, [(22, False)])[0], 'каталог не читается')
        volume = self.volume()
        volume.fail_lbas = {volume.fat_lba(10)}
        self.assertFalse(self.check(volume, [(10, True)])[0], 'FAT хвоста каталога не читается')


class GateKeepsIX(unittest.TestCase):
    """Шлюз расширения возвращает вызывающему все регистры функции, IX тоже
    (GATE_FINISH). WC держит в IX описатель окна или панели: функция, которая
    портит IX, ломает вызывающего (стенд 2026-09-27: ALIAS_ADD оставлял в IX
    указатель слота — GETen брал его за панель, F8 зависал с порчей экрана).
    Функции расширения этой работы (2026-09-27) IX сохраняют."""

    SENTINEL = 0x7EA0

    def test_new_functions(self):
        from test_io_failures import dot_sector
        volume = Volume(spc=1, fat_sectors=4)
        volume.sectors[volume.cluster_lba(10)] = dot_sector(10, parent=0)
        volume.set_fat(10, 0x0FFFFFFF)
        volume.make_chain([20, 21])
        volume.mem[0x7E00:0x7E04] = (20).to_bytes(4, 'little')
        volume.mem[0x7E10:0x7E14] = (1024).to_bytes(4, 'little')
        for name, registers in (('ALIAS_RESET', {}), ('ALIAS_ADD', dict(a=0, hl=10)),
                                ('ALIAS_ADD', dict(a=0x20, hl=20)), ('ALIAS_SCAN', dict(a=0)),
                                ('TREE_CHILD', dict(hl=10)), ('FILE_CHAIN', dict(a=0, hl=0x7E00, de=0x7E10)),
                                ('CLASSIFY_DATA', dict(hl=20)), ('DIR_LIST_OPEN', {}),
                                ('DIR_STREAM_OPEN', {})):
            with self.subTest(name=name, registers=registers):
                stub = gate_stub(volume, name)
                volume.cpu.ix = self.SENTINEL
                volume.call(stub, budget=100000, **registers)
                self.assertEqual(volume.cpu.ix, self.SENTINEL)
        with self.subTest(name='DLSG (NOTE_FREED_CHAIN, CLASSIFY_DATA)'):
            volume.mem[0x7E00:0x7E04] = (20).to_bytes(4, 'little')
            volume.cpu.ix = self.SENTINEL
            volume.call(volume.core('DLSG'), hl=0x7E00)
            self.assertEqual(volume.cpu.ix, self.SENTINEL)


class DirectoryLimit(unittest.TestCase):
    """Каталог FAT32 — не больше 4096 секторов (65536 записей). Codex R27-01
    (2026-09-27): полный каталог этого размера SVHDFL продлевал ещё на кластер,
    MKFILE сообщал успех, а потом проверка цепочки (DIR_CHAIN) отвергала
    каталог целиком — ни список, ни поиск. Теперь предел — отказ создания
    (A=16), каталог цел; на кластер меньше — продление ровно до 4096."""

    SPC = 64                                                # 4096 секторов — 64 кластера

    def volume(self, clusters):
        volume = Volume(spc=self.SPC, fat_sectors=4)
        chain = list(range(DIR_CLUSTER, DIR_CLUSTER + clusters))
        volume.make_chain(chain)
        index = 0
        for cluster in chain:
            for sector in range(self.SPC):
                data = b''.join(
                    f'F{index + n:07X}'.encode().ljust(11, b' ')[:8] + b'BIN' + bytes([0x20]) + bytes(20)
                    for n in range(16))
                volume.sectors[volume.cluster_lba(cluster) + sector] = data
                index += 16
        return volume, chain

    def test_full_maximum_directory_is_not_extended(self):
        volume, chain = self.volume(64)
        self.assertEqual(volume.mkfile('new.bin', 0), (16, False))
        self.assertEqual(volume.chain(DIR_CLUSTER), chain, 'каталог продлён за 4096 секторов')
        a, f, _, _ = volume.call(0x404E, hl=volume.query('F0000000.BIN'), budget=4000000)
        self.assertFalse(f & Z, 'после отказа каталог не ищется')
        self.assertEqual(volume.mem[volume.core('ABT')], 0)

    def test_growth_up_to_the_limit(self):
        volume, chain = self.volume(63)
        self.assertEqual(volume.mkfile('new.bin', 0), (0, True))
        self.assertEqual(len(volume.chain(DIR_CLUSTER)), 64)
        a, f, _, _ = volume.call(0x404E, hl=volume.query('new.bin'), budget=4000000)
        self.assertFalse(f & Z, 'новая запись не находится')


class CyclicDirectory(unittest.TestCase):
    """Замкнутая цепочка каталога вне обхода дерева (Codex R26-02,
    2026-09-27): перечисление (панель, API 58), поиск и создание записи ходили
    по ней без конца — в секторе одни удалённые записи, нулевой нет. Теперь
    цепочка проверяется до чтения (DIR_CHAIN): отказ чтения, ABT=#FE, возврат.
    Вызов, не вернувшийся за бюджет эмулятора, — провал теста."""

    def volume(self, links, current):
        volume = Volume(spc=1, fat_sectors=4)
        for cluster, value in links.items():
            volume.set_fat(cluster, value)
            # 16 удалённых записей, нулевой нет: перечислять нечего, конца нет.
            volume.sectors[volume.cluster_lba(cluster)] = (b'\xE5' + b'X' * 31) * 16
        lstcat, cgfl = volume.core('LSTCAT'), volume.core('CGFL')
        volume.mem[lstcat:lstcat + 4] = current.to_bytes(4, 'little')
        volume.mem[cgfl:cgfl + 2] = bytes(2)
        return volume

    def cases(self):
        return (({10: 10}, 10, 'каталог на себя'), ({10: 11, 11: 10}, 10, 'через второй кластер'),
                ({2: 2}, 0, 'корень на себя'))

    def test_listing_ends(self):
        for links, current, why in self.cases():
            for entry in (0x405A, 0x4057):
                with self.subTest(why=why, entry=hex(entry)):
                    volume = self.volume(links, current)
                    _, f, _, _ = volume.call(entry, a=0, de=0x9000, budget=200000)
                    self.assertTrue(f & Z, 'перечисление не кончилось')
                    self.assertEqual(volume.mem[volume.core('ABT')], 0xFE)

    def test_search_and_create_end(self):
        for links, current, why in self.cases():
            with self.subTest(why=why, kind='поиск'):
                volume = self.volume(links, current)
                a, f, _, _ = volume.call(0x404E, hl=volume.query('nothing.txt'), budget=200000)
                self.assertTrue(f & Z, 'найдено несуществующее')
                self.assertEqual(volume.mem[volume.core('ABT')], 0xFE)
            with self.subTest(why=why, kind='создание'):
                volume = self.volume(links, current)
                a, done = volume.mkfile('new.bin', 0)
                self.assertEqual((a, done), (0xFF, False))


class VolumeLimit(unittest.TestCase):
    """Кластер за концом области данных тома (FAT_DATA_CLUSTER_LIMIT) — порча
    ссылки для GIPAG, переходов потока и DLSG (Codex R25-03, 2026-09-27):
    последний сектор FAT держит слоты за концом данных, и испорченная цепочка
    вела чтение и запись за границу тома. Граница не задана — как прежде."""

    def volume(self, limit):
        volume = Volume(spc=1, fat_sectors=4)                # FAT на 512 слотов
        address = volume.extension('FAT_DATA_CLUSTER_LIMIT')
        volume.mem[address:address + 4] = limit.to_bytes(4, 'little')
        return volume

    def test_gipag(self):
        for cluster, limit, ok in ((50, 100, True), (99, 100, True), (100, 100, False),
                                   (110, 100, False), (110, 0, True), (110, 2, True)):
            with self.subTest(cluster=cluster, limit=limit):
                volume = self.volume(limit)
                volume.mem[volume.core('ABT')] = 0
                a, f = volume.open(cluster)
                self.assertEqual(bool(f & Z), ok)
                self.assertEqual(volume.mem[volume.core('ABT')], 0 if ok else 0xFE)

    def test_stream_and_dlsg_stop_at_the_limit(self):
        volume = self.volume(100)
        volume.make_chain([20, 21])
        volume.set_fat(21, 110)                              # хвост — за область данных
        volume.set_fat(110, 0x0FFFFFFF)
        self.assertTrue(volume.open(20)[1] & Z)
        a, carry, _ = volume.load(3)
        self.assertEqual((a, carry), (0xFF, 1), 'переход за границу тома не отвергнут')
        self.assertNotIn(volume.cluster_lba(110), [lba for kind, lba in volume.log if kind == 'R'])
        # DLSG освобождает цепочку до плохой ссылки, за границу не идёт.
        slot = 0x7E00
        volume.mem[slot:slot + 4] = (20).to_bytes(4, 'little')
        volume.call(volume.core('DLSG'), hl=slot)
        self.assertEqual((volume.fat(20), volume.fat(21)), (0, 0))
        self.assertEqual(volume.fat(110), 0x0FFFFFFF, 'DLSG прошёл за границу тома')


class DirectoryListEnd(unittest.TestCase):
    """Конец перечисления NXTETY2/NXTETY (2026-09-26). Каталог читается в
    буфер NXTBU по 8 КиБ, дальше — по 4 КиБ (NXMR). У полного каталога
    (записи до конца цепочки, нулевой нет) размером 8 КиБ, 12 КиБ и т. д.
    ноль за последней записью ложится за NXTBE, и перечисление доходит до
    NXMR при EOC. С 2026-07-16 NXMR отдавал там NZ без новой записи — каталог
    перечислялся без конца (панель набирала записи до переполнения, F5 по
    дереву повторял последний файл). Отказ чтения — тоже конец (Z), признак —
    ABT≠0: по нему обход дерева F5/F8 отличает отказ (Codex R23-01)."""

    OUT = 0x9000

    @staticmethod
    def record(index):
        data = bytearray(32)
        data[:11] = f'F{index:04}   BIN'.encode()
        data[11] = 0x20
        return bytes(data)

    def volume(self, spc, clusters, entries):
        volume = Volume(spc=spc, fat_sectors=4)
        volume.make_chain(list(range(DIR_CLUSTER, DIR_CLUSTER + clusters)))
        size = clusters * spc * 512
        raw = b''.join(self.record(i) for i in range(entries)).ljust(size, b'\0')
        for n in range(clusters * spc):
            volume.sectors[volume.cluster_lba(DIR_CLUSTER) + n] = raw[n * 512:(n + 1) * 512]
        return volume

    def listed(self, volume, entry=0x405A):
        """Сколько записей до Z (не больше 2000) и ABT в этот момент."""
        for count in range(2000):
            _, f, _, _ = volume.call(entry, a=0, de=self.OUT)
            if f & Z:
                return count, volume.mem[volume.core('ABT')]
        return 2000, None

    def test_full_directory_ends(self):
        for spc, clusters in ((1, 16), (8, 2), (8, 3), (16, 1), (1, 15), (4, 7)):
            capacity = spc * clusters * 16
            for entries in (capacity, capacity - 1):
                with self.subTest(spc=spc, clusters=clusters, entries=entries):
                    self.assertEqual(self.listed(self.volume(spc, clusters, entries)), (entries, 0))
        # NXTETY (панель) — тот же NXMR.
        self.assertEqual(self.listed(self.volume(8, 2, 256), 0x4057), (256, 0))

    def test_read_failure_ends_with_abt(self):
        # Отказ первого сектора (NXTINI), середины первой загрузки и первого
        # сектора дочитывания (NXMR): записи до отказа, затем Z и ABT≠0.
        for spc, clusters, fail in ((8, 3, 0), (1, 16, 5), (8, 3, 16), (1, 24, 16)):
            with self.subTest(spc=spc, clusters=clusters, fail=fail):
                volume = self.volume(spc, clusters, spc * clusters * 16)
                volume.fail_lbas = {volume.cluster_lba(DIR_CLUSTER) + fail}
                count, abt = self.listed(volume)
                self.assertEqual(count, fail * 16)
                self.assertTrue(abt, 'отказ чтения не отличить от конца каталога')

    def test_bad_first_cluster_is_a_failure(self):
        # Codex R24-01 (2026-09-27): у каталога с недопустимым первым кластером
        # GIPAG ставит ABT=#FE, а NXTINI всё равно звал LOAD512 — тот обнулял
        # ABT, и выходил Z без признака, как у пустого каталога (F5 давал
        # пустую копию без сообщения). Теперь NXTINI не читает: Z и ABT=#FE.
        # Первый кластер — маркер конца цепочки: у каталога нет ни кластера —
        # с проверкой цепочки (DIR_CHAIN, Codex R26-02) тоже порча, ABT=#FE.
        for first, abt in ((1, 0xFE), (0x0FFFFFF7, 0xFE), (0x0FFFFFF0, 0xFE),
                           (0x0FFFFFFF, 0xFE)):
            for entry in (0x405A, 0x4057):
                with self.subTest(first=hex(first), entry=hex(entry)):
                    volume = self.volume(1, 1, 5)
                    lstcat, cgfl = volume.core('LSTCAT'), volume.core('CGFL')
                    volume.mem[lstcat:lstcat + 4] = first.to_bytes(4, 'little')
                    volume.mem[cgfl:cgfl + 2] = bytes(2)            # новое перечисление
                    self.assertEqual(self.listed(volume, entry), (0, abt))


if __name__ == '__main__':
    unittest.main(verbosity=2)
