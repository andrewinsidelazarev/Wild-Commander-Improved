#!/usr/bin/env python3
"""Compare a Wild Commander build tree with a reference tree using SHA-256."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path


MATCH = "MATCH"
HASH_MISMATCH = "HASH_MISMATCH"
MISSING_ACTUAL = "MISSING_ACTUAL"
EXTRA_ACTUAL = "EXTRA_ACTUAL"


@dataclass(frozen=True)
class FileRecord:
    relative_path: str
    path: Path
    size: int
    sha256: str


@dataclass(frozen=True)
class Comparison:
    status: str
    relative_path: str
    actual_size: int | None
    reference_size: int | None
    actual_sha256: str | None
    reference_sha256: str | None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def collect_files(root: Path) -> dict[str, FileRecord]:
    if not root.is_dir():
        raise ValueError(f"directory does not exist: {root}")

    records: dict[str, FileRecord] = {}
    for path in sorted((item for item in root.rglob("*") if item.is_file())):
        relative = path.relative_to(root).as_posix()
        key = relative.casefold()
        if key in records:
            raise ValueError(
                "case-insensitive path collision under "
                f"{root}: {records[key].relative_path!r} and {relative!r}"
            )
        records[key] = FileRecord(
            relative_path=relative,
            path=path,
            size=path.stat().st_size,
            sha256=sha256_file(path),
        )
    return records


def compare_trees(actual_root: Path, reference_root: Path) -> list[Comparison]:
    actual = collect_files(actual_root)
    reference = collect_files(reference_root)
    results: list[Comparison] = []

    for key in sorted(set(actual) | set(reference)):
        actual_file = actual.get(key)
        reference_file = reference.get(key)

        if actual_file is None:
            assert reference_file is not None
            results.append(
                Comparison(
                    MISSING_ACTUAL,
                    reference_file.relative_path,
                    None,
                    reference_file.size,
                    None,
                    reference_file.sha256,
                )
            )
            continue

        if reference_file is None:
            results.append(
                Comparison(
                    EXTRA_ACTUAL,
                    actual_file.relative_path,
                    actual_file.size,
                    None,
                    actual_file.sha256,
                    None,
                )
            )
            continue

        status = (
            MATCH
            if actual_file.size == reference_file.size
            and actual_file.sha256 == reference_file.sha256
            else HASH_MISMATCH
        )
        results.append(
            Comparison(
                status,
                reference_file.relative_path,
                actual_file.size,
                reference_file.size,
                actual_file.sha256,
                reference_file.sha256,
            )
        )

    return results


def _text(value: object | None) -> str:
    return "" if value is None else str(value)


def render_tsv(results: list[Comparison]) -> str:
    lines = [
        "status\tpath\tactual_bytes\treference_bytes\tactual_sha256\treference_sha256"
    ]
    for item in results:
        lines.append(
            "\t".join(
                (
                    item.status,
                    item.relative_path,
                    _text(item.actual_size),
                    _text(item.reference_size),
                    _text(item.actual_sha256),
                    _text(item.reference_sha256),
                )
            )
        )
    return "\n".join(lines) + "\n"


def _markdown_cell(value: object | None) -> str:
    return _text(value).replace("|", "\\|").replace("\n", "<br>")


def render_markdown(results: list[Comparison]) -> str:
    lines = [
        "| Status | Path | Actual bytes | Reference bytes | Actual SHA-256 | Reference SHA-256 |",
        "|---|---|---:|---:|---|---|",
    ]
    for item in results:
        values = (
            item.status,
            item.relative_path,
            item.actual_size,
            item.reference_size,
            item.actual_sha256,
            item.reference_sha256,
        )
        lines.append("| " + " | ".join(_markdown_cell(value) for value in values) + " |")
    return "\n".join(lines) + "\n"


def default_reference(project_root: Path) -> Path:
    env_path = os.environ.get("WC_REFERENCE_EXE")
    if env_path:
        return Path(env_path)

    candidates = (
        project_root / "reference" / "exe",
        project_root.parent
        / "Chkdsk"
        / "wc_reference"
        / "pentevo"
        / "soft"
        / "WC"
        / "exe",
    )
    return next((candidate for candidate in candidates if candidate.is_dir()), candidates[0])


def run_self_test() -> None:
    # tempfile.mkdtemp() creates a mode-0700 directory.  In some brokered
    # Windows Server sessions that ACL is inaccessible to the next file call,
    # so create a unique, normally inherited test directory explicitly.
    root = Path(__file__).resolve().parent / (
        ".verify_hashes_selftest_" + uuid.uuid4().hex
    )
    root.mkdir()
    try:
        actual = root / "actual"
        reference = root / "reference"
        (actual / "nested").mkdir(parents=True)
        (reference / "nested").mkdir(parents=True)

        (actual / "same.bin").write_bytes(b"same")
        (reference / "same.bin").write_bytes(b"same")
        (actual / "different.bin").write_bytes(b"actual")
        (reference / "different.bin").write_bytes(b"reference")
        (actual / "extra.bin").write_bytes(b"extra")
        (reference / "nested" / "missing.bin").write_bytes(b"missing")

        results = compare_trees(actual, reference)
        statuses = {item.relative_path: item.status for item in results}
        assert statuses == {
            "different.bin": HASH_MISMATCH,
            "extra.bin": EXTRA_ACTUAL,
            "nested/missing.bin": MISSING_ACTUAL,
            "same.bin": MATCH,
        }
        assert render_tsv(results).startswith("status\tpath\t")
        assert render_markdown(results).startswith("| Status | Path |")
    finally:
        shutil.rmtree(root)


def build_parser() -> argparse.ArgumentParser:
    project_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        description="Compare every file in a built exe tree with a reference exe tree."
    )
    parser.add_argument(
        "--actual",
        type=Path,
        default=project_root / "exe",
        help=f"built exe directory (default: {project_root / 'exe'})",
    )
    parser.add_argument(
        "--reference",
        type=Path,
        default=default_reference(project_root),
        help="reference exe directory (or set WC_REFERENCE_EXE)",
    )
    parser.add_argument(
        "--format",
        choices=("tsv", "markdown"),
        default="tsv",
        help="report format (default: tsv)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="write the report as UTF-8 to this file instead of stdout",
    )
    parser.add_argument(
        "--self-test", action="store_true", help="run built-in checks and exit"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.self_test:
        run_self_test()
        print("verify_hashes.py: self-test passed")
        return 0

    try:
        results = compare_trees(args.actual, args.reference)
        report = render_tsv(results) if args.format == "tsv" else render_markdown(results)
        if args.output is None:
            sys.stdout.write(report)
        else:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(report, encoding="utf-8", newline="\n")
            print(f"report\t{args.output}", file=sys.stderr)
    except (OSError, ValueError) as exc:
        print(f"verify_hashes.py: error: {exc}", file=sys.stderr)
        return 2

    mismatches = sum(item.status != MATCH for item in results)
    print(
        f"checked\t{len(results)}\tmismatches\t{mismatches}",
        file=sys.stderr,
    )
    return 0 if mismatches == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
