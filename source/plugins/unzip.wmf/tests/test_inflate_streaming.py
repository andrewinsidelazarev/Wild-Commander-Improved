"""Заголовки Stored-блоков Deflate на границах входного окна UNZIP."""
from __future__ import annotations

import binascii
import io
import struct
import unittest
import zipfile

import test_plugin_z80 as plugin


def stored_block_archive(start: int, payload: bytes, *, descriptor: bool = False,
                         bad_nlen: bool = False) -> bytes:
    """Один валидный ZIP, начало Deflate — по заданному смещению в архиве.

    Размер extra-поля с неизвестным ID управляет выравниванием, не меняя
    содержимое файла. Сжатый поток создаём сами: zlib обычно выбирает другие
    границы блоков и потому прежние случайные тесты не ловили этот дефект.
    """
    name = b"BOUNDARY.BIN"
    padding = start - 30 - len(name)
    assert padding >= 4 and len(payload) <= 65535
    extra = struct.pack("<HH", 0xFFFF, padding - 4) + bytes(padding - 4)
    nlen = len(payload) ^ 0xFFFF ^ int(bad_nlen)
    compressed = b"\x01" + struct.pack("<HH", len(payload), nlen) + payload
    crc = binascii.crc32(payload) & 0xFFFFFFFF
    flags = 8 if descriptor else 0
    local = struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, flags, 8, 0, 0,
                        0 if descriptor else crc,
                        0 if descriptor else len(compressed),
                        0 if descriptor else len(payload), len(name), len(extra))
    data = local + name + extra + compressed
    if descriptor:
        data += struct.pack("<IIII", 0x08074B50, crc, len(compressed), len(payload))
    central = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, flags, 8,
                          0, 0, crc, len(compressed), len(payload), len(name),
                          0, 0, 0, 0, 0, 0) + name
    end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 1, 1, len(central), len(data), 0)
    return data + central + end


class StreamingInflateTests(unittest.TestCase):
    def test_stored_header_across_input_refill(self) -> None:
        # LEN=8056h как в ISDOS.ZIP: младший NLEN=A9h, старший=7Fh.
        # При старом коде in_more затирал C между чтением этих двух байтов.
        payload = (bytes(range(256)) * 129)[:0x8056]
        for start in range(1018, 1026):
            for filex in (False, True):
                for descriptor in (False, True):
                    with self.subTest(start=start, filex=filex, descriptor=descriptor):
                        archive = stored_block_archive(start, payload, descriptor=descriptor)
                        with zipfile.ZipFile(io.BytesIO(archive)) as reference:
                            self.assertEqual(reference.read("BOUNDARY.BIN"), payload)
                        wc = plugin.VirtualWC(b"TEST.ZIP", archive, filex_available=filex)
                        machine = plugin.PluginZ80Tests().run_plugin(wc, b"TEST.ZIP", archive)
                        self.assertEqual(machine.a, 3)
                        self.assertEqual(wc.files.get((b"BOUNDARY.BIN",)), payload)
                        self.assertEqual(wc.files[(b"TEST.ZIP",)], archive)
                        plugin.PluginZ80Tests.assert_no_temporary_files(wc)

    def test_empty_and_maximum_stored_blocks_at_refill(self) -> None:
        for size in (0, 1, 65535):
            with self.subTest(size=size):
                payload = (bytes(range(256)) * 256)[:size]
                archive = stored_block_archive(2044, payload)
                wc = plugin.VirtualWC(b"TEST.ZIP", archive)
                plugin.PluginZ80Tests().run_plugin(wc, b"TEST.ZIP", archive)
                self.assertEqual(wc.files.get((b"BOUNDARY.BIN",)), payload)
                plugin.PluginZ80Tests.assert_no_temporary_files(wc)

    def test_bad_stored_length_at_refill_keeps_existing_file(self) -> None:
        archive = stored_block_archive(1020, b"unchanged", bad_nlen=True)
        old = b"existing file must survive invalid input"
        wc = plugin.VirtualWC(b"TEST.ZIP", archive,
                              initial_files={(b"BOUNDARY.BIN",): old}, keys=b"y")
        plugin.PluginZ80Tests().run_plugin(wc, b"TEST.ZIP", archive)
        self.assertEqual(wc.files[(b"BOUNDARY.BIN",)], old)
        self.assertTrue(any(b"invalid Deflate stream" in text for _, _, text in wc.prints))
        plugin.PluginZ80Tests.assert_no_temporary_files(wc)

    def test_truncated_stored_header_at_refill_keeps_existing_file(self) -> None:
        # Поток кончается перед старшим NLEN: возврат с C=1 из in_more
        # должен по-прежнему завершать распаковку и удалять временный файл.
        archive = stored_block_archive(1020, b"payload")[:1024]
        old = b"keep this file on input EOF"
        wc = plugin.VirtualWC(b"TEST.ZIP", archive,
                              initial_files={(b"BOUNDARY.BIN",): old}, keys=b"y")
        plugin.PluginZ80Tests().run_plugin(wc, b"TEST.ZIP", archive)
        self.assertEqual(wc.files[(b"BOUNDARY.BIN",)], old)
        self.assertTrue(any(b"ERROR:" in text for _, _, text in wc.prints))
        plugin.PluginZ80Tests.assert_no_temporary_files(wc)


if __name__ == "__main__":
    unittest.main()
