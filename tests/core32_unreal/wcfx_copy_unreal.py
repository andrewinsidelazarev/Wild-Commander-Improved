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
SOURCE = "SMALL541.BIN"
SOURCE_PAYLOAD = bytes((index * 73 + 19) & 0xFF for index in range(541))


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
        # входит в AAADST, а левая одним DOWN выбирает SMALL541.BIN.
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
            raise RuntimeError("Не удалось подготовить SMALL541.BIN")

        # Эмулировать реальную холодную карту, где FSI_Nxt_Free неизвестен.
        # После штатного COPYF CORE32 обязан сохранить уже найденную позицию,
        # иначе первый поиск будет повторяться после каждой перезагрузки.
        put32(image.data, fsinfo_offset(image) + 492, 0xFFFFFFFF)
        print(
            f"PREPARED {image_path}: spc={image.spc}, source={len(SOURCE_PAYLOAD)}, "
            f"sha256={hashlib.sha256(SOURCE_PAYLOAD).hexdigest()}, root={root_order[:3]}, "
            "FSI_Nxt_Free=FFFFFFFF"
        )
    finally:
        image.save()


def inspect(image_path: Path, exe_root: Path) -> int:
    failures: list[str] = []
    image = Fat32Image(image_path)
    try:
        root = image.root_cluster
        source_entry = image.find_entry(root, SOURCE)
        destination_entry = image.find_entry(root, DESTINATION)
        if not source_entry:
            failures.append(f"Исходный {SOURCE} исчез")
        elif image.read_file(root, SOURCE) != SOURCE_PAYLOAD:
            failures.append(f"Исходный {SOURCE} повреждён")

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
        cluster_limit = (
            image.total_sectors - image.first_data_sector
        ) // image.spc + 2
        if not 2 <= next_free < cluster_limit:
            failures.append(f"FSI_Nxt_Free не сохранён: #{next_free:08X}")
        elif image.get_fat(next_free) != 0:
            failures.append(
                f"FSI_Nxt_Free={next_free} не указывает на свободный кластер fixture"
            )
    finally:
        image.save()

    if failures:
        print("WCFX COPYF UNREAL FAIL:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(
        "WCFX COPYF UNREAL PASS: source/destination=541 bytes, exact SHA-256, "
        "one SPC8 cluster, equal FAT mirrors, no orphans, wc.ini unchanged, "
        "FSI_Nxt_Free persisted for cold remount"
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
    args = parser.parse_args()

    if args.command == "prepare":
        prepare(args.base, args.image, args.exe)
        return 0
    return inspect(args.image, args.exe)


if __name__ == "__main__":
    raise SystemExit(main())
