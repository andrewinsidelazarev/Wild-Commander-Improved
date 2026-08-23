"""Машинные проверки логической границы штатного F5 COPYF."""
from __future__ import annotations

import re
from pathlib import Path

import z80


PROJECT_ROOT = Path(__file__).resolve().parents[2]
PAYLOAD = PROJECT_ROOT / "Build" / "boot.payload.bin"
SYMBOLS = PROJECT_ROOT / "Build" / "boot.sym"
PAYLOAD_BASE = 0x6011
RETURN_SENTINEL = 0xFF00
STACK_BASE = 0xFE00
BREAKPOINT_HIT = 1 << 1
SYMBOL_RE = re.compile(r"^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$")


def load_symbols() -> dict[str, int]:
    result: dict[str, int] = {}
    for line in SYMBOLS.read_text(encoding="utf-8").splitlines():
        match = SYMBOL_RE.match(line.strip())
        if match:
            result[match.group(1)] = int(match.group(2), 16)
    return result


def put16(memory: memoryview, address: int, value: int) -> None:
    memory[address] = value & 0xFF
    memory[address + 1] = value >> 8 & 0xFF


def get16(memory: memoryview, address: int) -> int:
    return memory[address] | memory[address + 1] << 8


def put32(memory: memoryview, address: int, value: int) -> None:
    put16(memory, address, value)
    put16(memory, address + 2, value >> 16)


def get32(memory: memoryview, address: int) -> int:
    return get16(memory, address) | get16(memory, address + 2) << 16


class BootHarness:
    def __init__(self) -> None:
        self.symbols = load_symbols()
        self.machine = z80.Z80Machine()
        self.memory = self.machine.memory
        self.machine.set_memory_block(PAYLOAD_BASE, PAYLOAD.read_bytes())
        core_source = self.symbols["WDOS.CORE32"]
        core_start = self.symbols["WDOS.START"]
        core_length = self.symbols["WDOS.END"] - core_start
        self.machine.set_memory_block(
            core_start,
            bytes(self.memory[core_source : core_source + core_length]),
        )
        self.machine.set_breakpoint(RETURN_SENTINEL)

    def address(self, name: str) -> int:
        return self.symbols[f"WCFX.{name}"]

    def wdos_address(self, name: str) -> int:
        return self.symbols[f"WDOS.{name}"]

    def invoke(self, address: int, *, hl: int = 0, de: int = 0, b: int = 0) -> None:
        self.machine.sp = STACK_BASE
        put16(self.memory, STACK_BASE, RETURN_SENTINEL)
        self.machine.pc = address
        self.machine.hl = hl
        self.machine.de = de
        self.machine.b = b
        while True:
            self.machine.ticks_to_stop = 1_000_000
            event = self.machine.run()
            if not event & BREAKPOINT_HIT:
                raise AssertionError(
                    f"Z80 остановился вне breakpoint: event={event}, "
                    f"pc=#{self.machine.pc:04X}"
                )
            if self.machine.pc == RETURN_SENTINEL:
                return
            raise AssertionError(f"неожиданный breakpoint #{self.machine.pc:04X}")


def expect(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: получено {actual!r}, ожидалось {expected!r}")


def expected_chunks(size: int) -> list[int]:
    chunks: list[int] = []
    remaining = size
    while remaining > 16 * 1024:
        chunks.append(32)
        remaining -= 16 * 1024
    if remaining:
        chunks.append((remaining + 511) // 512)
    return chunks


def test_copy_chunk() -> None:
    cases = (
        0,
        1,
        511,
        512,
        513,
        541,
        16 * 1024 - 1,
        16 * 1024,
        16 * 1024 + 1,
        32 * 1024,
        32 * 1024 + 17,
        0x00010000,
        0x01000001,
    )
    for size in cases:
        actual: list[int] = []

        if size == 0:
            harness = BootHarness()
            remaining_address = harness.address("LOBU") + 1
            put32(harness.memory, remaining_address, size)
            harness.invoke(harness.address("COPY_CHUNK"))
            expect("нулевой файл не запускает секторный API", harness.machine.b, 0)
            expect("нулевой файл является последним проходом", harness.machine.c, 1)
            continue

        remaining = size
        while True:
            # Один Z80Machine на один вызов: python-z80 намеренно подавляет
            # повторный breakpoint, завершивший предыдущий run().
            harness = BootHarness()
            remaining_address = harness.address("LOBU") + 1
            put32(harness.memory, remaining_address, remaining)
            before = remaining
            harness.invoke(harness.address("COPY_CHUNK"))
            count = harness.machine.b
            last = harness.machine.c
            if not 1 <= count <= 32:
                raise AssertionError(f"size={size}: недопустимый B={count}")
            actual.append(count)
            if last:
                expect(f"size={size}: последний остаток", before <= 16 * 1024, True)
                break
            remaining = get32(harness.memory, remaining_address)
            expect(
                f"size={size}: вычтен полный блок",
                remaining,
                before - 16 * 1024,
            )

        expect(f"size={size}: секторные проходы", actual, expected_chunks(size))

    harness = BootHarness()
    remaining_address = harness.address("LOBU") + 1
    put32(harness.memory, remaining_address, 0xFFFFFFFF)
    harness.invoke(harness.address("COPY_CHUNK"))
    expect("4-GiB граница: первый B", harness.machine.b, 32)
    expect("4-GiB граница: не последний", harness.machine.c, 0)
    expect(
        "4-GiB граница: остаток",
        get32(harness.memory, remaining_address),
        0xFFFFFFFF - 16 * 1024,
    )


def return_from_call(harness: BootHarness) -> None:
    return_address = get16(harness.memory, harness.machine.sp)
    harness.machine.sp = harness.machine.sp + 2 & 0xFFFF
    harness.machine.pc = return_address


def test_copy_loop_uses_chunk_counts() -> None:
    for size in (0, 1, 512, 513, 541, 16 * 1024, 16 * 1024 + 1, 32 * 1024 + 17):
        harness = BootHarness()
        remaining_address = harness.address("LOBU") + 1
        put32(harness.memory, remaining_address, size)

        # PBPR и SWPPAND не участвуют в выборе длины. RET оставляет машинный
        # стек и BC нетронутыми, а реальные LOAD512/SAVE512 перехватываются.
        harness.memory[harness.address("PBPR")] = 0xC9
        harness.memory[harness.address("SWPPAND")] = 0xC9
        load512 = harness.address("LOAD512")
        save512 = harness.address("SAVE512")
        rresb = harness.address("RRESB")
        for address in (load512, save512, rresb, RETURN_SENTINEL):
            harness.machine.set_breakpoint(address)

        loads: list[int] = []
        saves: list[int] = []
        harness.machine.sp = STACK_BASE
        put16(harness.memory, STACK_BASE, RETURN_SENTINEL)
        harness.machine.pc = harness.address("SVNG")
        harness.machine.ix = 0x1234

        while True:
            harness.machine.ticks_to_stop = 1_000_000
            event = harness.machine.run()
            if not event & BREAKPOINT_HIT:
                raise AssertionError(
                    f"size={size}: остановка вне breakpoint, "
                    f"pc=#{harness.machine.pc:04X}"
                )
            if harness.machine.pc == RETURN_SENTINEL:
                break
            if harness.machine.pc == load512:
                loads.append(harness.machine.b)
            elif harness.machine.pc == save512:
                saves.append(harness.machine.b)
            elif harness.machine.pc != rresb:
                raise AssertionError(
                    f"size={size}: неожиданный breakpoint #{harness.machine.pc:04X}"
                )
            harness.machine.a = 0
            harness.machine.f = 0x40
            return_from_call(harness)

        expected = expected_chunks(size)
        expect(f"size={size}: LOAD512 B", loads, expected)
        expect(f"size={size}: SAVE512 B", saves, expected)
        expect(f"size={size}: IX восстановлен", harness.machine.ix, 0x1234)


def test_compacted_helpers() -> None:
    for value in (0, 1, 63, 64, 65, 0xFFFF, 0x10000, 0xFFFFFFFF):
        harness = BootHarness()
        harness.invoke(
            harness.address("DEL64"),
            hl=value & 0xFFFF,
            de=value >> 16,
            b=0xA5,
        )
        actual = harness.machine.hl | harness.machine.de << 16
        expect(f"DEL64 value={value}", actual, value >> 6)

    mappings = {
        1: "TERC1",
        2: "TERC2",
        3: "TERC3",
        4: "TERC4",
        5: "TERC5",
        6: "TERC6",
        7: "TERD7",
        8: "TERD8",
        0: "TERCU",
        9: "TERCU",
        254: "TERCU",
    }
    for code, target in mappings.items():
        harness = BootHarness()
        harness.invoke(harness.address("FEEM2"), b=code)
        expect(f"FEEM2 B={code}", harness.machine.hl, harness.symbols[target])


def read_c_string(memory: memoryview, address: int, limit: int = 256) -> bytes:
    result = bytearray()
    for offset in range(limit):
        value = memory[address + offset]
        if value == 0:
            return bytes(result)
        result.append(value)
    raise AssertionError(f"строка по #{address:04X} не завершена за {limit} байт")


def test_sfn_name_output() -> None:
    cases = (
        (b"BOOT    $C ", 0x00, b"boot.$c"),
        (b"ONE     C  ", 0x00, b"one.c"),
        (b"TWO     GZ ", 0x00, b"two.gz"),
        (b"THREE   BIN", 0x00, b"three.bin"),
        (b"NOEXT      ", 0x00, b"noext"),
        (b"LEVEL1     ", 0x10, b"level1"),
    )
    for short_name, attr, expected in cases:
        harness = BootHarness()
        source = 0xB200
        output = 0xB300
        harness.memory[source : source + 11] = short_name
        harness.memory[source + 11] = attr
        harness.invoke(harness.wdos_address("Snm"), hl=source, de=output)
        expect(
            f"SFN {short_name!r}: NXTETY",
            read_c_string(harness.memory, output),
            expected,
        )
        expect(
            f"SFN {short_name!r}: DE после имени",
            harness.machine.de,
            output + len(expected) + 1,
        )


def test_copy_rename_name_normalization() -> None:
    cases = (
        b"boot.$c",
        b"one.c",
        b"two.gz",
        b"three.bin",
        b"noext",
        b"Long Name.GZ",
        b"Long Name.extension",
    )
    for panel_name in cases:
        harness = BootHarness()
        source = 0x9000
        source_payload = bytes((0x10,)) + panel_name + b"\0"
        harness.memory[source : source + len(source_payload)] = source_payload
        before = bytes(harness.memory[source : source + len(source_payload)])

        harness.invoke(harness.address("NAMEBG"), de=source)

        query = harness.address("LOBU") + 4
        expect(f"{panel_name!r}: тип запроса FENTRY", harness.memory[query], 0)
        expect(
            f"{panel_name!r}: NAMEBG сохраняет выдачу NXTETY",
            read_c_string(harness.memory, query + 1),
            panel_name,
        )
        expect(
            f"{panel_name!r}: панельная строка не изменена",
            bytes(harness.memory[source : source + len(source_payload)]),
            before,
        )
        expect(f"{panel_name!r}: HL NAMEBG", harness.machine.hl, source + 1)
        expect(
            f"{panel_name!r}: DE NAMEBG",
            harness.machine.de,
            query + 1 + 256,
        )
        expect(f"{panel_name!r}: BC NAMEBG", harness.machine.bc, 0)


def test_recursive_delete_uses_short_directory_alias() -> None:
    harness = BootHarness()
    start = harness.address("DDIRS")
    end = harness.address("NODIRS")
    block = bytes(harness.memory[start:end])
    marker = bytes((0x3E, 0x82, 0xD5, 0xCD, 0x5A, 0x40))
    expect(
        "DIRTREM перечисляет дочерний каталог как SFN для безопасного FENTRY/DELFL",
        block.count(marker),
        1,
    )


def main() -> int:
    symbols = load_symbols()
    required = (
        "WCFX.COPY_CHUNK",
        "WCFX.SVNG",
        "WCFX.PBPR",
        "WCFX.SWPPAND",
        "WCFX.DEL64",
        "WCFX.FEEM2",
        "WCFX.NAMEBG",
        "WCFX.DDIRS",
        "WCFX.NODIRS",
        "WCFX.LOAD512",
        "WCFX.SAVE512",
        "WCFX.RRESB",
        "WCFX.LOBU",
        "WDOS.CORE32",
        "WDOS.START",
        "WDOS.END",
        "WDOS.Snm",
        "TERC1",
        "TERC2",
        "TERC3",
        "TERC4",
        "TERC5",
        "TERC6",
        "TERD7",
        "TERD8",
        "TERCU",
    )
    missing = [name for name in required if name not in symbols]
    if missing:
        raise AssertionError("в boot.sym отсутствуют символы: " + ", ".join(missing))
    expect(
        "WCINI использует актуальный адрес WCFX.ERR0",
        symbols.get("WCINI.ERR0"),
        symbols["WCFX.ERR0"],
    )

    test_copy_chunk()
    test_copy_loop_uses_chunk_counts()
    test_compacted_helpers()
    test_sfn_name_output()
    test_copy_rename_name_normalization()
    test_recursive_delete_uses_short_directory_alias()
    print(
        "WCFX COPYF bounds PASS: logical sector counts, zero-size guard, "
        "32-bit remaining bytes, loop B values, DEL64, FEEM2 and "
        "NXTETY/F5/F6 short-extension name normalization and F8 LFN traversal"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
