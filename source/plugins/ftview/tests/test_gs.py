"""Звук AVI через General Sound: код плагина Z80, ПЗУ GS и драйвер FTView вместе.

Процессор ZX исполняет собранный WMF (как в test_ftview.py), процессор GS —
образ ПЗУ GS 1.05a и загруженный через него драйвер (tests/gsemu.py). Порты
#BB/#B3 соединяют их; время GS идёт вместе с тактами ZX. FT812 здесь модель:
команды завершаются сразу, поэтому темп кадров задают только часы GS.
Проверяется протокол и порядок сэмплов на ЦАП, а не звучание на слух.
"""
from pathlib import Path
import argparse
import json
import struct
import sys
import unittest

from intelhex import IntelHex

import test_ftview
from test_ftview import Machine, OUT
from gsemu import GS, find_rom
from avigen import make_avi

ROM = find_rom()


def need_rom(test):
    return unittest.skipUnless(ROM, 'GS ROM (Unreal rom/gs105a.rom) not found; set GS_ROM_DIR')(test)


def driver(out):
    ih = IntelHex(str(out/'gs/gsdrv.ihx'))
    return ih.minaddr(), bytes(ih.tobinarray(start=ih.minaddr(), end=ih.maxaddr()))


def booted_gs(out):
    """GS после холодного старта ПЗУ (около 2 с времени GS: тест памяти)."""
    sym = json.loads((out/'build.json').read_text())['gs']['symbols']
    g = GS(ROM, dac={sym['gs_dac_left']: 0, sym['gs_dac_right']: 2})
    while not 0x026E <= g.cpu.pc <= 0x0292:
        g.run(12000)
    return g


def pcm_sample(frame, rate=22050, fps=25):
    return frame * rate // fps


class DeafGS:
    """Высокоуровневая эмуляция без процессора (Unreal GSType=BASS): статус
    всегда «готов», #13/#14 не исполняются, ответов нет."""
    def __init__(self):
        self.commands = []

    def run(self, ticks):
        pass

    def zx_in(self, port):
        return 0x7E if port & 255 == 0xBB else 0xFF

    def zx_out(self, port, value):
        if port & 255 == 0xBB:
            self.commands.append(value)


@need_rom
class Boot(unittest.TestCase):
    def test_driver_uploaded_through_rom(self):
        g = booted_gs(OUT)
        m = Machine(bank='image', gs=g)
        m.call('_gs_boot', limit=200000)
        self.assertEqual(m.cpu.a, 1)
        org, code = driver(OUT)
        # С gs_vars начинаются переменные драйвера: их меняет сам драйвер.
        n = json.loads((OUT/'build.json').read_text())['gs']['symbols']['gs_vars'] - org
        self.assertEqual(bytes(g.cpu.memory[org:org + n]), code[:n])
        self.assertEqual(g.page, 2)
        self.assertTrue(org <= g.cpu.pc < org + len(code), hex(g.cpu.pc))
        # IM2: байт вектора на шине настоящего GS не определён (модель и
        # Unreal дают #FF). Таблица из 257 одинаковых байтов ведёт в
        # обработчик #5050 при любом байте.
        sym = json.loads((OUT/'build.json').read_text())['gs']['symbols']
        self.assertEqual(sym['gs_isr'], 0x5050)
        self.assertEqual(bytes(g.cpu.memory[0x5C00:0x5D01]), b'\x50' * 257)
        self.assertEqual(bytes(g.cpu._Z80State__ir)[1], 0x5C)
        self.assertEqual(bytes(g.cpu._Z80State__int_mode)[0], 2)
        # Повторный запуск плагина: #F3 выводит прежний драйвер в ПЗУ.
        m.call('_gs_boot', limit=200000)
        self.assertEqual(m.cpu.a, 1)
        self.assertEqual(bytes(g.cpu.memory[org:org + n]), code[:n])

    def test_absent_card_is_quick(self):
        m = Machine(bank='image')
        m.call('_gs_boot', limit=100)
        self.assertEqual(m.cpu.a, 0)

    def test_emulation_without_cpu_keeps_ft812_sound(self):
        gs = DeafGS()
        m = Machine(bank='image', gs=gs)
        m.call('_gs_boot', limit=400000)
        self.assertEqual(m.cpu.a, 0)
        self.assertEqual(gs.commands[:3], [0xF3, 0x14, 0x13])
        self.assertEqual(gs.commands[-1], 0x01)


class GSPlayer(Machine):
    """Покадровый режим со звуком на GS и сценарием клавиш."""

    def __init__(self, data, *, actions=(), **kw):
        super().__init__(data, **kw)
        self.set('_gs_loaded', 1)
        self.actions = list(actions)   # (условие(кадр, машина), код клавиши)
        self.pressed = None
        self.draws = []                # (кадр, сэмпл GS, воспроизведено)
        self.restarts = []             # длина media на каждом avi_restart
        self.seeks = []                # целевые кадры
        self.paused_at = None
        self.watch = {self.s['_avi_draw']: self.on_draw,
                      self.s['_avi_restart']: self.on_restart}

    def on_draw(self):
        if self.bank == 'video':
            self.draws.append((self.get('_avi_frame', 4) - 1,
                               self.get('_pcm_drop', 4) + self.get('_pcm_played', 4),
                               len(self.gs.samples)))

    def on_restart(self):
        if self.bank == 'video':
            self.restarts.append(len(self.media))

    def api(self):
        key = self.cpu.a
        if 0x10 <= key <= 0x1C:
            frame = self.get('_avi_frame', 4)
            pressed = False
            if self.actions and self.actions[0][1] == key and self.actions[0][0](frame, self):
                self.actions.pop(0)
                pressed = True
            if not self.actions and frame == self.get('_avi_total', 4) and self.get('_avi_paused'):
                self.cpu.memory[0x6004] = 1
            self.cpu.f = 0 if pressed else 0x40
            self.api_calls.append(key)
            self.ret()
        else:
            super().api()


def segments(samples, pcm, starts):
    """DAC должен дать pcm[starts[0]:...] + pcm[starts[1]:...] + ... подряд."""
    runs = []
    it = iter(starts)
    pos = None
    for value in samples:
        if pos is not None and pos < len(pcm) and pcm[pos] == value:
            pos += 1
            continue
        start = next(it)
        assert pcm[start] == value, ('segment start', start, value, pcm[start])
        if pos is not None:
            runs[-1][1] = pos
        runs.append([start, None])
        pos = start + 1
    runs[-1][1] = pos
    return runs


@need_rom
class Playback(unittest.TestCase):
    def play(self, data, actions=(), frames=None, limit=3000000):
        g = booted_gs(OUT)
        boot = Machine(bank='image', gs=g)
        boot.call('_gs_boot', limit=200000)
        self.assertEqual(boot.cpu.a, 1)
        g.samples.clear()
        m = GSPlayer(data, gs=g, actions=actions)
        m.call('_show_avi', limit=limit)
        self.assertEqual(m.get('_view_failed'), 0)
        self.assertEqual(m.get('_pcm_gs'), 1)
        return m, g

    def check_sync(self, m, fps=25, rate=22050):
        # Кадр показывается, когда звук дошёл до его отметки, и не позже
        # следующего кадра: FT812-модель мгновенна, темп задаёт только GS.
        for frame, played, _ in m.draws:
            self.assertGreaterEqual(played + 1, pcm_sample(frame, rate, fps) if frame else 0, (frame, played))
            self.assertLessEqual(played, pcm_sample(frame + 2, rate, fps), (frame, played))

    def test_plays_all_samples_in_time(self):
        data, pcm, _ = make_avi(60)
        m, g = self.play(data)
        left = [v for _, c, v in g.samples if c == 0]
        right = [v for _, c, v in g.samples if c == 2]
        self.assertEqual(left, list(pcm))
        self.assertEqual(right, left)
        self.assertEqual(m.get('_avi_frame', 4), 60)
        # Первый кадр — до старта звука, остальные по часам GS.
        self.check_sync(m)
        self.assertEqual([f for f, _, _ in m.draws], list(range(60)) + [59])

    def test_pause_holds_gs_and_resumes_without_restart(self):
        data, pcm, _ = make_avi(40)
        state = {}

        def pause(frame, m):
            return frame >= 10

        def resume(frame, m):
            # Во время паузы позиция GS не меняется; держим паузу ~0,2 с.
            n = len(m.gs.samples)
            if 'n' not in state:
                state['n'], state['ticks'] = n, m.gs.ticks
                return False
            assert n <= state['n'] + 2, 'GS advances while paused'
            return m.gs.ticks - state['ticks'] > 12000 * 200

        m, g = self.play(data, [(pause, 0x10), (resume, 0x10)])
        left = [v for _, c, v in g.samples if c == 0]
        self.assertEqual(left, list(pcm))
        self.assertEqual(len(m.restarts), 1)   # только начальный старт

    def test_seeks_restart_audio_at_target(self):
        # 16 с: шаг Left/Right — 10 с (250 кадров) от показанного кадра.
        data, pcm, _ = make_avi(400, split=576)
        targets = []

        def press(n, delta, below=10 ** 6):
            # below — кадр ещё до прежней позиции: перемотка уже произошла,
            # а не нажата вместе с предыдущей клавишей в той же итерации.
            def cond(frame, m):
                if not n <= frame < below:
                    return False
                shown = frame - 1
                targets.append(0 if delta is None else max(0, min(399, shown + delta)))
                return True
            return cond

        m, g = self.play(data, [(press(30, 250), 0x14), (press(300, -250), 0x13),
                                (press(80, None, 250), 0x1B)])
        expect = [0] + [pcm_sample(t) for t in targets]
        left = [v for _, c, v in g.samples if c == 0]
        runs = segments(left, pcm, expect)
        self.assertEqual([r[0] for r in runs], expect)
        self.assertEqual(runs[-1][1], len(pcm))
        self.assertEqual(m.get('_avi_frame', 4), 400)
        # Перемотка через таблицу idx1: позиция потока — проходом цепочки FAT
        # и GIPAG, а не повторным чтением файла с начала.
        self.assertTrue(m.gipags)
        self.check_sync(m)

    def test_seek_stream_is_header_junk_and_chunks(self):
        data, pcm, info = make_avi(120, split=576)
        m, g = self.play(data, [(lambda f, m: f >= 5, 0x14)])
        # Второй старт: заголовок до 'movi', JUNK и файл с точки входа.
        start = m.restarts[1]
        stream = bytes(m.media[start:])
        movi = info['movi_start']
        self.assertEqual(stream[:movi], data[:movi])
        self.assertEqual(stream[movi:movi + 4], b'JUNK')
        size = struct.unpack_from('<I', stream, movi + 4)[0]
        self.assertEqual(size % 2, 0)
        entry = movi + 8 + size
        seek_pos = m.get('_avi_seek_pos', 4)
        self.assertGreater(seek_pos, movi)
        # Заголовок с JUNK кончается на границе 4 байтов, дальше — байты
        # файла с seek_pos & ~3 (хвост JUNK) и сам чанк.
        self.assertEqual((entry - (seek_pos & 3)) % 4, 0)
        # После JUNK поток идёт ровно с чанка точки входа.
        self.assertEqual(stream[entry:entry + 64], data[seek_pos:seek_pos + 64])
        self.assertIn(stream[entry:entry + 4], (b'00dc', b'01wb'))
        # До перемотки прочитано начало файла, после — только хвост.
        self.assertEqual(m.get('_avi_frame', 4), 120)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=OUT)
    args, rest = parser.parse_known_args()
    OUT = test_ftview.OUT = args.out
    unittest.main(argv=[sys.argv[0], *rest])
