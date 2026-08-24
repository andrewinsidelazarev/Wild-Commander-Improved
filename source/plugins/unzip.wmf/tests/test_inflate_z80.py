"""Машинные тесты потокового декодера Deflate на эмуляторе Z80."""
from __future__ import annotations

import random
import unittest
import zlib
from pathlib import Path

import z80


PROJECT_ROOT = Path(__file__).resolve().parents[1]
HARNESS = PROJECT_ROOT / "build" / "inflate_test.bin"
CODE_ADDRESS = 0x8000
INPUT_ADDRESS = 0x4000
CONTROL_ADDRESS = 0x7E00
STACK_ADDRESS = 0x7D00
RETURN_SENTINEL = 0x7F00
BREAKPOINT_HIT = 1 << 1
HISTORY_FILL = 0xA5


def put16(memory: memoryview, address: int, value: int) -> None:
    memory[address] = value & 0xFF
    memory[address + 1] = value >> 8 & 0xFF


def get16(memory: memoryview, address: int) -> int:
    return memory[address] | memory[address + 1] << 8


def get32(memory: memoryview, address: int) -> int:
    return get16(memory, address) | get16(memory, address + 2) << 16


def raw_deflate(data: bytes, *, level: int = 6, strategy: int = 0) -> bytes:
    compressor = zlib.compressobj(level, zlib.DEFLATED, -15, 8, strategy)
    return compressor.compress(data) + compressor.flush()


class InflateZ80Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.harness = HARNESS.read_bytes()

    def run_until_breakpoint(self, machine: z80.Z80Machine) -> None:
        for _ in range(5000):
            machine.ticks_to_stop = 10_000_000
            event = machine.run()
            if event & BREAKPOINT_HIT:
                self.assertEqual(machine.pc, RETURN_SENTINEL)
                return
            self.assertEqual(event, 1)
        self.fail(f"превышен лимит Z80, PC=#{machine.pc:04X}")

    def run_valid(self, compressed: bytes, expected: bytes) -> None:
        self.assertLess(len(compressed), CONTROL_ADDRESS - INPUT_ADDRESS)
        machine = z80.Z80Machine()
        memory = machine.memory
        memory[0:0x4000] = bytes((HISTORY_FILL,)) * 0x4000
        memory[0xC000:0x10000] = bytes((HISTORY_FILL,)) * 0x4000
        machine.set_memory_block(CODE_ADDRESS, self.harness)
        machine.set_memory_block(INPUT_ADDRESS, compressed)
        put16(memory, CONTROL_ADDRESS, INPUT_ADDRESS)
        put16(memory, CONTROL_ADDRESS + 2, len(compressed))
        machine.sp = STACK_ADDRESS
        put16(memory, STACK_ADDRESS, RETURN_SENTINEL)
        machine.pc = CODE_ADDRESS
        machine.set_breakpoint(RETURN_SENTINEL)
        self.run_until_breakpoint(machine)
        self.assertEqual(memory[CONTROL_ADDRESS + 4], 1)
        self.assertEqual(memory[CONTROL_ADDRESS + 5], 0)
        self.assertEqual(get16(memory, CONTROL_ADDRESS + 6), len(compressed))
        self.assertEqual(get32(memory, CONTROL_ADDRESS + 8), len(expected))

        expected_history = bytearray((HISTORY_FILL,)) * 0x8000
        for index, value in enumerate(expected):
            expected_history[index & 0x7FFF] = value
        actual_history = bytes(memory[0:0x4000]) + bytes(memory[0xC000:0x10000])
        self.assertEqual(actual_history, bytes(expected_history))

    def run_invalid(self, compressed: bytes) -> None:
        machine = z80.Z80Machine()
        memory = machine.memory
        machine.set_memory_block(CODE_ADDRESS, self.harness)
        machine.set_memory_block(INPUT_ADDRESS, compressed)
        put16(memory, CONTROL_ADDRESS, INPUT_ADDRESS)
        put16(memory, CONTROL_ADDRESS + 2, len(compressed))
        machine.sp = STACK_ADDRESS
        put16(memory, STACK_ADDRESS, RETURN_SENTINEL)
        machine.pc = CODE_ADDRESS
        machine.set_breakpoint(RETURN_SENTINEL)
        self.run_until_breakpoint(machine)
        self.assertEqual(memory[CONTROL_ADDRESS + 4], 0)

    def test_stored_block(self) -> None:
        payload = bytes(range(256)) * 8
        compressed = raw_deflate(payload, level=0)
        self.assertEqual((compressed[0] >> 1) & 3, 0)
        self.run_valid(compressed, payload)

    def test_fixed_huffman_block(self) -> None:
        payload = (b"fixed Huffman block 0123456789\r\n" * 250)
        compressed = raw_deflate(payload, level=9, strategy=zlib.Z_FIXED)
        self.assertEqual((compressed[0] >> 1) & 3, 1)
        self.run_valid(compressed, payload)

    def test_dynamic_huffman_block(self) -> None:
        payload = b"".join(
            f"row={index:04d}; value={(index * 7919) % 65521:05d}\n".encode()
            for index in range(2200)
        )
        compressed = raw_deflate(payload, level=9)
        self.assertEqual((compressed[0] >> 1) & 3, 2)
        self.run_valid(compressed, payload)

    def test_long_distance_and_window_wrap(self) -> None:
        generator = random.Random(0x5A17)
        base = generator.randbytes(9000)
        payload = base + b"Q" * 10000 + base + base[:7000]
        compressed = raw_deflate(payload, level=9)
        self.run_valid(compressed, payload)

    def test_output_larger_than_64k(self) -> None:
        payload = b"0123456789ABCDEF" * 5000
        self.run_valid(raw_deflate(payload, level=9), payload)

    def test_truncated_stream_is_rejected(self) -> None:
        compressed = raw_deflate(b"truncated stream " * 1000, level=9)
        self.run_invalid(compressed[:-1])

    def test_reserved_block_type_is_rejected(self) -> None:
        self.run_invalid(bytes((0x07,)))


if __name__ == "__main__":
    unittest.main()
