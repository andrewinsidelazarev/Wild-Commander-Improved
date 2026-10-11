# Claude - 2026-10-10 - begin
"""Оверлей расширения ядра в FILEX.WMF (2026-10-10).

Холодная часть CORE32_EXT (запись, APPEND, псевдонимы, часы, строка
состояния) в boot.$C не входит: её байты везёт FILEX.WMF, а его установщик
(ранняя установка, по #8000) кладёт их в страницу #E8 по OVERLAY_START, если
штамп сборки EXT_STAMP в #E8 совпал со своим. Исполняется настоящий код
FILEX.WMF; страницы окна #C000 — по порту #13AF, как в TS-Conf.
"""
from pathlib import Path
import re
import unittest

import z80

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build'
STOP, STACK = 0x5C80, 0x5D80
FILEX_PAGE, OTHER_PAGE, EXT_PAGE = 0x61, 0x03, 0xE8
HALT = 0x76


def symbols(name):
    return {m[1]: int(m[2], 16) for line in (BUILD / name).read_text(encoding='utf-8').splitlines()
            if (m := re.match(r'^([^:]+):\s+EQU\s+0x([0-9A-Fa-f]+)$', line))}


EXT = symbols('CORE32_EXT.sym')
FX = symbols('FILEX.sym')


def iff(cpu, enabled=None):
    if enabled is not None:
        cpu._Z80State__iff1[0] = cpu._Z80State__iff2[0] = int(enabled)
    return bool(cpu._Z80State__iff1[0])


class Stand:
    """#E8 — как после установщика boot.$C: загрузочная часть, на месте
    оверлея HALT. FILEX — в окне #8000, в окне #C000 — посторонняя страница."""

    def __init__(self, interrupts=True):
        self.cpu = z80.Z80Machine()
        boot = (BUILD / 'CORE32_EXT_BOOT.bin').read_bytes()
        e8 = bytearray(0x4000)
        e8[:len(boot)] = boot
        start, end = EXT['WDOS_EXT.OVERLAY_START'] - 0xC000, EXT['WDOS_EXT.OVERLAY_END'] - 0xC000
        e8[start:end] = bytes([HALT]) * (end - start)
        other = bytearray(range(256)) * 64
        self.banks = {EXT_PAGE: e8, OTHER_PAGE: other}
        self.mapped = OTHER_PAGE
        self.cpu.memory[0xC000:] = other
        filex = (BUILD / 'FILEX.WMF').read_bytes()[512:]
        self.cpu.memory[0x8000:0x8000 + len(filex)] = filex
        self.cpu.memory[0x6002] = FILEX_PAGE
        self.cpu.memory[EXT['WDOS_EXT.OVERLAY_STATE']] = 0
        self.cpu.set_output_callback(self.out)
        self.cpu.set_input_callback(lambda port: self.mapped if port == 0x13AF else 0xFF)
        iff(self.cpu, interrupts)

    def out(self, port, value):
        if port == 0x13AF:
            self.banks[self.mapped] = bytearray(self.cpu.memory[0xC000:])
            self.cpu.memory[0xC000:] = self.banks.setdefault(value, bytearray(0x4000))
            self.mapped = value

    def page(self, number):
        if number == self.mapped:
            return bytes(self.cpu.memory[0xC000:])
        return bytes(self.banks[number])

    def install(self, a=0x07):
        c = self.cpu
        c.pc, c.sp, c.a = 0x8000, STACK, a                # FILEX_INSTALL по #8000
        c.memory[STACK:STACK + 2] = STOP.to_bytes(2, 'little')
        c.set_breakpoint(STOP)
        for _ in range(50):                               # LDIR оверлея — не в один заход
            c.ticks_to_stop = 2000000
            if c.run() & 2 and c.pc == STOP:
                break
        c.clear_breakpoint(STOP)
        assert c.pc == STOP, hex(c.pc)
        return c.a


class Overlay(unittest.TestCase):

    def test_header_asks_for_early_install(self):
        header = (BUILD / 'FILEX.WMF').read_bytes()[:512]
        self.assertEqual(header[33] & 1, 1, '+33 bit 0 — ранняя установка')
        self.assertEqual(header[197], 0x06)

    def test_filex_carries_this_build(self):
        wmf = (BUILD / 'FILEX.WMF').read_bytes()
        overlay = (BUILD / 'CORE32_EXT_OVL.bin').read_bytes()
        at = 512 + FX['FILEX_OVERLAY_IMAGE'] - 0xC000
        self.assertEqual(wmf[at:at + len(overlay)], overlay)
        stamp_at = EXT['WDOS_EXT.EXT_STAMP'] - 0xC000
        boot = (BUILD / 'CORE32_EXT_BOOT.bin').read_bytes()
        mine = 512 + FX['FILEX_EXT_STAMP'] - 0xC000
        self.assertEqual(wmf[mine:mine + 4], boot[stamp_at:stamp_at + 4])
        self.assertNotEqual(boot[stamp_at:stamp_at + 4], bytes(4))

    def test_installs_overlay_and_registers(self):
        s = Stand()
        self.assertEqual(s.install(), 0)
        installed = (BUILD / 'CORE32_EXT.bin').read_bytes()
        end = EXT['WDOS_EXT.OVERLAY_END'] - 0xC000
        self.assertEqual(s.page(EXT_PAGE)[:end], installed[:end], '#E8 = страница с оверлеем')
        self.assertEqual(s.cpu.memory[EXT['WDOS_EXT.OVERLAY_STATE']], 1)
        self.assertEqual(s.cpu.memory[FX['FILEX_PROVIDER_PAGE_ADDR']], FILEX_PAGE)
        self.assertEqual(s.mapped, OTHER_PAGE, 'окно #C000 возвращено')
        self.assertTrue(iff(s.cpu), 'прерывания вызывающего снова разрешены')

    def test_keeps_interrupts_disabled(self):
        s = Stand(interrupts=False)
        s.install()
        self.assertEqual(s.cpu.memory[EXT['WDOS_EXT.OVERLAY_STATE']], 1)
        self.assertFalse(iff(s.cpu))

    def test_second_call_does_not_copy_again(self):
        # AX_RUN зовёт FILEX ещё раз (A=#06): оверлей уже стоит.
        s = Stand()
        s.install()
        start = EXT['WDOS_EXT.OVERLAY_START'] - 0xC000
        e8 = bytearray(s.page(EXT_PAGE))
        e8[start] ^= 0xFF                                   # метка: копии не было
        s.banks[EXT_PAGE] = e8
        s.install(a=0x06)
        self.assertEqual(s.page(EXT_PAGE)[start], e8[start])
        self.assertEqual(s.cpu.memory[FX['FILEX_PROVIDER_PAGE_ADDR']], FILEX_PAGE)
        self.assertEqual(s.mapped, OTHER_PAGE)

    def test_foreign_build_is_not_installed(self):
        # boot.$C другой сборки: штамп не совпал — оверлей не ставится,
        # OVERLAY_STATE=2, на его месте по-прежнему HALT.
        s = Stand()
        stamp = EXT['WDOS_EXT.EXT_STAMP'] - 0xC000
        s.banks[EXT_PAGE][stamp] ^= 0x01
        s.install()
        self.assertEqual(s.cpu.memory[EXT['WDOS_EXT.OVERLAY_STATE']], 2)
        start, end = EXT['WDOS_EXT.OVERLAY_START'] - 0xC000, EXT['WDOS_EXT.OVERLAY_END'] - 0xC000
        self.assertEqual(set(s.page(EXT_PAGE)[start:end]), {HALT})
        self.assertEqual(s.mapped, OTHER_PAGE)
        self.assertTrue(iff(s.cpu))

    def test_boot_part_does_not_reach_the_overlay(self):
        # Загрузочная часть (то, что есть до FILEX) не прыгает в оверлей из
        # таблицы входов функций, нужных старту: монтирование, чтение
        # каталогов и файлов, драйверы. Их строки JP ведут ниже OVERLAY_START.
        boot = (BUILD / 'CORE32_EXT_BOOT.bin').read_bytes()
        start, end = EXT['WDOS_EXT.OVERLAY_START'], EXT['WDOS_EXT.OVERLAY_END']
        api = (ROOT / 'source/CORE32_EXT_API.ASM').read_text(encoding='utf-8')
        ids = {m[1]: int(m[2]) for m in re.finditer(r'^ID_([A-Z0-9_]+)\s+EQU\s+(\d+)', api, re.M)}
        startup = ['STREAM_WITH_HANDLER', 'READ_SECTORS', 'STREAM_IO_ERROR', 'POSITION_FAT_READ',
                   'FAT_SECTOR_IN_RANGE', 'CLASSIFY_FAT_LINK', 'FAT_LINK_ERROR',
                   'REFINE_NAME_CLASSIFICATION', 'IS_EOC_BEFORE_HL', 'RESET_DIR_HISTORY',
                   'SAVE_PREVIOUS_DIR_LBA', 'PRESERVE_OLDER_DIR_SECTOR', 'BEGIN_LFN_COMPARE',
                   'COMPARE_LFN_CHAR', 'RFRH_SAFE', 'RECORD_FAT_LINK_ERROR', 'LOAD_FAT_CONFIG',
                   'VALIDATE_NAME', 'MAP_OLDER_LFN_POINTER', 'UNPACK_DRIVER', 'COPY_ENTRY_AND_CAPTURE',
                   'LOAD_FREE_HINT', 'GET_DATA_CLUSTER_LIMIT', 'STREAM_NEXT_CLUSTER', 'STREAM_LINK',
                   'DIR_LIST_OPEN', 'DIR_STREAM_OPEN', 'CLASSIFY_DATA', 'INSTALL_TAIL',
                   # Чтение для раннего плагина выше FILEX: список (NXTETY2 → CHECK_STAMP)
                   # и открытие файла (GFILE → GIPAG_FILE → FILE_START_CHECK).
                   'CHECK_STAMP', 'FILE_START_CHECK']
        for name in startup:
            row = ids[name] * 3
            self.assertEqual(boot[row], 0xC3, name)
            target = int.from_bytes(boot[row + 1:row + 3], 'little')
            self.assertFalse(start <= target < end, f'{name} -> #{target:04X} в оверлее')


class BootPage(unittest.TestCase):
    """Старт до FILEX: страница #E8 — загрузочная часть, на месте оверлея HALT.
    Поиск каталога wc (FINI → LINI → FNDSN → DIR_STREAM_OPEN → DIR_CHAIN) и
    захват найденной записи (TENTRY → COPY_ENTRY_AND_CAPTURE) не заходят в
    оверлей. Стенд unreal-ng 2026-10-10: DIR_CHAIN звал TREE_CHILD_ENTRY.root
    из оверлея, и старт вставал на HALT."""

    def harness(self):
        import runtime_image
        import test_lfn_namespace as ns
        directory = (ns.long_entry('Wild folder', b'WILDFO~1   ', 0x10)
                     + ns.entry(b'WC         ', 0x10) + ns.entry(b'BOOT    $C ', 0x20))
        h = ns.Harness(directory)
        boot = runtime_image.boot_extension()
        h.ram[0xC000:0xC000 + len(boot)] = boot
        start, end = EXT['WDOS_EXT.OVERLAY_START'], EXT['WDOS_EXT.OVERLAY_END']
        h.ram[start:end] = bytes([HALT]) * (end - start)
        h.ram[EXT['WDOS_EXT.OVERLAY_STATE']] = 0
        for address in range(start, end):                 # вход в оверлей — стоп
            h.cpu.set_breakpoint(address)
        return h

    def test_folder_search_stays_out_of_the_overlay(self):
        import test_lfn_namespace as ns
        h = self.harness()
        self.assertTrue(ns.found(h.find('wc', 0x10)), 'каталог wc не найден')
        h = self.harness()
        self.assertTrue(ns.found(h.find('Wild folder', 0x10)))
        h.invoke('TENTRY', de=0x9000)
        self.assertEqual(bytes(h.ram[0x9000:0x900B]), b'WILDFO~1   ')


if __name__ == '__main__':
    unittest.main(verbosity=2)
# Claude - 2026-10-10 - end
