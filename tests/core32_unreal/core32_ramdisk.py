"""Real FILEX/core/extension with bank switching; sector driver backed by RAM."""
import time
import core32_machine as p


class Volume:
    def __init__(self, original=0x1FF01, free=66000):
        self.cpu = p.base(True)
        self.mem = self.cpu.memory
        self.original = original
        self.original_clusters = (original + 511) // 512
        self.limit = 3 + self.original_clusters + free
        self.fat_sectors = (self.limit + 127) // 128
        self.fat_start = 32
        self.data_start = self.fat_start + self.fat_sectors
        self.disk = bytearray((self.data_start + self.limit - 2) * 512)
        self.disk[512:1024] = p.h.make_fsinfo(3 + self.original_clusters)
        self.position = 0
        self.page = 0xE9
        self.pages = {
            0xE9: bytearray(self.mem[0xC000:]),
            0xE8: bytearray((p.ROOT / 'Build/CORE32_EXT.bin').read_bytes()).ljust(0x4000, b'\0'),
        }
        self.cpu.set_input_callback(lambda port: self.page if port == 0x13AF else 255)
        self.cpu.set_output_callback(self.output)
        self.reads = self.writes = 0
        self.events = []
        for cluster in range(self.fat_sectors * 128):
            self.set_fat(cluster, 0x0FFFFFFF)
        for cluster in range(3, 3 + self.original_clusters - 1):
            self.set_fat(cluster, cluster + 1)
        for cluster in range(3 + self.original_clusters, self.limit):
            self.set_fat(cluster, 0)
        start = (self.data_start + 1) * 512
        self.disk[start:start + original] = b'\xA5' * original
        entry = bytearray(32)
        entry[:11] = b'AUDIT   BIN'
        entry[11] = 0x20
        p.h.put16(entry, 26, 3)
        p.h.put32(entry, 28, original)
        self.disk[self.data_start * 512:self.data_start * 512 + 32] = entry
        for name, value in {
            'BFTSZ': self.fat_sectors, 'SFAT': self.fat_start,
            'SDFAT': self.data_start, 'ADDTOP': 0, 'BROOTC': 2,
            'FSTFRC': 3 + self.original_clusters, 'FSINF': 1,
        }.items():
            p.h.put32(self.mem, self.core(name), value)
        self.mem[self.core('BSECPC')] = self.mem[self.core('BFATS')] = 1
        self.mem[self.core('FATFLAGS')] = 0
        ext = self.pages[0xE8]
        put = lambda name, value: p.h.put32(ext, self.ext(name) - 0xC000, value)
        put('FAT_DATA_CLUSTER_LIMIT', self.limit)
        put('APPEND_DIRECTORY_LBA', self.data_start)
        p.h.put16(ext, self.ext('APPEND_DIRECTORY_OFFSET') - 0xC000, 0)
        offset = self.ext('APPEND_ENTRY') - 0xC000
        ext[offset:offset + 32] = entry
        ext[self.ext('APPEND_VALID') - 0xC000] = 1
        ext[self.ext('APPEND_READY') - 0xC000] = 0
        self.mem[self.core('ENTRY'):self.core('ENTRY') + 32] = entry
        self.callbacks = {
            self.core('XPOZI'): self.position_and_remember,
            self.core('PROZ'): self.seek,
            self.core('RDDSE'): self.read,
            self.core('SDDSE'): self.write,
        }

    def core(self, name):
        return p.BOOT['WDOS.' + name]

    def ext(self, name):
        return p.EXT['WDOS_EXT.' + name]

    def output(self, port, value):
        if port != 0x13AF:
            return
        assert value in self.pages, hex(value)
        self.pages[self.page][:] = self.mem[0xC000:]
        self.mem[0xC000:] = self.pages[value]
        self.page = value

    def set_fat(self, cluster, value):
        p.h.put32(self.disk, self.fat_start * 512 + cluster * 4, value)

    def fat(self, cluster):
        return p.h.get32(self.disk, self.fat_start * 512 + cluster * 4) & 0x0FFFFFFF

    def position_and_remember(self):
        # XPOZI сохраняет базовый LBA, PROZ меняет только позицию драйвера.
        p.h.put32(self.mem, self.core('LTHL'), self.cpu.de * 65536 + self.cpu.hl)
        self.seek()

    def seek(self):
        self.position = self.cpu.de * 65536 + self.cpu.hl
        p.ret(self.cpu)

    def transfer(self, write):
        count = self.cpu.a or 256
        size = count * 512
        start = self.position * 512
        assert start + size <= len(self.disk), ('disk range', self.position, count)
        assert self.cpu.hl + size <= 65536, ('buffer range', self.cpu.hl, count)
        if write:
            self.disk[start:start + size] = self.mem[self.cpu.hl:self.cpu.hl + size]
            self.writes += count
        else:
            self.mem[self.cpu.hl:self.cpu.hl + size] = self.disk[start:start + size]
            self.reads += count
        self.cpu.hl = (self.cpu.hl + size) & 65535
        self.mem[self.core('ABT')] = 0
        p.ret(self.cpu)

    def read(self):
        self.transfer(False)

    def write(self):
        self.transfer(True)

    def state(self):
        cursor = 3
        chain = []
        while cursor < 0x0FFFFFF8:
            assert 2 <= cursor < self.limit, ('bad link', cursor)
            chain.append(cursor)
            cursor = self.fat(cursor)
            assert len(chain) <= self.limit, 'cycle'
        return dict(declared_size=p.h.get32(self.disk, self.data_start * 512 + 28),
                    chain_bytes=len(chain) * 512, free_clusters=sum(self.fat(n) == 0 for n in range(2, self.limit)),
                    original_bytes_unchanged=self.disk[(self.data_start + 1) * 512:(self.data_start + 1) * 512 + self.original] == b'\xA5' * self.original)

    def operation(self, target):
        cpu = self.cpu
        block = 0x9000
        self.mem[block:block + 32] = bytes(32)
        self.mem[block + p.FX['FILEX_P_SIZE']] = 32
        self.mem[block + p.FX['FILEX_P_VERSION']] = p.FX['FILEX_API_VERSION']
        self.mem[block + p.FX['FILEX_P_OPERATION']] = p.FX['FILEX_OP_SET_EOF32']
        p.h.put32(self.mem, block + p.FX['FILEX_P_OFFSET'], target)
        cpu.hl, cpu.pc, cpu.sp = block, p.FX['FILEX_ENTRY'], p.STACK
        p.h.put16(self.mem, p.STACK, p.STOP)
        observations = {
            p.FX['FILEX_GROW_TO_TARGET']: 'growth_started',
            p.FX['FILEX_GROW_TO_TARGET.append_failed']: 'append_failed',
            p.FX['FILEX_SHRINK_TO_TARGET']: 'shrink_started',
        }
        for address in {p.STOP, *self.callbacks, *observations}:
            cpu.set_breakpoint(address)
        start = time.monotonic()
        pending = None
        while True:
            cpu.ticks_to_stop = 1000000
            event = cpu.run()
            if pending is not None:
                cpu.set_breakpoint(pending)
                pending = None
            if event & 2:
                address = cpu.pc
                if address == p.STOP:
                    break
                if address in self.callbacks:
                    self.callbacks[address]()
                elif address in observations:
                    if self.page == 0xE9:
                        self.events.append(dict(event=observations[address], status=cpu.a,
                                                writes=self.writes,
                                                declared_size=p.h.get32(self.disk, self.data_start * 512 + 28)))
                    cpu.clear_breakpoint(address)
                    pending = address
                # Page switching can yield a breakpoint event after the
                # instruction at a watched address; resume at the new PC.
            now = time.monotonic()
            if now - start > 240:
                raise RuntimeError(('timeout', hex(cpu.pc), self.page, self.reads, self.writes))
        return dict(original=self.original, target=target, status=cpu.a,
                    block_status=self.mem[block + p.FX['FILEX_P_STATUS']],
                    reads=self.reads, writes=self.writes, elapsed=round(time.monotonic() - start, 3),
                    events=self.events,
                    **self.state())
