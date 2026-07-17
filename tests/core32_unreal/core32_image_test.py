# Codex - 2026-07-16 - begin
"""Подготовка и проверка изолированного FAT32-образа для патченного Unreal."""
from __future__ import annotations

import argparse
import importlib.util
import shutil
import struct
import types
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
CHKDSK_ROOT = PROJECT_ROOT.parent / "Chkdsk"
UPDATE_PATH = CHKDSK_ROOT / "Debug" / "update_wc_image.py"
TEST_DIRECTORY = "C32T716"
LONG_DIRECTORY = "LFNDEL"
FULL_DIRECTORY = "FULLEOC"
# Codex - 2026-07-17 - begin
APPEND_FILE = "FTPAPP.BIN"
APPEND_PAYLOAD = (
    bytes([0xA1]) * 3
    + bytes([0xB2]) * 509
    + bytes([0xC3])
    + bytes([0xD4]) * 511
    + bytes([0xE5]) * 512
    + bytes([0xF6]) * 17
    + bytes([0x17]) * 100
    + bytes([0x28]) * 400
)
# Codex - 2026-07-17 - end
PLUGIN_NAME = "CORE32T.WMF"
MAIN_RESULT = "C32RESULT.BIN"
LONG_RESULT = "C32LONG.BIN"
MARK_BEGIN = "; Codex - 2026-07-16 - begin"
MARK_END = "; Codex - 2026-07-16 - end"


def load_update_module():
    spec = importlib.util.spec_from_file_location("core32_update_wc", UPDATE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Не удалось загрузить {UPDATE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


UPDATE = load_update_module()
Fat32Image = UPDATE.Fat32Image
ATTR_ARCHIVE = UPDATE.ATTR_ARCHIVE
ATTR_DIRECTORY = UPDATE.ATTR_DIRECTORY
le16 = UPDATE.le16
le32 = UPDATE.le32
put16 = UPDATE.put16
put32 = UPDATE.put32


# Codex - 2026-07-17 - begin
def configure_ini(
    payload: bytes,
    left_driver: int | None = None,
    right_driver: int | None = None,
) -> bytes:
# Codex - 2026-07-17 - end
    text = payload.decode("cp866", errors="replace")
    source_lines = text.splitlines()
    filtered: list[str] = []
    skip_marker = False
# Codex - 2026-07-17 - begin
    current_section = ""
# Codex - 2026-07-17 - end
    for line in source_lines:
        stripped = line.strip()
        upper = stripped.split(";", 1)[0].strip().upper()
# Codex - 2026-07-17 - begin
        if stripped.startswith("[") and stripped.endswith("]"):
            current_section = stripped[1:-1].upper()
# Codex - 2026-07-17 - end
        if stripped == MARK_BEGIN:
            skip_marker = True
            continue
        if stripped == MARK_END and skip_marker:
            skip_marker = False
            continue
        if upper == PLUGIN_NAME:
            continue
        if stripped.upper().startswith("SAVEPATHS="):
            line = "SavePaths=0; тест всегда начинается из корня"
        elif stripped.upper().startswith("SAVEPOSITION="):
            line = "SavePosition=0; позиция панели не восстанавливается"
        elif stripped.upper().startswith("SCREENSAVER="):
            line = "ScreenSaver=0; скринсейвер отключён на время теста"
# Codex - 2026-07-17 - begin
        elif upper.startswith("DRV=") and current_section == "LPANEL" and left_driver is not None:
            line = f"DRV={left_driver}; тестовый драйвер левой панели"
        elif upper.startswith("DRV=") and current_section == "RPANEL" and right_driver is not None:
            line = f"DRV={right_driver}; тестовый драйвер правой панели"
# Codex - 2026-07-17 - end
        filtered.append(line)

    result: list[str] = []
    inserted = False
    for line in filtered:
        # Codex - 2026-07-16 - begin
        if not inserted and line.strip().upper() == "[PLUGINS]":
            # Парсер WC завершает список плагинов на пустой строке. Комментарий
            # сразу после заголовка превращался именно в такую строку, поэтому
            # маркер начала ставится перед секцией, а тестовый плагин остаётся
            # первой строкой внутри неё.
            result.extend((MARK_BEGIN, line, PLUGIN_NAME, MARK_END))
            inserted = True
        else:
            result.append(line)
        # Codex - 2026-07-16 - end
    if not inserted:
        raise RuntimeError("В wc.ini отсутствует раздел [PLUGINS]")
    return ("\r".join(result) + "\r").encode("cp866", errors="replace")


def add_empty_short_entry(image: Fat32Image, directory_cluster: int, name: str) -> int:
    stem, ext = name.rsplit(".", 1)
    short_name = UPDATE.sanitize_short(stem, ext)
    entry = image.make_short_entry(short_name, ATTR_ARCHIVE, 0, 0)
    slot = image.find_free_dir_slots(directory_cluster, 1)
    image.write_dir_entries(directory_cluster, slot, [entry])
    return slot


# Codex - 2026-07-17 - begin
def prepare_image(
    base: Path,
    image_path: Path,
    exe_root: Path,
    plugin: Path,
    mode: str,
    left_driver: int | None = None,
    right_driver: int | None = None,
) -> None:
# Codex - 2026-07-17 - end
    if not base.is_file():
        raise FileNotFoundError(base)
    if not exe_root.is_dir():
        raise FileNotFoundError(exe_root)
    if not plugin.is_file():
        raise FileNotFoundError(plugin)
    image_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(base, image_path)

    image = Fat32Image(image_path)
    try:
# Codex - 2026-07-17 - begin
        # Пустой форматированный образ ещё не содержит wc.ini, тогда как общий
        # обновлятор сначала сливает его со старой копией. Создать минимальное
        # исходное дерево перед тем же штатным обновлением.
        wc_entry = image.find_entry(image.root_cluster, "WC")
        if not wc_entry:
            wc_cluster = UPDATE.ensure_dir(image, image.root_cluster, "WC")
            UPDATE.write_file_any(
                image,
                wc_cluster,
                "wc.ini",
                (exe_root / "WC" / "wc.ini").read_bytes(),
            )
# Codex - 2026-07-17 - end
        UPDATE.update_tree(image, exe_root)
        root = image.root_cluster
        if image.find_entry(root, TEST_DIRECTORY):
            raise RuntimeError(f"В исходном образе уже существует каталог {TEST_DIRECTORY}")

        wc_entry = image.find_entry(root, "WC")
        if not wc_entry or not (wc_entry["attr"] & ATTR_DIRECTORY):
            raise RuntimeError("В корне образа отсутствует каталог WC")
        wc_cluster = wc_entry["cluster"]
        UPDATE.write_file_any(image, wc_cluster, PLUGIN_NAME, plugin.read_bytes())
        wc_ini = image.read_file(wc_cluster, "wc.ini")
# Codex - 2026-07-17 - begin
        UPDATE.write_file_any(
            image,
            wc_cluster,
            "wc.ini",
            configure_ini(wc_ini, left_driver, right_driver),
        )
# Codex - 2026-07-17 - end

        test_cluster = UPDATE.ensure_dir(image, root, TEST_DIRECTORY)
        UPDATE.write_file_any(image, test_cluster, MAIN_RESULT, b"HOSTPREP" + bytes(504))
        main_result_entry = image.find_entry(test_cluster, MAIN_RESULT)
        if not main_result_entry:
            raise RuntimeError("Не удалось создать основной файл результата")
        image.set_fat(main_result_entry["cluster"], 0x0FFFFFF8)

        long_cluster = UPDATE.ensure_dir(image, test_cluster, LONG_DIRECTORY)
        UPDATE.write_file_any(image, long_cluster, LONG_RESULT, b"HOSTPREP" + bytes(504))
        long_result_entry = image.find_entry(long_cluster, LONG_RESULT)
        if not long_result_entry:
            raise RuntimeError("Не удалось создать файл результата длинного имени")
        image.set_fat(long_result_entry["cluster"], 0x0FFFFFFE)

        filler_slots = [
            add_empty_short_entry(image, long_cluster, f"F{i:02d}.BIN")
            for i in range(12)
        ]
        if filler_slots != list(range(3, 15)):
            raise RuntimeError(f"Неожиданное размещение заполнителей: {filler_slots}")

        # Каталог ровно на один кластер без свободной записи #00 проверяет
        # завершение SRHDRN по EOC, а не по маркеру внутри каталога.
        full_cluster = UPDATE.ensure_dir(image, test_cluster, FULL_DIRECTORY)
# Codex - 2026-07-17 - begin
        entries_per_cluster = image.cluster_size // 32
        full_slots = [
            add_empty_short_entry(image, full_cluster, f"Q{i:02d}.BIN")
            for i in range(entries_per_cluster - 2)
        ]
        if full_slots != list(range(2, entries_per_cluster)):
            raise RuntimeError(f"Неожиданное заполнение каталога EOC: {full_slots}")
# Codex - 2026-07-17 - end
        full_raw = image.read_chain(full_cluster)
        if len(full_raw) != image.spc * image.bps:
            raise RuntimeError("Каталог EOC неожиданно вышел за один кластер")
        if any(full_raw[offset] == 0 for offset in range(0, len(full_raw), 32)):
            raise RuntimeError("В полном каталоге EOC осталась запись #00")

        ext_flags = 0 if mode == "mirrored" else 0x0081
        put16(image.data, 40, ext_flags)
        first_free = next(
            cluster
            for cluster in range(2, (image.total_sectors - image.first_data_sector) // image.spc + 2)
            if image.get_fat(cluster) == 0
        )
        # Codex - 2026-07-16 - begin
        # Заведомо устаревшие значения обязаны быть заменены публичным RFRH:
        # Free_Count — на неизвестное, Next_Free — на безопасную подсказку.
        fsinfo_sector = le16(image.data, 48)
        fsinfo_offset = fsinfo_sector * image.bps
        put32(image.data, fsinfo_offset + 488, 0x12345678)
        put32(image.data, fsinfo_offset + 492, 0x12345678)
        # Codex - 2026-07-16 - end
        print(f"Образ: {image_path}")
        print(f"Режим FAT: {mode}, BPB_ExtFlags=#{ext_flags:04X}")
        print(f"Первый свободный кластер перед Unreal: {first_free}")
        print(f"Каталог длинного имени: кластер {long_cluster}, целевой начальный слот 15")
    finally:
        image.save()


def select_active_fat(image: Fat32Image) -> tuple[int, bool]:
    ext_flags = le16(image.data, 40)
    mirrored = (ext_flags & 0x0080) == 0
    active_fat = 0 if mirrored else ext_flags & 0x000F
    if active_fat >= image.fats:
        raise RuntimeError(f"Недопустимый номер активной FAT: {active_fat}")

    def active_get_fat(self, cluster: int) -> int:
        return le32(self.data, self.fat_offset(cluster, active_fat)) & 0x0FFFFFFF

    image.get_fat = types.MethodType(active_get_fat, image)
    return active_fat, mirrored


def result_fields(payload: bytes) -> tuple[bytes, int, int, int, int, int]:
    if len(payload) < 13:
        raise RuntimeError("Файл результата короче служебного заголовка")
    return payload[:8], payload[8], payload[9], payload[10], payload[11], payload[12]


def inspect_image(image_path: Path) -> int:
    failures: list[str] = []
    image = Fat32Image(image_path)
    try:
        # Codex - 2026-07-17 - begin
        # Запись по ошибочному LBA может незаметно расширить обычный файл
        # образа. BPB задаёт точную физическую границу проверяемого тома.
        expected_image_size = image.total_sectors * image.bps
        if len(image.data) != expected_image_size:
            failures.append(
                f"Размер образа {len(image.data)} байт, ожидалось {expected_image_size}"
            )
        # Codex - 2026-07-17 - end
        active_fat, mirrored = select_active_fat(image)
        root = image.root_cluster
        test_entry = image.find_entry(root, TEST_DIRECTORY)
        if not test_entry or not (test_entry["attr"] & ATTR_DIRECTORY):
            failures.append(f"Каталог {TEST_DIRECTORY} не найден")
            test_cluster = 0
        else:
            test_cluster = test_entry["cluster"]

        main_fields = None
        long_fields = None
        persistent_entries = []
        if test_cluster:
            try:
                main_fields = result_fields(image.read_file(test_cluster, MAIN_RESULT))
            except Exception as exc:
                failures.append(f"Основной результат не читается: {exc}")

            empty = image.find_entry(test_cluster, "EMPTY0.BIN")
            if not empty:
                failures.append("EMPTY0.BIN не создан")
            elif empty["size"] != 0 or empty["cluster"] != 0:
                failures.append(
                    f"EMPTY0.BIN имеет size={empty['size']} cluster={empty['cluster']}, ожидались нули"
                )

            for name in ("AB C.TXT", "   Leading Name.txt", "Plain Leading.txt"):
                entry = image.find_entry(test_cluster, name)
                if not entry:
                    failures.append(f"Не найден созданный объект {name!r}")
                    continue
                persistent_entries.append(entry)
                if entry["entries"] < 2:
                    failures.append(f"Имя {name!r} ошибочно сохранено без LFN")

            # Codex - 2026-07-16 - begin
            plain_entry = image.find_entry(test_cluster, "plain83.txt")
            if not plain_entry:
                failures.append("Не найден обычный объект 'plain83.txt'")
            else:
                persistent_entries.append(plain_entry)
                if plain_entry["entries"] != 1:
                    failures.append("Обычное имя plain83.txt ошибочно сохранено как LFN")
            # Codex - 2026-07-16 - end

            for name in ("IO512.BIN", "CROSSFAT.BIN"):
                if image.find_entry(test_cluster, name):
                    failures.append(f"Временный файл {name} не удалён")

            # Codex - 2026-07-17 - begin
            append_entry = image.find_entry(test_cluster, APPEND_FILE)
            if not append_entry:
                failures.append(f"Файл дописывания {APPEND_FILE} не создан")
            else:
                persistent_entries.append(append_entry)
                if append_entry["size"] != len(APPEND_PAYLOAD):
                    failures.append(
                        f"Размер {APPEND_FILE} равен {append_entry['size']}, "
                        f"ожидалось {len(APPEND_PAYLOAD)}"
                    )
                if append_entry["cluster"] < 2:
                    failures.append(f"У непустого {APPEND_FILE} отсутствует первый кластер")
                else:
                    chain = image.cluster_chain(append_entry["cluster"])
                    bytes_per_cluster = image.bps * image.spc
                    expected_clusters = (
                        len(APPEND_PAYLOAD) + bytes_per_cluster - 1
                    ) // bytes_per_cluster
                    if len(chain) != expected_clusters:
                        failures.append(
                            f"Цепочка {APPEND_FILE} содержит {len(chain)} кластеров, "
                            f"ожидалось {expected_clusters}"
                        )
                    try:
                        payload = image.read_file(test_cluster, APPEND_FILE)
                    except Exception as exc:
                        failures.append(f"Файл {APPEND_FILE} не читается: {exc}")
                    else:
                        if payload != APPEND_PAYLOAD:
                            mismatch = next(
                                (
                                    index
                                    for index, (actual, expected) in enumerate(
                                        zip(payload, APPEND_PAYLOAD)
                                    )
                                    if actual != expected
                                ),
                                min(len(payload), len(APPEND_PAYLOAD)),
                            )
                            failures.append(
                                f"Данные {APPEND_FILE} отличаются с позиции {mismatch}"
                            )
                        raw_tail = image.read_chain(append_entry["cluster"])[len(APPEND_PAYLOAD):]
                        if any(raw_tail):
                            failures.append(
                                f"Хвост последнего частичного сектора {APPEND_FILE} не обнулён"
                            )
            # Codex - 2026-07-17 - end

            long_dir_entry = image.find_entry(test_cluster, LONG_DIRECTORY)
            if not long_dir_entry or not (long_dir_entry["attr"] & ATTR_DIRECTORY):
                failures.append(f"Каталог {LONG_DIRECTORY} не найден")
            else:
                long_cluster = long_dir_entry["cluster"]
                chain = image.cluster_chain(long_cluster)
# Codex - 2026-07-17 - begin
                # Максимальный LFN обязан пересечь три сектора, но при SPC>1
                # эти сектора корректно находятся внутри одного кластера.
                if len(image.read_chain(long_cluster)) < 3 * image.bps:
                    failures.append("Каталог LFN короче трёх секторов")
# Codex - 2026-07-17 - end
                try:
                    long_fields = result_fields(image.read_file(long_cluster, LONG_RESULT))
                except Exception as exc:
                    failures.append(f"Результат LFN не читается: {exc}")
                raw = image.read_chain(long_cluster)
                if len(raw) < 36 * 32:
                    failures.append("Цепочка каталога LFN слишком короткая для проверки слотов")
                else:
                    wrong = [
                        slot for slot in range(15, 36)
                        if raw[slot * 32] != 0xE5
                    ]
                    if wrong:
                        failures.append(f"Не полностью удалены LFN/SFN-слоты: {wrong}")

            full_dir_entry = image.find_entry(test_cluster, FULL_DIRECTORY)
            if not full_dir_entry or not (full_dir_entry["attr"] & ATTR_DIRECTORY):
                failures.append(f"Каталог {FULL_DIRECTORY} не найден")
            else:
                full_cluster = full_dir_entry["cluster"]
                full_chain = image.cluster_chain(full_cluster)
                full_raw = image.read_chain(full_cluster)
                if len(full_chain) != 1:
                    failures.append(
                        f"Каталог EOC занимает {len(full_chain)} кластеров вместо одного"
                    )
                zero_slots = [
                    slot for slot in range(len(full_raw) // 32)
                    if full_raw[slot * 32] == 0
                ]
                if zero_slots:
                    failures.append(f"В полном каталоге EOC появились записи #00: {zero_slots}")

        if main_fields is not None:
            signature, status, failed_test, api_error, stage, completed = main_fields
            if signature != b"C32T2026":
                failures.append(f"Основной результат не перезаписан плагином: {signature!r}")
            # Codex - 2026-07-17 - begin
            if stage < 8:
            # Codex - 2026-07-17 - end
                failures.append(
                    f"Основной цикл остановился на stage={stage}, test={failed_test}, api=#{api_error:02X}"
                )
            # Codex - 2026-07-16 - begin
            # Codex - 2026-07-17 - begin
            if failed_test != 0 or api_error != 0 or completed != 8:
            # Codex - 2026-07-17 - end
                failures.append(
                    f"Основной набор CORE32 не прошёл: test={failed_test}, "
                    f"api=#{api_error:02X}, completed={completed}"
                )
            # Codex - 2026-07-16 - end
            print(
                f"Основной результат: status=#{status:02X} test={failed_test} "
                f"api=#{api_error:02X} stage={stage} completed={completed}"
            )

        if long_fields is not None:
            signature, status, failed_test, api_error, stage, completed = long_fields
            if signature != b"C32T2026":
                failures.append(f"LFN-результат не перезаписан плагином: {signature!r}")
            # Codex - 2026-07-16 - begin
            # Codex - 2026-07-17 - begin
            if status != 1 or failed_test != 0 or completed != 10:
            # Codex - 2026-07-17 - end
            # Codex - 2026-07-16 - end
                failures.append(
                    f"LFN-цикл не прошёл: status=#{status:02X}, test={failed_test}, "
                    f"api=#{api_error:02X}, stage={stage}, completed={completed}"
                )
            print(
                f"LFN-результат: status=#{status:02X} test={failed_test} "
                f"api=#{api_error:02X} stage={stage} completed={completed}"
            )

        fat_length = image.fat_size * image.bps
        fat0_off = image.fat_offset(0, 0)
        fat1_off = image.fat_offset(0, 1)
        fat0 = bytes(image.data[fat0_off:fat0_off + fat_length])
        fat1 = bytes(image.data[fat1_off:fat1_off + fat_length])
        if mirrored:
            if fat0 != fat1:
                failures.append("В режиме зеркалирования FAT0 и FAT1 различаются")
        else:
            if active_fat != 1:
                failures.append(f"Ожидалась активная FAT1, получена FAT{active_fat}")
            if fat0 == fat1:
                failures.append("В режиме active FAT1 обе таблицы неожиданно остались одинаковыми")
            for entry in persistent_entries:
                cluster = entry["cluster"]
                if cluster < 2:
                    continue
                active_value = le32(image.data, image.fat_offset(cluster, 1)) & 0x0FFFFFFF
                inactive_value = le32(image.data, image.fat_offset(cluster, 0)) & 0x0FFFFFFF
                if active_value == 0:
                    failures.append(f"Активная FAT1 не содержит кластер {cluster} файла {entry['name']!r}")
                if inactive_value != 0:
                    failures.append(
                        f"Неактивная FAT0 была изменена для кластера {cluster}: #{inactive_value:08X}"
                    )

        # Codex - 2026-07-16 - begin
        fsinfo_sector = le16(image.data, 48)
        fsinfo_offset = fsinfo_sector * image.bps
        free_count = le32(image.data, fsinfo_offset + 488)
        next_free = le32(image.data, fsinfo_offset + 492)
        max_cluster = (image.total_sectors - image.first_data_sector) // image.spc + 1
        if free_count != 0xFFFFFFFF:
            failures.append(f"FSI_Free_Count не сброшен: #{free_count:08X}")
        if next_free != 0xFFFFFFFF and not (2 <= next_free <= max_cluster):
            failures.append(f"FSI_Nxt_Free вне диапазона: #{next_free:08X}")
        if next_free == 0x12345678:
            failures.append("FSI_Nxt_Free сохранил подготовленное устаревшее значение")
        # Codex - 2026-07-16 - end

        print(f"Активная FAT: {active_fat}; зеркалирование: {'да' if mirrored else 'нет'}")
    finally:
        image.save()

    if failures:
        print("ПРОВАЛ:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("ПРОЙДЕНО: образ и результаты CORE32 согласованы")
    return 0


# Codex - 2026-07-17 - begin
def inspect_ui_image(image_path: Path, scenario: str) -> int:
    """Проверить штатные F5/F8 после остановки патченного Unreal."""
    failures: list[str] = []
    image = Fat32Image(image_path)
    try:
        root = image.root_cluster
        copied = image.find_entry(root, MAIN_RESULT)
        if not copied:
            failures.append(f"В корне не найден скопированный {MAIN_RESULT}")
        else:
            expected = b"HOSTPREP" + bytes(504)
            try:
                payload = image.read_file(root, MAIN_RESULT)
            except Exception as exc:
                failures.append(f"Скопированный {MAIN_RESULT} не читается: {exc}")
            else:
                if payload != expected:
                    failures.append(f"Данные скопированного {MAIN_RESULT} повреждены")

        if scenario == "sd":
            test_entry = image.find_entry(root, TEST_DIRECTORY)
            if not test_entry or not (test_entry["attr"] & ATTR_DIRECTORY):
                failures.append(f"Каталог {TEST_DIRECTORY} не найден")
            elif image.find_entry(test_entry["cluster"], MAIN_RESULT):
                failures.append(f"Исходный {TEST_DIRECTORY}/{MAIN_RESULT} не удалён F8")
        else:
            if image.find_entry(root, "NEMO.TXT"):
                failures.append("NEMO.TXT не удалён F8 на Nemo IDE")
            for name in ("README.TXT", "SUBDIR"):
                if not image.find_entry(root, name):
                    failures.append(f"Контрольный объект {name} исчез после операций Nemo IDE")

        fat_length = image.fat_size * image.bps
        fat0_offset = image.fat_offset(0, 0)
        fat1_offset = image.fat_offset(0, 1)
        if image.data[fat0_offset:fat0_offset + fat_length] != image.data[
            fat1_offset:fat1_offset + fat_length
        ]:
            failures.append("FAT0 и FAT1 различаются после штатных F5/F8")
    finally:
        image.save()

    if failures:
        print("ПРОВАЛ UI:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(f"ПРОЙДЕНО UI ({scenario}): F5/F8, данные и обе FAT согласованы")
    return 0
# Codex - 2026-07-17 - end


# Codex - 2026-07-17 - begin
def format_fat32_base(image_path: Path, total_sectors: int, spc: int) -> int:
    """Создать минимальный superfloppy FAT32 для проверки многосекторного кластера."""
    if spc not in (1, 2, 4, 8, 16, 32, 64, 128):
        raise ValueError("Число секторов на кластер должно быть степенью двойки 1..128")
    reserved = 32
    fats = 2
    fat_size = 1
    while True:
        clusters = (total_sectors - reserved - fats * fat_size) // spc
        required = ((clusters + 2) * 4 + 511) // 512
        if required == fat_size:
            break
        fat_size = required
    if clusters < 65525:
        raise ValueError(f"Для FAT32 недостаточно кластеров: {clusters}")

    image_path.parent.mkdir(parents=True, exist_ok=True)
    with image_path.open("wb") as stream:
        stream.truncate(total_sectors * 512)

    boot = bytearray(512)
    boot[0:3] = b"\xEB\x58\x90"
    boot[3:11] = b"WCSPC8  "
    put16(boot, 11, 512)
    boot[13] = spc
    put16(boot, 14, reserved)
    boot[16] = fats
    boot[21] = 0xF8
    put16(boot, 24, 63)
    put16(boot, 26, 255)
    put32(boot, 32, total_sectors)
    put32(boot, 36, fat_size)
    put32(boot, 44, 2)
    put16(boot, 48, 1)
    put16(boot, 50, 6)
    boot[64] = 0x80
    boot[66] = 0x29
    put32(boot, 67, 0x20260717)
    boot[71:82] = b"WC CORE32  "
    boot[82:90] = b"FAT32   "
    boot[510:512] = b"\x55\xAA"

    fsinfo = bytearray(512)
    put32(fsinfo, 0, 0x41615252)
    put32(fsinfo, 484, 0x61417272)
    put32(fsinfo, 488, clusters - 1)
    put32(fsinfo, 492, 3)
    put32(fsinfo, 508, 0xAA550000)

    fat_head = bytearray(512)
    put32(fat_head, 0, 0x0FFFFFF8)
    put32(fat_head, 4, 0xFFFFFFFF)
    put32(fat_head, 8, 0x0FFFFFFF)

    with image_path.open("r+b") as stream:
        stream.seek(0)
        stream.write(boot)
        stream.seek(512)
        stream.write(fsinfo)
        stream.seek(6 * 512)
        stream.write(boot)
        stream.seek(7 * 512)
        stream.write(fsinfo)
        for fat_index in range(fats):
            stream.seek((reserved + fat_index * fat_size) * 512)
            stream.write(fat_head)

    print(
        f"Создан FAT32: {image_path}, sectors={total_sectors}, "
        f"spc={spc}, clusters={clusters}, fatsz={fat_size}"
    )
    return 0
# Codex - 2026-07-17 - end


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--base", type=Path, required=True)
    prepare_parser.add_argument("--image", type=Path, required=True)
    prepare_parser.add_argument("--exe", type=Path, required=True)
    prepare_parser.add_argument("--plugin", type=Path, required=True)
    prepare_parser.add_argument("--mode", choices=("mirrored", "active1"), default="mirrored")
# Codex - 2026-07-17 - begin
    prepare_parser.add_argument("--left-driver", type=int, choices=range(7))
    prepare_parser.add_argument("--right-driver", type=int, choices=range(7))
# Codex - 2026-07-17 - end

    inspect_parser = subparsers.add_parser("inspect")
    inspect_parser.add_argument("--image", type=Path, required=True)

# Codex - 2026-07-17 - begin
    ui_parser = subparsers.add_parser("inspect-ui")
    ui_parser.add_argument("--image", type=Path, required=True)
    ui_parser.add_argument("--scenario", choices=("sd", "nemo"), required=True)

    format_parser = subparsers.add_parser("format-base")
    format_parser.add_argument("--image", type=Path, required=True)
    format_parser.add_argument("--total-sectors", type=int, default=600000)
    format_parser.add_argument("--spc", type=int, default=8)
# Codex - 2026-07-17 - end

    args = parser.parse_args()
# Codex - 2026-07-17 - begin
    if args.command == "format-base":
        return format_fat32_base(args.image, args.total_sectors, args.spc)
# Codex - 2026-07-17 - end
    if args.command == "prepare":
        prepare_image(
            args.base,
            args.image,
            args.exe,
            args.plugin,
            args.mode,
            args.left_driver,
            args.right_driver,
        )
        return 0
# Codex - 2026-07-17 - begin
    if args.command == "inspect-ui":
        return inspect_ui_image(args.image, args.scenario)
# Codex - 2026-07-17 - end
    return inspect_image(args.image)


if __name__ == "__main__":
    raise SystemExit(main())
# Codex - 2026-07-16 - end
