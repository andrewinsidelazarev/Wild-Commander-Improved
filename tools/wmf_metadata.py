"""Упаковка переменных ассоциаций WMF #11 без изменения кода плагина.

JSON: [{"extension": "TXT", "handler": 0}, ...]. handler должен соответствовать
контракту конкретного плагина; это не порядковый номер в новом списке.
Без --extensions переносит старые ассоциации, сохраняя их индексы.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

VERSION = 0x11
POOL_BYTES = 16384


def encode(entries):
    result = bytearray()
    seen = set()
    for item in entries:
        name, handler = item['extension'], item['handler']
        if not isinstance(name, str) or not 1 <= len(name) <= 255:
            raise ValueError('extension must contain 1..255 ASCII characters')
        if any(not 33 <= ord(c) < 127 or c in './\\*?' for c in name):
            raise ValueError(f'invalid extension: {name!r}')
        name = name.upper()
        if name in seen:
            raise ValueError(f'duplicate extension: {name}')
        seen.add(name)
        if type(handler) is not int or not 0 <= handler <= 255:
            raise ValueError('handler must be an integer in 0..255')
        result.extend(bytes((len(name), handler)) + name.encode('ascii'))
    if len(result) > POOL_BYTES:
        raise ValueError('metadata exceeds the current 16 KiB pool')
    return bytes(result)


def decode(header, body):
    if header[32] != VERSION:
        entries = []
        for i in range(32):
            raw = header[64 + 3*i:67 + 3*i]
            if not raw[0]:
                break
            entries.append(dict(extension=raw.decode('ascii').rstrip(' '), handler=i))
        return entries
    size = int.from_bytes(header[48:50], 'little')
    count = int.from_bytes(header[50:52], 'little')
    if header[54] != 1 or size > POOL_BYTES or len(body) < size:
        raise ValueError('invalid WMF metadata descriptor')
    entries, pos = [], 0
    for _ in range(count):
        if pos + 2 > size or not body[pos] or pos + 2 + body[pos] > size:
            raise ValueError('truncated WMF metadata record')
        length, handler = body[pos:pos + 2]
        entries.append(dict(extension=body[pos + 2:pos + 2 + length].decode('ascii'),
                            handler=handler))
        pos += 2 + length
    if pos != size:
        raise ValueError('WMF metadata count/size mismatch')
    encode(entries)
    return entries


def rewrite(blob, entries=None):
    if len(blob) < 512 or blob[16:32] != b'WildCommanderMDL' or not 2 <= blob[32] <= VERSION:
        raise ValueError('unsupported or truncated WMF header')
    header = bytearray(blob[:512])
    old = decode(header, blob[512:])
    offset = 512
    if header[32] == VERSION:
        offset += (int.from_bytes(header[48:50], 'little') + 511) // 512 * 512
    if offset > len(blob):
        raise ValueError('truncated WMF metadata sectors')
    entries = old if entries is None else entries
    data = encode(entries)
    header[32] = VERSION
    header[48:50] = len(data).to_bytes(2, 'little')
    header[50:52] = len(entries).to_bytes(2, 'little')
    header[52:54] = b'\0\0'
    header[54] = 1
    header[55:63] = bytes(8)            # резерв #11 — нули, как описано в формате
    header[64:161] = bytes(97)
    return bytes(header) + data.ljust((len(data) + 511) // 512 * 512, b'\0') + blob[offset:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--extensions', type=Path)
    args = parser.parse_args()
    if args.input.resolve() == args.output.resolve():
        parser.error('input and output must be different files')
    try:
        entries = (json.loads(args.extensions.read_text(encoding='utf-8'))
                   if args.extensions else None)
        result = rewrite(args.input.read_bytes(), entries)
    except (ValueError, KeyError, TypeError) as error:
        parser.error(str(error))
    args.output.write_bytes(result)
    print(f'WMF #11: {int.from_bytes(result[50:52], "little")} extensions, '
          f'{int.from_bytes(result[48:50], "little")} metadata bytes, {len(result)} file bytes')


if __name__ == '__main__':
    main()
