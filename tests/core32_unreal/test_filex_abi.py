"""Проверить неизменяемые адреса и заголовки публичного FILEX API 77."""
from __future__ import annotations

import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
BUILD = PROJECT_ROOT / "Build"
PAYLOAD_BASE = 0x6011
PLUGIN_TYPE_OFFSET = 197
SYMBOL_RE = re.compile(r"^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$")


def load_symbols(path: Path) -> dict[str, int]:
    result: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = SYMBOL_RE.match(line.strip())
        if match:
            result[match.group(1)] = int(match.group(2), 16)
    return result


def payload_slice(payload: bytes, address: int, size: int) -> bytes:
    offset = address - PAYLOAD_BASE
    if offset < 0 or offset + size > len(payload):
        raise AssertionError(f"адрес #{address:04X} находится вне boot.payload.bin")
    return payload[offset : offset + size]


def word(payload: bytes, address: int) -> int:
    data = payload_slice(payload, address, 2)
    return data[0] | data[1] << 8


def expect(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: получено {actual!r}, ожидалось {expected!r}")


def main() -> int:
    boot = load_symbols(BUILD / "boot.sym")
    provider = load_symbols(BUILD / "FILEX.sym")
    payload = (BUILD / "boot.payload.bin").read_bytes()

    # Независимый фиксированный контракт: адреса нельзя брать из текущих
    # символов как эталон, иначе одновременный сдвиг ядра и провайдера скроет
    # несовместимость с уже собранными плагинами. Проверяем все 18 входов,
    # перечисленных в заголовке CORE32, включая границу рабочего образа.
    frozen_core = {
        "START": 0x4000, "NXTETY2": 0x4067, "NXTETY": 0x413F,
        "LOAD512": 0x43A0, "SAVE512": 0x4398,
        "CURIT": 0x44A5, "GIPAG": 0x44D7,
        "MKSG": 0x4880, "DLSG": 0x49B4, "SRHDRN": 0x4A4C,
        "MKFILE": 0x4D34, "MKDIR": 0x4D5B,
        "DELFL": 0x4CDD, "RENAME": 0x4D13,
        "HDD": 0x4E71, "DOS_SWP": 0x4FF8, "DEHR": 0x5AAA,
        "END": 0x5BF2,
    }
    for name, address in frozen_core.items():
        expect(f"фиксированный вход WDOS.{name}", boot.get("WDOS." + name), address)

    required_boot = {
        "PLUGIN_API_TABLE",
        "FEX",
        "XFILEX",
        "WDOS_FILEX_GATE",
        "FILEX_PROVIDER_PAGE_PATCH",
        "INIT_RELOCATED",
    }
    missing = sorted(required_boot - boot.keys())
    if missing:
        raise AssertionError("в boot.sym отсутствуют символы: " + ", ".join(missing))

    expect("публичная обёртка XFILEX", boot["XFILEX"], 0x6AFD)
    expect("резидентный шлюз FILEX", boot["WDOS_FILEX_GATE"], 0x6A47)
    expect("операнд страницы FILEX", boot["FILEX_PROVIDER_PAGE_PATCH"], 0x6A48)
    expect("перенесённый INIT", boot["INIT_RELOCATED"], 0xBFD4)
    expect("поиск для существующего FILEX.WMF", boot["WDOS.SRHDRN"], 0x4A4C)
    expect("удаление цепочки для существующего FILEX.WMF", boot["WDOS.DLSG"], 0x49B4)
    if boot["XFILEX"] >= 0x8000 or boot["WDOS_FILEX_GATE"] >= 0x8000:
        raise AssertionError("обёртка или шлюз FILEX недоступны при странице плагина в #8000")
    if 0x6020 <= boot["WDOS_FILEX_GATE"] < 0x6049:
        raise AssertionError("шлюз FILEX пересекается с очищаемым PLresCP")

    table = boot["PLUGIN_API_TABLE"]
    expect("API 55 сохранил FEX", word(payload, table + 55 * 2), boot["FEX"])
    expect("API 77 указывает XFILEX", word(payload, table + 77 * 2), boot["XFILEX"])
    expect(
        "внутренний слот #402D",
        payload_slice(payload, 0xC00C + 0x2D, 3),
        bytes((0xC3, 0x47, 0x6A)),
    )
    expect(
        "машинный код XFILEX",
        payload_slice(payload, boot["XFILEX"], 9),
        bytes((0xCD, 0x7A, 0x6B, 0xCD, 0x2D, 0x40, 0xC3, 0x8B, 0x6B)),
    )
    expect("начальное значение страницы провайдера", payload_slice(payload, 0x6A48, 1), b"\0")

    for name, expected_type in (
        ("FILEX.WMF", 0x06),
        ("FILEXT.WMF", 0x03),
        ("FILEXNST.WMF", 0x06),
    ):
        data = (BUILD / name).read_bytes()
        if len(data) <= PLUGIN_TYPE_OFFSET:
            raise AssertionError(f"слишком короткий заголовок {name}")
        expect(f"тип плагина {name}", data[PLUGIN_TYPE_OFFSET], expected_type)

    for symbol, expected in (
        ("FILEX_API_VERSION", 1),
        ("FILEX_BLOCK_SIZE", 32),
        ("FILEX_OP_COUNT", 8),
        ("FILEX_CAP_MOVE_CURRENT_DIR", 0x40),
        ("FILEX_CAP_READ_FAT", 0x80),
        ("FILEX_FLAG_CURRENT_DIR", 0x02),
        ("FILEX_STATUS_OK", 0x00),
        ("FILEX_STATUS_FAT", 0x20),
        ("FILEX_STATUS_MEDIA", 0x21),
        ("FILEX_STATUS_NO_SPACE", 0x22),
    ):
        expect(symbol, provider.get(symbol), expected)
    if "FILEX_PREFLIGHT_GROWTH" not in provider:
        raise AssertionError("в FILEX runtime отсутствует защита роста полного диска")

    print(
        "FILEX ABI PASS: API77=#6AFD, gate=#6A47, provider=#06, "
        "FILEXT=#03, FILEXNST=#06, block=32, operations=8, caps=#FF, "
        "18 fixed CORE32 addresses"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
