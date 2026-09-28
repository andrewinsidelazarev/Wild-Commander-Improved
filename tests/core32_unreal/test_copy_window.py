"""Окно хода F5 и F8 — одно на всю операцию (2026-09-26).

Прежде окно полосы F5 открывалось и закрывалось на каждом файле поверх
диалога, полоса каждый раз начиналась с нуля, а пока ищутся файлы и читается
FAT, на экране стоял диалог с кнопками (у F8 — «Deleting is in Progress!»).
Теперь CP_GO/DL_GO (WCINI) закрывают диалог и открывают PBWND: заголовок
«COPY»/«DELETE», строка 2 — «... started...», как пошло дело — «Copying имя»/
«Deleting имя»; строка 3 — «<n of M>»; строка 5 — полоса по всей операции;
строки 1 и 4 пустые (с 2026-09-28: окно CP_W+2 на 7 по центру, прежде 66×5 —
строки 1..3 подряд, полоса 64 клетки). Полоса считается в 64-х долях (CP_BAR),
клеток — доли·CP_W/64.
С 2026-09-27 n и M — файлы операции: M считает CP_COUNT до первого действия
(обход деревьев только на чтение), n растёт на каждом начатом файле, полоса —
по файлам. Прежде там был номер объекта панели: у каталога «0001 of 0001» на
всё дерево, а полоса в каталоге шла ступенями 64·j/(j+8).

Исполняются настоящие CP_GO, DL_GO, PBPR (WCFX) и CP_*/DL_INNER (WCINI) из
собранной нагрузки boot.$C (Build/boot.payload.bin). Вывод (PRWOW, PRSRW,
TXTPR, PRIAT, RRESB), выбор кнопки (YN) и DELFL ядра подменены: записывается,
что и в какую строку окна выведено.

Обход дерева F5/F8 (TreeReadFailure): Z перечисления каталога — конец либо
отказ чтения (ABT≠0 страницы, где шло перечисление). Исполняются настоящие
DFILES, DDIRS/NODIRS, DELDIR, IDXLOOP (WCFX) и DL_NEXT/CP_NEXT/DL_UP/
DL_EMPTY/DL_NED (WCINI); подменены NXTETY2/NXTETY ядра, LOADCD, FENTRY,
GDIR, SAVECD, CDIREX. Окно #0000 переключается по-настоящему (порт #10AF):
у F5/F8 перечисление идёт в копии страницы ФС (#F3), её ABT виден только
до CLONOFF.
"""
from pathlib import Path
import random
import re
import unittest

import z80

ROOT = Path(__file__).resolve().parents[2]
STOP = 0xFF00
STACK = 0x5FFE                                # как у WC: ниже — место за строкой TXTBU
TITLE, NAME, COUNT, BAR = 0, 2, 3, 5          # строки окна хода; 1 и 4 — пустые


def symbols():
    text = (ROOT / 'Build/boot.sym').read_text(encoding='utf-8')
    return {m[1]: int(m[2], 16) for line in text.splitlines()
            if (m := re.match(r'^([^:]+):\s+EQU\s+(0x[0-9A-Fa-f]+)$', line))}


class Window:
    """WC в памяти Z80; вывод в окно хода записывается по строкам."""

    def __init__(self):
        self.sym = symbols()
        self.cpu = z80.Z80Machine()
        # Полезная нагрузка boot.$C с #6011: в сборке тест идёт до записи exe.
        self.cpu.set_memory_block(0x6011, (ROOT / 'Build/boot.payload.bin').read_bytes())
        self.cpu.set_output_callback(lambda port, value: None)
        self.cpu.set_input_callback(lambda port: 0xFF)
        self.rows, self.events, self.writes, self.dialog = {}, [], [], []
        self.geometry = []                            # X, Y, ширина, высота PBWND при PRWOW
        self.width = self.sym['WCINI.CP_W']           # ширина текста и полосы окна хода
        self.delfl_ok, self.deleted = True, []
        self.hooks = {self.sym['PRSRW']: self.prsrw, self.sym['TXTPR']: self.txtpr,
                      self.sym['PRWOW']: self.prwow, self.sym['RRESB']: self.rresb,
                      self.sym['YN']: self.yn, self.sym['PRIAT']: self.priat,
                      0x403F: self.delfl, self.sym['WCFX.ERR0']: self.err0}

    def s(self, name):
        return self.sym[name]

    def put16(self, address, value):
        self.cpu.memory[address:address + 2] = (value & 0xFFFF).to_bytes(2, 'little')

    def put32(self, address, value):
        self.cpu.memory[address:address + 4] = value.to_bytes(4, 'little')

    def ret(self):
        sp = self.cpu.sp
        self.cpu.pc = self.cpu.memory[sp] | self.cpu.memory[sp + 1] << 8
        self.cpu.sp = sp + 2

    def text(self, address, length=None):
        mem = self.cpu.memory
        if length is not None:
            return bytes(mem[address:address + length]).decode('cp866')
        end = address
        while mem[end]:
            end += 1
        return bytes(mem[address:end]).decode('cp866')

    def window_is_progress(self):
        return self.cpu.ix == self.s('PBWND')

    def prsrw(self):
        cpu = self.cpu
        if self.window_is_progress():
            self.rows[cpu.d] = self.text(cpu.hl, cpu.bc)
            self.writes.append(cpu.d)
        else:
            self.dialog.append(('PRSRW', cpu.ix, cpu.d, cpu.e, cpu.bc))
        self.ret()

    def line(self, row):
        return self.rows.get(row, '').strip()

    def centered(self, row):
        text = self.rows[row]
        body = text.strip()
        left = len(text) - len(text.lstrip())
        right = len(text) - len(text.rstrip())
        return len(text) == self.width and abs(left - right) <= 1 and body

    def txtpr(self):
        cpu = self.cpu
        if self.window_is_progress():
            self.rows[cpu.d] = self.text(cpu.hl).replace('\x0e', '').replace('\x09', '')
        else:
            self.dialog.append(('TXTPR', cpu.ix, cpu.d, cpu.e, self.text(cpu.hl)))
        self.ret()

    def priat(self):
        self.dialog.append(('PRIAT', self.cpu.ix, self.cpu.a))
        self.ret()

    def prwow(self):
        ix = self.cpu.ix
        self.events.append(('PRWOW', ix))
        if ix == self.s('PBWND'):
            mem = self.cpu.memory
            self.geometry.append(tuple(mem[ix + 2:ix + 6]))
            header = mem[ix + 12] | mem[ix + 13] << 8
            body = self.text(mem[ix + 16] | mem[ix + 17] << 8)
            row = 1 + len(body) - len(body.lstrip('\r'))  # #0D — строкой ниже
            self.rows = {TITLE: self.text(header).replace('\x0e', '').replace('\x09', ''),
                         row: body.lstrip('\r').replace('\x0e', '')}
        self.ret()

    def rresb(self):
        self.events.append(('RRESB', self.cpu.ix))
        self.ret()

    def err0(self):
        self.events.append(('ERR0', self.text(self.cpu.hl).replace('\x0e', '')))
        self.ret()

    def delfl(self):
        # DELFL ядра: HL → [тип, имя, 0]; NZ — удалено, Z — отказ: A=8 —
        # поиск не нашёл (ABT=0 — записи нет, ABT≠0 — не прочитал каталог),
        # A=0 — отказ записи каталога или освобождения цепочки.
        self.deleted.append(self.text(self.cpu.hl + 1))
        self.cpu.f = 0 if self.delfl_ok else 0x40
        if not self.delfl_ok:
            self.cpu.a = getattr(self, 'delfl_a', 8)
            self.cpu.memory[self.s('WDOS.ABT')] = getattr(self, 'delfl_abt', 0)
        self.ret()

    def yn(self):
        # A=#FF — узнать выбор; ответ: [OK] (Z).
        self.cpu.a, self.cpu.f = 0, 0x40
        self.ret()

    def call(self, address, *, a=0, hl=0, de=0, bc=0, ix=0x1234, f=0):
        cpu = self.cpu
        cpu.sp, cpu.pc, cpu.a, cpu.hl, cpu.de, cpu.bc, cpu.ix = STACK, address, a, hl, de, bc, ix
        cpu.f = f
        self.ticks = 0
        self.put16(STACK, STOP)
        for point in (*self.hooks, STOP):
            cpu.set_breakpoint(point)
        for _ in range(20000):
            cpu.ticks_to_stop = 200000
            event = cpu.run()
            self.ticks += 200000 - int.from_bytes(bytes(cpu._StateBase__ticks_to_stop), 'little')
            if not event & 2:
                continue
            if cpu.pc == STOP:
                return cpu
            handler = self.hooks.get(cpu.pc)
            if handler is None:
                # Эмулятор проверяет точку по адресу сразу за командой: JR
                # прямо перед подменой (цикл CP_MUL64DIV перед ERR0) даёт
                # остановку на цели перехода. Как в test_fat_stream_cache —
                # продолжаем.
                continue
            handler()
            if cpu.pc == STOP:                       # хвостовой JP в подменённую
                return cpu
        raise AssertionError('Z80 не вернулся')

    def bar(self):
        """Заполненная часть полосы в 64-х долях (CP_BAR); нарисованные
        клетки строки 5 обязаны быть долями·CP_W/64."""
        row = self.rows.get(BAR, '')
        self.assertion_bar(row)
        share = self.cpu.memory[self.s('WCINI.CP_BAR')]
        assert row.count('█') == share * self.width // 64, (share, row)
        return share

    def assertion_bar(self, row):
        assert len(row) == self.width, row
        filled = row.count('█')
        assert row == '█' * filled + '▒' * (self.width - filled), row

    # --- шаги операции, как их делает WCFX ---
    def start(self):
        self.call(self.s('WCINI.CP_GO'), ix=self.s('F5WND'))

    def files(self, total):
        """CP_COUNT: всего файлов в операции, начатых — ни одного."""
        self.put16(self.s('WCINI.CP_FILES'), total)
        self.put16(self.s('WCINI.CP_NUM'), 0)

    def entry(self, index, count, name):
        """FLOF: номер объекта панели (MRRN — для «started...») и его имя (как
        в CP_NAME кладёт FLOF); строку 2 пишет CP_COUNTER — по файлам."""
        self.put16(self.s('MRRN'), index)
        self.put16(self.s('MRCT'), count)
        data = name.encode('cp866')[:56]
        base = self.s('WCINI.CP_NAME')
        self.cpu.memory[base:base + 56] = data + bytes(56 - len(data))
        self.call(self.s('WCINI.CP_FLOF'), ix=self.s('F5WND'))  # FLOF: IX = F5WND

    def number(self, name):
        mem = self.cpu.memory
        return mem[self.s(name)] | mem[self.s(name) + 1] << 8

    def file(self, size, *, in_dir_name=None):
        """COPYFD: режим, размер/64 (DEL64) и порции PBPR; в конце CP_DONE."""
        if in_dir_name is None:
            self.call(self.s('WCINI.CP_FILE'), a=3, hl=0)
        else:
            buffer = self.s('WCINI.TXTBU')
            data = in_dir_name.encode('cp866')
            self.cpu.memory[buffer:buffer + len(data) + 1] = data + b'\0'
            self.call(self.s('WCINI.CP_FILE'), a=4, hl=buffer)
        divisor = size >> 6
        self.put16(self.s('WCFX.PBSTL') + 1, divisor & 0xFFFF)
        self.put16(self.s('WCFX.PBSTH') + 1, divisor >> 16)
        self.put32(self.s('PBNOW'), 0)
        fills = []
        for _ in range(-(-size // 16384)):
            self.call(self.s('WCFX.PBPR'))
            fills.append(self.bar())
        self.call(self.s('WCINI.CP_DONE'))
        fills.append(self.bar())
        return fills


class CopyWindow(unittest.TestCase):

    def test_start_closes_dialog_and_opens_one_window(self):
        w = Window()
        w.start()
        self.assertEqual(w.events, [('RRESB', w.s('F5WND')), ('PRWOW', w.s('PBWND'))])
        self.assertEqual(w.line(TITLE), 'COPY')
        self.assertEqual(w.line(NAME), 'Copying started...')
        self.assertEqual(w.bar(), 0)
        self.assertEqual(w.cpu.memory[w.s('WCINI.CP_OPEN')], 1)
        w.call(w.s('WCINI.CP_CLOSE'))
        self.assertEqual(w.events[-1], ('RRESB', w.s('PBWND')))
        self.assertEqual(w.cpu.memory[w.s('WCINI.CP_OPEN')], 0)

    def test_window_is_centered_with_blank_rows(self):
        # 2026-09-28: окно CP_W+2 на 7 — заголовок, пустая строка, имя,
        # счётчик, пустая строка, полоса. X/Y при каждом показе — 255: PRWOW
        # заменяет их вычисленными, и без сброса окно после смены текстового
        # режима осталось бы на месте прежнего центра.
        w = Window()
        w.start()
        self.assertEqual(w.geometry, [(255, 255, w.width + 2, 7)])
        self.assertEqual(w.line(NAME), 'Copying started...')
        pbwnd = w.s('PBWND')
        w.cpu.memory[pbwnd + 2:pbwnd + 4] = bytes((7, 9))     # центр прежнего режима
        w.call(w.s('WCINI.CP_CLOSE'))
        w.start()
        self.assertEqual(w.geometry[-1], (255, 255, w.width + 2, 7))
        w.files(3)
        w.writes.clear()
        for index, size in enumerate((70_000, 0, 500), 1):
            w.entry(index, 3, f'f{index}.bin')
            w.file(size)
        self.assertEqual(set(w.writes), {NAME, COUNT, BAR}, 'строки 1 и 4 — пустые')

    def test_bar_cells_follow_share(self):
        # Полоса считается в 64-х долях, клеток — доли·CP_W/64: до конца
        # передачи (63) — не полная, в конце (64) — вся строка.
        w = Window()
        w.start()
        for share in range(65):
            w.cpu.memory[w.s('WCINI.CP_BAR')] = 0
            w.call(w.s('WCINI.CP_DRAW'), a=share)
            self.assertEqual(w.bar(), share)
            self.assertEqual(w.rows[BAR].count('█'), share * w.width // 64, share)
        self.assertEqual(w.rows[BAR], '█' * w.width)
        w.cpu.memory[w.s('WCINI.CP_BAR')] = 0
        w.call(w.s('WCINI.CP_DRAW'), a=63)
        self.assertEqual(w.rows[BAR].count('█'), w.width - 1)

    def test_flof_without_window_keeps_dialog(self):
        # Окна хода нет (F5 и F8 его открывают, но FLOF к этому не привязана):
        # CP_FLOF ничего не выводит и возвращает Z с HL=TXTBU, B=32; дальше
        # FLOF, как прежде, пишет имя и счётчик в диалог F5WND.
        w = Window()
        cpu = w.call(w.s('WCINI.CP_FLOF'), ix=w.s('F5WND'), hl=0, bc=0)
        self.assertTrue(cpu.f & 0x40, 'F8: FLOF должна продолжить прежний вывод')
        self.assertEqual((cpu.hl, cpu.b), (w.s('WCINI.TXTBU'), 32))
        self.assertEqual((w.rows, w.dialog, w.writes), ({}, [], []))
        # Прежний вывод FLOF в F5WND на месте: сразу за переходом из CP_FLOF.
        flof = bytes(w.cpu.memory[w.s('WCFX.FLOF'):w.s('WCFX.FLOF_SHOWN')])
        self.assertIn(bytes((0xE5, 0xCD)) + w.s('WCFX.NOPING').to_bytes(2, 'little'), flof)

    def test_status_waits_for_data_then_names_file(self):
        w = Window()
        w.start()
        w.files(2)
        w.entry(1, 2, 'big.bin')
        self.assertEqual(w.line(NAME), 'Copying started...', 'пока ищутся файлы и читается FAT')
        self.assertEqual(w.line(COUNT), '<0000 of 0002>', 'файл ещё не начат')
        self.assertTrue(w.centered(COUNT), repr(w.rows[COUNT]))
        w.file(40000)
        self.assertEqual(w.line(NAME), 'Copying big.bin')
        self.assertEqual(w.line(COUNT), '<0001 of 0002>')
        self.assertTrue(w.centered(NAME), repr(w.rows[NAME]))
        w.writes.clear()
        w.entry(2, 2, 'next one.txt')
        self.assertEqual(w.line(NAME), 'Copying next one.txt')
        self.assertEqual(w.line(COUNT), '<0001 of 0002>')
        self.assertTrue(w.centered(NAME) and w.centered(COUNT))
        # Одна запись на строку: без промежуточной очистки, строка не мигает.
        self.assertEqual(sorted(w.writes), [NAME, COUNT, BAR])

    def test_long_name_fills_the_line(self):
        w = Window()
        w.start()
        name = 'A very long file name that certainly does not fit the line.txt'
        w.entry(1, 1, name)
        w.file(100)
        self.assertEqual(w.line(NAME), ('Copying ' + name)[:w.width])

    def test_bar_only_grows_over_group(self):
        w = Window()
        w.start()
        sizes = [1_000_000, 150_000, 0, 63, 64, 500, 16384, 16385]
        w.files(len(sizes))
        seen = [0]
        for index, size in enumerate(sizes, 1):
            w.entry(index, len(sizes), f'f{index}')
            fills = w.file(size)
            begin = 64 * (index - 1) // len(sizes)
            end = 64 * index // len(sizes)
            self.assertTrue(all(begin <= f <= end for f in fills), (size, fills, begin, end))
            self.assertEqual(fills[-1], end, f'конец доли файла {size}')
            seen += fills
        self.assertEqual(seen, sorted(seen), 'полоса шла назад')
        self.assertEqual(seen[-1], 64)
        self.assertEqual([e for e in w.events if e[0] == 'PRWOW'], [('PRWOW', w.s('PBWND'))],
                         'окно открыто один раз на всю операцию')
        self.assertNotIn('RRESB', [e[0] for e in w.events[1:]], 'окно закрывалось посреди операции')

    def test_single_big_file_moves_by_bytes(self):
        w = Window()
        w.start()
        w.files(1)
        w.entry(1, 1, 'big.bin')
        fills = w.file(1 << 20)                              # 64 порции
        self.assertEqual(fills[:3], [0, 1, 2], 'доля — по уже переданным порциям')
        self.assertEqual(fills, sorted(fills))
        self.assertEqual(fills[-1], 64)

    def test_directory_advances_per_file(self):
        # Каталог из 10 файлов и файл за ним: всего 11, номер растёт на каждом
        # файле каталога, а не стоит на «1 of 2».
        w = Window()
        w.start()
        w.files(11)
        w.entry(1, 2, 'dir')
        self.assertEqual(w.line(COUNT), '<0000 of 0011>')
        fills = []
        for j in range(1, 11):
            fills += w.file(20000, in_dir_name=f'file{j:02}.bin')
            self.assertEqual(w.line(NAME), f'Copying file{j:02}.bin')
            self.assertEqual(w.line(COUNT), f'<{j:04} of 0011>')
            self.assertTrue(w.centered(NAME) and w.centered(COUNT))
            self.assertEqual(fills[-1], 64 * j // 11, 'файл кончился — полоса на конце его доли')
        self.assertEqual(fills, sorted(fills), 'полоса каталога шла назад')
        w.entry(2, 2, 'after.txt')
        self.assertEqual(w.line(COUNT), '<0010 of 0011>')
        after = w.file(1000)
        self.assertEqual(w.line(COUNT), '<0011 of 0011>')
        self.assertGreaterEqual(after[0], fills[-1])
        self.assertEqual(after[-1], 64)

    def test_delete_opens_one_window(self):
        w = Window()
        w.call(w.s('WCINI.DL_GO'), ix=w.s('F5WND'))
        self.assertEqual(w.events, [('RRESB', w.s('F5WND')), ('PRWOW', w.s('PBWND'))])
        self.assertEqual(w.line(TITLE), 'DELETE')
        self.assertEqual(w.line(NAME), 'Deleting started...')
        self.assertEqual(w.bar(), 0)
        # После F8 копирование снова «Copy» и «Copying started...».
        w.call(w.s('WCINI.CP_CLOSE'))
        w.call(w.s('WCINI.CP_GO'), ix=w.s('F5WND'))
        self.assertEqual((w.line(TITLE), w.line(NAME)), ('COPY', 'Copying started...'))

    def test_delete_group_of_files(self):
        # DELF → DL_DELFILE: n+1 до удаления, удалён — доля файла полная.
        w = Window()
        w.call(w.s('WCINI.DL_GO'), ix=w.s('F5WND'))
        w.files(3)
        record = w.s('WCINI.LOBU') + 4

        def delete(name):
            w.cpu.memory[record:record + len(name) + 2] = b'\x00' + name.encode() + b'\0'
            cpu = w.call(w.s('WCINI.DL_DELFILE'), hl=record)
            self.assertTrue(cpu.f & 0x40, 'удалено — Z, как у DL_DELETE')

        w.entry(1, 3, 's1.txt')
        self.assertEqual(w.line(NAME), 'Deleting started...', 'первый файл ищется')
        self.assertEqual((w.line(COUNT), w.bar()), ('<0000 of 0003>', 0))
        delete('s1.txt')
        self.assertEqual((w.line(NAME), w.line(COUNT), w.bar()), ('Deleting s1.txt', '<0001 of 0003>', 21))
        w.entry(2, 3, 's2.txt')
        self.assertEqual(w.line(NAME), 'Deleting s2.txt')
        self.assertTrue(w.centered(NAME))
        self.assertEqual(w.bar(), 64 * 1 // 3, 'первый удалён — полоса на начале второй доли')
        delete('s2.txt')
        w.entry(3, 3, 's3.txt')
        delete('s3.txt')
        self.assertEqual((w.line(NAME), w.line(COUNT), w.bar()), ('Deleting s3.txt', '<0003 of 0003>', 64))
        self.assertEqual(w.deleted, ['s1.txt', 's2.txt', 's3.txt'])
        # Отказ удаления — «UNKNOWN ERROR!!» и NZ, полоса на начале доли
        # (новая операция — новое окно, полоса с нуля).
        w.call(w.s('WCINI.DL_CLOSE'))
        w.call(w.s('WCINI.DL_GO'), ix=w.s('F5WND'))
        w.files(1)
        w.delfl_ok = False
        cpu = w.call(w.s('WCINI.DL_DELFILE'), hl=record)
        self.assertFalse(cpu.f & 0x40)
        self.assertEqual(w.events[-1], ('ERR0', 'UNKNOWN ERROR!!'))
        self.assertEqual((w.line(COUNT), w.bar()), ('<0001 of 0001>', 0))

    def test_delete_directory_steps_per_file(self):
        w = Window()
        w.call(w.s('WCINI.DL_GO'), ix=w.s('F5WND'))
        w.files(9)
        w.entry(1, 1, 'games')
        record = w.s('WCINI.LOBU') + 1024
        fills = []
        for j in range(1, 9):
            data = b'\x00' + f'file{j}.bin'.encode() + b'\0'
            w.cpu.memory[record:record + len(data)] = data
            cpu = w.call(w.s('WCINI.DL_INNER'), hl=record)
            self.assertFalse(cpu.f & 0x40, 'удалено — NZ, как у DELFL')
            self.assertEqual(w.line(NAME), f'Deleting file{j}.bin')
            self.assertEqual(w.line(COUNT), f'<{j:04} of 0009>')
            fills.append(w.bar())
            self.assertEqual(fills[-1], 64 * j // 9)
        self.assertEqual(w.deleted, [f'file{j}.bin' for j in range(1, 9)])
        self.assertEqual(fills, sorted(fills))
        # Отказ DELFL — Z, полоса — на начале доли девятого файла.
        w.delfl_ok = False
        cpu = w.call(w.s('WCINI.DL_INNER'), hl=record)
        self.assertTrue(cpu.f & 0x40)
        self.assertEqual(w.bar(), fills[-1])

    def test_huge_tree_stays_in_its_line(self):
        # Codex R20-01 (прежние ступени каталога): доля не выходит за 64,
        # полоса не пишет за TXTBU, счёт — не секунды. Теперь номер и число
        # файлов до 65535; в строке 2 больше 9999 — 9999.
        w = Window()
        w.start()
        w.entry(1, 1, 'tree')
        buffer = w.s('WCINI.TXTBU')
        guard = bytes(range(0x5FC0 - buffer - 64))   # за строкой полосы — до стека
        prev = 0
        for n in (4094, 4095, 9999, 10000, 65527, 65534, 65535):
            w.cpu.memory[buffer + 64:0x5FC0] = guard
            w.put16(w.s('WCINI.CP_FILES'), 65535)
            w.put16(w.s('WCINI.CP_NUM'), n)
            w.call(w.s('WCINI.CP_ENTRY'), a=40)
            self.assertLess(w.ticks, 20000, f'полоса при n={n} считалась {w.ticks} тактов')
            fill = w.bar()
            self.assertGreaterEqual(fill, prev, n)
            self.assertLessEqual(fill, 64)
            prev = fill
            w.call(w.s('WCINI.CP_COUNTER'))
            self.assertEqual(w.line(COUNT), f'<{min(n, 9999):04} of 9999>')
            self.assertEqual(bytes(w.cpu.memory[buffer + 64:0x5FC0]), guard,
                             f'запись за TXTBU при n={n}')

    def test_mul64div_never_exceeds_64(self):
        w = Window()
        for x, n in ((5, 0), (65535, 1), (65535, 7), (300, 299), (1000, 8)):
            w.call(w.s('WCFX.CP_MUL64DIV'), hl=x, de=n)
            self.assertLessEqual(w.cpu.a, 64, (x, n))
            self.assertLess(w.ticks, 20000, (x, n))

    def test_bar_at_4gb_does_not_go_back(self):
        # Codex R20-02: у файла #FFFFFFFF последняя порция переводила PBNOW
        # #FFFFC000 в 0 — полоса 63 → 0 → 64.
        w = Window()
        w.start()
        w.files(1)
        w.entry(1, 1, 'huge.img')
        w.call(w.s('WCINI.CP_FILE'), a=3, hl=0)
        divisor = 0xFFFFFFFF >> 6
        w.put16(w.s('WCFX.PBSTL') + 1, divisor & 0xFFFF)
        w.put16(w.s('WCFX.PBSTH') + 1, divisor >> 16)
        w.put32(w.s('PBNOW'), 0xFFFF8000)
        fills = []
        for _ in range(2):
            w.call(w.s('WCFX.PBPR'))
            fills.append(w.bar())
        w.call(w.s('WCINI.CP_DONE'))
        fills.append(w.bar())
        self.assertEqual(fills, sorted(fills), fills)
        self.assertEqual(fills[-1], 64)
        pbnow = int.from_bytes(bytes(w.cpu.memory[w.s('PBNOW'):w.s('PBNOW') + 4]), 'little')
        self.assertEqual(pbnow, 0xFFFFFFFF, 'PBNOW — не дальше #FFFFFFFF')

    def test_close_completes_bar_only_on_success(self):
        # Codex R20-03: единственный (последний) каталог не доводил полосу
        # до конца. CPgo/DLgo: Z — все объекты пройдены, NZ — отказ/отмена.
        w = Window()
        w.start()
        w.files(2)                                   # второй файл каталога не дошёл
        w.entry(1, 1, 'dir')
        w.file(9000, in_dir_name='only.bin')
        self.assertLess(w.bar(), 64)
        w.call(w.s('WCINI.CP_CLOSE'), f=0x40)
        self.assertEqual(w.bar(), 64)
        self.assertEqual(w.events[-1], ('RRESB', w.s('PBWND')))
        w2 = Window()
        w2.start()
        w2.files(2)
        w2.entry(1, 1, 'dir')
        w2.file(9000, in_dir_name='only.bin')
        before = w2.bar()
        w2.call(w2.s('WCINI.CP_CLOSE'), f=0)
        self.assertEqual(w2.bar(), before, 'при отказе полоса не «дорисовывается»')

    def test_tree_counter_saturates(self):
        # Codex R21-01 (прежний счётчик каталога): на 65536-м файле номер
        # обнулялся бы — полоса назад. Номер и число файлов — не больше 65535.
        w = Window()
        w.start()
        w.files(65535)
        w.entry(1, 1, 'tree')
        w.put16(w.s('WCINI.CP_NUM'), 0xFFFE)
        record = w.s('WCINI.LOBU') + 1024
        w.cpu.memory[record:record + 7] = b'\x00f.bin\0'
        fills = []
        for _ in range(4):
            w.call(w.s('WCINI.DL_INNER'), hl=record)
            fills.append(w.bar())
        self.assertEqual(w.number('WCINI.CP_NUM'), 0xFFFF)
        self.assertEqual(fills, [64, 64, 64, 64])
        w.put16(w.s('WCINI.CP_FILES'), 0xFFFE)
        for _ in range(3):
            w.call(w.s('WCINI.CT_ONE'))
        self.assertEqual(w.number('WCINI.CP_FILES'), 0xFFFF)

    def test_delete_failure_is_reported_and_stops(self):
        # Codex R21-02: DELDIR не проверял отказ удаления каталога, DELF
        # останавливался молча. DL_DELETE: отказ — «UNKNOWN ERROR!!» и NZ.
        w = Window()
        record = w.s('WCINI.LOBU') + 4
        w.cpu.memory[record:record + 6] = b'\x10tree\0'
        w.delfl_ok = False
        cpu = w.call(w.s('WCINI.DL_DELETE'), hl=record)
        self.assertFalse(cpu.f & 0x40, 'отказ — NZ, F8 останавливается')
        self.assertEqual(w.events, [('ERR0', 'UNKNOWN ERROR!!')])
        w.events.clear()
        w.delfl_ok = True
        cpu = w.call(w.s('WCINI.DL_DELETE'), hl=record)
        self.assertTrue(cpu.f & 0x40)
        self.assertEqual(w.events, [])
        self.assertEqual(w.deleted, ['tree', 'tree'])

    def test_delete_close_does_not_claim_success(self):
        # Codex R21-02: «DIR is not empty!» не прерывает F8, и Z в конце не
        # значит, что удалено всё: DL_CLOSE полосу не дорисовывает.
        w = Window()
        w.call(w.s('WCINI.DL_GO'), ix=w.s('F5WND'))
        w.files(2)
        w.entry(1, 2, 'dir')
        before, writes = w.bar(), len(w.writes)
        w.call(w.s('WCINI.DL_CLOSE'), f=0x40)
        self.assertEqual((w.bar(), len(w.writes)), (before, writes))
        self.assertEqual(w.events[-1], ('RRESB', w.s('PBWND')))
        self.assertEqual(w.cpu.memory[w.s('WCINI.CP_OPEN')], 0)

    def test_small_file_bar_waits_for_transfer(self):
        # Codex R22-01: PBPR считал и начатую порцию — у файла в 100 байт
        # полоса была полной до передачи, в том числе когда она отказывала.
        w = Window()
        w.start()
        w.files(1)
        w.entry(1, 1, 'small.txt')
        w.call(w.s('WCINI.CP_FILE'), a=3, hl=0)
        w.put16(w.s('WCFX.PBSTL') + 1, 100 >> 6)
        w.put16(w.s('WCFX.PBSTH') + 1, 0)
        w.put32(w.s('PBNOW'), 0)
        w.call(w.s('WCFX.PBPR'))
        self.assertEqual(w.bar(), 0, 'до передачи единственной порции')
        w.call(w.s('WCINI.CP_DONE'))
        self.assertEqual(w.bar(), 64)

    def test_deldir_search_failure_is_reported(self):
        # Codex R22-02: поздний FENTRY в DELDIR (отказ чтения) уводил в DER0 —
        # F8 останавливался молча. Теперь «UNKNOWN ERROR!!» и NZ.
        w = Window()
        w.hooks[w.s('WCFX.SAVECD')] = w.ret
        def fentry():
            w.events.append(('FENTRY', w.text(w.cpu.hl + 1)))
            w.cpu.f = 0x40                               # Z — не найден
            w.ret()
        w.hooks[w.s('WCFX.FENTRY')] = fentry
        record = w.s('WCINI.LOBU') + 4
        w.cpu.memory[record:record + 6] = b'\x10tree\0'
        cpu = w.call(w.s('WCFX.DELDIR'))
        self.assertFalse(cpu.f & 0x40, 'F8 останавливается (NZ)')
        self.assertEqual(w.events, [('FENTRY', 'tree'), ('ERR0', 'UNKNOWN ERROR!!')])

    def test_file_share_waits_for_the_last_bytes(self):
        # Codex R23-02: перед последней порцией файла k·16384+1…63 байт доля
        # была ровно 64, у файла короче 64 байт (делитель 0) — 64 до передачи.
        # Теперь до конца передачи не больше 63, у короткого файла — 0.
        for size in (1, 63, 64, 65, 16383, 16384, 16385, 16447, 16448,
                     32769, 32831, 32832, 49153, 114751):
            with self.subTest(size=size):
                w = Window()
                w.start()
                w.files(1)
                w.entry(1, 1, 'f.bin')
                fills = w.file(size)
                chunks = -(-size // 16384)
                # PBPR: переданное / ⌊размер/64⌋ (до 64), CP_PART — не больше 63.
                expected = [min(63, k * 16384 // (size >> 6)) if size >= 64 else 0
                            for k in range(chunks)]
                self.assertEqual(fills[:-1], expected)
                self.assertEqual(fills[-1], 64)

    def test_group_is_not_full_before_the_last_bytes(self):
        # Последний объект группы с долей 63: общая полоса меньше 64 при
        # любом числе объектов (CP_TOTAL: начало доли + ширина·63/64).
        w = Window()
        w.start()
        for count in list(range(1, 41)) + [100, 1000, 65535]:
            w.put16(w.s('WCINI.CP_NUM'), count)
            w.put16(w.s('WCINI.CP_FILES'), count)
            w.call(w.s('WCINI.CP_ENTRY'), a=63)
            self.assertLess(w.bar(), 64, count)

    def test_part_limits_share(self):
        w = Window()
        w.start()
        w.files(1)
        w.entry(1, 1, 'f.bin')
        w.call(w.s('WCINI.CP_FILE'), a=3, hl=0)
        for low, high, share, expected in ((0, 0, 64, 0), (1, 0, 64, 63), (0, 1, 64, 63),
                                           (5, 0, 17, 17), (0, 0, 0, 0), (7, 0, 63, 63)):
            w.put16(w.s('WCFX.PBSTL') + 1, low)
            w.put16(w.s('WCFX.PBSTH') + 1, high)
            w.cpu.memory[w.s('WCINI.CP_BAR')] = 0            # каждый случай — с пустой полосы
            w.call(w.s('WCINI.CP_PART'), a=share)
            self.assertEqual(w.bar(), expected, (low, high, share))

    def test_bar_never_goes_back(self):
        # Codex R37-2: после 65535-го файла (n насыщен) начало следующего
        # рисовало долю 65535-го — 63 после полной 64. Полоса только растёт;
        # новое окно начинает её с нуля.
        w = Window()
        w.start()
        w.files(65535)
        w.put16(w.s('WCINI.CP_NUM'), 65534)
        w.entry(1, 1, 'tree')
        fills = w.file(100, in_dir_name='last.bin')          # файл 65535: до 64
        fills += w.file(100, in_dir_name='more.bin')         # за пределом счёта
        self.assertEqual(fills, sorted(fills), fills)
        self.assertEqual(fills[-1], 64)
        w.call(w.s('WCINI.CP_DRAW'), a=10)
        self.assertEqual(w.bar(), 64, 'CP_DRAW меньше нарисованного — полоса та же')
        w.call(w.s('WCINI.CP_CLOSE'))
        w.start()
        self.assertEqual(w.bar(), 0, 'новое окно — полоса с нуля')

    def test_unknown_total(self):
        # Счёт брошен (M=0): «of ????», полоса пустая, номер растёт.
        w = Window()
        w.start()
        w.entry(1, 1, 'dir')
        self.assertEqual(w.line(COUNT), '<0000 of ????>')
        w.file(1000, in_dir_name='a.bin')
        self.assertEqual((w.line(COUNT), w.bar()), ('<0001 of ????>', 0))
        self.assertTrue(w.centered(COUNT))

    def test_arithmetic(self):
        w = Window()
        rng = random.Random(26)
        for _ in range(300):
            n = rng.choice([1, 2, 3, 7, 64, 65, 1000, 65535, rng.randint(1, 65535)])
            x = rng.randint(0, n)
            w.call(w.s('WCFX.CP_MUL64DIV'), hl=x, de=n)
            self.assertEqual(w.cpu.a, 64 * x // n, (x, n))
        for a in (0, 1, 7, 32, 64):
            for e in (0, 1, 33, 64):
                w.call(w.s('WCINI.CP_SCALE'), a=a, de=e)
                self.assertEqual(w.cpu.a, a * e // 64, (a, e))


class Tree(Window):
    """Окно WC с переключением окна #0000: FEP2 — страница ФС (#05), копия
    для перечисления F5/F8 — #F3 (CLPG)."""

    ORIGINAL, CLONE = 0x05, 0xF3

    def __init__(self):
        super().__init__()
        self.banks = {self.ORIGINAL: bytearray(0x4000), self.CLONE: bytearray(0x4000)}
        self.page = self.ORIGINAL
        self.cpu.set_output_callback(self.output)
        self.cpu.memory[self.s('WCFX.FEP2')] = self.ORIGINAL
        self.abt = self.s('WDOS.ABT')
        self.listing = []                   # ответы NXTETY2/NXTETY: 'Z' или имя
        self.calls = []
        self.hooks[self.s('WCFX.NXTETY2')] = self.nxtety
        self.hooks[self.s('WCFX.NXTETY')] = self.nxtety
        for name in ('WCFX.LOADCD', 'WCFX.SAVECD', 'WCFX.GDIR', 'WCFX.CDIREX'):
            self.hooks[self.s(name)] = lambda name=name: self.called(name)
        # Шлюз расширения: здесь его зовёт только DL_ENTER/CP_ENTER (проверка
        # каталога ID_TREE_CHILD); ответ задаёт тест, сама проверка — в
        # test_crash_paths.TreeChild на настоящем ядре.
        self.child_ok = True
        self.hooks[self.s('WDOS.EXTENSION_GATE')] = self.gate
        # FILE_CHAIN порциями (Codex R28-02): столько раз ответ «порция»
        # (CF=1, A=1), потом итог; между ними WCFX.FC_LOOP — EI:HALT.
        self.chain_pauses = 0
        self.hooks[self.s('WCFX.FC_WAIT') + 1] = self.halt

    def gate(self):
        cpu = self.cpu
        ret = cpu.memory[cpu.sp] | cpu.memory[cpu.sp + 1] << 8
        ident = cpu.memory[ret]
        self.put16(cpu.sp, ret + 1)
        if ident == self.s('WDOS_EXT.ID_FILE_CHAIN'):     # CP_SOURCE: HL → кластер, DE → размер
            self.events.append(('FILE_CHAIN', cpu.hl, cpu.de, cpu.a))
            if self.chain_pauses:
                self.chain_pauses -= 1
                cpu.a, cpu.f = 1, 0x41
                self.ret()
                return
        else:
            assert ident == self.s('WDOS_EXT.ID_TREE_CHILD'), ident
            self.events.append(('TREE_CHILD', cpu.de << 16 | cpu.hl, self.page))
        cpu.f = 0x40 if self.child_ok else 0
        self.ret()

    def halt(self):
        # HALT в WCFX.FC_LOOP: кадр IM2 между порциями. Прерывания обязаны быть
        # включены — иначе HALT навсегда; сам кадр здесь не моделируется.
        self.events.append(('HALT', bytes(self.cpu._Z80State__iff1)[0]))
        self.cpu.pc += 1

    def output(self, port, value):
        if port != 0x10AF:
            return
        mem = self.cpu.memory
        self.banks[self.page][:] = mem[0:0x4000]
        mem[0:0x4000] = self.banks.setdefault(value, bytearray(0x4000))
        self.page = value

    def map(self, page):
        self.output(0x10AF, page)

    def set_abt(self, page, value):
        if page == self.page:
            self.cpu.memory[self.abt] = value
        else:
            self.banks[page][self.abt] = value

    def called(self, name):
        self.events.append((name.split('.')[-1], self.page))
        self.ret()

    def nxtety(self):
        cpu = self.cpu
        self.calls.append((cpu.a, cpu.de, self.page))
        answer = self.listing.pop(0) if self.listing else 'Z'
        if answer == 'Z':
            cpu.f = 0x40
        else:
            data = b'\x20' + answer.encode('cp866') + b'\0'   # признак и имя
            cpu.memory[cpu.de:cpu.de + len(data)] = data
            cpu.de += len(data)
            cpu.f = 0
        self.ret()

    def err0(self):
        self.events.append(('ERR0', self.text(self.cpu.hl).replace('\x0e', ''), self.page))
        self.ret()

    def stop_at(self, name):
        """Переход в обработчик ошибки (DTRER0/ERMAIN): записать B и выйти."""
        def stop():
            self.events.append((name.split('.')[-1], self.cpu.b))
            self.cpu.pc = STOP
        self.hooks[self.s(name)] = stop


class TreeReadFailure(unittest.TestCase):
    """Codex R23-01: при F8 отказ чтения каталога внутри дерева давал Z, как
    конец: подкаталог удалялся с непройденными файлами, их цепочки терялись
    без сообщения. F5 так же молча копировал дерево не целиком. Теперь отказ
    — «UNKNOWN ERROR!!» и выход с ошибкой (B=255: сообщение уже показано)."""

    def test_next_tells_failure_from_end(self):
        for entry, target in (('WCINI.DL_NEXT', 'WCFX.DTRER0'), ('WCINI.CP_NEXT', 'WCFX.ERMAIN')):
            for clone_abt, original_abt, answer, failed in (
                    (1, 0, 'Z', True),              # отказ в копии — виден до CLONOFF
                    (0, 1, 'Z', False),             # ABT страницы ФС не при чём
                    (0, 0, 'Z', False),             # настоящий конец
                    (1, 0, 'x.bin', False)):        # запись — не отказ
                with self.subTest(entry=entry, clone_abt=clone_abt, original_abt=original_abt,
                                  answer=answer):
                    w = Tree()
                    w.stop_at(target)
                    w.map(w.CLONE)                  # CLPG
                    w.set_abt(w.CLONE, clone_abt)
                    w.set_abt(w.ORIGINAL, original_abt)
                    w.listing = [answer]
                    cpu = w.call(w.s(entry), a=1, de=0xB400)
                    self.assertEqual(w.calls, [(1, 0xB400, w.CLONE)], 'маска и буфер NXTETY2')
                    self.assertEqual(w.page, w.ORIGINAL, 'CLONOFF не вызван')
                    if failed:
                        self.assertEqual(w.events, [('ERR0', 'UNKNOWN ERROR!!', w.ORIGINAL),
                                                    (target.split('.')[-1], 255)])
                    else:
                        self.assertEqual(w.events, [])
                        self.assertEqual(bool(cpu.f & 0x40), answer == 'Z')

    def test_up_checks_subdir_listing(self):
        w = Tree()
        w.stop_at('WCFX.DTRER0')
        w.set_abt(w.ORIGINAL, 1)
        w.call(w.s('WCINI.DL_UP'))
        self.assertEqual(w.events, [('ERR0', 'UNKNOWN ERROR!!', w.ORIGINAL), ('DTRER0', 255)])
        w = Tree()
        cpu = w.call(w.s('WCINI.DL_UP'))
        self.assertEqual((w.events, cpu.hl), ([], w.s('UPDIR')))

    def test_deldir_emptiness_read_failure(self):
        for entry, abt, events, deleted, stops in (
                ('WCINI.DL_EMPTY', 1, [('LOADCD', 5), ('ERR0', 'UNKNOWN ERROR!!', 5)], [], True),
                ('WCINI.DL_EMPTY', 0, [('LOADCD', 5)], ['tree'], False),
                ('WCINI.DL_NED', 1, [('LOADCD', 5), ('ERR0', 'UNKNOWN ERROR!!', 5)], [], True),
                ('WCINI.DL_NED', 0, [('LOADCD', 5), ('ERR0', 'DIR is not empty!', 5)], [], False)):
            with self.subTest(entry=entry, abt=abt):
                w = Tree()
                record = w.s('WCINI.LOBU') + 4
                w.cpu.memory[record:record + 6] = b'\x10tree\0'
                w.set_abt(w.ORIGINAL, abt)
                cpu = w.call(w.s(entry))
                self.assertEqual(w.events, events)
                self.assertEqual(w.deleted, deleted)
                self.assertEqual(not cpu.f & 0x40, stops, 'NZ — F8 останавливается')

    def test_dfiles_stops_on_read_failure(self):
        # Настоящий DFILES: отказ чтения в копии — ни одного DELFL, сообщение
        # одно, DTRER0 восстанавливает каталог, выход NZ (F8 остановлен).
        w = Tree()
        w.set_abt(w.CLONE, 1)
        cpu = w.call(w.s('WCFX.DFILES'))
        self.assertEqual(w.calls, [(1, w.s('WCINI.LOBU') + 1024, w.CLONE)])
        self.assertEqual(w.events, [('ERR0', 'UNKNOWN ERROR!!', w.ORIGINAL), ('LOADCD', w.ORIGINAL)])
        self.assertEqual(w.deleted, [])
        self.assertFalse(cpu.f & 0x40)
        self.assertEqual(cpu.sp, STACK + 2, 'стек')

    def test_dfiles_file_failure_messages(self):
        # Codex R29-02: F8 дерева, файл внутри — DELFL отказал с A=0 (запись
        # убрана, а цепочку не освободить: DLSG отверг ссылку, например первый
        # кластер корня) — окно писало «File not found». Теперь «UNKNOWN
        # ERROR!!»; так же A=8 при ABT≠0 — поиск не прочитал каталог (Codex
        # R30-01). Записи нет (A=8, ABT=0) — «File not found», как прежде.
        # Сообщение одно, DTRER0 восстанавливает каталог, F8 останавливается.
        unknown, missing = ('UNKNOWN ERROR!!', ('ERR0', 'LOADCD')), ('File not found', ('LOADCD', 'ERR0'))
        for a, abt, (text, order) in ((0, 0, unknown), (0, 0xFE, unknown), (8, 1, unknown),
                                      (8, 0xFF, unknown), (8, 0, missing)):
            with self.subTest(a=a, abt=abt):
                w = Tree()
                w.listing = ['a.bin', 'b.bin', 'Z']
                w.delfl_ok, w.delfl_a, w.delfl_abt = False, a, abt
                cpu = w.call(w.s('WCFX.DFILES'))
                self.assertEqual(w.deleted, ['a.bin'])
                self.assertEqual([e[0] for e in w.events if e[0] in ('ERR0', 'LOADCD')], list(order))
                self.assertEqual([e[1] for e in w.events if e[0] == 'ERR0'], [text])
                self.assertFalse(cpu.f & 0x40, 'F8 останавливается')
                self.assertEqual(cpu.sp, STACK + 2, 'стек')

    def test_dfiles_end_goes_to_subdirs(self):
        # Настоящий конец файлов: дальше — подкаталоги (DDIRZ, RECBUF_DEPTH).
        w = Tree()
        w.stop_at('WDOS.RECBUF_DEPTH')
        w.listing = ['a.bin', 'Z']
        w.call(w.s('WCFX.DFILES'))
        self.assertEqual(w.deleted, ['a.bin'])
        self.assertEqual(w.events[-1], ('RECBUF_DEPTH', w.cpu.b))
        self.assertNotIn('ERR0', [e[0] for e in w.events])

    def test_nodirs_stops_on_read_failure(self):
        # DDIRS: «.», «..» и подкаталоги перечисляются в странице ФС; Z с
        # ABT≠0 — не «подкаталогов нет» (прежде шли наверх и удаляли каталог
        # вместе с непройденными подкаталогами).
        w = Tree()
        w.set_abt(w.ORIGINAL, 1)
        cpu = w.call(w.s('WCFX.DDIRS'))
        self.assertEqual(len(w.calls), 3)
        self.assertEqual(w.events, [('ERR0', 'UNKNOWN ERROR!!', w.ORIGINAL), ('LOADCD', w.ORIGINAL)])
        self.assertFalse(cpu.f & 0x40)
        self.assertEqual(cpu.sp, STACK + 2)
        # Без отказа — наверх по «..», как прежде.
        w = Tree()
        names = []
        def fentry():
            names.append(w.text(w.cpu.hl + 1))
            w.cpu.pc = STOP
        w.hooks[w.s('WCFX.FENTRY')] = fentry
        w.call(w.s('WCFX.DDIRS'))
        self.assertEqual((names, w.events), (['..'], []))

    def test_deldir_does_not_delete_after_read_failure(self):
        for listing, abt, deleted, message, stops in (
                (['.', '..'], 1, [], 'UNKNOWN ERROR!!', True),      # третьей нет — отказ
                (['.', '..'], 0, ['tree'], None, False),            # пуст — удалить
                ([], 1, [], 'UNKNOWN ERROR!!', True),               # «.» не прочиталась
                (['.', '..', 'x'], 0, [], 'DIR is not empty!', False)):
            with self.subTest(listing=listing, abt=abt):
                w = Tree()
                record = w.s('WCINI.LOBU') + 4
                w.cpu.memory[record:record + 6] = b'\x10tree\0'
                w.hooks[w.s('WCFX.FENTRY')] = lambda: (setattr(w.cpu, 'f', 0), w.ret())
                w.listing = list(listing) + ['Z']
                w.set_abt(w.ORIGINAL, abt)
                cpu = w.call(w.s('WCFX.DELDIR'))
                self.assertEqual(w.deleted, deleted)
                errors = [e[1] for e in w.events if e[0] == 'ERR0']
                self.assertEqual(errors, [message] if message else [])
                self.assertEqual([e[0] for e in w.events].count('LOADCD'), 1, 'каталог панели')
                self.assertEqual(not cpu.f & 0x40, stops)

    def test_copy_tree_stops_on_read_failure(self):
        # IDXLOOP (F5): отказ перечисления — сообщение и ERMAIN (CDIREX), а не
        # «каталог кончился» (DCUPP) с молча неполной копией.
        w = Tree()
        stack = 0xFE00                      # стек индексов (в WC — страница в #C000)
        w.put16(w.s('WCFX.DDIRS') + 1, stack)
        w.put16(stack, 0)
        w.set_abt(w.CLONE, 1)
        cpu = w.call(w.s('WCFX.IDXLOOP'))
        self.assertEqual(w.calls, [(0, w.s('WCINI.LOBU') + 4, w.CLONE)])
        self.assertEqual(w.events, [('ERR0', 'UNKNOWN ERROR!!', w.ORIGINAL), ('CDIREX', w.ORIGINAL)])
        self.assertFalse(cpu.f & 0x40)
        self.assertEqual(cpu.sp, STACK + 2)

    @staticmethod
    def found(w, cluster, present=True):
        """FENTRY: запись найдена (NZ), её кластер — в #7F30, как у MD20."""
        def fentry():
            w.events.append(('FENTRY', w.text(w.cpu.hl + 1)))
            w.cpu.memory[0x7F30:0x7F34] = cluster.to_bytes(4, 'little')
            w.cpu.f = 0 if present else 0x40
            w.ret()
        w.hooks[w.s('WCFX.FENTRY')] = fentry

    def test_enter_checks_the_directory(self):
        # 2026-09-27: испорченная запись каталога (кластер 0 — GLSTCAT
        # понимает его как корень; кластер корня или чужого каталога) вела
        # обход не туда: F8 одного такого каталога удалял неотмеченные файлы
        # корня. Перед входом — ID_TREE_CHILD («.» и «..»); не настоящий —
        # отказ. FEP2 чужой: на первом входе копии страницы ещё нет, CLONOFF
        # здесь нельзя.
        for entry, target in (('WCINI.DL_ENTER', 'WCFX.DTRER0'), ('WCINI.CP_ENTER', 'WCFX.ERMAIN')):
            for present, child_ok, events, zero_flag in (
                    (True, False, [('TREE_CHILD', 0x12345, 5), ('ERR0', 'UNKNOWN ERROR!!', 5),
                                   (target.split('.')[-1], 255)], None),
                    (True, True, [('TREE_CHILD', 0x12345, 5)], False),
                    (False, True, [], True)):
                with self.subTest(entry=entry, present=present, child_ok=child_ok):
                    w = Tree()
                    w.cpu.memory[w.s('WCFX.FEP2')] = 0x77
                    w.child_ok = child_ok
                    w.stop_at(target)
                    self.found(w, 0x12345, present)
                    record = w.s('WCINI.LOBU') + 4
                    w.cpu.memory[record:record + 5] = b'\x10bad\0'
                    cpu = w.call(w.s(entry), hl=record)
                    self.assertEqual(w.events, [('FENTRY', 'bad')] + events)
                    self.assertEqual(w.page, w.ORIGINAL, 'окно #0000 переключено')
                    if zero_flag is not None:
                        self.assertEqual(bool(cpu.f & 0x40), zero_flag)

    def test_copy_checks_the_source_chain(self):
        # 2026-09-27: у источника кластер помечен в FAT свободным — MKFILE отдавал
        # его копии, цепочки сцеплялись, часть копии — чужие байты, без
        # сообщения. CP_SOURCE (вместо GFILE в COPYFD): ID_FILE_CHAIN; порча —
        # «UNKNOWN ERROR!!» и NZ из COPYF, поток источника не открывается.
        stub = 0xFE00                                        # «COPYFD»: CALL CP_SOURCE
        for ok in (True, False):
            with self.subTest(ok=ok):
                w = Tree()
                w.child_ok = ok
                w.hooks[w.s('WCFX.GFILE')] = lambda: w.called('WCFX.GFILE')
                source = w.s('WCINI.CP_SOURCE')
                w.cpu.memory[stub:stub + 5] = bytes([0xCD, source & 0xFF, source >> 8, 0xAF, 0xC9])
                cpu = w.call(stub)                           # за CALL: XOR A (Z), RET
                lobu = w.s('WCINI.LOBU')
                chain = [('FILE_CHAIN', 0x7F30, lobu + 1, 0)]
                self.assertEqual(cpu.sp, STACK + 2, 'стек')
                if ok:
                    self.assertEqual(w.events, chain + [('GFILE', 5)])
                    self.assertTrue(cpu.f & 0x40, 'COPYFD продолжился')
                else:
                    self.assertEqual(w.events, chain + [('ERR0', 'UNKNOWN ERROR!!', 5)])
                    self.assertFalse(cpu.f & 0x40, 'F5 файла останавливается (NZ из COPYF)')

    def test_source_check_in_portions(self):
        # Codex R28-02: FILE_CHAIN держал прерывания выключенными весь обход.
        # Теперь порции: CF=1, A=1 — EI:HALT (кадр IM2) и продолжение с A≠0;
        # в конце — GFILE или сообщение порчи, стек цел.
        stub = 0xFE00
        for ok in (True, False):
            with self.subTest(ok=ok):
                w = Tree()
                w.child_ok, w.chain_pauses = ok, 2
                w.hooks[w.s('WCFX.GFILE')] = lambda: w.called('WCFX.GFILE')
                source = w.s('WCINI.CP_SOURCE')
                w.cpu.memory[stub:stub + 5] = bytes([0xCD, source & 0xFF, source >> 8, 0xAF, 0xC9])
                cpu = w.call(stub)
                lobu = w.s('WCINI.LOBU')
                first, more = ('FILE_CHAIN', 0x7F30, lobu + 1, 0), ('FILE_CHAIN', 0x7F30, lobu + 1, 1)
                portions = [first, ('HALT', 1), more, ('HALT', 1), more]
                self.assertEqual(cpu.sp, STACK + 2, 'стек')
                if ok:
                    self.assertEqual(w.events, portions + [('GFILE', 5)])
                    self.assertTrue(cpu.f & 0x40)
                else:
                    self.assertEqual(w.events, portions + [('ERR0', 'UNKNOWN ERROR!!', 5)])
                    self.assertFalse(cpu.f & 0x40)

    def test_zanovo_does_not_enter_a_broken_directory(self):
        # Настоящие ZANOVO (F8) и ZANOVOC (F5): GDIR не вызывается, сообщение
        # одно, выход NZ через DTRER0/ERMAIN.
        for entry, cleanup in (('WCFX.ZANOVO', 'LOADCD'), ('WCFX.ZANOVOC', 'CDIREX')):
            with self.subTest(entry=entry):
                w = Tree()
                w.child_ok = False
                self.found(w, 0)
                record = w.s('WCINI.LOBU') + 4
                w.cpu.memory[record:record + 5] = b'\x10bad\0'
                cpu = w.call(w.s(entry), hl=record if entry == 'WCFX.ZANOVO' else 0xFE00)
                self.assertEqual(w.events, [('FENTRY', 'bad'), ('TREE_CHILD', 0, 5),
                                            ('ERR0', 'UNKNOWN ERROR!!', 5), (cleanup, 5)])
                self.assertFalse(cpu.f & 0x40)
                self.assertEqual(cpu.sp, STACK + 2)

    def test_enter_search_failure_is_not_missing(self):
        # Codex R31-01: FENTRY не нашёл каталог дерева (Z). ABT=0 страницы,
        # где искали, — имени нет: Z, у ZANOVO/ZANOVOC «DIR not found (src)»
        # (B=1), как прежде. ABT≠0 — поиск не прочитал каталог: «UNKNOWN
        # ERROR!!» и обработчик с B=255, проверки каталога нет. ABT копии для
        # перечисления (#F3) не при чём; CLONOFF нет (FEP2 чужой).
        for entry, target in (('WCINI.DL_ENTER', 'WCFX.DTRER0'), ('WCINI.CP_ENTER', 'WCFX.ERMAIN')):
            for abt in (0, 1, 0xFE):
                with self.subTest(entry=entry, abt=abt):
                    w = Tree()
                    w.cpu.memory[w.s('WCFX.FEP2')] = 0x77
                    w.stop_at(target)
                    self.found(w, 0x12345, present=False)
                    w.set_abt(w.ORIGINAL, abt)
                    w.set_abt(w.CLONE, 0 if abt else 1)
                    record = w.s('WCINI.LOBU') + 4
                    w.cpu.memory[record:record + 5] = b'\x10bad\0'
                    cpu = w.call(w.s(entry), hl=record)
                    self.assertEqual(w.page, w.ORIGINAL, 'окно #0000 переключено')
                    if abt:
                        self.assertEqual(w.events, [('FENTRY', 'bad'), ('ERR0', 'UNKNOWN ERROR!!', 5),
                                                    (target.split('.')[-1], 255)])
                        self.assertEqual(cpu.sp, STACK + 2, 'обработчик — вместо возврата')
                    else:
                        self.assertEqual(w.events, [('FENTRY', 'bad')])
                        self.assertTrue(cpu.f & 0x40, 'Z — «DIR not found (src)» у вызывающего')
                        self.assertEqual(cpu.sp, STACK + 2)

    def test_subdir_delete_failure_messages(self):
        # Codex R31-01: F8 дерева, опустевший подкаталог — настоящие
        # DDIRS_DELETE → DL_DIRDEL → DIRTREM_DELETE (MD20), подменён DELFL.
        # Записи нет (A=8, ABT=0) — DTRER0 с B=3, «DIR not found (dst)», как
        # прежде. Поиск не прочитал каталог (A=8, ABT≠0), отказ записи или
        # освобождения цепочки (A=0) — «UNKNOWN ERROR!!» и DTRER0 с B=255
        # (сообщение уже показано). Удалён — дальше DDIRS. Стек у обработчика
        # — как у прежнего CALL @DIRTREM_DELETE.
        unknown = [('ERR0', 'UNKNOWN ERROR!!', 5), ('DTRER0', 255)]
        for ok, a, abt, events in ((True, 0, 0, [('DDIRS', 3)]), (False, 8, 0, [('DTRER0', 3)]),
                                   (False, 8, 1, unknown), (False, 8, 0xFF, unknown),
                                   (False, 0, 0, unknown), (False, 0, 0xFE, unknown)):
            with self.subTest(ok=ok, a=a, abt=abt):
                w = Tree()
                w.stop_at('WCFX.DTRER0')
                w.stop_at('WCFX.DDIRS')
                w.delfl_ok, w.delfl_a, w.delfl_abt = ok, a, abt
                record = 0xFE00                     # запись в стеке индексов (в WC — #C000)
                w.cpu.memory[record:record + 6] = b'\x10tree\0'
                cpu = w.call(w.s('WCFX.DDIRS_DELETE'), hl=record)
                self.assertEqual(w.deleted, ['tree'])
                self.assertEqual(w.events, events)
                self.assertEqual(cpu.sp, STACK)


class Panel(Window):
    """Панель в памяти, как её читает MD20 (L6011_35): индекс в странице #0B,
    записи — в #0C, обе в окне #C000 по порту #13AF; IX — WINDOW. Элемент
    индекса — [относительная страница, адрес записи, длина], адрес 0 — конец.
    Запись: +0 отметка, +4..+7 первый кластер, +16 признак (0 — каталог), +17
    имя. Шлюз расширения подменён: ALIAS_RESET, ALIAS_ADD, ALIAS_SCAN
    записываются, ответы — из answers ('Z', 'NZ', 'CF')."""

    INDEX, DATA = 0x0B, 0x0C

    def __init__(self, entries):
        super().__init__()
        self.mapped = 0x03
        self.banks = {0x03: bytearray(self.cpu.memory[0xC000:0x10000])}
        index, data, at = bytearray(0x4000), bytearray(0x4000), 0x100
        for n, (mark, cluster, kind, name) in enumerate(entries):
            record = (bytes([mark]) + b'BIN' + cluster.to_bytes(4, 'little') + bytes(8)
                      + bytes([kind]) + name.encode('cp866') + b'\0')
            data[at:at + len(record)] = record
            address = 0xC000 + at
            index[4 * n:4 * n + 4] = bytes([1, address & 0xFF, address >> 8, len(record)])
            at += len(record)
        self.banks[self.INDEX], self.banks[self.DATA] = index, data
        self.cpu.set_output_callback(self.output)
        self.cpu.set_input_callback(lambda port: self.mapped if port == 0x13AF else 0xFF)
        self.cpu.memory[self.s('WINDOW') + 0x19] = 0      # левая панель: страницы #0B..
        self.answers = {'ADD': [], 'SCAN': []}
        self.ids = {self.s('WDOS_EXT.ID_ALIAS_RESET'): 'RESET',
                    self.s('WDOS_EXT.ID_ALIAS_ADD'): 'ADD',
                    self.s('WDOS_EXT.ID_ALIAS_SCAN'): 'SCAN',
                    self.s('WDOS_EXT.ID_TREE_CHILD'): 'CHILD'}
        self.hooks[self.s('WDOS.EXTENSION_GATE')] = self.gate
        self.hooks[self.s('WCINI.DL_SCAN_PART') + 6] = self.halt   # CALL, DB, RET NC, EI — HALT
        # Дерево каталогов для CP_COUNT (CT_TREE): каталог → записи [(имя,
        # каталог?)]; «.» и «..» перечисление даёт первыми. Текущий каталог и
        # позиция перечисления (сбрасывает CLONEZ) — как у WDOS; события — в fs.
        self.tree, self.cwd, self.pos, self.found_dir, self.fs = {}, '', 0, None, []
        self.child_ok, self.fail_in, self.saved = True, None, None
        for name, hook in (('WCFX.FENTRY', self.fentry), ('WCFX.GDIR', self.gdir),
                           ('WCFX.NXTETY2', self.nxtety2), ('WCFX.SAVECD', self.savecd),
                           ('WCFX.LOADCD', self.loadcd), ('WCFX.CLONEZ', self.clonez),
                           ('WCFX.CLPG', self.clpg), ('WCFX.CLONOFF', self.clonoff)):
            self.hooks[self.s(name)] = hook

    def listing(self, path):
        entries = self.tree.get(path, [])
        return ([('.', True), ('..', True)] if path else []) + entries

    def fentry(self):
        name = self.text(self.cpu.hl + 1)
        self.fs.append(('FENTRY', self.cwd, name))
        if name == '..':
            target = self.cwd.rsplit('/', 1)[0] if '/' in self.cwd else ''
        else:
            target = (self.cwd + '/' if self.cwd else '') + name
        present = name == '..' or target in self.tree
        self.found_dir = target if present else None
        self.cpu.memory[0x7F30:0x7F34] = (0x1000 + len(target)).to_bytes(4, 'little')
        self.cpu.f = 0 if present else 0x40
        self.ret()

    def gdir(self):
        self.cwd = self.found_dir
        self.fs.append(('GDIR', self.cwd))
        self.ret()

    def clonez(self):
        self.pos = 0
        self.ret()

    def clpg(self):
        self.ret()

    def clonoff(self):
        self.ret()                                   # флаги — как есть

    def savecd(self):
        self.saved = self.cwd
        self.fs.append(('SAVECD', self.cwd))
        self.ret()

    def loadcd(self):
        self.cwd = self.saved
        self.fs.append(('LOADCD', self.cwd))
        self.ret()

    def nxtety2(self):
        cpu = self.cpu
        entries = self.listing(self.cwd)
        if self.fail_in == self.cwd and self.pos >= 2:
            cpu.memory[self.s('WDOS.ABT')] = 1            # отказ чтения — в копии страницы ФС
            cpu.f = 0x40
        elif self.pos < len(entries):
            name, is_dir = entries[self.pos]
            self.pos += 1
            data = bytes([0x10 if is_dir else 0x20]) + name.encode('cp866') + b'\0'
            cpu.memory[cpu.de:cpu.de + len(data)] = data
            cpu.de += len(data)
            cpu.f = 0
        else:
            cpu.f = 0x40
        self.ret()

    def output(self, port, value):
        if port != 0x13AF:
            return
        mem = self.cpu.memory
        self.banks[self.mapped][:] = mem[0xC000:0x10000]
        mem[0xC000:0x10000] = self.banks.setdefault(value, bytearray(0x4000))
        self.mapped = value

    def gate(self):
        cpu = self.cpu
        ret = cpu.memory[cpu.sp] | cpu.memory[cpu.sp + 1] << 8
        name = self.ids[cpu.memory[ret]]
        self.put16(cpu.sp, ret + 1)
        if name == 'CHILD':                          # CT_TREE: проверка подкаталога
            self.fs.append(('CHILD', cpu.de << 16 | cpu.hl))
            cpu.f = 0x40 if self.child_ok else 0
            self.ret()
            return
        answer = self.answers.get(name, [])
        answer = answer.pop(0) if answer else 'Z'
        if name == 'RESET':
            self.events.append(('RESET', cpu.a))
        elif name == 'ADD':
            self.events.append(('ADD', cpu.de << 16 | cpu.hl, cpu.a, cpu.ix))
        else:
            self.events.append(('SCAN', cpu.a))
        cpu.f = {'Z': 0x40, 'NZ': 0, 'CF': 0x01}[answer]
        if answer == 'CF':
            cpu.a = 1
        self.ret()

    def halt(self):
        self.events.append(('HALT', bytes(self.cpu._Z80State__iff1)[0]))
        self.cpu.pc += 1


class FileCount(unittest.TestCase):
    """Счёт файлов операции (2026-09-27): настоящие CP_COUNT и CT_TREE на
    панели Panel и дереве каталогов модели. Отмеченный файл — один, каталог —
    все файлы его дерева; после подъёма («..») каталог перечисляется заново до
    записи, с которой ушли вниз. Каталог панели — как был (SAVECD/LOADCD).
    Отказ чтения или испорченный подкаталог — счёт бросается (M=0), ABT
    сброшен: ошибку покажет сама операция."""

    ENTRIES = [(1, 100, 0x20, 'a.bin'), (0, 200, 0x20, 'b.bin'), (1, 300, 0, 'tree'),
               (0, 400, 0, 'other'), (1, 500, 0x20, 'c.bin')]
    TREE = {'tree': [('f1', False), ('sub1', True), ('f2', False), ('sub2', True), ('f3', False)],
            'tree/sub1': [('g1', False), ('deep', True)],
            'tree/sub1/deep': [('h1', False), ('h2', False)],
            'tree/sub2': [],
            'other': [('x', False), ('y', False)]}

    def count(self, tree=None, **options):
        w = Panel(self.ENTRIES)
        w.tree = dict(self.TREE if tree is None else tree)
        for key, value in options.items():
            setattr(w, key, value)
        window = w.s('WINDOW')
        cpu = w.call(w.s('WCINI.CP_COUNT'), ix=window, hl=0x1234)
        self.assertEqual((cpu.hl, bool(cpu.f & 0x40)), (0, True), 'выход: HL=0, Z')
        self.assertEqual((cpu.ix, cpu.sp), (window, STACK + 2))
        return w

    def test_files_of_marked_trees(self):
        w = self.count()
        # a.bin, c.bin и дерево tree: f1, f2, f3, g1, h1, h2.
        self.assertEqual((w.number('WCINI.CP_FILES'), w.number('WCINI.CP_NUM')), (8, 0))
        self.assertEqual(w.cwd, '', 'каталог панели восстановлен')
        self.assertEqual([e for e in w.fs if e[0] in ('SAVECD', 'LOADCD')],
                         [('SAVECD', ''), ('LOADCD', '')])
        visited = [e[1] for e in w.fs if e[0] == 'GDIR']
        self.assertEqual(visited, ['tree', 'tree/sub1', 'tree/sub1/deep', 'tree/sub1', 'tree',
                                   'tree/sub2', 'tree'], 'обход и подъёмы')
        self.assertTrue(all(e[0] != 'FENTRY' or e[2] != 'other' for e in w.fs),
                        'неотмеченный каталог не обходится')
        self.assertEqual(w.cpu.memory[w.s('WDOS.ABT')], 0)

    def test_read_failure_drops_the_count(self):
        w = self.count(fail_in='tree/sub1')
        self.assertEqual(w.number('WCINI.CP_FILES'), 0, 'счёт брошен')
        self.assertEqual(w.cwd, '', 'каталог панели восстановлен')
        self.assertEqual(w.cpu.memory[w.s('WDOS.ABT')], 0, 'ABT сброшен — ошибку покажет операция')
        self.assertEqual([e for e in w.events if e[0] == 'ERR0'], [], 'без сообщения')

    def test_broken_subdirectory_drops_the_count(self):
        w = self.count(child_ok=False)
        self.assertEqual(w.number('WCINI.CP_FILES'), 0)
        self.assertEqual([e[0] for e in w.fs][:3], ['SAVECD', 'FENTRY', 'CHILD'])
        self.assertNotIn('GDIR', [e[0] for e in w.fs], 'в испорченный каталог не входили')
        self.assertEqual(w.cwd, '')

    def test_missing_directory_drops_the_count(self):
        w = self.count(tree={})
        self.assertEqual(w.number('WCINI.CP_FILES'), 0)
        self.assertEqual(w.cwd, '')

    def test_empty_tree_and_files_only(self):
        w = self.count(tree={'tree': [('empty', True)], 'tree/empty': []})
        self.assertEqual(w.number('WCINI.CP_FILES'), 2, 'только a.bin и c.bin')

    def test_index_overflow_drops_the_count(self):
        # Codex R37-1: у каталога больше 65535 записей 16-битный индекс
        # перечисления переполнялся, и после подъёма из подкаталога пропуск
        # возвращался к «.» и «..» — бесконечный обход до начала F5/F8.
        # Переполнение — счёт брошен: CF=1, без перечисления, каталог панели
        # возвращён (LOADCD).
        w = Panel(self.ENTRIES)
        stack = bytearray(0x4000)
        stack[0:2] = (0xFFFF).to_bytes(2, 'little')          # индекс вершины — #FFFF
        w.banks[w.s('WCFX.TVBPG')] = stack
        w.put16(w.s('WCINI.CT_SP'), 0xC000)
        reads = []
        w.hooks[w.s('WCFX.NXTETY2')] = lambda: (reads.append(1), w.nxtety2())
        cpu = w.call(w.s('WCINI.CT_LOOP'), ix=w.s('WINDOW'))
        self.assertTrue(cpu.f & 0x01, 'счёт брошен (CF=1)')
        self.assertEqual(reads, [], 'после переполнения каталог не перечислялся')
        self.assertEqual([e[0] for e in w.fs], ['LOADCD'])

    def test_dl_alias_counts_after_the_check(self):
        # F8: счёт — только когда проверка DL_ALIAS прошла; выход Z и HL=0.
        w = Panel(self.ENTRIES)
        w.tree = dict(self.TREE)
        window = w.s('WINDOW')
        cpu = w.call(w.s('WCINI.DL_ALIAS'), ix=window)
        self.assertTrue(cpu.f & 0x40)
        self.assertEqual((cpu.hl, w.number('WCINI.CP_FILES')), (0, 8))
        w = Panel(self.ENTRIES)
        w.tree = dict(self.TREE)
        w.answers['SCAN'] = ['NZ']
        cpu = w.call(w.s('WCINI.DL_ALIAS'), ix=window)
        self.assertFalse(cpu.f & 0x40)
        self.assertEqual(w.fs, [], 'после нарушения дерево не обходится')


class DeleteAlias(unittest.TestCase):
    """F8 до удаления (Codex R27-04, частичная защита, 2026-09-27): настоящие
    WCINI.DL_ALIAS и WCFX.DLGO. Отмеченные записи панели — в ALIAS_ADD
    (первый кластер DE:HL, признак в A), затем ALIAS_SCAN порциями (между ними
    EI:HALT). Нарушение или отказ чтения — «UNKNOWN ERROR!!», F8 не удаляет
    ничего; таблица полна (CF) — проход, сброс и тот же объект снова."""

    ENTRIES = [(0, 100, 0x20, 'a.bin'), (1, 200, 0x20, 'b.bin'), (0, 0, 0, '..'),
               (1, 300, 0, 'tree'), (1, 0x12345678, 0x20, 'big.bin'), (0, 400, 0, 'other')]
    MARKED = [('ADD', 200, 0x20), ('ADD', 300, 0), ('ADD', 0x12345678, 0x20)]

    def run_alias(self, entries=None, **answers):
        w = Panel(self.ENTRIES if entries is None else entries)
        w.answers.update(answers)
        window = w.s('WINDOW')
        cpu = w.call(w.s('WCINI.DL_ALIAS'), ix=window)
        adds = [e[:3] for e in w.events if e[0] == 'ADD']
        self.assertTrue(all(e[3] == window for e in w.events if e[0] == 'ADD'), 'IX — панель')
        self.assertEqual(cpu.sp, STACK + 2, 'стек')
        self.assertEqual(cpu.ix, window)
        return w, cpu, adds

    def test_marked_entries_then_scan(self):
        w, cpu, adds = self.run_alias()
        self.assertEqual(adds, self.MARKED)
        self.assertEqual([e for e in w.events if e[0] != 'ADD'], [('RESET', 0), ('SCAN', 0)])
        self.assertTrue(cpu.f & 0x40, 'можно удалять')

    def test_violation_and_failures_stop_f8(self):
        for answers, adds, why in (({'SCAN': ['NZ']}, self.MARKED, 'нарушение'),
                                   ({'ADD': ['Z', 'NZ']}, self.MARKED[:2], 'FAT хвоста каталога')):
            with self.subTest(why=why):
                w, cpu, got = self.run_alias(**answers)
                self.assertEqual(got, adds)
                self.assertEqual([e for e in w.events if e[0] == 'ERR0'], [('ERR0', 'UNKNOWN ERROR!!')])
                self.assertFalse(cpu.f & 0x40, 'F8 не удаляет')
                if why == 'FAT хвоста каталога':
                    self.assertNotIn(('SCAN', 0), w.events)

    def test_full_table_is_flushed(self):
        w, cpu, adds = self.run_alias(ADD=['Z', 'CF'])
        self.assertEqual(adds, [self.MARKED[0], self.MARKED[1], self.MARKED[1], self.MARKED[2]])
        kinds = [e[0] for e in w.events]
        self.assertEqual(kinds, ['RESET', 'ADD', 'ADD', 'SCAN', 'RESET', 'ADD', 'ADD', 'SCAN'])
        resets = [e for e in w.events if e[0] == 'RESET']
        self.assertEqual(resets, [('RESET', 0), ('RESET', 1)], 'сброс между заходами — с A≠0')
        self.assertTrue(cpu.f & 0x40)
        w, cpu, adds = self.run_alias(ADD=['Z', 'CF'], SCAN=['NZ'])
        self.assertEqual(adds, self.MARKED[:2], 'после нарушения дальше не идёт')
        self.assertFalse(cpu.f & 0x40)

    def test_scan_in_portions(self):
        w, cpu, _ = self.run_alias(SCAN=['CF', 'CF', 'Z'])
        tail = [e for e in w.events if e[0] in ('SCAN', 'HALT')]
        self.assertEqual(tail, [('SCAN', 0), ('HALT', 1), ('SCAN', 1), ('HALT', 1), ('SCAN', 1)])
        self.assertTrue(cpu.f & 0x40)

    def test_nothing_marked(self):
        for entries in ([], [(0, 100, 0x20, 'a.bin')]):
            with self.subTest(entries=len(entries)):
                w, cpu, adds = self.run_alias(entries)
                self.assertEqual((adds, [e[0] for e in w.events]), ([], ['RESET', 'SCAN']))
                self.assertTrue(cpu.f & 0x40)

    def test_dlgo_deletes_nothing_on_violation(self):
        # Настоящий DLGO (как из DLDI: в стеке IX панели, IX — F5WND): отказ
        # DL_ALIAS — окно хода закрыто (DL_CLOSE), до GETen/DELF не дошло,
        # выход NZ (A=1), IX панели восстановлен, стек цел.
        for ok in (True, False):
            with self.subTest(ok=ok):
                w = Window()
                window, dlgo = w.s('WINDOW'), w.s('WCFX.DLGO')
                seen = []

                def alias():
                    seen.append(('DL_ALIAS', w.cpu.ix))
                    w.cpu.f = 0x40 if ok else 0
                    w.cpu.hl = 0x5A5A
                    w.ret()

                def geten():
                    seen.append(('GETen', w.cpu.hl))
                    w.cpu.hl = 0                        # конец списка
                    w.ret()
                w.hooks[w.s('WCINI.DL_ALIAS')] = alias
                w.hooks[w.s('GETen')] = geten
                stub = 0xFE00                           # PUSH IX; LD IX,F5WND; JP DLGO
                f5 = w.s('F5WND')
                w.cpu.memory[stub:stub + 9] = bytes([0xDD, 0xE5, 0xDD, 0x21, f5 & 0xFF, f5 >> 8,
                                                     0xC3, dlgo & 0xFF, dlgo >> 8])
                cpu = w.call(stub, ix=window)
                self.assertEqual(seen, [('DL_ALIAS', window)] + ([('GETen', 0)] if ok else []))
                self.assertEqual(w.events[-1], ('RRESB', w.s('PBWND')), 'окно хода закрыто')
                self.assertEqual((cpu.a, bool(cpu.f & 0x40)), (1, False))
                self.assertEqual((cpu.ix, cpu.sp), (window, STACK + 2))


if __name__ == '__main__':
    unittest.main(verbosity=2)
