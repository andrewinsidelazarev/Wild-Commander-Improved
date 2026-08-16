"""Машинные регрессии безопасного сохранения и границ TXTEDIT.WMF."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

import z80


PROJECT_ROOT = Path(__file__).resolve().parents[2]
TXTEDIT_SOURCE = PROJECT_ROOT / "source" / "plugins" / "txt_editor" / "TXTEDIT.ASM"
TXTEDIT_BIN = PROJECT_ROOT / "Build" / "TXTEDIT.WMF"
TXTEDIT_SYMBOLS = PROJECT_ROOT / "Build" / "TXTEDIT.sym"
CODE_BASE = 0x8000
HEADER_SIZE = 512
WLD = 0x6006
RETURN_SENTINEL = 0xFF00
STACK_BASE = 0xFE00
BREAKPOINT_HIT = 1 << 1
SYMBOL_RE = re.compile(r"^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$")


def load_symbols() -> dict[str, int]:
    result: dict[str, int] = {}
    for line in TXTEDIT_SYMBOLS.read_text(encoding="utf-8").splitlines():
        match = SYMBOL_RE.match(line.strip())
        if match:
            result[match.group(1)] = int(match.group(2), 16)
    return result


def put16(memory: memoryview, address: int, value: int) -> None:
    memory[address] = value & 0xFF
    memory[address + 1] = value >> 8 & 0xFF


def get16(memory: memoryview, address: int) -> int:
    return memory[address] | memory[address + 1] << 8


def get32(memory: memoryview, address: int) -> int:
    return get16(memory, address) | get16(memory, address + 2) << 16


def c_string(memory: memoryview, address: int) -> str:
    data = bytearray()
    while memory[address]:
        data.append(memory[address])
        address += 1
    return data.decode("ascii")


def expect(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: получено {actual!r}, ожидалось {expected!r}")


class MachineHarness:
    def __init__(self) -> None:
        self.symbols = load_symbols()
        self.machine = z80.Z80Machine()
        self.memory = self.machine.memory
        raw = TXTEDIT_BIN.read_bytes()
        if len(raw) <= HEADER_SIZE:
            raise AssertionError("TXTEDIT.WMF короче 512-байтового заголовка")
        self.machine.set_memory_block(CODE_BASE, raw[HEADER_SIZE:])
        self.machine.set_breakpoint(WLD)
        self.machine.set_breakpoint(RETURN_SENTINEL)

    def return_from_api(self) -> None:
        return_address = get16(self.memory, self.machine.sp)
        self.machine.sp = self.machine.sp + 2 & 0xFFFF
        self.machine.pc = return_address

    def invoke(
        self,
        symbol: str,
        api_handler=None,
        a: int = 0,
        de: int = 0,
        hl: int = 0,
    ) -> None:
        self.machine.sp = STACK_BASE
        put16(self.memory, STACK_BASE, RETURN_SENTINEL)
        self.machine.pc = self.symbols[symbol]
        self.machine.a = a
        self.machine.de = de
        self.machine.hl = hl

        while True:
            self.machine.ticks_to_stop = 1_000_000
            event = self.machine.run()
            if not event & BREAKPOINT_HIT:
                raise AssertionError(
                    f"Z80 остановился вне breakpoint: event={event}, "
                    f"pc=#{self.machine.pc:04X}, процедура={symbol}"
                )
            if self.machine.pc == RETURN_SENTINEL:
                return
            if self.machine.pc != WLD or api_handler is None:
                raise AssertionError(
                    f"неожиданный вызов WLD A=#{self.machine.a:02X} в {symbol}"
                )
            api_handler(self)
            self.return_from_api()


def find_key(files: dict[str, str], name: str) -> str | None:
    folded = name.casefold()
    return next((key for key in files if key.casefold() == folded), None)


@dataclass
class SaveScenario:
    files: dict[str, str] = field(default_factory=lambda: {"wc.ini": "old"})
    filex_caps: int = 0x7F
    filex_version: int = 1
    filex_query_status: int = 0
    filex_move_status: int = 0
    write_error: bool = False
    write_status: int | None = None
    create_error: bool = False
    rename_failures: set[int] = field(default_factory=set)
    delete_error: bool = False
    calls: list[tuple[object, ...]] = field(default_factory=list)
    rename_index: int = 0

    def handle(self, harness: MachineHarness) -> None:
        machine = harness.machine
        memory = harness.memory
        api = machine.a

        if api == 77:  # FILEX
            block = machine.hl
            operation = memory[block + 2]
            if operation == 0:  # QUERY_CAPS
                self.calls.append((api, "QUERY_CAPS"))
                memory[block + 24 : block + 28] = self.filex_caps.to_bytes(4, "little")
                memory[block + 28] = self.filex_query_status
                memory[block + 29] = self.filex_version
                machine.a = self.filex_query_status
                machine.f = 0x40 if machine.a == 0 else 0
                return

            if operation == 5:  # MOVE_RENAME
                source_pointer = get16(memory, block + 8)
                source_length = get16(memory, block + 10)
                destination_pointer = get16(memory, block + 12)
                destination_length = get16(memory, block + 14)
                source = c_string(memory, source_pointer + 1)
                destination = c_string(memory, destination_pointer + 1)
                flags = memory[block + 3]
                source_directory = get32(memory, block + 16)
                destination_directory = get32(memory, block + 20)
                self.calls.append(
                    (
                        api,
                        "MOVE_RENAME",
                        flags,
                        source,
                        destination,
                        source_length,
                        destination_length,
                        source_directory,
                        destination_directory,
                    )
                )

                if self.filex_move_status in (0, 0x25):
                    source_key = find_key(self.files, source)
                    destination_key = find_key(self.files, destination)
                    if source_key is None:
                        raise AssertionError("FILEX MOVE_RENAME не нашёл temp")
                    new_contents = self.files.pop(source_key)
                    if destination_key is not None:
                        del self.files[destination_key]
                    self.files[destination] = new_contents

                memory[block + 24 : block + 28] = (1).to_bytes(4, "little")
                memory[block + 28] = self.filex_move_status
                machine.a = self.filex_move_status
                machine.f = 0x40 if machine.a == 0 else 0
                return

            raise AssertionError(f"неожиданная операция FILEX {operation}")

        if api == 59:  # FENTRY
            name = c_string(memory, machine.hl + 1)
            self.calls.append((api, name))
            found = find_key(self.files, name) is not None
            machine.a = 1 if found else 0
            machine.f = 0 if found else 0x40
            return

        if api == 72:  # MKFILE
            name = c_string(memory, machine.hl + 5)
            self.calls.append((api, name))
            collision = find_key(self.files, name) is not None
            if self.create_error or collision:
                machine.a = 3
                machine.f = 0
            else:
                self.files[name] = "new"
                machine.a = 0
                machine.f = 0x40
            return

        if api == 65:  # MNGCVPL
            self.calls.append((api,))
            machine.a = 0
            machine.f = 0x40
            return

        if api == 49:  # SAVE512
            self.calls.append((api, machine.b))
            if self.write_error:
                machine.a = 0xFF
                machine.f = 0x01
            elif self.write_status is not None:
                machine.a = self.write_status
                machine.f = 0
            else:
                machine.a = 0x0F
                machine.f = 0
            return

        if api == 74:  # RENAME
            self.rename_index += 1
            old_name = c_string(memory, machine.hl + 1)
            new_name = c_string(memory, machine.de)
            self.calls.append((api, old_name, new_name))
            old_key = find_key(self.files, old_name)
            collision = find_key(self.files, new_name) is not None
            failed = self.rename_index in self.rename_failures
            if failed or old_key is None or collision:
                machine.a = 0
                machine.f = 0x40
            else:
                self.files[new_name] = self.files.pop(old_key)
                machine.a = 1
                machine.f = 0
            return

        if api == 75:  # DELFL
            name = c_string(memory, machine.hl + 1)
            self.calls.append((api, name))
            key = find_key(self.files, name)
            if self.delete_error or key is None:
                machine.a = 0
                machine.f = 0x40
            else:
                del self.files[key]
                machine.a = 1
                machine.f = 0
            return

        raise AssertionError(f"неожиданный файловый API {api}")


def run_safe_store(scenario: SaveScenario) -> tuple[bool, SaveScenario]:
    harness = MachineHarness()
    symbols = harness.symbols
    memory = harness.memory
    memory[symbols["FLMAKE"] + 1 : symbols["FLMAKE"] + 5] = (4).to_bytes(
        4, "little"
    )
    memory[symbols["ENTRYN"] : symbols["ENTRYN"] + 7] = b"wc.ini\0"
    memory[symbols["DHLA"] + 2] = 0
    harness.invoke("SAFE_STORE", scenario.handle)
    return bool(harness.machine.f & 0x40), scenario


def test_safe_store() -> None:
    source = TXTEDIT_SOURCE.read_text(encoding="utf-8")
    dispatch_start = source.index("\nSAFE_STORE\n") + 1
    dispatch_end = source.index("\nSAFE_STORE_LEGACY\n", dispatch_start) + 1
    dispatch = source[dispatch_start:dispatch_end]
    if "JP SAFE_STORE_LEGACY" not in dispatch:
        raise AssertionError("SAFE_STORE не закреплён за аппаратно безопасным legacy path")
    if "FILEX_FAST_AVAILABLE" in dispatch or "FILEX_SAFE_STORE" in dispatch:
        raise AssertionError("SAFE_STORE снова вызывает зависающий FILEX fast path")

    success, scenario = run_safe_store(SaveScenario())
    expect("успешный аппаратно безопасный SAFE_STORE", success, True)
    expect("legacy replace опубликовал новый wc.ini", scenario.files, {"wc.ini": "new"})
    file_calls = [call for call in scenario.calls if call[0] != 65]
    expect(
        "порядок API безопасного сохранения",
        file_calls,
        [
            (59, "WCETMP0.$$$"),
            (59, "WCEBAK0.$$$"),
            (72, "WCETMP0.$$$"),
            (49, 1),
            (74, "wc.ini", "WCEBAK0.$$$"),
            (74, "WCETMP0.$$$", "wc.ini"),
            (75, "WCEBAK0.$$$"),
        ],
    )
    if any(call[0] == 77 for call in scenario.calls):
        raise AssertionError("аппаратно безопасный SAFE_STORE вызвал FILEX API")

    success, scenario = run_safe_store(SaveScenario(write_error=True))
    expect("ошибка записи возвращена", success, False)
    expect("исходник после ошибки записи", scenario.files["wc.ini"], "old")
    expect("недописанный временный файл удалён", scenario.files, {"wc.ini": "old"})
    if any(call[0] == 74 for call in scenario.calls):
        raise AssertionError("после ошибки SAVE512 выполнен RENAME")
    expect(
        "очистка после ошибки SAVE512",
        [call for call in scenario.calls if call[0] == 75],
        [(75, "WCETMP0.$$$")],
    )

    success, scenario = run_safe_store(SaveScenario(write_status=1))
    expect("неизвестный статус SAVE512 возвращён как ошибка", success, False)
    expect("исходник после неизвестного статуса", scenario.files["wc.ini"], "old")
    expect("temp после неизвестного статуса удалён", scenario.files, {"wc.ini": "old"})

    success, scenario = run_safe_store(SaveScenario(write_error=True, delete_error=True))
    expect("ошибка записи при недоступной очистке", success, False)
    expect("исходник при недоступной очистке", scenario.files["wc.ini"], "old")
    expect(
        "недописанный temp остаётся только при ошибке DELFL",
        scenario.files["WCETMP0.$$$"],
        "new",
    )

    success, scenario = run_safe_store(SaveScenario(create_error=True))
    expect("ошибка создания temp возвращена", success, False)
    expect("исходник после ошибки создания temp", scenario.files, {"wc.ini": "old"})
    expect(
        "ошибка MKFILE возвращена после выбора свободной пары",
        [call for call in scenario.calls if call[0] != 65],
        [
            (59, "WCETMP0.$$$"),
            (59, "WCEBAK0.$$$"),
            (72, "WCETMP0.$$$"),
        ],
    )

    stale = {"wc.ini": "old", "WCETMP0.$$$": "stale"}
    success, scenario = run_safe_store(SaveScenario(files=stale))
    expect("выбор следующего служебного имени", success, True)
    expect("старый recovery не удалён", scenario.files["WCETMP0.$$$"], "stale")
    expect(
        "коллизия обработана с безопасной парой temp/backup",
        [call for call in scenario.calls if call[0] != 65][:4],
        [
            (59, "WCETMP0.$$$"),
            (59, "WCETMP1.$$$"),
            (59, "WCEBAK1.$$$"),
            (72, "WCETMP1.$$$"),
        ],
    )

    full = {"wc.ini": "old"}
    full.update({f"WCETMP{index}.$$$": "stale" for index in range(10)})
    success, scenario = run_safe_store(SaveScenario(files=full))
    expect("исчерпание служебных имён", success, False)
    expect("исходник при исчерпании имён", scenario.files["wc.ini"], "old")
    if any(call[0] != 59 for call in scenario.calls):
        raise AssertionError("при занятых именах началась запись данных")


def test_safe_store_legacy_fallback() -> None:
    success, scenario = run_safe_store(
        SaveScenario(rename_failures={1})
    )
    expect("ошибка первого RENAME", success, False)
    expect("исходник после первого RENAME", scenario.files["wc.ini"], "old")
    expect("новые данные после первого RENAME", scenario.files["WCETMP0.$$$"], "new")

    success, scenario = run_safe_store(
        SaveScenario(rename_failures={2})
    )
    expect("ошибка публикации", success, False)
    expect("откат вернул исходник", scenario.files["wc.ini"], "old")
    expect("новые данные сохранены во временном файле", scenario.files["WCETMP0.$$$"], "new")

    success, scenario = run_safe_store(
        SaveScenario(rename_failures={2, 3})
    )
    expect("ошибка отката", success, False)
    expect("старые данные доступны в backup", scenario.files["WCEBAK0.$$$"], "old")
    expect("новые данные доступны во временном файле", scenario.files["WCETMP0.$$$"], "new")

    success, scenario = run_safe_store(
        SaveScenario(delete_error=True)
    )
    expect("ошибка удаления backup не отменяет commit", success, True)
    expect("новый исходный файл", scenario.files["wc.ini"], "new")
    expect("старый backup сохранён", scenario.files["WCEBAK0.$$$"], "old")


def test_save_as_partial_cleanup() -> None:
    harness = MachineHarness()
    symbols = harness.symbols
    memory = harness.memory
    memory[symbols["ENTRYN"] : symbols["ENTRYN"] + 8] = b"new.ini\0"
    scenario = SaveScenario(files={"new.ini": "partial"})
    harness.invoke("DROP_ACTIVE_SAVEAS", scenario.handle)
    expect("Save As удалил недописанный файл", scenario.files, {})
    expect("Save As вызвал DELFL для нового имени", scenario.calls, [(75, "new.ini")])
    expect("Save As сохранил признак ошибки", bool(harness.machine.f & 0x40), False)

    harness = MachineHarness()
    symbols = harness.symbols
    memory = harness.memory
    memory[symbols["ENTRYN"] : symbols["ENTRYN"] + 8] = b"new.ini\0"
    scenario = SaveScenario(files={"new.ini": "partial"}, delete_error=True)
    harness.invoke("DROP_ACTIVE_SAVEAS", scenario.handle)
    expect(
        "при ошибке DELFL недописанный Save As не скрыт",
        scenario.files,
        {"new.ini": "partial"},
    )
    expect("ошибка Save As возвращена", bool(harness.machine.f & 0x40), False)


def test_save_writes_only_logical_sectors() -> None:
    cases = (
        (1, [1]),
        (512, [1]),
        (513, [2]),
        (541, [2]),
        (16 * 1024, [32]),
        (16 * 1024 + 1, [32, 1]),
        (32 * 1024 + 17, [32, 32, 1]),
    )

    for size, expected_counts in cases:
        harness = MachineHarness()
        symbols = harness.symbols
        harness.memory[
            symbols["FLMAKE"] + 1 : symbols["FLMAKE"] + 5
        ] = size.to_bytes(4, "little")
        counts: list[int] = []

        def handler(local: MachineHarness) -> None:
            if local.machine.a == 65:  # MNGCVPL
                local.machine.a = 0
                local.machine.f = 0x40
                return
            if local.machine.a != 49:
                raise AssertionError(f"неожиданный API SAVEDAT {local.machine.a}")
            counts.append(local.machine.b)
            local.machine.a = 0
            local.machine.f = 0x40

        harness.invoke("SAVEDAT", handler)
        expect(f"SAVEDAT size={size} status", bool(harness.machine.f & 0x40), True)
        expect(f"SAVEDAT size={size} sector counts", counts, expected_counts)

    harness = MachineHarness()
    symbols = harness.symbols
    harness.memory[
        symbols["FLMAKE"] + 1 : symbols["FLMAKE"] + 5
    ] = (16 * 1024 + 1).to_bytes(4, "little")
    counts = []

    def early_eoc(local: MachineHarness) -> None:
        if local.machine.a == 65:
            local.machine.a = 0
            local.machine.f = 0x40
            return
        counts.append(local.machine.b)
        local.machine.a = 0x0F
        local.machine.f = 0

    harness.invoke("SAVEDAT", early_eoc)
    expect("ранний EOC является ошибкой", bool(harness.machine.f & 0x40), False)
    expect("после раннего EOC запись остановлена", counts, [32])


def test_error_messages() -> None:
    harness = MachineHarness()
    symbols = harness.symbols
    memory = harness.memory
    expect(
        "честное сообщение ошибки сохранения",
        c_string(memory, symbols["MSG_SAVE_ERROR"]),
        "\x0eSave ERROR! Original file preserved.",
    )
    expect(
        "сообщение ошибки чтения",
        c_string(memory, symbols["MSG_READ_ERROR"]),
        "\x0eRead ERROR! File was not opened.",
    )


def test_empty_save_as_name() -> None:
    harness = MachineHarness()
    symbols = harness.symbols
    memory = harness.memory
    before = bytes([0xA5]) * 256
    memory[symbols["ENTRYN"] : symbols["ENTRYN"] + 256] = before
    memory[symbols["SASBUF"] : symbols["SASBUF"] + 255] = b" " * 255
    harness.invoke("STRING_TO_ENTRY")
    expect("пустое имя отклонено", bool(harness.machine.f & 0x40), False)
    expect(
        "пустое имя не затронуло ENTRYN",
        bytes(memory[symbols["ENTRYN"] : symbols["ENTRYN"] + 256]),
        before,
    )

    memory[symbols["SASBUF"]] = ord("A")
    harness.invoke("STRING_TO_ENTRY")
    expect("односимвольное имя принято", bool(harness.machine.f & 0x40), True)
    expect("односимвольное имя", bytes(memory[symbols["ENTRYN"] : symbols["ENTRYN"] + 2]), b"A\0")


def test_load_error_and_page_limit() -> None:
    def run_load(mode: str) -> tuple[bool, int]:
        harness = MachineHarness()
        reads = 0

        def handler(local: MachineHarness) -> None:
            nonlocal reads
            if local.machine.a == 65:
                local.machine.a = 0
                local.machine.f = 0x40
                return
            if local.machine.a != 48:
                raise AssertionError(f"неожиданный API загрузки {local.machine.a}")
            reads += 1
            if mode == "error":
                local.machine.a = 0xFF
                local.machine.f = 0x01
            elif mode == "bad_status":
                local.machine.a = 1
                local.machine.f = 0
            elif mode == "eoc":
                local.machine.a = 0x0F
                local.machine.f = 0
            else:
                local.machine.a = 0
                local.machine.f = 0

        harness.invoke("LOADFL", handler)
        return bool(harness.machine.f & 0x40), reads

    expect("ошибка LOAD512", run_load("error"), (False, 1))
    expect("неизвестный статус LOAD512", run_load("bad_status"), (False, 1))
    expect("штатный EOC", run_load("eoc"), (True, 1))
    expect("цепочка длиннее буфера", run_load("no_eoc"), (False, 64))


def test_last_page_insert_guard() -> None:
    harness = MachineHarness()
    symbols = harness.symbols
    memory = harness.memory
    put16(memory, symbols["LHLCR"], 0x3FFF)
    memory[symbols["LHLCR"] + 2] = 0x3F
    put16(memory, symbols["RHLCR"], 0x0100)
    memory[symbols["RHLCR"] + 2] = 0
    memory[0x3FFF] = 0xA5

    def handler(local: MachineHarness) -> None:
        if local.machine.a != 80:
            raise AssertionError(f"неожиданный API вставки {local.machine.a}")
        local.machine.a = 0
        local.machine.f = 0x40

    harness.invoke("INCLCR", handler, a=ord("X"))
    expect("страница курсора не стала #40", memory[symbols["LHLCR"] + 2], 0x3F)
    expect("смещение курсора не переполнилось", get16(memory, symbols["LHLCR"]), 0x3FFF)
    expect("отказ вставки не изменил последний байт", memory[0x3FFF], 0xA5)
    expect("вставка вернула NC", bool(harness.machine.f & 0x01), False)


def test_search_stops_at_eof() -> None:
    harness = MachineHarness()
    symbols = harness.symbols
    memory = harness.memory
    memory[symbols["STRBUFF"] : symbols["STRBUFF"] + 40] = b"X" + b" " * 39
    put16(memory, symbols["LHLCR"], 0)
    memory[symbols["LHLCR"] + 2] = 0
    put16(memory, symbols["RHLCR"], 0x0100)
    memory[symbols["RHLCR"] + 2] = 0
    memory[0xC101] = 0
    map_calls = 0

    def handler(local: MachineHarness) -> None:
        nonlocal map_calls
        if local.machine.a not in (65, 80):
            raise AssertionError(f"неожиданный API поиска {local.machine.a}")
        map_calls += 1
        local.machine.a = 0
        local.machine.f = 0x40

    harness.invoke("GOSRH", handler, de=0)
    expect("поиск на EOF вернул not found", bool(harness.machine.f & 0x01), False)
    expect("поиск не пошёл по следующим страницам", map_calls, 2)
    expect("правая граница остановлена на EOF", get16(memory, symbols["RHLCR"]), 0x0101)


def test_inspector_division_stack() -> None:
    def run(expression: bytes) -> tuple[int, int, bool]:
        harness = MachineHarness()
        address = 0xB000
        harness.memory[address : address + len(expression)] = expression
        harness.invoke("POLSK", hl=address)
        return harness.machine.a, harness.machine.bc, bool(harness.machine.f & 0x01)

    # RPN: 4, 2, DIV, END.
    expect(
        "штатное деление Inspector",
        run(bytes((2, 4, 0, 2, 2, 0, 8, 0))),
        (0, 2, False),
    )
    # RPN: 1, 0, DIV, END. Ветка ошибки обязана вернуть исходный стек и CF=1.
    expect(
        "деление Inspector на ноль",
        run(bytes((2, 1, 0, 2, 0, 0, 8, 0))),
        (26, 0, True),
    )


def main() -> int:
    for required in (
        "SAFE_STORE",
        "STRING_TO_ENTRY",
        "LOADFL",
        "INCLCR",
        "GOSRH",
        "ENTRYN",
        "FLMAKE",
        "DROP_ACTIVE_SAVEAS",
        "MSG_SAVE_ERROR",
        "MSG_READ_ERROR",
    ):
        if required not in load_symbols():
            raise AssertionError(f"в TXTEDIT.sym отсутствует {required}")

    test_safe_store()
    test_safe_store_legacy_fallback()
    test_save_as_partial_cleanup()
    test_save_writes_only_logical_sectors()
    test_error_messages()
    test_empty_save_as_name()
    test_load_error_and_page_limit()
    test_last_page_insert_guard()
    test_search_stops_at_eof()
    test_inspector_division_stack()
    print(
        "TXTEDIT safety unit PASS: hardware-safe transactional save, fault rollback, cleanup, "
        "logical-sector SAVE512 bounds, Save As cleanup, visible errors, empty name, "
        "LOAD512 errors, "
        "page #3F guard, EOF search, Inspector division"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
