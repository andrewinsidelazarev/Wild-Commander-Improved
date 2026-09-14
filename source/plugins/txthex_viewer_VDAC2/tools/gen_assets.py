"""Ресурсы TXTVIEW2: Unicode, составные буквы и сглаженный Noto Sans Mono.

Генерация полностью локальная: TTF и лицензия входят в проект. В RAM_G
лежит транспонированный L4-атлас по 128 ячеек на bitmap handle. Цельные
глифы копируются в полосы страницы через CMD_MEMCPY; на строку текста
нужен один VERTEX2II. Handle/cell отдельных глифов используются для UI.
Таблицы Unicode и композиции остаются в отдельной странице памяти Z80.
"""
from pathlib import Path
import hashlib
import json
import struct
import unicodedata as ud
import zlib

from PIL import Image, ImageDraw, ImageFont
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build'
CELL_W, CELL_H, ADVANCE, BASELINE = 12, 34, 12, 26
RANGES = [(0x20, 0x24f), (0x300, 0x52f), (0x1c80, 0x1c8f),
          (0x1e00, 0x1eff), (0x2000, 0x206f), (0x20a0, 0x20cf),
          (0x2100, 0x214f), (0x2190, 0x22ff), (0x2500, 0x25ff),
          (0x2c60, 0x2c7f), (0xa640, 0xa69f), (0xa720, 0xa7ff),
          (0xab30, 0xab6f)]


def words(values):
    return struct.pack('<' + 'H' * len(values), *values)


def generate():
    OUT.mkdir(exist_ok=True)
    path = ROOT / 'fonts/NotoSansMono-Regular.ttf'
    cmap = TTFont(path).getBestCmap()
    codes = sorted({c for lo, hi in RANGES for c in range(lo, hi + 1)
                    if c in cmap and ud.category(chr(c)) not in ('Cc', 'Cf', 'Cn')}
                   | {0xfffd, 0x25cc})
    assert all(c in cmap for c in codes)
    glyphs = [chr(c) for c in codes]
    index = {c: i for i, c in enumerate(codes)}
    pairs = {}
    for c in codes:
        dec = ud.decomposition(chr(c)).split()
        if len(dec) != 2 or dec[0].startswith('<'):
            continue
        first, mark = [int(v, 16) for v in dec]
        if first in index and 0x300 <= mark <= 0x36f and ud.normalize('NFC', chr(first) + chr(mark)) == chr(c):
            pairs[index[first], mark] = index[c]
    # Ударение в кириллическом тексте часто не имеет готовой буквы Unicode.
    # Такие сочетания храним как дополнительные глифы, без подмены кодов файла
    # символами из Private Use Area. Для повторного запуска номера стабильны.
    for c in codes:
        if 0x400 <= c <= 0x52f and ud.category(chr(c)).startswith('L'):
            for mark in (0x300, 0x301):
                key = index[c], mark
                if key not in pairs:
                    pairs[key] = len(glyphs)
                    glyphs.append(chr(c) + chr(mark))
    assert len(glyphs) <= 4096
    font = ImageFont.truetype(str(path), 20)
    raw = bytearray()
    fitted_glyphs = []
    for text in glyphs:
        if len(text) == 1 and ud.combining(text):
            text = '\u25cc' + text
        tile = Image.new('L', (CELL_W, CELL_H))
        draw = ImageDraw.Draw(tile)
        box = draw.textbbox((0, BASELINE), text, font=font, anchor='ls')
        if box[0] < 0 or box[1] < 0 or box[2] > CELL_W or box[3] > CELL_H:
            fitted_glyphs.append([text, list(box)])
            # В Mono есть широкие диграфы и выносные диакритики. Рисуем их
            # полностью, затем вписываем по ширине: ни один штрих не отсекаем.
            wide = Image.new('L', (box[2] - box[0], CELL_H))
            ImageDraw.Draw(wide).text((-box[0], BASELINE), text, font=font,
                                     fill=255, anchor='ls')
            tile = wide.resize((CELL_W, CELL_H), Image.Resampling.LANCZOS)
            assert 0 <= box[1] and box[3] <= CELL_H, (text, box)
        else:
            draw.text((0, BASELINE), text, font=font, fill=255, anchor='ls')
        # Столбцы глифа идут подряд. CMD_MEMCPY соединяет целые глифы
        # в одну полосу без 34 отдельных копирований строк на каждую букву.
        # Матрица FT812 меняет X/Y местами при выводе, без фильтрации/масштаба.
        pixels = list(tile.transpose(Image.Transpose.TRANSPOSE).get_flattened_data())
        raw.extend(((pixels[i] + 8) // 17 << 4) | ((pixels[i + 1] + 8) // 17)
                   for i in range(0, len(pixels), 2))
    assert len(raw) <= 1024 * 1024
    compressed = zlib.compress(raw, 9)
    comp = b''.join(words([a, b, v]) for (a, b), v in sorted(pairs.items()))
    metadata = words(codes) + comp
    # Часто используемые Latin/Greek/Cyrillic до U+05FF ищутся одним чтением,
    # без двоичного поиска на каждой букве. Таблица занимает свободный хвост
    # той же страницы 1; состав шрифта и число страниц WMF не увеличиваются.
    fast_offset = len(metadata)
    fast_high = 6
    metadata += words([index.get(c,index[0xfffd]) for c in range(fast_high*256)])
    assert len(metadata) <= 16384
    (OUT / 'metadata.bin').write_bytes(metadata.ljust(16384, b'\0'))
    (OUT / 'font.l4').write_bytes(raw)
    (OUT / 'font.zlib').write_bytes(compressed)
    pages = [compressed[p:p+16384] for p in range(0, len(compressed), 16384)]
    # До поля расширений (63) помещаются 12 дескрипторов плюс терминатор.
    assert len(pages) + 2 <= 12, len(pages)
    for i, data in enumerate(pages, 2):
        (OUT / f'page{i}.bin').write_bytes(data.ljust(16384, b'\0'))
    setup = []
    for handle in range((len(glyphs) + 127) // 128):
        setup += [0x05000000 | handle,
                  0x01000000 | (handle * 128 * CELL_W * CELL_H // 2),
                  0x07000000 | (2 << 19) | ((CELL_H // 2) << 9) | CELL_W,
                  0x08000000 | (CELL_W << 9) | CELL_H]
    (OUT / 'font_setup.bin').write_bytes(struct.pack('<' + 'I'*len(setup), *setup))
    include = ['; Создано tools/gen_assets.py. Не редактировать вручную.',
               f'FONT_CODE_COUNT EQU {len(codes)}',
               f'FONT_GLYPH_COUNT EQU {len(glyphs)}',
               f'COMPOSE_TABLE EQU {len(codes)*2}',
               f'COMPOSE_COUNT EQU {len(pairs)}',
               f'FAST_GLYPH_TABLE EQU {fast_offset}',
               f'FAST_GLYPH_HIGH EQU {fast_high}',
               f'GLYPH_REPLACEMENT EQU {index[0xfffd]}',
               f'ASSET_PAD EQU {(-len(compressed)) % 4}',
               f'PLUGIN_PAGES EQU {len(pages) + 2}',
               f'FONT_RAM_BYTES EQU {len(raw)}',
               f'FONT_CELL_BYTES EQU {CELL_W*CELL_H//2}',
               f'FONT_STRIDE EQU {CELL_H//2}',
               'AssetSegments:']
    for i, data in enumerate(pages, 2):
        include += [f'        DB {i}', f'        DW 0,{len(data)}']
    include += ['        DB #FF', 'FontSetup:',
                '        INCBIN "../build/font_setup.bin"', 'FontSetupEnd:']
    split = include.index('AssetSegments:')
    (ROOT / 'src/constants.inc').write_text('\n'.join(include[:split])+'\n', encoding='utf-8')
    (ROOT / 'src/assets.inc').write_text('\n'.join(include[split:])+'\n', encoding='utf-8')
    (ROOT / 'src/descriptors.inc').write_text('\n'.join(
        f'        DB {i},32' for i in range(1, len(pages)+2))+'\n', encoding='utf-8')
    (ROOT / 'src/pages.inc').write_text('\n'.join(
        ['        ORG 0\n        INCBIN "../build/metadata.bin"'] +
        [f'        ORG 0\n        INCBIN "../build/page{i}.bin"' for i in range(2, len(pages)+2)])+'\n', encoding='utf-8')
    result = dict(codes=codes, glyphs=glyphs, compositions=[[a,b,v] for (a,b),v in sorted(pairs.items())],
                  cell=[CELL_W,CELL_H], advance=ADVANCE, baseline=BASELINE,
                  ram_g=len(raw), transposed=True, compressed=len(compressed), pages=len(pages)+2,
                  fitted_glyphs=fitted_glyphs, font_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    (OUT / 'font.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({k: (len(v) if isinstance(v, list) else v) for k,v in result.items()}, ensure_ascii=True))


if __name__ == '__main__':
    generate()
