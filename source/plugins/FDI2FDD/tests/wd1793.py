"""Функциональная модель FD1793-02 в MFM, без аналога магнитного канала.

Порты, команды, CRC, DRQ/INTRQ, физическое положение и track register разделены.
Обычный режим ускоряет вращение: один индекс/поиск — несколько опросов.
Timed-режим берёт такты настоящего Z80 для DRQ и индекса (250 kbit/s, 300 rpm).
"""
from collections import defaultdict
from fdi import Sector


def crc16(data, value=0xFFFF):
    for byte in data:
        value ^= byte << 8
        for _ in range(8):
            value = ((value << 1) ^ (0x1021 if value & 0x8000 else 0)) & 0xFFFF
    return value


def decode_track(raw, clocks, capacity):
    if len(raw) > capacity:
        raise AssertionError(f'track overflow: {len(raw)} > {capacity}')
    ids = [i for i in range(len(raw) - 9)
           if raw[i:i + 4] == b'\xa1\xa1\xa1\xfe' and clocks[i:i + 3] == [1, 1, 1]]
    sectors = []
    for index, i in enumerate(ids):
        c, h, r, n = raw[i + 4:i + 8]
        end = ids[index + 1] if index + 1 < len(ids) else len(raw)
        for j in range(i + 10, end - 3):
            if (raw[j:j + 3] == b'\xa1\xa1\xa1' and clocks[j:j + 3] == [1, 1, 1]
                    and 0xF8 <= raw[j + 3] <= 0xFB):
                length = 128 << (n & 3)  # длину 1793 выбирают два младших бита N
                payload = bytes(raw[j + 4:j + 4 + length])
                crcpos = j + 4 + length
                if len(payload) != length or crcpos + 2 > end:
                    break
                good = int.from_bytes(raw[crcpos:crcpos + 2], 'big') == crc16(raw[j:crcpos])
                idgood = int.from_bytes(raw[i + 8:i + 10], 'big') == crc16(raw[i:i + 8])
                sectors.append(Sector(c, h, r, n, payload, raw[j + 3] in (0xF8, 0xF9), good, idgood))
                break
    return sectors


class WD1793:
    def __init__(self, capacity=6250, drive=True, disk=True, protected=False,
                 fault=None, timed=False, frequency=3_500_000, now=lambda: 0,
                 motor_idle_revolutions=10, spin_revolutions=5, moonsound=False,
                 report_head_loaded_after_d0=True, absent_bus=None,
                 disk_speed=1, probe_success_attempt=1, sector_latch_us=0):
        assert absent_bus is None or 0 <= absent_bus <= 255
        self.absent_bus = absent_bus   # все порты отсутствующего FDC читают константу
        self.disk_speed = disk_speed
        self.probe_success_attempt, self.probe_attempts = probe_success_attempt, 0
        self.probe_history = []         # попытки отдельно для каждого OpenFDC
        self.probing = True
        self.sector_latch_us, self.pending_sector = sector_latch_us, None
        self.stray_writes = []
        self.capacity, self.has_drive, self.has_disk = capacity, drive, disk
        self.protected, self.fault, self.timed = protected, fault, timed
        self.frequency, self.now = frequency, now
        self.tracks = {}  # (drive, physical cylinder, side), порядок секторов
        self.positions = [0, 0, 0, 0]
        self.sys, self.track, self.sector, self.data = 0x3C, 0, 1, 0
        self.command, self.status = 0xD0, 0
        self.busy, self.drq, self.intrq = False, False, False
        self.operation = None
        self.queue, self.output = b'', bytearray()
        self.raw, self.clocks, self.crc = bytearray(), [], 0xFFFF
        self.polls, self.wait, self.byte_index = 0, 0, 0
        self.id_cursor = defaultdict(int)
        self.commands, self.formatted, self.written = [], [], []
        self.writes = 0
        self.deadline, self.ready_at, self.started = 0, 0, 0
        self.on_command = lambda cmd: None
        self.max_expanded = 0
        self.direction = 1
        self.finish_at, self.end_status = 0, 0
        self.last_force = None
        self.layouts, self.command_times, self.track_times = {}, [], {}
        self.command_finishes = []
        self.track_raw = {}
        self.read_ids, self.read_sectors = [], []
        self.motor_idle_revolutions = motor_idle_revolutions
        # Вариант стенда: после D0 idle status не сообщает HLD, хотя мотор
        # продолжает вращаться. Меняем только bit 5, не INDEX/DRQ и не таймер.
        self.report_head_loaded_after_d0 = report_head_loaded_after_d0
        self.spin_revolutions = spin_revolutions
        self.motor_since = [None] * 4
        self.motor_last = [0] * 4
        self.motor_starts, self.unsafe_commands = [], []
        self.spin_corrupt = False
        self.moonsound, self.sound_bytes = moonsound, []
        self.drq_latencies = {'read': [], 'write': []}

    def begin_probe(self):
        """Новый доступ через #29AF=80: обе пробы регистра нужны снова."""
        self.probing, self.probe_attempts = True, 0
        self.probe_history.append(0)

    @property
    def motor_clock(self):
        # Быстрый режим ускоряет индекс; пауза хоста всё равно останавливает мотор.
        return self.now() + (0 if self.timed else self.polls * self.period / 32)

    @property
    def head_loaded(self):
        started = self.motor_since[self.drive]
        if started is None or not self.sys & 8 or not self.has_drive:
            return False
        if not self.busy and self.motor_clock - self.motor_last[self.drive] >= self.motor_idle_revolutions * self.period:
            self.motor_since[self.drive] = None
            return False
        return True

    def load_head(self):
        if not self.head_loaded:
            self.motor_since[self.drive] = self.motor_clock
            self.motor_starts.append((self.drive, self.now()))
        self.motor_last[self.drive] = self.motor_clock

    @property
    def at_speed(self):
        return (self.head_loaded and self.motor_clock - self.motor_since[self.drive]
                >= self.spin_revolutions * self.period)

    def service_ticks(self, operation=None):
        # FD179X, 1 MHz clock / 250 kbit/s: WRITE 23.5 us, READ 27 us.
        write = (operation or self.operation) in ('format', 'write')
        return round(self.frequency * (23.5e-6 if write else 27e-6))

    @property
    def period(self):
        return self.capacity * self.byte_ticks

    @property
    def angular_position(self):
        """Позиция в физических байтах от INDEX, включая промежутки команд."""
        return (self.now() % self.period) / self.byte_ticks

    @property
    def revolutions(self):
        return self.now() / self.period

    def next_position(self, bytepos):
        current = self.now()
        target = (current // self.period) * self.period + bytepos * self.byte_ticks
        return target if target > current else target + self.period

    @property
    def drive(self):
        return self.sys & 3

    @property
    def side(self):
        return 0 if self.sys & 0x10 else 1

    @property
    def key(self):
        return self.drive, self.positions[self.drive], self.side

    @property
    def byte_ticks(self):
        return self.frequency * 32e-6 / self.disk_speed

    @property
    def index(self):
        if not self.has_disk or not self.head_loaded:
            return False
        if self.timed:
            return self.angular_position < 62.5
        return self.polls % 32 < 2

    def finish(self, status=0):
        self.command_finishes.append((self.command, self.key, self.now(), status))
        if self.timed and self.key in self.track_times:
            self.track_times[self.key][1] = self.now()
        self.busy, self.drq, self.intrq = False, False, True
        self.status, self.operation = status, None
        self.motor_last[self.drive] = self.motor_clock

    def start(self, cmd):
        self.latch_sector()
        if self.timed and self.last_force is not None:
            assert self.now() - self.last_force >= self.frequency * 16e-6, 'FORCE INTERRUPT quiet time'
        self.command = cmd
        self.commands.append((cmd, self.key, self.track, self.sector))
        self.command_times.append((cmd, self.key, self.now(), self.angular_position))
        self.on_command(cmd)
        if cmd & 0xF0 == 0xD0:
            if not self.busy:
                self.status = 0          # idle FORCE: обновляется type I status
            self.last_force = self.now()
            self.busy, self.drq = False, False
            self.intrq = bool(cmd & 15)  # D0 не вызывает INTRQ
            self.operation = None
            return
        self.probing = False
        self.spin_corrupt = False
        if cmd < 0x80 and cmd & 8:
            self.load_head()
        elif cmd >= 0x80:
            ready = self.at_speed
            self.load_head()              # type II/III сами поднимают HLD
            if not ready:
                self.unsafe_commands.append((cmd, self.key, self.now()))
                self.spin_corrupt = True
        self.busy, self.intrq, self.drq, self.status = True, False, False, 0
        self.started = self.now()
        self.wait, self.byte_index, self.output = 3, 0, bytearray()
        self.finish_at = 0
        if cmd < 0x80:
            self.operation = 'type1'
            if cmd & 0xF0 == 0:
                if self.has_drive:
                    self.positions[self.drive] = 0
                self.track = 0
            elif cmd & 0xF0 == 0x10:
                # SEEK использует разность Data/Track, не абсолютный physical C.
                if self.has_drive:
                    self.positions[self.drive] += self.data - self.track
                    self.positions[self.drive] = max(0, min(255, self.positions[self.drive]))
                self.track = self.data
            elif cmd & 0xE0 in (0x20, 0x40, 0x60):
                if cmd & 0xE0 != 0x20:
                    self.direction = -1 if cmd & 0xE0 == 0x60 else 1
                self.positions[self.drive] = max(0, self.positions[self.drive] + self.direction)
                if cmd & 0x10:
                    self.track = (self.track + self.direction) & 255
            return
        if not self.has_drive or not self.has_disk:
            self.operation, self.status = 'missing', 0x80
            return
        if cmd & 0xE0 == 0xA0 or cmd & 0xF0 == 0xF0:
            if self.protected:
                self.operation, self.status = 'missing', 0x40
                return
        if self.fault == 'stall':
            self.operation = 'stall'
            return
        if cmd & 0xF0 == 0xF0:
            self.operation = 'format'
            self.raw, self.clocks, self.crc = bytearray(), [], 0xFFFF
            # Первый DRQ сразу: байт должен быть загружен до первого индекса.
            period = self.period
            self.ready_at = self.now() + (round(self.frequency * .030) if cmd & 4 else 0)
            self.first_index = (self.ready_at // period + 1) * period
            self.deadline = self.first_index
            self.format_started = False
            self.track_times[self.key] = [self.now(), self.now()]
            return
        sectors = self.tracks.get(self.key, [])
        if cmd & 0xF0 == 0xC0:
            if not sectors:
                self.operation, self.status = 'missing', 0x10
                self.finish_at = self.now() + 5 * self.period
                return
            if self.timed:
                layout = self.layouts[self.key]
                index = min(range(len(sectors)), key=lambda i: self.next_position(layout[i][0]))
                found_at = self.next_position(layout[index][0])
            else:
                index = self.id_cursor[self.key] % len(sectors)
            self.id_cursor[self.key] += 1
            s = sectors[index]
            ident = bytes(s.id)
            self.queue = ident + crc16(b'\xa1' * 3 + b'\xfe' + ident).to_bytes(2, 'big')
            self.sector = s.c             # READ ADDRESS переносит C в sector register
            self.operation, self.status = 'read', 0 if s.good_id_crc else 8
            self.read_ids.append((self.key, s.id))
            if self.fault == 'id_mismatch':
                self.queue = bytes([self.queue[0] ^ 1]) + self.queue[1:]
        elif cmd & 0xE0 in (0x80, 0xA0):
            s = next((s for s in sectors if s.c == self.track and s.r == self.sector
                      and (not cmd & 8 or s.h == ((cmd >> 1) & 1)) and s.good_id_crc), None)
            if s is None:
                self.operation, self.status = 'missing', 0x10
                self.finish_at = self.now() + 5 * self.period
                return
            self.active = s
            if self.timed:
                identpos, datapos = self.layouts[self.key][sectors.index(s)]
                found_at = self.next_position(identpos)
                self.write_data_at = found_at + (datapos - identpos) * self.byte_ticks
            if cmd & 0xE0 == 0x80:
                self.operation = 'read'
                self.queue = s.data[:128 << (s.n & 3)]
                self.read_sectors.append((self.key, s.id))
                self.status = (0 if s.good_crc else 8) | (32 if s.deleted else 0)
                if self.fault == 'mismatch':
                    self.queue = bytes([self.queue[0] ^ 1]) + self.queue[1:]
                if self.fault == 'read_crc':
                    self.status |= 8
                if self.fault == 'rnf':
                    self.operation, self.status = 'missing', 0x10
                    self.finish_at = self.now() + 5 * self.period
                    return
            else:
                self.operation = 'write'
                self.length = 128 << (s.n & 3)
        else:
            raise AssertionError(f'unimplemented command {cmd:02x}')
        self.ready_at = self.now() + self.byte_ticks
        self.deadline = self.ready_at + self.byte_ticks
        if self.timed:
            if cmd & 0xF0 == 0xC0:
                self.ready_at = found_at + 4 * self.byte_ticks
            elif cmd & 0xE0 == 0x80:
                self.ready_at = self.write_data_at
            else:
                self.ready_at = found_at + 10 * self.byte_ticks
            self.deadline = self.ready_at + (22 * self.byte_ticks if self.operation == 'write'
                                              else self.service_ticks())

    def advance(self):
        self.polls += 1
        if self.operation == 'stall':
            return
        if self.operation == 'end':
            if self.now() >= self.finish_at:
                self.finish(self.end_status)
            return
        if self.operation in ('type1', 'missing'):
            if self.timed and self.operation == 'missing' and self.finish_at:
                if self.now() >= self.finish_at:
                    self.finish(self.status)
                return
            self.wait -= 1
            if self.wait <= 0:
                op, status = self.operation, self.status
                if op == 'type1' and self.fault == 'seek' and self.command & 0xF0 == 0x10:
                    status = 0x10
                self.finish(status)
            return
        if self.operation in ('format', 'read', 'write'):
            if not self.head_loaded:
                self.drq = False
                return                   # остановленный мотор: ни INDEX, ни DRQ
            if self.timed and self.now() > self.deadline:
                self.finish(4)            # missed DRQ — lost data
                return
            if not self.timed or self.now() >= self.ready_at:
                self.drq = True

    def input(self, port):
        port &= 255
        if self.absent_bus is not None:
            assert port in (0x1F, 0x3F, 0x5F, 0x7F, 0xFF)
            return self.absent_bus
        if port == 0xFF:
            self.advance()
            return (128 if self.intrq else 0) | (64 if self.drq else 0)
        if port == 0x1F:
            self.advance()
            self.intrq = False            # чтение status сбрасывает INTRQ
            if self.command < 0x80 or self.command & 0xF0 == 0xD0:
                head_reported = self.head_loaded and (self.report_head_loaded_after_d0
                                                     or self.command & 0xF0 != 0xD0)
                return (self.status | (1 if self.busy else 0) | (2 if self.index else 0)
                        | (4 if self.has_drive and self.positions[self.drive] == 0 else 0)
                        | (32 if head_reported else 0)
                        | (64 if self.protected else 0))
            return self.status | (1 if self.busy else 0) | (2 if self.drq else 0)
        if port == 0x3F:
            return self.track
        if port == 0x5F:
            self.latch_sector()
            return self.sector
        if port == 0x7F:
            assert self.drq and self.operation == 'read', 'read without DRQ'
            if self.timed and self.now() > self.deadline:
                self.finish(4)
                return 0
            byte = self.queue[self.byte_index]
            if self.timed:
                self.drq_latencies['read'].append(self.now() - self.ready_at)
            self.byte_index += 1
            self.consumed()
            if self.byte_index == len(self.queue):
                if self.timed and self.command & 0xE0 == 0x80:
                    self.operation, self.drq = 'end', False
                    self.finish_at, self.end_status = self.ready_at + 2 * self.byte_ticks, self.status
                else:
                    self.finish(self.status)
            return byte
        raise AssertionError(f'unknown FDC input {port:02x}')

    def latch_sector(self):
        if self.pending_sector and self.now() >= self.pending_sector[0]:
            self.sector = self.pending_sector[1]
            self.pending_sector = None

    def consumed(self, expansion=1):
        self.drq = False
        if self.timed:
            self.ready_at += self.byte_ticks * expansion
            self.deadline = self.ready_at + self.service_ticks()

    def append(self, byte, clock=0):
        if len(self.raw) >= self.capacity:
            raise AssertionError('write-track exceeds physical capacity')
        self.raw.append(byte)
        self.clocks.append(clock)
        self.max_expanded = max(self.max_expanded, len(self.raw))

    def token(self, byte):
        if byte == 0xF5:
            self.append(0xA1, 1)
            self.crc = 0xCDB4             # preset after the last missing-clock A1
        elif byte == 0xF6:
            self.append(0xC2, 2)
            self.crc = crc16(bytes([0xC2]), self.crc)
        elif byte == 0xF7:
            self.append(self.crc >> 8)
            self.append(self.crc & 255)
        else:
            self.append(byte)
            self.crc = crc16(bytes([byte]), self.crc)

    def output_port(self, port, byte):
        port &= 255
        if self.absent_bus is not None:
            assert port in (0x1F, 0x3F, 0x5F, 0x7F, 0xFF)
            return                      # без FDC запись не меняет ответ шины
        if port == 0xFF:
            if not byte & 8:
                self.motor_since[byte & 3] = None
            self.sys = byte
            return
        if port == 0x1F:
            self.start(byte)
            return
        if port == 0x3F:
            self.track = byte
            return
        if port == 0x5F:
            if self.probing and byte == 0x55:
                self.probe_attempts += 1
                if self.probe_history:
                    self.probe_history[-1] = self.probe_attempts
            if self.probing and self.probe_attempts < self.probe_success_attempt:
                return
            if self.sector_latch_us:
                self.pending_sector = (self.now() + self.frequency * self.sector_latch_us * 1e-6, byte)
            else:
                self.sector = byte
            return
        if port != 0x7F:
            raise AssertionError(f'unknown FDC output {port:02x}')
        self.data = byte
        if self.moonsound:
            self.sound_bytes.append(byte)
            return                       # конфликт декодирования #7F вне TR-DOS
        if self.operation not in ('format', 'write'):
            self.stray_writes.append((self.command, self.operation, self.now(), byte))
            return
        assert self.drq, 'write without DRQ'
        if self.timed and self.now() > self.deadline:
            self.finish(4)
            return
        if self.timed:
            self.drq_latencies['write'].append(self.now() - self.ready_at)
        if self.operation == 'format':
            self.token(byte)
            if self.timed and not self.format_started:
                self.ready_at = self.first_index
                self.format_started = True
            self.consumed(2 if byte == 0xF7 else 1)
            if len(self.raw) == self.capacity:
                if self.spin_corrupt:
                    self.raw[0] ^= 1      # намеренно порчим раннюю запись
                self.tracks[self.key] = decode_track(self.raw, self.clocks, self.capacity)
                self.track_raw[self.key] = (bytearray(self.raw), list(self.clocks))
                ids = [i for i in range(len(self.raw) - 9)
                       if self.raw[i:i + 4] == b'\xa1\xa1\xa1\xfe'
                       and self.clocks[i:i + 3] == [1, 1, 1]]
                self.layouts[self.key] = []
                for i in ids:
                    j = next(j for j in range(i + 10, len(self.raw) - 3)
                             if self.raw[j:j + 3] == b'\xa1\xa1\xa1'
                             and self.clocks[j:j + 3] == [1, 1, 1]
                             and 0xF8 <= self.raw[j + 3] <= 0xFB)
                    self.layouts[self.key].append((i, j + 4))
                self.id_cursor[self.key] = 0
                self.formatted.append(self.key)
                self.writes += 1
                status = 0x20 if self.fault == 'write' else 4 if self.spin_corrupt else 0
                if self.timed:
                    self.operation, self.drq = 'end', False
                    self.finish_at, self.end_status = self.ready_at, status
                else:
                    self.finish(status)
        else:
            self.output.append(byte)       # write sector НЕ трактует F5/F6/F7 как команды
            if self.timed and len(self.output) == 1:
                self.ready_at = self.write_data_at
            self.consumed()
            if len(self.output) == self.length:
                if self.spin_corrupt:
                    self.output[0] ^= 1
                self.active.data = bytes(self.output)
                self.active.deleted = bool(self.command & 1)
                self.active.good_crc = True
                if self.key in self.track_raw:
                    sectors = self.tracks[self.key]
                    index = sectors.index(self.active)
                    _, datapos = self.layouts[self.key][index]
                    raw, clocks = self.track_raw[self.key]
                    prefix = b'\xa1' * 3 + bytes([0xF8 if self.active.deleted else 0xFB])
                    field = b'\0' * 12 + prefix + self.active.data + crc16(prefix + self.active.data).to_bytes(2, 'big') + b'\xff'
                    start, end = datapos - 16, datapos + self.length + 3
                    next_id = self.layouts[self.key][(index + 1) % len(sectors)][0]
                    if index == len(sectors) - 1:
                        next_id += self.capacity
                    assert end < next_id, 'write splice overwrites next ID / beginning'
                    assert end <= self.capacity, 'write crosses INDEX'
                    raw[start:end] = field
                    clocks[start:end] = [0] * 12 + [1] * 3 + [0] * (len(field) - 15)
                    self.tracks[self.key] = decode_track(raw, clocks, self.capacity)
                self.written.append((self.key, self.track, self.sector, self.length))
                self.writes += 1
                status = 0x20 if self.fault == 'write_sector' else 0
                if self.timed:
                    self.operation, self.drq = 'end', False
                    self.finish_at, self.end_status = self.ready_at + 3 * self.byte_ticks, status
                else:
                    self.finish(status)
