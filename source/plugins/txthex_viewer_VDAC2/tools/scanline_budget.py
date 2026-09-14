"""Оценка нагрузки RAM_DL просмотрщика, отдельно от тактов Z80.

FT81X Programmer Guide 1.2, 2.5.7: 1 DL instruction/clock, L4 NEAREST
16 pixels/clock. Складываем выборку всех слов, очистку и перекрывающиеся
примитивы; прозрачные поля bitmap тоже считаем. Дополнительно оставляем
128 тактов на строку. Скорость 16 пикселей/такт для транспонированного
чтения здесь ПРЕДПОЛАГАЕТСЯ, но на плате не подтверждена. После фотографии
разрывов nedoos.txt эту оценку нельзя использовать как доказательство
приёмки бюджета. DLL проверяет пиксели, а не худшую задержку памяти FT812.
Поддерживается только используемое просмотрщиком подмножество команд;
неизвестная команда вызывает ошибку, а не занижение оценки.
"""
import math
import struct


def display_words(viewer):
    # После SWAP чтение RAM_DL в DLL может вернуть предыдущий буфер.
    # Берём последний поток, действительно отправленный машинным кодом.
    # Здесь после DLSTART идут только прямые DL-слова, без CMD_TEXT и т.п.
    words = struct.unpack('<'+'I'*(len(viewer.commands)//4),viewer.commands)
    start = max(i for i,w in enumerate(words) if w == 0xffffff00)
    result = words[start+1:-1]
    assert words[-1] == 0xffffff01 and result[-1] == 0
    assert all(w < 0xffffff00 for w in result)
    return result


def profile(words, width=1024, height=768, hcycle=1344, pclk=1):
    handles = [{} for _ in range(32)]
    handle = tx = ty = primitive = 0
    pixels = [0] * height
    vertices = []
    clip_x=clip_y=0
    clip_w,clip_h=width,height

    def span(x, y, w, h):
        visible = max(0, min(width,clip_x+clip_w,math.ceil(x+w)) - max(0,clip_x,math.floor(x)))
        cost = math.ceil(visible / 16)
        for row in range(max(0,clip_y,math.floor(y)), min(height,clip_y+clip_h,math.ceil(y+h))):
            pixels[row] += cost

    for word in words:
        op = word >> 24
        if word >> 30 == 2:
            assert primitive == 1, 'VERTEX2II outside BITMAPS'
            bitmap = handles[(word >> 7) & 31]
            assert bitmap['format'] == 2 and bitmap['filter'] == 0
            span(((word >> 21) & 511)+tx, ((word >> 12) & 511)+ty,
                 bitmap['w'], bitmap['h'])
        elif word >> 30 == 1:
            assert primitive == 9, 'Only RECTS VERTEX2F supported'
            x, y = (word >> 15) & 32767, word & 32767
            x = (x if x < 16384 else x-32768)/16 + tx
            y = (y if y < 16384 else y-32768)/16 + ty
            vertices.append((x, y))
            if len(vertices) == 2:
                (x0,y0),(x1,y1) = vertices
                # LINE_WIDTH=1: запас по пикселю на сглаженные края.
                span(min(x0,x1)-1, min(y0,y1)-1, abs(x1-x0)+2, abs(y1-y0)+2)
                vertices.clear()
        elif op == 5:
            handle = word & 31
        elif op == 7:
            handles[handle]['format'] = (word >> 19) & 31
        elif op == 8:
            handles[handle].update(w=(word >> 9) & 511, h=word & 511,
                                   filter=(word >> 20) & 1)
        elif op == 0x29:
            handles[handle]['w'] = (handles[handle]['w'] & 511) | (((word >> 2) & 3) << 9)
            handles[handle]['h'] = (handles[handle]['h'] & 511) | ((word & 3) << 9)
        elif op in (0x2b, 0x2c):
            value = word & 0x1ffff
            value = (value if value < 0x10000 else value-0x20000)/16
            if op == 0x2b: tx = value
            else: ty = value
        elif op == 0x1f:
            primitive = word & 15
            vertices.clear()
        elif op == 0x1b:
            clip_x,clip_y=(word >> 11) & 2047,word & 2047
        elif op == 0x1c:
            clip_w,clip_h=(word >> 12) & 4095,word & 4095
        elif op == 0x26:
            assert word & 7 == 7
            span(0,0,width,height)
        elif op == 0x0e:
            assert word & 0xfff == 16
        elif op in (0,1,2,4,0x21,0x28):
            pass
        elif op in (0x15,0x16,0x18,0x19):
            assert word & 0xffffff == (256 if op in (0x16,0x18) else 0)
        elif op in (0x17,0x1a):
            assert word & 0xffffff == 0
        else:
            raise AssertionError(f'Unaccounted DL command {word:08x}')
    reserve = 128
    totals = [len(words)+value+reserve for value in pixels]
    return dict(dl_words=len(words), budget=hcycle*pclk,
                max_estimated_clocks=max(totals), worst_scanline=totals.index(max(totals)),
                max_pixel_clocks=max(pixels), reserve_clocks=reserve,
                margin_clocks=hcycle*pclk-max(totals), hardware_measured=False,
                assumed_pixels_per_clock=16,
                timing_status='unverified: transposed RAM_G access, not hardware acceptance')
