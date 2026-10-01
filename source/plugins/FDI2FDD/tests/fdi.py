"""Независимый разбор UKV FDI, эталон для сравнения с результатом ВГ93."""
from dataclasses import dataclass
import struct


@dataclass
class Sector:
    c: int
    h: int
    r: int
    n: int
    data: bytes
    deleted: bool = False
    good_crc: bool = True
    good_id_crc: bool = True

    @property
    def id(self):
        return self.c, self.h, self.r, self.n


def parse_fdi(blob):
    assert blob[:3] == b'FDI'
    wp, cylinders, heads, desc, data, extra = struct.unpack_from('<B5H', blob, 3)
    tracks = {}
    pos = 14 + extra
    for cylinder in range(cylinders):
        for side in range(heads):
            offset, reserved, count = struct.unpack_from('<IHB', blob, pos)
            pos += 7
            sectors = []
            for _ in range(count):
                c, h, r, n, flags, rel = struct.unpack_from('<5BH', blob, pos)
                pos += 7
                length = 128 << n
                start = data + offset + rel
                payload = blob[start:start + length]
                assert len(payload) == length
                sectors.append(Sector(c, h, r, n, payload, bool(flags & 128), bool(flags & (1 << n))))
            tracks[cylinder, side] = sectors
    return tracks, pos


def make_fdi(tracks, cylinders=1, heads=1):
    """Маленькие искусственные образы; данные не содержат тестовых подсказок коду."""
    table, data = bytearray(), bytearray()
    for c in range(cylinders):
        for h in range(heads):
            sectors = tracks.get((c, h), [])
            base = len(data)
            table += struct.pack('<IHB', base, 0, len(sectors))
            for sector in sectors:
                flags = (1 << sector.n) if sector.good_crc else 0
                flags |= 128 if sector.deleted else 0
                table += struct.pack('<5BH', *sector.id, flags, len(data) - base)
                data += sector.data
    description = 14 + len(table)
    header = b'FDI' + struct.pack('<B5H', 0, cylinders, heads, description, description + 1, 0)
    return header + table + b'\0' + data
