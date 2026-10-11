# Claude - 2026-10-11 - begin
"""Вынутая загрузочная карта SD-ZC (2026-10-11).

Точный штатный SD-ZC ждёт карту без предела (CMD18 без ответа — JR NZ,$,
токен — WTDO): вынули загрузочную карту — WC висел навсегда. После распаковки
SD-ZC (DOS_SWP → UNPACK_DRIVER) входы чтения и записи его таблицы ведут через
проверку карты (ZCG_* второго резидентного блока): CMD16 без ответа у
загрузочной карты — окно «Insert boot drive», SDINI до ответа, сверка
серийного номера тома с запомненным при первом монтировании, затем отказ до
MAIN (MEDIA_FENCE); MAIN перемонтирует её панели (MEDIA_IDLE). Исполняются
настоящие установщик boot.$C, DOS_SWP, распакованный драйвер и резидентный
код; карта — SPI-модель на портах #77/#57; SDINI, RDDSE драйвера и входы
окон WC — подменены там, где это сказано.
"""
import unittest

import test_boot_resources as br

STOP = br.STOP
EXT = br.ext_symbols()
SERIAL = bytes([0x12, 0x34, 0x56, 0x78])


def e(name):
    return EXT['WDOS_EXT.' + name]


class Card:
    """Карта на SPI ZC: выбрана, пока в #77 не 3 (CSH драйвера). Команда —
    шесть байт с битами 01 в первом; ответ R1 (0) — через байт, если карта
    на месте и инициализирована (в режиме SPI)."""

    def __init__(self):
        self.present = True
        self.ready = True
        self.selected = False
        self.command = []
        self.queue = []
        self.commands = []
        self.remove_after = None                        # через столько команд — вынута
        self.busy = 0                                   # чтений #00 (R1b) — и при снятом CS

    def conf(self, value):
        self.selected = value != 3
        if not self.selected:
            self.command, self.queue = [], []

    def write(self, value):
        if not (self.selected and self.present):
            return
        if self.busy:                                   # занята — команду не слышит
            return
        if not self.command and value & 0xC0 != 0x40:
            return
        self.command.append(value)
        if len(self.command) == 6:
            self.commands.append(tuple(self.command))
            if self.remove_after is not None:
                self.remove_after -= 1
                if self.remove_after == 0:
                    self.ready, self.remove_after = False, None
            if self.ready:
                self.queue = [0xFF, 0x00]
            self.command = []

    def read(self):
        if self.selected and self.present and self.busy:
            self.busy -= 1
            return 0x00
        if self.selected and self.present and self.queue:
            return self.queue.pop(0)
        return 0xFF


class Stand(br.Machine):
    """Установщик boot.$C, затем DOS_SWP(A) — драйвер SD-ZC по #3800."""

    def __init__(self, device=1):
        self.card = Card()
        self.page8000 = 0x07
        self.strange = []                               # чтения прочих портов
        super().__init__()
        self.call(self.sym['WDOS.INSTALL_WILDDOS'])
        cpu = self.cpu
        cpu.a = device
        self.call(self.sym['WDOS.DOS_SWP'])
        self.ports.clear()
        self.card.commands.clear()

    def inp(self, port):
        if port == 0x0057:
            return self.card.read()
        if port == 0x0077:
            return 0
        if port == 0x12AF:
            return self.page8000
        if port != 0x13AF:
            self.strange.append((port, self.cpu.pc))
            return 0xFF
        return self.mapped

    def out(self, port, value):
        if port == 0x0077:
            self.card.conf(value)
            return
        if port == 0x0057:
            self.card.write(value)
            return
        if port == 0x12AF:
            self.page8000 = value
        super().out(port, value)

    def run(self, address, stubs=(), **regs):
        """Вызов address; stubs — {адрес: f(stand)}: подменённая процедура,
        f ставит выход и возвращает True — выполнить RET."""
        cpu = self.cpu
        stubs = dict(stubs)
        for name, value in regs.items():
            setattr(cpu, name, value)
        cpu.sp, cpu.pc = 0x5F00, address
        cpu.memory[0x5F00:0x5F02] = STOP.to_bytes(2, 'little')
        points = set(stubs) | {STOP}
        for point in points:
            cpu.set_breakpoint(point)
        try:
            for _ in range(20000):
                cpu.ticks_to_stop = 200000
                if not cpu.run() & 2:
                    continue
                if cpu.pc == STOP:
                    return
                assert cpu.pc in stubs, hex(cpu.pc)
                stubs[cpu.pc](self)
                sp = cpu.sp
                cpu.pc, cpu.sp = cpu.memory[sp] | cpu.memory[sp + 1] << 8, sp + 2
                if cpu.pc == STOP:                      # точка останова под PC не срабатывает
                    return
            raise AssertionError(('не вернулся', hex(cpu.pc)))
        finally:
            for point in points:
                cpu.clear_breakpoint(point)

    def word(self, address):
        return self.cpu.memory[address] | self.cpu.memory[address + 1] << 8


def zf(cpu):
    return bool(cpu.f & 0x40)


class Patch(unittest.TestCase):
    """DOS_SWP с SD-ZC: три входа таблицы — на проверку карты; эталон драйвера
    (адреса точного DOSpSDZC35) — те, что зовёт резидентный код."""

    def test_zc_table_points_to_the_guard(self):
        for device, cs in ((1, 0x01), (6, 0x0B)):
            with self.subTest(device=device):
                s = Stand(device)
                self.assertEqual(s.word(0x3801), e('ZC_SELDEV'))
                self.assertEqual(s.word(0x3804), 0x3A7C, 'SDINI таблицы не тронут')
                self.assertEqual(s.word(0x380D), 0x38DC, 'PROZ таблицы не тронут')
                self.assertEqual(s.word(0x3810), e('ZCG_RDDSE'))
                self.assertEqual(s.word(0x3813), e('ZCG_SDDSE'))
                self.assertEqual(s.word(0x3816), e('ZCG_RDD256'))
                self.assertEqual(s.cpu.memory[e('ZC_CS_OPERAND')], cs, 'CS слота — от SELDEV')
                # CSL: LD BC,#0077 : LD A,n — n и есть CS слота.
                self.assertEqual(bytes(s.cpu.memory[0x3B35:0x3B39]), bytes([0x01, 0x77, 0x00, 0x3E]))

    def test_reference_targets(self):
        import runtime_image
        import z80
        sym = br.symbols()
        cpu = z80.Z80Machine()
        cpu.set_memory_block(0x4000, runtime_image.core_image())
        cpu.sp, cpu.pc, cpu.hl, cpu.de = 0x5FFC, sym['WDOS.DEHR'], sym['WDOS.DR2'], 0x3800
        cpu.memory[0x5FFC:0x5FFE] = STOP.to_bytes(2, 'little')
        br.run_until(cpu, STOP)
        ref = bytes(cpu.memory[0x3800:0x4000])
        word = lambda a: ref[a - 0x3800] | ref[a - 0x3800 + 1] << 8
        self.assertEqual(word(0x3810), e('ZC_RDDSE'))
        self.assertEqual(word(0x3813), e('ZC_SDDSE'))
        self.assertEqual(word(0x3816), e('ZC_RDD256'))
        self.assertEqual(word(0x3801), e('ZC_SELDEV'))
        # LD (CS_ON+1),A в SELDEV — операнд, который читает проверка.
        self.assertEqual(word(0x3C7A + 12), e('ZC_CS_OPERAND'))
        # PROZ (#38DC): LD (BLKNUM),HL — позиция, которую ZCG_RECOVER сберегает.
        self.assertEqual(ref[0x38DC - 0x3800], 0x22)
        self.assertEqual(word(0x38DC + 1), e('ZC_BLKNUM'))

    def test_other_drivers_untouched(self):
        s = Stand(0)                                    # Nemo
        self.assertNotEqual(s.word(0x3801), e('ZC_SELDEV'))
        guards = {e('ZCG_RDDSE'), e('ZCG_SDDSE'), e('ZCG_RDD256')}
        self.assertFalse({s.word(0x3810), s.word(0x3813), s.word(0x3816)} & guards)


class Guard(unittest.TestCase):

    def setUp(self):
        self.s = Stand(1)
        m = self.s.cpu.memory
        m[e('BOOT_CS')] = 0x01
        m[e('BOOT_SERIAL'):e('BOOT_SERIAL') + 4] = SERIAL
        m[e('BOOT_LBA'):e('BOOT_LBA') + 4] = bytes([0x00, 0x08, 0x00, 0x00])
        m[e('MEDIA_FENCE')] = 0
        m[e('MAIN_SEEN')] = 1                           # обычная работа, MAIN уже шёл
        self.calls = []

    def tearDown(self):
        self.assertEqual(self.s.strange, [], 'чтения посторонних портов')

    def driver(self, name):
        def stub(s):
            self.calls.append((name, s.cpu.hl, s.cpu.a))
        return stub

    def stubs(self):
        return {e('ZC_RDDSE'): self.driver('RDDSE'), e('ZC_SDDSE'): self.driver('SDDSE'),
                e('ZC_RDD256'): self.driver('RDD256')}

    def test_present_card_goes_to_the_driver(self):
        s = self.s
        for entry, name in (('ZCG_RDDSE', 'RDDSE'), ('ZCG_SDDSE', 'SDDSE'), ('ZCG_RDD256', 'RDD256')):
            with self.subTest(entry=entry):
                self.calls.clear()
                s.run(e(entry), self.stubs(), hl=0x9000, a=3, de=0x1111, bc=0x2222)
                self.assertEqual(self.calls, [(name, 0x9000, 3)], 'вход драйвера и HL, A')
        self.assertEqual(s.card.commands[-1], (0x50, 0, 0, 2, 0, 0xFF), 'CMD16, 512')

    def test_busy_card_is_not_removed(self):
        # RDD256 кончает CMD12 без WTBY: карта ещё занята (R1b, #00) — проверка
        # ждёт #FF, как CSL драйвера, а не считает карту вынутой (Codex, круг 5).
        s = self.s
        for busy in (1, 2, 7, 300):
            with self.subTest(busy=busy):
                self.calls.clear()
                s.card.busy = busy
                s.run(e('ZCG_RDDSE'), self.stubs(), hl=0x9000, a=1)
                self.assertEqual(self.calls, [('RDDSE', 0x9000, 1)])
                self.assertEqual(s.card.busy, 0)
                self.assertEqual(s.cpu.memory[e('MEDIA_FENCE')], 0)

    def test_other_slot_without_card_fails(self):
        s = self.s
        s.cpu.memory[e('ZC_CS_OPERAND')] = 0x0B          # второй слот, не загрузочный
        s.card.present = False
        s.cpu.memory[s.sym['WDOS.ABT']] = 0
        s.run(e('ZCG_RDDSE'), self.stubs(), hl=0x9000, a=1)
        self.assertEqual(self.calls, [], 'драйвер не зван')
        self.assertFalse(zf(s.cpu))
        self.assertEqual(s.cpu.memory[s.sym['WDOS.ABT']], 1)
        self.assertEqual(s.cpu.memory[e('MEDIA_FENCE')], 0)

    def test_fence_fails_without_touching_the_card(self):
        s = self.s
        s.cpu.memory[e('MEDIA_FENCE')] = 1
        s.run(e('ZCG_SDDSE'), self.stubs(), hl=0x9000, a=1)
        self.assertEqual(self.calls, [])
        self.assertEqual(s.card.commands, [], 'обмена с картой нет')
        self.assertFalse(zf(s.cpu))

    BLKNUM = bytes([0x78, 0x56, 0x34, 0x12])
    BPB = 0x8000                                        # своя страница в окне #8000
    PAGE = EXT['WC_PHYS_MEDIA_PAGE']
    SECBU = bytes((i * 7 + 3) & 0xFF for i in range(512))

    def recover(self, serials):
        """Загрузочная карта не отвечает. SDINI: две попытки без карты, затем
        ответ; RDDSE драйвера в SECBU кладёт BPB с серийными номерами из serials
        по очереди, иное RDDSE — повтор прерванного обмена. PROZ пишет BLKNUM,
        как настоящий. Окна WC подменены, их вызовы пишутся. ADDTOP — ноль:
        как после DOS_SWP при перемонтировании (BPB — по BOOT_LBA)."""
        s = self.s
        m = s.cpu.memory
        s.card.ready = False
        m[s.sym['WDOS.ADDTOP']:s.sym['WDOS.ADDTOP'] + 4] = bytes(4)
        m[e('ZC_BLKNUM'):e('ZC_BLKNUM') + 4] = self.BLKNUM
        sdini = {'n': 0}
        events = []
        serials = list(serials)

        def sdini_stub(st):
            sdini['n'] += 1
            ok = sdini['n'] % 3 == 0
            events.append('SDINI ok' if ok else 'SDINI no')
            st.card.ready = ok
            st.cpu.f = 0x40 if ok else 0

        def proz(st):
            events.append(('PROZ', st.cpu.de << 16 | st.cpu.hl))
            at = e('ZC_BLKNUM')
            st.cpu.memory[at:at + 4] = (st.cpu.de << 16 | st.cpu.hl).to_bytes(4, 'little')

        def rddse(st):
            if st.cpu.hl != self.BPB:
                at = e('ZC_BLKNUM')
                events.append(('OP', st.cpu.hl, st.cpu.a, bytes(st.cpu.memory[at:at + 4])))
                return
            events.append(('RDDSE', st.cpu.hl, st.cpu.a, st.page8000, st.cpu.memory[0x6002]))
            serial = serials.pop(0)
            st.cpu.memory[self.BPB + 0x43:self.BPB + 0x47] = serial
            if serial != SERIAL:
                st.card.ready = True       # чужая карта отвечает, пока её не вынут
                st.card.remove_after = 2

        def prsrw(st):
            text = bytes(st.cpu.memory[st.cpu.hl:st.cpu.hl + st.cpu.bc]).decode()
            events.append(('PRSRW', st.cpu.d, st.cpu.e, text))

        stubs = {0x3803: sdini_stub, 0x380C: proz, e('ZC_RDDSE'): rddse,
                 e('WC_PRWOW'): lambda st: events.append('PRWOW'),
                 e('WC_PRSRW'): prsrw,
                 e('WC_RRESB'): lambda st: events.append('RRESB')}
        s.page8000, m[0x6002], m[0x6003] = 0x21, 0x21, 0x03
        m[0x6011:0x6013] = (0xBD00).to_bytes(2, 'little')  # пул фона окон почти полон — не важно
        m[0x3000:0x3200] = self.SECBU                       # сектор FAT, ждёт записи
        gen = s.sym['WDOS.FAT_CACHE_GENERATION']
        before = m[gen]
        m[s.sym['WDOS.ABT']] = 0
        s.run(e('ZCG_RDDSE'), stubs, hl=0x9000, a=4, ix=0x4321)
        return events, before, gen

    def test_boot_card_comes_back(self):
        s = self.s
        events, before, gen = self.recover([SERIAL])
        self.assertEqual(events[0], 'PRWOW')
        self.assertEqual(events[1], ('PRSRW', 2, (e('ZCG_W') - 17) // 2, 'Insert boot drive'))
        self.assertEqual(s.cpu.memory[e('ZCG_WINDOW') + 6], 0x2F, 'окно красное, как ERWND')
        self.assertEqual(s.cpu.memory[e('ZCG_WINDOW') + 5], 4, 'пустая строка и строка текста')
        self.assertEqual(events[2:5], ['SDINI no', 'SDINI no', 'SDINI ok'])
        self.assertEqual(events[5], ('PROZ', 0x800), 'BPB тома по BOOT_LBA, не по сброшенному ADDTOP')
        self.assertEqual(self.PAGE, 0xEA)
        self.assertEqual(events[6], ('RDDSE', self.BPB, 1, self.PAGE, self.PAGE),
                         'BPB — в свою страницу #EA в #8000 (и её копия для DMA), пул окон не тронут')
        self.assertEqual(events[7:], ['RRESB'])
        self.assertEqual(bytes(s.cpu.memory[0x3000:0x3200]), self.SECBU, 'SECBU не тронут')
        self.assertEqual(self.calls, [], 'прерванный обмен не выполняется')
        self.assertFalse(zf(s.cpu))
        self.assertEqual(s.cpu.memory[s.sym['WDOS.ABT']], 1)
        self.assertEqual(s.cpu.memory[e('MEDIA_FENCE')], 1)
        self.assertNotEqual(s.cpu.memory[gen], before, 'кэш FAT недействителен')
        self.assertEqual((s.page8000, s.mapped), (0x21, 0x03), 'окна #8000/#C000')
        self.assertEqual((s.cpu.memory[0x6002], s.cpu.memory[0x6003]), (0x21, 0x03))
        self.assertEqual(s.cpu.ix, 0x4321)
        self.assertEqual(bytes(s.cpu.memory[e('ZC_BLKNUM'):e('ZC_BLKNUM') + 4]), self.BLKNUM,
                         'позиция драйвера — прежняя')

    def test_full_window_pool_still_checks_the_serial(self):
        # Codex, седьмой круг: при почти полном пуле фона окон сверку
        # пропускали — чужая карта принималась своей. BPB теперь читается в
        # свою страницу: чужая карта отвергается при любом пуле.
        s = self.s
        events, _, _ = self.recover([b'\x00\x00\x00\x01', SERIAL])
        reads = [ev for ev in events if isinstance(ev, tuple) and ev[0] == 'RDDSE']
        self.assertEqual(len(reads), 2)
        self.assertEqual(s.cpu.memory[0x6011:0x6013], (0xBD00).to_bytes(2, 'little'), 'пул не тронут')
        self.assertEqual(s.cpu.memory[e('MEDIA_FENCE')], 1)
        self.assertEqual(bytes(s.cpu.memory[0x3000:0x3200]), self.SECBU)

    def test_probe_gives_up_on_endless_busy(self):
        # Карта держит #00 дольше предела ожидания — «не отвечает», а не
        # следующий #00 за R1 (Codex, круг 6).
        s = self.s
        s.card.busy = 70000
        s.run(e('ZCG_PROBE'))
        self.assertFalse(zf(s.cpu))
        self.assertEqual(s.card.commands, [], 'CMD16 не посылалась')
        s.card.busy = 0
        s.run(e('ZCG_PROBE'))
        self.assertTrue(zf(s.cpu))

    def test_start_repeats_the_exchange(self):
        # До первого прохода MAIN (старт WC: wc.ini, плагины) снять забор
        # некому: после возврата своей карты обмен повторяется с прежней
        # позицией, забора нет (Codex, круг 5).
        s = self.s
        s.cpu.memory[e('MAIN_SEEN')] = 0
        events, _, _ = self.recover([SERIAL])
        self.assertEqual(events[-1], ('OP', 0x9000, 4, self.BLKNUM), 'повтор с прежними HL, A, BLKNUM')
        self.assertEqual(events[-2], 'RRESB')
        self.assertEqual(bytes(s.cpu.memory[0x3000:0x3200]), self.SECBU,
                         'сектор FAT, ждавший записи, цел (Codex, круг 6)')
        self.assertTrue(zf(s.cpu))
        self.assertEqual(s.cpu.memory[e('MEDIA_FENCE')], 0)
        self.assertEqual(s.cpu.memory[s.sym['WDOS.ABT']], 0)

    def test_wrong_card_waits_for_the_right_one(self):
        s = self.s
        events, _, _ = self.recover([b'\x00\x00\x00\x01', SERIAL])
        texts = [ev[3] for ev in events if isinstance(ev, tuple) and ev[0] == 'PRSRW']
        self.assertEqual(texts, ['Insert boot drive', 'Wrong drive - insert boot drive', 'Insert boot drive'])
        rows = {ev[1] for ev in events if isinstance(ev, tuple) and ev[0] == 'PRSRW'}
        self.assertEqual(rows, {2}, 'средняя строка окна')
        reads = [ev for ev in events if isinstance(ev, tuple) and ev[0] == 'RDDSE']
        self.assertEqual(len(reads), 2, 'серийный номер сверен дважды')
        # Чужую карту вынули — окно рисуется заново с прежним текстом.
        windows = [ev for ev in events if ev in ('PRWOW', 'RRESB')]
        self.assertEqual(windows, ['PRWOW', 'RRESB', 'PRWOW', 'RRESB'])
        self.assertEqual(s.cpu.memory[e('MEDIA_FENCE')], 1)

class Idle(unittest.TestCase):
    """MAIN: MEDIA_IDLE — CURSOR, а после возврата карты сперва перемонтировать
    её панели (как выбор диска: (IX+#1C)=0, DRACT, ORIGA) и DRACT своей."""

    def run_idle(self, fence, devices, boot_cs=0x01):
        s = Stand(1)
        m = s.cpu.memory
        m[e('MEDIA_FENCE')] = fence
        m[e('BOOT_CS')] = boot_cs
        for panel, device in zip((e('WC_WINDOW'), e('WC_WINDO2')), devices):
            m[panel + 0x1D] = device
            m[panel + 0x1C] = 1
        events = []

        self.seen = []

        def note(name):
            def stub(st):
                events.append((name, st.cpu.ix, st.cpu.memory[st.cpu.ix + 0x1C]))
                self.seen.append((name, st.cpu.memory[e('MAIN_SEEN')]))
            return stub
        stubs = {e('WC_DRACT'): note('DRACT'), e('WC_ORIGA'): note('ORIGA'),
                 e('WC_CURSOR'): note('CURSOR'), e('WC_STATUS'): note('STATUS')}
        s.run(e('MEDIA_IDLE'), stubs, ix=0x7EA0)
        return s, events

    def test_quiet(self):
        s, events = self.run_idle(0, (1, 1))
        self.assertEqual(events, [('CURSOR', 0x7EA0, 1)])
        self.assertEqual(s.cpu.memory[e('MAIN_SEEN')], 1, 'старт WC позади')

    def test_remount_boot_panels(self):
        w, w2 = e('WC_WINDOW'), e('WC_WINDO2')
        s, events = self.run_idle(1, (1, 0))           # вторая панель — Nemo
        self.assertEqual(events, [('DRACT', w, 0), ('ORIGA', w, 0), ('DRACT', w, 0), ('STATUS', w2, 1),
                                  ('CURSOR', w, 0)])
        self.assertEqual(s.cpu.memory[e('MEDIA_FENCE')], 0)
        # На время перемонтирования MAIN_SEEN=0: вынутую ещё раз карту
        # восстановление не обносит забором (цикл ORIGA к MAIN не выходит).
        self.assertEqual([v for n, v in self.seen if n in ('DRACT', 'ORIGA', 'STATUS')], [0, 0, 0, 0])
        self.assertEqual(self.seen[-1], ('CURSOR', 1))
        s, events = self.run_idle(1, (6, 6), boot_cs=0x0B)
        self.assertEqual([ev[:2] for ev in events],
                         [('DRACT', w), ('ORIGA', w), ('DRACT', w2), ('ORIGA', w2), ('DRACT', w),
                          ('STATUS', w2), ('CURSOR', w)])


class BootNote(unittest.TestCase):
    """Первое монтирование (LOAD_FAT_CONFIG через шлюз) — загрузочное: CS
    слота и серийный номер BPB; дальше не меняется. Не SD-ZC — #FF."""

    def mount(self, s, serial):
        m = s.cpu.memory
        lobu = s.sym['WDOS.LOBU']
        m[lobu:lobu + 512] = bytes(512)
        m[lobu + 16] = 2                                # FAT
        m[lobu + 36] = 0x10                             # FATSz32
        m[lobu + 44] = 2                                # корень
        m[lobu + 0x43:lobu + 0x47] = serial
        gate = s.sym['WDOS.EXTENSION_GATE']
        m[0x5D00:0x5D04] = bytes([0xCD, gate & 0xFF, gate >> 8, EXT['WDOS_EXT.ID_LOAD_FAT_CONFIG']])
        m[0x5D04] = 0xC9
        s.run(0x5D00)
        self.assertTrue(zf(s.cpu), 'BPB принят')

    def test_first_mount_is_remembered(self):
        s = Stand(6)
        m = s.cpu.memory
        m[e('BOOT_CS')] = 0
        addtop = s.sym['WDOS.ADDTOP']
        m[addtop:addtop + 4] = bytes([0x00, 0x08, 0x00, 0x00])       # раздел MBR с 2048
        self.mount(s, SERIAL)
        self.assertEqual(m[e('BOOT_CS')], 0x0B)
        self.assertEqual(bytes(m[e('BOOT_SERIAL'):e('BOOT_SERIAL') + 4]), SERIAL)
        self.assertEqual(bytes(m[e('BOOT_LBA'):e('BOOT_LBA') + 4]), bytes([0x00, 0x08, 0x00, 0x00]))
        m[addtop:addtop + 4] = bytes(4)
        self.mount(s, b'\x01\x02\x03\x04')
        self.assertEqual(bytes(m[e('BOOT_SERIAL'):e('BOOT_SERIAL') + 4]), SERIAL, 'не меняется')
        self.assertEqual(bytes(m[e('BOOT_LBA'):e('BOOT_LBA') + 4]), bytes([0x00, 0x08, 0x00, 0x00]))

    def test_not_zc(self):
        s = Stand(0)
        s.cpu.memory[e('BOOT_CS')] = 0
        self.mount(s, SERIAL)
        self.assertEqual(s.cpu.memory[e('BOOT_CS')], 0xFF)


class SpgFail(unittest.TestCase):
    """Загрузчик SPG 1.0 (WCVW) не прочитал блок — LOAD512 с CF=1 (вынутая
    загрузочная карта после возврата отказывает до MAIN): программу не
    запускать, красное окно «SPG load failed - press reset» и останов (Codex,
    восьмой круг: BPB в #EA и окно восстановления ложились поверх прочитанных
    блоков, а загрузчик всё равно запускал программу). Исполняется загрузчик
    на своём месте в образе WC до ARBLKZ; LOAD512, MNGC и окна WC подменены."""

    BACK = 0x5E00                                       # STOP для выхода из подмены

    def leave(self, st):
        st.cpu.memory[self.BACK:self.BACK + 2] = STOP.to_bytes(2, 'little')
        st.cpu.sp = self.BACK

    def loader(self, packed, read_ok, last=True):
        s = Stand(1)
        sym = s.sym
        m = s.cpu.memory
        table = sym['WCVW.LOB3'] + 256
        m[table:table + 3] = bytes([(0x80 if last else 0) | 0x02,    # последний, с #C400
                                    (0x40 if packed else 0) | 0x00,  # 1 сектор; MLZ — упакован
                                    0x10])                           # страница #10
        events = []

        def load(st):
            events.append(('LOAD512', st.cpu.hl, st.cpu.b))
            st.cpu.f = st.cpu.f & ~1 if read_ok else st.cpu.f | 1

        def fail(st):
            events.append('SPG_FAIL')
            self.leave(st)

        def arblkz(st):
            events.append('ARBLKZ')
            self.leave(st)

        stubs = {sym['WCVW.LOAD512']: load, sym['WCVW.MNGC']: lambda st: events.append(('MNGC', st.cpu.a)),
                 e('SPG_FAIL'): fail, sym['WCVW.ARBLKZ']: arblkz,
                 sym['WCVW.MLZP']: lambda st: events.append('MLZ')}
        # Вход ARBLKZ и SPG_FAIL — не вызовы: подмена ставит выход сама.
        s.run(sym['WCVW.SPGRZ'], stubs)
        return events

    def test_read_error_stops_the_loader(self):
        for packed in (False, True):
            with self.subTest(packed=packed):
                events = self.loader(packed, read_ok=False)
                self.assertEqual(events[-1], 'SPG_FAIL')
                self.assertNotIn('ARBLKZ', events, 'программа не запускается')
                self.assertNotIn('MLZ', events, 'не распаковывать недочитанное')

    def test_good_read_goes_on(self):
        for packed in (False, True):
            with self.subTest(packed=packed):
                events = self.loader(packed, read_ok=True)
                self.assertNotIn('SPG_FAIL', events)
                self.assertEqual(events[-1], 'ARBLKZ')
                self.assertEqual(events.count(('MNGC', 0x10)), 1)

    def test_window_and_stop(self):
        s = Stand(1)
        m = s.cpu.memory
        code = e('SPG_FAIL_CODE')
        events = []

        def prsrw(st):
            text = bytes(st.cpu.memory[st.cpu.hl:st.cpu.hl + st.cpu.bc]).decode()
            events.append(('PRSRW', st.cpu.d, st.cpu.e, text))

        stop = code + 19
        self.assertEqual(bytes(m[stop:stop + 2]), bytes([0xF3, 0x76]), 'DI, HALT')

        def halt(st):
            events.append('DI HALT')
            self.leave(st)

        # DI идёт сразу за возвратом из подмены PRSRW (точка останова под PC не
        # срабатывает) — ловим следующий за ним HALT.
        s.run(e('SPG_FAIL'), {e('WC_PRWOW'): lambda st: events.append(('PRWOW', st.cpu.ix)),
                              e('WC_PRSRW'): prsrw, stop + 1: halt})
        width = EXT['WDOS_EXT.ZCG_W']
        text = 'SPG load failed - press reset'
        self.assertEqual(events, [('PRWOW', e('ZCG_WINDOW')),
                                  ('PRSRW', 2, (width - len(text)) // 2, text), 'DI HALT'])
        self.assertEqual((width - len(text)) % 2, 0, 'по центру, отступы поровну')
        self.assertEqual(m[e('ZCG_WINDOW') + 6], 0x2F, 'красное, как окно карты')


if __name__ == '__main__':
    unittest.main(verbosity=2)
# Claude - 2026-10-11 - end
