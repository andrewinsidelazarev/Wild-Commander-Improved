"""Подготовить и проверить существующий FAT32-образ для холодного TXTEDIT Save."""
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


def fsinfo_offset(image: Fat32Image) -> int:
    relative_sector = le16(image.data, 48)
    if relative_sector == 0 or relative_sector >= image.reserved:
        raise RuntimeError(f"Некорректный BPB_FSInfo={relative_sector}")
    return relative_sector * image.bps


def configured_ini(payload: bytes) -> bytes:
    """Оставить плагины, но сделать начальную позицию панелей детерминированной."""
    result: list[str] = []
    section = ""
    text = payload.decode("cp866", errors="replace")
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for original in lines:
        stripped = original.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped[1:-1].upper()
            result.append(original)
            continue
        upper = stripped.split(";", 1)[0].strip().upper()
        line = original
        if upper.startswith("SAVEPATHS="):
            line = "SavePaths=0; TXTEDIT cold-save fixture"
        elif upper.startswith("SAVEPOSITION="):
            line = "SavePosition=0; TXTEDIT cold-save fixture"
        elif upper.startswith("SCREENSAVER="):
            line = "ScreenSaver=0; TXTEDIT cold-save fixture"
        elif section in ("LPANEL", "RPANEL") and upper.startswith("DRV="):
            line = "DRV=1; SD1zc"
        elif section in ("LPANEL", "RPANEL") and upper.startswith("CSORT="):
            line = "CSORT=0; retain physical directory order"
        result.append(line)
    configured = ("\r".join(result) + "\r").encode("cp866", errors="replace")
    if b"FILEX.WMF" not in configured or b"TXTEDIT.WMF" not in configured:
        raise RuntimeError("В тестовом wc.ini должны остаться FILEX.WMF и TXTEDIT.WMF")
    return configured


def edited_ini(payload: bytes, comment_spaces: int) -> bytes:
    """Вставить пробелы только после `CPU_FREQ=2;`, то есть внутри комментария."""
    marker = b"CPU_FREQ=2;"
    offset = payload.find(marker)
    if offset < 0:
        raise RuntimeError("В wc.ini отсутствует строка CPU_FREQ=2;")
    insert_at = offset + len(marker)
    return payload[:insert_at] + b" " * comment_spaces + payload[insert_at:]


def prepare(
    base: Path, image_path: Path, exe_root: Path, fsi_next_free: str
) -> None:
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
        wc_entry = image.find_entry(root, "WC")
        if not wc_entry or not (wc_entry["attr"] & ATTR_DIRECTORY):
            raise RuntimeError("В базовом образе отсутствует каталог WC")
        UPDATE.update_tree(image, exe_root)
        wc_entry = image.find_entry(root, "WC")
        wc_cluster = wc_entry["cluster"]
        expected = configured_ini((exe_root / "WC" / "wc.ini").read_bytes())
        UPDATE.write_file_any(image, wc_cluster, "wc.ini", expected)
        ini_entry = image.find_entry(wc_cluster, "wc.ini")
        if not ini_entry:
            raise RuntimeError("После подготовки отсутствует WC/wc.ini")

        limit = (image.total_sectors - image.first_data_sector) // image.spc + 2
        first_free = next(cluster for cluster in range(2, limit) if image.get_fat(cluster) == 0)
        # unknown воспроизводит старый носитель без подсказки; first-free —
        # холодный запуск после операции, уже сохранившей FSI_Nxt_Free.
        next_free = 0xFFFFFFFF if fsi_next_free == "unknown" else first_free
        put32(image.data, fsinfo_offset(image) + 492, next_free)
        root_order = [entry["name"] for entry in image.parse_dir(root)]
        wc_order = [entry["name"] for entry in image.parse_dir(wc_cluster)]
        print(
            f"PREPARED {image_path}: spc={image.spc}, wc_ini_cluster={ini_entry['cluster']}, "
            f"size={len(expected)}, sha256={hashlib.sha256(expected).hexdigest()}, "
            f"first_free={first_free}, FSI_Nxt_Free={next_free:08X}"
        )
        print(f"ROOT_ORDER={root_order[:8]}")
        print(f"WC_ORDER={wc_order[:8]}")
    finally:
        image.save()


def inspect(
    image_path: Path,
    exe_root: Path,
    comment_spaces: int,
    old_cluster: int,
    expected_next_free: int,
) -> int:
    failures: list[str] = []
    image = Fat32Image(image_path)
    try:
        root = image.root_cluster
        wc_entry = image.find_entry(root, "WC")
        if not wc_entry or not (wc_entry["attr"] & ATTR_DIRECTORY):
            failures.append("Каталог WC исчез")
            payload = b""
            current_cluster = 0
            service_names: list[str] = []
        else:
            wc_cluster = wc_entry["cluster"]
            ini_entry = image.find_entry(wc_cluster, "wc.ini")
            if not ini_entry:
                failures.append("WC/wc.ini исчез")
                payload = b""
                current_cluster = 0
            else:
                payload = image.read_file(wc_cluster, "wc.ini")
                current_cluster = ini_entry["cluster"]
                current_chain = image.cluster_chain(current_cluster)
            service_names = [
                entry["name"]
                for entry in image.parse_dir(wc_cluster)
                if entry["name"].upper().startswith(("WCETMP", "WCEBAK"))
            ]

        expected = edited_ini(
            configured_ini((exe_root / "WC" / "wc.ini").read_bytes()),
            comment_spaces,
        )
        if payload != expected:
            mismatch = next(
                (
                    index
                    for index, (actual_byte, expected_byte) in enumerate(
                        zip(payload, expected, strict=False)
                    )
                    if actual_byte != expected_byte
                ),
                min(len(payload), len(expected)),
            )
            failures.append(
                f"wc.ini не равен ожидаемому результату редактора: "
                f"size={len(payload)}, expected={len(expected)}, mismatch={mismatch}, "
                f"actual={payload[max(0, mismatch-16):mismatch+24]!r}, "
                f"expected={expected[max(0, mismatch-16):mismatch+24]!r}"
            )
        if current_cluster == old_cluster:
            failures.append("Безопасное сохранение не заменило цепочку wc.ini")
        if image.get_fat(old_cluster) != 0:
            failures.append(f"Старая цепочка {old_cluster} не освобождена")
        if service_names:
            failures.append(f"Остались служебные файлы: {service_names}")

        next_free = le32(image.data, fsinfo_offset(image) + 492)
        if next_free != expected_next_free:
            failures.append(
                f"FSI_Nxt_Free={next_free}, ожидалось неизменённое значение "
                f"{expected_next_free}"
            )

        fat_length = image.fat_size * image.bps
        fat0 = image.fat_offset(0, 0)
        fat1 = image.fat_offset(0, 1)
        if image.data[fat0 : fat0 + fat_length] != image.data[fat1 : fat1 + fat_length]:
            failures.append("FAT0 и FAT1 различаются")
        orphans = collect_orphan_clusters(image)
        if orphans:
            orphan_details = []
            for cluster in sorted(orphans)[:16]:
                offset = image.cluster_offset(cluster)
                orphan_details.append(
                    (
                        cluster,
                        image.get_fat(cluster),
                        bytes(image.data[offset : offset + 32]),
                    )
                )
            failures.append(f"Потерянные FAT-кластеры: {orphan_details}")
    finally:
        image.save()

    if failures:
        print("TXTEDIT SAVE UNREAL FAIL:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(
        f"TXTEDIT SAVE UNREAL PASS: comment_spaces={comment_spaces}, size={len(payload)}, "
        f"sha256={hashlib.sha256(payload).hexdigest()}, current_cluster={current_cluster}, "
        f"freed_cluster={old_cluster}, FSI_Nxt_Free={expected_next_free}, equal FAT mirrors, "
        "no automatic FSInfo write, no orphans/temp/backup"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--base", type=Path, required=True)
    prepare_parser.add_argument("--image", type=Path, required=True)
    prepare_parser.add_argument("--exe", type=Path, required=True)
    prepare_parser.add_argument(
        "--fsi-next-free", choices=("unknown", "first-free"), default="unknown"
    )
    inspect_parser = subparsers.add_parser("inspect")
    inspect_parser.add_argument("--image", type=Path, required=True)
    inspect_parser.add_argument("--exe", type=Path, required=True)
    inspect_parser.add_argument("--comment-spaces", type=int, required=True)
    inspect_parser.add_argument("--old-cluster", type=int, required=True)
    inspect_parser.add_argument("--expected-next-free", type=int, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.base, args.image, args.exe, args.fsi_next_free)
        return 0
    return inspect(
        args.image,
        args.exe,
        args.comment_spaces,
        args.old_cluster,
        args.expected_next_free,
    )


if __name__ == "__main__":
    raise SystemExit(main())
