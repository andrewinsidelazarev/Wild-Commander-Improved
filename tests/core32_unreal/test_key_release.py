"""USPO (API 46) не виснет, если отпускание клавиши потерялось.

Исполняется собранный код WC из Build/boot.payload.bin (с #6011): USPO по
адресу ABI #744B уходит в USPO_SAFE (MD20). Кадровое прерывание — IM 1 с RET
по #0038; перед каждым прерыванием тест обновляет таблицу клавиш TAB так же,
как это сделал бы обработчик PS/2: автоповтор снова отмечает зажатую клавишу,
отпускание её очищает, а потерянное отпускание оставляет отметку навсегда.
"""
import re
import unittest
from pathlib import Path

import z80

ROOT = Path(__file__).resolve().parents[2]
PAYLOAD = ROOT / 'Build/boot.payload.bin'
BASE = 0x6011
SYMBOL_RE = re.compile(r'^([^:]+):\s+EQU\s+0x([0-9A-Fa-f]+)$')
TAB = 0x76B4                    # двадцать ячеек состояния клавиш (PS2P)
F2 = 4                          # ячейка F-клавиш: скан-код #06 — F2
STUB, STACK, STOP = 0x5E00, 0x5F00, 0xFF00


def symbols(path):
    out = {}
    for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
        match = SYMBOL_RE.match(line.strip())
        if match:
            out[match.group(1)] = int(match.group(2), 16)
    return out


B = symbols(ROOT / 'Build/boot.sym')


class Release(unittest.TestCase):

    def setUp(self):
        m = self.m = z80.Z80Machine()
        m.memory[0:0x10000] = bytes(0x10000)
        data = PAYLOAD.read_bytes()
        m.memory[BASE:BASE + len(data)] = data
        m.memory[0x38] = 0xC9                                   # обработчик: RET
        uspo = B['USPO']
        m.memory[STUB:STUB + 5] = bytes([0xED, 0x56, 0xC3, uspo & 0xFF, uspo >> 8])  # IM 1; JP USPO
        m.memory[STACK:STACK + 2] = STOP.to_bytes(2, 'little')

    def test_uspo_goes_through_the_safe_loop(self):
        m = self.m
        self.assertEqual(B['USPO'], 0x744B, 'адрес USPO задан ABI')
        self.assertEqual(bytes(m.memory[0x744B:0x744E]),
                         bytes([0xC3, B['USPO_SAFE'] & 0xFF, B['USPO_SAFE'] >> 8]))
        self.assertEqual(bytes(m.memory[B['ANYK']:B['ANYK'] + 3]), bytes([0x21, 0xB4, 0x76]),
                         'ANYK смотрит в ту же таблицу TAB')

    def frames_until_return(self, before_frame):
        """Кадров до возврата из USPO; before_frame(n) правит TAB перед n-м кадром."""
        m = self.m
        m.pc, m.sp = STUB, STACK
        m.set_breakpoint(STOP)
        frames = 0
        try:
            while frames < 2000:
                m.ticks_to_stop = 100000
                m.run()
                if m.pc == STOP:
                    return frames
                if m.halted:
                    frames += 1
                    before_frame(frames)
                    m.on_handle_active_int()
        finally:
            m.clear_breakpoint(STOP)
        raise AssertionError('USPO не вернулся за 2000 кадров')

    def mark(self, value):
        self.m.memory[TAB + F2] = value

    def test_no_keys_returns_at_once(self):
        self.assertEqual(self.frames_until_return(lambda n: None), 1)

    def test_normal_release(self):
        self.mark(0x06)
        frames = self.frames_until_return(lambda n: self.mark(0) if n == 20 else None)
        self.assertEqual(frames, 20)

    def test_lost_release_does_not_hang(self):
        self.mark(0x06)                                         # отпускание так и не придёт
        frames = self.frames_until_return(lambda n: None)
        self.assertTrue(80 <= frames <= 90, frames)
        self.assertEqual(bytes(self.m.memory[TAB:TAB + 20]), bytes(20), 'таблица очищена')

    def test_really_held_key_is_waited_for(self):
        # Автоповтор PS/2 отмечает клавишу раз в три кадра, пока её держат 300 кадров.
        self.mark(0x06)

        def typematic(n):
            if n <= 300 and n % 3 == 0:
                self.mark(0x06)
            elif n == 301:
                self.mark(0)

        frames = self.frames_until_return(typematic)
        self.assertTrue(301 <= frames <= 303, frames)


if __name__ == '__main__':
    unittest.main(verbosity=2)
