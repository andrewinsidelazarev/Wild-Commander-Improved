"""Регрессии собранного TXTVIEW2: Unicode, потоковый файл и реальный EVE DL.

API файлов — контролируемый стенд, FT812 — официальная DLL Bridgetek.
Ожидания Unicode получены независимыми стандартными кодеками Python.
"""
import hashlib
import json
import random
import struct
import unicodedata as ud
import unittest

from harness import Viewer, VirtualFile, FONT, PROJECT, WMF, PAGES
from scanline_budget import display_words, profile

SAMPLE = '\n'.join([
    'TXT / HEX VIEWER  -  UNICODE READING ROOM', '',
    'English     The quick brown fox jumps over the lazy dog.',
    'French      À bientôt ! Cœur, Noël, français, déjà vu.',
    'German      Grüße aus Köln. Ä Ö Ü ä ö ü ß.',
    'Spanish     ¡Buenos días! El pingüino y la niña.',
    'Portuguese  São Paulo, coração, amanhã, bênção.',
    'Polish      Zażółć gęślą jaźń.',
    'Czech       Příliš žluťoučký kůň úpěl ďábelské ódy.',
    'Romanian    Știință, țară, mâine, întâmplare.',
    'Turkish     İstanbul, ışık, şeker, çığ, öğüt.',
    'Vietnamese  Tiếng Việt: Trường, Nguyễn, cộng hòa.',
    'Russian     Съешь ещё этих мягких французских булок.',
    'Ukrainian   Ґанок, їжак, єдність, Україна.',
    'Belarusian  Беларусь, ў, і, ё.',
    'Serbian     Љубљана, Његош, ђак, ћирилица, џез.',
    'Macedonian  Ѓорѓи, ќерка, ѕвезда, љубов, њ.',
    'Kazakh      Қазақ: Ә Ғ Қ Ң Ө Ұ Ү Һ І ә ғ қ ң ө ұ ү һ і.',
    'Tatar       Татарча: Ә ә Җ җ Ң ң Ө ө Ү ү Һ һ.',
    'Mongolian   Монгол хэл: Ө ө Ү ү.',
    '', 'Decomposed  a\u0301 e\u0302\u0301 о\u0301 и\u0300',
])+'\n'


class CoreTests(unittest.TestCase):
    def test_scroll_ring_wrap_tabs_eof_and_reverse(self):
        from check_nedoos import reference
        content = b''.join((f'{i:03} '.encode()+('Я'*((i*17)%140)).encode('cp866')+
                            b'\tend'+(b'\r\n', b'\r', b'\n')[i%3]) for i in range(90))
        expected = list(reference(content))
        v = Viewer(content, detect=False)
        v.draw()

        def check(index):
            rows = expected[index:index+22]
            self.assertEqual(v.grid(), [r[2] for r in rows]+['']*(22-len(rows)))
            self.assertEqual(v.get('Top'), expected[index][0])
            offsets = [r[0] for r in rows]+[len(content)]*(22-len(rows))
            at = v.s('RowOffsets')
            self.assertEqual(bytes(v.mem[at:at+88]), struct.pack('<22I', *offsets))
            self.assertEqual(v.get('PageAfter'), rows[-1][1])

        check(0)
        for index in range(1, len(expected)):
            v.call('GoDown')
            check(index)
        for _ in range(2):
            v.call('GoDown')
            check(len(expected)-1)
        for index in range(len(expected)-2, -1, -1):
            v.call('GoUp')
            check(index)
        v.call('GoUp')
        check(0)
        v.call('GoDown')
        v.call('PageDown')
        check(23)
        v.call('PageUp')
        check(1)
        v.call('GoEnd')
        check(len(expected)-22)
        v.call('GoUp')
        check(len(expected)-23)

    def test_scroll_utf8_and_hex_large_boundaries(self):
        lines = [f'{i:03} Україна, Καλημέρα, e\u0302\u0301, о\u0301' for i in range(90)]
        content = ('\ufeff'+'\r\n'.join(lines)).encode()
        v = Viewer(content)
        v.call('GoHome')
        v.draw()
        for i in range(1, 60):
            v.call('GoDown')
            self.assertEqual(v.grid(), [ud.normalize('NFC', s) for s in lines[i:i+22]])
        for i in range(58, -1, -1):
            v.call('GoUp')
            self.assertEqual(v.grid(), [ud.normalize('NFC', s) for s in lines[i:i+22]])
        self.assertEqual(v.get('Top'), 3)
        for top in (0xffe0, 0xffffe0, 0x7fffffe0, 0xfffffe00):
            v = Viewer(VirtualFile(size=0xffffffff), detect=False)
            ref = Viewer(VirtualFile(size=0xffffffff), detect=False)
            for instance in (v, ref):
                instance.put('HexMode', 1, 1)
                instance.put('Top', top)
                instance.draw()
            for direction, step in (('GoDown', 16), ('GoUp', -16)):
                for _ in range(35):
                    v.call(direction)
                    top = min(0xfffffff0, top+step)
                    ref.put('Top', top)
                    self.assertEqual(v.get('Top'), top)
                    self.assertEqual(v.grid(), ref.draw())
                    self.assertEqual(v.get('PageAfter'), ref.get('PageAfter'))

    def test_scroll_read_failure_and_cancel_preserve_visible_page(self):
        for command in ('GoDown', 'GoUp'):
            for failure in ('media', 'cancel'):
                v = Viewer(b'abcdef\n'*1500)
                v.draw()
                v.call('GoDown')
                state = (v.get('Top'), v.get('PageAfter'), v.get('RowRing', 1), v.grid(),
                         bytes(v.mem[v.s('RowOffsets'):v.s('RowOffsets')+88]))
                v.put('CacheValid', 0, 1)
                if failure == 'media': v.fault = 'media'
                else: v.escape_during_read = True
                v.call(command)
                self.assertEqual((v.get('Top'), v.get('PageAfter'), v.get('RowRing', 1), v.grid(),
                                  bytes(v.mem[v.s('RowOffsets'):v.s('RowOffsets')+88])), state)
                self.assertEqual(v.get('AllowCancel', 1), 0)
                self.assertEqual(v.get('Cancelled', 1), 0)
                self.assertEqual(bool(v.get('IoError', 1)), failure == 'media')

    def test_scroll_percent_exact_32_bit_and_last_page(self):
        v = Viewer(detect=False)
        rng = random.Random(1344)
        cases = [(0, 0, 0), (0, 1, 0), (0, 1, 1), (0, 4096, 100),
                 (4095, 4096, 4096), (0x80000000, 0xffffffff, 0x80000001)]
        for size in (1, 99, 100, 101, 65536, 0x1000000, 0x80000000, 0xffffffff):
            cases.extend((top, size, top) for top in (0, size//2, size-1))
        for _ in range(400):
            size = rng.randrange(1, 0x100000000)
            top = rng.randrange(size)
            cases.append((top, size, top))
        for top, size, after in cases:
            v.put('Top', top)
            v.put('FileSize', size)
            v.put('PageAfter', after)
            v.call('StatusLine')
            status = v.cstring(v.s('StatusBuffer'))
            self.assertEqual(status[77:78], b'%')
            self.assertEqual(int(status[74:77]), 100 if after >= size else top*100//size,
                             (top, size, after, status))
            self.assertIn(b'TEXT', status)
            self.assertLessEqual(len(status), 78)

    def test_header_resources_and_coverage(self):
        self.assertEqual(WMF[16:32], b'WildCommanderMDL')
        self.assertEqual(WMF[34], len(PAGES))
        self.assertEqual(WMF[63],3)
        self.assertIn(b'v0.26',WMF[165:197])
        self.assertGreater(len(PAGES),1)
        v=Viewer()
        self.assertLessEqual(v.s('ENDPL'),0xA800)
        self.assertGreaterEqual(v.s('AssetSegments'),0x8000)
        available=set(FONT['codes'])
        self.assertTrue({ord(c) for c in SAMPLE if ord(c)>=32} <= available)
        for low, high in ((0x400,0x52f),(0x1e00,0x1eff),(0xa640,0xa69f)):
            self.assertTrue({c for c in range(low,high+1) if ud.category(chr(c))!='Cn'} <= available)
        self.assertLessEqual(FONT['ram_g'],1024*1024)

    def test_every_unicode_mapping(self):
        v=Viewer()
        for index,code in enumerate(FONT['codes']):
            v.call('LookupGlyph',de=code)
            self.assertEqual(v.m.hl,index,hex(code))
        for code in (0,31,0x7f,0xd800,0xffff,0x4e00):
            v.call('LookupGlyph',de=code)
            self.assertEqual(v.m.hl,v.s('GLYPH_REPLACEMENT'))

    def test_every_composition(self):
        v=Viewer()
        for base,mark,result in FONT['compositions']:
            v.put('Cluster',base,2)
            v.put('Decoded',mark,2)
            _,found=v.call('ComposeGlyph')
            self.assertTrue(found)
            self.assertEqual(v.m.hl,result,(base,mark))

    def test_utf8_and_single_byte_decoders(self):
        for encoding,choice in (('cp866',0),('cp1251',1)):
            raw=bytes(range(256))
            v=Viewer(raw,detect=False)
            v.put('Encoding',choice,1)
            for b in raw:
                _,eof=v.call('ReadChar')
                self.assertFalse(eof)
                self.assertEqual(v.get('Decoded',2),ord(bytes([b]).decode(encoding,errors='replace')))
            self.assertTrue(v.call('ReadChar')[1])
        rnd=random.Random(0x812)
        for _ in range(160):
            raw=bytes(rnd.randrange(256) for _ in range(rnd.randrange(1,70)))
            expected=raw.decode('utf-8',errors='replace')
            v=Viewer(raw,detect=False)
            v.put('Encoding',2,1)
            got=[]
            while not v.call('ReadChar')[1]:
                got.append(chr(v.get('Decoded',2)))
            expected=''.join(c if ord(c)<=0xffff else '\ufffd' for c in expected)
            self.assertEqual(''.join(got),expected,raw.hex())

    def test_detection_cycle_and_bom(self):
        text='Привет! Проверка кодировки и просмотра текста. Съешь ещё этих булок.'
        for name,expected in (('cp866',0),('cp1251',1),('utf-8',2)):
            v=Viewer(text.encode(name))
            self.assertEqual(v.get('Encoding',1),expected)
        v=Viewer(b'\xef\xbb\xbf'+text.encode())
        self.assertEqual(v.get('Top'),3)
        for choice,encoding in ((1,0),(2,1),(3,2),(0,2)):
            v.call('NextEncoding')
            self.assertEqual(v.get('Choice',1),choice)
            self.assertEqual(v.get('Encoding',1),encoding)
            self.assertEqual(v.get('Top'),3 if encoding==2 else 0)

    def test_languages_and_combining_cache_boundary(self):
        v=Viewer(SAMPLE.encode())
        self.assertEqual(v.draw(), ud.normalize('NFC',SAMPLE).splitlines()[:22])
        for offset in (4093,4094,4095,4096):
            text='e\u0302\u0301о\u0301ЯҐЇӘ\u040d🙂'
            v=Viewer(b'x'*offset+text.encode())
            v.put('Position',offset)
            v.put('Encoding',2,1)
            v.call('TextRow')
            self.assertEqual(v.line(),'ếо\u0301ЯҐЇӘ\u040d\ufffd')

    def test_line_boundaries_tabs_and_long_lines(self):
        v=Viewer(b'A\0B\tC\r\nD\rE\nF')
        self.assertEqual(v.draw()[:4],['A.B     C','D','E','F'])
        v=Viewer(b'X'*78+b'\r\nY\n')
        self.assertEqual(v.draw()[:2],['X'*78,'Y'])
        v=Viewer(VirtualFile(size=1024*1024,pattern=b'x'))
        self.assertEqual(v.draw(),['x'*78]*22)
        v.call('PageDown')
        self.assertEqual(v.get('Top'),1716)
        v.call('PageUp')
        self.assertEqual(v.get('Top'),0)

    def test_large_offsets_and_navigation(self):
        for size in (65537,16*1024*1024+7,0x80000007,0xffffffff):
            v=Viewer(VirtualFile(size=size),detect=False)
            v.put('HexMode',1,1)
            v.call('GoEnd')
            self.assertEqual(v.get('Top'),(size-1)&~15)
            v.call('MapGrid')
            v.call('HexRow')
            self.assertFalse(v.get('IoError',1))
            self.assertTrue(all(r[1]+r[3]<=size+511 for r in v.reads))
        v=Viewer(('line\n'*500).encode())
        for _ in range(17): v.call('PageDown')
        saved=v.get('Top')
        v.call('GoUp')
        self.assertEqual(v.get('Top'),saved-5)

    def test_read_failure_and_esc_latch(self):
        for fault in ('media','short','count_high'):
            v=Viewer(VirtualFile(size=100000),detect=False)
            v.fault=fault
            v.put('Position',20000)
            v.call('ReadByte')
            self.assertNotEqual(v.get('IoError',1),0)
        v=Viewer(VirtualFile(size=100000),detect=False)
        v.put('AllowCancel',1,1)
        v.put('Position',20000)
        v.escape_during_read=True
        self.assertTrue(v.call('ReadByte')[1])
        self.assertTrue(v.get('Cancelled',1))

    def test_search_and_status_english(self):
        v=Viewer(('x'*4094+'Привет, Україна!').encode())
        request='Привет'.encode('cp866').ljust(40,b' ')
        v.mem[v.s('InputBuffer'):v.s('InputBuffer')+40]=request
        v.call('BuildSearch')
        v.call('BeginCommand')
        v.call('FindBytes')
        self.assertEqual(v.get('Top'),4094)
        for lang in (0,1):
            v.mem[0x781a]=lang
            v.call('StatusLine')
            status=v.cstring(v.s('StatusBuffer'))
            self.assertTrue(all(c<128 for c in status))
            self.assertIn(b'UTF-8',status)
            self.assertIn(b'00000FFE',status)

    def test_missing_ft_is_bounded_and_restores_wc(self):
        v=Viewer()
        old=v.m.ix
        v.call('RE',a=0,bc=v.s('FileName')+1)
        self.assertEqual(v.m.ix,old)
        self.assertEqual(v.video_mode,0)
        self.assertEqual(v.cfg,3)
        self.assertIn(b'FT812',v.messages[-1][2])

    def test_faulted_fifo_stops_transmission(self):
        v=Viewer()
        v.call('Cmd_Begin')
        v.call('Cmd_Word',hl=0,de=0)
        self.assertEqual(v.get('FtFault',1),1)
        self.assertEqual(v.cfg,3)
        count=len(v.commands)
        v.call('Cmd_Block',hl=v.s('FileName'),bc=256)
        v.call('Cmd_Word',hl=1,de=0xffff)
        self.assertEqual(len(v.commands),count)
        self.assertEqual(v.cfg,3)

    def test_menu_and_failed_file_do_not_touch_font_pages(self):
        v=Viewer(b'secret',detect=False)
        v.call('RE',a=3,bc=0xffff)
        self.assertEqual(v.reads,[])
        self.assertIn(b'Select a file',v.messages[-1][2])
        v.fail_open=True
        v.call('RE',a=0,bc=v.s('FileName')+1)
        self.assertEqual(v.reads,[])
        self.assertEqual(bytes(v.pages[1]),PAGES[1])
        self.assertIn(b'Cannot open',v.messages[-1][2])


class GraphicsTests(unittest.TestCase):
    def test_scroll_changes_only_spare_strip_and_matches_full_frame(self):
        from PIL import ImageChops
        content = ''.join(f'{i:03} '+'Я'*(i%60)+' e\u0302\u0301\n' for i in range(120)).encode()
        v = Viewer(content, chip=True)
        ref = Viewer(content, chip=True)
        atlas = (PROJECT/'build/font.l4').read_bytes()
        cell = 204
        strip = 78*cell
        try:
            for instance in (v, ref):
                instance.call('FT_Boot')
                instance.call('FT_LoadAssets')
                instance.put('FtReady', 1, 1)
                instance.draw()
            for cmd in ('GoDown', 'GoUp'):
                for step in range(50):
                    ring = v.get('RowRing', 1)
                    spare = (ring+22)%23
                    old = v.chip.read(len(atlas), 23*strip)
                    v.commands.clear()
                    v.call(cmd)
                    self.assertLessEqual(v.commands.count(b'\x1d\xff\xff\xff'), 78)
                    current = v.chip.read(len(atlas), 23*strip)
                    for slot in range(23):
                        if slot != spare:
                            self.assertEqual(current[slot*strip:(slot+1)*strip], old[slot*strip:(slot+1)*strip])
                    v.call('MapGrid')
                    ids = v.ids(0x2000, 23*78)
                    expected = b''.join(atlas[g*cell:(g+1)*cell] for g in ids)
                    self.assertEqual(current, expected)
                    if step in (0, 22, 23, 49):
                        ref.put('Top', v.get('Top'))
                        self.assertEqual(v.grid(), ref.draw())
                        self.assertIsNone(ImageChops.difference(v.chip.frame(), ref.chip.frame()).getbbox())
            self.assertEqual(v.get('Top'), 0)
            self.assertFalse(v.chip.errors, v.chip.errors)
            self.assertEqual(v.chip.read(0, len(atlas)), atlas)
        finally:
            v.close()
            ref.close()

    def test_cached_grid_covers_all_glyphs_and_preserves_atlas(self):
        v=Viewer(chip=True)
        atlas=(PROJECT/'build/font.l4').read_bytes()
        cell=FONT['cell'][0]*FONT['cell'][1]//2
        count=78*23
        end=len(atlas)+count*cell
        try:
            v.call('FT_Boot')
            v.call('FT_LoadAssets')
            v.put('FtReady',1,1)
            v.chip.write(end,b'\x5a'*64)
            for first in (0, count, 0):
                ids=[(first+i)%len(FONT['glyphs']) for i in range(count)]
                v.call('MapGrid')
                v.mem[0x2000:0x2000+count*2]=struct.pack('<'+'H'*count,*ids)
                v.put('GridDirty',1,1)
                v.call('PresentScreen')
                expected=b''.join(atlas[i*cell:(i+1)*cell] for i in ids)
                self.assertEqual(v.chip.read(len(atlas),count*cell),expected)
                self.assertEqual(v.chip.read(0,len(atlas)),atlas)
                self.assertEqual(v.chip.read(end,64),b'\x5a'*64)
                self.assertEqual(v.get('FtFault',1),0)
            v.commands.clear()
            v.put('GridDirty',1,1)
            v.call('PresentScreen')
            self.assertEqual(v.commands[:4],struct.pack('<I',0xffffff00),
                             'Unchanged cells must not emit CMD_MEMCPY')
            self.assertFalse(v.chip.errors,v.chip.errors)
        finally:
            v.close()

    def test_foreign_handle_high_bits_do_not_break_panels(self):
        # Сброс ядра FT812 не очищает таблицу дескрипторов. FTView показывает
        # кадр 1024x768 через handle 0 и оставляет в нём старшие поля
        # геометрии: шаг 1024 байта (LAYOUT_H) и размер 1024x768 (SIZE_H).
        # FontSetup их не пишет — панели выходили мусором, а текст (полосы
        # handle 31) оставался цел. FT_ResetHandles обнуляет их один раз
        # после загрузки шрифта: экран совпадает с запуском на чистом чипе.
        from PIL import ImageChops
        shots=[]
        for foreign in (False,True):
            v=Viewer(SAMPLE.encode(),chip=True)
            try:
                if foreign:
                    v.chip.boot()
                    v.chip.cmd(struct.pack('<6I',0xffffff00,0x05000000,0x28000004,0x29000009,
                                           0x00000000,0xffffff01))
                    v.chip.wait_idle()
                    v.chip.frame()
                for name in ('FT_Boot','FT_LoadAssets','FT_ResetHandles'):
                    _,fault=v.call(name)
                    self.assertFalse(fault,name)
                v.put('FtReady',1,1)
                v.draw()
                shots.append(v.chip.frame())
                self.assertFalse(v.chip.errors,v.chip.errors)
            finally:
                v.close()
        self.assertIsNone(ImageChops.difference(*shots).getbbox())

    def test_z80_boot_font_upload_dense_page_and_help(self):
        v=Viewer(SAMPLE.encode(),chip=True)
        budgets={}
        try:
            _,fault=v.call('FT_Boot')
            self.assertFalse(fault)
            self.assertEqual(v.chip.rd32(0x302034),1024)
            self.assertEqual(v.chip.rd32(0x302048),768)
            _,fault=v.call('FT_LoadAssets')
            self.assertFalse(fault)
            self.assertEqual(v.chip.read(0,FONT['ram_g']),(PROJECT/'build/font.l4').read_bytes())
            v.put('FtReady',1,1)
            self.assertEqual(v.draw(),ud.normalize('NFC',SAMPLE).splitlines()[:22])
            budgets['languages']=profile(display_words(v))
            v.chip.frame().save(PROJECT/'build/preview-text.png')
            self.assertFalse(v.chip.errors,v.chip.errors)
            v.file=VirtualFile(b'W'*78*22)
            v.put('FileSize',v.file.size)
            v.put('CacheValid',0,1)
            v.stream=0
            v.put('StreamNext',0)
            v.call('GoHome')
            v.commands.clear()
            self.assertEqual(v.draw(),['W'*78]*22)
            words=struct.unpack('<'+'I'*(len(v.commands)//4),v.commands)
            # Перед DLSTART идут CMD_MEMCPY в RAM_G; они не исполняются
            # заново на каждой растровой строке и не входят в длину RAM_DL.
            words=words[words.index(0xffffff00):]
            self.assertEqual(words[0],0xffffff00)
            self.assertEqual(words[-1],0xffffff01)
            self.assertLessEqual(len(words)-2,2048)
            self.assertEqual(sum((w>>30)==2 for w in words if w<0xffffff00),
                             22+sum((w>>30)==2 for w in words[:words.index(0x04d9e5f5)] if w<0xffffff00)
                             +len('F1HelpTabTXT/HEXF8EncodingCtrl+FFindCtrl+GNextEscClose'))
            v.chip.frame().save(PROJECT/'build/preview-dense.png')
            budgets['dense']=profile(display_words(v))
            for mode,name in ((1,'help'),(2,'search')):
                v.put('Modal',mode,1)
                v.commands.clear()
                v.call('PresentScreen')
                self.assertLessEqual(len(v.commands)//4-2,2048)
                v.chip.frame().save(PROJECT/f'build/preview-{name}.png')
                budgets[name]=profile(display_words(v))
            v.put('Modal',2,1)
            v.mem[v.s('InputBuffer'):v.s('InputBuffer')+41]=b'W'*40+b'\0'
            v.call('PresentScreen')
            budgets['search_full']=profile(display_words(v))
            for name,budget in budgets.items():
                self.assertGreaterEqual(budget['margin_clocks'],0,(name,budget))
            (PROJECT/'build/scanline-budget.json').write_text(
                json.dumps(dict(sha256=hashlib.sha256(WMF).hexdigest(),cases=budgets,
                                method='DL fetch + L4 NEAREST pixel work + 128 reserve; not hardware timing'),
                           indent=2)+'\n',encoding='utf-8')
            self.assertFalse(v.chip.errors,v.chip.errors)
            before=bytes(v.pages[1])
            v.call('RestoreVideo')
            self.assertEqual(bytes(v.pages[1]),before)
            self.assertEqual(v.cfg,3)
            (PROJECT/'build/graphics-result.txt').write_text(
                f'Dense DL words: {len(words)-2}/2048\nRAM_G verified: {FONT["ram_g"]} bytes\n',encoding='utf-8')
        finally:
            v.close()


if __name__=='__main__':
    unittest.main(verbosity=2)
