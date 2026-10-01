"""Восьмой заход: границы передачи и доступы к памяти неизменного WMF.

Сценарный контроллер заменяет только периферию. Адрес каждого INI/OUTI
снимается ДО настоящей инструкции CPU; HL не подправляется тестом.
"""
import math
import unittest

import test_plugin as harness
from test_plugin import Plugin, SYMS, EVIDENCE, STACK, ROOT, WaitingForKey
from test_regressions import tiny


LIMITS = (6, 128, 256, 512, 1024, 6656)
COMMANDS = ((0xF4, 'WRITE TRACK', False, 6656, 7),
            (0xA0, 'WRITE SECTOR', False, 128, 7),
            (0x80, 'READ SECTOR', True, 128, 8),
            (0xC0, 'READ ADDRESS', True, 6, 8))
SENTINEL = 0x5AA5


class TransferController:
    """DRQ постоянно либо заданное число байтов; INTRQ до/после байта.

    requests=None: DRQ не снимается даже после последнего разрешённого байта.
    intrq_before: обе линии активны в опросе указанного (1-based) байта.
    finish_on_data: INTRQ поднимается при приёме последнего байта в #7F.
    silent_after: после requests байтов обе линии выключены навсегда.
    """
    def __init__(self, p, target, requests=None, intrq_before=None,
                 finish_on_data=False, silent_after=False):
        self.p, self.target, self.requests = p, target, requests
        self.intrq_before, self.finish_on_data = intrq_before, finish_on_data
        self.silent_after = silent_after
        self.rows, self.active = [], None
        self.original_start = p.model.start
        self.original_input = p.model.input
        self.original_output = p.model.output_port
        p.model.start, p.model.input, p.model.output_port = self.start, self.input, self.output
        for read in (False, True):
            address = SYMS['ReadBytes.event'] + 3 if read else SYMS['WriteBytes.event']
            assert bytes(p.cpu.memory[address:address + 2]) == (b'\xed\xa2' if read else b'\xed\xa3')
            p.cpu.set_breakpoint(address)
            p.instruction_observers[address] = lambda read=read: self.observe(read)

    def start(self, command):
        if command & 0xF0 == 0xD0 and self.active is not None:
            self.active['forced_idle'] = True
            self.active = None
        self.original_start(command)
        if command == self.target:
            self.active = {'command': command, 'start': self.p.word('TransferStart'),
                           'limit': self.p.word('TransferLimit'), 'accepted': 0,
                           'port_accesses': 0, 'stray_outi': 0, 'addresses': [],
                           'polls': 0, 'forced_idle': False, 'intrq_seen': False,
                           'data': [], 'interrupts_during_data': []}
            self.rows.append(self.active)
            m = self.p.model
            m.operation, m.busy, m.drq, m.intrq = 'stall', True, True, False

    def observe(self, read):
        if self.active is None:
            return
        row = self.active
        assert read == (self.target in (0x80, 0xC0))
        address = self.p.cpu.hl
        assert row['start'] <= address < row['start'] + row['limit'], (
            'INI/OUTI outside buffer', row, address)
        row['addresses'].append(address)
        row['interrupts_during_data'].append(self.p.interrupts_enabled)

    def finish(self):
        self.active['intrq_seen'] = True
        m = self.p.model
        m.intrq, m.drq, m.busy, m.operation = True, False, False, None

    def input(self, port):
        row, m = self.active, self.p.model
        if row is None:
            return self.original_input(port)
        port &= 255
        if port == 0xFF:
            row['polls'] += 1
            if self.intrq_before == row['accepted'] + 1:
                self.finish()
                return 0xC0              # INTRQ имеет прежний приоритет над DRQ
            if m.intrq:
                return 0x80
            if self.requests is None or row['accepted'] < self.requests:
                return 0x40
            if self.silent_after:
                m.drq = False
                return 0
            self.finish()
            return 0x80
        if port == 0x1F:
            assert m.intrq
            self.active = None
            m.intrq = False
            return 0                    # без ошибок статуса периферии
        if port == 0x7F:
            assert not m.intrq, 'INI after INTRQ'
            value = self.value(row['accepted'])
            self.accept(value)
            return value
        return self.original_input(port)

    @staticmethod
    def value(index):
        return (index * 13 + 17) & 255

    def accept(self, value):
        row = self.active
        row['port_accesses'] += 1
        row['accepted'] += 1
        row['data'].append(value)
        if self.finish_on_data and row['accepted'] == self.requests:
            self.finish()

    def output(self, port, value):
        if self.active is not None and port & 255 == 0x7F:
            if self.p.model.intrq:
                self.active['port_accesses'] += 1
                self.active['stray_outi'] += 1
            else:
                self.accept(value)
            return
        return self.original_output(port, value)


def transfer_probe(command, limit, **args):
    p = Plugin(tiny(), saved_cpu_hz=3_500_000)
    p.mask = 0x80
    p.cpu.memory[0x6004] = 0
    p.poke('TransferLeft', SENTINEL, 2)
    start = 0xC100
    payload = bytes(TransferController.value(i) for i in range(limit))
    read = command in (0x80, 0xC0)
    p.cpu.memory[start - 16:start + limit + 16] = b'\xA7' * (limit + 32)
    if not read:
        p.cpu.memory[start:start + limit] = payload
    before = bytes(p.cpu.memory[start - 16:start + limit + 16])
    controller = TransferController(p, command, **args)
    p.call('ReadBytes' if read else 'WriteBytes', a=command, hl=start, de=limit)
    row = controller.rows[0]
    assert bytes(p.cpu.memory[start - 16:start]) == before[:16]
    assert bytes(p.cpu.memory[start + limit:start + limit + 16]) == before[-16:]
    if read:
        assert bytes(p.cpu.memory[start:start + row['accepted']]) == payload[:row['accepted']]
        assert bytes(p.cpu.memory[start + row['accepted']:start + limit]) == b'\xA7' * (limit - row['accepted'])
    else:
        assert bytes(p.cpu.memory[start:start + limit]) == payload
        assert bytes(row['data']) == payload[:row['accepted']]
    assert row['port_accesses'] == len(row['addresses'])
    assert not any(row['interrupts_during_data'])
    assert p.interrupts_enabled
    assert p.cpu.sp == STACK + 2
    assert not p.model.busy or p.model.intrq
    return p, row


def compact(row):
    return {key: value for key, value in row.items()
            if key not in ('addresses', 'data', 'interrupts_during_data')}


def check_stuck_plugin_exit(test):
    rows = {}
    for command, name, read, limit, error in COMMANDS:
        for hz, cache in ((14_000_000, 2), (7_000_000, 1), (3_500_000, 0)):
            with test.subTest(command=name, saved=(hz, cache)):
                p = Plugin(tiny(), saved_cpu_hz=hz, saved_cache=cache)
                controller = TransferController(p, command)
                p.call()
                test.assertTrue(controller.rows)
                for row in controller.rows:
                    test.assertEqual(row['limit'], limit)
                    test.assertEqual(row['accepted'], limit)
                    test.assertEqual(row['port_accesses'], limit)
                    test.assertEqual(row['addresses'], list(range(row['start'], row['start'] + limit)))
                    test.assertEqual(row['stray_outi'], 0)
                    test.assertTrue(row['forced_idle'])
                    test.assertFalse(any(row['interrupts_during_data']))
                test.assertEqual(p.result, 7 if command == 0xF4 else 9)
                test.assertTrue(p.interrupts_enabled)
                test.assertEqual(p.mask, 0x85)
                test.assertEqual((p.cpu_frequency, p.cache), (hz, cache))
                test.assertEqual(p.fdc_cpu_settings, {(3_500_000, 0)})
                test.assertEqual([e['b'] for e in p.frequency_events], [0, 255, 0, 255])
                test.assertFalse(p.model.busy or p.model.drq)
                test.assertEqual(p.cpu.sp, STACK + 2)
                rows[f'{name}/{hz}/{cache}'] = {'plugin_result': p.result,
                    'attempts': len(controller.rows), 'data_port_accesses_each': limit,
                    'buffer_accesses_in_bounds': True, 'interrupts_enabled': True,
                    'frequency_cache_restored': True, 'mask29af': p.mask}
    EVIDENCE['stuck_drq_fixed_plugin_exit'] = rows


class EighthTests(unittest.TestCase):
    def test_init_transfer_count_preserves_command_and_both_counters(self):
        rows = {}
        for limit in LIMITS + (257, 258, 511, 6655):
            for command, *_ in COMMANDS:
                p = Plugin(tiny())
                p.cpu.alt_bc = 0xABCD
                p.cpu.f = 0xA5
                p.call('InitTransferCount', a=command, de=limit, hl=0xC100, bc=0x1234)
                self.assertEqual(p.cpu.a, command)
                self.assertEqual(p.cpu.f, 0xA5)
                self.assertEqual(p.cpu.bc, ((limit & 255) << 8) | 0x7F)
                self.assertEqual(p.cpu.alt_bc, 0x0400 | ((limit + 255) // 256))
                self.assertEqual(p.cpu.de, limit)
                self.assertEqual(p.cpu.hl, 0xC100)
            rows[str(limit)] = {'b': limit & 255, 'c_alt': (limit + 255) // 256, 'b_alt': 4}
        EVIDENCE['transfer_counter_initialization'] = rows

    def test_stuck_drq_exact_limits_all_commands_no_buffer_overrun(self):
        rows = {}
        for command, name, read, _, error in COMMANDS:
            for limit in LIMITS:
                with self.subTest(command=name, limit=limit):
                    p, row = transfer_probe(command, limit)
                    self.assertTrue(p.cpu.f & 1)
                    self.assertEqual(p.cpu.a, error)
                    self.assertEqual(p.cpu.hl, row['start'] + limit)
                    self.assertEqual(row['accepted'], limit)
                    self.assertEqual(row['port_accesses'], limit)
                    self.assertEqual(row['addresses'], list(range(row['start'], row['start'] + limit)))
                    self.assertTrue(row['forced_idle'])
                    self.assertEqual(p.word('TransferLeft'), SENTINEL)  # CF=1: как раньше, не обновляется
                    rows[f'{name}/{limit}'] = compact(row)
        EVIDENCE['stuck_drq_fixed_limits'] = rows

    def test_controller_exact_one_fewer_one_more_and_transferleft(self):
        rows = {}
        for command, name, read, _, error in COMMANDS:
            for limit in LIMITS + (257, 258, 511, 6655):
                for delta in (-1, 0, 1):
                    with self.subTest(command=name, limit=limit, delta=delta):
                        p, row = transfer_probe(command, limit, requests=limit + delta)
                        transferred = min(limit, limit + delta)
                        self.assertEqual(row['accepted'], transferred)
                        stray = int(not read and delta == -1)
                        self.assertEqual(row['port_accesses'], transferred + stray)
                        self.assertEqual(row['stray_outi'], stray)
                        self.assertEqual(p.cpu.hl, row['start'] + transferred)
                        self.assertEqual(bool(p.cpu.f & 1), delta == 1)
                        if delta == 1:
                            self.assertEqual(p.cpu.a, error)
                            self.assertEqual(p.word('TransferLeft'), SENTINEL)
                        else:
                            self.assertEqual(p.word('TransferLeft'), -delta)
                        rows[f'{name}/{limit}/{delta:+}'] = dict(compact(row), transfer_left=p.word('TransferLeft'))
        EVIDENCE['transfer_counter_boundaries'] = rows

    def test_intrq_with_last_data_access_and_last_drq_poll(self):
        rows = {}
        for command, name, read, _, _ in COMMANDS:
            for limit in LIMITS:
                for mode in ('at_data_port', 'at_drq_poll'):
                    with self.subTest(command=name, limit=limit, intrq=mode):
                        args = {'requests': limit, 'finish_on_data': True} if mode == 'at_data_port' else {'intrq_before': limit}
                        p, row = transfer_probe(command, limit, **args)
                        count = limit if mode == 'at_data_port' else limit - 1
                        self.assertFalse(p.cpu.f & 1)
                        self.assertEqual(row['accepted'], count)
                        self.assertEqual(row['stray_outi'], int(not read and mode == 'at_drq_poll'))
                        self.assertEqual(p.cpu.hl, row['start'] + count)
                        self.assertEqual(p.word('TransferLeft'), limit - count)
                        rows[f'{name}/{limit}/{mode}'] = dict(compact(row), transfer_left=p.word('TransferLeft'))
        EVIDENCE['intrq_last_byte'] = rows

    def test_intrq_first_byte_new_block_and_stray_outi_zero_b(self):
        rows = {}
        for command, name, read, _, _ in COMMANDS:
            for limit in LIMITS + (257, 258, 511, 6655):
                first_block = (limit & 255) or 256
                boundaries = {before for end in range(first_block, limit + 1, 256)
                              for before in (end, end + 1)}
                for before in sorted(boundaries):
                    if before > limit:
                        continue
                    with self.subTest(command=name, limit=limit, before=before):
                        p, row = transfer_probe(command, limit, intrq_before=before)
                        self.assertFalse(p.cpu.f & 1)
                        self.assertEqual(row['accepted'], before - 1)
                        self.assertEqual(p.cpu.hl, row['start'] + before - 1)
                        self.assertEqual(p.word('TransferLeft'), limit - before + 1)
                        self.assertEqual(row['stray_outi'], int(not read))
                        at_end = (before - first_block) % 256 == 0
                        expected_b = (1 if read else 0) if at_end else (0 if read else 255)
                        self.assertEqual(p.cpu.b, expected_b)
                        # Stray OUTI при B=0 не должен уменьшать C' (.block -> .done).
                        completed_blocks = (before - 1 + 256 - first_block) // 256
                        expected_pages = (limit + 255) // 256 - completed_blocks
                        self.assertEqual(p.cpu.alt_bc & 255, expected_pages)
                        rows[f'{name}/{limit}/{before}'] = dict(compact(row),
                            transfer_left=p.word('TransferLeft'), b=p.cpu.b, c_alt=p.cpu.alt_bc & 255)
        EVIDENCE['intrq_block_boundaries'] = rows

    def test_full_buffer_silence_times_out_without_more_memory_accesses(self):
        rows = {}
        for command, name, *_ in COMMANDS:
            p, row = transfer_probe(command, 256, requests=256, silent_after=True)
            self.assertTrue(p.cpu.f & 1)
            self.assertEqual(p.cpu.a, SYMS['ERR_TIMEOUT'])
            self.assertEqual(row['port_accesses'], 256)
            self.assertEqual(p.cpu.hl, row['start'] + 256)
            self.assertEqual(p.cpu.alt_bc >> 8, 0)
            self.assertTrue(row['forced_idle'])
            self.assertGreater(p.elapsed / p.model.frequency, 2.9)
            self.assertLess(p.elapsed / p.model.frequency, 3)
            rows[name] = dict(compact(row), seconds=round(p.elapsed / p.model.frequency, 6))
        EVIDENCE['transfer_full_watchdog'] = rows

    def test_latency_from_previous_data_port_including_new_jr_and_block(self):
        # DRQ следующего байта сдвигается после первого строба. В отличие от
        # входа прямо в .stream, сюда включены JR Z и вся ветка .block.
        rows = {}
        for read in (False, True):
            for block in (False, True):
                values, gaps, immediate = [], [], None
                for offset in range(1, 160):
                    # Новый экземпляр: первый байт передаётся штатно; второй
                    # запрашивается после него в заданной непрерывной фазе.
                    p = Plugin(tiny(), timed=True)
                    p.mask = 0x80
                    p.cpu.memory[0x6004] = 0
                    p.cpu._Z80State__iff1[0] = p.cpu._Z80State__iff2[0] = 0
                    m = p.model
                    # Диагностический перебор включает физически невозможный
                    # новый DRQ сразу после предыдущего строба. Здесь отключён
                    # только дедлайн; штатные timed-прогоны отдельно используют
                    # исходные 23,5/27 мкс и период 32/1,03 мкс.
                    m.service_ticks = lambda operation=None: 1000
                    m.load_head()
                    m.motor_since[0] -= 5 * m.period
                    m.busy, m.operation, m.command = True, 'read' if read else 'write', 0x80 if read else 0xA0
                    from fdi import Sector
                    m.active, m.length, m.queue = Sector(0, 0, 1, 0, b'ZZ'), 2, b'XX'
                    m.ready_at, m.write_data_at, m.deadline = 1, 1, 1 + m.service_ticks()
                    original = m.consumed
                    first_port = []
                    def consumed(expansion=1):
                        if not first_port:
                            first_port.append(p.now())
                            original(expansion)
                            m.ready_at = first_port[0] + offset - .999
                            m.deadline = m.ready_at + m.service_ticks()
                        else:
                            original(expansion)
                    m.consumed = consumed
                    polls = []
                    original_input = m.input
                    def input_port(port):
                        if port & 255 == 0xFF:
                            polls.append(p.now())
                        return original_input(port)
                    m.input = input_port
                    p.poke('TransferStart', 0xAC00, 2)
                    p.poke('TransferLimit', 257 if block else 2, 2)
                    p.poke('TransferKind', 8 if read else 7)
                    p.cpu.alt_bc = 0x0402 if block else 0x0401
                    p.call('ReadBytes.wait' if read else 'WriteBytes.wait',
                           bc=0x017F if block else 0x027F, de=0x0202, hl=0xAC00)
                    self.assertFalse(p.cpu.f & 1)
                    self.assertEqual(p.cpu.hl, 0xAC02)
                    self.assertEqual(p.word('TransferLeft'), 255 if block else 0)
                    self.assertEqual(m.status, 0, (read, block, offset, m.drq_latencies, polls, first_port))
                    values.append(m.drq_latencies['read' if read else 'write'][1])
                    gaps.append(next(t for t in polls if t > first_port[0]) - first_port[0])
                    if offset == 1:
                        immediate = math.ceil(values[-1])
                maximum = math.ceil(max(values))
                self.assertEqual(maximum, (90 if block else 81) if read else (91 if block else 70))
                self.assertEqual(max(gaps), (48 if block else 21) if read else (56 if block else 29))
                rows[f'{"read" if read else "write"}/{"block" if block else "byte"}'] = {
                    'max_t': maximum, 'sample_max_t': round(max(values), 3),
                    'first_poll_after_data_t': max(gaps), 'immediate_drq_t': immediate,
                    'phases': 159, 'deadline_disabled_for_diagnostic_sweep': True}
        EVIDENCE['drq_after_byte_and_block'] = rows


class FlowTrace:
    """Хронология готового WMF: точки входа процедур, API и #29AF.

    Наблюдатели исполняют настоящую первую инструкцию, без изменения кода,
    HL или SP. Состояние снимается до API, а запись #29AF — после OUT.
    """
    def __init__(self, p):
        self.p, self.events, self.on_routine = p, [], lambda label: None
        labels = ('Options', 'ProbeDisk', 'Warning', 'Validate', 'RunDisk',
                  'StartFDC', 'OpenFDC', 'CloseFDC', 'SpinUpFromIndex')
        for label in labels:
            address = SYMS[label]
            p.cpu.set_breakpoint(address)
            p.instruction_observers[address] = lambda label=label: self.routine(label)
        p.on_api = self.api
        original_output = p.output
        def output(port, value):
            original_output(port, value)
            if port == 0x29AF:
                self.record('mask', value=value)
        p.cpu.set_output_callback(output)

    def record(self, event, **extra):
        p = self.p
        row = dict(event=event, time=p.now(), sp=p.cpu.sp,
                   drive=p.cpu.memory[SYMS['Drive']], mask=p.mask,
                   frequency=p.cpu_frequency, cache=p.cache,
                   fdc_open=p.cpu.memory[SYMS['FdcOpen']],
                   read_calls=len(p.reads), disk_writes=p.model.writes,
                   outputs=len(p.controller_outputs), result=p.result)
        row.update(extra)
        self.events.append(row)

    def routine(self, label):
        self.record(label)
        self.on_routine(label)

    def api(self, number):
        if number == 3:
            p = self.p
            text = bytes(p.cpu.memory[p.cpu.hl:p.cpu.hl + p.cpu.bc]).decode('cp866').strip()
            self.record('print', row=p.cpu.d, text=text)
        elif number == 14:
            self.record('frequency', b=self.p.cpu.b, c=self.p.cpu.c)
        elif number in (1, 2, 47, 48, 59, 61, 77):
            self.record(f'api{number}')

    def named(self, event):
        return [row for row in self.events if row['event'] == event]


def drive_conditions(p, conditions):
    """Периферия: отдельное наличие/WP для A..D при реальном SelectSide."""
    original_output = p.model.output_port
    def output(port, value):
        if port & 255 == 0xFF and value & 8:
            state = conditions.get(value & 3, {})
            p.model.has_drive = state.get('drive', True)
            p.model.has_disk = state.get('disk', True)
            p.model.protected = state.get('protected', False)
        original_output(port, value)
    p.model.output_port = output


PROBE_ERRORS = (({'drive': False}, 3, 'Drive not found'),
                ({'disk': False}, 4, 'No disk in drive'),
                ({'protected': True}, 5, 'Disk is write protected'))


class DriveFlowTests(unittest.TestCase):
    def check_wc_return(self, p):
        self.assertEqual(p.cpu.sp, STACK + 2)
        self.assertEqual(p.cpu.ix, 0x6200)
        self.assertEqual(p.mask, 0x85)
        self.assertEqual((p.cpu_frequency, p.cache), p.saved_cpu_settings)
        self.assertFalse(p.window_open or p.keyboard.held or p.model.busy or p.model.drq)
        self.assertTrue(p.interrupts_enabled)

    def check_probe_error(self, p, trace, result, message, reselect=True):
        self.assertEqual(p.result, result)
        self.assertEqual(p.cpu.memory[SYMS['Reselect']], int(reselect))
        self.assertEqual(''.join(p.window_rows[2]).strip(), message)
        prompt = 'Press any key to select drive' if reselect else 'Press any key to exit'
        self.assertEqual(''.join(p.window_rows[4]).strip(), prompt)
        self.assertFalse(p.reads or p.model.writes or p.model.formatted or p.model.written)
        self.assertEqual(p.read_count, 0)
        self.assertFalse(trace.named('Warning') or trace.named('Validate') or trace.named('RunDisk'))
        self.assertEqual([e['b'] for e in p.frequency_events], [0, 255])
        self.assertEqual(p.mask, 0x85)
        self.assertEqual((p.cpu_frequency, p.cache), p.saved_cpu_settings)
        self.assertEqual(p.cpu.memory[SYMS['FdcOpen']], 0)
        printed = trace.named('print')
        self.assertEqual([row['text'] for row in printed if row['row'] == 2], ['Checking drive...', message])
        self.assertFalse(any('Continue?' in row['text'] or 'All data' in row['text'] for row in printed))
        summary = next(row for row in printed if row['text'] == message)
        restore = next(row for row in trace.named('frequency') if row['b'] == 255)
        mask_restore = next(row for row in trace.named('mask') if row['value'] == 0x85)
        self.assertLess(trace.events.index(mask_restore), trace.events.index(restore))
        self.assertLess(trace.events.index(restore), trace.events.index(summary))
        for row in printed[printed.index(summary):]:
            self.assertEqual((row['frequency'], row['cache'], row['mask'], row['fdc_open']),
                             (*p.saved_cpu_settings, 0x85, 0))
        self.assertTrue(p.interrupts_enabled)

    def test_probe_errors_message_before_question_any_key_reopens_same_drive(self):
        rows = {}
        for args, result, message in PROBE_ERRORS:
            for drive in range(4):
                for key in ('space', 'enter', 'escape', 'f1'):
                    with self.subTest(error=result, drive=drive, key=key):
                        p = Plugin(tiny(), saved_cpu_hz=14_000_000, saved_cache=2)
                        drive_conditions(p, {drive: args})
                        trace = FlowTrace(p)
                        p.option_keys = ['right'] * drive + ['enter']
                        p.final_key = None
                        with self.assertRaisesRegex(WaitingForKey, 'error'):
                            p.call()
                        self.check_probe_error(p, trace, result, message)
                        outputs = list(p.controller_outputs)
                        p.option_keys, p.final_key = ['escape'], key
                        self.assertEqual(p.resume(), 0)
                        options = trace.named('Options')
                        self.assertEqual(len(options), 2)
                        self.assertEqual(options[1]['sp'], options[0]['sp'])
                        self.assertEqual(options[1]['drive'], drive)
                        highlights = [e for e in p.ui_events if e['window'] == 2 and e['api'] == 4
                                      and e['colour'] == 0xF0]
                        self.assertEqual([(e['x'], e['text'].strip()) for e in highlights],
                                         [(9 + 7 * drive, 'A      B      C      D')])
                        self.assertEqual(p.controller_outputs, outputs)
                        self.assertEqual(p.result, 9)
                        self.assertFalse(p.reads)
                        self.check_wc_return(p)
                        rows[f'{result}/{chr(65 + drive)}/{key}'] = {
                            'probe_result': result, 'message': message, 'row4': 'Press any key to select drive',
                            'options_sp': [e['sp'] for e in options], 'highlight_x': highlights[0]['x'],
                            'fdi_bytes_read': 0, 'controller_writes_after_probe_closed': 0,
                            'restored_before_result': True}
        EVIDENCE['probe_error_reselection'] = rows

    def test_ten_wrong_choices_no_stack_growth_then_good_drive_complete_write(self):
        rows = {}
        for args, result, message in PROBE_ERRORS:
            with self.subTest(error=result):
                p = Plugin(tiny(), saved_cpu_hz=14_000_000, saved_cache=2)
                drive_conditions(p, {2: args})
                trace = FlowTrace(p)
                p.option_keys = ['right', 'right'] + ['enter'] * 10 + ['left', 'enter']
                p.call()
                options = trace.named('Options')
                self.assertEqual(len(options), 11)
                self.assertEqual([row['sp'] for row in options], [options[0]['sp']] * 11)
                self.assertEqual([row['drive'] for row in options], [0] + [2] * 10)
                self.assertTrue(all(row['read_calls'] == row['disk_writes'] == 0 for row in options))
                menus = [e for e in p.ui_events if e['api'] == 4 and e['colour'] == 0xF0]
                for window in range(2, 22, 2):
                    self.assertEqual(next(e['x'] for e in menus if e['window'] == window), 23)
                self.assertEqual(menus[-1]['x'], 16)
                printed = trace.named('print')
                self.assertEqual(sum(e['text'] == message for e in printed), 10)
                self.assertEqual(sum(e['text'] == 'Press any key to select drive' for e in printed), 10)
                question = next(e for e in printed if 'Continue?' in e['text'])
                self.assertEqual(question['drive'], 1)
                self.assertEqual(question['read_calls'], 0)
                self.assertIn('All data on disk B will be destroyed!', [e['text'] for e in printed])
                self.assertEqual(len(trace.named('ProbeDisk')), 11)
                self.assertEqual(len(trace.named('RunDisk')), 1)
                self.assertEqual(len(trace.named('OpenFDC')), 12)
                self.assertEqual([e['b'] for e in p.frequency_events], [0, 255] * 12)
                self.assertEqual(p.cpu.memory[SYMS['Drive']], 1)
                self.assertTrue(all(key[0] == 1 for key in p.model.formatted))
                harness.PluginTests().check_disk(p, p.blob, window_pairs=11)
                self.check_wc_return(p)
                rows[str(result)] = {'wrong_choices': 10, 'options_sp': [e['sp'] for e in options],
                    'reopened_drive': 'C', 'good_drive': 'B', 'good_drive_written_and_verified': True,
                    'open_fdc_count': 12, 'fdi_reads_before_good_drive': 0}
        EVIDENCE['ten_wrong_choices_then_success'] = rows

    def test_probe_nofdc_any_key_exits_without_reselection(self):
        rows = {}
        for bus, key in ((0xFF, 'space'), (0, 'escape'), (0x55, 'f1')):
            p = Plugin(tiny(), absent_bus=bus, saved_cpu_hz=14_000_000, trace_io=True)
            trace = FlowTrace(p)
            p.final_key = None
            with self.assertRaisesRegex(WaitingForKey, 'error'):
                p.call()
            self.check_probe_error(p, trace, 11, 'Floppy disk controller not found', reselect=False)
            outputs = list(p.controller_outputs)
            p.final_key = key
            self.assertEqual(p.resume(), 0)
            self.assertEqual(len(trace.named('Options')), 1)
            self.assertEqual(p.controller_outputs, outputs)
            self.assertEqual(p.result, 11)
            self.check_wc_return(p)
            rows[f'{bus:02X}'] = {'row4': 'Press any key to exit', 'options_calls': 1,
                                 'fdi_bytes_read': 0, 'restored_before_result': True}
        EVIDENCE['probe_nofdc_flow'] = rows

    def test_esc_during_probe_returns_silently(self):
        rows = {}
        for phase in ('restore_latched', 'spin_live'):
            p = Plugin(tiny(), saved_cpu_hz=14_000_000, timed=True)
            trace = FlowTrace(p)
            if phase == 'restore_latched':
                def command(cmd):
                    if cmd == 0x08:
                        p.cpu.memory[0x6004] = 1
                        p.keyboard.release()
                p.model.on_command = command
            else:
                trace.on_routine = lambda label: setattr(p, 'escaped', True) if label == 'SpinUpFromIndex' else None
            p.call()
            self.assertEqual(p.result, 9)
            self.assertEqual(p.wait_events, ['drive'])
            self.assertEqual(len(trace.named('Options')), 1)
            self.assertFalse(trace.named('Warning') or trace.named('Validate') or trace.named('RunDisk'))
            self.assertFalse(p.reads or p.model.writes)
            self.assertFalse(any('Press any key' in s or 'Continue?' in s for _, _, s in p.messages))
            self.assertEqual([e['b'] for e in p.frequency_events], [0, 255])
            self.check_wc_return(p)
            rows[phase] = {'result': 9, 'silent': True, 'fdi_bytes_read': 0, 'frequency_restored': True}
        EVIDENCE['probe_escape'] = rows

    def test_good_disk_opened_twice_warning_validate_at_wc_frequency(self):
        rows = {}
        for hz, cache in ((14_000_000, 2), (7_000_000, 1), (3_500_000, 0)):
            p = Plugin(tiny(), saved_cpu_hz=hz, saved_cache=cache, trace_io=True)
            trace = FlowTrace(p)
            p.call()
            self.assertEqual(len(trace.named('ProbeDisk')), 1)
            self.assertEqual(len(trace.named('OpenFDC')), 2)
            self.assertEqual(p.model.probe_history, [1, 1])
            self.assertEqual([e['b'] for e in p.frequency_events], [0, 255, 0, 255])
            first, second = trace.named('OpenFDC')
            between = trace.events[trace.events.index(first) + 1:trace.events.index(second)]
            self.assertTrue(any(e['event'] == 'CloseFDC' for e in between))
            self.assertTrue(any(e['event'] == 'mask' and e['value'] == 0x85 for e in between))
            for event in ('Warning', 'Validate'):
                state = trace.named(event)
                self.assertEqual(len(state), 1)
                self.assertEqual((state[0]['frequency'], state[0]['cache'], state[0]['mask'], state[0]['fdc_open']),
                                 (hz, cache, 0x85, 0))
            for e in trace.events:
                if e['event'] in ('api48', 'api59', 'api61', 'api77') and e['fdc_open'] == 0:
                    self.assertEqual((e['frequency'], e['cache'], e['mask']), (hz, cache, 0x85))
            before_warning = trace.events[:trace.events.index(trace.named('Warning')[0])]
            self.assertTrue(any(e['event'] == 'print' and e['text'] == 'Checking drive...' for e in before_warning))
            self.assertEqual(trace.named('Warning')[0]['read_calls'], 0)
            self.assertEqual(trace.named('RunDisk')[0]['mask'], 0x85)
            self.assertEqual(p.fdc_cpu_settings, {(3_500_000, 0)})
            harness.PluginTests().check_disk(p, p.blob)
            self.check_wc_return(p)
            rows[f'{hz}/{cache}'] = {'open_fdc_count': 2, 'probe_attempts_each': [1, 1],
                'close_between_opens': True, 'warning_validate_hz': hz,
                'warning_validate_cache': cache, 'written_and_verified': True}
        EVIDENCE['probe_then_work_frequency'] = rows

    def test_disk_removed_after_probe_run_disk_exit_prompt(self):
        p = Plugin(tiny(), saved_cpu_hz=14_000_000)
        trace = FlowTrace(p)
        trace.on_routine = lambda label: setattr(p.model, 'has_disk', False) if label == 'Warning' else None
        p.final_key = None
        with self.assertRaisesRegex(WaitingForKey, 'error'):
            p.call()
        self.assertEqual(p.result, 4)
        self.assertEqual(p.cpu.memory[SYMS['Reselect']], 0)
        self.assertEqual(''.join(p.window_rows[2]).strip(), 'No disk in drive')
        self.assertEqual(''.join(p.window_rows[4]).strip(), 'Press any key to exit')
        self.assertEqual(len(trace.named('OpenFDC')), 2)
        self.assertEqual(len(trace.named('RunDisk')), 1)
        self.assertEqual([e['b'] for e in p.frequency_events], [0, 255, 0, 255])
        self.assertTrue(p.reads)
        self.assertFalse(p.model.writes or p.model.formatted or p.model.written)
        summary = next(e for e in trace.named('print') if e['text'] == 'No disk in drive')
        self.assertEqual((summary['frequency'], summary['cache'], summary['mask'], summary['fdc_open']),
                         (*p.saved_cpu_settings, 0x85, 0))
        outputs = list(p.controller_outputs)
        p.final_key = 'space'
        p.resume()
        self.assertEqual(len(trace.named('Options')), 1)
        self.assertEqual(p.controller_outputs, outputs)
        self.check_wc_return(p)
        EVIDENCE['removed_after_probe'] = {'result': 4, 'row4': 'Press any key to exit',
            'open_fdc_count': 2, 'options_calls': 1, 'disk_writes': 0,
            'warning_and_validate_completed': True, 'restored_before_result': True}

    def test_wmf_header_size_padding_and_state_below_seqbuf(self):
        import hashlib
        blob = (ROOT / 'build/FDI2FDD.WMF').read_bytes()
        self.assertEqual(len(blob), 7168)
        self.assertEqual(hashlib.sha256(blob).hexdigest(),
                         '25f20eb5dc9e343fa109d130a1fa6640d4ccdaf4c8c434b65a90ed525bb1e747')
        self.assertEqual(blob[16:32], b'WildCommanderMDL')
        self.assertEqual(blob[36], 0)
        blocks = (SYMS['CodeEnd'] - SYMS['CodeStart'] + 511) // 512
        self.assertEqual(blob[37], blocks)
        self.assertEqual(blocks, 13)
        self.assertEqual(len(blob), 512 + blocks * 512)
        self.assertEqual(SYMS['FileEnd'] - SYMS['FileStart'], len(blob))
        self.assertEqual(SYMS['StateEnd'], SYMS['CodeEnd'])
        self.assertLess(SYMS['State'], SYMS['StateEnd'])
        self.assertLessEqual(SYMS['CodeEnd'], SYMS['SEQBUF'])
        end = 512 + SYMS['CodeEnd'] - SYMS['CodeStart']
        self.assertEqual(blob[end:], bytes(len(blob) - end))
        p = Plugin(tiny())
        guard = bytes(range(256)) * ((SYMS['SEQBUF'] - SYMS['CodeEnd']) // 256 + 1)
        guard = guard[:SYMS['SEQBUF'] - SYMS['CodeEnd']]
        p.cpu.memory[SYMS['CodeEnd']:SYMS['SEQBUF']] = guard
        p.call()
        harness.PluginTests().check_disk(p, p.blob)
        self.assertEqual(bytes(p.cpu.memory[SYMS['CodeEnd']:SYMS['SEQBUF']]), guard)
        EVIDENCE['wmf_layout'] = {'wmf_bytes': len(blob), 'header_code_blocks': blocks,
            'code_start': SYMS['CodeStart'], 'code_end': SYMS['CodeEnd'],
            'state_start': SYMS['State'], 'state_end': SYMS['StateEnd'],
            'code_and_state_bytes': SYMS['CodeEnd'] - SYMS['CodeStart'],
            'padding_bytes': len(blob) - end, 'seqbuf': SYMS['SEQBUF'],
            'bytes_free_before_seqbuf': len(guard), 'guard_unchanged_after_complete_write': True}


if __name__ == '__main__':
    unittest.main()
