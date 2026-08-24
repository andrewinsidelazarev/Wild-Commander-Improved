"""Подготовить и проверить существующий тестовый FAT32-образ Unreal."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
WC_ROOT = PROJECT_ROOT.parents[2]
UPDATE_PATH = WC_ROOT.parent / "Chkdsk" / "Debug" / "update_wc_image.py"


def load_update_module():
    spec = importlib.util.spec_from_file_location("unzip_update_wc", UPDATE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Не удалось загрузить {UPDATE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


UPDATE = load_update_module()
Fat32Image = UPDATE.Fat32Image
ATTR_DIRECTORY = UPDATE.ATTR_DIRECTORY


def configured_ini(payload: bytes) -> bytes:
    """Зафиксировать корень SD, физический порядок и отключить сохранение позиции."""
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
            line = "SavePaths=0; тест UNZIP начинается из корня"
        elif upper.startswith("SAVEPOSITION="):
            line = "SavePosition=0; тест UNZIP не восстанавливает курсор"
        elif upper.startswith("SCREENSAVER="):
            line = "ScreenSaver=0; скринсейвер отключён для теста"
        elif section in ("LPANEL", "RPANEL") and upper.startswith("DRV="):
            line = "DRV=1; тестовая SD1zc"
        elif section in ("LPANEL", "RPANEL") and upper.startswith("CSORT="):
            line = "CSORT=0; физический порядок, TEST.ZIP записан последним"
        result.append(line)
    configured = ("\r".join(result) + "\r").encode("cp866", errors="replace")
    if b"FILEX.WMF\rUNZIP.WMF\r" not in configured:
        raise RuntimeError("UNZIP должен находиться сразу после FILEX в wc.ini")
    return configured


def require_directory(image: Fat32Image, cluster: int, name: str) -> int:
    entry = image.find_entry(cluster, name)
    if not entry or not (entry["attr"] & ATTR_DIRECTORY):
        raise FileNotFoundError(f"Каталог не найден: {name}")
    return entry["cluster"]


def read_path(image: Fat32Image, path: str) -> bytes:
    parts = path.split("/")
    cluster = image.root_cluster
    for component in parts[:-1]:
        cluster = require_directory(image, cluster, component)
    return image.read_file(cluster, parts[-1])


def prepare(image_path: Path, exe_root: Path, archive_path: Path) -> None:
    if not image_path.is_file():
        raise FileNotFoundError(
            f"Скрипт не создаёт образы; отсутствует готовый образ: {image_path}"
        )
    required = (
        exe_root / "boot.$C",
        exe_root / "WC" / "wc.ini",
        exe_root / "WC" / "FILEX.WMF",
        exe_root / "WC" / "UNZIP.WMF",
        archive_path,
    )
    for path in required:
        if not path.is_file():
            raise FileNotFoundError(path)

    before_hash = hashlib.sha256(image_path.read_bytes()).hexdigest()
    image = Fat32Image(image_path)
    try:
        root = image.root_cluster
        wc_cluster = require_directory(image, root, "WC")
        for name in ("ROOT.TXT", "DIR1", "ТЕСТ", "IMPLICIT", "BIG", "TEST.ZIP"):
            if image.find_entry(root, name):
                raise RuntimeError(f"Тестовый объект уже существует в корне: {name}")

        UPDATE.write_file_any(image, root, "boot.$C", (exe_root / "boot.$C").read_bytes())
        UPDATE.write_file_any(
            image,
            wc_cluster,
            "FILEX.WMF",
            (exe_root / "WC" / "FILEX.WMF").read_bytes(),
        )
        UPDATE.write_file_any(
            image,
            wc_cluster,
            "UNZIP.WMF",
            (exe_root / "WC" / "UNZIP.WMF").read_bytes(),
        )
        UPDATE.write_file_any(
            image,
            wc_cluster,
            "wc.ini",
            configured_ini((exe_root / "WC" / "wc.ini").read_bytes()),
        )
        UPDATE.write_file_any(image, root, "TEST.ZIP", archive_path.read_bytes())
    finally:
        image.save()

    after_hash = hashlib.sha256(image_path.read_bytes()).hexdigest()
    check = Fat32Image(image_path)
    wc_cluster = require_directory(check, check.root_cluster, "WC")
    checks = {
        "boot.$C": (exe_root / "boot.$C").read_bytes(),
        "TEST.ZIP": archive_path.read_bytes(),
    }
    for name, expected in checks.items():
        actual = check.read_file(check.root_cluster, name)
        if actual != expected:
            raise RuntimeError(f"После записи отличается {name}")
    if check.read_file(wc_cluster, "FILEX.WMF") != (exe_root / "WC" / "FILEX.WMF").read_bytes():
        raise RuntimeError("После записи отличается WC/FILEX.WMF")
    if check.read_file(wc_cluster, "UNZIP.WMF") != (exe_root / "WC" / "UNZIP.WMF").read_bytes():
        raise RuntimeError("После записи отличается WC/UNZIP.WMF")
    print(
        f"PREPARED existing image={image_path}; spc={check.spc}; "
        f"before={before_hash}; after={after_hash}; TEST.ZIP is last root entry"
    )


def refresh_plugin(
    image_path: Path,
    plugin_path: Path,
    filex_path: Path,
    allow_used: bool = False,
) -> None:
    """Обновить UNZIP.WMF и обязательный провайдер FILEX в тестовом образе."""
    if not image_path.is_file():
        raise FileNotFoundError(
            f"Скрипт не создаёт образы; отсутствует готовый образ: {image_path}"
        )
    if not plugin_path.is_file():
        raise FileNotFoundError(plugin_path)
    if not filex_path.is_file():
        raise FileNotFoundError(filex_path)

    before_hash = hashlib.sha256(image_path.read_bytes()).hexdigest()
    image = Fat32Image(image_path)
    root = image.root_cluster
    wc_cluster = require_directory(image, root, "WC")
    if not image.find_entry(root, "TEST.ZIP"):
        raise RuntimeError("Образ ещё не подготовлен: TEST.ZIP отсутствует")
    for name in ("ROOT.TXT", "DIR1", "ТЕСТ", "IMPLICIT", "BIG"):
        if image.find_entry(root, name) and not allow_used:
            raise RuntimeError(f"Образ уже использован для извлечения: {name}")

    ini_lines = [line.strip().upper() for line in image.read_file(wc_cluster, "wc.ini").splitlines()]
    plugins_index = ini_lines.index(b"[PLUGINS]")
    if ini_lines[plugins_index + 1 : plugins_index + 3] != [b"FILEX.WMF", b"UNZIP.WMF"]:
        raise RuntimeError("В образе UNZIP.WMF не зарегистрирован сразу после FILEX.WMF")

    try:
        UPDATE.write_file_any(image, wc_cluster, "FILEX.WMF", filex_path.read_bytes())
        UPDATE.write_file_any(image, wc_cluster, "UNZIP.WMF", plugin_path.read_bytes())
    finally:
        image.save()

    after_hash = hashlib.sha256(image_path.read_bytes()).hexdigest()
    check = Fat32Image(image_path)
    wc_cluster = require_directory(check, check.root_cluster, "WC")
    actual_filex = check.read_file(wc_cluster, "FILEX.WMF")
    expected_filex = filex_path.read_bytes()
    if actual_filex != expected_filex:
        raise RuntimeError("После обновления отличается WC/FILEX.WMF")
    actual = check.read_file(wc_cluster, "UNZIP.WMF")
    expected = plugin_path.read_bytes()
    if actual != expected:
        raise RuntimeError("После обновления отличается WC/UNZIP.WMF")
    print(
        f"REFRESHED existing image={image_path}; before={before_hash}; "
        f"after={after_hash}; filex_sha256={hashlib.sha256(actual_filex).hexdigest()}; "
        f"plugin_sha256={hashlib.sha256(actual).hexdigest()}"
    )


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


def inspect(image_path: Path, archive_path: Path) -> None:
    if not image_path.is_file():
        raise FileNotFoundError(image_path)
    from make_test_zip import test_entries

    image = Fat32Image(image_path)
    failures: list[str] = []
    for entry in test_entries():
        if entry.is_directory:
            continue
        try:
            actual = read_path(image, entry.name)
        except (FileNotFoundError, RuntimeError) as error:
            failures.append(f"{entry.name}: {error}")
            continue
        if actual != entry.data:
            failures.append(
                f"{entry.name}: размер {len(actual)} вместо {len(entry.data)}, "
                f"sha256={hashlib.sha256(actual).hexdigest()}"
            )

    archive = image.read_file(image.root_cluster, "TEST.ZIP")
    if archive != archive_path.read_bytes():
        failures.append("Исходный TEST.ZIP изменён")
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
        raise SystemExit(1)
    print(
        f"UNZIP UNREAL PASS: files=7; archive_sha256="
        f"{hashlib.sha256(archive).hexdigest()}; equal FAT mirrors; no temp files"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--image", type=Path, required=True)
    prepare_parser.add_argument("--exe", type=Path, required=True)
    prepare_parser.add_argument("--archive", type=Path, required=True)
    refresh_parser = subparsers.add_parser("refresh-plugin")
    refresh_parser.add_argument("--image", type=Path, required=True)
    refresh_parser.add_argument("--plugin", type=Path, required=True)
    refresh_parser.add_argument(
        "--filex",
        type=Path,
        default=WC_ROOT / "exe" / "WC" / "FILEX.WMF",
    )
    refresh_parser.add_argument("--allow-used", action="store_true")
    inspect_parser = subparsers.add_parser("inspect")
    inspect_parser.add_argument("--image", type=Path, required=True)
    inspect_parser.add_argument("--archive", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.image, args.exe, args.archive)
    elif args.command == "refresh-plugin":
        refresh_plugin(args.image, args.plugin, args.filex, args.allow_used)
    else:
        inspect(args.image, args.archive)


if __name__ == "__main__":
    main()
