"""Статические проверки заголовка и карты памяти UNZIP.WMF."""
from __future__ import annotations

import re
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
WMF = PROJECT_ROOT / "build" / "UNZIP.WMF"
CODE = PROJECT_ROOT / "build" / "code.bin"
MAP = PROJECT_ROOT / "build" / "obj" / "unzip.map"


class WmfContractTests(unittest.TestCase):
    def test_header_and_extension_launch(self) -> None:
        data = WMF.read_bytes()
        self.assertEqual(data[0:16], bytes(16))
        self.assertEqual(data[16:32], b"WildCommanderMDL")
        self.assertEqual(data[32], 0x10)
        self.assertEqual(data[34], 3)
        self.assertEqual(data[35], 0)
        self.assertEqual(data[36], 0)
        self.assertGreater(data[37], 0)
        self.assertEqual(data[38:42], bytes((1, 0, 2, 0)))
        self.assertEqual(data[63], 1)
        self.assertEqual(data[64:67], b"ZIP")
        self.assertEqual(data[197], 0)
        self.assertEqual(data[165:177], b"ZIP unpacker")
        self.assertIn(b"unziping: ", data)
        self.assertIn(b"Replace existing file?", data)
        self.assertIn(b"[Y] Yes  [N] No  [A] All  [Esc] Cancel", data)
        self.assertEqual(len(data), 512 + data[37] * 512)

    def test_code_and_data_fit_the_declared_page(self) -> None:
        self.assertLessEqual(CODE.stat().st_size, 0x4000)
        text = MAP.read_text(encoding="ascii")
        data_match = re.search(
            r"_DATA\s+0000([0-9A-F]{4})\s+0000([0-9A-F]{4})", text
        )
        self.assertIsNotNone(data_match)
        start = int(data_match.group(1), 16)
        length = int(data_match.group(2), 16)
        self.assertGreaterEqual(start, 0xB000)
        self.assertLessEqual(start + length, 0xC000)

    def test_sources_are_utf8_without_bom(self) -> None:
        suffixes = {".c", ".h", ".s", ".asm", ".ps1", ".md", ".py"}
        for path in PROJECT_ROOT.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in suffixes:
                continue
            raw = path.read_bytes()
            self.assertFalse(raw.startswith(b"\xef\xbb\xbf"), str(path))
            raw.decode("utf-8", errors="strict")

    def test_runtime_registration_and_binary_identity(self) -> None:
        wc_root = PROJECT_ROOT.parents[2] / "exe" / "WC"
        runtime = wc_root / "UNZIP.WMF"
        self.assertEqual(runtime.read_bytes(), WMF.read_bytes())
        lines = wc_root.joinpath("wc.ini").read_bytes().splitlines()
        plugins = lines.index(b"[PLUGINS]")
        self.assertEqual(lines[plugins + 1].strip().upper(), b"FILEX.WMF")
        self.assertEqual(lines[plugins + 2].strip().upper(), b"UNZIP.WMF")
        self.assertEqual(
            sum(line.strip().upper().startswith(b"UNZIP.WMF") for line in lines),
            1,
        )


if __name__ == "__main__":
    unittest.main()
