"""Настоящий Z80: регистрация WMF, пул метаданных, поиск и оба пути загрузки.

Подменены только чтения с диска; копирование, парсер, распределение памяти,
страничные переключения и машинный код диспетчера исполняются из сборки.
"""
from pathlib import Path
import re
import sys
import unittest

import z80

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build'
sys.path.insert(0, str(ROOT / 'tools'))
import wmf_metadata
STOP, STACK = 0x5C80, 0x5D80


def symbols(name):
    return {m[1]: int(m[2], 16) for line in (BUILD / name).read_text().splitlines()
            if (m := re.match(r'^([^:]+):\s+EQU\s+0x([0-9A-Fa-f]+)$', line))}


S = symbols('WMF_RUNTIME.sym')
W = symbols('boot.sym')


def word(buf, pos, value=None):
    if value is None:
        return int.from_bytes(bytes(buf[pos:pos + 2]), 'little')
    buf[pos:pos + 2] = (value & 0xFFFF).to_bytes(2, 'little')


def metadata(entries):
    return b''.join(bytes((len(ext), handler)) + ext.encode('ascii')
                    for ext, handler in entries)


def header(entries=(), *, version=0x11, name='Dynamic fixture', route=0):
    data = bytearray(512)
    data[16:32] = b'WildCommanderMDL'
    data[32], data[34] = version, 1
    data[36:38] = bytes((0, 1))
    data[63] = route
    data[161:165] = b'\xff' * 4
    data[165:197] = name.encode().ljust(32, b' ')
    if version == 0x11:
        word(data, 48, len(metadata(entries)))
        word(data, 50, len(entries))
        data[54] = 1
    else:
        for i, (ext, _) in enumerate(entries):
            data[64 + 3*i:67 + 3*i] = ext.encode().ljust(3, b' ')
    return data


class Stand:
    def __init__(self):
        self.cpu = z80.Z80Machine()
        self.cpu.set_memory_block(0x6011, (BUILD / 'boot.payload.bin').read_bytes())
        self.cpu.set_memory_block(0x5300, (BUILD / 'WMF_RUNTIME.bin').read_bytes())
        self.banks = {0x60: bytearray(0x4000), 0xE9: bytearray([0xCC]) * 0x4000}
        for p in range(0x61, 0xA0):
            self.banks[p] = bytearray([0xA5]) * 0x4000
        self.mapped = 0x60
        self.cpu.memory[0xC000:] = self.banks[0x60]
        self.cpu.memory[0x6003] = 0x60
        self.cpu.set_output_callback(self.out)
        self.cpu.set_input_callback(lambda port: self.mapped)
        word(self.cpu.memory, 0x7F18, 0xC000)
        self.cpu.ix, self.cpu.iy = 0x7EA0, 0x1234
        self.file = b''
        self.position = 0
        self.reads = []
        self.fail_at = None

    def map(self, page):
        self.banks[self.mapped][:] = bytes(self.cpu.memory[0xC000:])
        self.cpu.memory[0xC000:] = self.banks[page]
        self.mapped = page
        self.cpu.memory[0x6003] = page

    def out(self, port, value):
        assert port == 0x13AF, hex(port)
        self.map(value)

    def ret(self):
        self.cpu.pc = word(self.cpu.memory, self.cpu.sp)
        self.cpu.sp = (self.cpu.sp + 2) & 0xFFFF

    def read(self):
        c = self.cpu
        n = c.b * 512
        self.reads.append((c.hl, n))
        if len(self.reads) - 1 == self.fail_at:
            c.f = 1
        else:
            chunk = self.file[self.position:self.position + n]
            # Диск читает сектора; конец FAT-цепочки может прийти без CF.
            chunk = chunk[:len(chunk) // 512 * 512]
            assert c.hl + len(chunk) <= 0x10000
            c.memory[c.hl:c.hl + len(chunk)] = chunk
            self.position += len(chunk)
            c.hl = (c.hl + len(chunk)) & 0xFFFF
            c.af = 0x0040 if len(chunk) == n else 0x0F00
        self.ret()

    def call(self, entry, *, stop=STOP):
        c = self.cpu
        c.pc, c.sp = entry, STACK
        word(c.memory, STACK, STOP)
        c.set_breakpoint(stop)
        disk_entries = (0x4015, W['WDOS.LOAD512'])
        for address in disk_entries:
            c.set_breakpoint(address)
        for _ in range(1000):
            c.ticks_to_stop = 100000
            event = c.run()
            if event & 2:
                if c.pc == stop:
                    c.clear_breakpoint(stop)
                    for address in disk_entries:
                        c.clear_breakpoint(address)
                    self.banks[self.mapped][:] = bytes(c.memory[0xC000:])
                    return
                if c.pc in disk_entries:
                    self.read()
                # Движок также уступает управление на обратном JR WALK.
                # Только наши адреса подменяют вызов; остальные продолжаются.
        raise AssertionError(f'Z80 timeout at {c.pc:04X}')

    def register(self, entries=(), *, raw=None, desc=None, **kwargs):
        self.map(0x60)
        self.cpu.memory[0xB000:0xB200] = desc or header(entries, **kwargs)
        raw = metadata(entries) if raw is None else raw
        self.file = raw.ljust((len(raw) + 511) // 512 * 512, b'\0')
        self.position = 0
        self.call(S['WMF_REGISTER'])
        return not self.cpu.f & 1

    def match(self, index, name):
        self.map(0x60)
        self.cpu.memory[0x5E00:0x5F00] = name.encode('ascii').ljust(256, b'\0')
        ext = name.rsplit('.', 1)[-1].upper().encode('ascii')[:3].ljust(3, b' ')
        self.cpu.memory[0x7F73:0x7F76] = ext
        self.cpu.de = 0xC040 + index * 512
        self.call(S['WMF_MATCH'])
        return None if self.cpu.f & 0x40 else self.cpu.a


class Registration(unittest.TestCase):
    def test_sector_boundaries_including_exact_16k(self):
        for size in (511, 512, 513, 16383, 16384):
            s = Stand()
            entries = [('X', 0)] * ((size - 3) // 3)
            entries.append(('Y' * (size - len(metadata(entries)) - 2), 255))
            self.assertEqual(len(metadata(entries)), size)
            self.assertTrue(s.register(entries), size)
            self.assertEqual(s.position, (size + 511) // 512 * 512)
            self.assertEqual(s.match(0, 'file.' + entries[-1][0]), 255)

    def test_full_header_table_rejects_an_extra_plugin_without_writes(self):
        s = Stand()
        for i in range(32):
            self.assertTrue(s.register([], name=str(i)))
        before = bytes(s.cpu.memory[:0x5300])
        table = bytes(s.banks[0x60])
        self.assertFalse(s.register([], name='33rd'))
        self.assertEqual(s.cpu.a, 2)
        self.assertEqual(word(s.cpu.memory, 0x7F18), 0)
        self.assertEqual(bytes(s.cpu.memory[:0x5300]), before)
        self.assertEqual(bytes(s.banks[0x60]), table)

    def test_variable_counts_and_cookies_over_255(self):
        for count in (0, 1, 32, 64, 70, 256, 300, 1000):
            with self.subTest(count=count):
                s = Stand()
                entries = [(f'E{i:04}', i % 256) for i in range(count)]
                self.assertTrue(s.register(entries))
                self.assertEqual(word(s.cpu.memory, 0x7F18), 0xC200)
                self.assertEqual((s.cpu.ix, s.cpu.iy), (0x7EA0, 0x1234))
                for i in sorted(set((0, 31, 63, 69, 255, 256, count - 1))):
                    if 0 <= i < count:
                        self.assertEqual(s.match(0, f'file.e{i:04}'), i % 256)
                self.assertIsNone(s.match(0, 'file.unknown'))

    def test_legacy_all_32_positions_and_header_tail_ignored(self):
        s = Stand()
        entries = [(f'{i:03}', i) for i in range(32)]
        desc = header(entries, version=0x10)
        desc[48:63] = b'\xFF' * 15
        self.assertTrue(s.register(desc=desc))
        self.assertEqual(s.reads, [])
        for i in range(32):
            self.assertEqual(s.match(0, f'x.{i:03}'), i)
        self.assertIsNone(s.match(0, 'x.ABC'))

    def test_aliases_long_extensions_case_and_last_dot(self):
        s = Stand()
        self.assertTrue(s.register([('txt', 0), ('log', 0), ('LONGFORMAT', 255), ('C', 7)]))
        for name, code in [('one.TXT', 0), ('two.log', 0), ('a.b.LoNgFoRmAt', 255), ('a.c', 7)]:
            self.assertEqual(s.match(0, name), code)
        for name in ('no_extension', 'tail.', 'x.log2', 'x.longformatx', 'a.txt.zip'):
            self.assertIsNone(s.match(0, name))

    def test_full_pool_and_full_header_table(self):
        s = Stand()
        for i in range(32):
            self.assertTrue(s.register([(f'{i:03}', i)], name=f'Plugin {i}'))
        self.assertEqual(word(s.cpu.memory, 0x7F18), 0)
        for i in (0, 16, 31):
            self.assertEqual(s.match(i, f'x.{i:03}'), i)
        self.assertEqual(bytes(s.cpu.memory[:512]), bytes(512))
        s.cpu.de = 0xBE40
        for i in range(32):
            s.call(S['WMF_NEXT'])
            self.assertFalse(s.cpu.f & 1)
            self.assertEqual(s.cpu.de, 0xC040 + i * 512)
        s.call(S['WMF_NEXT'])
        self.assertTrue(s.cpu.f & 1)

    def test_memory_exhaustion_and_reuse_after_removing_header(self):
        s = Stand()
        # 5461 трёхбайтовая запись = 16383 байта: весь 16-КиБ пул, 16-битный count.
        self.assertTrue(s.register([('X', 123)] * 5461))
        saved = bytes(s.cpu.memory[0xC000:0xC200])
        self.assertFalse(s.register([('Z', 2)]))
        self.assertEqual(s.cpu.a, 2)
        self.assertEqual(word(s.cpu.memory, 0x7F18), 0xC200)
        self.assertEqual(bytes(s.cpu.memory[0xC000:0xC200]), saved)
        self.assertEqual(s.match(0, 'a.X'), 123)
        word(s.cpu.memory, 0x7F18, 0xC000)
        self.assertTrue(s.register([('Z', 255)]))
        self.assertEqual(word(s.cpu.memory, 0xC034), 0xC000)
        self.assertEqual(s.match(0, 'a.Z'), 255)

    def test_removed_middle_record_frees_only_its_sectors(self):
        s = Stand()
        for name, cookie in [('AAA', 1), ('BBB', 2), ('CCC', 3)]:
            self.assertTrue(s.register([(name, cookie)]))
        s.cpu.memory[0xC200:0xC400] = bytes(s.cpu.memory[0xC400:0xC600])
        word(s.cpu.memory, 0x7F18, 0xC400)
        self.assertTrue(s.register([('DDD', 4)]))
        self.assertEqual(word(s.cpu.memory, 0xC434), 0xC200)
        for i, ext, code in [(0, 'AAA', 1), (1, 'CCC', 3), (2, 'DDD', 4)]:
            self.assertEqual(s.match(i, 'x.' + ext), code)

    def test_bad_descriptors_and_records_do_not_publish(self):
        cases = []
        for offset, value in [(48, 0x4001), (48, 0xFFFF), (50, 0), (50, 0xFFFF)]:
            h = header([('TXT', 0)])
            word(h, offset, value)
            cases.append((h, b'\3\0TXT'))
        h = header([('TXT', 0)])
        h[54] = 2
        cases.append((h, b'\3\0TXT'))
        for blob in (b'\0\0', b'\3\0TX', b'\3\0TXTz', b'\1\0.', b'\1\0/', b'\1\0\\', b'\1\0*', b'\1\0?', b'\1\0\0', b'\1\0\x80'):
            h = header([('X', 0)])
            word(h, 48, len(blob))
            cases.append((h, blob))
        for h, blob in cases:
            with self.subTest(header=bytes(h[48:55]), blob=blob):
                s = Stand()
                self.assertFalse(s.register(desc=h, raw=blob))
                self.assertEqual(s.cpu.a, 1)
                self.assertEqual(word(s.cpu.memory, 0x7F18), 0xC000)
                self.assertEqual(s.mapped, 0x60)

    def test_io_failure_and_short_chain_do_not_publish(self):
        for fail in (False, True):
            s = Stand()
            if fail:
                s.fail_at = 0
            self.assertFalse(s.register(desc=header([('TXT', 0)]), raw=b''))
            self.assertEqual(s.cpu.a, 3)
            self.assertEqual(word(s.cpu.memory, 0x7F18), 0xC000)

    def test_enter_f3_and_no_read_past_last_header(self):
        s = Stand()
        for route in (1, 3, 0):
            self.assertTrue(s.register([('TXT', route)], route=route))
        for key, wanted in [(0, [0, 2]), (1, [1, 2])]:
            s.cpu.memory[0x6017] = key
            s.cpu.de = 0xBE40
            for i in wanted:
                s.call(S['WMF_NEXT'])
                self.assertFalse(s.cpu.f & 1)
                self.assertEqual(s.cpu.de, 0xC040 + 512 * i)
            s.call(S['WMF_NEXT'])
            self.assertTrue(s.cpu.f & 1)


class Loading(unittest.TestCase):
    def test_native_wc_registration_and_eager_loading(self):
        for version, count in [(0x10, 32), (0x11, 300)]:
            s = Stand()
            entries = [(f'{i:03}', i % 256) for i in range(count)]
            s.cpu.memory[0xB000:0xB200] = header(entries, version=version)
            raw = metadata(entries) if version == 0x11 else b''
            code = bytes(range(256)) * 2
            s.file = raw.ljust((len(raw) + 511) // 512 * 512, b'\0') + code
            s.call(W['WCVW.LDRE'], stop=W['WCVW.LGW'])
            self.assertEqual(word(s.cpu.memory, 0x7F18), 0xC200)
            self.assertEqual(bytes(s.banks[0x61][:512]), code)
            self.assertEqual(s.position, len(s.file))

    def test_plm_skip_zero_legacy_multisector_and_failure(self):
        for version, count in [(0x10, 0), (0x11, 0), (0x11, 300)]:
            s = Stand()
            entries = [('TXT', i % 256) for i in range(count)]
            s.cpu.memory[0x9A00:0x9C00] = header(entries, version=version)
            raw = metadata(entries)
            padded = raw.ljust((len(raw) + 511) // 512 * 512, b'\0')
            s.file = padded + b'CODE' * 128
            s.cpu.hl, s.cpu.de = 0x9A00, 0x9C00
            s.call(S['WMF_SKIP'])
            self.assertFalse(s.cpu.f & 1)
            self.assertEqual(s.position, len(padded))
        for short in (False, True):
            s = Stand()
            s.cpu.memory[0x9A00:0x9C00] = header([('X', 0)] * 400)
            s.file = bytes(512) if short else bytes(1536)
            if not short:
                s.fail_at = 1
            s.cpu.hl, s.cpu.de = 0x9A00, 0x9C00
            s.call(S['WMF_SKIP'])
            self.assertTrue(s.cpu.f & 1)
            self.assertEqual(s.cpu.a, 3)

    def test_plm_lazy_load_evict_reload_and_short_metadata(self):
        import test_plugin_manager as plm

        class Disk(plm.Stand):
            def file_call(self, name):
                def handler(cpu):
                    self.file_calls.append(name)
                    self.file_streams.append(self.peek(0x6000))
                    cpu.f = 0x40
                    if name == 'GIPAG':
                        self.position = 0
                    else:
                        size = cpu.b * 512
                        chunk = self.file[self.position:self.position + size]
                        chunk = chunk[:len(chunk) // 512 * 512]
                        cpu.memory[cpu.hl:cpu.hl + len(chunk)] = chunk
                        cpu.hl = (cpu.hl + len(chunk)) & 65535
                        self.position += len(chunk)
                        if len(chunk) < size:
                            cpu.af = 0x0F00
                    self.ret(cpu)
                return handler

        entries = [(f'E{i:04}', i % 256) for i in range(1000)]
        desc = header(entries)
        raw = metadata(entries)
        code = bytes(range(256)) * 2
        for short in (False, True):
            s = Disk([dict(name='Dynamic', pages=1, base=255)], restop=2, ppgm=2)
            s.file = bytes(desc) + (bytes(512) if short else
                     raw.ljust((len(raw) + 511) // 512 * 512, b'\0') + code)
            for attempt in range(2):
                s.cpu.memory[plm.S['COPY']:plm.S['COPY'] + 512] = desc
                s.cpu.hl = 0xC000
                s.run(plm.S['LOAD_PLUGIN'])
                self.assertEqual(s.peek(0x6000), plm.PANEL_STREAM)
                if short:
                    self.assertEqual(s.peek(plm.S['TRACE']), 4)
                    self.assertEqual(s.headers()[0]['base'], 255)
                    self.assertEqual(s.peek(plm.S['PPGM']), 2)
                    break
                self.assertEqual(s.cpu.a, 2)
                self.assertEqual(bytes(s.pages[plm.S['PLGPG'] + 2][:512]), code)
                self.assertEqual(s.position, len(s.file))
                s.poke(plm.S['NEEDED'], plm.S['POOL_LIMIT'] - 2)
                s.run(plm.S['ENSURE_SPACE'])
                self.assertEqual(s.headers()[0]['base'], 255)
                self.assertEqual(s.peek(plm.S['PPGM']), 2)


class Packaging(unittest.TestCase):
    def test_old_cookies_and_code_survive_conversion_and_repacking(self):
        code = bytes(range(256)) * 2
        old = bytes(header([('TXT', 0), ('LOG', 1)], version=0x10)) + code
        new = wmf_metadata.rewrite(old)
        self.assertEqual(wmf_metadata.decode(new[:512], new[512:]),
                         [dict(extension='TXT', handler=0), dict(extension='LOG', handler=1)])
        self.assertEqual(new[1024:], code)
        entries = [dict(extension=f'E{i:04}', handler=i % 256) for i in range(1000)]
        packed = wmf_metadata.rewrite(new, entries)
        self.assertEqual(packed[512 + 7168:], code)
        self.assertEqual(wmf_metadata.decode(packed[:512], packed[512:]), entries)
        self.assertEqual(packed[161:512], old[161:512], 'параметры и свойства сохранены')
        self.assertEqual(wmf_metadata.rewrite(packed, []), packed[:48] + bytes(4) +
                         packed[52:512] + code)
        # Резерв +55..+62 прежнего заголовка в #11 не переносится.
        dirty = bytearray(old)
        dirty[48:63] = b'\xff' * 15
        self.assertEqual(wmf_metadata.rewrite(bytes(dirty))[55:63], bytes(8))

    def test_bad_or_ambiguous_associations_rejected(self):
        for entries in ([dict(extension='txt', handler=0), dict(extension='TXT', handler=1)],
                        [dict(extension='a.b', handler=0)], [dict(extension='TXT', handler=256)],
                        [dict(extension='X'*255, handler=0)] * 100):
            with self.assertRaises(ValueError):
                wmf_metadata.encode(entries)


if __name__ == '__main__':
    unittest.main(verbosity=2)
