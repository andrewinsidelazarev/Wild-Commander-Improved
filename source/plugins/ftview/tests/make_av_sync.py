"""Локальный MJPEG/PCM AVI: вспышка и тон начинаются на одной временной отметке.

Не требует ffmpeg или скачиваний. Файл нужен для наблюдения синхрона в Unreal
и на EVO; корректная разметка файла сама по себе не доказывает синхрон выхода.
"""
import argparse
import io
import json
import math
import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def chunk(tag, data):
    return tag + struct.pack('<I', len(data)) + data + bytes(len(data) & 1)


def list_chunk(tag, data):
    return chunk(b'LIST', tag + data)


def make(out, seconds=34):
    width, height, fps, rate = 512, 384, 25, 32000
    frames = seconds * fps
    per_frame = rate // fps
    font_path = Path('C:/Windows/Fonts/arialbd.ttf')
    big = ImageFont.truetype(str(font_path), 48) if font_path.exists() else ImageFont.load_default()
    small = ImageFont.truetype(str(font_path), 22) if font_path.exists() else ImageFont.load_default()
    audio = bytearray([128]) * (seconds * rate)
    pulse_frames = 2  # 80 мс: и картинка, и звук имеют одинаковую длительность.
    for second in range(2, seconds, 2):
        start = second * rate
        for sample in range(pulse_frames * per_frame):
            audio[start + sample] = round(128 + 70 * math.sin(2 * math.pi * 1000 * sample / rate))

    avih = struct.pack('<14I', 1000000 // fps, 600000, 0, 0x10, frames, 0, 2,
                       32768, width, height, 0, 0, 0, 0)
    video_header = struct.pack('<4s4sIHHIIIIIIIIhhhh', b'vids', b'MJPG', 0, 0, 0, 0,
                               1, fps, 0, frames, 32768, 0xFFFFFFFF, 0, 0, 0, width, height)
    video_format = struct.pack('<IiiHH4sIiiII', 40, width, height, 1, 24, b'MJPG',
                               width * height * 3, 0, 0, 0, 0)
    audio_header = struct.pack('<4s4sIHHIIIIIIIIhhhh', b'auds', bytes(4), 0, 0, 0, 0,
                               1, rate, 0, len(audio), 16384, 0xFFFFFFFF, 1, 0, 0, 0, 0)
    audio_format = struct.pack('<HHIIHH', 1, 1, rate, rate, 1, 8)
    header = list_chunk(b'hdrl', chunk(b'avih', avih) +
                        list_chunk(b'strl', chunk(b'strh', video_header) + chunk(b'strf', video_format)) +
                        list_chunk(b'strl', chunk(b'strh', audio_header) + chunk(b'strf', audio_format)))
    movi, index = bytearray(), bytearray()

    def add(tag, data):
        # Смещения idx1 отсчитываются от FOURCC movi, как в обычном AVI 1.0.
        index.extend(struct.pack('<4sIII', tag, 0x10, len(movi) + 4, len(data)))
        movi.extend(chunk(tag, data))

    # Звуковая дорожка передаётся с упреждением 0,5 с, но её временное начало
    # остаётся нулевым. Такой порядок чанков есть и у пользовательского AVI.
    audio_pos = rate // 2
    add(b'01wb', audio[:audio_pos])
    for frame in range(frames):
        flash = frame >= fps * 2 and frame % (fps * 2) < pulse_frames
        im = Image.new('RGB', (width, height), 'white' if flash else (24, 24, 24))
        draw = ImageDraw.Draw(im)
        ink = 'black' if flash else 'white'
        draw.text((width // 2, 48), 'A/V SYNC', font=big, fill=ink, anchor='mm')
        draw.text((width // 2, 124), 'FLASH + BEEP' if flash else 'Wait for flash + beep',
                  font=small, fill=ink, anchor='mm')
        stamp = '%02d:%02d.%02d' % (frame // fps // 60, frame // fps % 60, frame % fps * 4)
        draw.text((width // 2, 210), stamp, font=big, fill=ink, anchor='mm')
        draw.text((width // 2, 280), 'Together every 2 seconds', font=small, fill=ink, anchor='mm')
        x = 16 + (width - 32) * (frame % (2 * fps)) // (2 * fps - 1)
        draw.rectangle((x, 315, x + 3, 339), fill=ink)
        # Десять бит номера кадра позволяют проверить кадр по снимку экрана.
        for bit in range(10):
            color = (30, 140, 255) if frame & (1 << bit) else (8, 8, 32)
            draw.rectangle((96 + bit * 32, 355, 119 + bit * 32, 375), fill=color)
        encoded = io.BytesIO()
        im.save(encoded, 'JPEG', quality=85, subsampling=0)
        add(b'00dc', encoded.getvalue())
        if audio_pos < len(audio):
            part = audio[audio_pos:audio_pos + per_frame]
            add(b'01wb', part)
            audio_pos += len(part)
    assert audio_pos == len(audio)
    file = chunk(b'RIFF', b'AVI ' + header + list_chunk(b'movi', movi) + chunk(b'idx1', index))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(file)
    report = dict(seconds=seconds, frames=frames, fps=fps, audio_rate=rate, audio_samples=len(audio),
                  pulse_seconds=list(range(2, seconds, 2)), pulse_duration_ms=80, bytes=len(file))
    out.with_suffix('.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=Path(__file__).resolve().parents[1] / 'obj/avsync.avi')
    make(parser.parse_args().out)
