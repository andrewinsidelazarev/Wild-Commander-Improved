"""Install CHKDSK.WMF and register it after UNZIP in [PLUGINS]."""
from __future__ import annotations

import argparse
import hashlib
import shutil
from pathlib import Path


EXPECTED_SIGNATURE = b"WildCommanderMDL"
EXPECTED_TITLE = b"ChkDsk FAT32 v0.06 (c)2026      "
EXPECTED_PAGES = 5
EXPECTED_SHA256 = "E74D5F21760FAE0C09E84D2E9E7095613C67F79B2C8FD4A801E168822C631216"


def detect_newline(line: bytes) -> bytes:
    if line.endswith(b"\r\n"):
        return b"\r\n"
    if line.endswith(b"\r"):
        return b"\r"
    return b"\n"


def validate_plugin(plugin: Path) -> bytes:
    payload = plugin.read_bytes()
    if len(payload) < 197:
        raise RuntimeError("CHKDSK.WMF is shorter than the Wild Commander header")
    if payload[16:32] != EXPECTED_SIGNATURE:
        raise RuntimeError("CHKDSK.WMF has an invalid Wild Commander signature")
    if payload[34] != EXPECTED_PAGES:
        raise RuntimeError(
            f"CHKDSK.WMF reserves {payload[34]} pages, expected {EXPECTED_PAGES}"
        )
    if payload[165:197] != EXPECTED_TITLE:
        actual = payload[165:197].decode("ascii", errors="replace")
        raise RuntimeError(f"unexpected CHKDSK.WMF title: {actual!r}")
    actual_sha256 = hashlib.sha256(payload).hexdigest().upper()
    if actual_sha256 != EXPECTED_SHA256:
        raise RuntimeError(
            f"unexpected CHKDSK.WMF SHA-256: {actual_sha256}"
        )
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--wc-dir", type=Path, required=True)
    args = parser.parse_args()

    plugin = args.plugin.resolve()
    wc_dir = args.wc_dir.resolve()
    ini_path = wc_dir / "wc.ini"
    if not plugin.is_file():
        raise FileNotFoundError(f"CHKDSK plugin not found: {plugin}")
    if not ini_path.is_file():
        raise FileNotFoundError(f"Wild Commander configuration not found: {ini_path}")
    payload = validate_plugin(plugin)

    # wc.ini contains historical OEM text, so preserve its bytes and line endings.
    lines = ini_path.read_bytes().splitlines(keepends=True)
    filtered: list[bytes] = []
    plugins_index: int | None = None
    filex_index: int | None = None
    unzip_index: int | None = None
    for line in lines:
        stripped = line.strip()
        if stripped.upper().startswith(b"CHKDSK.WMF"):
            continue
        if stripped.upper() == b"[PLUGINS]":
            plugins_index = len(filtered)
        elif plugins_index is not None and stripped.upper().startswith(b"FILEX.WMF"):
            filex_index = len(filtered)
        elif plugins_index is not None and stripped.upper().startswith(b"UNZIP.WMF"):
            unzip_index = len(filtered)
        filtered.append(line)
    if plugins_index is None:
        raise RuntimeError("wc.ini has no [PLUGINS] section")

    anchor = unzip_index if unzip_index is not None else filex_index
    if anchor is None:
        anchor = plugins_index
    newline = detect_newline(filtered[anchor])
    filtered.insert(anchor + 1, b"CHKDSK.WMF" + newline)
    ini_path.write_bytes(b"".join(filtered))

    destination = (wc_dir / "CHKDSK.WMF").resolve()
    if plugin != destination:
        shutil.copyfile(plugin, destination)
    if destination.read_bytes() != payload:
        raise RuntimeError("installed CHKDSK.WMF differs from the source plugin")

    print("Installed ChkDsk FAT32 v0.06 after UNZIP.WMF")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
