"""Сквозной тест UNZIP.WMF с подменой публичного API Wild Commander."""
from __future__ import annotations

import io
import binascii
import random
import re
import struct
import sys
import unittest
import zipfile
from pathlib import Path

import z80


PROJECT_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = PROJECT_ROOT.parents[2]
sys.path.insert(0, str(PROJECT_ROOT))

from tools.make_test_zip import make_archive, raw_deflate  # noqa: E402


CODE = PROJECT_ROOT / "build" / "code.bin"
MAP = PROJECT_ROOT / "build" / "obj" / "unzip.map"
BOOT = REPOSITORY_ROOT / "exe" / "boot.$C"
CODE_ADDRESS = 0x8000
WC_API = 0x6006
NAME_ADDRESS = 0x7800
PANEL_ADDRESS = 0x7EA0
STACK_ADDRESS = 0x7D00
RETURN_SENTINEL = 0x7F00
BREAKPOINT_HIT = 1 << 1


def put16(memory: memoryview, address: int, value: int) -> None:
    memory[address] = value & 0xFF
    memory[address + 1] = value >> 8 & 0xFF


def put32(memory: memoryview, address: int, value: int) -> None:
    memory[address] = value & 0xFF
    memory[address + 1] = value >> 8 & 0xFF
    memory[address + 2] = value >> 16 & 0xFF
    memory[address + 3] = value >> 24 & 0xFF


def read_cstring(memory: memoryview, address: int) -> bytes:
    result = bytearray()
    while memory[address]:
        result.append(memory[address])
        address += 1
    return bytes(result)


def make_single_descriptor_archive(name: bytes, payload: bytes) -> bytes:
    """Создать один Deflate-файл с нулевыми размерами в локальном заголовке."""
    compressed = raw_deflate(payload)
    crc = binascii.crc32(payload) & 0xFFFFFFFF
    flags = 0x0008
    local = struct.pack(
        "<IHHHHHIIIHH",
        0x04034B50,
        20,
        flags,
        8,
        0,
        0,
        0,
        0,
        0,
        len(name),
        0,
    ) + name
    descriptor = struct.pack("<IIII", 0x08074B50, crc, len(compressed), len(payload))
    central_offset = len(local) + len(compressed) + len(descriptor)
    central = struct.pack(
        "<IHHHHHHIIIHHHHHII",
        0x02014B50,
        20,
        20,
        flags,
        8,
        0,
        0,
        crc,
        len(compressed),
        len(payload),
        len(name),
        0,
        0,
        0,
        0,
        0,
        0,
    ) + name
    end = struct.pack(
        "<IHHHHIIH",
        0x06054B50,
        0,
        0,
        1,
        1,
        len(central),
        central_offset,
        0,
    )
    return local + compressed + descriptor + central + end


def symbol_address(name: str) -> int:
    pattern = re.compile(rf"^\s*([0-9A-F]{{8}})\s+{re.escape(name)}\s+", re.MULTILINE)
    match = pattern.search(MAP.read_text(encoding="ascii"))
    if not match:
        raise AssertionError(f"символ {name} не найден")
    return int(match.group(1), 16)


class VirtualWC:
    def __init__(
        self,
        archive_name: bytes,
        archive_data: bytes,
        *,
        initial_files: dict[tuple[bytes, ...], bytes] | None = None,
        keys: bytes = b"",
        filex_available: bool = True,
    ) -> None:
        self.archive_name = archive_name
        self.files: dict[tuple[bytes, ...], bytes] = {(archive_name,): archive_data}
        self.directories: set[tuple[bytes, ...]] = {()}
        if initial_files:
            self.files.update(initial_files)
            for path in initial_files:
                for depth in range(1, len(path)):
                    self.directories.add(path[:depth])
        self.streams = [self.new_stream(), self.new_stream()]
        self.current = 0
        self.keys = list(keys)
        self.filex_available = filex_available
        self.key_release_calls = 0
        self.replace_prompts = 0
        self.loaded_sectors = 0
        self.events: list[str] = []
        self.prints: list[tuple[int, int, bytes]] = []
        self.window_open = False
        self.window_descriptor: bytes | None = None
        self.window_title = b""
        self.window_restored = False

    @staticmethod
    def new_stream() -> dict[str, object]:
        return {"path": (), "found": None, "file": None, "position": 0}

    def path_for(self, name: bytes) -> tuple[bytes, ...]:
        path = self.streams[self.current]["path"]
        assert isinstance(path, tuple)
        return path + (name,)

    def find(self, kind: int, name: bytes) -> tuple[bytes, ...] | None:
        stream = self.streams[self.current]
        path = stream["path"]
        assert isinstance(path, tuple)
        if kind == 0x10 and name == b"..":
            return path[:-1]
        candidate = path + (name,)
        if kind == 0x10:
            return candidate if candidate in self.directories else None
        return candidate if candidate in self.files else None

    @staticmethod
    def set_flags(machine: z80.Z80Machine, *, zero: bool = False, carry: bool = False) -> None:
        machine.f = (0x40 if zero else 0) | (1 if carry else 0)

    @staticmethod
    def return_from_call(machine: z80.Z80Machine) -> None:
        memory = machine.memory
        address = memory[machine.sp] | memory[(machine.sp + 1) & 0xFFFF] << 8
        machine.sp = (machine.sp + 2) & 0xFFFF
        machine.pc = address

    def handle(self, machine: z80.Z80Machine) -> None:
        memory = machine.memory
        api = machine.a

        if api == 15:
            self.set_flags(machine, zero=True)
        elif api == 57:
            if machine.d == 0xFE:
                self.streams = [self.new_stream(), self.new_stream()]
                self.current = 0
            elif machine.d in (0, 1) and machine.bc == 0xFFFF:
                self.current = machine.d
            else:
                raise AssertionError(f"неподдерживаемый STREAM D=#{machine.d:02X}")
            self.set_flags(machine, zero=True)
        elif api == 59:
            kind = memory[machine.hl]
            name = read_cstring(memory, machine.hl + 1)
            found = self.find(kind, name)
            self.streams[self.current]["found"] = found
            if found is None:
                self.set_flags(machine, zero=True)
            else:
                size = len(self.files.get(found, b""))
                machine.hl = size & 0xFFFF
                machine.de = size >> 16
                self.set_flags(machine)
        elif api == 62:
            stream = self.streams[self.current]
            stream["file"] = stream["found"]
            stream["position"] = 0
            self.set_flags(machine, zero=True)
        elif api == 48:
            stream = self.streams[self.current]
            file_path = stream["file"]
            position = stream["position"]
            assert isinstance(file_path, tuple) and isinstance(position, int)
            data = self.files[file_path]
            length = machine.b * 512
            chunk = data[position : position + length]
            memory[machine.hl : machine.hl + length] = chunk.ljust(length, b"\x00")
            stream["position"] = position + length
            self.loaded_sectors += machine.b
            machine.a = 0
            self.set_flags(machine)
        elif api == 63:
            stream = self.streams[self.current]
            found = stream["found"]
            assert isinstance(found, tuple) and found in self.directories
            stream["path"] = found
            self.set_flags(machine, zero=True)
        elif api == 72:
            name = read_cstring(memory, machine.hl + 5)
            target = self.path_for(name)
            if target in self.files or target in self.directories:
                machine.a = 3
                self.set_flags(machine)
            else:
                self.files[target] = b""
                self.events.append("create")
                machine.a = 0
                self.set_flags(machine, zero=True)
        elif api == 73:
            name = read_cstring(memory, machine.hl)
            target = self.path_for(name)
            if target in self.files or target in self.directories:
                machine.a = 3
                self.set_flags(machine)
            else:
                self.directories.add(target)
                self.events.append("mkdir")
                machine.a = 0
                self.set_flags(machine, zero=True)
        elif api == 74:
            old_kind = memory[machine.hl]
            old_name = read_cstring(memory, machine.hl + 1)
            new_name = read_cstring(memory, machine.de)
            old_path = self.find(old_kind, old_name)
            new_path = self.path_for(new_name)
            if old_path is None or new_path in self.files or new_path in self.directories:
                self.set_flags(machine, zero=True)
            else:
                self.files[new_path] = self.files.pop(old_path)
                self.events.append("rename")
                self.set_flags(machine)
        elif api == 75:
            kind = memory[machine.hl]
            name = read_cstring(memory, machine.hl + 1)
            target = self.find(kind, name)
            if target is None or target not in self.files:
                self.set_flags(machine, zero=True)
            else:
                del self.files[target]
                self.events.append("delete")
                self.set_flags(machine)
        elif api == 76:
            stream = self.streams[self.current]
            target = stream["found"]
            if not isinstance(target, tuple) or target not in self.files:
                machine.a = 3
                self.set_flags(machine)
            else:
                self.files[target] += bytes(memory[machine.hl : machine.hl + machine.bc])
                self.events.append("append")
                machine.a = 0
                self.set_flags(machine, zero=True)
        elif api == 77:
            block = machine.hl
            if not self.filex_available:
                machine.a = 0x15
                self.set_flags(machine)
            else:
                self.assert_filex_block(memory, block)
                offset = int.from_bytes(memory[block + 4 : block + 8], "little")
                buffer = memory[block + 8] | memory[block + 9] << 8
                length = memory[block + 10] | memory[block + 11] << 8
                found = self.streams[self.current]["found"]
                assert isinstance(found, tuple) and found in self.files
                data = self.files[found]
                chunk = data[offset : offset + length]
                memory[buffer : buffer + len(chunk)] = chunk
                put32(memory, block + 24, len(chunk))
                status = 0 if len(chunk) == length else 1
                memory[block + 28] = status
                machine.a = status
                self.set_flags(machine, zero=status == 0)
        elif api == 1:
            self.window_open = True
            self.window_descriptor = bytes(memory[machine.ix : machine.ix + 18])
            title_address = self.window_descriptor[12] | self.window_descriptor[13] << 8
            self.window_title = read_cstring(memory, title_address)
            # Настоящий PRWOW помещает в поля 8..9 адрес сохранённого фона.
            memory[machine.ix + 8] = 0x00
            memory[machine.ix + 9] = 0x70
            self.set_flags(machine, zero=True)
        elif api == 2:
            self.window_restored = bool(memory[machine.ix + 8] | memory[machine.ix + 9])
            memory[machine.ix + 8] = 0
            memory[machine.ix + 9] = 0
            self.window_open = False
            self.set_flags(machine, zero=True)
        elif api == 3:
            printed = bytes(memory[machine.hl : machine.hl + machine.bc])
            self.prints.append((machine.d, machine.e, printed))
            if b"Replace existing file?" in printed:
                self.replace_prompts += 1
                self.events.append("prompt")
            self.set_flags(machine, zero=True)
        elif api == 22:
            self.set_flags(machine, zero=True)
        elif api == 23:
            self.set_flags(machine, zero=True)
        elif api == 42:
            machine.a = self.keys.pop(0) if self.keys else 0xFF
            self.set_flags(machine, zero=machine.a == 0)
        elif api == 45:
            self.set_flags(machine)
        elif api == 46:
            self.key_release_calls += 1
            self.set_flags(machine, zero=True)
        elif api in (0, 78):
            self.set_flags(machine, zero=True)
        else:
            raise AssertionError(f"необработанный WC API {api} в PC=#{machine.pc:04X}")

        self.return_from_call(machine)

    @staticmethod
    def assert_filex_block(memory: memoryview, block: int) -> None:
        if memory[block] != 32 or memory[block + 1] != 1 or memory[block + 2] != 1:
            raise AssertionError("неверный блок FILEX READ_AT")

class PluginZ80Tests(unittest.TestCase):
    def run_plugin(
        self, wc: VirtualWC, archive_name: bytes, archive: bytes
    ) -> z80.Z80Machine:
        machine = z80.Z80Machine()
        memory = machine.memory
        machine.set_memory_block(CODE_ADDRESS, CODE.read_bytes())
        # В машинной модели кадровое ожидание не нужно: заменяем EI/HALT/RET
        # одним RET, чтобы тест не зависел от обработки HALT библиотекой z80.
        memory[symbol_address("_wc_wait_frame")] = 0xC9
        memory[NAME_ADDRESS : NAME_ADDRESS + len(archive_name) + 1] = archive_name + b"\x00"
        machine.hl = len(archive) & 0xFFFF
        machine.de = len(archive) >> 16
        machine.bc = NAME_ADDRESS
        machine.ix = PANEL_ADDRESS
        machine.sp = STACK_ADDRESS
        put16(memory, STACK_ADDRESS, RETURN_SENTINEL)
        machine.pc = CODE_ADDRESS

        for address in (WC_API, RETURN_SENTINEL):
            machine.set_breakpoint(address)

        for _ in range(30000):
            machine.ticks_to_stop = 10_000_000
            event = machine.run()
            if not event & BREAKPOINT_HIT:
                self.assertEqual(event, 1)
                continue
            if machine.pc == WC_API:
                wc.handle(machine)
                continue
            if machine.pc == RETURN_SENTINEL:
                break
            self.fail(f"неожиданный breakpoint #{machine.pc:04X}")
        else:
            self.fail(f"превышен лимит Z80, PC=#{machine.pc:04X}")
        return machine

    @staticmethod
    def encoded_path(name: str) -> tuple[bytes, ...]:
        return tuple(part.encode("cp866") for part in name.split("/"))

    @staticmethod
    def assert_no_temporary_files(wc: VirtualWC) -> None:
        if any(
            path[-1].startswith(b"WCUZ") and path[-1].endswith(b".$$$")
            for path in wc.files
            if path
        ):
            raise AssertionError("временные файлы должны быть удалены или переименованы")

    def test_recursive_extraction_and_progress(self) -> None:
        archive_path, expected = make_archive()
        archive = archive_path.read_bytes()
        archive_name = b"TEST.ZIP"
        legitimate_tmp = (b"WCUZ0000.TMP",)
        wc = VirtualWC(
            archive_name,
            archive,
            initial_files={legitimate_tmp: b"legitimate user TMP file"},
        )
        machine = self.run_plugin(wc, archive_name, archive)

        self.assertEqual(machine.a, 3)
        self.assertEqual(machine.ix, PANEL_ADDRESS)
        self.assertFalse(wc.window_open)
        self.assertIsNotNone(wc.window_descriptor)
        self.assertEqual(wc.window_descriptor[0], 0x81)
        self.assertEqual(wc.window_descriptor[4:7], bytes((64, 9, 0x1F)))
        self.assertEqual(wc.window_descriptor[8:10], bytes(2))
        self.assertEqual(wc.window_title, b"\x0e\x09 ZIP unpacker ")
        self.assertTrue(wc.window_restored)
        self.assertEqual(wc.streams[1]["path"], ())

        for name, data in expected.items():
            encoded_path = self.encoded_path(name)
            self.assertIn(encoded_path, wc.files, name)
            self.assertEqual(wc.files[encoded_path], data, name)
        self.assertEqual(wc.files[(archive_name,)], archive)
        self.assertEqual(wc.files[legitimate_tmp], b"legitimate user TMP file")
        self.assert_no_temporary_files(wc)

        lines = [text.rstrip() for _, _, text in wc.prints]
        self.assertTrue(any(line.strip().startswith(b"000%") for line in lines))
        self.assertTrue(any(line.strip().startswith(b"100%") for line in lines))
        self.assertTrue(any(line.startswith(b"unziping: DIR1/") for line in lines))
        self.assertTrue(any(line.startswith(b"unziping: done") for line in lines))
        bars = [text for y, x, text in wc.prints if (y, x) == (4, 3)]
        self.assertTrue(any(line[2:56] == b"\xb1" * 54 for line in bars))
        self.assertTrue(any(line[2:56] == b"\xdb" * 54 for line in bars))

    def test_existing_file_yes_replaces_it(self) -> None:
        archive_path, expected = make_archive()
        archive = archive_path.read_bytes()
        archive_name = b"TEST.ZIP"
        root = (b"ROOT.TXT",)
        wc = VirtualWC(
            archive_name,
            archive,
            initial_files={root: b"old root\r\n"},
            keys=b"y",
        )

        machine = self.run_plugin(wc, archive_name, archive)

        self.assertEqual(machine.a, 3)
        self.assertEqual(wc.files[root], expected["ROOT.TXT"])
        self.assertEqual(wc.replace_prompts, 1)
        self.assertEqual(wc.key_release_calls, 2)
        self.assertEqual(wc.events[0], "prompt")
        self.assert_no_temporary_files(wc)

    def test_existing_file_no_keeps_it_and_continues(self) -> None:
        archive_path, expected = make_archive()
        archive = archive_path.read_bytes()
        archive_name = b"TEST.ZIP"
        root = (b"ROOT.TXT",)
        old = b"keep this file\r\n"
        wc = VirtualWC(
            archive_name,
            archive,
            initial_files={root: old},
            keys=b"n",
        )

        machine = self.run_plugin(wc, archive_name, archive)

        self.assertEqual(machine.a, 3)
        self.assertEqual(wc.files[root], old)
        self.assertEqual(
            wc.files[self.encoded_path("DIR1/DEFLATE.BIN")],
            expected["DIR1/DEFLATE.BIN"],
        )
        self.assertEqual(wc.replace_prompts, 1)
        self.assertEqual(wc.events[0], "prompt")
        self.assertEqual(wc.events.count("create"), 5)
        self.assert_no_temporary_files(wc)

    def test_existing_large_file_no_reads_without_writes_or_false_progress(self) -> None:
        payload = bytes(range(256)) * 32
        archive_stream = io.BytesIO()
        with zipfile.ZipFile(
            archive_stream, "w", compression=zipfile.ZIP_STORED, allowZip64=False
        ) as archive_file:
            archive_file.writestr("ONLY.BIN", payload)
        archive = archive_stream.getvalue()
        archive_name = b"ONE.ZIP"
        target = (b"ONLY.BIN",)
        old = b"keep existing file"
        wc = VirtualWC(
            archive_name,
            archive,
            initial_files={target: old},
            keys=b"n",
        )

        machine = self.run_plugin(wc, archive_name, archive)

        self.assertEqual(machine.a, 0)
        self.assertEqual(wc.files[target], old)
        self.assertEqual(wc.events, ["prompt"])
        self.assertEqual(wc.loaded_sectors, 1)
        lines = [text.rstrip() for _, _, text in wc.prints]
        self.assertFalse(any(line.startswith(b"skipping: ONLY.BIN") for line in lines))
        self.assertFalse(any(line.startswith(b"unziping: done") for line in lines))
        self.assertFalse(any(line.strip().startswith(b"100%") for line in lines))
        self.assert_no_temporary_files(wc)

    def test_existing_deflate_file_no_keeps_zip_boundary(self) -> None:
        payload = random.Random(0x110).randbytes(8192)
        archive_stream = io.BytesIO()
        with zipfile.ZipFile(
            archive_stream, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=False
        ) as archive_file:
            archive_file.writestr("DEFLATE.BIN", payload)
        archive = archive_stream.getvalue()
        target = (b"DEFLATE.BIN",)
        wc = VirtualWC(
            b"DEFLATE.ZIP",
            archive,
            initial_files={target: b"OLD DEFLATE"},
            keys=b"n",
        )

        machine = self.run_plugin(wc, b"DEFLATE.ZIP", archive)

        self.assertEqual(machine.a, 0)
        self.assertEqual(wc.files[target], b"OLD DEFLATE")
        self.assertEqual(wc.events, ["prompt"])
        self.assertEqual(wc.loaded_sectors, 1)
        lines = [text.rstrip() for _, _, text in wc.prints]
        self.assertFalse(any(line.startswith(b"skipping: DEFLATE.BIN") for line in lines))
        self.assertFalse(any(b"invalid ZIP structure" in line for line in lines))
        self.assertFalse(any(line.startswith(b"unziping: done") for line in lines))
        self.assert_no_temporary_files(wc)

    def test_existing_descriptor_file_no_keeps_zip_boundary(self) -> None:
        # Размер больше 64 КиБ проверяет все четыре байта offset FILEX READ_AT.
        payload = random.Random(0x808).randbytes(256 * 1024)
        archive = make_single_descriptor_archive(b"STREAM.BIN", payload)
        target = (b"STREAM.BIN",)
        wc = VirtualWC(
            b"STREAM.ZIP",
            archive,
            initial_files={target: b"OLD STREAM"},
            keys=b"n",
        )

        machine = self.run_plugin(wc, b"STREAM.ZIP", archive)

        self.assertEqual(machine.a, 0)
        self.assertEqual(wc.files[target], b"OLD STREAM")
        self.assertEqual(wc.events, ["prompt"])
        self.assertEqual(wc.loaded_sectors, 1)
        lines = [text.rstrip() for _, _, text in wc.prints]
        self.assertFalse(any(line.startswith(b"skipping: STREAM.BIN") for line in lines))
        self.assertFalse(any(b"invalid ZIP structure" in line for line in lines))
        self.assertFalse(any(line.startswith(b"unziping: done") for line in lines))
        self.assert_no_temporary_files(wc)

    def test_eocd_comment_and_false_signature_still_find_last_entry(self) -> None:
        archive_stream = io.BytesIO()
        with zipfile.ZipFile(
            archive_stream, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=False
        ) as archive_file:
            archive_file.writestr("COMMENT.BIN", b"payload")
            # EOCD находится дальше одного 512-байтового окна, а ложная
            # сигнатура в комментарии не должна прервать обратный поиск.
            archive_file.comment = b"A" * 350 + b"PK\x05\x06" + b"B" * 350
        archive = archive_stream.getvalue()
        target = (b"COMMENT.BIN",)
        wc = VirtualWC(
            b"COMMENT.ZIP",
            archive,
            initial_files={target: b"OLD"},
            keys=b"n",
        )

        machine = self.run_plugin(wc, b"COMMENT.ZIP", archive)

        self.assertEqual(machine.a, 0)
        self.assertEqual(wc.files[target], b"OLD")
        self.assertEqual(wc.events, ["prompt"])
        self.assertEqual(wc.loaded_sectors, 1)
        self.assert_no_temporary_files(wc)

    def test_no_falls_back_to_sequential_skip_without_filex(self) -> None:
        payload = bytes(range(256)) * 8
        archive_stream = io.BytesIO()
        with zipfile.ZipFile(
            archive_stream, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=False
        ) as archive_file:
            archive_file.writestr("FALLBACK.BIN", payload)
        archive = archive_stream.getvalue()
        target = (b"FALLBACK.BIN",)
        wc = VirtualWC(
            b"FALLBACK.ZIP",
            archive,
            initial_files={target: b"OLD"},
            keys=b"n",
            filex_available=False,
        )

        machine = self.run_plugin(wc, b"FALLBACK.ZIP", archive)

        self.assertEqual(machine.a, 0)
        self.assertEqual(wc.files[target], b"OLD")
        self.assertEqual(wc.events, ["prompt"])
        lines = [text.rstrip() for _, _, text in wc.prints]
        self.assertTrue(any(line.startswith(b"skipping: FALLBACK.BIN") for line in lines))
        self.assertFalse(any(b"invalid ZIP structure" in line for line in lines))
        self.assert_no_temporary_files(wc)

    def test_existing_streamed_descriptor_no_writes_skipped_file(self) -> None:
        archive_path, expected = make_archive()
        archive = archive_path.read_bytes()
        archive_name = b"TEST.ZIP"
        descriptor = self.encoded_path("DIR1/NESTED/DESCRIPTOR.TXT")
        old = b"keep streamed descriptor target\r\n"
        wc = VirtualWC(
            archive_name,
            archive,
            initial_files={descriptor: old},
            keys=b"n",
        )

        machine = self.run_plugin(wc, archive_name, archive)

        self.assertEqual(machine.a, 3)
        self.assertEqual(wc.files[descriptor], old)
        self.assertEqual(
            wc.files[self.encoded_path("BIG/WINDOW.BIN")],
            expected["BIG/WINDOW.BIN"],
        )
        self.assertEqual(wc.replace_prompts, 1)
        # В архиве шесть файлов: для пропущенного не должно быть WC_MKFILE.
        self.assertEqual(wc.events.count("create"), 5)
        self.assert_no_temporary_files(wc)

    def test_existing_file_all_replaces_later_conflicts_without_prompt(self) -> None:
        archive_path, expected = make_archive()
        archive = archive_path.read_bytes()
        archive_name = b"TEST.ZIP"
        root = self.encoded_path("ROOT.TXT")
        nested = self.encoded_path("DIR1/DEFLATE.BIN")
        wc = VirtualWC(
            archive_name,
            archive,
            initial_files={root: b"old root", nested: b"old nested"},
            keys=b"a",
        )

        machine = self.run_plugin(wc, archive_name, archive)

        self.assertEqual(machine.a, 3)
        self.assertEqual(wc.files[root], expected["ROOT.TXT"])
        self.assertEqual(wc.files[nested], expected["DIR1/DEFLATE.BIN"])
        self.assertEqual(wc.replace_prompts, 1)
        self.assertEqual(wc.events[0], "prompt")
        self.assert_no_temporary_files(wc)

    def test_existing_file_escape_cancels_and_keeps_it(self) -> None:
        archive_path, _ = make_archive()
        archive = archive_path.read_bytes()
        archive_name = b"TEST.ZIP"
        root = (b"ROOT.TXT",)
        old = b"keep on cancel\r\n"
        wc = VirtualWC(
            archive_name,
            archive,
            initial_files={root: old},
            keys=bytes((27,)),
        )

        machine = self.run_plugin(wc, archive_name, archive)

        self.assertEqual(machine.a, 0)
        self.assertEqual(wc.files[root], old)
        self.assertNotIn(self.encoded_path("DIR1/DEFLATE.BIN"), wc.files)
        self.assertEqual(wc.replace_prompts, 1)
        self.assertEqual(wc.events, ["prompt"])
        self.assert_no_temporary_files(wc)

    def test_wc_110i_standard_refresh_contract(self) -> None:
        """Код возврата 3 должен обрабатываться штатным WCVW после NYAU."""
        boot = BOOT.read_bytes()
        refresh = 0x9B28 - 0x6000
        self.assertEqual(
            boot[refresh : refresh + 8],
            b"\xcd\x9d\x70\xfe\x03\xcc\x75\x8d",
        )


if __name__ == "__main__":
    unittest.main()
