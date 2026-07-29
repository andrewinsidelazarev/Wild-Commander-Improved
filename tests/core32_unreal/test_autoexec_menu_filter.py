"""Проверить автозапуск #06 и удаление его заголовка из меню плагинов."""
from __future__ import annotations

import re
from pathlib import Path

import z80


PROJECT_ROOT = Path(__file__).resolve().parents[2]
PAYLOAD = PROJECT_ROOT / "Build" / "boot.payload.bin"
SYMBOLS = PROJECT_ROOT / "Build" / "boot.sym"
PAYLOAD_BASE = 0x6011
HEADER_BASE = 0xC000
HEADER_SIZE = 512
TYPE_OFFSET = 197
RETURN_SENTINEL = 0xFF00
STACK_BASE = 0xFE00
COUNTERS = 0xF000
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


def counter_stub(last_address: int, count_address: int) -> bytes:
    """LD (last),A; LD A,(count); INC A; LD (count),A; RET."""
    return bytes(
        (
            0x32,
            last_address & 0xFF,
            last_address >> 8,
            0x3A,
            count_address & 0xFF,
            count_address >> 8,
            0x3C,
            0x32,
            count_address & 0xFF,
            count_address >> 8,
            0xC9,
        )
    )


def run_case(symbols: dict[str, int], types: list[int]) -> None:
    machine = z80.Z80Machine()
    memory = machine.memory
    machine.set_memory_block(PAYLOAD_BASE, PAYLOAD.read_bytes())

    ajt_last = COUNTERS
    ajt_count = COUNTERS + 1
    mngc_last = COUNTERS + 2
    mngc_count = COUNTERS + 3
    memory[symbols["AX_AJT"] : symbols["AX_AJT"] + 11] = counter_stub(
        ajt_last, ajt_count
    )
    memory[symbols["AX_MNGC"] : symbols["AX_MNGC"] + 11] = counter_stub(
        mngc_last, mngc_count
    )

    headers: list[bytes] = []
    for index, plugin_type in enumerate(types):
        header = bytearray([0x30 + index] * HEADER_SIZE)
        header[TYPE_OFFSET] = plugin_type
        headers.append(bytes(header))
        start = HEADER_BASE + index * HEADER_SIZE
        memory[start : start + HEADER_SIZE] = header

    put16(memory, symbols["PHED"], HEADER_BASE + len(headers) * HEADER_SIZE)
    memory[0x6003] = 0x22
    machine.sp = STACK_BASE
    put16(memory, STACK_BASE, RETURN_SENTINEL)
    machine.pc = symbols["AX_RUN"]
    machine.set_breakpoint(RETURN_SENTINEL)

    while True:
        machine.ticks_to_stop = 1_000_000
        event = machine.run()
        if not event & BREAKPOINT_HIT:
            raise AssertionError(
                f"Z80 остановился вне breakpoint: event={event}, "
                f"pc=#{machine.pc:04X}"
            )
        if machine.pc == RETURN_SENTINEL:
            break

    expected_headers = [
        header for header, plugin_type in zip(headers, types) if plugin_type != 0x06
    ]
    expected_end = HEADER_BASE + len(expected_headers) * HEADER_SIZE
    actual_end = memory[symbols["PHED"]] | memory[symbols["PHED"] + 1] << 8
    if actual_end != expected_end:
        raise AssertionError(
            f"PHED: ожидалось #{expected_end:04X}, получено #{actual_end:04X}; "
            f"AJT={memory[ajt_count]}, MNGC={memory[mngc_count]}"
        )

    for index, expected in enumerate(expected_headers):
        start = HEADER_BASE + index * HEADER_SIZE
        actual = bytes(memory[start : start + HEADER_SIZE])
        if actual != expected:
            raise AssertionError(f"нарушен порядок заголовков, слот {index}")

    expected_runs = types.count(0x06)
    if memory[ajt_count] != expected_runs:
        raise AssertionError(
            f"AJT: ожидалось запусков {expected_runs}, получено {memory[ajt_count]}"
        )
    if expected_runs and memory[ajt_last] != 0x06:
        raise AssertionError(f"AJT получил A=#{memory[ajt_last]:02X}, ожидалось #06")
    if memory[mngc_count] != expected_runs + 2:
        raise AssertionError(
            f"MNGC: ожидалось вызовов {expected_runs + 2}, "
            f"получено {memory[mngc_count]}"
        )
    if memory[mngc_last] != 0x22:
        raise AssertionError(
            f"не восстановлена страница #C000: A=#{memory[mngc_last]:02X}"
        )


def main() -> int:
    symbols = load_symbols()
    for required in ("AX_RUN", "AX_AJT", "AX_MNGC", "PHED"):
        if required not in symbols:
            raise AssertionError(f"в boot.sym отсутствует {required}")

    # Средние записи проверяют сдвиг хвоста, последняя — безопасную ветку BC=0,
    # а единственная #06 — полное опустошение видимой таблицы.
    for types in ([0x03, 0x06, 0x06, 0x04], [0x03, 0x04, 0x06], [0x06]):
        run_case(symbols, list(types))

    print("AUTOEXEC menu filter PASS: each type #06 ran once and stayed out of menu")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
