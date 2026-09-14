"""Машинные регрессии TXTVIEW.WMF: собранный Z80, подменяется API WC.

Проверяются реальные инструкции просмотрщика, а не Python-копия алгоритма.
Модель файлов допускает размер до 4 ГиБ без выделения такого объёма на хосте.
Это проверка плагина и контрактов API, а не физического носителя/ZX-Evo.
"""
from __future__ import annotations

import argparse
import json
import re
import random
import unittest
from pathlib import Path

import z80


ROOT = Path(__file__).resolve().parents[2]
WMF = ROOT / "Build/TXTVIEW.WMF"
SYMBOLS = ROOT / "Build/TXTVIEW.sym"
STACK, RETURN, WLD = 0x7D00, 0x7F00, 0x6006


class VirtualFile:
    def __init__(self, content: bytes = b"", *, size: int | None = None,
                 pattern: bytes = b"0123456789abcdef\r\n"):
        self.content = content
        self.size = len(content) if size is None else size
        self.pattern = pattern if size is not None else None

    def read(self, offset: int, count: int) -> bytes:
        count = max(0, min(count, self.size - offset))
        if self.pattern is None:
            return self.content[offset:offset + count]
        period = len(self.pattern)
        start = offset % period
        return (self.pattern * ((count + start + period - 1) // period))[start:start + count]


class Viewer:
    def __init__(self, content: bytes | VirtualFile = b"", *, filex=True,
                 width=80, height=25, detect=True):
        self.file = content if isinstance(content, VirtualFile) else VirtualFile(content)
        self.symbols = {name: int(value, 16) for name, value in re.findall(
            r"^([^:]+):\s+EQU\s+(0x[0-9a-fA-F]+)$", SYMBOLS.read_text(), re.M)}
        self.m = z80.Z80Machine()
        self.mem = self.m.memory
        self.mem[:] = b"\xA5" * 65536  # за EOF и в истории заведомо не нули
        self.mem[0x8000:0x8000 + WMF.stat().st_size - 512] = WMF.read_bytes()[512:]
        self.mem[self.s("State"):self.s("StateEnd")] = bytes(self.s("StateEnd") - self.s("State"))
        self.mem[0x781A] = 0
        self.mem[0x6004] = 0
        self.mem[0x38] = 0xC9
        self.m.set_breakpoint(WLD)
        self.m.set_breakpoint(RETURN)
        self.filex = filex
        self.context = True
        self.stream = 0
        self.width, self.height = width, height
        self.screen = [bytearray(b" " * width) for _ in range(height)]
        self.calls: list[tuple] = []
        self.reads: list[tuple] = []
        self.messages: list[tuple[bytes, bytes, bytes]] = []
        self.fault = None
        self.fail_open = False
        self.cancel = False
        self.escape_during_read = False
        self.last_print = None
        self.keys: dict[int, int] = {}
        self.put("FileSize", self.file.size)
        self.put("Width", width, 1)
        self.put("Rows", height - 2, 1)
        self.put("HaveFilex", int(filex), 1)
        self.mem[self.s("FileName"):self.s("FileName") + 10] = b"\0TEST.TXT\0"
        self.m.ix = self.s("ViewWindow")
        self.mem[self.m.ix + 4:self.m.ix + 6] = bytes([width, height])
        self.encoded_api_args: list[int] = []
        if detect:
            self.call("DetectEncoding")
            self.call("GoHome")

    def s(self, name):
        return self.symbols[name]

    def put(self, name, value, length=4):
        self.mem[self.s(name):self.s(name) + length] = value.to_bytes(length, "little")

    def get(self, name, length=4):
        return int.from_bytes(self.mem[self.s(name):self.s(name) + length], "little")

    def word(self, address):
        return int.from_bytes(self.mem[address:address + 2], "little")

    def cstring(self, address):
        result = bytearray()
        for _ in range(2048):
            byte = self.mem[address]
            if not byte:
                return bytes(result)
            result.append(byte)
            address += 1
        raise AssertionError("Строка API не завершена нулём")

    def api(self):
        m, mem = self.m, self.mem
        api = m.a
        # Реальный диспетчер меняет AF/AF' и разрушает альтернативный BC.
        # Раскладка поля взята из установленного z80._machine.Z80State.
        alternate = m._Z80State__alt_af
        old = m.af
        m.af = int.from_bytes(alternate, "little")
        alternate[:] = old.to_bytes(2, "little")
        m.alt_bc = 0xDEAD
        argument = m.a
        self.calls.append((api,))
        if api in (49, 72, 73, 74, 75, 76):
            raise AssertionError(f"Просмотрщик вызвал записывающий API {api}")
        if api == 77:
            block = m.hl
            assert 0x8000 <= block <= 0xC000 - 32
            raw = bytes(mem[block:block + 32])
            assert raw[:2] == b"\x20\x01" and not any(raw[12:24] + raw[30:32])
            operation, offset = raw[2], int.from_bytes(raw[4:8], "little")
            pointer, length = int.from_bytes(raw[8:10], "little"), int.from_bytes(raw[10:12], "little")
            status, count = 0, 0
            if not self.filex:
                status = 0x15
            elif operation == 0:
                count = 0xFF
            elif operation == 1:
                assert self.context
                assert 0x8000 <= pointer < pointer + length <= 0xC000
                assert pointer + length <= block or block + 32 <= pointer
                data = self.file.read(offset, length)
                count = len(data)
                if self.fault == "short":
                    count = max(0, count - 1)
                if self.fault == "media":
                    status = 0x21
                else:
                    status = 0 if count == length else 1
                    mem[pointer:pointer + count] = data[:count]
                self.reads.append(("position", offset, length, count))
                if self.escape_during_read:
                    mem[0x6004] = 1    # Esc уже отпущен при возврате READ_AT
            else:
                raise AssertionError(f"FILEX operation {operation} is not read-only")
            mem[block + 24:block + 28] = count.to_bytes(4, "little")
            mem[block + 28:block + 30] = bytes([status, 1])
            if self.fault == "count_high" and operation == 1:
                mem[block + 26] = 1
            m.bc, m.de, m.hl, m.ix = 0x1234, 0x5678, 0x9ABC, 0xABCD
            m.a, m.f = status, 0x40 if status == 0 else 0
            # Провайдер и UI могут менять всё #C000. Кэш обязан пережить это.
            mem[0xC000:] = b"\xCC" * 0x4000
        elif api == 48:
            count = m.b * 512
            pointer = m.hl
            assert 0x8000 <= pointer < pointer + count <= 0xC000
            available = min(count, (self.file.size - self.stream + 511) // 512 * 512)
            data = self.file.read(self.stream, count)
            if self.fault == "media":
                m.a, m.f = 0xFF, 1
                return
            if self.fault == "short":
                available = max(0, available - 512)
            mem[pointer:pointer + available] = data[:available].ljust(available, b"\xD7")
            self.reads.append(("stream", self.stream, count, available))
            self.stream += available
            m.hl = pointer + available
            m.a = 0x0F if self.stream >= self.file.size else 0
            m.f = 0x40 if m.a == 0 else 0
            m.bc, m.de = 0xBAD0, 0xBAD1
        elif api == 59:
            assert self.cstring(m.hl + 1) == b"TEST.TXT"
            self.context = not self.fail_open
            m.de, m.hl = self.file.size >> 16, self.file.size & 65535
            m.f = 0x40 if self.fail_open else 0
        elif api == 62:
            assert self.context
            self.stream = 0
            m.a, m.f = 0, 0x40
        elif api == 80:
            assert argument == 0
            m.a, m.f = 0, 0x40
        elif api == 15:
            mem[0x1000:0x1448] = b"\xF0" * 0x448
            m.a, m.f = 0, 0x40
        elif api == 86:
            assert argument == 1
            m.a, m.f = 0, 0x40
        elif api == 1:
            ix = m.ix
            if ix == self.s("ViewWindow"):
                mem[ix + 4:ix + 6] = bytes([self.width, self.height])
            if ix == self.s("MessageWindow"):
                self.messages.append(tuple(self.cstring(self.word(ix + off)) for off in (12, 14, 16)))
            m.a, m.f = 0, 0x40
        elif api == 2:
            m.a, m.f = 0, 0x40
        elif api == 3:
            assert m.ix == self.s("ViewWindow")
            row, col, count = m.d, m.e, m.bc
            assert 0 <= row < self.height and 0 <= col < col + count <= self.width
            assert 0x8000 <= m.hl <= 0xC000 - count
            self.screen[row][col:col + count] = mem[m.hl:m.hl + count]
            self.last_print = row, col, count
            m.hl = 0xC000 + row * 256 + col + count
            m.b = count
            m.a, m.f = 0, 0x40
        elif api == 4:
            assert self.last_print is not None and m.b == self.last_print[2]
            assert argument == 0x17
            m.a, m.f = 0, 0x40
        elif api in range(16, 46):
            pressed = (api == 23 and self.cancel) or self.keys.get(api, 0)
            m.a, m.f = int(bool(pressed)), 0 if pressed else 0x40
        elif api in (46, 47):
            m.a, m.f = 0, 0x40
        else:
            raise AssertionError(f"Неожиданный API {api}, PC={m.pc:04X}")

    def call(self, symbol, *, a=None, de=None, hl=None, bc=None, stop=None,
             budget=300_000_000):
        m = self.m
        m.sp = STACK
        self.mem[STACK:STACK + 2] = RETURN.to_bytes(2, "little")
        m.pc = self.s(symbol)
        for name, value in (("a", a), ("de", de), ("hl", hl), ("bc", bc)):
            if value is not None:
                setattr(m, name, value)
        stops = {RETURN}
        if stop:
            stops.add(self.s(stop))
            m.set_breakpoint(self.s(stop))
        ticks = 0
        try:
            while m.pc not in stops:
                chunk = min(1_000_000, budget - ticks)
                if chunk <= 0:
                    raise AssertionError(f"Зависание {symbol}: PC={m.pc:04X}, pos={self.get('Position'):08X}")
                m.ticks_to_stop = chunk
                m.run()
                # В установленном z80 getter ticks_to_stop содержит опечатку;
                # setter и четырёхбайтовое поле состояния работают корректно.
                ticks += chunk - int.from_bytes(m._StateBase__ticks_to_stop, "little")
                if m.pc == WLD:
                    self.api()
                    m.pc = self.word(m.sp)
                    m.sp = (m.sp + 2) & 65535
                elif m.halted:
                    m.on_handle_active_int()
            return m.a, bool(m.f & 1)
        finally:
            if stop:
                m.clear_breakpoint(self.s(stop))

    def line(self):
        return bytes(self.mem[self.s("LineBuffer"):self.s("LineBuffer") + self.width]).rstrip(b" ")

    def draw(self):
        self.call("DrawPage")
        return [bytes(row).rstrip(b" ") for row in self.screen[1:-1]]


class ViewerTests(unittest.TestCase):
    def test_header(self):
        raw = WMF.read_bytes()
        self.assertEqual(raw[16:32], b"WildCommanderMDL")
        self.assertEqual(raw[34:36], b"\x01\0")
        self.assertEqual(raw[63], 3)
        self.assertEqual(raw[161:165], b"\xFF" * 4)
        self.assertEqual(raw[197], 5)
        self.assertIn(b"NFO", raw[64:160])
        self.assertLessEqual(0x8000 + len(raw) - 512, 0xA800)
        self.assertEqual(len(raw), 512 + raw[37] * 512)

    def test_real_entry_modes_and_reopen(self):
        for launch, extension, text, expected_hex in (
                (0, 0, b"first\r\nsecond", 0),
                (0, 9, b"binary", 1),
                (4, 9, b"plain\ttext", 0),
                (4, 0, b"text\0binary", 1),
                (0, 0, b"", 0)):
            v = Viewer(text, detect=False)
            # Имя во входном BC живёт вне страницы плагина и может содержать
            # ровно 255 байт. Здесь моделируется реальная точка входа RE.
            v.mem[0x7100:0x7109] = b"TEST.TXT\0"
            for width, height in ((80, 25), (90, 36), (80, 30)):
                v.width, v.height = width, height
                v.screen = [bytearray(b" " * width) for _ in range(height)]
                v.m._Z80State__alt_af[:] = (extension << 8).to_bytes(2, "little")
                v.call("RE", a=launch, bc=0x7100, stop="MainLoop")
                self.assertEqual(v.get("HexMode", 1), expected_hex)
                self.assertEqual(v.get("FileSize"), len(text))
                self.assertEqual((v.get("Width", 1), v.get("Rows", 1)), (width, height - 2))
                self.assertEqual(v.get("IoError", 1), 0)
        v = Viewer(b"unused", detect=False)
        v.call("RE", a=3, bc=0xFFFF)
        self.assertEqual(v.reads, [])
        self.assertIn(b"Select a file", v.messages[-1][2])

    def test_failed_entry_does_not_read_stale_context(self):
        v = Viewer(b"secret", detect=False)
        v.fail_open = True
        v.mem[0x7100:0x7109] = b"TEST.TXT\0"
        v.call("RE", a=0, bc=0x7100)
        self.assertEqual(v.reads, [])
        self.assertIn(b"Cannot open", v.messages[-1][2])

    def test_utf8_fuzz_matches_standard_decoder(self):
        randomizer = random.Random(0x8661251)
        for _ in range(150):
            raw = bytes(randomizer.randrange(256) for _ in range(randomizer.randrange(1, 90)))
            v = Viewer(raw, detect=False)
            v.put("Encoding", 2, 1)
            actual = bytearray()
            for _ in range(len(raw) + 1):
                value, eof = v.call("ReadChar")
                if eof:
                    break
                actual.append(value)
            self.assertEqual(bytes(actual), raw.decode("utf-8", errors="replace").encode("cp866", errors="replace"), raw)

    def test_bom_only_hex_end(self):
        v = Viewer(b"\xef\xbb\xbf")
        v.call("ToggleMode")
        v.call("GoEnd")
        self.assertEqual(v.get("Top"), 0)

    def test_encoding_detection(self):
        samples = [
            "Привет, мир! Это русский текст для проверки кодировки.",
            "Съешь ещё этих мягких французских булок, да выпей чаю.",
            "ПРОВЕРКА БОЛЬШОГО ТЕКСТОВОГО ФАЙЛА И ПЕРЕКЛЮЧЕНИЯ КОДИРОВКИ",
            "просмотр больших файлов: строка, текст, кодировка, чтение",
            "Ёжик живёт в лесу. Ещё один тест, всё работает хорошо.",
        ]
        for text in samples:
            for encoding, expected in (("cp866", 0), ("cp1251", 1), ("utf-8", 2)):
                with self.subTest(text=text, encoding=encoding):
                    v = Viewer(text.encode(encoding))
                    self.assertEqual(v.get("Detected", 1), expected,
                                     (v.get("Score866", 2), v.get("Score1251", 2)))
                    v.put("Position", v.get("Top"))
                    v.call("TextRow")
                    self.assertEqual(v.line(), text.encode("cp866")[:80])
        self.assertEqual(Viewer(b"ASCII only").get("Detected", 1), 0)
        self.assertEqual(Viewer(b"\xef\xbb\xbfASCII").get("Detected", 1), 2)

    def test_all_cp866_glyphs_utf8(self):
        chars = bytes(range(128, 256)).decode("cp866")
        v = Viewer(chars.encode("utf-8"), detect=False)
        v.put("Encoding", 2, 1)
        decoded = bytes(v.call("ReadChar")[0] for _ in chars)
        self.assertEqual(decoded, bytes(range(128, 256)))
        self.assertTrue(v.call("ReadChar")[1])

    def test_all_cp1251_bytes(self):
        raw = bytes(range(128, 256))
        v = Viewer(raw, detect=False)
        v.put("Encoding", 1, 1)
        decoded = bytes(v.call("ReadChar")[0] for _ in raw)
        self.assertEqual(decoded, raw.decode("cp1251", errors="replace").encode("cp866", errors="replace"))

    def test_malformed_utf8(self):
        cases = [b"\x80A", b"\xc0\xaf", b"\xc1\xbf", b"\xc2",
                 b"\xe0\x80\xafZ", b"\xed\xa0\x80", b"\xf0\x80\x80\xaf",
                 b"\xf4\x90\x80\x80", b"\xf5\x80\x80\x80", b"\xe2\x82",
                 b"\xd0\r\nOK", b"\xe2\x82X", b"\xf0\x9f\x98\x80!",
                 "€漢🙂".encode()]
        for raw in cases:
            with self.subTest(raw=raw):
                v = Viewer(raw, detect=False)
                v.put("Encoding", 2, 1)
                result = bytearray()
                for _ in range(len(raw) + 1):
                    value, eof = v.call("ReadChar")
                    if eof:
                        break
                    result.append(value)
                else:
                    self.fail("Декодер не достиг EOF")
                self.assertEqual(bytes(result), raw.decode("utf-8", errors="replace").encode("cp866", errors="replace"))

    def test_utf8_cache_boundaries(self):
        for prefix in (4093, 4094, 4095, 65535, 1048575):
            for char in ("я", "─", "🙂"):
                raw = b"x" * prefix + char.encode() + b"Z"
                v = Viewer(raw, detect=False)
                v.put("Encoding", 2, 1)
                v.put("Position", prefix)
                self.assertEqual(v.call("ReadChar"), (char.encode("cp866", errors="replace")[0], False))
                self.assertEqual(v.call("ReadChar"), (ord("Z"), False))
                self.assertTrue(v.call("ReadChar")[1])

    def test_nul_line_endings_and_tabs(self):
        for width in (80, 90):
            v = Viewer(b"A\0B\tC\r\n\rX\nY\rZ", width=width)
            v.put("Position", 0)
            expected = [b"A.B     C", b"", b"X", b"Y", b"Z"]
            for line in expected:
                v.call("TextRow")
                self.assertEqual(v.line(), line)
            self.assertEqual(v.get("Position"), v.file.size)

    def test_exact_width_and_long_lines(self):
        for width in (80, 90):
            for eol in (b"\r", b"\n", b"\r\n"):
                v = Viewer(b"a" * width + eol + b"b" * (width * 3 + 7), width=width)
                v.put("Position", 0)
                for text in (b"a" * width, b"b" * width, b"b" * width, b"b" * width, b"b" * 7):
                    v.call("TextRow")
                    self.assertEqual(v.line(), text)

    def test_large_random_offsets_and_hex_tail(self):
        for size in (0, 1, 15, 16, 17, 511, 512, 513, 4095, 4096, 4097,
                     65535, 65536, 1048576 + 123, 0x1000000 + 7,
                     0x80000000 + 3, 0xFFFFFFFF):
            with self.subTest(size=size):
                v = Viewer(VirtualFile(size=size), detect=False)
                v.put("HexMode", 1, 1)
                v.call("GoEnd")
                expected = (size - 1) & ~15 if size else 0
                self.assertEqual(v.get("Top"), expected)
                v.put("Position", expected)
                v.call("HexRow")
                data = v.file.read(expected, 16)
                line = bytes(v.mem[v.s("LineBuffer"):v.s("LineBuffer") + 80])
                if size:
                    self.assertEqual(line[:8], f"{expected:08X}".encode())
                for col in range(16):
                    self.assertEqual(line[9 + col * 3:11 + col * 3],
                                     f"{data[col]:02X}".encode() if col < len(data) else b"  ")
                self.assertEqual(v.get("Position"), size)

    def test_forward_stream_and_backward_filex(self):
        v = Viewer(VirtualFile(size=4096 * 6), detect=False)
        for offset in (0, 4095, 4096, 8192, 100, 12288, 16384):
            v.put("Position", offset)
            self.assertEqual(v.call("ReadByte"), (v.file.read(offset, 1)[0], False))
        self.assertEqual([(kind, start) for kind, start, *_ in v.reads],
                         [("stream", 0), ("stream", 4096), ("stream", 8192),
                          ("position", 0), ("stream", 12288), ("stream", 16384)])

    def test_fallback_without_filex(self):
        v = Viewer(VirtualFile(size=9000), filex=False, detect=False)
        for offset in (8000, 15, 8999):
            v.put("Position", offset)
            self.assertEqual(v.call("ReadByte"), (v.file.read(offset, 1)[0], False))
        self.assertFalse(any(kind == "position" for kind, *_ in v.reads))

    def test_read_errors_and_short_transfers(self):
        for fault in ("short", "media", "count_high"):
            for positional in (False, True):
                if fault == "count_high" and not positional:
                    continue
                v = Viewer(VirtualFile(size=16000), detect=False)
                v.fault = fault
                v.put("Position", 8192 if positional else 0)
                self.assertTrue(v.call("ReadByte")[1])
                self.assertEqual(v.get("IoError", 1), 1)
                self.assertEqual(v.get("CacheValid", 1), 0)
                self.assertEqual(v.get("Position"), 8192 if positional else 0)

    def test_navigation_and_history_overflow(self):
        raw = b"".join(f"Line {number:04d}\r\n".encode() for number in range(600))
        v = Viewer(raw)
        v.draw()
        for _ in range(15):
            v.call("PageDown")
        self.assertGreater(v.get("Top"), 256 * 11)
        top = v.get("Top")
        v.call("GoUp")
        self.assertEqual(v.get("Top"), top - 11)
        v.put("HistCount", 0, 2)
        v.call("GoUp")
        self.assertEqual(v.get("Top"), top - 22)
        v.call("GoEnd")
        self.assertEqual(v.get("Top"), (600 - 23) * 11)
        v.call("GoHome")
        self.assertEqual(v.get("Top"), 0)

    def test_wrap_reverse_without_history(self):
        for width in (80, 90):
            for source in (b"x" * 730 + b"\r\ny\n", b"x\r\n\r\nz", b"\r\n\n\r"):
                v = Viewer(source, width=width)
                v.put("Position", 0)
                starts = []
                while v.get("Position") < len(source):
                    starts.append(v.get("Position"))
                    v.call("TextRow")
                for old, expected in zip(starts[1:] + [len(source)], starts):
                    v.put("HistCount", 0, 2)
                    v.put("Position", old)
                    v.call("PreviousRow")
                    self.assertEqual(v.get("Position"), expected, (width, old, source[:20]))

    def test_manual_encoding_cycle_and_bom(self):
        v = Viewer(b"\xef\xbb\xbf" + "Привет".encode())
        self.assertEqual(v.get("Top"), 3)
        for choice, enc, start in ((1, 0, 0), (2, 1, 0), (3, 2, 3), (0, 2, 3)):
            v.call("NextEncoding")
            self.assertEqual((v.get("Choice", 1), v.get("Encoding", 1), v.get("Top")), (choice, enc, start))
            label = b"Auto:" if choice == 0 else b"Man.:"
            self.assertEqual(bytes(v.screen[-1][5:10]), label)

    def test_footer_is_english_in_both_layouts(self):
        # Проверяем именно выведенную строку: раскладка WC не должна менять
        # нижний бар даже после переключения кодировки или появления статуса.
        for width in (80, 90):
            v = Viewer("Привет".encode(), width=width)
            for language in (0, 1):
                v.mem[0x781A] = language
                for choice in range(4):
                    v.put("Choice", choice, 1)
                    for enc, label in enumerate((b"CP866", b"CP1251", b"UTF-8")):
                        v.put("Encoding", enc, 1)
                        for status in (None, "IoError", "AllowCancel", "SearchAgain"):
                            with self.subTest(width=width, language=language,
                                              choice=choice, enc=enc, status=status):
                                for field in ("IoError", "AllowCancel", "SearchAgain"):
                                    v.put(field, 0, 1)
                                if status:
                                    v.put(status, 2 if status == "SearchAgain" else 1, 1)
                                v.call("DrawFooter")
                                footer = bytes(v.screen[-1])
                                self.assertTrue(all(32 <= byte < 127 for byte in footer))
                                self.assertIn(b"Auto:" if choice == 0 else b"Man.:", footer)
                                for expected in (label, b"F8:Enc", b"Tab:Mode", b"F1:Help"):
                                    self.assertIn(expected, footer)
                                expected = {None: b"         ", "IoError": b"READ ERR ",
                                            "AllowCancel": b"READING..", "SearchAgain": b"NOT FOUND"}[status]
                                self.assertEqual(footer[71:80], expected)

    def test_search_encoding_and_boundaries(self):
        query = "Тест №1"
        for codec, enc in (("cp866", 0), ("cp1251", 1), ("utf-8", 2)):
            raw_query = query.encode(codec)
            raw = b"x" * 4093 + raw_query + b" tail " + raw_query
            v = Viewer(raw, detect=False)
            v.put("Encoding", enc, 1)
            v.mem[v.s("InputBuffer"):v.s("InputBuffer") + 40] = query.encode("cp866").ljust(40, b" ")
            v.call("BuildSearch")
            length = v.get("SearchLength", 1)
            self.assertEqual(bytes(v.mem[v.s("SearchBuffer"):v.s("SearchBuffer") + length]), raw_query)
            v.call("BeginCommand")
            v.call("FindBytes")
            self.assertEqual(v.get("Top"), 4093)
            v.call("SearchNext")
            self.assertEqual(v.get("SearchStart"), 4093 + len(raw_query) + 6)
            v.call("SearchNext")
            self.assertEqual(v.get("SearchAgain", 1), 2)

    def test_cancel_and_preserved_registers(self):
        v = Viewer(VirtualFile(size=10485760), detect=False)
        v.cancel = True
        v.call("GoEnd")
        self.assertEqual(v.get("Top"), 0)
        self.assertEqual(v.reads, [])
        v.cancel = False
        v.put("Position", 4096)
        old_ix = v.m.ix
        v.call("ReadByte", bc=0x1234, de=0x4567, hl=0x789A)
        self.assertEqual((v.m.bc, v.m.de, v.m.hl, v.m.ix), (0x1234, 0x4567, 0x789A, old_ix))

    def test_esc_latched_during_filex_call(self):
        v = Viewer(VirtualFile(size=10485760), detect=False)
        v.escape_during_read = True
        v.call("GoEnd")
        self.assertEqual(v.get("Top"), 0)
        self.assertEqual(v.get("IoError", 1), 0)
        self.assertEqual(v.get("Cancelled", 1), 0)
        self.assertEqual(v.mem[0x6004], 0)
        self.assertIn((46,), v.calls)
        self.assertEqual(len(v.reads), 1)

    def test_help_is_english_in_both_layouts(self):
        v = Viewer(b"abc")
        for language in (0, 1, 0, 1):
            v.mem[0x781A] = language
            v.call("ShowHelp")
            title, bottom, body = v.messages[-1]
            self.assertEqual(title, b"Text & HEX Viewer")
            self.assertEqual(bottom, b"Press any key to close")
            self.assertIn(b"encoding", body)
            self.assertTrue(all(byte < 128 for byte in title + bottom + body))
            self.assertEqual(v.mem[0x781A], language)
            for line in body.split(b"\r"):
                self.assertLessEqual(len(line), 64)


if __name__ == "__main__":
    unittest.main(verbosity=2)
