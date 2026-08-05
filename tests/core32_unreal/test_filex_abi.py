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
        ("FILEXNST.WMF", 0x03),
    ):
        data = (BUILD / name).read_bytes()
        if len(data) <= PLUGIN_TYPE_OFFSET:
            raise AssertionError(f"слишком короткий заголовок {name}")
        expect(f"тип плагина {name}", data[PLUGIN_TYPE_OFFSET], expected_type)

    for symbol, expected in (
        ("FILEX_API_VERSION", 1),
        ("FILEX_BLOCK_SIZE", 32),
        ("FILEX_OP_COUNT", 7),
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
        "tests=#03, block=32, operations=7"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
