"""Проверка образа FAT32 после распаковки произвольного ZIP в Wild Commander.

index   — физический номер записи корня (сколько раз нажать DOWN от первой);
inspect — сравнить каждый файл архива с файлом в образе, убедиться, что
          временных файлов WCUZ*.$$$ нет и копии FAT совпадают.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import sys
import zipfile
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
WC_ROOT = PROJECT_ROOT.parents[2]
UPDATE_PATH = WC_ROOT.parent / "Chkdsk" / "Debug" / "update_wc_image.py"


def load_update_module():
    spec = importlib.util.spec_from_file_location("unzip_check_wc", UPDATE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Не удалось загрузить {UPDATE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


UPDATE = load_update_module()
Fat32Image = UPDATE.Fat32Image
ATTR_DIRECTORY = UPDATE.ATTR_DIRECTORY


def find_ci(image: Fat32Image, cluster: int, name: str):
    """Запись каталога без учёта регистра: WC хранит короткие имена в верхнем."""
    for entry in image.parse_dir(cluster):
        if entry["name"].upper() == name.upper():
            return entry
    return None


def read_path(image: Fat32Image, path: str) -> bytes:
    parts = path.split("/")
    cluster = image.root_cluster
    for component in parts[:-1]:
        entry = find_ci(image, cluster, component)
        if not entry or not (entry["attr"] & ATTR_DIRECTORY):
            raise FileNotFoundError(f"Каталог не найден: {component}")
        cluster = entry["cluster"]
    entry = find_ci(image, cluster, parts[-1])
    if not entry:
        raise FileNotFoundError(parts[-1])
    return image.read_file(cluster, entry["name"])


def walk_temp_files(image: Fat32Image, cluster: int, prefix: str = "") -> list[str]:
    result: list[str] = []
    for entry in image.parse_dir(cluster):
        name = entry["name"]
        if name in (".", ".."):
            continue
        path = f"{prefix}/{name}" if prefix else name
        if name.upper().startswith("WCUZ") and name.upper().endswith(".$$$"):
            result.append(path)
        if entry["attr"] & ATTR_DIRECTORY:
            result.extend(walk_temp_files(image, entry["cluster"], path))
    return result


def root_index(image_path: Path, name: str) -> int:
    image = Fat32Image(image_path)
    names = [entry["name"].upper() for entry in image.parse_dir(image.root_cluster)]
    return names.index(name.upper())


def inspect(image_path: Path, archive_path: Path, image_archive_name: str) -> int:
    image = Fat32Image(image_path)
    failures: list[str] = []
    checked = 0
    with zipfile.ZipFile(archive_path) as archive:
        for info in archive.infolist():
            if info.is_dir():
                continue
            expected = archive.read(info)
            try:
                actual = read_path(image, info.filename)
            except (FileNotFoundError, RuntimeError) as error:
                failures.append(f"{info.filename}: {error}")
                continue
            if actual != expected:
                failures.append(
                    f"{info.filename}: размер {len(actual)} вместо {len(expected)}, "
                    f"sha256={hashlib.sha256(actual).hexdigest()}"
                )
            checked += 1
    stored = image.read_file(image.root_cluster, image_archive_name)
    if stored != archive_path.read_bytes():
        failures.append(f"Исходный {image_archive_name} изменён")
    temporary = walk_temp_files(image, image.root_cluster)
    if temporary:
        failures.append(f"Остались временные файлы: {temporary}")
    fat_length = image.fat_size * image.bps
    fat0 = image.fat_offset(0, 0)
    fat1 = image.fat_offset(0, 1)
    if image.data[fat0 : fat0 + fat_length] != image.data[fat1 : fat1 + fat_length]:
        failures.append("FAT0 и FAT1 различаются")
    if failures:
        print("UNZIP UNREAL FAIL:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(f"UNZIP UNREAL PASS: files={checked}; archive_sha256="
          f"{hashlib.sha256(archive_path.read_bytes()).hexdigest()}; equal FAT mirrors; no temp files")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    index_parser = subparsers.add_parser("index")
    index_parser.add_argument("--image", type=Path, required=True)
    index_parser.add_argument("--name", default="TEST.ZIP")
    inspect_parser = subparsers.add_parser("inspect")
    inspect_parser.add_argument("--image", type=Path, required=True)
    inspect_parser.add_argument("--archive", type=Path, required=True)
    inspect_parser.add_argument("--name", default="TEST.ZIP")
    args = parser.parse_args()
    if args.command == "index":
        print(root_index(args.image, args.name))
        return 0
    return inspect(args.image, args.archive, args.name)


if __name__ == "__main__":
    sys.exit(main())
