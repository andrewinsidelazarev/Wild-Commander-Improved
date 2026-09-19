"""Общий запуск собранных CORE32/FILEX с точками дискового стенда."""
from pathlib import Path
import z80
import test_fat_allocator_hint as h
import test_lfn_namespace as ns

ROOT = Path(__file__).resolve().parents[2]
BOOT = ns.symbols(ROOT / 'Build/boot.sym')
EXT = ns.symbols(ROOT / 'Build/CORE32_EXT.sym')
FX = ns.symbols(ROOT / 'Build/FILEX.sym')
STOP, STACK = 0xFF00, 0x5F00


def base(filex=False):
    cpu = z80.Z80Machine()
    boot = (ROOT / 'exe/boot.$C').read_bytes()
    cpu.set_memory_block(0x6000, boot)
    cpu.set_memory_block(0x4000, boot[0x600C:0x600C + BOOT['WDOS.END'] - 0x4000])
    runtime = ((ROOT / 'Build/FILEX.WMF').read_bytes()[512:] if filex
               else (ROOT / 'Build/CORE32_EXT.bin').read_bytes())
    cpu.set_memory_block(0xC000, runtime)
    return cpu


def ret(cpu):
    cpu.pc = h.get16(cpu.memory, cpu.sp)
    cpu.sp = (cpu.sp + 2) & 65535


def run(cpu, start, callbacks=None, stops=(), budget=500000):
    callbacks = callbacks or {}
    cpu.pc, cpu.sp = start, STACK
    h.put16(cpu.memory, STACK, STOP)
    targets = set(stops) | {STOP}
    for address in targets | callbacks.keys():
        cpu.set_breakpoint(address)
    for _ in range(budget):
        cpu.ticks_to_stop = 1000000
        event = cpu.run()
        if not event & 2:
            continue
        if cpu.pc in targets:
            return cpu.pc
        if cpu.pc in callbacks:
            callbacks[cpu.pc](cpu)
    raise AssertionError(f'Z80 did not finish at #{cpu.pc:04X}')
