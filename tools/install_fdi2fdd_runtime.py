"""Установить FDI2FDD.WMF и добавить его строку в [PLUGINS] после TRDUMP.WMF."""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path

NAME = b"FDI2FDD.WMF"


def detect_newline(line: bytes) -> bytes:
    if line.endswith(b"\r\n"):
        return b"\r\n"
    if line.endswith(b"\r"):
        return b"\r"
    return b"\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--wc-dir", type=Path, required=True)
    args = parser.parse_args()

    plugin = args.plugin.resolve()
    wc_dir = args.wc_dir.resolve()
    ini_path = wc_dir / "wc.ini"
    if not plugin.is_file():
        raise FileNotFoundError(f"Плагин FDI2FDD не найден: {plugin}")
    if not ini_path.is_file():
        raise FileNotFoundError(f"Конфигурация WC не найдена: {ini_path}")
    data = plugin.read_bytes()
    if data[16:32] != b"WildCommanderMDL" or data[197] != 0 or data[64:67] != b"FDI":
        raise RuntimeError("FDI2FDD.WMF: ожидался файловый плагин типа #00 с расширением FDI")

    # Исторический OEM-файл обрабатывается как байты, кодировка не меняется.
    # Плагин записи образа на дискету — рядом с TRDump, который пишет TRD.
    lines = ini_path.read_bytes().splitlines(keepends=True)
    filtered: list[bytes] = []
    plugins_index: int | None = None
    anchor: int | None = None
    for line in lines:
        stripped = line.strip().upper()
        if stripped.startswith(NAME) or stripped.startswith(b";" + NAME):
            continue
        if stripped == b"[PLUGINS]":
            plugins_index = len(filtered)
        elif plugins_index is not None and anchor is None and stripped.startswith(b"TRDUMP.WMF"):
            anchor = len(filtered)
        filtered.append(line)
    if plugins_index is None:
        raise RuntimeError("В wc.ini отсутствует раздел [PLUGINS]")
    if anchor is None:
        raise RuntimeError("В [PLUGINS] нет строки TRDUMP.WMF — некуда поставить FDI2FDD.WMF")

    filtered.insert(anchor + 1, NAME + detect_newline(filtered[anchor]))
    ini_path.write_bytes(b"".join(filtered))
    shutil.copyfile(plugin, wc_dir / "FDI2FDD.WMF")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
