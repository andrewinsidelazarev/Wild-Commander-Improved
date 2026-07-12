#!/usr/bin/env python3
"""Pack a sector-aligned payload into a HoBeta file.

The defaults reproduce the 17-byte header of the reference Wild Commander
``boot.$C``.  The input is expected to contain the complete 0x7C00-byte
sector payload, including any bytes after the logical file length.
"""

from __future__ import annotations

import argparse
import hashlib
import struct
import sys
from pathlib import Path


DEFAULT_NAME = "WC110B"
DEFAULT_TYPE = "C"
DEFAULT_LOAD_ADDRESS = 0x6011
DEFAULT_LOGICAL_LENGTH = 0x7BC2
DEFAULT_PAYLOAD_SIZE = 0x7C00
REFERENCE_HEADER = bytes.fromhex(
    "57 43 31 31 30 42 20 20 43 11 60 C2 7B 00 7C 84 1F"
)


def parse_integer(value: str) -> int:
    """Parse a decimal, 0x-prefixed, or #-prefixed integer."""

    text = value.strip()
    if text.startswith("#"):
        text = "0x" + text[1:]
    try:
        return int(text, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid integer: {value!r}") from exc


def _single_byte(text: str, field: str) -> bytes:
    try:
        encoded = text.encode("ascii")
    except UnicodeEncodeError as exc:
        raise ValueError(f"{field} must contain ASCII characters only") from exc
    if len(encoded) != 1:
        raise ValueError(f"{field} must be exactly one byte")
    return encoded


def build_header(
    *,
    name: str = DEFAULT_NAME,
    file_type: str = DEFAULT_TYPE,
    load_address: int = DEFAULT_LOAD_ADDRESS,
    logical_length: int = DEFAULT_LOGICAL_LENGTH,
    payload_size: int = DEFAULT_PAYLOAD_SIZE,
) -> bytes:
    """Build and return a validated 17-byte HoBeta header."""

    try:
        name_bytes = name.encode("ascii")
    except UnicodeEncodeError as exc:
        raise ValueError("name must contain ASCII characters only") from exc
    if not 1 <= len(name_bytes) <= 8:
        raise ValueError("name must be between 1 and 8 ASCII bytes")
    name_bytes = name_bytes.ljust(8, b" ")
    type_byte = _single_byte(file_type, "type")

    for value, field in (
        (load_address, "load address"),
        (logical_length, "logical length"),
        (payload_size, "payload size"),
    ):
        if not 0 <= value <= 0xFFFF:
            raise ValueError(f"{field} must fit in 16 bits")

    if payload_size == 0 or payload_size % 0x100:
        raise ValueError("payload size must be a non-zero multiple of 256 bytes")
    if logical_length > payload_size:
        raise ValueError("logical length cannot exceed the sector payload size")

    prefix = struct.pack(
        "<8scHHH",
        name_bytes,
        type_byte,
        load_address,
        logical_length,
        payload_size,
    )
    if len(prefix) != 15:
        raise AssertionError("internal error: HoBeta prefix is not 15 bytes")

    # HoBeta checksum: (sum of the first 15 bytes) * 257 + 105, modulo 65536.
    checksum = (sum(prefix) * 257 + 105) & 0xFFFF
    return prefix + struct.pack("<H", checksum)


def pack_payload(
    payload: bytes,
    *,
    name: str = DEFAULT_NAME,
    file_type: str = DEFAULT_TYPE,
    load_address: int = DEFAULT_LOAD_ADDRESS,
    logical_length: int = DEFAULT_LOGICAL_LENGTH,
    expected_payload_size: int = DEFAULT_PAYLOAD_SIZE,
) -> bytes:
    """Return a complete HoBeta file for *payload*."""

    if len(payload) != expected_payload_size:
        raise ValueError(
            f"payload is {len(payload)} bytes; expected {expected_payload_size} "
            f"(0x{expected_payload_size:X})"
        )
    header = build_header(
        name=name,
        file_type=file_type,
        load_address=load_address,
        logical_length=logical_length,
        payload_size=len(payload),
    )
    return header + payload


def run_self_test() -> None:
    header = build_header()
    assert header == REFERENCE_HEADER, (
        f"reference header mismatch: {header.hex(' ')} != "
        f"{REFERENCE_HEADER.hex(' ')}"
    )

    payload = bytes((index * 17 + 3) & 0xFF for index in range(DEFAULT_PAYLOAD_SIZE))
    packed = pack_payload(payload)
    assert len(packed) == 17 + DEFAULT_PAYLOAD_SIZE
    assert packed[:17] == REFERENCE_HEADER
    assert packed[17:] == payload

    custom = build_header(
        name="TEST",
        file_type="B",
        load_address=0x8000,
        logical_length=0x1234,
        payload_size=0x1300,
    )
    assert len(custom) == 17
    assert custom[:8] == b"TEST    "
    assert struct.unpack_from("<H", custom, 15)[0] == (
        sum(custom[:15]) * 257 + 105
    ) & 0xFFFF

    try:
        pack_payload(b"too short")
    except ValueError:
        pass
    else:
        raise AssertionError("short payload was accepted")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Pack a sector-aligned binary payload into a HoBeta file. "
            "Defaults match Wild Commander exe/boot.$C."
        )
    )
    parser.add_argument("payload", nargs="?", type=Path, help="input sector payload")
    parser.add_argument("output", nargs="?", type=Path, help="output HoBeta file")
    parser.add_argument("--name", default=DEFAULT_NAME, help="HoBeta name (1-8 ASCII bytes)")
    parser.add_argument(
        "--type", dest="file_type", default=DEFAULT_TYPE, help="one-byte file type"
    )
    parser.add_argument(
        "--load",
        type=parse_integer,
        default=DEFAULT_LOAD_ADDRESS,
        help="load address (default: 0x6011)",
    )
    parser.add_argument(
        "--length",
        type=parse_integer,
        default=DEFAULT_LOGICAL_LENGTH,
        help="logical file length (default: 0x7BC2)",
    )
    parser.add_argument(
        "--expected-size",
        type=parse_integer,
        default=DEFAULT_PAYLOAD_SIZE,
        help="required input payload size (default: 0x7C00)",
    )
    parser.add_argument(
        "--self-test", action="store_true", help="run built-in checks and exit"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.self_test:
        if args.payload is not None or args.output is not None:
            parser.error("--self-test does not accept payload or output paths")
        run_self_test()
        print("pack_hobeta.py: self-test passed")
        return 0

    if args.payload is None or args.output is None:
        parser.error("payload and output paths are required unless --self-test is used")

    try:
        payload = args.payload.read_bytes()
        packed = pack_payload(
            payload,
            name=args.name,
            file_type=args.file_type,
            load_address=args.load,
            logical_length=args.length,
            expected_payload_size=args.expected_size,
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(packed)
    except (OSError, ValueError) as exc:
        print(f"pack_hobeta.py: error: {exc}", file=sys.stderr)
        return 2

    digest = hashlib.sha256(packed).hexdigest()
    print(
        f"wrote\t{args.output}\t{len(packed)}\tsha256\t{digest}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
