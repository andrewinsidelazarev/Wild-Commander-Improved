"""VIDEO_PL: вывод TGV на FT812 (VDAC2).

Код плеера исполняется на модели Z80 (как в test_video_pl.py). Модель FT812:
SPI через порты #77/#57 Z-контроллера, команды хоста, RAM_G, дисплей-лист,
регистры; счётчик кадров REG_FRAMES идёт по времени Z80 с периодом из
HCYCLE/VCYCLE (64 МГц), REG_DLSWAP держит 2 до конца кадра, в котором список
записан. DMA TS-Conf ОЗУ -> SPI берёт байты из модели видеостраниц, куда их
кладёт LOAD256 (две строки по 256 байт с шагом 512 на сектор).

Проверяется: без VDAC2 плеер не трогает шину FT812; запуск FT812 и развёртка;
каждый кадр ролика — с ближайшего к его точному времени кадра FT812 (12,207
кадра/с на 59,084 Гц); в RAM_G при показе — точки кадра и его палитра RGB565;
дисплей-лист; звук стартует, когда FT812 показал первый кадр.
"""
from pathlib import Path
import struct
import unittest

import test_video_pl as base

LINES = 126                           # строк кадра по умолчанию (как KINO)
STEP = 4 * 256 + 0xD7                 # 4,8398 кадра FT812 на кадр ролика (8.8)


class FT812Model:
    def __init__(self, clock, lines=LINES):
        self.clock, self.lines = clock, lines
        self.ram = bytearray(0x100000)
        self.dl = bytearray(0x2000)
        self.reg = bytearray(0x1000)
        self.sel = False
        self.tx = bytearray()
        self.resp = []
        self.host = []
        self.swaps = []
        self.start = None
        self.pending = None

    def reg16(self, a):
        i = a - 0x302000
        return self.reg[i] | self.reg[i + 1] << 8

    def period(self):
        """Такты ZX (14 МГц) на кадр FT812 (64 МГц, HCYCLE*VCYCLE точек)."""
        return 14e6 * self.reg16(0x30202C) * self.reg16(0x302040) / 64e6

    def frames(self):
        if self.start is None:
            return 0
        return int((self.clock() - self.start) // self.period())

    def select(self, on):
        if on:
            self.sel, self.tx, self.resp = True, bytearray(), []
            return
        if self.sel and len(self.tx) == 3 and self.tx[0] >> 6 != 2:
            self.host.append((self.tx[0], self.tx[1]))
        self.sel = False

    def spi_out(self, b):
        if not self.sel:
            return
        t = self.tx
        t.append(b)
        if len(t) == 4 and t[0] >> 6 == 0:            # чтение: адрес и пустой байт
            a = (t[0] & 0x3F) << 16 | t[1] << 8 | t[2]
            self.resp = [0] + [self.read8(a + i) for i in range(4)]
        elif len(t) > 3 and t[0] >> 6 == 2:           # запись с автоинкрементом
            a = (t[0] & 0x3F) << 16 | t[1] << 8 | t[2]
            self.write8(a + len(t) - 4, b)

    def spi_in(self):
        return self.resp.pop(0) if self.resp else 0xFF

    def read8(self, a):
        if a == 0x302000:
            return 0x7C
        if 0x302004 <= a < 0x302008:
            return self.frames() >> 8 * (a - 0x302004) & 255
        if 0x302020 <= a < 0x302024:
            return 0
        if a == 0x302054:
            if self.pending is not None and self.frames() > self.pending:
                self.pending = None
            return 0 if self.pending is None else 2
        if 0x302000 <= a < 0x303000:
            return self.reg[a - 0x302000]
        return self.ram[a] if a < 0x100000 else 0

    def write8(self, a, v):
        if a < 0x100000:
            self.ram[a] = v
        elif 0x300000 <= a < 0x302000:
            self.dl[a - 0x300000] = v
        elif 0x302000 <= a < 0x303000:
            self.reg[a - 0x302000] = v
            if a == 0x302070 and v == 1 and self.start is None:
                self.start = self.clock()
            if a == 0x302054 and v == 2:
                f = self.frames()
                self.pending = f
                words = struct.unpack_from('<16I', self.dl)
                src = next((w & 0x3FFFFF for w in words if w >> 24 == 0x01), None)
                pal = next((w & 0x3FFFFF for w in words if w >> 24 == 0x2A), None)
                self.swaps.append(dict(
                    shown=f + 1, words=words,
                    pixels=bytes(self.ram[src:src + self.lines * 256]) if src is not None else None,
                    palette=bytes(self.ram[pal:pal + 512]) if pal is not None else None))


def frame_data(n, lines=LINES):
    pal = [(n * 37 + i * 113) & 0x7FFF for i in range(256)]
    pixels = bytes((n * 7 + y * 3 + x) & 255 for y in range(lines) for x in range(256))
    return struct.pack('<256H', *pal) + pixels


def rgb565(data):
    words = struct.unpack('<256H', data[:512])
    return struct.pack('<256H', *(((w & 0x7FE0) << 1) | (w & 0x1F) for w in words))


class FTPlayer(base.Player):
    def __init__(self, vdac2=True, frames=0, lines=LINES):
        super().__init__()
        self.vdac2, self.lines = vdac2, lines
        self.ft = FT812Model(self.now, lines) if vdac2 else None
        self.spi_touched = False
        self.pages = {}
        self.c000 = None
        self.dma = {}
        self.vmode = None
        self.stream = b''.join(frame_data(n, lines) for n in range(frames))
        self.pos = 0
        self.ticks = self.base_ticks = self.slice = 0
        self.gs_frames = []

    def now(self):
        left = int.from_bytes(bytes(self.cpu._StateBase__ticks_to_stop), 'little')
        return self.base_ticks + self.slice - left

    def input(self, port):
        if port == 0x00AF:
            return 7 if self.vdac2 else 0
        if port & 0xFF == 0xAF:
            return 0                              # DMA завершён
        if port & 0xFF == 0x57:
            return self.ft.spi_in() if self.ft else 0xFF
        return super().input(port)

    def output(self, port, value):
        p = port & 0xFF
        if p == 0x77:
            if self.ft:
                self.ft.select(value == 0x07)
            elif value == 0x07:
                self.spi_touched = True
        elif p == 0x57:
            if self.ft:
                self.ft.spi_out(value)
            else:
                self.spi_touched = True
        elif p == 0xAF:
            reg = port >> 8
            self.dma[reg] = value
            if reg == 0x27:
                assert value == 0x82, ('DMA mode', hex(value))
                page, offset = self.dma[0x1C], self.dma[0x1A] | self.dma[0x1B] << 8
                count = (self.dma[0x26] + 1) * 2 * (self.dma[0x28] + 1)
                assert offset + count <= 0x4000, ('DMA leaves page', offset, count)
                for b in self.pages.setdefault(page, bytearray(0x4000))[offset:offset + count]:
                    self.ft.spi_out(b)
        else:
            if p == 0xBB and self.ft:
                self.gs_frames.append((value, self.ft.frames()))
            super().output(port, value)

    def api(self):
        m = self.cpu
        f = m.a
        alt = bytes(m._Z80State__alt_af)[1]
        if f == 65:                               # MNGCVPL: видеостраница в #C000
            self.c000 = 0x20 + alt
        elif f == 66:                             # GVmod
            self.vmode = alt
        elif f in (48, 60):                       # LOAD512 / LOAD256
            if self.pos >= len(self.stream):
                self.calls.append(f)
                m.a = 0x0F
                m.pc = m.memory[m.sp] | m.memory[m.sp + 1] << 8
                m.sp = (m.sp + 2) & 0xFFFF
                return
            size = 512 * m.b
            chunk = self.stream[self.pos:self.pos + size]
            self.pos += size
            if f == 48:
                m.set_memory_block(m.hl, chunk)
            else:
                page = self.pages.setdefault(self.c000, bytearray(0x4000))
                line = (m.hl - 0xC000) // 512
                for i in range(0, len(chunk), 256):
                    at = (line + i // 256) * 512
                    page[at:at + 256] = chunk[i:i + 256]
        else:
            return super().api()
        self.calls.append(f)
        m.a = 0
        m.pc = m.memory[m.sp] | m.memory[m.sp + 1] << 8
        m.sp = (m.sp + 2) & 0xFFFF

    def call(self, name, hl=0, ix=None, frames=6000):
        m = self.cpu
        m.sp = 0x5D00
        m.set_memory_block(m.sp, base.RETURN.to_bytes(2, 'little'))
        m.pc = self.s[name]
        m.hl = hl
        if ix is not None:
            m.ix = ix
        for _ in range(frames):
            left = base.FRAME
            while left:
                self.base_ticks, self.slice = self.ticks, left
                m.ticks_to_stop = left
                event = m.run()
                rest = int.from_bytes(bytes(m._StateBase__ticks_to_stop), 'little')
                self.ticks += left - rest
                left = rest
                if m.pc == base.RETURN:
                    return
                if event & 2 and m.pc == 0x6006:
                    self.api()
                    if m.pc == base.RETURN:
                        return
            m.on_handle_active_int()
        raise AssertionError(('Execution limit', name, hex(m.pc)))

    def set16(self, name, value):
        self.cpu.set_memory_block(self.s[name], value.to_bytes(2, 'little'))

    def carry(self):
        return self.cpu.f & 1


class FT812Output(unittest.TestCase):
    def test_without_vdac2_ft812_is_not_touched(self):
        p = FTPlayer(vdac2=False)
        p.call('FTBOOT')
        self.assertEqual(p.cpu.memory[p.s['FTOK']], 0)
        p.set16('LNZ', LINES // 2)
        p.call('FTSTART')
        self.assertEqual(p.carry(), 1)            # вывод остаётся на TS-Conf
        self.assertEqual(p.cpu.memory[p.s['FTON']], 0)
        self.assertFalse(p.spi_touched)
        self.assertIsNone(p.vmode)

    def test_boot_uses_standard_1024x768_59(self):
        p = FTPlayer()
        p.call('FTBOOT')
        self.assertEqual(p.cpu.memory[p.s['FTOK']], 1)
        self.assertEqual(p.ft.host, [(0x43, 0), (0x00, 0), (0x42, 0), (0x44, 0), (0x61, 0x48), (0x00, 0), (0x68, 0)])
        regs = {name: p.ft.reg16(a) for name, a in (('HCYCLE', 0x30202C), ('HOFFSET', 0x302030),
                                                    ('HSIZE', 0x302034), ('HSYNC0', 0x302038),
                                                    ('HSYNC1', 0x30203C), ('VCYCLE', 0x302040),
                                                    ('VOFFSET', 0x302044), ('VSIZE', 0x302048),
                                                    ('VSYNC0', 0x30204C), ('VSYNC1', 0x302050))}
        self.assertEqual(regs, dict(HCYCLE=1344, HOFFSET=320, HSIZE=1024, HSYNC0=24, HSYNC1=160,
                                    VCYCLE=806, VOFFSET=37, VSIZE=768, VSYNC0=2, VSYNC1=8))
        self.assertEqual(p.ft.reg[0x70], 1)       # PCLK: 64 МГц
        self.assertIsNone(p.vmode)                # экран ещё на TS-Conf

    def play(self, frames, lines, sound=True):
        p = FTPlayer(frames=frames, lines=lines)
        p.call('FTBOOT')
        p.set16('LNZ', lines // 2)
        for name in ('PGNA', 'PGV'):
            p.cpu.memory[p.s[name]] = 0
        p.cpu.memory[p.s['SNDGO']] = int(sound)   # MP3 залит и ждёт первого кадра
        p.call('FTSTART')
        self.assertEqual(p.carry(), 0)
        self.assertEqual(p.vmode, 0x87)           # монитор — на FT812
        p.ft.swaps.clear()                        # без чёрного экрана запуска
        p.call('MAINFT')
        return p

    def test_frames_on_nearest_ft812_frame_with_their_pixels(self):
        # 126 строк — KINO, 144 — Bilby (16:9), 192 — наибольший кадр: кадры
        # в RAM_G не налезают друг на друга и на палитры.
        for lines, frames in ((126, 40), (144, 24), (192, 16)):
            with self.subTest(lines=lines):
                p = self.play(frames, lines)
                swaps = p.ft.swaps
                self.assertGreaterEqual(len(swaps), frames - 4)
                d0 = swaps[0]['shown']
                for n, swap in enumerate(swaps):
                    # Точное время кадра n — d0 + n*4,8398 кадра FT812; показ —
                    # с ближайшего кадра FT812 (половина — к следующему).
                    self.assertEqual(swap['shown'], (d0 * 256 + n * STEP + 128) // 256, (lines, n))
                    data = frame_data(n, lines)
                    self.assertEqual(swap['pixels'], data[512:], (lines, n))
                    self.assertEqual(swap['palette'], rgb565(data), (lines, n))
                shown = [s['shown'] for s in swaps]
                self.assertEqual(set(b - a for a, b in zip(shown, shown[1:])), {4, 5})
                # Звук: команда «играть» одна и в кадре, когда первый кадр уже
                # на экране.
                self.assertEqual([f for v, f in p.gs_frames if v == 1], [d0])

    def test_display_list_scales_and_centers(self):
        for lines in (126, 144):
            with self.subTest(lines=lines):
                p = self.play(6, lines, sound=False)
                h = lines * 4                     # высота на экране (x4)
                words = set(p.ft.swaps[0]['words'])
                expect = {
                    0x07720000 | lines,           # BITMAP_LAYOUT(PALETTED565, 256, строк)
                    0x28000000,                   # BITMAP_LAYOUT_H(0, 0)
                    0x08100000 | (h & 0x1FF),     # BITMAP_SIZE(BILINEAR, BORDER, BORDER, 1024, h)
                    0x29000008 | h >> 9,          # BITMAP_SIZE_H(1024 >> 9, h >> 9)
                    0x15000040, 0x19000040,       # BITMAP_TRANSFORM_A/E: x4
                    0x1F000001,                   # BEGIN(BITMAPS)
                    0x80000000 | (768 - h) // 2 << 12,  # VERTEX2II(0, по центру)
                }
                self.assertEqual(expect - words, set())
                self.assertEqual([v for v, f in p.gs_frames if v == 1], [])

if __name__ == '__main__':
    unittest.main(verbosity=2)
