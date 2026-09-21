"""Генератор небольших MJPEG/PCM8 AVI для тестов: заголовок, movi и idx1.

Раскладка повторяет файл, который ffmpeg пишет для FT812 и GS: видео —
поток 0 ('00dc'), PCM u8 mono — поток 1 ('01wb'), idx1 со смещениями от
FOURCC 'movi'. Звук может опережать кадры на lead сэмплов в первом чанке.
"""
import io
import struct


def chunk(tag, data):
    return tag + struct.pack('<I', len(data)) + data + bytes(len(data) & 1)


def list_chunk(tag, data):
    return chunk(b'LIST', tag + data)


def jpeg(n, width=64, height=48):
    from PIL import Image
    out = io.BytesIO()
    Image.new('RGB', (width, height), (40 + n * 30 % 200, 40 + n * 7 % 150, 80)).save(out, 'JPEG')
    return out.getvalue()


def make_avi(frames, *, width=64, height=48, fps=25, rate=22050, audio=True,
             frame=None, lead=None, index=True, split=None):
    """Возвращает (файл, звук, сведения о чанках).

    frame(n) — байты кадра n (по умолчанию короткие фиктивные данные: без
    настоящего FT812 декодер их не разбирает). split — наибольший размер
    звукового чанка, как у ffmpeg (576 байт для Muse).
    """
    frame = frame or (lambda n: struct.pack('<I', n) + bytes((n * 13 + i) & 255 for i in range(27)))
    samples = frames * rate // fps if audio else 0
    pcm = bytes((i * 7 + i // 97) & 255 for i in range(samples))
    lead = rate // 5 if lead is None else lead
    avih = struct.pack('<14I', 1000000 // fps, 100000, 0, 0x10, frames, 0, 2 if audio else 1,
                       0, width, height, 0, 0, 0, 0)
    vh = struct.pack('<4s4sIHHIIIIIIIIhhhh', b'vids', b'MJPG', 0, 0, 0, 0, 1, fps, 0, frames,
                     0, 0xFFFFFFFF, 0, 0, 0, width, height)
    vf = struct.pack('<IiiHH4sIiiII', 40, width, height, 1, 24, b'MJPG', width * height * 3, 0, 0, 0, 0)
    strl = list_chunk(b'strl', chunk(b'strh', vh) + chunk(b'strf', vf))
    if audio:
        ah = struct.pack('<4s4sIHHIIIIIIIIhhhh', b'auds', bytes(4), 0, 0, 0, 0, 1, rate, 0,
                         samples, 0, 0xFFFFFFFF, 1, 0, 0, 0, 0)
        af = struct.pack('<HHIIHH', 1, 1, rate, rate, 1, 8)
        strl += list_chunk(b'strl', chunk(b'strh', ah) + chunk(b'strf', af))
    head = b'RIFF\0\0\0\0AVI ' + list_chunk(b'hdrl', chunk(b'avih', avih) + strl)
    movi = bytearray(b'movi')
    entries = []
    info = []

    def add(tag, data):
        entries.append(struct.pack('<4sIII', tag, 0x10, len(movi), len(data)))
        info.append((tag, len(head) + 8 + len(movi), len(data)))
        movi.extend(chunk(tag, data))

    def add_audio(start, end):
        while start < end:
            part = min(end, start + (split or end))
            add(b'01wb', pcm[start:part])
            start = part

    pos = 0
    if audio and lead:
        pos = min(samples, lead)
        add_audio(0, pos)
    for n in range(frames):
        add(b'00dc', frame(n))
        if audio:
            end = min(samples, (n + 1) * rate // fps + lead)
            if n == frames - 1:
                end = samples
            add_audio(pos, end)
            pos = max(pos, end)
    assert not audio or pos == samples
    data = bytearray(head + b'LIST' + struct.pack('<I', len(movi)) + bytes(movi))
    if index:
        data += chunk(b'idx1', b''.join(entries))
    data[4:8] = struct.pack('<I', len(data) - 8)
    movi_start = len(head) + 12
    return bytes(data), pcm, dict(movi_start=movi_start, chunks=info)
