"""Проверить машинный код постоянного LBA-кэша APPEND без запуска GUI Unreal."""
from __future__ import annotations

import re
from pathlib import Path

import z80


PROJECT_ROOT = Path(__file__).resolve().parents[2]
EXTENSION_BIN = PROJECT_ROOT / "Build" / "CORE32_EXT.bin"
EXTENSION_SYMBOLS = PROJECT_ROOT / "Build" / "CORE32_EXT.sym"
CORE_SYMBOLS = PROJECT_ROOT / "Build" / "CORE32_WDOS_SYMBOLS.INC"
EXTENSION_BASE = 0xC000
RETURN_SENTINEL = 0xFF00
STACK_BASE = 0xFE00
BREAKPOINT_HIT = 1 << 1

EXT_SYMBOL_RE = re.compile(r"^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$")
CORE_SYMBOL_RE = re.compile(r"^([A-Za-z0-9_]+)\s+EQU\s+(0x[0-9A-Fa-f]+)$")


def load_symbols(path: Path, pattern: re.Pattern[str]) -> dict[str, int]:
    result: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line.strip())
        if match:
            result[match.group(1)] = int(match.group(2), 16)
    return result


def get16(memory: memoryview, address: int) -> int:
    return memory[address] | memory[address + 1] << 8


def put16(memory: memoryview, address: int, value: int) -> None:
    memory[address] = value & 0xFF
    memory[address + 1] = value >> 8 & 0xFF


def get32(memory: memoryview, address: int) -> int:
    return get16(memory, address) | get16(memory, address + 2) << 16


def put32(memory: memoryview, address: int, value: int) -> None:
    put16(memory, address, value)
    put16(memory, address + 2, value >> 16)


class CacheHarness:
    def __init__(self) -> None:
        self.ext = load_symbols(EXTENSION_SYMBOLS, EXT_SYMBOL_RE)
        self.core = load_symbols(CORE_SYMBOLS, CORE_SYMBOL_RE)
        self.machine = z80.Z80Machine()
        self.memory = self.machine.memory
        self.machine.set_memory_block(EXTENSION_BASE, EXTENSION_BIN.read_bytes())

        # APPEND_POSITION_SECTOR вызывает PROZ только для передачи вычисленного
        # LBA драйверу. RET сохраняет DE:HL, позволяя проверить точный результат.
        self.memory[self.core["PROZ"]] = 0xC9
        self.machine.set_breakpoint(self.core["GIPAG"])
        self.machine.set_breakpoint(RETURN_SENTINEL)

    def ext_address(self, name: str) -> int:
        return self.ext[f"WDOS_EXT.{name}"]

    def invoke_position(self) -> tuple[int, int]:
        self.machine.sp = STACK_BASE
        put16(self.memory, STACK_BASE, RETURN_SENTINEL)
        self.machine.pc = self.ext_address("APPEND_POSITION_SECTOR")
        gipag_calls = 0

        while True:
            self.machine.ticks_to_stop = 1_000_000
            event = self.machine.run()
            if not event & BREAKPOINT_HIT:
                raise AssertionError(
                    f"Z80 остановился вне breakpoint: event={event}, "
                    f"pc=#{self.machine.pc:04X}"
                )
            if self.machine.pc == RETURN_SENTINEL:
                break
            if self.machine.pc != self.core["GIPAG"]:
                raise AssertionError(f"Неожиданный breakpoint #{self.machine.pc:04X}")

            gipag_calls += 1
            current = get32(
                self.memory, self.ext_address("APPEND_WORK_CURRENT")
            )
            sectors_per_cluster = self.memory[self.core["BSECPC"]]
            data_start = get32(self.memory, self.core["SDFAT"])
            partition_start = get32(self.memory, self.core["ADDTOP"])
            base_lba = (
                partition_start
                + data_start
                + (current - 2) * sectors_per_cluster
            ) & 0xFFFFFFFF
            put32(self.memory, self.core["LTHL"], base_lba)

            return_address = get16(self.memory, self.machine.sp)
            self.machine.sp = self.machine.sp + 2 & 0xFFFF
            self.machine.a = 0
            self.machine.f = 0x40  # Z: успешный GIPAG
            self.machine.pc = return_address

        target_lba = self.machine.hl | self.machine.de << 16
        return gipag_calls, target_lba


def expect(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: получено {actual!r}, ожидалось {expected!r}")


def main() -> int:
    harness = CacheHarness()
    memory = harness.memory
    ext = harness.ext_address
    core = harness.core

    cluster = 42
    sectors_per_cluster = 8
    data_start = 0x00123400
    partition_start = 0x00010000
    base_lba = (
        partition_start + data_start + (cluster - 2) * sectors_per_cluster
    )
    put32(memory, ext("APPEND_WORK_CURRENT"), cluster)
    memory[ext("APPEND_WORK_SECTOR")] = 3
    memory[ext("APPEND_WORK_LBA_VALID")] = 0
    memory[core["BSECPC"]] = sectors_per_cluster
    put32(memory, core["SDFAT"], data_start)
    put32(memory, core["ADDTOP"], partition_start)

    calls, target = harness.invoke_position()
    expect("первый промах GIPAG", calls, 1)
    expect("LBA первого сектора", target, base_lba + 3)
    expect("VALID после промаха", memory[ext("APPEND_WORK_LBA_VALID")], 1)

    # Смоделировать успешный commit и начало следующего APPEND: именно эти два
    # LDIR выполняет production-код с APPEND_CONTEXT_SIZE.
    context_size = harness.ext["WDOS_EXT.APPEND_CONTEXT_SIZE"]
    persistent = ext("APPEND_CONTEXT")
    working = ext("APPEND_WORK_CONTEXT")
    memory[persistent : persistent + context_size] = memory[
        working : working + context_size
    ]
    memory[working : working + context_size] = bytes(context_size)
    memory[working : working + context_size] = memory[
        persistent : persistent + context_size
    ]
    memory[ext("APPEND_WORK_SECTOR")] = 4
    put32(memory, core["CUHL"], 0xFFFFFFFF)
    put32(memory, core["CLHL"], 0xFFFFFFFF)
    put32(memory, core["LTHL"], 0xFFFFFFFF)
    memory[core["NSDC"]] = 7
    memory[core["EOC"]] = 0x0F

    calls, target = harness.invoke_position()
    expect("межвызовное попадание GIPAG", calls, 0)
    expect("LBA после переноса контекста", target, base_lba + 4)
    expect("CUHL после попадания", get32(memory, core["CUHL"]), cluster)
    expect("CLHL после попадания", get32(memory, core["CLHL"]), base_lba)
    expect("LTHL после попадания", get32(memory, core["LTHL"]), base_lba)
    expect("NSDC после попадания", memory[core["NSDC"]], 0)
    expect("EOC после попадания", memory[core["EOC"]], 0)

    # Даже забытая явная инвалидизация не должна использовать базу другого
    # кластера: ключ кэша обязан превратить это в безопасный промах.
    cluster += 1
    put32(memory, ext("APPEND_WORK_CURRENT"), cluster)
    memory[ext("APPEND_WORK_SECTOR")] = 0
    base_lba = (
        partition_start + data_start + (cluster - 2) * sectors_per_cluster
    )
    calls, target = harness.invoke_position()
    expect("промах после смены кластера", calls, 1)
    expect("LBA нового кластера", target, base_lba)

    sectors_per_cluster = 16
    memory[core["BSECPC"]] = sectors_per_cluster
    base_lba = (
        partition_start + data_start + (cluster - 2) * sectors_per_cluster
    )
    calls, target = harness.invoke_position()
    expect("промах после смены секторов в кластере", calls, 1)
    expect("LBA новой кластерной геометрии", target, base_lba)

    data_start += 0x2000
    put32(memory, core["SDFAT"], data_start)
    base_lba = (
        partition_start + data_start + (cluster - 2) * sectors_per_cluster
    )
    calls, target = harness.invoke_position()
    expect("промах после смены начала области данных", calls, 1)
    expect("LBA новой области данных", target, base_lba)

    partition_start += 0x4000
    put32(memory, core["ADDTOP"], partition_start)
    base_lba = (
        partition_start + data_start + (cluster - 2) * sectors_per_cluster
    )
    calls, target = harness.invoke_position()
    expect("промах после смены начала раздела", calls, 1)
    expect("LBA нового раздела", target, base_lba)

    calls, target = harness.invoke_position()
    expect("повторное попадание GIPAG", calls, 0)
    expect("повторный LBA", target, base_lba)

    print(
        "APPEND LBA cache unit PASS: "
        "miss=1, persistent-hit=0, cluster-miss=1, spc-miss=1, "
        "data-start-miss=1, partition-miss=1, hit=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
