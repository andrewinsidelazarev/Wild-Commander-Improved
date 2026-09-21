"""Модель General Sound для тестов: настоящий Z80 GS, ПЗУ GS и порты #B3/#BB.

Исполняется образ ПЗУ GS 1.05a (Unreal Speccy, rom/gs105a.rom) и загруженный им
драйвер FTView. Модель повторяет то, что видит программа GS:

* #0000..#3FFF — ПЗУ; #4000..#7FFF — ОЗУ, совпадающее с верхней половиной
  страницы 1; окно #8000..#FFFF выбирается портом #00 (0 — ПЗУ, 1..15 — ОЗУ);
* порты 1..5: команда, данные ZX, данные для ZX, статус, сброс бита команды;
* прерывание каждые 320 тактов (12 МГц / 37,5 кГц), вектор с шины #FF.

Чтение GS из #6000..#7FFF защёлкивает ЦАП. Пакет z80 не сообщает о чтении
данных, поэтому значения ЦАП снимаются точками останова на двух инструкциях
драйвера сразу после защёлки (символы gs_dac_left/gs_dac_right).
Это модель протокола и тактов процессора GS, а не проверка аналогового звука.
"""
from pathlib import Path
import os

import z80

ROM_DIRS = [os.environ.get('GS_ROM_DIR', ''), r'C:\Users\Администратор\Desktop\Unreal\rom']
PAGE = 0x8000
INT_PERIOD = 320


def find_rom(name='gs105a.rom'):
    for d in ROM_DIRS:
        if d and (Path(d) / name).exists():
            return (Path(d) / name).read_bytes()
    return None


class GS:
    def __init__(self, rom, pages=16, dac=None):
        assert len(rom) == 0x8000
        self.cpu = z80.Z80Machine()
        self.rom = bytes(rom)
        self.pages = pages
        self.ram = bytearray(pages * PAGE)
        self.page = 0
        self.cmd = 0
        self.data_in = 0      # записано ZX, читается GS портом 2
        self.data_out = 0     # записано GS портом 3, читается ZX
        self.stat = 0         # бит 0 — команда, бит 7 — данные
        self.vol = [0] * 4
        self.ticks = 0
        self.next_int = INT_PERIOD
        self.dac = dac        # {адрес инструкции: канал}
        self.samples = []     # (такт, канал, значение)
        self.missed_int = 0
        self.cpu.set_memory_block(0, self.rom[:0x4000])
        self.cpu.set_memory_block(0x8000, self.rom)
        self.cpu.set_input_callback(self._in)
        self.cpu.set_output_callback(self._out)
        for addr in (dac or {}):
            self.cpu.set_breakpoint(addr)
        self.cpu.pc = 0

    # --- память --------------------------------------------------------
    def _save(self):
        mem = self.cpu.memory
        if self.page:
            base = (self.page - 1) * PAGE
            self.ram[base:base + PAGE] = mem[0x8000:0x10000]
        self.ram[0x4000:0x8000] = mem[0x4000:0x8000]

    def _map(self, page):
        self._save()
        page %= self.pages
        self.page = page
        mem = self.cpu.memory
        if page:
            base = (page - 1) * PAGE
            mem[0x8000:0x10000] = self.ram[base:base + PAGE]
        else:
            mem[0x8000:0x10000] = self.rom
        mem[0x4000:0x8000] = self.ram[0x4000:0x8000]

    def ring(self):
        """Текущее содержимое страницы 2 (кольцо драйвера)."""
        self._save()
        return bytes(self.ram[PAGE:2 * PAGE]) if self.page != 2 else bytes(self.cpu.memory[0x8000:])

    def load(self, addr, data):
        """Прямо поместить код в #4000..#7FFF (обход ПЗУ для узких тестов)."""
        self.cpu.set_memory_block(addr, data)

    # --- порты GS ---------------------------------------------------------
    def _in(self, port):
        port &= 0xFF
        if port == 1:
            return self.cmd
        if port == 2:
            self.stat &= 0x7F
            return self.data_in
        if port == 4:
            return self.stat
        if port == 5:
            self.stat &= 0xFE
        return 0xFF

    def _out(self, port, value):
        port &= 0xFF
        if port == 0:
            self._map(value)
        elif port == 3:
            self.data_out = value
            self.stat |= 0x80
        elif port == 5:
            self.stat &= 0xFE
        elif 6 <= port <= 9:
            self.vol[port - 6] = value & 0x3F

    # --- порты ZX ---------------------------------------------------------
    def zx_in(self, port):
        port &= 0xFF
        if port == 0xBB:
            return self.stat | 0x7E
        if port == 0xB3:
            self.stat &= 0x7F
            return self.data_out
        return 0xFF

    def zx_out(self, port, value):
        port &= 0xFF
        if port == 0xB3:
            self.data_in = value
            self.stat |= 0x80
        elif port == 0xBB:
            self.cmd = value
            self.stat |= 0x01

    # --- время -------------------------------------------------------------
    def run(self, ticks):
        """Исполнить GS примерно ticks тактов (12 МГц), с прерываниями."""
        end = self.ticks + ticks
        cpu = self.cpu
        while self.ticks < end:
            slice_ = min(end, self.next_int) - self.ticks
            if slice_ > 0:
                cpu.ticks_to_stop = slice_
                # run() возвращается и на точке останова, и на внутренней
                # границе «кадра» пакета z80 (событие 1) с ненулевым остатком.
                # Такой срез нельзя считать завершённым: иначе следующее INT
                # приходит раньше срока, пока идёт предыдущий обработчик.
                while True:
                    ev = cpu.run()
                    left = int.from_bytes(bytes(cpu._StateBase__ticks_to_stop), 'little')
                    if ev & 2 and self.dac and cpu.pc in self.dac:
                        self.samples.append((self.ticks + slice_ - left, self.dac[cpu.pc], cpu.a))
                    if not left:
                        break
                self.ticks += slice_
            if self.ticks >= self.next_int:
                self.next_int += INT_PERIOD
                # Импульс INT длится несколько тактов: даём процессору дойти
                # до конца инструкции после EI, но не ждём дольше импульса.
                for _ in range(8):
                    if cpu.on_handle_active_int():
                        break
                    cpu.ticks_to_stop = 4
                    ev = cpu.run()
                    if ev & 2 and self.dac and cpu.pc in self.dac:
                        self.samples.append((self.ticks, self.dac[cpu.pc], cpu.a))
                else:
                    self.missed_int += 1


def gs_symbols(path):
    """Символы драйвера из карты sdldz80 (.map)."""
    import re
    text = Path(path).read_text(errors='replace')
    return {n: int(a, 16) for a, n in re.findall(r'^\s+([0-9A-F]{8})\s+(\w+)', text, re.M)}
