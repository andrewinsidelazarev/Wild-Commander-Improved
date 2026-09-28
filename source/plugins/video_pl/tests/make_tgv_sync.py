"""Тестовый TGV для проверки синхрона звука и картинки VIDEO_PL.

Кадры 256x126 (как у TGV из сети) идут в темпе TS-Conf: кадр ролика — 4
кадра TS-Conf по 48,828125 Гц, 12,20703125 кадра/с. На каждом кадре — его
номер, время и полоса, которая сдвигается на 8 точек за кадр (видно
плавность). Каждый 24-й кадр (раз в 1,966 с) — белая вспышка на весь кадр, и
ровно с её начала в звуке писк 1 кГц длиной в один кадр ролика.

Звук — MP3 32 кГц моно 64 кбит/с (его играет NeoGS). Кодер MP3 добавляет в
начало тишину, а VS1001 её не пропускает: задержка измеряется декодированием
готового MP3 (без заголовка Xing, как его видит VS1001) и вычитается, так что
в файле писк начинается точно со вспышкой. Всё, что после этого разойдётся, —
сдвиг плеера и железа.

Запуск: python make_tgv_sync.py [файл.tgv] [секунд]
"""
from pathlib import Path
import math
import struct
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[4]
FFMPEG = ROOT / 'FTViewConvert/build/ffmpeg.exe'
FPS = 48.828125 / 4
WIDTH, LINES = 256, 126
RATE = 32000
FLASH_EVERY = 24
BEEP_HZ = 1000
PALETTE = [(0, 0, 0), (255, 255, 255), (40, 40, 48), (120, 120, 130), (230, 60, 60),
           (70, 200, 90), (240, 210, 60)]


def tsconf_palette():
    words = []
    for i in range(256):
        r, g, b = PALETTE[i] if i < len(PALETTE) else (0, 0, 0)
        words.append((r >> 3) << 10 | (g >> 3) << 5 | b >> 3)
    return struct.pack('<256H', *words)


def frame_image(n, fonts):
    big, small = fonts
    flash = n % FLASH_EVERY == 0 and n > 0
    im = Image.new('P', (WIDTH, LINES), 1 if flash else 2)
    im.putpalette([c for rgb in PALETTE for c in rgb] + [0] * (768 - 3 * len(PALETTE)))
    d = ImageDraw.Draw(im)
    ink = 0 if flash else 1
    d.text((WIDTH // 2, 44), f'{n}', font=big, fill=ink, anchor='mm')
    d.text((WIDTH // 2, 84), 'FLASH + BEEP' if flash else f'{n / FPS:6.2f} s', font=small, fill=ink,
           anchor='mm')
    x = n * 8 % WIDTH                              # бегущая полоса: 8 точек за кадр
    d.rectangle((x, 96, x + 3, 108), fill=4 if not flash else 0)
    step = n % FLASH_EVERY                         # до вспышки: деления снизу
    for i in range(FLASH_EVERY):
        d.rectangle((8 + i * 10, 114, 14 + i * 10, 122), fill=5 if i <= step else 3)
    return im.tobytes()


def beeps(seconds):
    total = int(seconds * RATE)
    pcm = [0.0] * total
    length = int(RATE / FPS)
    fade = int(RATE * 0.004)
    n = FLASH_EVERY
    while n / FPS < seconds:
        start = round(n / FPS * RATE)
        for i in range(length):
            if start + i >= total:
                break
            env = min(1.0, i / fade, (length - 1 - i) / fade)
            pcm[start + i] = 0.8 * env * math.sin(2 * math.pi * BEEP_HZ * i / RATE)
        n += FLASH_EVERY
    return pcm


def pcm_bytes(pcm):
    return struct.pack(f'<{len(pcm)}h', *(int(max(-1, min(1, s)) * 32767) for s in pcm))


def encode(pcm, tmp):
    raw, mp3 = Path(tmp) / 'a.raw', Path(tmp) / 'a.mp3'
    raw.write_bytes(pcm_bytes(pcm))
    subprocess.run([str(FFMPEG), '-v', 'error', '-y', '-f', 's16le', '-ar', str(RATE), '-ac', '1',
                    '-i', str(raw), '-c:a', 'libmp3lame', '-b:a', '64k', '-write_xing', '0', str(mp3)],
                   check=True)
    return mp3.read_bytes()


def decode(mp3, tmp):
    src, raw = Path(tmp) / 'd.mp3', Path(tmp) / 'd.raw'
    src.write_bytes(mp3)
    subprocess.run([str(FFMPEG), '-v', 'error', '-y', '-i', str(src), '-f', 's16le', '-ac', '1',
                    '-ar', str(RATE), str(raw)], check=True)
    data = raw.read_bytes()
    return struct.unpack(f'<{len(data) // 2}h', data)


def onset(samples):
    """Первый отсчёт писка: громкость выше половины пиковой."""
    peak = max(abs(s) for s in samples)
    return next(i for i, s in enumerate(samples) if abs(s) > peak // 2)


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'Build/tgv/AVSYNC.TGV'
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 30
    frames = int(seconds * FPS)
    pcm = beeps(seconds)
    with tempfile.TemporaryDirectory() as tmp:
        first = onset(pcm)
        delay = onset(decode(encode(pcm, tmp), tmp)) - first
        mp3 = encode(pcm[delay:] + [0.0] * delay, tmp)       # звук раньше на задержку MP3
        check = onset(decode(mp3, tmp)) - first
    fonts = (ImageFont.truetype('arialbd.ttf', 44), ImageFont.truetype('consola.ttf', 14))
    header = bytearray(512)
    header[:16] = b'TGA Video v0.2  '
    sectors = -(-len(mp3) // 512)
    struct.pack_into('<H', header, 16, sectors)
    struct.pack_into('<H', header, 32, LINES)
    palette = tsconf_palette()
    body = bytearray(header + mp3.ljust(sectors * 512, b'\0'))
    for n in range(frames):
        body += palette + frame_image(n, fonts)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(body)
    print(f'{out}: {frames} кадров, {frames / FPS:.1f} с, MP3 {len(mp3)} байт ({sectors} секторов); '
          f'задержка MP3 {delay} отсчётов ({delay / RATE * 1000:.1f} мс) вычтена, остаток {check} '
          f'({check / RATE * 1000:.2f} мс)')


if __name__ == '__main__':
    main()
