# Claude - 2026-09-27 - begin
"""Страницы после установщика boot.$C: ядро (#4000..END) и расширение (#E8).

С 2026-09-27 установщик, распаковав обе части расширения, переносит
упакованные драйверы ядра (#5176..#5AA9) в DRIVERS_E8 страницы #E8, а на их
место в странице #05 кладёт резидентный блок расширения (CORE_MKSG,
CORE_SRHFCL и их выход из #E8). Стенды, которые ставят ядро и расширение сразу
в память, а не исполняют установщик, делают то же через apply(): иначе в
ядре нет резидентного блока. У прежних сборок (нет RESIDENT_SOURCE) — ничего.
"""
# Claude - 2026-09-27 - end
# Claude - 2026-10-10 - begin
# С 2026-10-10 холодная часть расширения — оверлей FILEX (OVERLAY_START):
# Build/CORE32_EXT.bin — страница после установки оверлея, загрузочная часть
# (её распаковывает установщик boot.$C) — Build/CORE32_EXT_BOOT.bin. Исходники
# резидентных блоков и образ WMF лежат в одноразовой зоне за RUNTIME_END, на
# месте которой в CORE32_EXT.bin уже оверлей, — их apply() берёт из
# загрузочной части. OVERLAY_STATE=1 (FILEX поставил оверлей), если не сказано
# filex=False.
# Claude - 2026-10-10 - end
from pathlib import Path

BUILD = Path(__file__).resolve().parents[2] / 'Build'
HALT = 0x76


def boot_extension():
    """Загрузочная часть расширения (без оверлея FILEX)."""
    return (BUILD / 'CORE32_EXT_BOOT.bin').read_bytes()


def apply(memory, ext_symbols, extension=None, *, boot=None, filex=True):
    """memory — 64 КиБ: ядро с #4000 как в файле. Если в окне #C000 само
    расширение, extension не нужен: драйверы переносятся в его DRIVERS_E8.
    Иначе (там, например, FILEX) блок берётся из байтов extension, а драйверы
    остаются на месте. boot — загрузочная часть (по умолчанию из Build)."""
    source = ext_symbols.get('WDOS_EXT.RESIDENT_SOURCE')
    if source is None:
        return
    overlay = 'WDOS_EXT.OVERLAY_START' in ext_symbols
    if overlay:
        image = boot if boot is not None else boot_extension()

        def take(address, count):
            return bytes(image[address - 0xC000:address - 0xC000 + count])
    elif extension is None:
        def take(address, count):
            return bytes(memory[address:address + count])
    else:
        def take(address, count):
            return bytes(extension[address - 0xC000:address - 0xC000 + count])
    base = ext_symbols['WDOS_EXT.RESIDENT_BASE']
    length = ext_symbols['WDOS_EXT.RESIDENT_LENGTH']
    if extension is None:
        drivers = ext_symbols['WDOS_EXT.DRIVERS_E8']
        count = ext_symbols['WDOS_EXT.DRIVERS_LENGTH']
        memory[drivers:drivers + count] = bytes(memory[base:base + count])
    memory[base:base + length] = take(source, length)
    source2 = ext_symbols.get('WDOS_EXT.RESIDENT2_SOURCE')
    if source2 is not None:
        base2 = ext_symbols['WDOS_EXT.RESIDENT2_BASE']
        length2 = ext_symbols['WDOS_EXT.RESIDENT2_LENGTH']
        memory[base2:base2 + length2] = take(source2, length2)
    # Одноразовый хвост расширения переносится из будущей BSS в резидент.
    wmf_source = ext_symbols.get('WDOS_EXT.WMF_INSTALL_SOURCE')
    if wmf_source is not None:
        count = ext_symbols['WDOS_EXT.WMF_INSTALL_LENGTH']
        memory[0x5300:0x5300 + count] = take(wmf_source, count)
    if overlay:
        memory[ext_symbols['WDOS_EXT.OVERLAY_STATE']] = 1 if filex else 0


def core_image():
    """Рабочий образ ядра #4000..END. С 2026-09-27 в boot.$C код ядра лежит
    HR-потоком, поэтому образ — отдельным файлом сборки (из символического
    прохода, где CORE32 лежит как есть)."""
    return (BUILD / 'CORE32_RUNTIME.bin').read_bytes()


def expected_pages(boot, extension, boot_symbols, ext_symbols):
    """Ожидаемые байты ядра (#4000..END) и начала #E8 после установщика
    boot.$C. С оверлеем FILEX extension не нужен: в #E8 — загрузочная часть,
    на месте оверлея — HALT (EXT_INSTALL_TAIL), длина — до OVERLAY_END."""
    length = boot_symbols['WDOS.END'] - 0x4000
    core = core_image()
    assert len(core) == length, (len(core), length)
    memory = bytearray(0x10000)
    memory[0x4000:0x4000 + length] = core
    if 'WDOS_EXT.OVERLAY_START' in ext_symbols:
        image = boot_extension()
        memory[0xC000:0xC000 + len(image)] = image
        apply(memory, ext_symbols, filex=False)
        start = ext_symbols['WDOS_EXT.OVERLAY_START']
        end = ext_symbols['WDOS_EXT.OVERLAY_END']
        memory[start:end] = bytes([HALT]) * (end - start)
        top = max(0xC000 + len(image), end)
    else:
        memory[0xC000:0xC000 + len(extension)] = extension
        apply(memory, ext_symbols)
        top = 0xC000 + len(extension)
    return bytes(memory[0x4000:0x4000 + length]), bytes(memory[0xC000:top])
