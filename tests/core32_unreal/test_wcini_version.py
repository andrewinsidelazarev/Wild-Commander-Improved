"""Execute INI load paths, version compatibility and the no-INI fallback."""
from pathlib import Path
import re
import z80

ROOT = Path(__file__).resolve().parents[2]
STOP = 0xFF00
CURRENT = re.search(rb'DEFINE\s+WC_VERSION\s+"([^"]+)"',
                    (ROOT / 'source/VERSION.ASM').read_bytes()).group(1)


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


def supl_lines(syms, text):
    """Какие строки секции [PLUGINS] цикл SUPL отдаёт загрузчику SERNLOD.

    text — уже нормализованный INILOAD текст (без комментариев), цикл
    стартует с «]» заголовка, как после поиска секции. SERNLOD подменён:
    запоминает строку и отвечает Z («файла нет»), чтобы не звать PLPRNAM.
    """
    cpu = machine()
    cpu.set_memory_block(0, text + b'\0')
    cpu.pc, cpu.sp, cpu.hl = syms['WCINI.RSI'], 0x5FFC, text.index(b'[PLUGINS') + 8
    cpu.memory[0x5FFC:0x5FFE] = STOP.to_bytes(2, 'little')
    for address in (STOP, syms['WCINI.SERNLOD']):
        cpu.set_breakpoint(address)
    lines = []
    for _ in range(1000):
        cpu.ticks_to_stop = 100000
        if not cpu.run() & 2:
            continue
        if cpu.pc == STOP:
            return lines
        lines.append(bytes(cpu.memory[cpu.hl:cpu.hl + 80]).split(b'\r')[0].decode())
        cpu.f |= 0x40
        cpu.pc = int.from_bytes(cpu.memory[cpu.sp:cpu.sp + 2], 'little')
        cpu.sp += 2
    raise AssertionError('цикл SUPL не вернулся')


def main():
    syms = {m[1]: int(m[2], 16) for line in (ROOT / 'Build/boot.sym').read_text().splitlines()
            if (m := re.match(r'^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$', line))}
    # Выключенный плагин — «;» в начале строки (так пишет WC Setup), и после
    # INILOAD эта строка пустая. Раньше она кончала секцию: SCRSAVER за
    # выключенной строкой CLOCK не грузился вовсе. Конец — только «[» или
    # конец текста; флаги строки доходят до загрузчика целиком.
    ini = (CURRENT + b'\r[PLUGINS]\rFILEX.WMF\r;PLM.WMF\rSETUP.WMF\r'
           b';CLOCK.WMF;PLASMATW.WMF;SCRSAVER.WMF\rSCRSAVER.WMF\r\r'
           b'TXTEDIT.WMF -highlight=auto; auto,on,off\r\r[LPANEL]\rDRV=1\r')
    cpu = machine()
    invoke(cpu, syms['WCINI.INILOAD'], ini)
    normalized = bytes(cpu.memory[:0x1000]).split(b'\0')[0]
    seen = supl_lines(syms, normalized)
    assert seen == ['FILEX.WMF', 'SETUP.WMF', 'SCRSAVER.WMF', 'TXTEDIT.WMF -highlight=auto'], seen
    seen = supl_lines(syms, b'\r[PLUGINS]\rFILEX.WMF\r\r\rSETUP.WMF\r\r')
    assert seen == ['FILEX.WMF', 'SETUP.WMF'], ('секция в конце файла', seen)
    plugin_lines = b'[PLUGINS]\rFILEX.WMF\rTXTEDIT.WMF -highlight=auto\r'
    # Comments force multiple actual LOAD512 calls and exercise the loader's
    # sector boundaries while plugin arguments must survive normalization.
    body = (b'\r\r[SETUP]\rCPU_FREQ=2\r' + b';long comment\r' * 95
            + plugin_lines + b'\r[LPANEL]\rDRV=1\r\r[RPANEL]\rDRV=1\r')
    for header in (b'Wild Commander v1.1', CURRENT):
        cpu = machine()
        invoke(cpu, syms['WCINI.INILOAD'], header + body)
        assert cpu.f & 64, ('Compatible INI rejected', header)
        normalized = bytes(cpu.memory[:0x1000]).split(b'\0')[0]
        assert plugin_lines in normalized and b'long comment' not in normalized
        assert normalized.lstrip(b'\r').startswith(b'[SETUP]\r'), normalized[:32]
    # Один CR после старой версии и суффикс через границу сектора не должны
    # оставлять буквы версии в INIA или съедать первую секцию настроек.
    for header in (b'Wild Commander v1.1', CURRENT, CURRENT + b'x' * 512):
        cpu = machine()
        invoke(cpu, syms['WCINI.INILOAD'], header + b'\r[SETUP]\rCPU_FREQ=2\r')
        normalized = bytes(cpu.memory[:0x1000]).split(b'\0')[0]
        assert normalized == b'\r[SETUP]\rCPU_FREQ=2\r', normalized[:64]
    cpu = machine()
    invoke(cpu, syms['WCINI.INILOAD'], b'Invalid Commander v1.1' + body)
    assert not cpu.f & 64, 'Invalid signature accepted'
    # wc.ini пишет SETUP.WMF, ядро его только читает. Без файла ядро берёт
    # встроенный минимум: FILEX, менеджер плагинов и сам SETUP.WMF, который
    # при автозапуске предложит создать wc.ini.
    for name in ('GINI', 'SAVEINI', 'SETUPAPI', 'F9STP'):
        assert 'WCINI.' + name not in syms, f'в ядре снова есть запись wc.ini: {name}'
    payload = (ROOT / 'Build/boot.payload.bin').read_bytes()
    start = syms['WCINI.DEFINI'] - 0x6011
    builtin = payload[start:start + syms['WCINI.DEFINIL']]
    assert builtin == b'[PLUGINS]\rFILEX.WMF\rPLM.WMF\rSETUP.WMF\r\0', builtin
    # Шрифт лежит сразу за WCINI и сдвигается вместе с его концом; с
    # 2026-09-26 — HR-потоком, который VDAC распаковывает DEHR (test_boot_resources).
    assert syms['WCINI.FONT_PACKED'] == syms['FONT32L3_PACKED'], 'VDAC распаковывает шрифт не оттуда'
    assert syms['WCINI.DECODERS_PACKED'] == syms['DECODERS_PACKED'], 'распаковщики не оттуда'
    assert syms['WCINI.DEHR'] == syms['WDOS.DEHR'] == 0x5AAA, 'VDAC зовёт не DEHR ядра'
    print('WCINI version PASS: old/new INI load, multi-sector comments, '
          'plugin arguments kept, invalid signature, no INI writer in core, '
          'built-in FILEX/PLM/SETUP list, font follows WCINI, '
          'commented plugin lines do not end [PLUGINS]')


if __name__ == '__main__':
    main()
