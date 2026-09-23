# Claude - 2026-09-21 - begin
"""Кэш сектора FAT в потоке LOAD512/SAVE512/LOADNON: машинные тесты.

Исполняется собранный CORE32 из exe/boot.$C и CORE32_EXT из Build. Драйвер
носителя заменён RAM-моделью в точках XPOZI/PROZ/RDDSE/SDDSE/SELDEV/DEVINI;
всё остальное — настоящие Z80-команды ядра и расширения. Проверяется:

- поток читает и пишет те же секторы данных, что независимая модель цепочки
  FAT, и возвращает прежние A/CF/HL (конец цепочки, повреждённая ссылка,
  ссылка 0 на корень, ошибка I/O данных);
- сектор FAT читается один раз на сектор FAT, а не на каждый кластер;
- кэш сбрасывают: запись FAT со страницы-клона WC, CURIT с правкой SECBU без
  записи, DEVINI, DOS_SWP, HDD и начало чтения каталога NXTINI;
- цикл UCHN в разборе LFN (NXTETY) и укороченный DELEN дают прежний результат.

Пути к другому набору артефактов (например, к старому ядру для сравнения)
задаются переменными WC_BOOT, WC_EXT, WC_BOOT_SYM, WC_EXT_SYM.
"""
from __future__ import annotations

import os
import random
import re
import unittest
from pathlib import Path

import z80

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build'
STOP, STACK = 0xFF00, 0x5F00
CLUSTER_SLOT = 0x7FF0          # 4 байта номера кластера для GIPAG
BUFFER = 0x8000                # буфер потока: 32 сектора до #C000
EOC = 0x0FFFFFFF


def symbols(path: Path) -> dict[str, int]:
    text = path.read_text(encoding='utf-8')
    return {m[1]: int(m[2], 16)
            for m in re.finditer(r'^([^:\s]+):\s+EQU\s+0x([0-9A-Fa-f]+)', text, re.M)}


def get32(memory, address: int) -> int:
    return int.from_bytes(bytes(memory[address:address + 4]), 'little')


def put32(memory, address: int, value: int) -> None:
    memory[address:address + 4] = (value & 0xFFFFFFFF).to_bytes(4, 'little')


def data_pattern(lba: int) -> bytes:
    """Содержимое сектора данных однозначно задаёт его LBA."""
    head = lba.to_bytes(4, 'little')
    body = bytes((lba * 7 + i) & 255 for i in range(508))
    return head + body


class Machine:
    """Настоящий CORE32 + CORE32_EXT и FAT32-том в памяти Python."""

    def __init__(self, *, spc: int = 1, fat_sectors: int = 8, bfats: int = 1,
                 fatflags: int = 0, sfat: int = 32) -> None:
        boot = Path(os.environ.get('WC_BOOT', ROOT / 'exe' / 'boot.$C'))
        ext = Path(os.environ.get('WC_EXT', BUILD / 'CORE32_EXT.bin'))
        self.sym = symbols(Path(os.environ.get('WC_BOOT_SYM', BUILD / 'boot.sym')))
        self.ext = symbols(Path(os.environ.get('WC_EXT_SYM', BUILD / 'CORE32_EXT.sym')))
        self.cpu = z80.Z80Machine()
        self.mem = self.cpu.memory
        image = boot.read_bytes()
        self.cpu.set_memory_block(0x6000, image)
        end = self.core('END')
        self.cpu.set_memory_block(0x4000, image[0x600C:0x600C + end - 0x4000])
        self.cpu.set_memory_block(0xC000, ext.read_bytes())
        # Окно #0000..#3FFF — файловая страница WC. Остальные страницы живут
        # здесь и подставляются switch(), как это делает MNG0/DMA-клон WC.
        self.pages: dict[str, bytearray] = {}
        self.page = 'A'
        self.spc, self.fat_sectors, self.bfats, self.sfat = spc, fat_sectors, bfats, sfat
        self.fatflags = fatflags
        self.sdfat = sfat + bfats * fat_sectors
        self.clusters = fat_sectors * 128
        self.sectors: dict[int, bytes] = {}
        self.position = 0
        self.log: list[tuple[str, int]] = []
        self.fail_lbas: set[int] = set()
        self.fail_writes: set[int] = set()
        self.seldev: list[int] = []
        self.devini = 0
        self.ticks = 0
        for cluster in range(self.clusters):
            self.set_fat(cluster, 0)
        self.set_fat(0, 0x0FFFFFF8)
        self.set_fat(1, EOC)
        self.set_fat(2, EOC)                     # корневой каталог
        self.configure()
        self.handlers = {
            self.core('XPOZI'): self._xpozi, self.core('PROZ'): self._proz,
            self.core('RDDSE'): self._rddse, self.core('SDDSE'): self._sddse,
            self.core('SELDEV'): self._seldev, self.core('DEVINI'): self._devini,
        }
        for address in (*self.handlers, STOP):
            self.cpu.set_breakpoint(address)

    # --- адреса и состояние ---
    def core(self, name: str) -> int:
        return self.sym['WDOS.' + name]

    def extension(self, name: str) -> int:
        return self.ext['WDOS_EXT.' + name]

    def configure(self) -> None:
        """Записать параметры тома в VALS текущей страницы (как HDD)."""
        m = self.mem
        m[self.core('BSECPC')] = self.spc
        m[self.core('BFATS')] = self.bfats
        m[self.core('FATFLAGS')] = self.fatflags
        put32(m, self.core('BFTSZ'), self.fat_sectors)
        m[self.core('SFAT'):self.core('SFAT') + 2] = self.sfat.to_bytes(2, 'little')
        put32(m, self.core('SDFAT'), self.sdfat)
        put32(m, self.core('ADDTOP'), 0)
        put32(m, self.core('BROOTC'), 2)
        put32(m, self.core('FSTFRC'), 3)
        put32(m, self.extension('FAT_DATA_CLUSTER_LIMIT'), self.clusters)

    def generation(self) -> int:
        return get32(self.mem, self.core('FAT_CACHE_GENERATION'))

    def tag(self) -> int:
        return get32(self.mem, self.core('FATTAG'))

    def switch(self, page: str, clone_from: str | None = None) -> None:
        """Подменить окно #0000; clone_from повторяет DMA-клон WC (#3000..#3FFF)."""
        self.pages[self.page] = bytearray(self.mem[0:0x4000])
        if clone_from is not None:
            source = self.pages[clone_from]
            target = self.pages.get(page, bytearray(0x4000))
            target[0x3000:0x4000] = source[0x3000:0x4000]
            self.pages[page] = target
        self.mem[0:0x4000] = self.pages[page]
        self.page = page

    # --- FAT и секторы ---
    def fat_lba(self, cluster: int, copy: int = 0) -> int:
        return self.sfat + copy * self.fat_sectors + cluster // 128

    def read_sector(self, lba: int) -> bytes:
        if lba in self.sectors:
            return self.sectors[lba]
        if lba >= self.sdfat:
            return data_pattern(lba)
        return bytes(512)

    def set_fat(self, cluster: int, value: int) -> None:
        for copy in range(self.bfats):
            lba = self.fat_lba(cluster, copy)
            sector = bytearray(self.read_sector(lba))
            offset = cluster % 128 * 4
            sector[offset:offset + 4] = (value & 0xFFFFFFFF).to_bytes(4, 'little')
            self.sectors[lba] = bytes(sector)

    def active_copy(self) -> int:
        """Копия FAT, которую читает CURIT: активная при BPB_ExtFlags бит 7."""
        return self.fatflags & 0x0F if self.fatflags & 0x80 else 0

    def fat(self, cluster: int, copy: int | None = None) -> int:
        copy = self.active_copy() if copy is None else copy
        sector = self.read_sector(self.fat_lba(cluster, copy))
        return int.from_bytes(sector[cluster % 128 * 4:cluster % 128 * 4 + 4], 'little')

    def cluster_lba(self, cluster: int) -> int:
        return self.sdfat + (cluster - 2) * self.spc

    def make_chain(self, clusters: list[int]) -> None:
        for current, following in zip(clusters, clusters[1:] + [None]):
            self.set_fat(current, EOC if following is None else following)

    def is_fat(self, lba: int) -> bool:
        return self.sfat <= lba < self.sdfat

    def fat_reads(self) -> int:
        return sum(1 for kind, lba in self.log if kind == 'R' and self.is_fat(lba))

    def data_io(self, kind: str) -> list[int]:
        return [lba for k, lba in self.log if k == kind and not self.is_fat(lba)]

    # --- модель драйвера ---
    def _ret(self) -> None:
        sp = self.cpu.sp
        self.cpu.pc = self.mem[sp] | self.mem[sp + 1] << 8
        self.cpu.sp = sp + 2 & 0xFFFF

    def _xpozi(self) -> None:
        value = self.cpu.de << 16 | self.cpu.hl
        put32(self.mem, self.core('LTHL'), value)
        self.position = value
        self._ret()

    def _proz(self) -> None:
        self.position = self.cpu.de << 16 | self.cpu.hl
        self._ret()

    def _transfer(self, write: bool) -> None:
        count = self.cpu.a or 256
        address = self.cpu.hl
        for index in range(count):
            lba = self.position + index
            if lba in self.fail_lbas or write and lba in self.fail_writes:
                self.mem[self.core('ABT')] = 1
                self._ret()
                return
            self.log.append(('W' if write else 'R', lba))
            if write:
                self.sectors[lba] = bytes(self.mem[address:address + 512])
            else:
                self.mem[address:address + 512] = self.read_sector(lba)
            address += 512
        self.cpu.hl = address & 0xFFFF
        self.mem[self.core('ABT')] = 0
        self._ret()

    def _rddse(self) -> None:
        self._transfer(False)

    def _sddse(self) -> None:
        self._transfer(True)

    def _seldev(self) -> None:
        self.seldev.append(self.cpu.a)
        self._ret()

    def _devini(self) -> None:
        self.devini += 1
        # Драйвер IDE читает IDENTIFY прямо в #3000 (SECBU).
        self.mem[0x3000:0x3200] = bytes([0xEC]) * 512
        self.cpu.a, self.cpu.f = 0, 0x40
        self._ret()

    # --- вызов процедур ---
    def call(self, address: int, *, a: int = 0, bc: int = 0, de: int = 0, hl: int = 0,
             budget: int = 400000) -> tuple[int, int, int, int]:
        cpu = self.cpu
        cpu.sp = STACK
        self.mem[STACK:STACK + 2] = STOP.to_bytes(2, 'little')
        cpu.pc, cpu.a, cpu.bc, cpu.de, cpu.hl = address, a, bc, de, hl
        for _ in range(budget):
            cpu.ticks_to_stop = 1_000_000
            event = cpu.run()
            left = int.from_bytes(bytes(cpu._StateBase__ticks_to_stop), 'little')
            self.ticks += 1_000_000 - left
            if not event & 2:
                continue
            if cpu.pc == STOP:
                return cpu.a, cpu.f, cpu.hl, cpu.de
            handler = self.handlers.get(cpu.pc)
            if handler:
                handler()
                # Хвостовой JP в драйвер (DEVINI_INVALIDATE) возвращает прямо
                # в STOP: второй run() начал бы исполнять память за STOP.
                if cpu.pc == STOP:
                    return cpu.a, cpu.f, cpu.hl, cpu.de
            # Иначе метка задета служебным циклом памяти: продолжаем.
        raise AssertionError(f'Z80 did not finish at #{cpu.pc:04X}')

    def open(self, cluster: int) -> tuple[int, int]:
        put32(self.mem, CLUSTER_SLOT, cluster)
        a, f, _, _ = self.call(self.core('GIPAG'), hl=CLUSTER_SLOT)
        return a, f

    def stream(self, api: int, count: int, buffer: int = BUFFER) -> tuple[int, int, int]:
        a, f, hl, _ = self.call(api, bc=count << 8, hl=buffer)
        return a, f & 1, hl

    def load(self, count: int, buffer: int = BUFFER):
        return self.stream(0x4015, count, buffer)

    def save(self, count: int, buffer: int = BUFFER):
        return self.stream(0x4018, count, buffer)

    def skip(self, count: int):
        return self.stream(0x4054, count)


class ChainModel:
    """Независимая модель потока: те же правила перехода, что GIPAG."""

    def __init__(self, machine: Machine, cluster: int) -> None:
        self.m, self.cluster, self.sector, self.state = machine, cluster, 0, 0

    def follow(self) -> None:
        raw = self.m.fat(self.cluster)
        if raw == 0:
            self.cluster, self.sector = 2, 0          # исторический переход к корню
            return
        link = raw & 0x0FFFFFFF
        if link < 2 or 0x0FFFFFF0 <= link < 0x0FFFFFF8:
            self.state = 0xFF
        elif link >= 0x0FFFFFF8:
            self.state = 0x0F
        else:
            self.cluster, self.sector = link, 0

    def run(self, count: int) -> tuple[list[int], int, int]:
        """Вернуть LBA данных, A и CF одного вызова LOAD512/SAVE512/LOADNON."""
        if self.state:
            return [], self.state, 0
        lbas = []
        for _ in range(count):
            lbas.append(self.m.cluster_lba(self.cluster) + self.sector)
            self.sector += 1
            if self.sector == self.m.spc:
                self.follow()
                if self.state:
                    break
        return lbas, self.state, int(self.state == 0xFF)


def fragmented_chain(rng: random.Random, limit: int, length: int) -> list[int]:
    """Цепочка из смежных отрезков и скачков между разными секторами FAT."""
    free = list(range(3, limit))
    chain: list[int] = []
    while len(chain) < length:
        start = rng.choice(free)
        run = rng.choice((1, 2, 5, 40, 130, 300))
        for cluster in range(start, min(start + run, limit)):
            if cluster in free and len(chain) < length:
                free.remove(cluster)
                chain.append(cluster)
            else:
                break
    return chain


class StreamTests(unittest.TestCase):
    def check_stream(self, m: Machine, chain: list[int], calls: list[tuple[str, int]]):
        model = ChainModel(m, chain[0])
        self.assertEqual(m.open(chain[0])[1] & 0x40, 0x40)
        for kind, count in calls:
            api = {'load': m.load, 'save': m.save, 'skip': m.skip}[kind]
            before = len(m.log)
            if kind == 'save':
                payload = bytes(random.Random(count).randrange(256) for _ in range(count * 512))
                m.mem[BUFFER:BUFFER + len(payload)] = payload
            a, cf, hl = api(count)
            expected, state, error = model.run(count)
            new = [x for x in m.log[before:] if not m.is_fat(x[1])]
            if kind == 'skip':
                self.assertEqual(new, [], 'LOADNON не должен передавать данные')
            else:
                self.assertEqual([lba for _, lba in new], expected, (kind, count))
                self.assertEqual(hl, BUFFER + 512 * len(expected) & 0xFFFF)
            self.assertEqual((a, cf), (state, error), (kind, count))
            if kind == 'load':
                for index, lba in enumerate(expected):
                    data = bytes(m.mem[BUFFER + index * 512:BUFFER + index * 512 + 512])
                    self.assertEqual(data, m.read_sector(lba))
            if kind == 'save':
                for index, lba in enumerate(expected):
                    self.assertEqual(m.sectors[lba], payload[index * 512:(index + 1) * 512])
        return model

    def test_long_contiguous_chain_reads_each_fat_sector_once(self):
        for spc in (1, 4, 8):
            with self.subTest(spc=spc):
                m = Machine(spc=spc, fat_sectors=8)
                chain = list(range(3, 1000))
                m.make_chain(chain)
                calls = [('skip', 255)] * (len(chain) * spc // 255 + 1)
                self.check_stream(m, chain, calls)
                # Все 8 секторов FAT по одному разу: #03..#3E7 проходят 0..7.
                self.assertEqual(m.fat_reads(), 8)
                self.assertEqual(m.tag(), m.generation())

    def test_fragmented_chains_match_model(self):
        rng = random.Random(20260921)
        # Одна FAT, две зеркальные и активная FAT 1 (BPB_ExtFlags бит 7):
        # CURIT читает выбранную копию, кэш от этого не зависит.
        for spc, (bfats, fatflags) in ((1, (1, 0)), (2, (2, 0)), (8, (2, 0x81))):
            for trial in range(6):
                with self.subTest(spc=spc, fatflags=fatflags, trial=trial):
                    m = Machine(spc=spc, fat_sectors=8, bfats=bfats, fatflags=fatflags)
                    chain = fragmented_chain(rng, m.clusters, rng.randrange(40, 400))
                    m.make_chain(chain)
                    if fatflags & 0x80:
                        # Неактивная копия 0 не должна читаться вовсе.
                        for sector in range(m.fat_sectors):
                            m.sectors[m.sfat + sector] = bytes([0xA5]) * 512
                    calls = [(rng.choice(('load', 'load', 'skip', 'save')),
                              rng.choice((1, 3, 8, 16, 32))) for _ in range(120)]
                    self.check_stream(m, chain, calls)
                    # Сектор FAT перечитывается только при смене сектора FAT.
                    switches = 1 + sum(1 for a, b in zip(chain, chain[1:]) if a // 128 != b // 128)
                    self.assertLessEqual(m.fat_reads(), switches)

    def test_end_of_chain_bad_link_root_link_and_data_error(self):
        # EOC и повреждённая ссылка внутри уже кэшированного сектора FAT.
        for last, state in ((EOC, 0x0F), (0x0FFFFFF5, 0xFF), (1, 0xFF), (0x10000000, 0xFF)):
            with self.subTest(last=hex(last)):
                m = Machine(spc=2)
                chain = list(range(10, 20))
                m.make_chain(chain)
                m.set_fat(chain[-1], last)
                model = self.check_stream(m, chain, [('load', 8)] * 3)
                self.assertEqual(model.state, state)
                if state == 0xFF:
                    self.assertEqual(m.mem[m.core('ABT')], 0xFE)
                    self.assertEqual(m.mem[m.core('EOC')], 0xFF)
                self.assertEqual(m.fat_reads(), 1)
        # Ссылка 0 внутри кэшированного сектора: как и прежде, переход к корню.
        m = Machine(spc=1)
        m.make_chain([10, 11, 12])
        m.set_fat(12, 0)
        self.check_stream(m, [10, 11, 12], [('load', 5)])
        # Ошибка I/O данных после попаданий в кэш.
        m = Machine(spc=1)
        m.make_chain(list(range(10, 30)))
        m.fail_lbas = {m.cluster_lba(15)}
        m.open(10)
        a, cf, _ = m.load(16)
        self.assertEqual((a, cf), (0xFF, 1))
        self.assertEqual(m.mem[m.core('ABT')], 0xFF)

    def test_fat_write_from_cloned_page_invalidates(self):
        m = Machine(spc=1)
        chain = list(range(10, 60))
        m.make_chain(chain)
        m.open(10)
        self.assertEqual(m.load(20)[0], 0)          # страница A: кэш сектора 0
        fat_reads = m.fat_reads()
        # Страница B — клон A (WC CLONEZ/API 57). Через неё меняется ссылка
        # кластера 40: CURIT, правка записи, SAVE_FAT_SECTOR.
        m.switch('B', clone_from='A')
        a, f, hl, _ = m.call(m.core('CURIT'), hl=40)
        self.assertFalse(f & 1)
        put32(m.mem, hl, 200)
        m.call(m.extension('SAVE_FAT_SECTOR'))
        m.set_fat(200, EOC)
        self.assertEqual(m.fat(40), 200)
        m.switch('A')
        fat_reads = m.fat_reads()
        a, cf, _ = m.load(40)
        self.assertEqual((a, cf), (0x0F, 0))
        expected = [m.cluster_lba(c) for c in list(range(30, 41)) + [200]]
        self.assertEqual(m.data_io('R')[-len(expected):], expected)
        self.assertEqual(m.fat_reads(), fat_reads + 2)   # перечитан сектор 0, затем сектор 1

    def test_negative_control_without_generation_bump(self):
        # Контроль чувствительности: если бы SAVE_FAT_SECTOR не сбрасывал
        # поколение, страница A пошла бы по устаревшей ссылке 40 -> 41.
        m = Machine(spc=1)
        m.make_chain(list(range(10, 60)))
        m.mem[m.core('FAT_CACHE_BUMP')] = 0xC9      # RET вместо сброса
        m.open(10)
        m.load(20)
        m.switch('B', clone_from='A')
        a, f, hl, _ = m.call(m.core('CURIT'), hl=40)
        put32(m.mem, hl, 200)
        m.call(m.extension('SAVE_FAT_SECTOR'))
        m.switch('A')
        m.load(12)
        self.assertEqual(m.data_io('R')[-1], m.cluster_lba(41), 'тест не видит устаревший кэш')

    def test_curit_edit_without_save_is_not_trusted(self):
        m = Machine(spc=1)
        m.make_chain(list(range(10, 60)))
        m.open(10)
        m.load(20)
        # Вызывающий CURIT правит SECBU (как MKSG/DLSG) и не записывает FAT.
        a, f, hl, _ = m.call(m.core('CURIT'), hl=35)
        self.assertEqual(m.mem[m.core('FATTAG') + 3], 0xFF)
        put32(m.mem, hl, 300)
        before = m.fat_reads()
        m.load(30)
        self.assertEqual(m.data_io('R')[-30:], [m.cluster_lba(c) for c in range(30, 60)])
        self.assertEqual(m.fat_reads(), before + 1)

    def test_devini_dos_swp_hdd_and_directory_bump_generation(self):
        m = Machine(spc=1)
        m.make_chain(list(range(10, 60)))
        m.open(10)
        m.load(20)
        self.assertEqual(m.tag(), m.generation())
        # DEVINI через таблицу START: IDENTIFY затирает SECBU.
        generation = m.generation()
        m.call(0x4003)
        self.assertEqual(m.devini, 1)
        self.assertEqual(m.generation(), generation + 1)
        before = m.fat_reads()
        m.load(20)
        self.assertEqual(m.data_io('R')[-20:], [m.cluster_lba(c) for c in range(30, 50)])
        self.assertEqual(m.fat_reads(), before + 1)
        # DOS_SWP: распаковка драйвера в #3800 и SELDEV с прежним A.
        generation = m.generation()
        m.call(0x401B, a=5)
        self.assertEqual(m.seldev, [1])
        self.assertEqual(m.generation(), generation + 1)
        self.assertEqual(m.tag(), 0, 'образ драйвера обнуляет FATTAG')
        # NXTINI: начало чтения каталога (пустой корень, кластер 2).
        m.configure()
        m.sectors[m.cluster_lba(2)] = bytes(512)
        m.mem[m.core('CGFL'):m.core('CGFL') + 2] = b'\0\0'
        put32(m.mem, m.core('LSTCAT'), 0)
        generation = m.generation()
        m.call(0x4057, de=0xA000)
        self.assertEqual(m.generation(), generation + 1)
        # SAVE_FAT_SECTOR сам по себе.
        generation = m.generation()
        m.call(m.core('CURIT'), hl=10)
        m.call(m.extension('SAVE_FAT_SECTOR'))
        self.assertEqual(m.generation(), generation + 1)

    def test_hdd_bumps_generation(self):
        m = Machine(spc=1)
        mbr = bytearray(512)
        mbr[446 + 4] = 0x0C
        mbr[446 + 8:446 + 12] = (1).to_bytes(4, 'little')
        mbr[510:512] = b'\x55\xAA'
        bpb = bytearray(512)
        bpb[11:13] = (512).to_bytes(2, 'little')
        bpb[13], bpb[14:16], bpb[16] = 1, (32).to_bytes(2, 'little'), 1
        bpb[32:36] = (4096).to_bytes(4, 'little')
        bpb[36:40] = (8).to_bytes(4, 'little')
        bpb[44:48] = (2).to_bytes(4, 'little')
        bpb[48:50] = (1).to_bytes(2, 'little')
        bpb[510:512] = b'\x55\xAA'
        m.sectors[0] = bytes(mbr)
        m.sectors[1] = bytes(bpb)
        generation = m.generation()
        a, f, _, _ = m.call(0x4009)
        self.assertTrue(f & 0x40, 'HDD не смонтировал тестовый том')
        self.assertEqual(m.generation(), generation + 1)


class RefactorTests(unittest.TestCase):
    def directory(self, m: Machine, names: list[str]) -> bytes:
        """Корневой каталог (кластер 2) с LFN и SFN, как их пишет ENTREZ."""
        from test_lfn_namespace import long_entry
        records = b''
        for index, name in enumerate(names):
            short = f'N{index:07}TXT'.encode()
            records += long_entry(name, short)
        return records + bytes(32)

    def list_directory(self, m: Machine, names: list[str], mask: int | None) -> list[bytes]:
        records = self.directory(m, names)
        sectors = (len(records) + 511) // 512
        chain = [2] + list(range(100, 100 + (sectors - 1) // m.spc))
        m.make_chain(chain)
        for index in range(sectors):
            cluster = chain[index // m.spc]
            lba = m.cluster_lba(cluster) + index % m.spc
            m.sectors[lba] = records[index * 512:(index + 1) * 512].ljust(512, b'\0')
        for index in range(sectors, len(chain) * m.spc):
            m.sectors[m.cluster_lba(chain[index // m.spc]) + index % m.spc] = bytes(512)
        m.mem[m.core('CGFL'):m.core('CGFL') + 2] = b'\0\0'
        put32(m.mem, m.core('LSTCAT'), 0)
        result = []
        while True:
            if mask is None:
                a, f, _, de = m.call(0x4057, de=0xA000)
            else:
                a, f, _, de = m.call(0x405A, a=mask, de=0xA000)
            if f & 0x40:
                return result
            result.append(bytes(m.mem[0xA000:de]))

    def test_lfn_names_decode_through_uchn(self):
        names = ['a', 'Report 2026.txt', 'x' * 13, 'y' * 14, 'z' * 26, 'w' * 27,
                 'Длинное имя файла.txt', 'Ёжик и ёлка', 'q' * 255,
                 'Mixed Регистр 13ch', 'abcdefghijklm' * 3]
        for mask in (None, 0, 4):
            m = Machine(spc=1, fat_sectors=4)
            listing = self.list_directory(m, names, mask)
            self.assertEqual(len(listing), len(names))
            for name, raw in zip(names, listing):
                expected = name.encode('cp866') + b'\0'
                self.assertTrue(raw.endswith(expected), (mask, name, raw))

    def test_broken_lfn_falls_back_to_sfn(self):
        # Неверный номер записи LFN и символ вне CP866 (отказ UCHN с флагом Z).
        from test_lfn_namespace import long_entry
        for name, patch in (('broken name', 0x42), ('Café menu.txt', None)):
            with self.subTest(name=name):
                m = Machine(spc=1, fat_sectors=4)
                record = bytearray(long_entry(name, b'BROKEN  TXT'))
                if patch is not None:
                    record[0] = patch
                m.make_chain([2])
                m.sectors[m.cluster_lba(2)] = bytes(record) + bytes(512 - len(record))
                m.mem[m.core('CGFL'):m.core('CGFL') + 2] = b'\0\0'
                put32(m.mem, m.core('LSTCAT'), 0)
                a, f, _, de = m.call(0x4057, de=0xA000)
                self.assertFalse(f & 0x40)
                self.assertTrue(bytes(m.mem[0xA000:de]).endswith(b'broken.txt\0'))

    def test_delete_returns_flags_and_frees_chain(self):
        from test_lfn_namespace import long_entry
        for fail in (False, True):
            with self.subTest(fail=fail):
                m = Machine(spc=1, fat_sectors=4)
                entry = bytearray(long_entry('Delete me.txt', b'DELETE~1TXT'))
                entry[-32 + 26:-32 + 28] = (40).to_bytes(2, 'little')
                m.make_chain([2])
                m.make_chain([40, 41, 42])
                directory = m.cluster_lba(2)
                m.sectors[directory] = bytes(entry) + bytes(512 - len(entry))
                put32(m.mem, m.core('LSTCAT'), 0)
                query = b'\0' + 'Delete me.txt'.encode('cp866') + b'\0'
                m.mem[0x8000:0x8000 + len(query)] = query
                if fail:
                    m.fail_writes = {directory}
                a, f, _, _ = m.call(0x403F, hl=0x8000)
                if fail:
                    self.assertEqual((a, f & 0x40), (0, 0x40))
                    self.assertEqual(m.fat(40), 41)
                else:
                    self.assertEqual((a, f & 0x40), (1, 0))
                    self.assertEqual(m.sectors[directory][0], 0xE5)
                    self.assertEqual([m.fat(c) for c in (40, 41, 42)], [0, 0, 0])


if __name__ == '__main__':
    unittest.main(verbosity=2)
# Claude - 2026-09-21 - end
