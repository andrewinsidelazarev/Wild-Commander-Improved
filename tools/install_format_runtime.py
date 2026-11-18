"""Установить FORMAT.WMF в WC/ без строки в [PLUGINS] wc.ini.

Плагин размечает накопитель целиком, поэтому в меню F10 по умолчанию его нет:
его загружают Enter'ом на FORMAT.WMF в каталоге /WC (после этого он есть в F10
до конца сеанса). Строку FORMAT.WMF, если она осталась в wc.ini от прежней
сборки, установщик убирает.
"""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path

NAME = b"FORMAT.WMF"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--wc-dir", type=Path, required=True)
    args = parser.parse_args()

    plugin = args.plugin.resolve()
    wc_dir = args.wc_dir.resolve()
    ini_path = wc_dir / "wc.ini"
    if not plugin.is_file():
        raise FileNotFoundError(f"Плагин FORMAT не найден: {plugin}")
    if not ini_path.is_file():
        raise FileNotFoundError(f"Конфигурация WC не найдена: {ini_path}")
    data = plugin.read_bytes()
    if data[16:32] != b"WildCommanderMDL" or data[197] != 3:
        raise RuntimeError("FORMAT.WMF: ожидался плагин типа #03 (пункт F10)")

    # Исторический OEM-файл обрабатывается как байты, кодировка не меняется.
    lines = ini_path.read_bytes().splitlines(keepends=True)
    kept = [line for line in lines
            if not (line.strip().upper().startswith(NAME)
                    or line.strip().upper().startswith(b";" + NAME))]
    if len(kept) != len(lines):
        ini_path.write_bytes(b"".join(kept))
    shutil.copyfile(plugin, wc_dir / "FORMAT.WMF")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
