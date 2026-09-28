"""Короткое имя длинной записи без «~n» (2026-09-26).

ПЗУ ZX Evolution (TS-BIOS, booter.asm, srhdrn) ищет в корне boot.$C по
одиннадцати байтам короткого имени «BOOT    $C » — длинные имена оно не
читает. Ядро WC пишет длинное имя всему, что не является строчным именем 8.3
(ради заглавных букв), и прежде всегда делало короткое с «~n»: у «boot.$C»
выходило «BOOTJ$~1$C» (знак после BOOT — случайный), и после замены boot.$C
(FENTRY → DELFL → MKFILE → APPEND, как FTP) ПЗУ файла не находило. Теперь, если
имя укладывается в 8.3 и мешали только заглавные буквы, короткое имя — само
это имя заглавными, когда такого в каталоге нет (PLAIN_ALIAS расширения; так
делает и Windows). Имена длиннее 8.3, с лишней точкой, пробелом или знаком,
запрещённым в 8.3, получают «~n», как прежде.

Исполняются собранные ядро и расширение на диске в памяти.
"""
import unittest

import test_overwrite_path as t

ROM_NAME = b'BOOT    $C '


def records(volume):
    """Живые записи каталога: ('LFN', текст) и ('SFN', 11 байт)."""
    out = []
    data = volume.directory()
    for off in range(0, len(data), 32):
        rec = data[off:off + 32]
        if rec[0] == 0:
            break
        if rec[0] == 0xE5:
            continue
        if rec[11] == 0x0F:
            text = (rec[1:11] + rec[14:26] + rec[28:32]).decode('utf-16-le').split('\0')[0]
            out.append(('LFN', text))
        else:
            out.append(('SFN', rec[:11]))
    return out


def short_names(volume):
    return [data for kind, data in records(volume) if kind == 'SFN']


def sfn_checksum(sfn):
    total = 0
    for byte in sfn:
        total = (((total & 1) << 7) + (total >> 1) + byte) & 0xFF
    return total


def plant(volume, long_name, sfn):
    """Чужая запись в пустом каталоге: длинное имя и короткое sfn."""
    chars = [ord(c) for c in long_name]
    chunks = [chars[i:i + 13] for i in range(0, len(chars), 13)]
    recs = []
    for index in range(len(chunks), 0, -1):
        values = chunks[index - 1] + [0]
        values = (values + [0xFFFF] * 13)[:13]
        rec = bytearray(32)
        rec[0] = index | (0x40 if index == len(chunks) else 0)
        rec[11], rec[13] = 0x0F, sfn_checksum(sfn)
        for pos, value in zip((1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30), values):
            rec[pos:pos + 2] = value.to_bytes(2, 'little')
        recs.append(bytes(rec))
    recs.append(sfn + bytes([0x20]) + bytes(20))
    lba = volume.cluster_lba(t.DIR_CLUSTER)
    sector = bytearray(volume.read_sector(lba))
    sector[:32 * len(recs)] = b''.join(recs)
    volume.sectors[lba] = bytes(sector)


def lfn_checksums(volume):
    """Пары (сумма в записях LFN, сумма короткого имени за ними)."""
    out, pending = [], []
    data = volume.directory()
    for off in range(0, len(data), 32):
        rec = data[off:off + 32]
        if rec[0] == 0:
            break
        if rec[0] == 0xE5:
            pending = []
            continue
        if rec[11] == 0x0F:
            pending.append(rec[13])
            continue
        total = 0
        for byte in rec[:11]:
            total = (((total & 1) << 7) + (total >> 1) + byte) & 0xFF
        out.extend((value, total) for value in pending)
        pending = []
    return out


def rom_finds(volume):
    """Поиск ПЗУ: первые 11 байт записей до нулевой, побайтно."""
    data = volume.directory()
    for off in range(0, len(data), 32):
        if data[off] == 0:
            return False
        if data[off:off + 11] == ROM_NAME:
            return True
    return False


class PlainShortName(unittest.TestCase):

    def create(self, name, directory=False):
        v = t.Volume()
        if directory:
            a, f, _, _ = v.call(0x403C, hl=self.dir_query(v, name), budget=2000000)
            self.assertTrue(f & 0x40, f'MKDIR «{name}»: A={a}')
        else:
            a, created = v.mkfile(name, 0)
            self.assertTrue(created, f'MKFILE «{name}»: A={a}')
        return v

    @staticmethod
    def dir_query(v, name):
        data = name.encode('cp866') + b'\0'
        v.mem[t.NAME_SLOT:t.NAME_SLOT + len(data)] = data
        return t.NAME_SLOT

    def test_case_only_names_get_plain_short_name(self):
        cases = {
            'boot.$C': b'BOOT    $C ',
            'BOOT.$C': b'BOOT    $C ',
            'Boot.$C': b'BOOT    $C ',
            'ReadMe.txt': b'README  TXT',
            'A.B': b'A       B  ',
            'Game': b'GAME       ',
            'WC.INI': b'WC      INI',
            # cp866: ACS переводит и русские строчные; «х» (#E5 — метка
            # удалённой записи в FAT) становится «Х» (#95).
            'Файл.txt': 'ФАЙЛ    TXT'.encode('cp866'),
            'хЛам.txt': 'ХЛАМ    TXT'.encode('cp866'),
            'Ёлка.Txt': 'ЁЛКА    TXT'.encode('cp866'),
        }
        for name, expected in cases.items():
            with self.subTest(name):
                v = self.create(name)
                self.assertEqual(records(v), [('LFN', name), ('SFN', expected)])
                # Сумма в LFN посчитана по тому же короткому, что записано.
                sums = lfn_checksums(v)
                self.assertTrue(sums)
                self.assertTrue(all(a == b for a, b in sums), sums)

    def test_lowercase_name_is_still_short_only(self):
        v = self.create('boot.$c')
        self.assertEqual(records(v), [('SFN', b'BOOT    $C ')])

    def test_directory_with_capitals(self):
        v = self.create('Games', directory=True)
        self.assertIn(('SFN', b'GAMES      '), records(v))
        self.assertIn(('LFN', 'Games'), records(v))

    def test_other_long_names_keep_numeric_tail(self):
        for name in ('VeryLongName.txt', 'a.b.c', 'my file.txt', 'a+b.txt', 'name.text'):
            with self.subTest(name):
                v = self.create(name)
                short = short_names(v)
                self.assertEqual(len(short), 1)
                self.assertIn(b'~', short[0], f'у «{name}» короткое без «~n»: {short[0]!r}')

    def test_same_name_in_other_case_is_refused(self):
        # Короткое имя в FAT — тоже имя: при занятом «BOOT    $C» совпадает и
        # само имя, MKFILE отказывает, второй записи с тем же коротким нет.
        for first, second in (('boot.$c', 'Boot.$C'), ('Boot.$C', 'boot.$c'), ('BOOT.$C', 'boot.$C')):
            with self.subTest(first=first, second=second):
                v = t.Volume()
                self.assertTrue(v.mkfile(first, 0)[1])
                a, created = v.mkfile(second, 0)
                self.assertFalse(created)
                self.assertIn(a, (3, 4), '«Name already exists!»')
                self.assertEqual(short_names(v), [b'BOOT    $C '])

    def test_occupied_candidate_goes_to_numeric_tail(self):
        # Codex R18-1: короткое-кандидат занято чужой записью с другим длинным
        # именем. PLAIN_ALIAS обязан это увидеть и отдать имя пути «~n» (метка
        # NN); прежде он сравнивал короткие имена с ENTRY в исходном регистре и
        # отвечал «свободно». Итог MKFILE тот же — отказ последней проверкой
        # SRHDRN, запись чужая одна; различает их только ветка.
        cases = ((b'README  TXT', 'ReadMe.txt'),
                 ('ФАЙЛ    TXT'.encode('cp866'), 'Файл.txt'))
        for foreign, name in cases:
            with self.subTest(name):
                v = t.Volume()
                plant(v, 'Other name.txt', foreign)
                nn, hits = v.core('NN'), []

                def probe(v=v, nn=nn, hits=hits):
                    hits.append(nn)
                    v.cpu.clear_breakpoint(nn)
                v.handlers[nn] = probe
                v.cpu.set_breakpoint(nn)
                a, created = v.mkfile(name, 0)
                self.assertFalse(created)
                self.assertEqual(a, 3, '«Name already exists!»')
                self.assertEqual(short_names(v), [foreign])
                self.assertTrue(hits, 'PLAIN_ALIAS не заметил занятое короткое')

    def test_free_candidate_skips_numeric_tail(self):
        v = t.Volume()
        plant(v, 'Other name.txt', b'OTHERN~1TXT')
        nn, hits = v.core('NN'), []
        v.handlers[nn] = lambda: (hits.append(nn), v.cpu.clear_breakpoint(nn))
        v.cpu.set_breakpoint(nn)
        a, created = v.mkfile('ReadMe.txt', 0)
        self.assertTrue(created, a)
        self.assertEqual(hits, [])
        self.assertEqual(short_names(v), [b'OTHERN~1TXT', b'README  TXT'])

    def test_numeric_tails_do_not_repeat(self):
        v = t.Volume()
        for name in ('VeryLongName.txt', 'VeryLongName.txt2', 'VeryLongName.tx3'):
            self.assertTrue(v.mkfile(name, 0)[1], name)
        shorts = short_names(v)
        self.assertEqual(len(shorts), len(set(shorts)), f'повтор короткого имени: {shorts}')

    def test_replacing_boot_file_keeps_it_visible_to_rom(self):
        # Замена, как FTP: FENTRY, DELFL, MKFILE(0), FENTRY, APPEND.
        payload = bytes(range(256)) * 20
        for old, new in (('boot.$c', 'boot.$C'), ('boot.$C', 'boot.$C'), ('BOOT.$C', 'boot.$C')):
            with self.subTest(old=old, new=new):
                v = t.Volume()
                v.mkfile(old, 0)
                self.assertIsNotNone(v.find(new))
                self.assertFalse(v.delete(new)[1], 'DELFL прежнего')
                a, created = v.mkfile(new, 0)
                self.assertTrue(created, a)
                cluster = v.find(new)
                self.assertIsNotNone(cluster)
                self.assertEqual(v.append(payload), 0)
                self.assertTrue(rom_finds(v), records(v))
                entry = [e for e in v.entries() if e[0].lower() == 'boot.$c']
                self.assertEqual(len(entry), 1)
                self.assertEqual(v.read_file(entry[0][1], len(payload)), payload)


if __name__ == '__main__':
    unittest.main(verbosity=2)
