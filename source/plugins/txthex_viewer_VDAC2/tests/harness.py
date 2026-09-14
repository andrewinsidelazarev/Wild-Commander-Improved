"""Настоящие инструкции Z80, публичные API WC и SPI к bt8xxemu.dll.

Файловые операции подменяются контролируемым источником, как в регрессиях
обычного TXTVIEW. Многомегабайтные и 4-ГиБ файлы не загружаются целиком.
"""
import json
from pathlib import Path
import sys
from types import SimpleNamespace

PROJECT = Path(__file__).resolve().parents[1]
WC = PROJECT.parents[2]
sys.path.insert(0, str(WC/'tests/core32_unreal'))
sys.path.insert(0, str(PROJECT/'tools'))
import test_txthex_viewer as base
import ft812emu

WMF = (PROJECT/'TXTVIEW2.WMF').read_bytes()
PAGES = {}
pos, at = 512, 36
while WMF[at+1]:
    page, sectors = WMF[at:at+2]
    PAGES[page] = WMF[pos:pos+sectors*512].ljust(16384, b'\0')
    pos += sectors*512
    at += 2
assert pos == len(WMF)
CODE = WMF[:512]+PAGES[0][:WMF[37]*512]
base.WMF = SimpleNamespace(read_bytes=lambda: CODE, stat=lambda: SimpleNamespace(st_size=len(CODE)))
base.SYMBOLS = PROJECT/'build/TXTVIEW2.sym'
FONT = json.loads((PROJECT/'build/font.json').read_text(encoding='utf-8'))
VirtualFile = base.VirtualFile


class Viewer(base.Viewer):
    def __init__(self, content=b'', *, chip=False, **kw):
        self.chip = ft812emu.FT812() if chip else None
        self.cfg, self.rdbuff = 3, 255
        self.transaction = bytearray()
        self.commands = bytearray()
        self.pages = {k: bytearray(v) for k,v in PAGES.items()}
        self.pages['grid'] = bytearray(16384)
        self.mapped = 'grid'
        self.video_mode = 0
        super().__init__(content, width=78, height=24, **kw)
        self.mem[:16384] = self.pages['grid']
        self.mem[self.s('GraphicsState'):self.s('GraphicsStateEnd')] = bytes(self.s('GraphicsStateEnd')-self.s('GraphicsState'))
        self.m._Z80State__int_mode[0] = 2
        self.m._Z80State__ir[1] = 0x7B
        self.mem[0x7BFF:0x7C01] = b'\x20\x7c'
        self.mem[0x7C20] = 0xC9
        self.m.set_input_callback(self.port_in)
        self.m.set_output_callback(self.port_out)

    def api(self):
        api, m = self.m.a, self.m
        if api in (48,59,62,77):
            assert not self.cfg & 4, 'File API selected SD while FT812 was selected'
        if api not in (78,80,64,66):
            return super().api()
        alternate = m._Z80State__alt_af
        argument = int.from_bytes(alternate,'little') >> 8
        alternate[:] = m.af.to_bytes(2,'little')
        self.calls.append((api,argument))
        if api in (78,80):
            self.pages[self.mapped][:] = self.mem[:16384]
            self.mapped = 'grid' if api == 80 else argument
            self.mem[:16384] = self.pages[self.mapped]
        elif api == 66:
            self.video_mode = argument
        elif api == 64:
            assert self.mapped == 'grid'
            self.mem[0x1000:0x1448] = b'\xF0'*0x448
            self.video_mode = 0
        m.a, m.f = 0, 0x40
        m.alt_bc = 0xDEAD

    def port_out(self, port, value):
        low = port & 255
        if low == 0x77:
            if (self.cfg ^ value) & 4:
                if value & 4:
                    self.transaction.clear()
                elif self.transaction[:3] == b'\xb0\x25\x78':
                    assert (len(self.transaction)-3)%4 == 0
                    self.commands += self.transaction[3:]
                if self.chip:
                    self.chip.select(bool(value & 4))
            self.cfg = value
        elif low == 0x57:
            assert self.cfg & 2
            self.rdbuff = self.xfer(value)
        else:
            raise AssertionError(f'Unexpected port {port:04x}')

    def xfer(self, value):
        if not self.cfg & 4:
            return 255
        self.transaction.append(value)
        return self.chip.xfer(value) if self.chip else 255

    def port_in(self, port):
        assert port & 255 == 0x57
        value = self.rdbuff
        self.rdbuff = self.xfer(255)
        return value

    def ids(self, address, count=78):
        raw = self.mem[address:address+count*2]
        return [int.from_bytes(raw[i:i+2],'little') for i in range(0,len(raw),2)]

    def line(self):
        return ''.join(FONT['glyphs'][i] for i in self.ids(self.s('LineGlyphs'))).rstrip()

    def draw(self):
        self.call('DrawPage')
        return self.grid()

    def grid(self):
        """Текущий видимый порядок кольца, без перерисовки/исправления состояния."""
        self.call('MapGrid')
        ring = self.get('RowRing', 1)
        return [''.join(FONT['glyphs'][i] for i in self.ids(0x2000+((ring+row)%23)*156)).rstrip() for row in range(22)]

    def close(self):
        if self.chip:
            self.chip.close()
            self.chip = None
