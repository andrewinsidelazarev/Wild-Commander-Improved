# Claude - 2026-09-27 - begin
"""Страницы после установщика boot.$C: ядро (#4000..END) и расширение (#E8).

С 2026-09-27 установщик, распаковав обе части расширения, переносит
упакованные драйверы ядра (#5176..#5AA9) в DRIVERS_E8 страницы #E8, а на их
место в странице #05 кладёт резидентный блок расширения (CORE_MKSG,
CORE_SRHFCL и их выход из #E8). Стенды, которые ставят ядро и расширение сразу
в память, а не исполняют установщик, делают то же через apply(): иначе в
ядре нет резидентного блока. У прежних сборок (нет RESIDENT_SOURCE) — ничего.
"""


def apply(memory, ext_symbols, extension=None):
    """memory — 64 КиБ: ядро с #4000 как в файле. Если в окне #C000 само
    расширение, extension не нужен: драйверы переносятся в его DRIVERS_E8.
    Иначе (там, например, FILEX) блок берётся из байтов extension, а драйверы
    остаются на месте."""
    source = ext_symbols.get('WDOS_EXT.RESIDENT_SOURCE')
    if source is None:
        return
    base = ext_symbols['WDOS_EXT.RESIDENT_BASE']
    length = ext_symbols['WDOS_EXT.RESIDENT_LENGTH']
    if extension is None:
        drivers = ext_symbols['WDOS_EXT.DRIVERS_E8']
        count = ext_symbols['WDOS_EXT.DRIVERS_LENGTH']
        memory[drivers:drivers + count] = bytes(memory[base:base + count])
        blob = bytes(memory[source:source + length])
    else:
        blob = bytes(extension[source - 0xC000:source - 0xC000 + length])
    memory[base:base + length] = blob


def core_image():
    """Рабочий образ ядра #4000..END. С 2026-09-27 в boot.$C код ядра лежит
    HR-потоком, поэтому образ — отдельным файлом сборки (из символического
    прохода, где CORE32 лежит как есть)."""
    from pathlib import Path
    return (Path(__file__).resolve().parents[2] / 'Build/CORE32_RUNTIME.bin').read_bytes()


def expected_pages(boot, extension, boot_symbols, ext_symbols):
    """Ожидаемые байты ядра (#4000..END) и начала #E8 (длина extension)."""
    length = boot_symbols['WDOS.END'] - 0x4000
    core = core_image()
    assert len(core) == length, (len(core), length)
    memory = bytearray(0x10000)
    memory[0x4000:0x4000 + length] = core
    memory[0xC000:0xC000 + len(extension)] = extension
    apply(memory, ext_symbols)
    return bytes(memory[0x4000:0x4000 + length]), bytes(memory[0xC000:0xC000 + len(extension)])
# Claude - 2026-09-27 - end
