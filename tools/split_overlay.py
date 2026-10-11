# Claude - 2026-10-10 - begin
"""Разделить сырой образ CORE32_EXT на загрузочную часть и оверлей FILEX.

sjasmplus --raw пишет байты подряд: сначала загрузочная часть страницы #E8
(#C000..INSTALL_IMAGE_END, вместе с одноразовым образом WMF), затем оверлей,
собранный по адресам с RUNTIME_END (OVERLAY_START). Инструмент:

- ставит штамп EXT_STAMP — первые 4 байта SHA-256 сырого образа при нулевом
  штампе (сборка, где поменялся хоть байт загрузочной части или оверлея,
  получает другой штамп);
- пишет загрузочную часть (её пакует boot.$C), оверлей (его везёт
  FILEX.WMF) и образ страницы после установки оверлея — загрузочная часть
  до RUNTIME_END и оверлей за ней (им пользуются машинные тесты);
- пишет константы для FILEX.ASM: где лежит оверлей, его длину, адрес и байты
  штампа.
"""
from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path

SYMBOL_RE = re.compile(r"^WDOS_EXT\.([A-Za-z0-9_]+):\s+EQU\s+0x([0-9A-Fa-f]+)", re.MULTILINE)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--symbols", type=Path, required=True)
    parser.add_argument("--boot", type=Path, required=True)
    parser.add_argument("--overlay", type=Path, required=True)
    parser.add_argument("--installed", type=Path, required=True)
    parser.add_argument("--inc", type=Path, required=True)
    args = parser.parse_args()

    symbols = {name: int(value, 16) for name, value in
               SYMBOL_RE.findall(args.symbols.read_text(encoding="utf-8"))}
    raw = args.raw.read_bytes()
    runtime_end = symbols["RUNTIME_END"]
    image_end = symbols["INSTALL_IMAGE_END"]
    start = symbols["OVERLAY_START"]
    length = symbols["OVERLAY_END"] - start
    stamp_at = symbols["EXT_STAMP"] - 0xC000
    if start != runtime_end:
        raise RuntimeError(f"OVERLAY_START #{start:04X} не на RUNTIME_END #{runtime_end:04X}")
    boot_length = image_end - 0xC000
    overlay = raw[boot_length:]
    if len(overlay) != length:
        raise RuntimeError(f"оверлей {len(overlay)} байт, а по символам {length}")
    if raw[stamp_at:stamp_at + 4] != bytes(4):
        raise RuntimeError("EXT_STAMP в сыром образе не нулевой")
    stamp = hashlib.sha256(raw).digest()[:4]
    if stamp == bytes(4):
        raise RuntimeError("нулевой штамп")
    boot = bytearray(raw[:boot_length])
    boot[stamp_at:stamp_at + 4] = stamp
    installed = bytes(boot[:runtime_end - 0xC000]) + overlay
    if len(installed) > 0x4000:
        raise RuntimeError("страница с оверлеем длиннее 16 КиБ")

    args.boot.write_bytes(bytes(boot))
    args.overlay.write_bytes(overlay)
    args.installed.write_bytes(installed)
    lines = [
        "; Claude - 2026-10-10: создано tools/split_overlay.py",
        f"EXT_OVERLAY_START EQU 0x{start:04X}",
        f"EXT_OVERLAY_LENGTH EQU {length}",
        f"EXT_STAMP_ADDR EQU 0x{stamp_at + 0xC000:04X}",
    ]
    lines += [f"EXT_STAMP_{i} EQU 0x{byte:02X}" for i, byte in enumerate(stamp)]
    args.inc.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"overlay=#{start:04X}+{length} boot={len(boot)} stamp={stamp.hex()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
# Claude - 2026-10-10 - end
