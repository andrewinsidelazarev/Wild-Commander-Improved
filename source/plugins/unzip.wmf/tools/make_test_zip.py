"""Создать детерминированный ZIP для тестов плагина и эмулятора."""
from __future__ import annotations

import binascii
import hashlib
import json
import struct
import zlib
from dataclasses import dataclass
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ARCHIVE = PROJECT_ROOT / "build" / "unzip-test.zip"
DEFAULT_MANIFEST = PROJECT_ROOT / "build" / "unzip-test-manifest.json"


@dataclass(frozen=True)
class Entry:
    name: str
    data: bytes = b""
    method: int = 8
    descriptor: bool = False

    @property
    def is_directory(self) -> bool:
        return self.name.endswith("/")


def raw_deflate(data: bytes) -> bytes:
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    return compressor.compress(data) + compressor.flush()


def test_entries() -> tuple[Entry, ...]:
    rows = b"".join(
        f"row={index:04d}; value={(index * 3571) % 65521:05d}\r\n".encode()
        for index in range(320)
    )
    return (
        Entry("ROOT.TXT", b"Stored file in archive.\r\n", method=0),
        Entry("DIR1/", method=0),
        Entry("DIR1/DEFLATE.BIN", rows),
        Entry("DIR1/NESTED/", method=0),
        Entry(
            "DIR1/NESTED/DESCRIPTOR.TXT",
            b"Deflate data descriptor with signature.\r\n" * 40,
            descriptor=True,
        ),
        Entry("ТЕСТ/", method=0),
        Entry("ТЕСТ/ФАЙЛ.TXT", "Русский UTF-8 путь, данные сохранены.\r\n".encode()),
        Entry("IMPLICIT/DEEP/FILE.TXT", b"Parents are created recursively.\r\n"),
        Entry("BIG/WINDOW.BIN", b"0123456789ABCDEF" * 2500, descriptor=True),
    )


def make_archive(path: Path = DEFAULT_ARCHIVE) -> tuple[Path, dict[str, bytes]]:
    local_parts: list[bytes] = []
    central_parts: list[bytes] = []
    expected: dict[str, bytes] = {}
    offset = 0

    for entry in test_entries():
        name = entry.name.encode("utf-8")
        flags = 0x0800 | (0x0008 if entry.descriptor else 0)
        compressed = entry.data if entry.method == 0 else raw_deflate(entry.data)
        crc = binascii.crc32(entry.data) & 0xFFFFFFFF
        local_crc = 0 if entry.descriptor else crc
        local_compressed = 0 if entry.descriptor else len(compressed)
        local_size = 0 if entry.descriptor else len(entry.data)
        local_header = struct.pack(
            "<IHHHHHIIIHH",
            0x04034B50,
            20,
            flags,
            entry.method,
            0,
            0x0021,
            local_crc,
            local_compressed,
            local_size,
            len(name),
            0,
        )
        descriptor = (
            struct.pack("<IIII", 0x08074B50, crc, len(compressed), len(entry.data))
            if entry.descriptor
            else b""
        )
        local_record = local_header + name + compressed + descriptor
        local_parts.append(local_record)

        central_parts.append(
            struct.pack(
                "<IHHHHHHIIIHHHHHII",
                0x02014B50,
                20,
                20,
                flags,
                entry.method,
                0,
                0x0021,
                crc,
                len(compressed),
                len(entry.data),
                len(name),
                0,
                0,
                0,
                0,
                0x10 if entry.is_directory else 0,
                offset,
            )
            + name
        )
        if not entry.is_directory:
            expected[entry.name] = entry.data
        offset += len(local_record)

    central = b"".join(central_parts)
    end = struct.pack(
        "<IHHHHIIH",
        0x06054B50,
        0,
        0,
        len(central_parts),
        len(central_parts),
        len(central),
        offset,
        0,
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"".join(local_parts) + central + end)
    return path, expected


def write_manifest(path: Path, expected: dict[str, bytes]) -> None:
    manifest = {
        name: {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        for name, data in expected.items()
    }
    path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def main() -> None:
    archive, expected = make_archive()
    write_manifest(DEFAULT_MANIFEST, expected)
    print(f"{archive}: {archive.stat().st_size} bytes")
    print(f"SHA-256: {hashlib.sha256(archive.read_bytes()).hexdigest().upper()}")


if __name__ == "__main__":
    main()
