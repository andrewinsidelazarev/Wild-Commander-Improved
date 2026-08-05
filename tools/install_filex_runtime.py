"""Установить обязательный FILEX.WMF и первым добавить его в [PLUGINS]."""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", type=Path, required=True)
    parser.add_argument("--wc-dir", type=Path, required=True)
    args = parser.parse_args()

    provider = args.provider.resolve()
    wc_dir = args.wc_dir.resolve()
    ini_path = wc_dir / "wc.ini"
    if not provider.is_file():
        raise FileNotFoundError(f"Провайдер FILEX не найден: {provider}")
    if not ini_path.is_file():
        raise FileNotFoundError(f"Конфигурация WC не найдена: {ini_path}")

    # Работаем с байтами: эталонный wc.ini содержит исторический OEM-текст,
    # который нельзя незаметно перекодировать через Unicode.
    lines = ini_path.read_bytes().splitlines(keepends=True)
    filtered: list[bytes] = []
    plugins_index: int | None = None
    for line in lines:
        stripped = line.strip()
        if stripped.upper().startswith(b"FILEX.WMF"):
            continue
        if stripped.upper() == b"[PLUGINS]":
            plugins_index = len(filtered)
        filtered.append(line)
    if plugins_index is None:
        raise RuntimeError("В wc.ini отсутствует раздел [PLUGINS]")

    marker_line = filtered[plugins_index]
    if marker_line.endswith(b"\r\n"):
        newline = b"\r\n"
    elif marker_line.endswith(b"\r"):
        newline = b"\r"
    else:
        newline = b"\n"
    filtered.insert(plugins_index + 1, b"FILEX.WMF" + newline)
    ini_path.write_bytes(b"".join(filtered))
    shutil.copyfile(provider, wc_dir / "FILEX.WMF")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
