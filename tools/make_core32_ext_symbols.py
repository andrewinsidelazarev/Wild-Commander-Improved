# Codex - 2026-07-17 - begin
"""Создать минимальный EQU-интерфейс CORE32 для отдельной сборки расширения."""
from __future__ import annotations

import argparse
import re
from pathlib import Path


REFERENCE_RE = re.compile(r"@WDOS\.([A-Za-z0-9_]+)")
SYMBOL_RE = re.compile(r"^WDOS\.([A-Za-z0-9_]+):\s+EQU\s+(\S+)", re.MULTILINE)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--symbols", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    source = args.source.read_text(encoding="utf-8")
    symbol_text = args.symbols.read_text(encoding="utf-8")
    required = sorted(set(REFERENCE_RE.findall(source)))
    available = dict(SYMBOL_RE.findall(symbol_text))
    missing = [name for name in required if name not in available]
    if missing:
        raise RuntimeError("В карте CORE32 отсутствуют символы: " + ", ".join(missing))

    lines = [
        "; Codex - 2026-07-17 - begin",
        "; Автоматически создано tools/make_core32_ext_symbols.py.",
    ]
    lines.extend(f"{name} EQU {available[name]}" for name in required)
    lines.append("; Codex - 2026-07-17 - end")
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"Интерфейс CORE32: символов={len(required)}, файл={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
# Codex - 2026-07-17 - end
