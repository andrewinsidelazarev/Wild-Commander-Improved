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
        # Вход лежит с #4000, стек обвязки растёт вниз от #7D00: вход не
        # должен доходить до стека, иначе CALL/PUSH испортят его хвост.
        self.assertLess(len(compressed), STACK_ADDRESS - 0x100 - INPUT_ADDRESS)
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

    def test_random_streams_match_zlib(self) -> None:
        """Случайные данные всеми стратегиями zlib: табличный декодер,
        длинные коды (медленный путь), блоки без сжатия, повторы через
        границы кольца."""
        limit = STACK_ADDRESS - 0x100 - INPUT_ADDRESS
        strategies = (
            zlib.Z_DEFAULT_STRATEGY, zlib.Z_FILTERED, zlib.Z_HUFFMAN_ONLY,
            zlib.Z_RLE, zlib.Z_FIXED,
        )
        checked = 0
        for seed in range(48):
            generator = random.Random(0xC0DE + seed)
            size = generator.randint(1, 60000)
            kind = seed % 6
            if kind == 0:
                payload = generator.randbytes(size)
            elif kind == 1:
                payload = bytes(generator.choices(b"abcdefgh \n", k=size))
            elif kind == 2:
                payload = (generator.randbytes(generator.randint(1, 3000)) * 40)[:size]
            elif kind == 3:
                # Много редких символов: коды длиннее 8 бит
                weights = [generator.randint(1, 60) for _ in range(256)]
                payload = bytes(generator.choices(range(256), weights=weights, k=size))
            elif kind == 4:
                payload = bytes((generator.randint(0, 255),)) * size
            else:
                block = generator.randbytes(9000)
                payload = (block + b"Q" * 10000 + block)[:size]
            level = generator.choice((0, 1, 6, 9))
            strategy = generator.choice(strategies)
            compressed = raw_deflate(payload, level=level, strategy=strategy)
            while len(compressed) >= limit:
                payload = payload[: len(payload) * 3 // 4]
                compressed = raw_deflate(payload, level=level, strategy=strategy)
            with self.subTest(seed=seed, size=len(payload), level=level, strategy=strategy):
                self.run_valid(compressed, payload)
            checked += 1
        self.assertEqual(checked, 48)

    def test_truncated_stream_is_rejected(self) -> None:
        compressed = raw_deflate(b"truncated stream " * 1000, level=9)
        self.run_invalid(compressed[:-1])

    def test_reserved_block_type_is_rejected(self) -> None:
        self.run_invalid(bytes((0x07,)))


if __name__ == "__main__":
    unittest.main()
