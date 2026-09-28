"""Граница частей расширения CORE32 (tools/split_extension.py, 2026-09-27).

Поток части 1 — до #BF60, поток части 2 — в хвост boot.$C до #E000 и на место
потока части 1 (туда его переносит установщик); обе части распаковываются
обратно. Здесь упаковщик подставной: длины и отказы задаёт тест, поэтому
проверяется сам алгоритм — без MHMT и за доли секунды.
"""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
import split_extension as se                                  # noqa: E402

RAW = bytes(range(256)) * 40                                  # 10240 байт


def linear(data):
    """Длина потока — половина входа, упаковщик не берёт меньше 16 байт."""
    return None if len(data) < 16 else len(data) // 2


def always(data):
    return True


class Split(unittest.TestCase):

    def test_largest_fitting_split(self):
        cut, part1, part2 = se.choose(RAW, 3000, 4000, linear, always)
        self.assertEqual((cut, part1, part2), (6001, 3000, (len(RAW) - 6001) // 2))

    def test_non_monotonic_length_is_not_trusted(self):
        # Codex R37-3: двоичный поиск останавливается на границе, у которой
        # хвост не влезает, а чуть правее есть подходящая: окно её находит.
        # Граница 6000 «не влезает» среди влезающих: двоичный поиск, проверив
        # её, решает, что всё правее тоже не влезает, и даёт 5999 — у неё
        # хвост на байт длиннее места. Подходит 6001.
        def bumpy(data):
            return 5000 if len(data) == 6000 else linear(data)
        tail_room = (len(RAW) - 6001) // 2
        self.assertGreater((len(RAW) - 5999) // 2, tail_room)
        cut, part1, part2 = se.choose(RAW, 3000, tail_room, bumpy, always)
        self.assertEqual((cut, part1, part2), (6001, 3000, tail_room))
        # Без окна над найденной границей (прежний поиск: только вниз) — отказ.
        self.assertIsNone(se.choose(RAW, 3000, tail_room, bumpy, always, above=0))

    def test_tail_decides_among_fitting_splits(self):
        # Часть 1 влезает на нескольких границах; хвосту подходит лишь одна.
        def picky(data):
            if len(data) == len(RAW) - 6000:
                return 1000                                   # хвост от 6000 — короткий
            if len(data) < 6010 and len(data) > 5000:
                return 2000                                   # части 1 до 6009 — влезают
            return linear(data)
        cut, part1, part2 = se.choose(RAW, 2000, 1000, picky, always)
        self.assertEqual((cut, part1, part2), (6000, 2000, 1000))

    def test_short_part_is_not_the_end(self):
        # Codex R37-4: место части 1 велико — двоичный поиск ушёл бы к хвосту в
        # один байт, упаковщик такой не берёт. Части — от 16 байт, и отказ
        # упаковщика — лишь неподходящий кандидат.
        cut, part1, part2 = se.choose(RAW, 100000, 2145, linear, always)
        self.assertEqual(cut, len(RAW) - se.MIN_PART)
        self.assertEqual(part2, se.MIN_PART // 2)

    def test_packer_refusal_skips_the_candidate(self):
        def refuses(data):
            return None if len(data) in (6001, len(RAW) - 6000) else linear(data)
        cut, _, _ = se.choose(RAW, 3000, 4000, refuses, always)
        self.assertEqual(cut, 5999)

    def test_part2_must_fit_its_bounce_copy(self):
        # Поток части 2 переносится на место потока части 1: хвост длиннее
        # места части 1 не годится, даже если в хвосте файла место есть.
        self.assertIsNone(se.choose(RAW, 2500, 100000, linear, always))

    def test_unpacking_failure_moves_the_split(self):
        bad = {7001, 7000, 6999, len(RAW) - 6998}
        def unpacks(data):
            return len(data) not in bad
        cut, _, _ = se.choose(RAW, 3500, 4000, linear, unpacks)
        self.assertEqual(cut, 6997)

    def test_no_split(self):
        self.assertIsNone(se.choose(RAW, 3000, 1000, linear, always))
        self.assertIsNone(se.choose(bytes(20), 100, 100, linear, always), 'части короче 16 байт')


if __name__ == '__main__':
    unittest.main(verbosity=2)
