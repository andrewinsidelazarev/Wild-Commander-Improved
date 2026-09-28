"""Установить SETUP.WMF и поставить его в [PLUGINS] сразу за PLM.WMF.

SETUP.WMF — настройки WC обычным плагином меню F10 (тип #03, «WC Setup»).
Встроенный в ядро минимум плагинов на случай отсутствия wc.ini перечисляет
FILEX, PLM и SETUP в том же порядке, поэтому и в поставке строка идёт третьей.
"""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path


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
        raise FileNotFoundError(f"Плагин настроек не найден: {plugin}")
    if not ini_path.is_file():
        raise FileNotFoundError(f"Конфигурация WC не найдена: {ini_path}")

    # Исторический OEM-файл обрабатываем как байты, не меняя его кодировку.
    lines = ini_path.read_bytes().splitlines(keepends=True)
    filtered: list[bytes] = []
    plugins_index: int | None = None
    anchor: int | None = None
    for line in lines:
        stripped = line.strip().upper()
        if stripped.startswith(b"SETUP.WMF"):
            continue
        if stripped == b"[PLUGINS]":
            plugins_index = len(filtered)
        elif plugins_index is not None and stripped.startswith((b"FILEX.WMF", b"PLM.WMF")):
            anchor = len(filtered)
        filtered.append(line)
    if plugins_index is None:
        raise RuntimeError("В wc.ini отсутствует раздел [PLUGINS]")

    anchor = anchor if anchor is not None else plugins_index
    newline = detect_newline(filtered[anchor])
    filtered.insert(anchor + 1, b"SETUP.WMF" + newline)
    ini_path.write_bytes(b"".join(filtered))
    shutil.copyfile(plugin, wc_dir / "SETUP.WMF")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
