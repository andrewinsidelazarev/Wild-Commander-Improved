"""Run both built plugin-return paths and the real panel-switching wrapper."""
from pathlib import Path
import re
import z80

ROOT = Path(__file__).resolve().parents[2]
STACK = 0x5E00
STOP = 0xFF00


def main():
    sym = {m[1]: int(m[2], 16) for line in (ROOT / 'Build/boot.sym').read_text().splitlines()
           if (m := re.match(r'^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$', line))}
    boot = (ROOT / 'exe/boot.$C').read_bytes()
    assert sym['PLUGIN_REFRESH_BOTH'] == 0xBF60
    assert sym['AX_PATH'] == 0xBF69
    sites = (sym['WCVW.TOAJT']+5, sym['WCVW.Pf']+3)
    for site in sites:
        offset = site - 0x6000
        assert boot[offset:offset+5] == b'\xFE\x03\xCC\x60\xBF'
        for panel, other in ((0x7EA0, 0x7EC4), (0x7EC4, 0x7EA0)):
            for result in (0, 1, 2, 3, 4):
                cpu = z80.Z80Machine()
                cpu.set_memory_block(0x6011, boot[17:])
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
                cpu.set_breakpoint(STOP)
                for _ in range(100):
                    cpu.ticks_to_stop = 100000
                    event = cpu.run()
                    if not event & 2:
                        continue
                    if cpu.pc == STOP:
                        break
                    raise AssertionError(('Unexpected breakpoint', hex(cpu.pc)))
                else:
                    raise AssertionError('Plugin return did not terminate')
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
    print('Plugin panel refresh PASS: both entry paths, either active panel, '
          'code 3 reads both, other codes unchanged, IX/stack/flags restored')


if __name__ == '__main__':
    main()
