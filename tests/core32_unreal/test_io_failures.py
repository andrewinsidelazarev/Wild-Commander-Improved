"""Сбои ввода-вывода посреди файловых операций ядра (аудит Codex 2026-09-25).

Исполняется собранное ядро (exe/boot.$C) с расширением; дисковые процедуры
подменены точками останова и отвечают так, как задаёт тест. Каждый случай
падал на коде до исправления.

* BUtoFAT: CURIT не прочитал сектор FAT (CF=1) — прежде LDIR правил
  устаревший SECBU и SAVE_FAT_SECTOR писал его поверх другого сектора FAT.
* DELFL: запись удалена, а цепочку освободить не удалось — прежде «успех».
* F5 (CopyLoop): отказ LOAD512/SAVE512 прерывает копирование.
* MKDIR: тело каталога пишется до записи в родителе.
* Глубина обхода F5/F8 и F5 каталога в себя (DIRCOPY_INSIDE).
* Соседняя панель после F8 и кода плагина 3 (OTHER_REFRESH, DIR_ALIVE).
"""
import unittest

import core32_machine as p
import test_fat_allocator_hint as h

B = p.BOOT
Z, C = 0x40, 0x01


def sym(name):
    return B['WDOS.' + name]


class BuToFat(unittest.TestCase):

    def test_failed_curit_writes_no_fat(self):
        cpu = p.base()
        m = cpu.memory
        h.put32(m, sym('GENBU'), 10)                      # цепочка из одного кластера
        h.put32(m, sym('GENBU') + 4, 0x0FFFFFFF)
        m[sym('SECBU'):sym('SECBU') + 512] = bytes([0xAA]) * 512  # устаревший сектор
        saves = []

        def failed_curit(cpu):
            cpu.hl = sym('SECBU') + 40
            cpu.f = C                                      # сектор FAT не прочитан
            m[sym('ABT')] = 1
            p.ret(cpu)

        def fat_save(cpu):
            saves.append(cpu.pc)
            cpu.a, cpu.f = 0, Z
            p.ret(cpu)

        # Прежний путь после LDIR идёт в шлюз (IS_EOC_BEFORE_HL), затем в
        # SAVE_FAT_SECTOR: остановка на шлюзе и есть провал.
        stop = p.run(cpu, sym('BUtoFAT'), {sym('CURIT'): failed_curit, sym('LSTSR'): fat_save,
                                            sym('GGC'): fat_save}, stops=(sym('EXTENSION_GATE'),))
        self.assertEqual(stop, p.STOP, 'после отказа CURIT BUtoFAT пошёл дальше, к записи FAT')
        self.assertEqual(saves, [], 'после отказа CURIT BUtoFAT записал сектор FAT')
        self.assertTrue(cpu.f & C, 'BUtoFAT не сообщил о завершении с ошибкой (CF)')
        self.assertFalse(cpu.f & Z, 'ошибка BUtoFAT выглядит как успех (Z)')
        self.assertEqual(bytes(m[sym('SECBU'):sym('SECBU') + 512]), bytes([0xAA]) * 512,
                         'устаревший SECBU изменён')


class DelFl(unittest.TestCase):

    def delete(self, free_ok):
        cpu = p.base()

        def delen(cpu):                                    # запись помечена #E5
            cpu.a, cpu.f = 1, 0
            p.ret(cpu)

        def dlsg(cpu):
            if free_ok:
                cpu.a, cpu.f = 0, Z
            else:
                cpu.memory[sym('ABT')] = 1
                cpu.a, cpu.f = 1, C                        # отказ записи FAT
            p.ret(cpu)

        p.run(cpu, sym('DELFL'), {sym('DELEN'): delen, sym('DLSG'): dlsg})
        return cpu

    def test_success(self):
        cpu = self.delete(True)
        self.assertFalse(cpu.f & Z)
        self.assertEqual(cpu.a, 1)

    def test_chain_not_freed_is_reported(self):
        cpu = self.delete(False)
        self.assertTrue(cpu.f & Z, 'DELFL скрыл отказ освобождения цепочки')


class CopyLoop(unittest.TestCase):
    """F5 COPYF, цикл SVNG: отказ LOAD512/SAVE512 прерывает копирование."""

    def copy(self, fail=None):
        cpu = p.base()
        m = cpu.memory
        for index, name in enumerate(('WINDOW', 'WINDO2')):
            window = B[name]
            m[window + 0x1B], m[window + 0x1C], m[window + 0x1D] = index, 1, 0
        cpu.ix = B['WINDO2']                               # SVNG — в контексте назначения
        lobu = 0xB000
        m[lobu] = 0
        h.put32(m, lobu + 1, 512)                          # остаток — один сектор
        m[lobu + 5:lobu + 11] = b'X.BIN\0'
        events = []

        def load(cpu):
            events.append('LOAD')
            cpu.f = C if fail == 'read' else 0
            p.ret(cpu)

        def save(cpu):
            events.append('SAVE')
            cpu.f = C if fail == 'write' else 0
            p.ret(cpu)

        def delfl(cpu):
            end = cpu.hl + 1
            while m[end]:
                end += 1
            events.append(('DELFL', m[cpu.hl], bytes(m[cpu.hl + 1:end])))
            cpu.a, cpu.f = 1, 0
            p.ret(cpu)

        def note(label):
            def hook(cpu):
                events.append(label)
                p.ret(cpu)
            return hook

        # Обёртки COPY_LOAD/COPY_SAVE (ядро) зовут LOAD512/SAVE512 ядра прямо.
        p.run(cpu, B['WCFX.SVNG'], {0x4015: load, 0x4018: save, 0x403F: delfl,
                                    sym('LOAD512'): load, sym('SAVE512'): save,
                                    B['WCFX.PBPR']: note('PBPR'), 0x7ACE: note('RRESB'),
                                    B['WCINI.CP_DONE']: note('CPDONE'),
                                    B['WCFX.ERR0']: note('ERR0')})
        # Полоса окна хода (PBPR, CP_DONE) и окна — не предмет этой проверки.
        return cpu, [e for e in events if e not in ('PBPR', 'RRESB', 'CPDONE')]

    def test_read_failure_writes_nothing_and_drops_the_copy(self):
        cpu, events = self.copy('read')
        self.assertEqual(events, ['LOAD', ('DELFL', 0, b'X.BIN'), 'ERR0'])
        self.assertFalse(cpu.f & Z, 'после отказа чтения F5 сообщил успех')

    def test_write_failure_drops_the_copy(self):
        cpu, events = self.copy('write')
        self.assertEqual(events, ['LOAD', 'SAVE', ('DELFL', 0, b'X.BIN'), 'ERR0'])
        self.assertFalse(cpu.f & Z, 'после отказа записи F5 сообщил успех')

    def test_success(self):
        cpu, events = self.copy()
        self.assertEqual(events, ['LOAD', 'SAVE'])
        self.assertTrue(cpu.f & Z)


class MkDir(unittest.TestCase):
    """MKDIR (расширение): тело каталога пишется до записи в родителе.

    Прежде SVHDFL публиковал каталог первым: отказ записи его первого сектора
    оставлял в родителе каталог с мусором свободного кластера.
    """

    def mkdir(self, fail=None, spc=1, media=False, search=None):
        """fail — 'body' или 'entry'; media — отказ записи в родителе от носителя
        (ABT≠0), а не по имени; search — ответ повторного поиска имени:
        'none' — нет, 'ours'/'foreign' — есть с нашим/чужим кластером, 'error'."""
        cpu = p.base()
        m = cpu.memory
        m[sym('BSECPC')] = spc
        m[sym('ABT')] = 0
        h.put32(m, sym('FCTS'), 777)
        events = []

        def step(label, ok=True, abt=0):
            def hook(cpu):
                events.append(label)
                m[sym('ABT')] = 0 if ok else abt
                cpu.a, cpu.f = (0, Z) if ok else (1, 0)
                p.ret(cpu)
            return hook

        def gipag(cpu):
            events.append('GIPAG')
            h.put32(m, sym('CUHL'), 777)
            cpu.f = Z
            p.ret(cpu)

        def delcha(cpu):
            events.append('DELCHA')
            self.assertEqual(h.get32(m, sym('FCTS')), 777, 'DELCHA освобождает не ту цепочку')
            p.ret(cpu)                                     # код ошибки прежний

        def srhdrn(cpu):
            events.append('SRHDRN')
            self.assertEqual(bytes(m[cpu.hl:cpu.hl + 5]), bytes([0x10]) + b'new\0',
                             'повторный поиск не по нормализованному запросу NXTBU')
            cluster = {'ours': 777, 'foreign': 778}.get(search, 0)
            cpu.hl, cpu.de = cluster & 0xFFFF, cluster >> 16
            cpu.a, cpu.f = {'none': (0, Z), 'error': (0xFF, Z | C)}.get(search, (1, 0))
            p.ret(cpu)

        entry_step = step('SVHDFL', fail != 'entry', abt=1 if media else 0)

        def svhdfl(cpu):
            nxtbu = sym('NXTBU')                           # как ENTREZ: [тип, имя, 0]
            m[nxtbu:nxtbu + 5] = bytes([0x10]) + b'new\0'
            entry_step(cpu)

        p.run(cpu, p.EXT['WDOS_EXT.MKDIR_ENTRY'], {
            sym('MKSG'): step('MKSG'), sym('GIPAG'): gipag,
            sym('SAFE_SDDSE'): step('BODY', fail != 'body', abt=1),
            sym('SVHDFL'): svhdfl,
            sym('SRHDRN'): srhdrn, sym('DELCHA'): delcha})
        lobu = sym('LOBU')
        return cpu, events, bytes(m[lobu:lobu + 64])

    def test_body_before_entry(self):
        cpu, events, body = self.mkdir()
        self.assertEqual(events, ['MKSG', 'GIPAG', 'BODY', 'SVHDFL'])
        self.assertTrue(cpu.f & Z)
        self.assertEqual(body[0:11], b'.          ')
        self.assertEqual(body[32:43], b'..         ')

    def test_failed_body_publishes_nothing(self):
        cpu, events, _ = self.mkdir('body')
        self.assertEqual(events, ['MKSG', 'GIPAG', 'BODY', 'DELCHA'],
                         'каталог опубликован, хотя его тело не записано')
        self.assertFalse(cpu.f & Z)
        self.assertEqual(cpu.a, 0xFF, 'отказ носителя назван ошибкой имени')

    def test_failed_entry_frees_the_chain(self):
        # Отказ по имени или месту (ABT=0): в родителе не писали — освободить.
        cpu, events, _ = self.mkdir('entry')
        self.assertEqual(events, ['MKSG', 'GIPAG', 'BODY', 'SVHDFL', 'DELCHA'])
        self.assertFalse(cpu.f & Z)
        self.assertEqual(cpu.a, 1, 'код отказа по имени не сохранён')

    # Отказ носителя при записи в родителе: сектор мог лечь (аудит Codex, п. 14).
    def test_media_failure_entry_not_there_frees_the_chain(self):
        cpu, events, _ = self.mkdir('entry', media=True, search='none')
        self.assertEqual(events, ['MKSG', 'GIPAG', 'BODY', 'SVHDFL', 'SRHDRN', 'DELCHA'])
        self.assertFalse(cpu.f & Z)
        self.assertEqual(cpu.a, 0xFF)

    def test_media_failure_entry_landed_is_success(self):
        cpu, events, _ = self.mkdir('entry', media=True, search='ours')
        self.assertNotIn('DELCHA', events, 'цепочка освобождена под живой записью каталога')
        self.assertTrue(cpu.f & Z, 'каталог создан, а MKDIR сообщил отказ')

    def test_media_failure_unreadable_keeps_the_chain(self):
        cpu, events, _ = self.mkdir('entry', media=True, search='error')
        self.assertNotIn('DELCHA', events, 'неизвестно, легла ли запись, а цепочка освобождена')
        self.assertFalse(cpu.f & Z)
        self.assertEqual(cpu.a, 0xFF)

    def test_media_failure_foreign_cluster_keeps_the_chain(self):
        cpu, events, _ = self.mkdir('entry', media=True, search='foreign')
        self.assertNotIn('DELCHA', events)
        self.assertFalse(cpu.f & Z)


class Depth(unittest.TestCase):
    """Стеки обхода F5/F8 в странице #C000 не переходят за #FFFF."""

    def dircopy(self, top):
        cpu = p.base()
        m = cpu.memory
        ddirs = B['WCFX.DDIRS'] + 1
        h.put16(m, ddirs, top)
        p.run(cpu, B['WCFX.DCIN'], {}, stops=(B['WCFX.ERMAIN'], B['WCFX.ZANOVOC']))
        return cpu, h.get16(m, ddirs)

    def test_dircopy_normal_level(self):
        cpu, top = self.dircopy(0xC010)
        self.assertEqual(cpu.pc, B['WCFX.ZANOVOC'])
        self.assertEqual(top, 0xC012)

    def test_dircopy_refuses_before_the_page_end(self):
        cpu, top = self.dircopy(0xFEFE)
        self.assertEqual(cpu.pc, B['WCFX.ERMAIN'], 'стек индексов дошёл до конца страницы')
        self.assertEqual(cpu.b, 7)
        self.assertEqual(top, 0xFEFE, 'вершина стека сдвинута при отказе')

    def dirtrem(self, top):
        cpu = p.base()
        h.put16(cpu.memory, B['WCFX.DDIRS'] + 1, top)
        p.run(cpu, B['WCFX.DDIRZ'], {B['WCFX.RECBUF']: p.ret},
              stops=(B['WCFX.DDIRS'], B['WCFX.DTRER0']))
        return cpu

    def test_dirtrem_normal_level(self):
        self.assertEqual(self.dirtrem(0xC123).pc, B['WCFX.DDIRS'])

    def test_dirtrem_refuses_before_the_page_end(self):
        cpu = self.dirtrem(0xFF10)
        self.assertEqual(cpu.pc, B['WCFX.DTRER0'], 'стек имён дошёл до конца страницы')
        self.assertEqual(cpu.b, 7)


def lstcat(m):
    return h.get32(m, sym('LSTCAT'))


class CopyIntoItself(unittest.TestCase):
    """DIRCOPY_INSIDE: подъём по «..» от каталога назначения (ERRR) к корню.

    FENTRY подменён: «..» каталога берётся из словаря; поиск без ответа — Z
    («нет»), с ошибкой чтения — Z и ABT≠0. GDIR/TLSTCAT/LOADCD2 — настоящие.
    Прежде любой Z считался корнем: ошибка чтения или испорченный каталог
    открывали дорогу рекурсии.
    """

    def inside(self, dest, source, parents, broken=(), broot=2):
        cpu = p.base()
        m = cpu.memory
        h.put32(m, B['ERRR'], dest)
        h.put32(m, B['BRRR'], source)
        h.put32(m, sym('LSTCAT'), dest)
        h.put32(m, sym('BROOTC'), broot)
        steps = []

        def fentry(cpu):
            here = lstcat(m)
            steps.append(here)
            m[sym('ABT')] = 1 if here in broken else 0
            if here in parents and here not in broken:
                h.put32(m, 0x7F30, parents[here])
                cpu.f = 0                                  # NZ — «..» найдена
            else:
                cpu.f = Z
            p.ret(cpu)

        cpu.c = 0
        p.run(cpu, B['WCINI.DIRCOPY_INSIDE'], {B['WCINI.FENTRY']: fentry})
        self.assertEqual(lstcat(m), dest, 'каталог назначения не восстановлен')
        return bool(cpu.f & C), steps

    def test_descendant_refused(self):
        refused, _ = self.inside(100, 50, {100: 60, 60: 50, 50: 0})
        self.assertTrue(refused)

    def test_same_directory_refused(self):
        refused, steps = self.inside(50, 50, {50: 0})
        self.assertTrue(refused)
        self.assertEqual(steps, [])

    def test_unrelated_allowed_up_to_zero_root(self):
        refused, _ = self.inside(100, 50, {100: 60, 60: 0})
        self.assertFalse(refused)

    def test_root_as_brootc_allowed(self):
        refused, _ = self.inside(2, 50, {}, broot=2)
        self.assertFalse(refused)

    def test_read_error_is_not_root(self):
        # «..» каталога 60 не прочитана: прежде это считалось корнем.
        refused, _ = self.inside(100, 50, {100: 60, 60: 50}, broken=(60,))
        self.assertTrue(refused, 'ошибка чтения «..» открыла копию внутрь себя')

    def test_missing_dotdot_outside_root_refused(self):
        # у каталога 60 нет «..» (испорчен), а он не корень
        refused, _ = self.inside(100, 50, {100: 60})
        self.assertTrue(refused, 'каталог без «..» принят за корень')


def record(name, cluster, attr=0x10):
    rec = bytearray(32)
    rec[0:11] = name
    rec[11] = attr
    rec[20:22] = (cluster >> 16).to_bytes(2, 'little')
    rec[26:28] = (cluster & 0xFFFF).to_bytes(2, 'little')
    return bytes(rec)


def dot_sector(cluster, attr=0x10, parent=0):
    """Первый сектор каталога: «.» на cluster и «..» на parent (0 — корень)."""
    sector = bytearray(512)
    sector[0:32] = record(b'.          ', cluster, attr)
    sector[32:64] = record(b'..         ', parent)
    return bytes(sector)


def parent_sector(cluster, link='live'):
    """Сектор родителя: чужой файл, затем запись SUB на cluster — живая
    запись каталога ('live'), удалённая ('deleted'), файл ('file') или нет."""
    sector = bytearray(512)
    sector[0:32] = record(b'OTHER   BIN', 99, 0x20)
    if link != 'none':
        sector[32:64] = record(b'SUB        ', cluster, 0x20 if link == 'file' else 0x10)
        if link == 'deleted':
            sector[32] = 0xE5
    return bytes(sector)


class OtherPanelRefresh(unittest.TestCase):
    """OTHER_REFRESH после F8 и кода возврата плагина 3: соседняя панель.

    Каталог жив, только если его кластер занят в FAT, первый сектор
    начинается записями «.» каталога на этот же кластер и «..», а родитель из
    «..» ссылается на него живой записью каталога (ID_DIR_ALIVE; обход
    родителя — не больше 4096 секторов): плагин мог удалить каталог и тут же
    создать файл на его кластере (аудит Codex, п. 12) — панель писала бы
    записи каталога в данные файла. У «..» сверяются два байта имени и бит
    каталога; сам родитель (FAT, путь от корня) не проверяется — это защита
    от кластера, отданного файлу, а не проверка целостности тома.

    parent_length — родитель из стольких секторов, ссылка в последнем."""

    def refresh(self, curit_fails, fat_value=0x0FFFFFFF, dir_cluster=12, sector=None,
                read_fails=False, link='live', parent=0, looped=False, parent_length=None):
        cpu = p.base()
        m = cpu.memory
        h.put32(m, sym('LSTCAT'), dir_cluster)
        h.put32(m, sym('BROOTC'), 2)
        sector = dot_sector(dir_cluster, parent=parent) if sector is None else sector
        sectors = {dir_cluster: sector, parent or 2: parent_sector(dir_cluster, link)}
        events = []
        current = []
        filler = b''.join(record(b'X%02d     BIN' % i, 99, 0x20) for i in range(16))

        def gipag(cpu):
            cluster = h.get32(m, cpu.hl)
            events.append(('GIPAG', cluster))
            current[:] = [cluster]
            cpu.a, cpu.f = 0, Z
            p.ret(cpu)

        def load512(cpu):
            events.append('LOAD512')
            if read_fails:
                m[sym('ABT')] = 1
                cpu.a, cpu.f = 0xFF, C
            else:
                block = sectors[current[0]]
                eoc = 0x0F                              # каталог в один сектор
                if looped and current[0] != dir_cluster:
                    # FAT родителя замкнута на себя, и в секторе 16 живых
                    # чужих записей без конца каталога: EOC не наступает.
                    block, eoc = filler, 0
                    events.append('LOOP')
                if parent_length and current[0] != dir_cluster:
                    events.append('PARENT')
                    if events.count('PARENT') < parent_length:
                        block, eoc = filler, 0
                m[cpu.hl:cpu.hl + 512] = block
                m[sym('EOC')] = eoc
                cpu.hl, cpu.f = (cpu.hl + 512) & 0xFFFF, 0
            p.ret(cpu)

        def swppand(cpu):
            events.append('SWPPAND')
            p.ret(cpu)

        def curit(cpu):
            if curit_fails:
                m[sym('ABT')] = 1
                cpu.f = C
            else:
                h.put32(m, 0x3000, fat_value)
                cpu.hl, cpu.f = 0x3000, 0
            p.ret(cpu)

        def note(label):
            def hook(cpu):
                events.append(label)
                p.ret(cpu)
            return hook

        p.run(cpu, B['WCINI.OTHER_REFRESH'], {B['WCFX.SWPPAND']: swppand, sym('CURIT'): curit,
                                             sym('GIPAG'): gipag, sym('LOAD512'): load512,
                                             B['WCINI.RPATH']: note('RPATH'), B['PANELI']: note('PANELI'),
                                             B['FOLD']: note('FOLD')})
        return events, h.get32(m, B['BRRR'])

    def test_live_directory_stays(self):
        events, brrr = self.refresh(False)
        self.assertNotIn('RPATH', events)
        self.assertEqual(brrr, 12)

    def test_live_directory_with_high_cluster_stays(self):
        events, brrr = self.refresh(False, dir_cluster=0x012345)
        self.assertNotIn('RPATH', events)
        self.assertEqual(brrr, 0x012345)

    def test_cluster_reused_by_a_file_goes_to_root(self):
        # Кластер занят, но в нём данные файла: панель не должна считать его
        # своим каталогом.
        events, brrr = self.refresh(False, sector=bytes(range(256)) * 2)
        self.assertIn('RPATH', events, 'панель осталась в кластере, отданном файлу')
        self.assertEqual(brrr, 0)

    def test_dot_of_another_directory_goes_to_root(self):
        events, brrr = self.refresh(False, sector=dot_sector(13))
        self.assertIn('RPATH', events)
        self.assertEqual(brrr, 0)

    def test_dot_without_directory_attribute_goes_to_root(self):
        events, brrr = self.refresh(False, sector=dot_sector(12, attr=0x20))
        self.assertIn('RPATH', events)

    def test_parent_link_checked_in_parent_directory(self):
        events, brrr = self.refresh(False, parent=40)
        self.assertNotIn('RPATH', events)
        self.assertIn(('GIPAG', 40), events, 'родитель из «..» не прочитан')

    def test_root_parent_is_brootc(self):
        events, _ = self.refresh(False)
        self.assertIn(('GIPAG', 2), events, '«..»=0 — корень, BROOTC')

    def test_cluster_reused_by_unwritten_file_goes_to_root(self):
        # MKFILE выделил кластер удалённого каталога, данных ещё не писал:
        # «.» цела, но родитель на каталог больше не ссылается (аудит Codex).
        for link in ('deleted', 'file', 'none'):
            with self.subTest(link=link):
                events, brrr = self.refresh(False, link=link)
                self.assertIn('RPATH', events, f'родитель без живой ссылки ({link}), а панель осталась')
                self.assertEqual(brrr, 0)

    def test_looped_parent_chain_ends_and_goes_to_root(self):
        # Регрессия, найденная Codex: обход родителя без предела на замкнутой
        # цепочке испорченного тома не кончался — WC висел в OTHER_REFRESH.
        events, brrr = self.refresh(False, looped=True)
        self.assertIn('RPATH', events)
        self.assertEqual(events.count('LOOP'), 4096, 'предел обхода — 4096 секторов каталога')

    def test_full_parent_directory_is_read_to_the_last_sector(self):
        # Каталог FAT32 — до 65536 записей, 4096 секторов. Ссылка в последнем
        # секторе полного родителя находится: прежде счётчик 4096, уменьшаемый
        # до чтения, давал 4095 секторов, и панель зря уходила в корень.
        events, brrr = self.refresh(False, parent_length=4096)
        self.assertEqual(events.count('PARENT'), 4096)
        self.assertNotIn('RPATH', events, 'ссылка в 4096-м секторе родителя не найдена')
        self.assertEqual(brrr, 12)

    def test_second_entry_not_dotdot_goes_to_root(self):
        for broken in (record(b'SUB        ', 0), record(b'..         ', 0, 0x20)):
            with self.subTest(broken=broken[:12]):
                sector = bytearray(dot_sector(12))
                sector[32:64] = broken
                events, brrr = self.refresh(False, sector=bytes(sector))
                self.assertIn('RPATH', events, 'номер родителя взят не из «..» каталога')

    def test_unreadable_first_sector_goes_to_root(self):
        events, brrr = self.refresh(False, read_fails=True)
        self.assertIn('RPATH', events)
        self.assertEqual(brrr, 0)

    def test_freed_directory_goes_to_root(self):
        events, brrr = self.refresh(False, fat_value=0)
        self.assertIn('RPATH', events)
        self.assertEqual(brrr, 0)

    def test_unreadable_fat_goes_to_root(self):
        events, brrr = self.refresh(True)
        self.assertIn('RPATH', events, 'FAT не прочитана — панель оставлена в непроверенном каталоге')
        self.assertEqual(brrr, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
