#!/usr/bin/env python3
"""Граница частей расширения CORE32 в boot.$C (build.ps1, 2026-09-27).

Часть 1 (поток HR) лежит перед #BF60, часть 2 — в хвосте файла до #E000 (весь
boot.$C — не длиннее 32768 байт: BIOS TS-Conf читает файл целыми кластерами),
а при установке поток части 2 переносится на место потока части 1 — значит,
он должен поместиться и туда. Ищется граница, при которой обе части
укладываются во все три места и распаковываются обратно побайтно.

Длина сжатого префикса растёт с границей почти всегда, но не строго (Codex
R37-3): двоичный поиск даёт лишь начальную точку, дальше окно вокруг неё
просматривается сверху вниз, и берётся первая граница, проходящая все
проверки. MHMT не пакует вход короче 16 байт (R37-4): обе части — от 16; отказ
упаковщика у кандидата — просто неподходящий кандидат, а не конец сборки. У
отдельных длин MHMT даёт поток, который его же распаковщик не читает, —
поэтому обратная распаковка обязательна.

    python split_extension.py --raw CORE32_EXT.bin --part1-room N --part2-room M \\
        --mhmt W:/ZiFi/_spg/mhmt.exe --work W:/.../Build

Печатает «split=<смещение> part1=<длина> part2=<длина>»; не нашлось — код 1.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

MIN_PART = 16                 # MHMT: вход короче 16 байт не пакуется
ABOVE, BELOW = 48, 256        # окно просмотра вокруг двоичного поиска


def choose(raw: bytes, room1: int, room2: int, packed, unpacks,
           above: int = ABOVE, below: int = BELOW):
    """packed(data) — длина потока или None (упаковщик отказал); unpacks(data)
    — поток распаковывается обратно побайтно. Выход: (граница, длина части 1,
    длина части 2) или None."""
    lo, hi = MIN_PART, len(raw) - MIN_PART
    if lo > hi:
        return None

    def fits1(cut):
        length = packed(raw[:cut])
        return length is not None and length <= room1

    while lo < hi:
        mid = (lo + hi + 1) // 2
        if fits1(mid):
            lo = mid
        else:
            hi = mid - 1
    top = min(lo + above, len(raw) - MIN_PART)
    bottom = max(MIN_PART, lo - below)
    for cut in range(top, bottom - 1, -1):
        part1 = packed(raw[:cut])
        if part1 is None or part1 > room1:
            continue
        part2 = packed(raw[cut:])
        if part2 is None or part2 > room2 or part2 > room1:
            continue
        if unpacks(raw[:cut]) and unpacks(raw[cut:]):
            return cut, part1, part2
    return None


def mhmt_tools(mhmt: str, work: Path):
    raw_file, packed_file, check_file = (work / 'CORE32_EXT.probe.bin', work / 'CORE32_EXT.probe.CPD',
                                         work / 'CORE32_EXT.probe.verify.bin')
    cache: dict[bytes, bytes | None] = {}

    def stream(data: bytes):
        if data not in cache:
            raw_file.write_bytes(data)
            packed_file.unlink(missing_ok=True)
            run = subprocess.run([mhmt, '-hst', '-zxh', str(raw_file), str(packed_file)],
                                 capture_output=True, text=True)
            cache[data] = packed_file.read_bytes() if run.returncode == 0 and packed_file.exists() else None
        return cache[data]

    def packed(data: bytes):
        result = stream(data)
        return None if result is None else len(result)

    def unpacks(data: bytes):
        result = stream(data)
        if result is None or len(result) < 12 or result[:2] != b'HR':
            return False
        fixed = bytearray(result)                  # как Set-HrustPackedLength в build.ps1
        fixed[4:6] = len(fixed).to_bytes(2, 'little')
        packed_file.write_bytes(bytes(fixed))
        check_file.unlink(missing_ok=True)
        run = subprocess.run([mhmt, '-hst', '-zxh', '-d', str(packed_file), str(check_file)],
                             capture_output=True, text=True)
        return run.returncode == 0 and check_file.exists() and check_file.read_bytes() == data

    def cleanup():
        for name in (raw_file, packed_file, check_file):
            name.unlink(missing_ok=True)

    return packed, unpacks, cleanup


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--raw', type=Path, required=True)
    parser.add_argument('--part1-room', type=int, required=True)
    parser.add_argument('--part2-room', type=int, required=True)
    parser.add_argument('--mhmt', required=True)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args(argv)
    packed, unpacks, cleanup = mhmt_tools(args.mhmt, args.work)
    try:
        found = choose(args.raw.read_bytes(), args.part1_room, args.part2_room, packed, unpacks)
    finally:
        cleanup()
    if found is None:
        print(f'no split: part 1 room {args.part1_room}, tail room {args.part2_room}', file=sys.stderr)
        return 1
    cut, part1, part2 = found
    print(f'split={cut} part1={part1} part2={part2}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
