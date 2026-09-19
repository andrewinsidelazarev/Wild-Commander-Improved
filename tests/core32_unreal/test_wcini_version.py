"""Execute INI load/merge/create paths and verify version compatibility."""
from pathlib import Path
import re
import z80

ROOT = Path(__file__).resolve().parents[2]
STOP = 0xFF00
CURRENT = b'Wild Commander v1.10i'


def invoke(cpu, address, data=None):
    cpu.pc, cpu.sp = address, 0x5FFC
    cpu.memory[0x5FFC:0x5FFE] = STOP.to_bytes(2, 'little')
    cpu.set_breakpoint(STOP)
    if data is not None:
        cpu.set_breakpoint(0x4015)
    offset = 0
    for _ in range(100):
        cpu.ticks_to_stop = 100000
        event = cpu.run()
        if not event & 2:
            continue
        if cpu.pc == STOP:
            cpu.clear_breakpoint(STOP)
            if data is not None:
                cpu.clear_breakpoint(0x4015)
            assert cpu.sp == 0x5FFE
            return
        assert cpu.pc == 0x4015 and data is not None, hex(cpu.pc)
        assert cpu.b == 1, 'INILOAD must request one sector'
        cpu.set_memory_block(cpu.hl, data[offset:offset+512].ljust(512, b'\0'))
        offset += 512
        cpu.a, cpu.f = 1, 0
        cpu.pc = int.from_bytes(cpu.memory[cpu.sp:cpu.sp+2], 'little')
        cpu.sp += 2
    raise AssertionError(('INI did not return', hex(cpu.pc)))


def machine():
    cpu = z80.Z80Machine()
    cpu.set_memory_block(0x6011, (ROOT / 'Build/boot.payload.bin').read_bytes())
    return cpu


def main():
    syms = {m[1]: int(m[2], 16) for line in (ROOT / 'Build/boot.sym').read_text().splitlines()
            if (m := re.match(r'^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$', line))}
    plugin_lines = b'[PLUGINS]\rFILEX.WMF\rTXTEDIT.WMF -highlight=auto\r'
    # Comments force multiple actual LOAD512 calls and exercise the loader's
    # sector boundaries while the merge must preserve plugin arguments.
    body = (b'\r\r[SETUP]\rCPU_FREQ=2\r' + b';long comment\r' * 95
            + plugin_lines + b'\r[LPANEL]\rDRV=1\r\r[RPANEL]\rDRV=1\r')
    for header in (b'Wild Commander v1.1', CURRENT):
        cpu = machine()
        invoke(cpu, syms['WCINI.INILOAD'], header + body)
        assert cpu.f & 64, ('Compatible INI rejected', header)
        normalized = bytes(cpu.memory[:0x1000]).split(b'\0')[0]
        assert plugin_lines in normalized and b'long comment' not in normalized
        assert normalized.lstrip(b'\r').startswith(b'[SETUP]\r'), normalized[:32]
        cpu.a = 0  # Existing, valid INI: preserve its PLUGINS section.
        invoke(cpu, syms['WCINI.GINI'])
        n = int.from_bytes(cpu.memory[syms['WCINI.SFIS']:syms['WCINI.SFIS']+2], 'little')
        saved = bytes(cpu.memory[0x1000:0x1000+n])
        assert saved.startswith(CURRENT + b'\r\r[SETUP]\r'), saved[:40]
        assert saved.endswith(b'\r') and b'\0' not in saved, saved[-32:]
        assert cpu.memory[0x1000+n] == 0, 'RAM terminator must remain outside file size'
        assert plugin_lines in saved
        assert b'[LPANEL]\r' in saved and b'[RPANEL]\r' in saved
        reader = machine()
        invoke(reader, syms['WCINI.INILOAD'], saved)
        assert reader.f & 64 and plugin_lines in bytes(reader.memory[:0x1000])
    # Один CR после старой версии и суффикс через границу сектора не должны
    # оставлять буквы версии в INIA или съедать первую секцию настроек.
    for header in (b'Wild Commander v1.1', CURRENT, CURRENT + b'x' * 512):
        cpu = machine()
        invoke(cpu, syms['WCINI.INILOAD'], header + b'\r[SETUP]\rCPU_FREQ=2\r')
        normalized = bytes(cpu.memory[:0x1000]).split(b'\0')[0]
        assert normalized == b'\r[SETUP]\rCPU_FREQ=2\r', normalized[:64]
    cpu = machine()
    cpu.a = 3  # Missing INI: create the built-in settings without a merge.
    invoke(cpu, syms['WCINI.GINI'])
    assert bytes(cpu.memory[0x1000:0x1000+len(CURRENT)+2]) == CURRENT + b'\r\r'
    n = int.from_bytes(cpu.memory[syms['WCINI.SFIS']:syms['WCINI.SFIS']+2], 'little')
    assert cpu.memory[0x1000+n-1] == 13 and cpu.memory[0x1000+n] == 0
    cpu = machine()
    invoke(cpu, syms['WCINI.INILOAD'], b'Invalid Commander v1.1' + body)
    assert not cpu.f & 64, 'Invalid signature accepted'
    print('WCINI version PASS: old/new INI load, multi-sector comments, '
          'plugin merge, v1.10i save/create, exact text size without NUL, '
          'saved INI reload, invalid signature')


if __name__ == '__main__':
    main()
