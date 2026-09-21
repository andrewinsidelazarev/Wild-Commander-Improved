"""Регрессии потери данных, прозрачности шлюза и граничных счётчиков."""
import gc
import hashlib
import unittest
import core32_machine as p
from core32_ramdisk import Volume


def alt_af(cpu, value=None):
    field = cpu._Z80State__alt_af
    if value is not None:
        field[:] = value.to_bytes(2, 'little')
    return int.from_bytes(field, 'little')


def iff(cpu, enabled=None):
    if enabled is not None:
        cpu._Z80State__iff1[0] = cpu._Z80State__iff2[0] = int(enabled)
    return bool(cpu._Z80State__iff1[0])


class GateTests(unittest.TestCase):
    def exercise(self, *, enabled, nested, changed_outputs, race=False, timer=0, caller=0x9000):
        cpu = p.base()
        mem = cpu.memory
        current_page = [0xE9]
        pages = {0xE8: bytearray(mem[0xC000:]), 0xE9: bytearray(0x4000)}
        def out(port, value):
            if port == 0x13AF:
                pages[current_page[0]][:] = mem[0xC000:]
                mem[0xC000:] = pages[value]
                current_page[0] = value
        cpu.set_input_callback(lambda port: current_page[0] if port == 0x13AF else 255)
        cpu.set_output_callback(out)
        # Два ID направлены в тестовые функции; сам шлюз и его эпилог настоящие.
        for ident, target in ((3, 0x8800 if nested else 0x8900), (4, 0x8900)):
            offset = p.EXT['WDOS_EXT.ENTRY_TABLE'] - 0xC000 + ident * 3
            pages[0xE8][offset:offset + 3] = b'\xC3' + target.to_bytes(2, 'little')
        mem[0x8800:0x8805] = bytes.fromhex('cd235104c9')
        mem[0x8900] = 0xC9
        program = bytes.fromhex('cd235103c9')
        mem[0xC000:] = pages[0xE9]
        mem[caller:caller + len(program)] = program
        cpu.af, cpu.bc, cpu.de, cpu.hl = 0x5A95, 0x1122, 0x3344, 0x5566
        cpu.ix, cpu.iy = 0x7788, 0xABCD
        cpu.alt_bc, cpu.alt_de, cpu.alt_hl = 0xBEEF, 0xCAFE, 0x1234
        alt_af(cpu, 0xC369)
        expected = {name: getattr(cpu, name) for name in ('af', 'bc', 'de', 'hl', 'ix', 'iy', 'alt_bc', 'alt_de', 'alt_hl')}
        expected_alt = alt_af(cpu)
        mem[0x6009] = timer
        iff(cpu, enabled)
        leaf_seen = []
        def leaf(machine):
            nonlocal expected_alt
            self.assertEqual({n: getattr(machine, n) for n in expected}, expected)
            self.assertEqual(alt_af(machine), expected_alt)
            self.assertFalse(iff(machine))
            leaf_seen.append(True)
            if changed_outputs:
                for name in expected:
                    if name != 'iy':
                        expected[name] ^= 0xA55A
                        setattr(machine, name, expected[name])
                expected_alt ^= 0x96C3
                alt_af(machine, expected_alt)
            p.ret(machine)
        callbacks = {0x8900: leaf}
        if race:
            # Модель документированной гонки: обработчик WC уже увеличил
            # таймер и вернулся, но LD A,I оставил ложный P/V=0.
            point = p.BOOT['WDOS.EXTENSION_GATE_READ_IFF'] + 2
            def interrupt_return(machine):
                machine.f &= ~4
                mem[0x6009] = (mem[0x6009] + 1) & 255
                machine.clear_breakpoint(point)
            callbacks[point] = interrupt_return
        p.run(cpu, caller, callbacks)
        self.assertTrue(leaf_seen)
        self.assertEqual({n: getattr(cpu, n) for n in expected}, expected)
        self.assertEqual(alt_af(cpu), expected_alt)
        self.assertEqual(cpu.sp, p.STACK + 2)
        self.assertEqual(current_page[0], 0xE9)
        self.assertEqual(iff(cpu), enabled)

    def test_registers_outputs_nested_pages_and_return_carry(self):
        for enabled in (False, True):
            for nested in (False, True):
                for changed in (False, True):
                    for caller in (0x9000, 0xC0FC):
                        with self.subTest(enabled=enabled, nested=nested, changed=changed, caller=caller):
                            self.exercise(enabled=enabled, nested=nested, changed_outputs=changed, caller=caller)

    def test_iff_false_parity_after_wc_interrupt(self):
        for timer in (0, 255):
            self.exercise(enabled=True, nested=True, changed_outputs=True, race=True, timer=timer)


class FilesystemTests(unittest.TestCase):
    def tearDown(self):
        gc.collect()

    def test_append_fresh_context_cluster_counters(self):
        for spc in (1, 8):
            for clusters in (0xFF00, 0xFF01, 0xFFFF, 0x10000, 0x1FF01, 0x1FF02, 0x2FF02):
                for partial in (False, True):
                    with self.subTest(spc=spc, clusters=hex(clusters), partial=partial):
                        harness = p.h.ExtensionHarness()
                        cpu = harness.machine
                        total = clusters + int(partial)
                        harness.fat_entries = {n: n + 1 for n in range(2, total + 1)}
                        harness.fat_entries[total + 1] = 0x0FFFFFFF
                        cpu.memory[harness.core['BSECPC']] = spc
                        p.h.put32(cpu.memory, harness.ext_address('APPEND_SIZE'), clusters * spc * 512 + int(partial))
                        p.h.put32(cpu.memory, harness.ext_address('APPEND_FIRST_CLUSTER'), 2)
                        callbacks = {address: (lambda machine, fn=fn: fn()) for address, fn in harness.callouts.items()}
                        p.run(cpu, harness.ext_address('APPEND_PREPARE.nonzero_size'), callbacks)
                        self.assertEqual(cpu.a, 0)
                        self.assertEqual(p.h.get32(cpu.memory, harness.ext_address('APPEND_CURRENT_CLUSTER')), total + 1)
                        self.assertEqual(len(harness.curit_calls), total - 1)

    def test_preflight_cluster_counters(self):
        for required in (0xFF00, 0xFF01, 0xFFFF, 0x10000, 0x1FF01):
            with self.subTest(required=hex(required)):
                volume = Volume(original=0x1FF01, free=132000)
                mem = volume.mem
                p.h.put32(mem, p.FX['FILEX_FILE_SIZE'], volume.original)
                p.h.put32(mem, p.FX['FILEX_TARGET_SIZE'], (volume.original_clusters + required) * 512)
                callbacks = {address: (lambda cpu, fn=fn: fn()) for address, fn in volume.callbacks.items()}
                hint = p.h.get32(mem, volume.core('FSTFRC'))
                p.run(volume.cpu, p.FX['FILEX_PREFLIGHT_GROWTH'], callbacks)
                self.assertEqual(volume.cpu.a, 0)
                self.assertEqual(volume.writes, 0)
                self.assertEqual(p.h.get32(mem, volume.core('FSTFRC')), hint)
                del volume
                gc.collect()

    def test_insufficient_growth_leaves_whole_volume_unchanged(self):
        volume = Volume(original=0x1FF01, free=66000)
        before = hashlib.sha256(volume.disk).digest()
        result = volume.operation((volume.original_clusters + 0x1FF01) * 512)
        self.assertEqual(result['status'], 0x22)
        self.assertEqual(result['writes'], 0)
        self.assertFalse(result['events'])
        self.assertEqual(hashlib.sha256(volume.disk).digest(), before)

    def test_shrink_byte_boundaries(self):
        for target in (0xFF00, 0xFF01, 0xFFFF, 0x10000, 0x10001, 0x1FF01, 0x1FFFF, 0x20000):
            with self.subTest(target=hex(target)):
                volume = Volume(original=target + 65536, free=66000)
                result = volume.operation(target)
                self.assertEqual(result['status'], 0)
                self.assertEqual(result['declared_size'], target)
                capacity = (target + 511) // 512 * 512
                self.assertEqual(result['chain_bytes'], capacity)
                start = (volume.data_start + 1) * 512
                self.assertEqual(volume.disk[start:start + target], b'\xA5' * target)
                self.assertEqual(volume.disk[start + target:start + capacity], bytes(capacity - target))
                del volume
                gc.collect()

    def test_grow_io_failure_rolls_back_original_window_size(self):
        volume = Volume(original=0x1FF01, free=66000)
        write = volume.callbacks[volume.core('SDDSE')]
        failed = []
        def fail_once():
            size = p.h.get32(volume.disk, volume.data_start * 512 + 28)
            if not failed and size > volume.original and volume.position > volume.data_start:
                failed.append(True)
                volume.mem[volume.core('ABT')] = 1
                p.ret(volume.cpu)
            else:
                write()
        volume.callbacks[volume.core('SDDSE')] = fail_once
        result = volume.operation(volume.original + 8192)
        self.assertTrue(failed)
        self.assertEqual(result['status'], 0x21)
        self.assertEqual(result['declared_size'], volume.original)
        self.assertEqual(result['chain_bytes'], volume.original_clusters * 512)
        self.assertTrue(result['original_bytes_unchanged'])
        self.assertEqual(result['free_clusters'], 66000)

    def test_invalid_fat_sector_never_positions_data(self):
        cpu = p.base()
        core = lambda name: p.BOOT['WDOS.' + name]
        p.h.put32(cpu.memory, core('BFTSZ'), 1)
        p.h.put32(cpu.memory, 1, 42)
        cpu.hl, cpu.de = 128, 0
        visited = []
        def position(machine):
            visited.append(machine.hl)
            p.ret(machine)
        p.run(cpu, p.EXT['WDOS_EXT.STREAM_NEXT_CLUSTER'], {core('XPOZI'): position})
        self.assertTrue(cpu.f & 1)
        self.assertEqual(cpu.memory[core('ABT')], 0xFE)
        self.assertEqual(cpu.memory[core('EOC')], 0xFF)
        self.assertFalse(visited)


class StreamHandlerTests(unittest.TestCase):
    # LOADNON (API 61) и LOAD256 (API 60) идут через STREAM_WITH_HANDLER: он
    # ставит обработчик DE в NW0, зовёт LOAD512 и возвращает прежний. Прежний
    # код сохранял обработчик через BC и затирал число блоков B старшим байтом
    # адреса SAFE_RDDSE (#51): вызов проходил ~81 блок вместо B.
    def test_block_count_buffer_and_previous_handler_preserved(self):
        core = lambda name: p.BOOT['WDOS.' + name]
        for blocks in (1, 2, 255):
            with self.subTest(blocks=blocks):
                cpu = p.base()
                previous = p.h.get16(cpu.memory, core('NW0') + 1)
                seen = []

                def load512(machine):
                    seen.append((machine.b, machine.hl, p.h.get16(machine.memory, core('NW0') + 1)))
                    machine.a, machine.hl = 0x0F, 0x9E00
                    p.ret(machine)

                cpu.bc, cpu.de, cpu.hl = blocks << 8 | 0x3C, core('Z0'), 0x8000
                p.run(cpu, p.EXT['WDOS_EXT.STREAM_WITH_HANDLER'], {core('LOAD512'): load512})
                self.assertEqual(seen, [(blocks, 0x8000, core('Z0'))])
                self.assertEqual(p.h.get16(cpu.memory, core('NW0') + 1), previous)
                # Результат LOAD512 (A, HL) доходит до вызывающего.
                self.assertEqual((cpu.a, cpu.hl), (0x0F, 0x9E00))


if __name__ == '__main__':
    unittest.main(verbosity=2)
