"""Execute TXTEDIT editing and rendering code with WC memory/UI API shims.

The Z80 runs the assembled plugin, including REFRESH. Only WC page mapping and
screen-address APIs are supplied here; this is not a full WC or hardware test.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import test_txtedit_safety as safety


PAGE_SIZE = 0x4000
TEXT_SIZE = 64 * PAGE_SIZE
STACK = 0x7E00
RETURN = 0x7F00


class Editor(safety.MachineHarness):
    def __init__(self, text: bytes, cursor: int, highlight: bool = False,
                 view_start: int = 0) -> None:
        super().__init__()
        self.machine.clear_breakpoint(safety.RETURN_SENTINEL)
        self.machine.set_breakpoint(RETURN)
        # The gap contains stale bytes, not a zero-filled EOF sentinel. A real
        # cursor move also leaves the consumed suffix in its old physical slot.
        self.banks = {("text", p): bytearray(b"~" * PAGE_SIZE) for p in range(64)}
        self.banks[("plugin", 1)] = bytearray(PAGE_SIZE)
        self.banks[("screen", 0)] = bytearray(PAGE_SIZE)
        self.mappings: dict[int, tuple[str, int]] = {}
        self.snapshots: dict[int, bytes] = {}
        if not 0 <= cursor <= len(text) < TEXT_SIZE - 1:
            raise ValueError("invalid fixture")
        self.write_text(TEXT_SIZE - len(text), text)
        self.write_text(0, text[:cursor])
        self.write_text(TEXT_SIZE - len(text) + cursor, text[cursor:])
        self.set_pointer("LHLCR", cursor)
        self.set_pointer("RHLCR", TEXT_SIZE - len(text) + cursor - 1)
        self.set_pointer("PGHLP", view_start)
        self.machine.ix = self.symbols["PLWND"]
        self.memory[self.machine.ix + 4] = 80
        self.memory[self.machine.ix + 5] = 25
        self.memory[self.symbols["HIGHLGT"]] = int(highlight)
        self.api_calls = 0
        self.invoke("DETECT_EOL")
        self.invoke("REFRESH")
        self.invoke("SYNC_COLUMN")

    def write_text(self, offset: int, data: bytes) -> None:
        for i, byte in enumerate(data, offset):
            self.banks[("text", i // PAGE_SIZE)][i % PAGE_SIZE] = byte

    def set_pointer(self, name: str, value: int) -> None:
        address = self.symbols[name]
        safety.put16(self.memory, address, value % PAGE_SIZE)
        self.memory[address + 2] = value // PAGE_SIZE

    def pointer(self, name: str) -> int:
        address = self.symbols[name]
        return safety.get16(self.memory, address) + self.memory[address + 2] * PAGE_SIZE

    def flush(self) -> None:
        # Merge changes, including when two windows map the same physical page.
        for base, key in self.mappings.items():
            current = bytes(self.memory[base:base + PAGE_SIZE])
            previous = self.snapshots[base]
            if current != previous:
                bank = self.banks[key]
                for i, (new, old) in enumerate(zip(current, previous)):
                    if new != old:
                        bank[i] = new
        for base, key in self.mappings.items():
            current = bytes(self.banks[key])
            self.memory[base:base + PAGE_SIZE] = current
            self.snapshots[base] = current

    def map(self, base: int, key: tuple[str, int]) -> None:
        self.flush()
        if key not in self.banks:
            raise AssertionError(f"out-of-range mapping: {key}")
        self.mappings[base] = key
        current = bytes(self.banks[key])
        self.memory[base:base + PAGE_SIZE] = current
        self.snapshots[base] = current

    def api(self) -> None:
        self.api_calls += 1
        api = self.machine.a
        if api in (0, 65, 80):
            # EX AF,AF' is the first instruction in the real WC dispatcher.
            # Read the alternate AF from the Z80 state layout via the wrapper's
            # equivalent swap, then restore normal AF before returning.
            self.memory[0x7000:0x7002] = b"\x08\xc9"
            saved_pc = self.machine.pc
            saved_sp = self.machine.sp
            self.machine.sp = 0x7100
            safety.put16(self.memory, 0x7100, RETURN)
            self.machine.pc = 0x7000
            for _ in range(3):
                self.machine.ticks_to_stop = 1000
                self.machine.run()
                if self.machine.pc == RETURN:
                    break
            else:
                raise AssertionError("WC dispatcher AF exchange did not return")
            argument = self.machine.a
            self.machine.sp = saved_sp
            self.machine.pc = saved_pc
            key = ("plugin", argument) if api == 0 else ("text", argument)
            self.map(0 if api == 80 else 0xC000, key)
        elif api == 5:  # GADRW, including the TXT mapping done by WC
            self.map(0xC000, ("screen", 0))
            self.machine.hl = 0xC000 + self.machine.d * 256 + self.machine.e
        else:
            raise AssertionError(f"unexpected WC API {api}")
        self.machine.a = 0
        self.machine.f = 0x40

    def invoke(self, symbol: str, a: int = 0, de: int = 0, hl: int = 0,
               stop: str | None = None) -> None:
        stops = {RETURN}
        if stop:
            stops.add(self.symbols[stop])
            self.machine.set_breakpoint(self.symbols[stop])
        self.machine.sp = STACK
        safety.put16(self.memory, STACK, RETURN)
        self.machine.pc = self.symbols[symbol]
        self.machine.a, self.machine.de, self.machine.hl = a, de, hl
        for _ in range(250000):
            # A tail JP to an API can return directly to RETURN. The Z80
            # wrapper executes one instruction when resuming a breakpoint.
            if self.machine.pc in stops:
                if stop:
                    self.machine.clear_breakpoint(self.symbols[stop])
                self.flush()
                return
            self.machine.ticks_to_stop = 100_000
            event = self.machine.run()
            if not event & safety.BREAKPOINT_HIT:
                continue
            if self.machine.pc in stops:
                if stop:
                    self.machine.clear_breakpoint(self.symbols[stop])
                self.flush()
                return
            if self.machine.pc != safety.WLD:
                # This Z80 wrapper may report a breakpoint on the return
                # address immediately after CALL, with PC already in the callee.
                # Finish that call before treating the requested stop as reached.
                if stop and safety.get16(self.memory, self.machine.sp) == self.symbols[stop]:
                    continue
                raise AssertionError(f"unexpected PC {self.machine.pc:04x}")
            self.api()
            self.return_from_api()
        raise AssertionError(f"{symbol} did not finish, PC={self.machine.pc:04x}")

    def text(self) -> bytes:
        self.flush()
        data = b"".join(bytes(self.banks[("text", p)]) for p in range(64))
        return data[:self.pointer("LHLCR")] + data[self.pointer("RHLCR") + 1:]

    def row(self, number: int) -> bytes:
        self.flush()
        start = (number + 1) * 256
        screen = self.banks[("screen", 0)]
        # Highlighted rendering clears unused attributes instead of glyphs.
        return bytes(screen[start + i] if screen[start + i + 128] else 32
                     for i in range(80)).rstrip(b" ")

    def expect_screen(self, expected: bytes) -> None:
        lines = expected.split(b"\r")
        for row in range(23):
            safety.expect(f"screen row {row}", self.row(row),
                          lines[row][:80].rstrip(b" ") if row < len(lines) else b"")


def test_eof_typing() -> None:
    for highlight in (False, True):
        for text in (b"", b"x", b"abc", b"a\r", b"a\rbc"):
            for overwrite in (False, True):
                editor = Editor(text, len(text), highlight)
                editor.memory[editor.symbols["INOV"]] = int(overwrite)
                editor.invoke("SMBADD", a=ord("Z"))
                safety.expect(f"append {text!r}, OVR={overwrite}", editor.text(), text + b"Z")
                editor.expect_screen(text + b"Z")


def test_eof_backspace() -> None:
    for highlight in (False, True):
        for text in (b"", b"x", b"abc", b"a\r", b"a\rbc"):
            editor = Editor(text, len(text), highlight)
            expected = text
            for _ in range(len(text) + 2):
                editor.invoke("BSPACE")
                expected = expected[:-1]
                safety.expect("backspace contents", editor.text(), expected)
                editor.expect_screen(expected)
            editor.invoke("SMBADD", a=ord("Q"))
            safety.expect("type after deleting all contents", editor.text(), b"Q")
            editor.expect_screen(b"Q")


def test_delete_at_eof() -> None:
    for text in (b"", b"abc", b"abc\r"):
        editor = Editor(text, len(text))
        editor.invoke("DELETE")
        safety.expect("Delete at EOF contents", editor.text(), text)
        safety.expect("Delete at EOF changed flag", editor.memory[editor.symbols["CHANGES"]], 0)
        editor.expect_screen(text)


def test_delete_last_character() -> None:
    for highlight in (False, True):
        for text in (b"x", b"abc", b"abc\r", b"abc\rd"):
            editor = Editor(text, len(text) - 1, highlight)
            editor.invoke("DELETE")
            safety.expect("delete last character contents", editor.text(), text[:-1])
            editor.expect_screen(text[:-1])
            editor.invoke("SMBADD", a=ord("Q"))
            safety.expect("type after deleting last character", editor.text(), text[:-1] + b"Q")
            editor.expect_screen(text[:-1] + b"Q")


def test_render_eof() -> None:
    for highlight in (False, True):
        for text in (b"", b"x", b"abc", b"a\r", b"a\rbc"):
            editor = Editor(text, len(text), highlight)
            expected = text.split(b"\r")
            for row in range(5):
                safety.expect(f"EOF row {row}, highlight={highlight}, text={text!r}",
                              editor.row(row), expected[row] if row < len(expected) else b"")


def test_eof_enter() -> None:
    for text in (b"", b"x", b"a\r"):
        editor = Editor(text, len(text))
        editor.invoke("GO0D")
        safety.expect("Enter at EOF contents", editor.text(), text + b"\r")
        editor.expect_screen(text + b"\r")


def test_overwrite_inside_text() -> None:
    for text, cursor, expected in ((b"abc", 1, b"aZc"),
                                   (b"ab\rc", 2, b"abZ\rc")):
        editor = Editor(text, cursor)
        editor.memory[editor.symbols["INOV"]] = 1
        editor.invoke("SMBADD", a=ord("Z"))
        safety.expect("overwrite inside text", editor.text(), expected)
        editor.expect_screen(expected)


def test_page_boundary_editing() -> None:
    for highlight in (False, True):
        for end in (0x3FFE, 0x3FFF, 0x4000, 0x4001, 0x7FFF, 0x8000):
            prefix = b"p\r" * ((end - 8) // 2)
            expected = prefix + b"A" * (end - len(prefix))
            editor = Editor(expected, end, highlight, view_start=len(prefix))
            for operation, byte in (("SMBADD", ord("Z")), ("GO0D", 13),
                                    ("SMBADD", ord("Q")), ("BSPACE", 0),
                                    ("BSPACE", 0), ("BSPACE", 0),
                                    ("BSPACE", 0), ("SMBADD", ord("R"))):
                editor.invoke(operation, a=byte)
                expected = expected[:-1] if operation == "BSPACE" else expected + bytes((byte,))
                safety.expect(f"{operation} near page {end:#x}", editor.text(), expected)
                editor.expect_screen(expected[len(prefix):])


def test_crossing_screen_bottom() -> None:
    for highlight in (False, True):
        expected = b"line\r" * 21 + b"last"
        editor = Editor(expected, len(expected), highlight)
        for operation, byte in (("GO0D", 13), ("SMBADD", ord("Z")),
                                ("BSPACE", 0), ("BSPACE", 0),
                                ("BSPACE", 0), ("SMBADD", ord("Q"))):
            editor.invoke(operation, a=byte)
            expected = expected[:-1] if operation == "BSPACE" else expected + bytes((byte,))
            safety.expect("edit on bottom screen line", editor.text(), expected)
            editor.expect_screen(expected[editor.pointer("PGHLP"):])


def test_empty_file_initialization() -> None:
    for new_file in (False, True):
        editor = Editor(b"", 0)
        editor.memory[editor.symbols["F10MENU"]] = int(new_file)
        editor.memory[editor.symbols["DAHL"]:editor.symbols["DAHL"] + 4] = bytes(4)
        editor.invoke("LOAD")
        safety.expect("empty file must not gain a placeholder", editor.text(), b"")
        editor.invoke("SMBADD", a=ord("Q"))
        safety.expect("first typed character has no extra space", editor.text(), b"Q")
        editor.expect_screen(b"Q")


def test_save_empty_document() -> None:
    editor = Editor(b"Z", 1)
    editor.invoke("BSPACE")
    editor.invoke("PRTOSV")
    safety.expect("empty document normalized size", (editor.machine.de, editor.machine.hl), (0, 0))
    editor.memory[editor.symbols["DAHL"]:editor.symbols["DAHL"] + 4] = bytes(4)
    editor.invoke("FILE_SIZE_COPY")
    safety.expect("empty document on-disk size", safety.get32(editor.memory, editor.symbols["FLMAKE"] + 1), 0)
    editor.invoke("SAVEDAT")  # Zero bytes must not invoke any disk/page API.
    safety.expect("empty SAVE512 result", bool(editor.machine.f & 0x40), True)
    editor.invoke("TOWORK")
    safety.expect("restored empty editing buffer", editor.text(), b"")
    editor.invoke("SMBADD", a=ord("Q"))
    safety.expect("typing after empty save", editor.text(), b"Q")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--symbols", type=Path)
    args = parser.parse_args()
    if args.binary:
        safety.TXTEDIT_BIN = args.binary
    if args.symbols:
        safety.TXTEDIT_SYMBOLS = args.symbols
    failed = 0
    tests = (test_render_eof, test_eof_typing, test_eof_backspace,
             test_delete_at_eof, test_delete_last_character, test_eof_enter,
             test_overwrite_inside_text, test_page_boundary_editing,
             test_crossing_screen_bottom, test_empty_file_initialization,
             test_save_empty_document)
    for test in tests:
        try:
            test()
            print(f"PASS {test.__name__}")
        except AssertionError as error:
            failed += 1
            print(f"FAIL {test.__name__}: {error}")
    print(f"TXTEDIT editing: {len(tests) - failed}/{len(tests)} passed")
    return int(failed != 0)


if __name__ == "__main__":
    raise SystemExit(main())
