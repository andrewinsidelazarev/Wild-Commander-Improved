"""Подготовить и проверить существующий FAT32-образ для штатного F5 COPYF."""
from __future__ import annotations

import argparse
import hashlib
import shutil
from pathlib import Path

from core32_image_test import (
    ATTR_DIRECTORY,
    Fat32Image,
    UPDATE,
    collect_orphan_clusters,
    le16,
    le32,
    put32,
)


DESTINATION = "AAADST"
SOURCE = "SMALL541.$C"
RENAMED_SOURCE = "SMALL541.$ C"
SOURCE_PAYLOAD = bytes((index * 73 + 19) & 0xFF for index in range(541))
TREE_SOURCE = "TREE"
ASYNC_SMB_TREE_SOURCE = "CODEX_SMB_ASYNC_20260820_01"
DEFAULT_TREE_DEPTH = 21
DEFAULT_TREE_SHAPE = "chain"


def sibling_tree_fixture() -> tuple[
    tuple[str, ...], tuple[tuple[tuple[str, ...], bytes], ...]
]:
    branches = ("DIRONE", "DIRTWO")
    names = (
        "ZERO",
        "ONE.C",
        "TWO.$C",
        "THREE.BIN",
        "FOUR.LONGEXT",
        "Long File Name.extended",
    )
    files: list[tuple[tuple[str, ...], bytes]] = []
    for branch_index, branch in enumerate(branches, start=1):
        for file_index, name in enumerate(names, start=1):
            size = 80 + branch_index * 31 + file_index * 47
            payload = bytes(
                (branch_index * 41 + file_index * 17 + offset * 13) & 0xFF
                for offset in range(size)
            )
            files.append(((branch, name), payload))
    return branches, tuple(files)


def lfn_sibling_tree_fixture() -> tuple[
    tuple[str, ...], tuple[tuple[tuple[str, ...], bytes], ...]
]:
    branches = ("NATIVE_UNC", "RUN_0657_20260821_170616")
    files: list[tuple[tuple[str, ...], bytes]] = []
    for branch_index, branch in enumerate(branches, start=1):
        for file_index in range(1, 7):
            components = (branch, f"FILE_{file_index:02d}.BIN")
            files.append(
                (components, synthetic_payload(components, 80 + file_index * 47))
            )
    return branches, tuple(files)


def synthetic_payload(components: tuple[str, ...], size: int) -> bytes:
    """Создать локальные тестовые байты заданного размера, не читая файл с ZX-Evo."""
    seed = hashlib.sha256("/".join(components).encode("ascii")).digest()
    return (seed * ((size + len(seed) - 1) // len(seed)))[:size]


def write_fixture_file_preserving_name(
    image: Fat32Image, dir_cluster: int, name: str, payload: bytes
) -> None:
    """Записать fixture-файл, сохранив регистр имени даже при совпадении с 8.3."""
    existing = image.find_entry(dir_cluster, name)
    if existing:
        image.free_chain(existing["cluster"])
        image.mark_deleted(dir_cluster, existing)

    clusters_needed = max(1, (len(payload) + image.cluster_size - 1) // image.cluster_size)
    clusters = image.allocate_clusters(clusters_needed)
    position = 0
    for cluster in clusters:
        offset = image.cluster_offset(cluster)
        chunk = payload[position : position + image.cluster_size]
        image.data[offset : offset + len(chunk)] = chunk
        position += len(chunk)

    entries = UPDATE.make_file_entries(image, dir_cluster, name, clusters[0], len(payload))
    short_display = image.short_to_name(entries[-1][:11])
    if len(entries) == 1 and name != short_display:
        entries = UPDATE.lfn_entries(name, entries[-1][:11]) + entries
    slot = image.find_free_dir_slots(dir_cluster, len(entries))
    image.write_dir_entries(dir_cluster, slot, entries)


def async_smb_tree_fixture() -> tuple[
    tuple[str, ...], tuple[tuple[tuple[str, ...], bytes], ...]
]:
    """Метаданные CODEX_SMB_ASYNC_20260820_01; содержимое всегда синтетическое."""
    directories = ("NATIVE_UNC", "RUN_0657_20260821_170616")
    root_files = (
        ("windows_trace_600001.bin", 600001),
        ("read_test.bin", 16384),
        ("test_10k.bin", 10000),
        ("test_64k.bin", 65536),
        ("test_64kp1.bin", 65537),
        ("evogram.bin", 53248),
        ("np_target.txt", 16),
        ("async_read.bin", 196608),
        ("disconnect_read.bin", 65536),
        ("disconnect_active.bin", 65536),
        ("roundtrip_600001.bin", 600001),
        ("copyfile_600001.bin", 600001),
        ("flush_600001.bin", 600001),
        ("overwrite_while_reading.bin", 12345),
        ("security_query.bin", 1),
        ("file_regions.bin", 1),
        ("file_identity.bin", 1),
        ("allocation_262147.bin", 262147),
        ("async_pending_600001.bin", 600001),
        ("compound_padding_odd.bin", 1),
    )
    native_files = (
        ("native_source_20260821_262147.bin", 262147),
        ("native_singlewrite_02_262147.bin", 262147),
        ("compound_padding_odd.bin", 1),
    )
    run_files = (
        ("read_test.bin", 16384),
        ("test_10k.bin", 10000),
        ("test_64k.bin", 65536),
        ("test_64kp1.bin", 65537),
        ("evogram.bin", 53248),
        ("np_target.txt", 16),
        ("async_read.bin", 196608),
        ("disconnect_read.bin", 65536),
        ("disconnect_active.bin", 65536),
        ("roundtrip_600001.bin", 600001),
        ("flush_600001.bin", 600001),
        ("copyfile_600001.bin", 600001),
        ("overwrite_while_reading.bin", 12345),
        ("security_query.bin", 1),
        ("win_HOSTNAME_source_600001.bin", 600001),
        ("win_IP_source_262147.bin", 262147),
        ("file_regions.bin", 1),
    )
    specs = tuple(((name,), size) for name, size in root_files)
    specs += tuple(((directories[0], name), size) for name, size in native_files)
    specs += tuple(((directories[1], name), size) for name, size in run_files)
    return directories, tuple(
        (components, synthetic_payload(components, size)) for components, size in specs
    )


def tree_source_name(shape: str) -> str:
    return ASYNC_SMB_TREE_SOURCE if shape == "async-smb" else TREE_SOURCE


def tree_fixture(
    depth: int, shape: str
) -> tuple[tuple[str, ...], tuple[tuple[tuple[str, ...], bytes], ...]]:
    if shape == "siblings":
        return sibling_tree_fixture()
    if shape == "lfn-siblings":
        return lfn_sibling_tree_fixture()
    if shape == "async-smb":
        return async_smb_tree_fixture()
    if shape != "chain":
        raise ValueError(f"Unknown recursive fixture shape: {shape}")
    if depth < 4:
        raise ValueError("Recursive fixture depth must be at least 4")
    directories = tuple(f"D{level:02d}" for level in range(1, depth + 1))
    files = (
        (("ROOT.BIN",), bytes((index * 17 + 3) & 0xFF for index in range(700))),
        (directories[:1] + ("ONE.C",), b"level one is non-empty\r\n"),
        (directories[:2] + ("TWO.$C",), SOURCE_PAYLOAD),
        (
            directories[:3] + ("THREE.LONGEXT",),
            bytes((index * 29 + 11) & 0xFF for index in range(1200)),
        ),
        (directories[:4] + ("FOUR.DAT",), b"4"),
    ) + tuple(
        (
            directories[:level] + (f"F{level:02d}.DAT",),
            f"level {level} is non-empty\r\n".encode("ascii"),
        )
        for level in range(5, depth + 1)
    )
    return directories, files


def fsinfo_offset(image: Fat32Image) -> int:
    """Вернуть смещение основного FAT32 FSInfo в superfloppy fixture."""
    relative_sector = le16(image.data, 48)
    if relative_sector == 0 or relative_sector >= image.reserved:
        raise RuntimeError(f"Некорректный BPB_FSInfo={relative_sector}")
    return relative_sector * image.bps


def isolated_ini(payload: bytes) -> bytes:
    """Отключить плагины/сохранённые пути и оставить физический порядок панели."""
    result: list[str] = []
    section = ""
    plugins_closed = False
    for original in payload.decode("cp866", errors="replace").splitlines():
        stripped = original.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            next_section = stripped[1:-1].upper()
            if section == "PLUGINS" and next_section != "PLUGINS":
                result.append("")
                plugins_closed = True
            section = next_section
            result.append(original)
            continue

        if section == "PLUGINS":
            continue

        upper = stripped.split(";", 1)[0].strip().upper()
        line = original
        if upper.startswith("SAVEPATHS="):
            line = "SavePaths=0; COPYF Unreal test starts in the root"
        elif upper.startswith("SAVEPOSITION="):
            line = "SavePosition=0; COPYF Unreal test uses a fixed cursor"
        elif upper.startswith("SCREENSAVER="):
            line = "ScreenSaver=0; disabled for COPYF Unreal test"
        elif section in ("LPANEL", "RPANEL") and upper.startswith("DRV="):
            line = "DRV=1; SD1zc"
        elif section in ("LPANEL", "RPANEL") and upper.startswith("CSORT="):
            line = "CSORT=0; retain physical directory order"
        result.append(line)

    if "[PLUGINS]" not in (line.strip().upper() for line in result):
        raise RuntimeError("В wc.ini отсутствует раздел [PLUGINS]")
    if not plugins_closed:
        result.append("")
    return ("\r".join(result) + "\r").encode("cp866", errors="replace")


def prepare(base: Path, image_path: Path, exe_root: Path) -> None:
    if not base.is_file():
        raise FileNotFoundError(base)
    if not image_path.is_file():
        raise FileNotFoundError(
            f"Тест не создаёт новые образы; отсутствует существующий target: {image_path}"
        )
    if base.resolve() == image_path.resolve():
        raise RuntimeError("Исходный и рабочий образы должны различаться")
    if not (exe_root / "boot.$C").is_file() or not (exe_root / "WC" / "wc.ini").is_file():
        raise FileNotFoundError(f"Неполное дерево Wild Commander: {exe_root}")

    shutil.copy2(base, image_path)
    image = Fat32Image(image_path)
    try:
        root = image.root_cluster

        # Эти две записи намеренно создаются первыми. При CSORT=0 правая панель
        # входит в AAADST, а левая одним DOWN выбирает SMALL541.$C.
        UPDATE.ensure_dir(image, root, DESTINATION)
        UPDATE.write_file_any(image, root, SOURCE, SOURCE_PAYLOAD)

        wc_cluster = UPDATE.ensure_dir(image, root, "WC")
        UPDATE.write_file_any(
            image,
            wc_cluster,
            "wc.ini",
            (exe_root / "WC" / "wc.ini").read_bytes(),
        )
        UPDATE.update_tree(image, exe_root)

        wc_entry = image.find_entry(root, "WC")
        if not wc_entry or not (wc_entry["attr"] & ATTR_DIRECTORY):
            raise RuntimeError("После подготовки отсутствует каталог WC")
        UPDATE.write_file_any(
            image,
            wc_entry["cluster"],
            "wc.ini",
            isolated_ini((exe_root / "WC" / "wc.ini").read_bytes()),
        )

        root_order = [entry["name"] for entry in image.parse_dir(root)]
        if root_order[:3] != [DESTINATION, SOURCE, "WC"]:
            raise RuntimeError(f"Неожиданный физический порядок корня: {root_order[:3]}")
        source_entry = image.find_entry(root, SOURCE)
        if not source_entry or source_entry["size"] != len(SOURCE_PAYLOAD):
            raise RuntimeError(f"Не удалось подготовить {SOURCE}")

        # Эмулировать холодную карту, где FSI_Nxt_Free неизвестен. Штатный
        # COPYF не должен добавлять отдельную запись FSInfo: на реальной SD-ZC
        # этот дополнительный I/O зависал.
        put32(image.data, fsinfo_offset(image) + 492, 0xFFFFFFFF)
        print(
            f"PREPARED {image_path}: spc={image.spc}, source={len(SOURCE_PAYLOAD)}, "
            f"sha256={hashlib.sha256(SOURCE_PAYLOAD).hexdigest()}, root={root_order[:3]}, "
            "FSI_Nxt_Free=FFFFFFFF"
        )
    finally:
        image.save()


def prepare_tree(
    base: Path, image_path: Path, exe_root: Path, depth: int, shape: str
) -> None:
    """Подготовить существующий образ для F5 дерева и следующего F8 источника."""
    if not base.is_file():
        raise FileNotFoundError(base)
    if not image_path.is_file():
        raise FileNotFoundError(
            f"Тест не создаёт новые образы; отсутствует существующий target: {image_path}"
        )
    if base.resolve() == image_path.resolve():
        raise RuntimeError("Исходный и рабочий образы должны различаться")
    if not (exe_root / "boot.$C").is_file() or not (exe_root / "WC" / "wc.ini").is_file():
        raise FileNotFoundError(f"Неполное дерево Wild Commander: {exe_root}")

    shutil.copy2(base, image_path)
    image = Fat32Image(image_path)
    try:
        root = image.root_cluster
        UPDATE.ensure_dir(image, root, DESTINATION)
        tree_source = tree_source_name(shape)
        tree = UPDATE.ensure_dir(image, root, tree_source)

        _, tree_files = tree_fixture(depth, shape)
        directories: dict[tuple[str, ...], int] = {(): tree}
        for components, payload in tree_files:
            directory_components = components[:-1]
            for component_depth in range(1, len(directory_components) + 1):
                key = directory_components[:component_depth]
                if key not in directories:
                    parent = directories[key[:-1]]
                    directories[key] = UPDATE.ensure_dir(image, parent, key[-1])
            writer = (
                write_fixture_file_preserving_name
                if shape == "async-smb"
                else UPDATE.write_file_any
            )
            writer(image, directories[directory_components], components[-1], payload)

        wc_cluster = UPDATE.ensure_dir(image, root, "WC")
        UPDATE.write_file_any(
            image,
            wc_cluster,
            "wc.ini",
            (exe_root / "WC" / "wc.ini").read_bytes(),
        )
        UPDATE.update_tree(image, exe_root)
        wc_entry = image.find_entry(root, "WC")
        if not wc_entry:
            raise RuntimeError("После подготовки отсутствует каталог WC")
        UPDATE.write_file_any(
            image,
            wc_entry["cluster"],
            "wc.ini",
            isolated_ini((exe_root / "WC" / "wc.ini").read_bytes()),
        )

        root_order = [entry["name"] for entry in image.parse_dir(root)]
        if root_order[:3] != [DESTINATION, tree_source, "WC"]:
            raise RuntimeError(f"Неожиданный физический порядок корня: {root_order[:3]}")
        print(
            f"PREPARED TREE {image_path}: spc={image.spc}, "
            f"shape={shape}, depth={depth}, files={len(tree_files)}, "
            f"bytes={sum(len(payload) for _, payload in tree_files)}, "
            f"root={root_order[:3]}"
        )
    finally:
        image.save()


def read_tree_file(image: Fat32Image, tree_cluster: int, components: tuple[str, ...]) -> bytes:
    current = tree_cluster
    for directory in components[:-1]:
        entry = image.find_entry(current, directory)
        if not entry or not (entry["attr"] & ATTR_DIRECTORY):
            raise FileNotFoundError("/".join(components[:-1]))
        current = entry["cluster"]
    return image.read_file(current, components[-1])


def inspect_tree(
    image_path: Path,
    exe_root: Path,
    depth: int,
    shape: str,
    expect_copy: bool,
    expect_delete: bool,
) -> int:
    """Проверить рекурсивный F5 в AAADST и рекурсивный F8 исходного дерева."""
    failures: list[str] = []
    image = Fat32Image(image_path)
    try:
        root = image.root_cluster
        tree_source = tree_source_name(shape)
        source_tree = image.find_entry(root, tree_source)
        if expect_delete and source_tree:
            failures.append(f"Исходный каталог {tree_source} не удалён рекурсивным F8")
        elif not expect_delete and not source_tree:
            failures.append(f"Рекурсивный F5 удалил исходный каталог {tree_source}")

        destination = image.find_entry(root, DESTINATION)
        copied_tree = None
        if not destination or not (destination["attr"] & ATTR_DIRECTORY):
            failures.append(f"Каталог назначения {DESTINATION} исчез")
        elif expect_copy:
            copied_tree = image.find_entry(destination["cluster"], tree_source)
            if not copied_tree or not (copied_tree["attr"] & ATTR_DIRECTORY):
                failures.append(
                    f"Рекурсивный F5 не создал {DESTINATION}/{tree_source}"
                )

        _, tree_files = tree_fixture(depth, shape)
        if source_tree:
            for components, expected in tree_files:
                try:
                    actual = read_tree_file(image, source_tree["cluster"], components)
                except Exception as exc:
                    failures.append(
                        f"Не читается {'/'.join((tree_source,) + components)}: {exc}"
                    )
                else:
                    if actual != expected:
                        failures.append(
                            f"Повреждены байты {'/'.join((tree_source,) + components)}"
                        )
        if copied_tree:
            for components, expected in tree_files:
                try:
                    actual = read_tree_file(image, copied_tree["cluster"], components)
                except Exception as exc:
                    failures.append(
                        f"Не читается {'/'.join((DESTINATION, tree_source) + components)}: {exc}"
                    )
                else:
                    if actual != expected:
                        failures.append(
                            f"Повреждены байты {'/'.join((DESTINATION, tree_source) + components)}"
                        )

        wc_entry = image.find_entry(root, "WC")
        if not wc_entry:
            failures.append("Контрольный каталог WC исчез")
        else:
            expected_ini = isolated_ini((exe_root / "WC" / "wc.ini").read_bytes())
            if image.read_file(wc_entry["cluster"], "wc.ini") != expected_ini:
                failures.append("Рекурсивные операции неожиданно изменили WC/wc.ini")

        fat_length = image.fat_size * image.bps
        fat0 = image.fat_offset(0, 0)
        fat1 = image.fat_offset(0, 1)
        if image.data[fat0 : fat0 + fat_length] != image.data[fat1 : fat1 + fat_length]:
            failures.append("FAT0 и FAT1 различаются после рекурсивных F5/F8")
        orphans = collect_orphan_clusters(image)
        if orphans:
            failures.append(f"Потерянные FAT-кластеры: {sorted(orphans)[:16]}")
    finally:
        image.save()

    if failures:
        print("WCFX RECURSIVE UNREAL FAIL:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(
        f"WCFX RECURSIVE UNREAL PASS: shape={shape}, depth={depth}, "
        f"{'F5/F8' if expect_copy and expect_delete else 'F5' if expect_copy else 'F8'}, "
        "exact file bytes, "
        "equal FAT mirrors, no orphans"
    )
    return 0


def inspect(image_path: Path, exe_root: Path, renamed: bool) -> int:
    failures: list[str] = []
    image = Fat32Image(image_path)
    try:
        root = image.root_cluster
        expected_source = RENAMED_SOURCE if renamed else SOURCE
        source_entry = image.find_entry(root, expected_source)
        destination_entry = image.find_entry(root, DESTINATION)
        if not source_entry:
            failures.append(f"Исходный {expected_source} исчез")
        elif image.read_file(root, expected_source) != SOURCE_PAYLOAD:
            failures.append(f"Исходный {expected_source} повреждён")
        if renamed and image.find_entry(root, SOURCE):
            failures.append(f"После F6 осталось старое имя {SOURCE}")

        if not destination_entry or not (destination_entry["attr"] & ATTR_DIRECTORY):
            failures.append(f"Каталог назначения {DESTINATION} исчез")
        else:
            copied = image.find_entry(destination_entry["cluster"], SOURCE)
            if not copied:
                failures.append(f"В {DESTINATION} отсутствует {SOURCE}")
            else:
                payload = image.read_file(destination_entry["cluster"], SOURCE)
                if copied["size"] != len(SOURCE_PAYLOAD):
                    failures.append(
                        f"Размер копии {copied['size']}, ожидалось {len(SOURCE_PAYLOAD)}"
                    )
                if payload != SOURCE_PAYLOAD:
                    failures.append("SHA/байты копии не совпадают с исходником")
                chain = image.cluster_chain(copied["cluster"])
                if len(chain) != 1:
                    failures.append(f"Копия занимает {len(chain)} кластеров, ожидался 1")

        wc_entry = image.find_entry(root, "WC")
        if not wc_entry:
            failures.append("Каталог WC исчез")
        else:
            actual_ini = image.read_file(wc_entry["cluster"], "wc.ini")
            expected_ini = isolated_ini((exe_root / "WC" / "wc.ini").read_bytes())
            if actual_ini != expected_ini:
                failures.append("Тест F5 неожиданно изменил WC/wc.ini")

        fat_length = image.fat_size * image.bps
        fat0 = image.fat_offset(0, 0)
        fat1 = image.fat_offset(0, 1)
        if image.data[fat0 : fat0 + fat_length] != image.data[fat1 : fat1 + fat_length]:
            failures.append("FAT0 и FAT1 различаются")

        orphans = collect_orphan_clusters(image)
        if orphans:
            failures.append(f"Потерянные FAT-кластеры: {sorted(orphans)[:16]}")

        next_free = le32(image.data, fsinfo_offset(image) + 492)
        if next_free != 0xFFFFFFFF:
            failures.append(
                f"COPYF неожиданно записал FSI_Nxt_Free: #{next_free:08X}"
            )
    finally:
        image.save()

    if failures:
        print("WCFX COPYF UNREAL FAIL:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(
        f"WCFX COPYF{' + RENAME' if renamed else ''} UNREAL PASS: "
        "source/destination=541 bytes, exact SHA-256, "
        "one SPC8 cluster, equal FAT mirrors, no orphans, wc.ini unchanged, "
        "no automatic FSInfo write"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--base", type=Path, required=True)
    prepare_parser.add_argument("--image", type=Path, required=True)
    prepare_parser.add_argument("--exe", type=Path, required=True)
    inspect_parser = subparsers.add_parser("inspect")
    inspect_parser.add_argument("--image", type=Path, required=True)
    inspect_parser.add_argument("--exe", type=Path, required=True)
    inspect_parser.add_argument("--renamed", action="store_true")
    prepare_tree_parser = subparsers.add_parser("prepare-tree")
    prepare_tree_parser.add_argument("--base", type=Path, required=True)
    prepare_tree_parser.add_argument("--image", type=Path, required=True)
    prepare_tree_parser.add_argument("--exe", type=Path, required=True)
    prepare_tree_parser.add_argument("--depth", type=int, default=DEFAULT_TREE_DEPTH)
    prepare_tree_parser.add_argument(
        "--shape",
        choices=("chain", "siblings", "lfn-siblings", "async-smb"),
        default=DEFAULT_TREE_SHAPE,
    )
    inspect_tree_parser = subparsers.add_parser("inspect-tree")
    inspect_tree_parser.add_argument("--image", type=Path, required=True)
    inspect_tree_parser.add_argument("--exe", type=Path, required=True)
    inspect_tree_parser.add_argument("--depth", type=int, default=DEFAULT_TREE_DEPTH)
    inspect_tree_parser.add_argument(
        "--shape",
        choices=("chain", "siblings", "lfn-siblings", "async-smb"),
        default=DEFAULT_TREE_SHAPE,
    )
    inspect_tree_parser.add_argument("--delete-only", action="store_true")
    inspect_tree_parser.add_argument("--copy-only", action="store_true")
    args = parser.parse_args()

    if args.command == "prepare":
        prepare(args.base, args.image, args.exe)
        return 0
    if args.command == "prepare-tree":
        prepare_tree(args.base, args.image, args.exe, args.depth, args.shape)
        return 0
    if args.command == "inspect-tree":
        if args.delete_only and args.copy_only:
            raise ValueError("--delete-only and --copy-only are mutually exclusive")
        return inspect_tree(
            args.image,
            args.exe,
            args.depth,
            args.shape,
            expect_copy=not args.delete_only,
            expect_delete=not args.copy_only,
        )
    return inspect(args.image, args.exe, args.renamed)


if __name__ == "__main__":
    raise SystemExit(main())
