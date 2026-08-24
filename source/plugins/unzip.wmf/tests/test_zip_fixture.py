"""Проверить тестовый ZIP стандартным распаковщиком Python."""
from __future__ import annotations

import sys
import unittest
import zipfile
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

from tools.make_test_zip import make_archive  # noqa: E402


class ZipFixtureTests(unittest.TestCase):
    def test_fixture_matches_expected_payloads(self) -> None:
        archive, expected = make_archive()
        with zipfile.ZipFile(archive, "r") as source:
            source.testzip()
            actual = {
                info.filename: source.read(info)
                for info in source.infolist()
                if not info.is_dir()
            }
        self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
