"""Исполнить машинный код FAT allocator hint без запуска GUI Unreal."""
from __future__ import annotations

import re
from pathlib import Path

import z80


PROJECT_ROOT = Path(__file__).resolve().parents[2]
BUILD = PROJECT_ROOT / "Build"
CORE_SOURCE = PROJECT_ROOT / "source" / "CORE32.ASM"
EXTENSION_BASE = 0xC000
RETURN_SENTINEL = 0xFF00
STACK_BASE = 0xFE00
BREAKPOINT_HIT = 1 << 1
ZERO_FLAG = 0x40

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


def expect(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: получено {actual!r}, ожидалось {expected!r}")


def make_fsinfo(next_free: int, *, valid: bool = True) -> bytes:
    sector = bytearray(512)
    put32(memoryview(sector), 0, 0x41615252 if valid else 0)
    put32(memoryview(sector), 484, 0x61417272)
    put32(memoryview(sector), 488, 0xFFFFFFFF)
    put32(memoryview(sector), 492, next_free)
    put32(memoryview(sector), 508, 0xAA550000)
    return bytes(sector)


class ExtensionHarness:
    def __init__(self) -> None:
        self.ext = load_symbols(BUILD / "CORE32_EXT.sym", EXT_SYMBOL_RE)
        self.core = load_symbols(BUILD / "CORE32_WDOS_SYMBOLS.INC", CORE_SYMBOL_RE)
        self.machine = z80.Z80Machine()
        self.memory = self.machine.memory
        self.machine.set_memory_block(
            EXTENSION_BASE, (BUILD / "CORE32_EXT.bin").read_bytes()
        )
        self.read_sector = make_fsinfo(2)
        self.sector_overrides: dict[int, bytes] = {}
        self.position = 0
        self.read_calls: list[tuple[int, int, int]] = []
        self.fat_entries: dict[int, int] = {}
        self.curit_calls: list[int] = []
        self.written_sectors: list[bytes] = []
        self.mock_mksg_hint = 0
        self.callouts = {
            self.core["XPOZI"]: self._position,
            self.core["XSPOZ"]: self._return,
            self.core["RDDSE"]: self._read,
            self.core["SDDSE"]: self._write,
            self.core["ADD4B"]: self._add4b,
            self.core["DEL128"]: self._del128,
            self.core["CURIT"]: self._curit,
            self.core["MKSG"]: self._mksg,
        }
        for address in self.callouts:
            self.machine.set_breakpoint(address)
        self.machine.set_breakpoint(RETURN_SENTINEL)

    def ext_address(self, name: str) -> int:
        return self.ext[f"WDOS_EXT.{name}"]

    def _return(self) -> None:
        return_address = get16(self.memory, self.machine.sp)
        self.machine.sp = self.machine.sp + 2 & 0xFFFF
        self.machine.pc = return_address

    def _position(self) -> None:
        self.position = self.machine.de << 16 | self.machine.hl
        self._return()

    def _read(self) -> None:
        target = self.machine.hl
        count = self.machine.a
        self.read_calls.append((self.position, count, target))
        for index in range(count):
            sector = self.sector_overrides.get(
                self.position + index, self.read_sector
            )
            start = target + index * 512
            self.memory[start : start + 512] = sector
        self.memory[self.core["ABT"]] = 0
        self._return()

    def _write(self) -> None:
        source = self.machine.hl
        self.written_sectors.append(bytes(self.memory[source : source + 512]))
        self.memory[self.core["ABT"]] = 0
        self._return()

    def _add4b(self) -> None:
        value = ((self.machine.de << 16) | self.machine.hl) + self.machine.bc
        self.machine.hl = value & 0xFFFF
        self.machine.de = value >> 16 & 0xFFFF
        self.machine.f &= ~1
        self._return()

    def _del128(self) -> None:
        value = self.machine.de << 16 | self.machine.hl
        quotient, remainder = divmod(value, 128)
        self.machine.hl = quotient & 0xFFFF
        self.machine.de = quotient >> 16 & 0xFFFF
        self.machine.bc = remainder
        self.machine.a = remainder
        self.machine.f = ZERO_FLAG if remainder == 0 else 0
        self._return()

    def _curit(self) -> None:
        cluster = self.machine.de << 16 | self.machine.hl
        self.curit_calls.append(cluster)
        pointer = self.core["SECBU"]
        put32(self.memory, pointer, self.fat_entries.get(cluster, 0))
        self.machine.hl = pointer
        self.machine.f &= ~1
        self._return()

    def _mksg(self) -> None:
        if self.mock_mksg_hint < 2:
            raise AssertionError("ALLOCATE_FILE неожиданно вызвал MKSG без mock hint")
        put32(self.memory, self.core["FSTFRC"], self.mock_mksg_hint)
        self.machine.a = 0
        self.machine.f = ZERO_FLAG
        self._return()

    def invoke(self, name: str) -> None:
        self.machine.sp = STACK_BASE
        put16(self.memory, STACK_BASE, RETURN_SENTINEL)
        self.machine.pc = self.ext_address(name)
        while True:
            self.machine.ticks_to_stop = 2_000_000
            event = self.machine.run()
            if not event & BREAKPOINT_HIT:
                raise AssertionError(
                    f"Z80 остановился вне breakpoint: event={event}, "
                    f"pc=#{self.machine.pc:04X}"
                )
            if self.machine.pc == RETURN_SENTINEL:
                return
            handler = self.callouts.get(self.machine.pc)
            if handler is None:
                raise AssertionError(f"Неожиданный breakpoint #{self.machine.pc:04X}")
            handler()

    def configure_volume(self, next_free: int, *, valid_fsinfo: bool = True) -> int:
        lobu = self.core["LOBU"]
        total_sectors = 204_800
        first_data_sector = 1_600
        data_limit = total_sectors - first_data_sector + 2
        self.memory[lobu : lobu + 512] = bytes(512)
        put16(self.memory, lobu + 19, 0)
        put32(self.memory, lobu + 32, total_sectors)
        put32(self.memory, self.core["SDFAT"], first_data_sector)
        put16(self.memory, self.core["SFAT"], 32)
        put32(self.memory, self.core["BFTSZ"], 1_600)
        self.memory[self.core["BSECPC"]] = 1
        self.memory[self.core["BFATS"]] = 1
        self.memory[self.core["FATFLAGS"]] = 0
        put32(self.memory, self.core["FSINF"], 1)
        self.read_sector = make_fsinfo(next_free, valid=valid_fsinfo)
        self.sector_overrides.clear()
        self.read_calls.clear()
        self.fat_entries.clear()
        self.curit_calls.clear()
        return data_limit


class FilexHarness:
    def __init__(self) -> None:
        self.symbols = load_symbols(BUILD / "FILEX.sym", EXT_SYMBOL_RE)
        self.core = load_symbols(BUILD / "CORE32_WDOS_SYMBOLS.INC", CORE_SYMBOL_RE)
        self.machine = z80.Z80Machine()
        self.memory = self.machine.memory
        runtime = (BUILD / "FILEX.WMF").read_bytes()[512:]
        self.machine.set_memory_block(EXTENSION_BASE, runtime)
        self.current_fat_sector = 0
        self.sectors: dict[int, bytes] = {}
        self.read_sectors: list[int] = []
        self.callouts = {
            self.core["EXTENSION_GATE"]: self._extension,
        }
        for address in self.callouts:
            self.machine.set_breakpoint(address)
        self.machine.set_breakpoint(RETURN_SENTINEL)

    def address(self, name: str) -> int:
        return self.symbols[name]

    def _return(self) -> None:
        return_address = get16(self.memory, self.machine.sp)
        self.machine.sp = self.machine.sp + 2 & 0xFFFF
        self.machine.pc = return_address

    def _extension(self) -> None:
        return_address = get16(self.memory, self.machine.sp)
        extension_id = self.memory[return_address]
        put16(self.memory, self.machine.sp, return_address + 1)
        if extension_id == 7:  # ID_POSITION_FAT_READ
            self.current_fat_sector = self.machine.de << 16 | self.machine.hl
        elif extension_id == 1:  # ID_READ_SECTORS
            count = self.machine.a
            target = self.machine.hl
            for index in range(count):
                sector_number = self.current_fat_sector + index
                sector = self.sectors.get(sector_number)
                if sector is None:
                    raise AssertionError(f"нет FAT-сектора {sector_number}")
                start = target + index * 512
                self.memory[start : start + 512] = sector
                self.read_sectors.append(sector_number)
            self.current_fat_sector += count
            self.memory[self.core["ABT"]] = 0
        else:
            raise AssertionError(
                f"неожиданный FILEX extension id={extension_id} "
                f"return=#{return_address:04X} sp=#{self.machine.sp:04X}"
            )
        self.machine.a = 0
        self.machine.f = ZERO_FLAG
        self._return()

    def invoke(self, name: str) -> bool:
        self.machine.sp = STACK_BASE
        put16(self.memory, STACK_BASE, RETURN_SENTINEL)
        self.machine.pc = self.address(name)
        while True:
            self.machine.ticks_to_stop = 1_000_000
            event = self.machine.run()
            if not event & BREAKPOINT_HIT:
                raise AssertionError(
                    f"FILEX остановился вне breakpoint: event={event}, "
                    f"pc=#{self.machine.pc:04X}"
                )
            if self.machine.pc == RETURN_SENTINEL:
                return bool(self.machine.f & ZERO_FLAG)
            handler = self.callouts.get(self.machine.pc)
            if handler is None:
                raise AssertionError(f"Неожиданный FILEX breakpoint #{self.machine.pc:04X}")
            handler()

    def unique(self, *, start: int, cursor: int, cluster: int, wrapped: int) -> tuple[bool, int]:
        put32(self.memory, self.address("FILEX_SCAN_START"), start)
        put32(self.memory, self.address("FILEX_SCAN_CURSOR"), cursor)
        put32(self.memory, self.address("FILEX_SCAN_CLUSTER"), cluster)
        self.memory[self.address("FILEX_SCAN_WRAPPED")] = wrapped
        result = self.invoke("FILEX_SCAN_CLUSTER_UNIQUE")
        return result, self.memory[self.address("FILEX_SCAN_WRAPPED")]


def main() -> int:
    core_source = CORE_SOURCE.read_text(encoding="utf-8")
    expect(
        "MKSG сохраняет hint без шлюза в GENB",
        "GENB    LD (FSTFRC),HL,(FSTFRC+2),DE" in core_source,
        True,
    )
    expect(
        "MKSG сохраняет hint без шлюза в AR2",
        "AR2     LD (FSTFRC),HL,(FSTFRC+2),DE" in core_source,
        True,
    )
    if "GENB    CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_NEXT_FREE_HINT" in core_source:
        raise AssertionError("GENB снова вызывает шлюз внутри EXX-чувствительного цикла")
    if "AR2     CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_NEXT_FREE_HINT" in core_source:
        raise AssertionError("AR2 снова вызывает шлюз внутри EXX-чувствительного цикла")

    harness = ExtensionHarness()
    core = harness.core
    memory = harness.memory

    data_limit = harness.configure_volume(4_456)
    cold_fallback = data_limit - (data_limit >> 4)
    harness.invoke("LOAD_FREE_HINT")
    expect("вычисленная data-граница", get32(memory, harness.ext_address("FAT_DATA_CLUSTER_LIMIT")), data_limit)
    expect("валидный FSI_Nxt_Free", get32(memory, core["FSTFRC"]), 4_456)
    expect("валидный FSI_Nxt_Free проверяется по FAT", harness.curit_calls, [4_456])

    harness.configure_volume(0xFFFFFFFF)
    harness.invoke("LOAD_FREE_HINT")
    expect("неизвестный FSI_Nxt_Free", get32(memory, core["FSTFRC"]), cold_fallback)

    harness.configure_volume(data_limit)
    harness.invoke("LOAD_FREE_HINT")
    expect("подсказка за data-границей", get32(memory, core["FSTFRC"]), cold_fallback)

    harness.configure_volume(4_456, valid_fsinfo=False)
    harness.invoke("LOAD_FREE_HINT")
    expect("плохая сигнатура FSInfo", get32(memory, core["FSTFRC"]), cold_fallback)

    # Формально допустимый, но уже занятый FSI_Nxt_Free не должен запускать
    # холодный линейный проход от начала большой FAT. Проверка только читает
    # одну FAT-запись и выбирает безопасную RAM-точку 15/16 тома.
    stale_hint = 3
    harness.configure_volume(stale_hint)
    harness.fat_entries[stale_hint] = 0x0FFFFFFF
    harness.written_sectors.clear()
    harness.invoke("LOAD_FREE_HINT")
    expect("занятая FSInfo-подсказка заменяется холодной", get32(memory, core["FSTFRC"]), cold_fallback)
    expect("занятая FSInfo-подсказка проверяется один раз", harness.curit_calls, [stale_hint])
    expect("FSInfo читается один раз до отдельной FAT-проверки", len(harness.read_calls), 1)
    expect("холодная проверка не пишет носитель", len(harness.written_sectors), 0)

    put32(memory, core["FSTFRC"], 7_000)
    put32(memory, core["LOBU"], 321)
    harness.invoke("NOTE_FREED_CHAIN")
    expect("подсказка освобождённой цепочки", get32(memory, core["FSTFRC"]), 321)
    put32(memory, core["LOBU"], 0)
    harness.invoke("NOTE_FREED_CHAIN")
    expect("пустая цепочка сохраняет подсказку", get32(memory, core["FSTFRC"]), 321)

    put32(memory, core["CAHL"], 6_001)
    harness.invoke("SAVE_NEXT_FREE_HINT")
    expect("следующий кандидат после выделения", get32(memory, core["FSTFRC"]), 6_001)
    put32(memory, core["CAHL"], data_limit)
    harness.invoke("SAVE_NEXT_FREE_HINT")
    expect("wrap следующего кандидата", get32(memory, core["FSTFRC"]), 2)

    harness.read_sector = make_fsinfo(0xFFFFFFFF)
    harness.written_sectors.clear()
    put32(memory, core["FSTFRC"], 321)
    harness.invoke("RFRH_SAFE")
    expect("одна запись FSInfo", len(harness.written_sectors), 1)
    written = memoryview(harness.written_sectors[0])
    expect("FSInfo Free_Count неизвестен", get32(written, 488), 0xFFFFFFFF)
    expect("FSInfo сохраняет подсказку", get32(written, 492), 321)

    harness.written_sectors.clear()
    put32(memory, core["FSTFRC"], data_limit)
    harness.invoke("RFRH_SAFE")
    written = memoryview(harness.written_sectors[0])
    expect("FSInfo отвергает padding", get32(written, 492), 0xFFFFFFFF)

    # Полный холодный цикл: неизвестная подсказка даёт fallback 15/16, успешное
    # выделение сохраняет следующий кандидат, новое монтирование читает его.
    harness.configure_volume(0xFFFFFFFF)
    harness.invoke("LOAD_FREE_HINT")
    expect("холодный старт поиска", get32(memory, core["FSTFRC"]), cold_fallback)
    put32(memory, core["CAHL"], 4_457)
    harness.invoke("SAVE_NEXT_FREE_HINT")
    harness.written_sectors.clear()
    harness.read_sector = make_fsinfo(0xFFFFFFFF)
    harness.invoke("RFRH_SAFE")
    persisted = harness.written_sectors[-1]
    expect("commit сохраняет следующий кандидат", get32(memoryview(persisted), 492), 4_457)
    harness.configure_volume(4_457)
    harness.read_sector = persisted
    put32(memory, core["FSTFRC"], 2)
    harness.invoke("LOAD_FREE_HINT")
    expect("холодное повторное монтирование", get32(memory, core["FSTFRC"]), 4_457)

    harness.configure_volume(0xFFFFFFFF)
    harness.invoke("LOAD_FREE_HINT")
    harness.mock_mksg_hint = 7_001
    harness.read_sector = make_fsinfo(0xFFFFFFFF)
    harness.written_sectors.clear()
    harness.machine.hl = 541
    harness.machine.de = 0
    harness.invoke("ALLOCATE_FILE")
    expect("MKFILE allocation не пишет FSInfo", len(harness.written_sectors), 0)
    expect("MKFILE allocation сохраняет RAM-подсказку", get32(memory, core["FSTFRC"]), 7_001)

    harness.written_sectors.clear()
    harness.machine.hl = 0
    harness.machine.de = 0
    harness.invoke("ALLOCATE_FILE")
    expect("пустой MKFILE не пишет FSInfo", len(harness.written_sectors), 0)
    expect("пустой MKFILE не получает кластер", get32(memory, core["FCTS"]), 0)

    filex = FilexHarness()
    expect("до wrap кластер уникален", filex.unique(start=100, cursor=100, cluster=110, wrapped=0), (True, 0))
    expect("кластер после wrap уникален", filex.unique(start=100, cursor=121, cluster=5, wrapped=0), (True, 1))
    expect("исходная позиция после wrap повторна", filex.unique(start=100, cursor=6, cluster=100, wrapped=1), (False, 1))
    expect("wrap от кластера 2 не считает его дважды", filex.unique(start=2, cursor=200, cluster=2, wrapped=0), (False, 1))

    put32(filex.memory, filex.address("FILEX_SCAN_START"), 4_456)
    put32(filex.memory, core["FSTFRC"], 2)
    filex.invoke("FILEX_RESTORE_SCAN_HINT")
    expect("preflight восстанавливает подсказку", get32(filex.memory, core["FSTFRC"]), 4_456)

    # READ_FAT обязан читать только запрошенное секторное окно активной FAT и
    # не выходить за полный 32-битный BFTSZ.
    block = 0x9000
    buffer = 0xA000
    filex.memory[block : block + 32] = bytes(32)
    filex.memory[block + 0] = 32
    filex.memory[block + 1] = 1
    filex.memory[block + 2] = 7
    put32(filex.memory, block + 4, 512)
    put16(filex.memory, block + 8, buffer)
    put16(filex.memory, block + 10, 1024)
    put32(filex.memory, core["BFTSZ"], 3)
    filex.sectors = {
        1: bytes((index * 7 + 3) & 0xFF for index in range(512)),
        2: bytes((index * 11 + 5) & 0xFF for index in range(512)),
    }
    filex.machine.hl = block
    expect("FILEX READ_FAT status", filex.invoke("FILEX_ENTRY"), True)
    expect("FILEX READ_FAT sectors", filex.read_sectors, [1, 2])
    expect(
        "FILEX READ_FAT bytes",
        bytes(filex.memory[buffer : buffer + 1024]),
        filex.sectors[1] + filex.sectors[2],
    )
    expect("FILEX READ_FAT count", get32(filex.memory, block + 24), 1024)

    filex.read_sectors.clear()
    put32(filex.memory, block + 4, 2 * 512)
    put16(filex.memory, block + 10, 2 * 512)
    filex.machine.hl = block
    expect("FILEX READ_FAT bound status", filex.invoke("FILEX_ENTRY"), False)
    expect("FILEX READ_FAT bound code", filex.memory[block + 28], 0x14)
    expect("FILEX READ_FAT bound no I/O", filex.read_sectors, [])

    print(
        "FAT allocator hint PASS: mount Next_Free, stale-entry check, 15/16 fallback, data limit, "
        "delete hint, MKSG inline cursor, next preflight candidate, explicit FSInfo/remount, "
        "FILEX unique wrap and active FAT windows"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
