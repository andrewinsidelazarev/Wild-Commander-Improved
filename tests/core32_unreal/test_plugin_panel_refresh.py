"""Install the resident handler, overwrite the LOBU scratch page, and run both returns."""
from pathlib import Path
import re
import z80

import runtime_image

ROOT = Path(__file__).resolve().parents[2]
STACK = 0x5E00
STOP = 0xFF00


def run_until(cpu, address):
    cpu.set_breakpoint(address)
    for _ in range(100):
        cpu.ticks_to_stop = 100000
        event = cpu.run()
        if not event & 2:
            continue
        if cpu.pc == address:
            cpu.clear_breakpoint(address)
            return
        raise AssertionError(('Unexpected breakpoint', hex(cpu.pc)))
    raise AssertionError(('Execution did not terminate', hex(cpu.pc), hex(address)))


def installed_cpu(sym, boot):
    """Run the real boot installer and decompressor with a banked C000 window."""
    cpu = z80.Z80Machine()
    cpu.set_memory_block(0x6011, boot[17:])
    cpu.memory[0x5BF2:0x5C03] = bytes([0xA5]) * 17
    banks = {3: bytes(cpu.memory[0xC000:]), 0xE8: bytes([0xCC]) * 0x4000}
    mapped = [3]
    switches = []
    spi = []

    def input_port(port):
        assert port == 0x13AF, hex(port)
        return mapped[0]

    def output_port(port, value):
        # Установщик приводит шину SPI в покой (SpiBusIdle, см. test_spi_idle.py).
        if port in (0x0077, 0x0057):
            spi.append((port, value))
            return
        assert port == 0x13AF, hex(port)
        banks[mapped[0]] = bytes(cpu.memory[0xC000:])
        cpu.set_memory_block(0xC000, banks[value])
        mapped[0] = value
        switches.append(value)

    cpu.set_input_callback(input_port)
    cpu.set_output_callback(output_port)
    cpu.sp, cpu.pc, cpu.ix = 0x5FFC, sym['WDOS.INSTALL_WILDDOS'], 0x1234
    cpu.memory[cpu.sp:cpu.sp+2] = STOP.to_bytes(2, 'little')
    run_until(cpu, STOP)
    # Часть 1 расширения, возврат загрузочной страницы, часть 2 (с 2026-09-27).
    assert switches == [0xE8, 3, 0xE8, 3] and mapped[0] == 3
    assert spi == [(0x0077, 0x03)] + [(0x0057, 0xFF)] * 16 + [(0x0077, 0x03)], spi
    assert cpu.sp == 0x5FFE and cpu.ix == 0x1234
    raw_extension = (ROOT / 'Build/CORE32_EXT.bin').read_bytes()
    ext_sym = {m[1]: int(m[2], 16)
               for line in (ROOT / 'Build/CORE32_EXT.sym').read_text().splitlines()
               if (m := re.match(r'^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$', line))}
    core, page = runtime_image.expected_pages(boot, raw_extension, sym, ext_sym)
    assert banks[0xE8][:len(raw_extension)] == page
    assert bytes(cpu.memory[0x4000:0x5BF2]) == core
    template = sym['PLUGIN_REFRESH_TEMPLATE'] - 0x6000
    assert bytes(cpu.memory[0x5BF2:0x5BFA]) == boot[template:template+8]
    assert bytes(cpu.memory[0x5BFA:0x5C03]) == bytes([0xA5]) * 9
    return cpu


def overwrite_f9_buffer(cpu, sym):
    """Overwrite the whole LOBU scratch page, destroying the load-time template.

    Раньше сюда копировал 4 КиБ диалог F9 при записи wc.ini; теперь запись
    делает SETUP.WMF, а LOBU по-прежнему общий буфер просмотрщиков и файловых
    операций. Установленный обработчик не должен зависеть от шаблона в #BF60.
    """
    before = bytes(cpu.memory[0x5BF2:0x5C03])
    cpu.memory[0xB000:0xC000] = bytes([0x76]) * 0x1000
    assert bytes(cpu.memory[0x5BF2:0x5C03]) == before


def main():
    sym = {m[1]: int(m[2], 16) for line in (ROOT / 'Build/boot.sym').read_text().splitlines()
           if (m := re.match(r'^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$', line))}
    boot = (ROOT / 'exe/boot.$C').read_bytes()
    assert sym['PLUGIN_REFRESH_BOTH'] == sym['WDOS.END'] == 0x5BF2
    assert sym['PLUGIN_REFRESH_LENGTH'] == 8
    assert sym['PLUGIN_REFRESH_TEMPLATE'] == 0xBF60
    assert sym['AX_PATH'] == 0xBF69
    assert sym['INIT_RELOCATED'] == 0xBFD4
    # С 2026-09-27 за прежним концом лежит часть 2 расширения. Весь файл — не
    # длиннее 32768 байт (BIOS TS-Conf читает его целыми кластерами с #6000),
    # последний сектор Hobeta не добивается.
    # Код ядра — HR-потоком (с 2026-09-27): файл и короче прежних 124 секторов.
    assert 0x7000 <= len(boot) <= 0x8000 and len(boot) == 17 + sym['WDOS_BOOT_TAIL_END'] - 0x6011
    # С 2026-09-27 по #C00C — драйверы DR1..DR4 и DEHR ядра как есть, за ними
    # код ядра HR-потоком (прежние 17 байт по #DC00 ушли вместе с образом ядра).
    core = runtime_image.core_image()
    raw = sym['WDOS.DR1'] - 0x4000
    assert boot[sym['WDOS.CORE32']-0x6000:][:len(core) - raw] == core[raw:]
    sites = (sym['WCVW.TOAJT']+5, sym['WCVW.Pf']+3)
    for site in sites:
        offset = site - 0x6000
        assert boot[offset:offset+5] == b'\xFE\x03\xCC\xF2\x5B'
        for panel, other in ((0x7EA0, 0x7EC4), (0x7EC4, 0x7EA0)):
            for result in (0, 1, 2, 3, 4):
                cpu = installed_cpu(sym, boot)
                # Repeated LOBU overwrites must not damage the installed code. Even
                # replacing its old BF60 source with HALT cannot affect return.
                for _ in range(3):
                    overwrite_f9_buffer(cpu, sym)
                cpu.pc, cpu.sp, cpu.ix, cpu.a = site, STACK, panel, result
                cpu.memory[STACK:STACK+2] = STOP.to_bytes(2, 'little')
                # Stop after the tested return handling, before Pf's EI/HALT.
                cpu.memory[site+5] = 0xC9
                # Device/drawing stubs record (operation, IX) in RAM. The
                # wrapper, SEXY, TERM, SWPPAND, SWPPAN and PANELI run unchanged.
                for address, tag in ((0x4021, 1), (sym['FOLD'], 2), (sym['DRACT'], 3)):
                    stub = bytes((0x2A, 0x00, 0xF0, 0x36, tag, 0x23,
                                  0xDD, 0xE5, 0xD1, 0x73, 0x23, 0x72, 0x23,
                                  0x22, 0x00, 0xF0, 0x3E, 0x77, 0x37, 0xC9))
                    cpu.set_memory_block(address, stub)
                cpu.memory[0xF000:0xF002] = b'\x00\xF1'
                run_until(cpu, STOP)
                end = cpu.memory[0xF000] | cpu.memory[0xF001] << 8
                names = {1: 'cwd', 2: 'read', 3: 'drive'}
                trace = [(names[cpu.memory[p]], cpu.memory[p+1] | cpu.memory[p+2] << 8)
                         for p in range(0xF100, end, 3)]
                expected = [('cwd', panel), ('read', panel), ('drive', other),
                            ('cwd', other), ('read', other), ('drive', panel)]
                assert trace == (expected if result == 3 else []), (site, result, trace)
                assert cpu.ix == panel and cpu.sp == STACK+2
                if result == 3:
                    assert cpu.a == 0 and cpu.f & 64 and not cpu.f & 1
    print('Plugin panel refresh PASS: real boot install/decompression, IM2 guard, '
          'three LOBU overwrites, both entry paths, either active panel, '
          'code 3 reads both, other codes unchanged, IX/stack/flags restored')


if __name__ == '__main__':
    main()
