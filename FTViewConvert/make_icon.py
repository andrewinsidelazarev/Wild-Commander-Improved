"""Иконка FTViewConvert: app.ico рядом со скриптом (нужен Pillow).

Кадр плёнки с кнопкой воспроизведения. Каждый размер рисуется отдельно с
4-кратным запасом и уменьшается: у 16–24 точек нет перфорации, треугольник
крупнее. Размеры до 64 хранятся в ICO как 32-битный BMP с маской, 256 — PNG,
как в иконках Windows.
"""
from io import BytesIO
from pathlib import Path
import struct

from PIL import Image, ImageDraw

SIZES = (16, 20, 24, 32, 40, 48, 64, 256)
SCALE = 4


def render(size):
    s = size * SCALE
    top, bottom = (43, 91, 215), (19, 35, 90)
    grad = Image.new('RGBA', (s, s))
    d = ImageDraw.Draw(grad)
    for y in range(s):
        t = y / (s - 1)
        d.line([(0, y), (s, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    mask = Image.new('L', (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, s - 1, s - 1], radius=round(s * 0.2), fill=255)
    im = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    im.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(im)
    small = size < 32
    if not small:
        # Перфорация плёнки сверху и снизу.
        w, h = s * 0.11, s * 0.075
        for row in (0.1, 0.9 - 0.075):
            for i in range(4):
                x = s * 0.17 + i * (s * 0.66 - w) / 3
                d.rounded_rectangle([x, s * row, x + w, s * row + h], radius=h * 0.3, fill=(221, 230, 255, 235))
    # Кнопка воспроизведения, центр тяжести треугольника — в центре значка.
    th = s * (0.56 if small else 0.42)
    tw = th * 0.9
    cx, cy = s * 0.5 + tw / 6, s * 0.5
    d.polygon([(cx - tw * 2 / 3, cy - th / 2), (cx - tw * 2 / 3, cy + th / 2), (cx + tw / 3, cy)],
              fill=(255, 168, 38, 255))
    return im.resize((size, size), Image.LANCZOS)


def dib(im):
    """Кадр ICO в формате BMP: заголовок, BGRA снизу вверх, маска AND."""
    w, h = im.size
    px = im.tobytes('raw', 'BGRA')
    xor = b''.join(px[y * w * 4:(y + 1) * w * 4] for y in reversed(range(h)))
    stride = (w + 31) // 32 * 4
    alpha = im.getchannel('A').tobytes()
    mask = bytearray()
    for y in reversed(range(h)):
        row = bytearray(stride)
        for x in range(w):
            if not alpha[y * w + x]:
                row[x >> 3] |= 0x80 >> (x & 7)
        mask += row
    return struct.pack('<IiiHHIIiiII', 40, w, h * 2, 1, 32, 0, len(xor) + len(mask), 0, 0, 0, 0) + xor + bytes(mask)


def png(im):
    out = BytesIO()
    im.save(out, 'PNG', optimize=True)
    return out.getvalue()


def main():
    frames = [(n, png(render(n)) if n >= 256 else dib(render(n))) for n in SIZES]
    head = struct.pack('<HHH', 0, 1, len(frames))
    offset = len(head) + 16 * len(frames)
    entries, blobs = b'', b''
    for n, data in frames:
        entries += struct.pack('<BBBBHHII', n % 256, n % 256, 0, 0, 1, 32, len(data), offset + len(blobs))
        blobs += data
    path = Path(__file__).with_name('app.ico')
    path.write_bytes(head + entries + blobs)
    print(path, path.stat().st_size, 'bytes')


if __name__ == '__main__':
    main()
