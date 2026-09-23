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


# --- Таблица перемотки: эталон плеера и готовая таблица FTViewConvert --------

AVI_INDEX_MAX = 5460
INDEX_MAGIC = b'FTVIEWI1'


def avi_fields(data):
    """Поля заголовка так, как их берёт avi_probe (порядок AVI_SHARED)."""
    f = dict(pcm_rate=0, movi_start=0, movi_end=0, total=0, rate=0, scale=0, bytes=0,
             pcm_total=0, width=0, height=0)
    ends = [struct.unpack_from('<I', data, 4)[0] + 8]
    pos = 12
    while True:
        while len(ends) > 1 and pos == ends[-1]:
            ends.pop()
        tag, size = struct.unpack_from('<4sI', data, pos)
        pos += 8
        end = pos + size
        if tag == b'LIST':
            sub = data[pos:pos + 4]
            if sub == b'movi':
                f['movi_start'], f['movi_end'] = pos + 4, end
                break
            if sub in (b'hdrl', b'strl'):
                ends.append(end)
                pos += 4
                continue
        elif tag == b'avih':
            v = struct.unpack_from('<10I', data, pos)
            f['total'], f['width'], f['height'] = v[4], v[8], v[9]
        elif tag == b'strh':
            kind, handler = data[pos:pos + 4], data[pos + 4:pos + 8]
            if kind == b'vids' and handler == b'MJPG':
                f['scale'], f['rate'] = struct.unpack_from('<II', data, pos + 20)
            elif kind == b'auds':
                _, f['pcm_rate'], _, f['pcm_total'] = struct.unpack_from('<IIII', data, pos + 20)
        pos = end + (size & 1)
    f['bytes'] = (f['width'] * f['height'] * 2 + 3) & ~3
    return f


def seek_table(data):
    """(шаг, записи) — как index_build строит таблицу по idx1; None — таблицы нет.

    Запись k — первый чанк idx1, начиная с которого есть и кадр k*шаг, и звук
    с сэмпла k*шаг*pcm_rate/fps: абсолютное смещение чанка, число видеочанков
    и звуковых байтов до него (u32 каждое)."""
    f = avi_fields(data)
    fps = f['rate']
    if f['bytes'] > 0xD0000 // 2 or f['movi_start'] > 0x10000 or (f['pcm_rate'] and (f['scale'] != 1 or not fps)):
        return None
    pcm_total = f['pcm_total'] if f['pcm_rate'] else 0
    pos = f['movi_end'] + (f['movi_end'] & 1)
    for _ in range(8):
        if pos + 8 > len(data):
            return None
        tag, size = struct.unpack_from('<4sI', data, pos)
        if tag == b'idx1':
            break
        pos += 8 + size + (size & 1)
    else:
        return None
    if size > len(data) - pos - 8:
        return None
    n = size >> 4
    step = f['total'] // AVI_INDEX_MAX + 1
    count = (f['total'] + step - 1) // step
    sample_step = sample_rem = 0
    if pcm_total:
        sample_step = step * f['pcm_rate']
        sample_rem = sample_step % fps
        sample_step //= fps
    frame = sample = video = audio = base = rem = k = 0
    out = []
    p = pos + 8
    while n and k < count:
        n -= 1
        e = data[p:p + 16]
        p += 16
        off, length = struct.unpack_from('<II', e, 8)
        if not video and not audio and not k:
            base = f['movi_start'] - 4 if off < f['movi_start'] else 0
        is_video = e[:3] == b'00d' and e[3:4] in (b'c', b'b')
        is_audio = bool(pcm_total) and e[:4] == b'01wb'
        while k < count and ((is_video and video >= frame) or
                             (is_audio and (audio + length) & 0xFFFFFFFF > sample)):
            out.append(struct.pack('<III', (base + off) & 0xFFFFFFFF, video, audio))
            k += 1
            frame += step
            sample += sample_step
            rem += sample_rem
            if rem >= fps:
                rem -= fps
                sample += 1
        if is_video:
            video += 1
        if is_audio:
            audio += length
    return (step, b''.join(out)) if k else None


def embed_index(data):
    """Файл с готовой таблицей, как пишет FTViewConvert: JUNK перед idx1 —
    подпись, шаг и число записей (u16), поля AVI_SHARED от pcm_rate до
    pcm_total (30 байт), два байта выравнивания и записи."""
    f = avi_fields(data)
    step, entries = seek_table(data)
    fields = struct.pack('<HIIIIIII', f['pcm_rate'], f['movi_start'], f['movi_end'], f['total'],
                         f['rate'], f['scale'], f['bytes'], f['pcm_total'])
    payload = INDEX_MAGIC + struct.pack('<HH', step, len(entries) // 12) + fields + bytes(2) + entries
    pos = f['movi_end'] + (f['movi_end'] & 1)
    out = bytearray(data[:pos] + chunk(b'JUNK', payload) + data[pos:])
    out[4:8] = struct.pack('<I', len(out) - 8)
    return bytes(out)
