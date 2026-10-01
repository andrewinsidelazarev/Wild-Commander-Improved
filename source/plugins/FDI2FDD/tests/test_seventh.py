"""Седьмой заход: неизменный WMF, CPU 3,5 МГц и восстановление записи.

Все повреждения вносятся в RAM модели дискеты. Файлы FDI/ZIP не записываются.
"""
import unittest
from fdi import Sector, make_fdi
from wd1793 import crc16
import test_plugin as harness
from test_plugin import Plugin, SYMS, EVIDENCE, STACK, WaitingForKey
import test_regressions as regressions
from test_regressions import tiny


class SeventhTests(unittest.TestCase):
    def check_return(self, p):
        self.assertEqual(p.cpu.sp, STACK + 2)
        self.assertEqual(p.mask, 0x85)
        self.assertFalse(p.model.busy or p.model.drq)

    def test_frequency_before_all_fdc_io_and_restored_on_every_exit(self):
        rows = {}
        cases = {'success': {}, 'no_fdc': {'probe_success_attempt': 9},
                 'no_drive': {'drive': False}, 'no_disk': {'disk': False},
                 'write_protected': {'protected': True}, 'timeout': {'fault': 'stall'},
                 'seek_error': {'fault': 'seek'}, 'format_error': {'fault': 'write'},
                 'file_error': {}, 'esc': {}, 'write_abort': {'fault': 'write_sector'},
                 'verify_abort': {'fault': 'mismatch'}, 'id_abort': {'fault': 'id_mismatch'}}
        for name, args in cases.items():
            for hz, cache in ((14_000_000, 2), (7_000_000, 1), (3_500_000, 0)):
                with self.subTest(exit=name, saved=(hz, cache)):
                    p = Plugin(tiny(), saved_cpu_hz=hz, saved_cache=cache, **args)
                    if name in ('file_error', 'esc'):
                        address = SYMS['RunDisk.track']
                        p.cpu.set_breakpoint(address)
                        def stop_track():
                            if name == 'esc':
                                p.cpu.memory[0x6004] = 1
                            else:
                                p.file_fault_at = p.read_count
                                # Эта ошибка должна случиться в LoadTrack, а не Validate.
                                p.cpu.memory[SYMS['SeqValid']] = 0
                        p.hooks[address] = stop_track
                    if name in ('no_drive', 'no_disk', 'write_protected'):
                        p.final_key = None
                        with self.assertRaisesRegex(WaitingForKey, 'error'):
                            p.call()
                    else:
                        p.call()
                    expected = {'success': 0, 'no_fdc': 11, 'no_drive': 3, 'no_disk': 4,
                                'write_protected': 5, 'timeout': 10, 'file_error': 2,
                                'seek_error': 6, 'format_error': 7,
                                'esc': 9, 'write_abort': 9, 'verify_abort': 9, 'id_abort': 9}
                    self.assertEqual(p.result, expected[name])
                    probe_only = name in ('no_fdc', 'no_drive', 'no_disk', 'write_protected')
                    if not probe_only:
                        self.assertEqual([e['b'] for e in p.frequency_events], [0, 255, 0, 255])
                    if name in ('no_drive', 'no_disk', 'write_protected'):
                        p.option_keys, p.final_key = ['escape'], 'space'
                        p.resume()
                    self.check_return(p)
                    events = p.frequency_events
                    self.assertEqual([e['b'] for e in events], [0, 255] if probe_only else [0, 255, 0, 255])
                    self.assertEqual(events[0]['c'], 0)
                    self.assertEqual(events[0]['fdc_access_count'], 0)
                    self.assertEqual(events[-1]['fdc_access_count'], p.fdc_access_count)
                    self.assertGreater(p.fdc_access_count, 0)
                    self.assertEqual(p.fdc_cpu_settings, {(3_500_000, 0)})
                    self.assertEqual((p.cpu_frequency, p.cache), (hz, cache))
                    self.assertEqual(p.api_calls.count(14), 2 if probe_only else 4)
                    rows[f'{name}/{hz}/{cache}'] = {'result': expected[name], 'events': events}
        EVIDENCE['frequency_restore'] = rows

    def test_frequency_restored_after_prework_exit_and_unchanged_on_menu_esc(self):
        for reason in ('menu_esc', 'warning_n', 'invalid_image'):
            p = Plugin(b'bad' if reason == 'invalid_image' else tiny(), saved_cpu_hz=14_000_000)
            if reason == 'menu_esc': p.option_keys = ['escape']
            if reason == 'warning_n': p.warning_key = 'n'
            p.call()
            if reason == 'menu_esc':
                self.assertFalse(p.frequency_events or p.fdc_access_count)
            else:
                self.assertEqual([e['b'] for e in p.frequency_events], [0, 255])
                self.assertGreater(p.fdc_access_count, 0)
                self.assertFalse(p.model.writes)
            self.assertEqual((p.cpu_frequency, p.cache), p.saved_cpu_settings)

    def test_controller_recovers_on_second_and_eighth_attempt(self):
        rows = {}
        for attempt in (2, 8):
            p = Plugin(tiny(), timed=True, probe_success_attempt=attempt, trace_io=True)
            p.call()
            harness.PluginTests().check_disk(p, p.blob)
            self.assertEqual(p.model.probe_attempts, attempt)
            self.assertNotIn('choice', p.wait_events)
            probe = [(op, value) for op, port, value in p.io_events if port & 255 == 0x5F]
            self.assertEqual(probe[:2 * (attempt - 1)], [('out', 0x55), ('in', 1)] * (attempt - 1))
            self.assertEqual(probe[2 * (attempt - 1):2 * attempt + 2],
                             [('out', 0x55), ('in', 0x55), ('out', 0xAA), ('in', 0xAA)])
            rows[str(attempt)] = {'attempts': p.model.probe_attempts, 'result': p.result}
        EVIDENCE['probe_recovery'] = rows

    def test_controller_never_echoes_stops_after_eight_attempts_with_only_d0(self):
        p = Plugin(tiny(), timed=True, probe_success_attempt=9)
        p.call()
        self.check_return(p)
        self.assertEqual(p.result, 11)
        self.assertEqual(p.model.probe_attempts, 8)
        self.assertEqual([cmd for cmd, *_ in p.model.commands], [0xD0, 0xD0])
        self.assertFalse(p.model.formatted or p.model.written)
        self.assertEqual(sum(port == 0x5F and value == 0x55 for port, value in p.controller_outputs), 8)

    def test_controller_requires_both_echoes_from_same_attempt(self):
        for success_attempt in (2, 8, 9):
            p = Plugin(tiny(), trace_io=True)
            original_input = p.model.input
            def input_port(port):
                value = original_input(port)
                if (port & 255 == 0x5F and p.model.probing and value == 0xAA
                        and p.model.probe_attempts < success_attempt):
                    return 0x55          # первая проба проходит, вторая ещё нет
                return value
            p.model.input = input_port
            p.call()
            self.check_return(p)
            self.assertEqual(p.model.probe_attempts, min(success_attempt, 8))
            self.assertEqual(p.result, 0 if success_attempt <= 8 else 11)
            probes = [(op, value) for op, port, value in p.io_events if port & 255 == 0x5F]
            failed = min(success_attempt - 1, 8)
            self.assertEqual(probes[:4 * failed],
                             [('out', 0x55), ('in', 0x55), ('out', 0xAA), ('in', 0x55)] * failed)
            if success_attempt <= 8:
                harness.PluginTests().check_disk(p, p.blob)
            else:
                self.assertEqual([cmd for cmd, *_ in p.model.commands], [0xD0, 0xD0])

    def test_controller_delayed_sector_latch_accepted(self):
        # Реальный регистр ещё содержит старое значение сразу после OUT.
        for delay in (5, 20, 50):
            p = Plugin(tiny(), timed=True, sector_latch_us=delay)
            seen = []
            original = p.model.output_port
            def output(port, value):
                original(port, value)
                if p.model.probing and port & 255 == 0x5F:
                    seen.append((p.model.sector, value))
            p.model.output_port = output
            p.mask = 0x80
            p.poke('FdcOpen', 0x80)
            p.cpu.memory[0x6004] = 0
            p.call('OpenFDC')
            self.assertFalse(p.cpu.f & 1)
            self.assertEqual(p.model.probe_attempts, 1)
            self.assertEqual(seen, [(1, 0x55), (0x55, 0xAA)])
            p.call('CloseFDC')
            self.check_return(p)
        EVIDENCE['probe_latch_us'] = [5, 20, 50]

    def test_full_length_format_write_read_all_sizes_at_3500khz_and_fast_disk(self):
        rows = {}
        for speed in (1, 1.03):
            for n in range(4):
                blob = make_fdi({(0, 0): [Sector(0, 0, r, n, bytes(range(128)) * (1 << n))
                                          for r in (1, 2)]})
                p = Plugin(blob, timed=True, disk_speed=speed)
                p.call()
                harness.PluginTests().check_disk(p, blob)
                self.assertEqual(len(p.model.track_raw[(0, 0, 0)][0]), 6250)
                self.assertEqual([s[3] for s in p.model.written], [128 << n] * 2)
                self.assertEqual(len(p.model.read_sectors), 2)
                self.assertEqual(len(p.model.formatted), 1)
                self.assertNotIn('choice', p.wait_events)
                self.assertTrue(all(status & 4 == 0 for *_, status in p.model.command_finishes))
                self.assertEqual(p.fdc_cpu_settings, {(3_500_000, 0)})
                rows[f'{128 << n}/{speed}'] = {'format_bytes': 6250, 'byte_period_us': 32 / speed,
                    'max_write_t': round(max(p.model.drq_latencies['write']), 6),
                    'max_read_t': round(max(p.model.drq_latencies['read']), 6)}
        EVIDENCE['full_transfers_3500khz'] = rows

    def test_stray_outi_intrq_does_not_change_byte_count_or_read_memory(self):
        for read in (False, True):
            p = regressions.TransferTests().probe(read, 11.001)
            self.assertEqual(p.cpu.hl, 0xAC01)
            self.assertEqual(p.word('TransferLeft'), 0)
            self.assertEqual(p.model.byte_index if read else len(p.model.output), 1)
            self.assertEqual(len(p.model.stray_writes), 0)  # полный буфер: TransferFull
            self.assertEqual(p.cpu.memory[0xAC01], 0)
            self.assertEqual(p.cpu.sp, STACK + 2)
        # INTRQ до первого байта: WRITE делает ровно один лишний OUTI и DEC HL.
        for read in (False, True):
            p = Plugin(tiny())
            p.mask = 0x80
            p.model.intrq = True
            p.poke('TransferStart', 0xAC00, 2)
            p.poke('TransferLimit', 128, 2)
            p.cpu.memory[0xAC00:0xAC02] = b'XY'
            p.call('ReadBytes.wait' if read else 'WriteBytes.wait', hl=0xAC00, bc=0x007F)
            self.assertEqual(p.cpu.hl, 0xAC00)
            self.assertEqual(p.word('TransferLeft'), 128)
            self.assertFalse(p.cpu.f & 1)
            self.assertEqual(bytes(p.cpu.memory[0xAC00:0xAC02]), b'XY')
            self.assertEqual(len(p.model.stray_writes), 0 if read else 1)

    def track_fault(self, kind, bad_tracks, persistent_sector=False, choice='a'):
        sectors = [Sector(0, 0, r, 0, bytes([r]) * 128) for r in (1, 2)]
        sectors.append(Sector(0, 0, 3, 0, b'\xf5\xf6\xf7' + b'Z' * 125, good_crc=False))
        p = Plugin(make_fdi({(0, 0): sectors}), timed=True)
        p.error_keys = [choice] if isinstance(choice, str) else list(choice)
        damaged = set()
        prompts = []
        def command(cmd):
            generation = len(p.model.formatted)
            if cmd == 0xC0 and generation <= bad_tracks and generation not in damaged:
                damaged.add(generation)
                key = p.model.key
                if kind == 'missing_id':
                    identpos, _ = p.model.layouts[key].pop(1)
                    p.model.tracks[key].pop(1)
                    p.model.track_raw[key][0][identpos + 3] = 0xFD
                else:
                    s = p.model.tracks[key][0]
                    s.data = bytes([s.data[0] ^ 1]) + s.data[1:]
                    self.assertTrue(s.good_crc)
                    _, pos = p.model.layouts[key][0]
                    raw = p.model.track_raw[key][0]
                    raw[pos:pos + 128] = s.data
                    raw[pos + 128:pos + 130] = crc16(b'\xa1' * 3 + b'\xfb' + s.data).to_bytes(2, 'big')
            if cmd == 0x80:
                if persistent_sector and generation == 3 and p.model.sector == 1:
                    # Каждая повторная запись снова портится с валидным CRC.
                    # Не XOR очереди: он мог бы исправить уже испорченный байт.
                    s = p.model.tracks[p.model.key][0]
                    s.data = b'\x02' + s.data[1:]
                    _, pos = p.model.layouts[p.model.key][0]
                    raw = p.model.track_raw[p.model.key][0]
                    raw[pos:pos + 128] = s.data
                    raw[pos + 128:pos + 130] = crc16(b'\xa1' * 3 + b'\xfb' + s.data).to_bytes(2, 'big')
                p.model.fault = None
        def wait(stage):
            if stage == 'choice':
                prompts.append({'formats': len(p.model.formatted), 'writes': len(p.model.written),
                                'reads': len(p.model.read_sectors)})
        p.model.on_command, p.on_wait = command, wait
        p.call()
        self.check_return(p)
        return p, prompts

    def test_one_and_two_bad_track_verifications_reformat_silently_count_changes_once(self):
        rows = {}
        for kind in ('wrong_data_valid_crc', 'missing_id'):
            for failures in (1, 2):
                p, prompts = self.track_fault(kind, failures)
                harness.PluginTests().check_disk(p, p.blob)
                self.assertEqual(len(p.model.formatted), failures + 1)
                self.assertEqual(len(p.model.written), 2 * (failures + 1))
                self.assertFalse(prompts)
                self.assertEqual(p.word('ApproxDone'), 1)
                self.assertEqual(p.word('ApproxBytes'), 3)
                rows[f'{kind}/{failures}'] = {'formats': len(p.model.formatted), 'changed_bytes': 3}
        EVIDENCE['silent_track_rewrites'] = rows

    def test_third_bad_track_verification_dialog_only_after_recovery_exhausted(self):
        for kind in ('wrong_data_valid_crc', 'missing_id'):
            p, prompts = self.track_fault(kind, 3, persistent_sector=True)
            self.assertEqual(p.result, 9)
            self.assertEqual(len(prompts), 1)
            self.assertEqual(prompts[0]['formats'], 3)
            self.assertEqual(len(p.model.formatted), 3)
            self.assertEqual(p.word('TracksDone'), 0)
            self.assertEqual(p.word('ApproxDone'), 0)
            self.assertEqual(p.word('ApproxBytes'), 0)
            if kind == 'wrong_data_valid_crc':
                self.assertEqual(prompts[0]['reads'], 7) # 3 fast + 4 VerifyWithChoice
                self.assertEqual(prompts[0]['writes'], 9) # 6 track + 3 sector

    def test_third_transient_bad_data_repaired_by_sector_without_dialog(self):
        p, prompts = self.track_fault('wrong_data_valid_crc', 3)
        harness.PluginTests().check_disk(p, p.blob)
        self.assertFalse(prompts)
        self.assertEqual(len(p.model.formatted), 3)
        self.assertEqual(len(p.model.written), 7)
        self.assertEqual(p.word('ApproxBytes'), 3)

    def test_third_bad_track_ignore_balances_stack_and_counts_changes_once(self):
        for kind in ('wrong_data_valid_crc', 'missing_id'):
            p, prompts = self.track_fault(kind, 3,
                                         persistent_sector=(kind == 'wrong_data_valid_crc'), choice='i')
            self.assertEqual(p.result, 0)
            self.assertEqual(len(prompts), 1)
            self.assertEqual(len(p.model.formatted), 3)
            self.assertEqual(p.word('TracksDone'), 1)
            self.assertEqual(p.word('IgnoredDone'), 1)
            self.assertEqual(p.word('ApproxDone'), 1)
            self.assertEqual(p.word('ApproxBytes'), 3)

    def test_two_independent_verification_errors_need_separate_ignores(self):
        # Отсутствует ID сектора 2, а сектор 1 каждый раз портится с верным CRC.
        # Ignore ID не разрешает молча пропустить другую ошибку данных.
        p, prompts = self.track_fault('missing_id', 3, persistent_sector=True, choice=['i', 'i'])
        self.assertEqual(p.result, 0)
        self.assertEqual(len(prompts), 2)
        self.assertEqual(prompts[0]['formats'], 3)
        self.assertEqual(prompts[0]['reads'], 0)
        self.assertEqual(prompts[1]['reads'], 4)
        self.assertEqual(p.word('IgnoredDone'), 2)
        self.assertEqual(p.word('TracksDone'), 1)
        self.assertEqual(p.word('ApproxDone'), 1)
        self.assertEqual(p.word('ApproxBytes'), 3)

    def test_track_recovery_fatal_and_esc_exit_paths_restore_stack_and_frequency(self):
        rows = {}
        for stage, error, formats in (('RunDisk.badtrack', 'disk', 1),
                                      ('RunDisk.badtrack', 'wp', 1),
                                      ('RunDisk.badtrack', 'esc', 1),
                                      ('RunDisk.bysector', 'disk', 3),
                                      ('VerifySlow', 'disk', 3),
                                      ('VerifySlow', 'esc', 3)):
            p = Plugin(tiny(), fault='mismatch', saved_cpu_hz=14_000_000, saved_cache=2)
            address = SYMS[stage]
            p.cpu.set_breakpoint(address)
            reached = []
            def inject():
                reached.append(len(p.model.formatted))
                if error == 'disk': p.model.has_disk = False
                elif error == 'wp': p.model.protected = True
                else: p.cpu.memory[0x6004] = 1
            p.hooks[address] = inject
            p.call()
            self.check_return(p)
            self.assertEqual(reached, [formats])
            self.assertEqual(p.result, {'disk': 4, 'wp': 5, 'esc': 9}[error])
            self.assertNotIn('choice', p.wait_events)
            self.assertEqual(p.word('TracksDone'), 0)
            self.assertEqual([e['b'] for e in p.frequency_events], [0, 255, 0, 255])
            self.assertEqual(p.frequency_events[0]['fdc_access_count'], 0)
            self.assertEqual(p.frequency_events[-1]['fdc_access_count'], p.fdc_access_count)
            self.assertEqual(p.fdc_cpu_settings, {(3_500_000, 0)})
            self.assertEqual((p.cpu_frequency, p.cache), p.saved_cpu_settings)
            rows[f'{stage}/{error}'] = {'result': p.result, 'formats_before_error': formats,
                                       'returned_sp': p.cpu.sp}
        EVIDENCE['track_recovery_fatal_exits'] = rows

    def sector_fixture(self, bad_crc=False):
        blob = make_fdi({(0, 0): [Sector(0, 0, 1, 0, b'Z' * 128, good_crc=not bad_crc)]})
        p = Plugin(blob)
        p.call()
        p.call('ShowWindow')
        p.call('MapTrack')
        p.mask = 0x80
        p.poke('FdcOpen', 0x80)
        p.poke('SectorIndex', 0)
        p.cpu.memory[0x6004] = 0
        p.keyboard.release()
        p.model.sys = 0x3C
        p.model.load_head()
        p.model.motor_since[0] -= 5 * p.model.period
        p.poke('LastCmd', p.word(0x6009), 2)
        p.model.commands.clear()
        p.model.written.clear()
        p.model.read_sectors.clear()
        p.wait_events.clear()
        return p

    def run_sector_cycle(self, choice, bad_crc=False, failures=99):
        p = self.sector_fixture(bad_crc)
        reads = [0]
        prompts = []
        p.error_keys = [choice]
        def command(cmd):
            if cmd == 0x80:
                reads[0] += 1
                p.model.fault = 'mismatch' if reads[0] <= failures else None
        def wait(stage):
            if stage == 'choice':
                prompts.append(reads[0])
                if choice == 'r': p.model.fault = None
        p.model.on_command, p.on_wait = command, wait
        p.call('VerifyWithChoice', iy=SYMS['TrackDesc'] + 7)
        self.assertEqual(p.cpu.sp, STACK + 2)
        return p, prompts

    def test_verifywithchoice_rewrites_between_verifications_and_fourth_failure_prompts(self):
        p, prompts = self.run_sector_cycle('a')
        sequence = [cmd for cmd, *_ in p.model.commands if cmd in (0x80, 0xA0)]
        self.assertEqual(sequence, [0x80, 0xA0, 0x80, 0xA0, 0x80, 0xA0, 0x80])
        self.assertEqual(prompts, [4])
        self.assertTrue(p.cpu.f & 1)
        self.assertEqual(p.cpu.a, 9)

    def test_verifywithchoice_retry_restarts_cycle_and_can_succeed(self):
        p, prompts = self.run_sector_cycle('r', failures=5)
        self.assertEqual(prompts, [4])
        self.assertFalse(p.cpu.f & 1)
        sequence = [cmd for cmd, *_ in p.model.commands if cmd in (0x80, 0xA0)]
        self.assertEqual(sequence, [0x80, 0xA0, 0x80, 0xA0, 0x80, 0xA0, 0x80,
                                    0x80, 0xA0, 0x80])
        self.assertEqual(p.word('IgnoredDone'), 0)

    def test_verifywithchoice_ignore_marks_sector_once(self):
        p, prompts = self.run_sector_cycle('i')
        self.assertEqual(prompts, [4])
        self.assertFalse(p.cpu.f & 1)
        self.assertEqual(p.cpu.memory[SYMS['Ignored']], 1)
        self.assertEqual(p.word('IgnoredDone'), 1)
        p.call('MarkIgnored')
        self.assertEqual(p.word('IgnoredDone'), 1)

    def test_verifywithchoice_bad_crc_rereads_without_write_sector_even_on_retry(self):
        p, prompts = self.run_sector_cycle('r', bad_crc=True, failures=5)
        self.assertEqual(prompts, [4])
        self.assertFalse(p.cpu.f & 1)
        self.assertEqual(len(p.model.read_sectors), 6)
        self.assertFalse(p.model.written)
        self.assertFalse(any(cmd & 0xE0 == 0xA0 for cmd, *_ in p.model.commands))
        self.assertFalse(p.model.tracks[(0, 0, 0)][0].good_crc)

    def test_verifywithchoice_rewrite_failure_is_bounded_and_fatal_exits_balance_stack(self):
        for error in ('write_sector', 'disk', 'wp', 'esc'):
            p = self.sector_fixture()
            def command(cmd):
                if cmd == 0x80: p.model.fault = 'mismatch'
                if cmd & 0xE0 == 0xA0:
                    if error == 'disk': p.model.has_disk = False
                    elif error == 'wp': p.model.protected = True
                    else: p.model.fault = 'write_sector'
                    if error == 'esc': p.cpu.memory[0x6004] = 1
            p.model.on_command = command
            p.error_keys = ['a']
            p.call('VerifyWithChoice', iy=SYMS['TrackDesc'] + 7)
            self.assertTrue(p.cpu.f & 1)
            self.assertEqual(p.cpu.a, {'write_sector': 9, 'disk': 4, 'wp': 5, 'esc': 9}[error])
            self.assertEqual(p.cpu.sp, STACK + 2)
            self.assertLessEqual(len(p.model.written), 3)

    def test_stuck_drq_fixed_limits_and_plugin_exit_restore(self):
        from test_eighth import check_stuck_plugin_exit
        check_stuck_plugin_exit(self)


if __name__ == '__main__':
    unittest.main()
