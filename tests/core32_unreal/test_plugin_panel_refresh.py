"""Install the resident handler, overwrite F9 scratch RAM, and run both returns."""
from pathlib import Path
import re
import z80

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

    def input_port(port):
        assert port == 0x13AF, hex(port)
        return mapped[0]

    def output_port(port, value):
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
    assert switches == [0xE8, 3] and mapped[0] == 3
    assert cpu.sp == 0x5FFE and cpu.ix == 0x1234
    raw_extension = (ROOT / 'Build/CORE32_EXT.bin').read_bytes()
    assert banks[0xE8][:len(raw_extension)] == raw_extension
    core_offset = sym['WDOS.CORE32'] - 0x6000
    core_length = sym['WDOS.END'] - 0x4000
    assert bytes(cpu.memory[0x4000:0x5BF2]) == boot[core_offset:core_offset+core_length]
    template = sym['PLUGIN_REFRESH_TEMPLATE'] - 0x6000
    assert bytes(cpu.memory[0x5BF2:0x5BFA]) == boot[template:template+8]
    assert bytes(cpu.memory[0x5BFA:0x5C03]) == bytes([0xA5]) * 9
    return cpu


def overwrite_f9_buffer(cpu, sym):
    """Execute F9's actual 4-KiB copy, destroying the entire load-time template."""
    before = bytes(cpu.memory[0x5BF2:0x5C03])
    cpu.memory[0x1000:0x2000] = bytes([0x76]) * 0x1000
    cpu.pc = sym['WCINI.JI']
    # Stop after the following LD HL,SFINI. python-z80 also checks a breakpoint
    # directly after LDIR on intermediate iterations, before rewinding PC.
    run_until(cpu, sym['WCINI.JI'] + 14)
    assert bytes(cpu.memory[0xB000:0xC000]) == bytes([0x76]) * 0x1000
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
    assert len(boot) == 31761
    assert boot[0xDC00-0x6000:] == bytes.fromhex('210cc011004001c71bedb0c9c36243c303')
    sites = (sym['WCVW.TOAJT']+5, sym['WCVW.Pf']+3)
    for site in sites:
        offset = site - 0x6000
        assert boot[offset:offset+5] == b'\xFE\x03\xCC\xF2\x5B'
        for panel, other in ((0x7EA0, 0x7EC4), (0x7EC4, 0x7EA0)):
            for result in (0, 1, 2, 3, 4):
                cpu = installed_cpu(sym, boot)
                # Repeated F9 copies must not damage the installed code. Even
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
    # F9 also recreates wc.ini and invalidates its cached directory entry.
    # Execute the actual dialog-exit code with its real saved-IX stack frame.
    for panel, other in ((0x7EA0, 0x7EC4), (0x7EC4, 0x7EA0)):
        cpu = installed_cpu(sym, boot)
        overwrite_f9_buffer(cpu, sym)
        cpu.pc, cpu.sp, cpu.ix = sym['WCINI.STPE'], STACK, sym['WCINI.F9WND']
        cpu.memory[STACK:STACK+4] = panel.to_bytes(2, 'little') + STOP.to_bytes(2, 'little')
        for address, tag in ((0x4021, 1), (sym['FOLD'], 2), (sym['DRACT'], 3),
                             (sym['WCINI.RRESB'], 4)):
            cpu.set_memory_block(address, bytes((
                0x2A, 0x00, 0xF0, 0x36, tag, 0x23,
                0xDD, 0xE5, 0xD1, 0x73, 0x23, 0x72, 0x23,
                0x22, 0x00, 0xF0, 0x3E, 0x77, 0x37, 0xC9)))
        cpu.memory[0xF000:0xF002] = b'\x00\xF1'
        run_until(cpu, STOP)
        end = int.from_bytes(cpu.memory[0xF000:0xF002], 'little')
        trace = [(cpu.memory[p], int.from_bytes(cpu.memory[p+1:p+3], 'little'))
                 for p in range(0xF100, end, 3)]
        assert trace == [(4, sym['WCINI.F9WN2']), (4, sym['WCINI.F9WND']),
                         (1, panel), (2, panel), (3, other),
                         (1, other), (2, other), (3, panel)]
        assert cpu.ix == panel and cpu.sp == STACK+4
    print('Plugin panel refresh PASS: real boot install/decompression, IM2 guard, '
          'three real F9 buffer overwrites, both entry paths, either active panel, '
          'code 3 reads both, other codes unchanged, F9 dialog exit refreshes both, '
          'IX/stack/flags restored')


if __name__ == '__main__':
    main()
