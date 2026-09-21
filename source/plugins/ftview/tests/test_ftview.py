"""Регрессии собранного Z80-кода, с файловыми отказами и моделью интерфейса FT.

Подменяются только границы WC API и передачи в FT812, C-код и команды SDK
исполняются процессором. test_chip.py передаёт данные в официальный bt8xxemu.dll.
"""
from pathlib import Path
import argparse
import hashlib
import io
import json
import re
import struct
import sys
import unittest

import z80
from PIL import Image

PLUGIN = Path(__file__).resolve().parents[1]
WC = PLUGIN.parents[2]
OUT = PLUGIN/'obj'


STUBS = ('_ft_write', '_ft_read', '_ft_rreg16', '_ft_rreg8', '_ft_rreg32',
         '_ft_wreg8', '_ft_wreg16', '_ft_wreg32')
# Фиксированные входы WildDOS для внешних плагинов (CORE32.ASM).
KERNEL_STUBS = {0x44A5: '@CURIT', 0x44D7: '@GIPAG'}
# Поля структуры AVI_SHARED (avi_index.c) под прежними именами переменных.
AVI_FIELDS = {'_avi_pcm_rate': 2, '_avi_movi_start': 4, '_avi_movi_end': 8,
              '_avi_total': 12, '_avi_rate': 16, '_avi_scale': 20, '_avi_bytes': 24,
              '_avi_pcm_total': 28, '_avi_target': 32, '_avi_seek_pos': 36,
              '_avi_seek_frame': 40, '_avi_seek_audio': 44, '_avi_write': 48,
              '_avi_period': 52, '_avi_width': 56, '_avi_height': 58, '_avi_ulaw': 60}


def symbols(out, bank):
    s = {n: int(a, 16) for a, n in re.findall(r'^\s+([0-9A-F]{8})\s+(_\w+)\s+',
         (out/bank/'ftview.map').read_text(), re.M)}
    if '_avi' in s:
        s.update({n: s['_avi'] + o for n, o in AVI_FIELDS.items()})
    return s


class Machine:
    """Z80 плагина с моделью WC API, SPI/DMA FT812 и, по желанию, GS.

    gs — модель tests/gsemu.GS: порты #BB/#B3 процессора ZX идут в неё, а её
    время идёт вместе со временем ZX (12 МГц GS против 14 МГц ZX). Без модели
    порты GS читаются как #FF — карты нет.
    """
    def __init__(self, data=b'', *, out=None, chip=None, fail_read=None, space=0xFFC, bank='video', gs=None,
                 spc=8, chain=None):
        out = out or OUT
        report=json.loads((out/'build.json').read_text())
        assert report['sha256']==hashlib.sha256((out/'FTVIEW.WMF').read_bytes()).hexdigest()
        assert report['map_sha256']==hashlib.sha256((out/'ftview.map').read_bytes()).hexdigest()
        self.cpu = z80.Z80Machine()
        self.out,self.report,self.bank=out,report,bank
        self.binary=(out/'FTVIEW.WMF').read_bytes()
        self.s = symbols(out, bank)
        offset=512+(16384 if bank=='video' else 0)
        self.cpu.set_memory_block(0x8000,self.binary[offset:offset+16384])
        self.pages = {}
        self.data, self.pos, self.reads, self.skips = data,0,[],[]
        self.chip, self.fail_read, self.space = chip,fail_read,space
        self.writes, self.regs, self.api_calls = [],[],[]
        self.ts, self.spi = {}, bytearray()
        self.banks = {page:bytes(16384) for page in range(0x8A,0x92)}
        self.media = bytearray()
        self.ramg = bytearray(0x100000)
        self.native_playing = False
        self.media_read = 0
        self.gs, self.gs_ticks = gs, 0
        self.cpu.memory[0x6002]=0x92 if bank=='video' else 0x89
        self.cpu.memory[0x6003]=0x8A  # отдельная страница файлового буфера.
        self.cpu.set_input_callback(self.input)
        self.cpu.set_output_callback(self.output)
        self.set('_filesize',len(data),4)
        # Файл на FAT32: цепочка кластеров (по умолчанию сплошная) и входы
        # ядра, которые плагин вызывает напрямую: CURIT #44A5 и GIPAG #44D7.
        # Страница WildDOS в окне #0000 (#6000 = #600B), SECBU — #3000.
        self.spc=spc
        count=max(1,-(-len(data)//(spc*512)))
        self.chain=list(chain) if chain else list(range(3,3+count))
        assert len(self.chain)>=count and len(set(self.chain))==len(self.chain)
        self.fat={c:n for c,n in zip(self.chain,self.chain[1:])}
        self.fat[self.chain[-1]]=0x0FFFFFFF
        self.curits,self.gipags=[],[]
        self.cpu.memory[0x3894]=spc
        self.cpu.memory[0x6000]=self.cpu.memory[0x600B]=0xF0
        self.kernel_cluster(self.chain[0])
        self.stubs = {self.s[n]:n for n in STUBS if n in self.s}
        self.stubs.update(KERNEL_STUBS)
        for a in list(self.stubs)+[0x6006,0x7000]:
            self.cpu.set_breakpoint(a)

    def kernel_cluster(self,cluster):
        """CUHL/CUDE WildDOS — текущий кластер потока, NSDC/EOC — сброс."""
        self.cpu.set_memory_block(0x38A8,cluster.to_bytes(4,'little'))
        self.cpu.memory[0x3848]=self.cpu.memory[0x3849]=0

    def select_bank(self, bank, preserve_context=False):
        # Загружаем тот же секторный блок из настоящего WMF, что загружает WC,
        # а при повторном переключении — сохранённую страницу этого банка:
        # переменные банка изображений живут между вызовами far_call.
        # При API 79 общий кадр не копируется моделью: это обязан сделать Z80.
        context=bytes(self.cpu.memory[0xBFE0:0xBFEE])
        self.pages[self.bank]=bytes(self.cpu.memory[0x8000:0xC000])
        for a in self.stubs:self.cpu.clear_breakpoint(a)
        self.bank=bank
        self.s=symbols(self.out, bank)
        offset=512+(16384 if bank=='video' else 0)
        # В WC оба банка получают входной кадр: main() банка изображений
        # пишет его, шлюз копирует в видеобанк. Тест, начатый прямо в
        # видеобанке, при первом переходе переносит кадр так же.
        first=bank not in self.pages
        self.cpu.set_memory_block(0x8000,self.pages.get(bank, self.binary[offset:offset+16384]))
        self.cpu.memory[0x6002]=0x92 if bank=='video' else 0x89
        if preserve_context or (first and bank=='image'):self.cpu.set_memory_block(0xBFE0,context)
        self.stubs={self.s[n]:n for n in STUBS if n in self.s}
        self.stubs.update(KERNEL_STUBS)
        for a in self.stubs:self.cpu.set_breakpoint(a)

    def input(self, port):
        if port & 255 in (0xBB, 0xB3):
            if not self.gs:
                return 0xFF
            if port & 255 == 0xBB:
                # Итерация опроса ZX (~30 тактов 14 МГц) — 26 тактов GS.
                self.gs.run(26); self.gs_ticks += 26
            return self.gs.zx_in(port)
        return 0  # DMA завершён.

    def gs_sync(self, zx_ticks):
        """Довести время GS до времени ZX после среза исполнения."""
        if self.gs:
            due = zx_ticks * 6 // 7 - self.gs_ticks
            if due > 0:
                self.gs.run(due)
            self.gs_ticks = 0

    def set(self,name,value,size=1):
        self.cpu.set_memory_block(self.s[name],value.to_bytes(size,'little'))

    def output(self,port,value):
        """Исполняется настоящий SDK DMA-код; моделируются только порты TS.

        Это проверяет длину последней порции, адрес в странице и SPI-заголовок,
        а не подменяет целиком ft_load_ram_dma заранее ожидаемым результатом.
        """
        if port & 255 in (0xBB, 0xB3):
            if self.gs:self.gs.zx_out(port,value)
        elif port & 255 == 0x77:
            self.spi.clear()
            self.spi_offset=0
        elif port & 255 == 0x57:
            self.spi.append(value)
        elif port & 255 == 0xAF:
            reg=port>>8; self.ts[reg]=value
            if reg==0x27:
                assert value==0x82, ('DMA mode',value)
                assert len(self.spi)==3 and self.spi[0]&0x80, bytes(self.spi)
                address=int.from_bytes(self.spi,'big')&0x3FFFFF
                offset=self.ts[0x1A]|self.ts[0x1B]<<8
                count=(self.ts[0x26]+1)*2*(self.ts[0x28]+1)
                assert offset+count<=0x4000, ('DMA leaves page',offset,count)
                page=self.ts[0x1C]
                assert page in (self.cpu.memory[0x6002],self.cpu.memory[0x6003]), ('Unexpected DMA page',page)
                base=0x8000 if page==self.cpu.memory[0x6002] else 0xC000
                data=bytes(self.cpu.memory[base+offset:base+offset+count])
                if address!=0x302578:address+=self.spi_offset
                self.spi_offset+=count
                offset+=count
                self.ts[0x1A]=offset&255;self.ts[0x1B]=offset>>8
                self.writes.append((address,data))
                if address==0x302578 and data[:4]==struct.pack('<I',0xFFFFFF3A):
                    self.native_playing=True
                if 0xE0000<=address<0x100000:
                    assert address+len(data)<=0x100000, 'Media DMA crosses RAM_G'
                    self.media.extend(data)
                if address<0x100000:self.ramg[address:address+len(data)]=data
                if self.chip:self.chip.write(address,data)

    def get(self,name,size=1):
        a=self.s[name]
        return int.from_bytes(self.cpu.memory[a:a+size],'little')

    def arg(self,off,size):
        a=self.cpu.sp+2+off
        return int.from_bytes(self.cpu.memory[a:a+size],'little')

    def ret(self):
        self.cpu.pc=int.from_bytes(self.cpu.memory[self.cpu.sp:self.cpu.sp+2],'little')
        self.cpu.sp+=2

    def api(self):
        m=self.cpu
        self.api_calls.append(m.a)
        if m.a==0:
            page=m._Z80State__alt_af[1]
            assert 1<=page<=8, ('Page outside WMF reservation',page)
            self.banks[m.memory[0x6003]]=bytes(m.memory[0xC000:])
            m.set_memory_block(0xC000,self.banks[0x89+page])
            m.memory[0x6003]=0x89+page
        elif m.a==0x30:
            count=m.b*512
            self.reads.append((self.pos,count))
            if len(self.reads)==self.fail_read:
                m.a,m.f=0xFF,1
            else:
                assert self.pos < len(self.data),(self.pos,len(self.data))
                part=self.data[self.pos:self.pos+count].ljust(count,b'\xA5')
                m.set_memory_block(m.hl,part)
                self.pos+=count
                m.hl+=count
                m.a,m.f=0,0x40
        elif m.a==0x32:
            self.pos=0
            self.kernel_cluster(self.chain[0])
            m.a,m.f=0,0x40
        elif m.a==0x3D:
            # LOADNONE: позиция потока идёт вперёд по цепочке, данные не читаются.
            assert 1<=m.b<=255, ('Skip count',m.b)
            self.skips.append((self.pos,m.b))
            self.pos+=m.b*512
            m.a,m.f=0,0x40
        elif m.a==0x0E:
            assert m.bc in (0x0002,0xFF00), ('Video clock contract',m.bc)
            m.a,m.f=0,0x40
        elif m.a==79:
            # MNG8_PL: номер функции в таблице ядра десятичный (MD20.ASM).
            page=m._Z80State__alt_af[1]
            assert page in (0,9), ('Code bank',page)
            self.select_bank('video' if page==9 else 'image')
        elif m.a in (0x42,0x01,0x02):
            m.a,m.f=0,0x40
        elif 0x10 <= m.a <= 0x1C:
            m.a,m.f=0,0x40
            # В покадровом тесте выходим после показа последнего кадра.
            if self.get('_avi_frame',4) and self.get('_avi_frame',4)==self.get('_avi_total',4):
                m.memory[0x6004]=1
        else:
            raise AssertionError(('Unexpected WC API',m.a))
        self.ret()

    def stub(self,name):
        m=self.cpu
        if name=='_ft_write':
            ptr,addr,count=self.arg(0,2),self.arg(2,4),self.arg(6,2)
            assert count>0,'Zero-length SDK write'
            data=bytes(m.memory[ptr:ptr+count])
            self.writes.append((addr,data))
            if addr<0x100000:self.ramg[addr:addr+count]=data
            if self.chip:self.chip.write(addr,data)
        elif name=='_ft_read':
            ptr,addr,count=self.arg(0,2),self.arg(2,4),self.arg(6,2)
            assert count>0 and addr+count<=0x100000,'SDK read outside RAM_G'
            data=self.chip.read(addr,count) if self.chip else self.ramg[addr:addr+count]
            m.set_memory_block(ptr,bytes(data))
        elif name=='@CURIT':
            # DE:HL — кластер. Сектор FAT (128 записей) — в SECBU, HL — запись.
            cluster=m.de<<16|m.hl
            self.curits.append(cluster)
            base=cluster&~127
            m.set_memory_block(0x3000,b''.join(self.fat.get(base+i,0).to_bytes(4,'little')
                                               for i in range(128)))
            m.hl=0x3000+(cluster&127)*4
            m.f=0
            # CURIT разрушает остальные регистры: плагин не должен на них полагаться.
            m.bc=m.de=0xDEAD;m.ix=m.iy=0xBEEF
        elif name=='@GIPAG':
            cluster=int.from_bytes(m.memory[m.hl:m.hl+4],'little')
            assert cluster in self.chain,('GIPAG outside file chain',cluster)
            index=self.chain.index(cluster)
            self.gipags.append((cluster,index))
            self.pos=index*self.spc*512
            self.kernel_cluster(cluster)
            m.f=0x40
            m.bc=m.de=0xDEAD;m.ix=m.iy=0xBEEF
        elif name.startswith('_ft_rreg'):
            reg=0x300000|self.arg(0,2)
            size={'_ft_rreg8':1,'_ft_rreg16':2,'_ft_rreg32':4}[name]
            if self.chip:value=int.from_bytes(self.chip.read(reg,size),'little')
            elif reg==0x302574:
                value=self.space
                if self.space==0xFFC and self.native_playing and len(self.media)<len(self.data):
                    value=0xFF4
            elif reg==0x309014:value=self.media_read
            else:value=0
            m.hl=value&0xFFFF
            if size==4:m.de=value>>16
        else:
            size={'_ft_wreg8':1,'_ft_wreg16':2,'_ft_wreg32':4}[name]
            reg=0x300000|self.arg(0,2)
            value=self.arg(2,size)
            self.regs.append((reg,value))
            if reg==0x309018:self.media_read=value
            if self.chip:self.chip.write(reg,value.to_bytes(size,'little'))
        self.ret()

    def call(self,name,args=b'',limit=30000):
        m=self.cpu
        if name not in self.s:self.select_bank('image',preserve_context=True)
        m.sp=0x5D00
        m.set_memory_block(m.sp,b'\x00\x70'+args)
        m.pc=self.s[name]
        if name=='_show_jpg_png':m.a=args[0]
        watch=getattr(self,'watch',{})
        for a in watch:m.set_breakpoint(a)
        for _ in range(limit):
            m.ticks_to_stop=200000
            event=m.run()
            self.gs_sync(200000-int.from_bytes(bytes(m._StateBase__ticks_to_stop),'little'))
            if event&1:m.memory[0x6009]=(m.memory[0x6009]+1)&255
            if m.pc==0x7000:return
            if m.pc==0x6006:self.api()
            elif m.pc in self.stubs:self.stub(self.stubs[m.pc])
            elif m.pc in watch:watch[m.pc]()
        raise AssertionError(('Execution limit',name,hex(m.pc)))


def picture(fmt='JPEG',size=(64,48),**kw):
    out=io.BytesIO()
    Image.new('RGB',size,(200,40,80)).save(out,format=fmt,**kw)
    return out.getvalue()


class Files(unittest.TestCase):
    def test_cache_refill_uses_ft_fifo_reserve(self):
        class SlowConsumer(Machine):
            write = 0

            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                self.refill_queued = []

            def stub(self, name):
                reg = self.arg(0, 2)
                if name == '_ft_wreg32' and reg == 0x9018:
                    # Потребитель не обязан сразу поглотить записанные байты.
                    previous = self.media_read
                    self.write = self.arg(2, 4)
                    super().stub(name)
                    self.media_read = previous
                else:
                    if name == '_ft_rreg32' and reg == 0x9014:
                        queued = (self.write - self.media_read) & 0x1FFFF
                        self.media_read = (self.media_read + min(queued, 512)) & 0x1FFFF
                    super().stub(name)

            def api(self):
                if self.cpu.a == 0x30 and self.native_playing:
                    self.refill_queued.append((self.write - self.media_read) & 0x1FFFF)
                super().api()

        size = 0x3E00 * 24 + 11
        data = b'RIFF' + struct.pack('<I', size-8) + b'AVI ' + bytes(i % 251 for i in range(size-12))
        m = SlowConsumer(data)
        m.call('_show_avi', limit=100000)
        self.assertEqual(m.media, data + bytes(-size % 4))
        self.assertEqual(m.get('_view_failed'), 0)
        self.assertTrue(m.refill_queued)
        # Первые восемь страниц уже прочитаны до PLAYVIDEO. Новое чтение
        # должно использовать запас FT812. Немедленный refill после первой
        # страницы оставлял меньше 16 КиБ, невзирая на восемь страниц EVO.
        self.assertGreater(min(m.refill_queued), 65536)

    def test_dls_complete(self):
        for size in (4,512,4096,4100,8192):
            with self.subTest(size=size):
                data=b'\x07\x00\x00\x26'*(size//4-1)+bytes(4)
                m=Machine(data);m.call('_show_dls')
                sent=b''.join(d for a,d in m.writes if 0x300000<=a<0x302000)
                self.assertEqual(sent[:size],data)
                self.assertEqual(sum(c for _,c in m.reads),(size+511)//512*512)
                self.assertEqual(m.get('_view_failed'),0)

    def test_dls_bad_sizes(self):
        for size in (0,1,3,5,8193,8196):
            m=Machine(bytes(size));m.call('_show_dls')
            self.assertEqual(m.get('_view_failed'),1)
            self.assertFalse(m.writes)

    def test_short_dxp(self):
        for size in range(9):
            m=Machine(bytes(size));m.call('_show_dxp')
            self.assertEqual(m.get('_view_failed'),1)
            self.assertFalse(m.writes)

    def test_dxp_raw(self):
        payload=bytes(range(256))*32
        m=Machine(b'DXP\0'+struct.pack('<HH',128,128)+payload)
        m.call('_show_dxp')
        self.assertEqual(b''.join(d for a,d in m.writes if a<0x100000),payload)
        self.assertEqual(m.get('_view_failed'),0)

    def test_read_failure_stops_dls(self):
        m=Machine(bytes(8192),fail_read=2);m.call('_show_dls')
        self.assertEqual(m.get('_view_failed'),1)
        self.assertEqual(sum(len(d) for a,d in m.writes),4096)
        self.assertNotIn((0x302054,2),m.regs)

    def test_jpeg_shapes_and_large_app(self):
        for size in ((64,48),(1024,32),(32,1024),(1024,512),(512,1024)):
            data=picture(size=size)
            data=data[:2]+b'\xFF\xE1'+struct.pack('>H',5002)+bytes(5000)+data[2:]
            m=Machine(data);m.call('_show_jpg_png',b'\x01')
            self.assertEqual(m.get('_view_failed'),0,size)
            self.assertEqual((m.get('_image_x',2),m.get('_image_y',2)),size)

    def test_bad_jpeg_rejected_before_gpu(self):
        for data, error in ((b'',1),(b'\xFF\xD8\xFF\xC4\0\x20garbage',1),
                            (picture(progressive=True),1),(picture(size=(1024,768)),2)):
            m=Machine(data);m.call('_show_jpg_png',b'\x01')
            self.assertEqual(m.get('_view_failed'),error)
            self.assertFalse(m.writes)

    def test_reported_portrait(self):
        path=PLUGIN/'artykan0.jpg'
        if not path.exists():self.skipTest('User-supplied local regression image absent')
        m=Machine(path.read_bytes());m.call('_show_jpg_png',b'\1')
        self.assertEqual((m.get('_image_x',2),m.get('_image_y',2)),(646,988))
        self.assertEqual(m.get('_view_failed'),2)
        self.assertFalse(m.writes)

    def test_png(self):
        m=Machine(picture('PNG'));m.call('_show_jpg_png',b'\0')
        self.assertEqual(m.get('_view_failed'),0)

    def test_avi_exact_stream(self):
        for size in (12,513,4096,4101,16387,0x3E00*8-1,0x3E00*8,0x3E00*17+3):
            data=b'RIFF'+struct.pack('<I',size-8)+b'AVI '+bytes((i%251 for i in range(size-12)))
            m=Machine(data);m.call('_show_avi')
            stream=b''.join(d for a,d in m.writes if a==0x302578)
            self.assertIn(struct.pack('<II',0xFFFFFF3A,8|32|4|16),stream)
            self.assertEqual(m.media,data+bytes(-size%4))
            self.assertEqual(sum(c for _,c in m.reads),(size+511)//512*512+2*min(4096,(size+511)//512*512))

    def test_fifo_full_fault_and_cancel(self):
        for space,escape in ((0,0),(0xFFF,0),(0xFFC,1)):
            m=Machine(b'RIFF\4\0\0\0AVI ',space=space)
            m.cpu.memory[0x6004]=escape
            m.call('_show_avi',limit=80000)
            self.assertEqual(m.get('_view_failed'),1)
            self.assertFalse(m.writes)

    def test_avi_prefill_and_refill_failure(self):
        data=b'RIFF'+struct.pack('<I',300000-8)+b'AVI LIST'+struct.pack('<I',300000-20)+b'movi'+bytes(300000-24)
        for read_number in (3,11):  # два чтения заголовка, затем prefill/refill.
            m=Machine(data,fail_read=read_number)
            m.call('_show_avi')
            self.assertEqual(m.get('_view_failed'),1)
            self.assertEqual(len(m.reads),read_number)
            if read_number==3:self.assertFalse(m.media)

    def test_evo_cache_preserves_code_page(self):
        size=0x3E00*18+7
        data=b'RIFF'+struct.pack('<I',size-8)+b'AVI '+bytes(i%251 for i in range(size-12))
        m=Machine(data);code_end=sum(m.report['areas']['_HOME']);code=bytes(m.cpu.memory[0x8000:code_end])
        m.call('_show_avi')
        self.assertEqual(m.media,data+bytes(-size%4))
        self.assertEqual(bytes(m.cpu.memory[0x8000:code_end]),code)
        self.assertEqual(m.get('_view_failed'),0)

    def test_wc_window_wrapper_preserves_ix(self):
        m=Machine();m.cpu.ix=0xCAFE
        m.call('_wc_api_u16',b'\x01\x00\x90')
        self.assertEqual(m.cpu.ix,0xCAFE)

    def test_wc_read_restores_interrupts_and_carry(self):
        # Драйвер с DI: обёртка обязана разрешить IM2 и сохранить ошибку CF.
        for failure in (None,1):
            m=Machine(bytes(512),fail_read=failure)
            m.cpu._Z80State__iff1[0]=m.cpu._Z80State__iff2[0]=0
            m.call('_wc_load512',struct.pack('<HB',m.s['_fs_buf'],1))
            self.assertEqual(m.cpu._Z80State__iff1[0],1)
            self.assertEqual(m.cpu._Z80State__iff2[0],1)
            self.assertEqual(m.cpu.hl,0 if failure else m.s['_fs_buf']+512)


class FatWalkTests(unittest.TestCase):
    def skip(self,chain,spc,sectors):
        data=bytes(i%251 for i in range(len(chain)*spc*512))
        m=Machine(data,bank='image',spc=spc,chain=chain)
        m.call('_wc_rewind')
        m.cpu.hl,m.cpu.de=sectors>>16,sectors&0xFFFF  # u32: HL — старшее слово
        m.call('_disk_skip')
        return m

    def test_skip_reads_fat_once_per_sector(self):
        # Цепочка с разрывами через границы секторов FAT (128 записей): поток
        # встаёт на нужный кластер, CURIT читает сектор FAT лишь при смене
        # сектора, а не на каждый кластер, как LOADNON ядра.
        chain=list(range(5,300))+list(range(1000,1400))+list(range(300,600))
        for spc in (1,8):
            for clusters,rest in ((0,0),(0,spc-1),(1,0),(122,0),(123,spc-1),(294,0),(295,0),
                                  (296,spc-1),(700,0),(994,0)):
                sectors=clusters*spc+rest
                with self.subTest(spc=spc,sectors=sectors):
                    m=self.skip(chain,spc,sectors)
                    self.assertEqual(m.cpu.a,1)
                    self.assertEqual(m.get('_view_failed'),0)
                    self.assertEqual(m.pos,sectors*512)
                    walked=chain[:clusters]
                    fat=len(walked) and 1+sum(a>>7!=b>>7 for a,b in zip(walked,walked[1:]))
                    self.assertEqual(len(m.curits),fat)
                    self.assertEqual(len(m.gipags),1 if clusters else 0)

    def test_skip_past_chain_end_fails(self):
        m=self.skip(list(range(5,40)),8,35*8)
        self.assertEqual(m.cpu.a,0)
        self.assertEqual(m.get('_view_failed'),1)
        self.assertFalse(m.gipags)


class PCMTests(unittest.TestCase):
    def test_pcm_stream_chunk_splits_seek_and_wrap(self):
        def chunk(tag,data):return tag+struct.pack('<I',len(data))+data+bytes(len(data)&1)
        audio=bytes(i*37%256 for i in range(90017))
        movi=b''.join(chunk(b'00dc',b'JPEG01wb'+bytes(i%19))+chunk(b'01wb',audio[i:i+777])
                      for i in range(0,len(audio),777))
        data=bytes(7)+movi
        for drop in (0,1,65535,70017):
            m=Machine();m.set('_avi_movi_start',7,4);m.set('_avi_movi_end',len(data),4)
            m.set('_avi_pcm_total',len(audio),4);m.set('_pcm_drop',drop,4)
            m.call('_pcm_reset')
            pos=0;parts=(1,7,3,4095,2,511,4096)
            while pos<len(data):
                n=min(parts[pos%len(parts)],len(data)-pos)
                block=data[pos:pos+n];m.cpu.set_memory_block(0xC000,block)
                m.cpu.hl=0xC000;m.cpu.de=n
                m.call('_pcm_tee',struct.pack('<I',pos))
                self.assertEqual(m.get('_view_failed'),0,(drop,pos))
                self.assertEqual(bytes(m.cpu.memory[0xC000:0xC000+n]),block)
                # Независимая модель потребителя: освобождаем только уже
                # реально записанные сэмплы; продолжения заголовка не угадываем.
                m.set('_pcm_played',m.get('_pcm_written',4),4)
                pos+=n
            sent=b''.join(d for a,d in m.writes if 0xC0000<=a<0xD0000)
            self.assertEqual(sent,bytes(x^128 for x in audio[drop:]))
            self.assertEqual(m.get('_pcm_seen',4),len(audio))
            self.assertTrue(all(a+len(d)<=0xD0000 for a,d in m.writes if a>=0xC0000))

    def test_hud_template_fits_buffer(self):
        # Шаблон HUD живёт в hud_cmd (#BBD0..#BCFF), за ним — DATA плагина.
        # Самый длинный вариант (звук на FT812, код отказа GS) не должен
        # выйти за буфер.
        for gs,ulaw in ((1,0),(0,0),(0,1)):
            for paused in (0,1):
                m=Machine()
                cmdl=m.s['_hud_cmd']-128;end=0xBD00
                m.set('_avi_ulaw',ulaw)
                m.set('_avi_width',512,2);m.set('_avi_height',384,2)
                m.set('_avi_pcm_rate',22050,2);m.set('_pcm_gs',gs);m.set('_avi_paused',paused)
                m.cpu.memory[0xBFED]=0x81|5<<2
                guard=bytes(m.cpu.memory[end:end+64])
                m.call('_avi_hud_build')
                self.assertLessEqual(m.get('_hud_len',2),end-cmdl-128,(gs,paused))
                self.assertEqual(bytes(m.cpu.memory[end:end+64]),guard,(gs,paused))

    def test_hud_counters_follow_frames(self):
        # Время и полоса HUD считаются приращениями: сверяем с делением на
        # соседних кадрах, через границу минуты и после прыжков.
        m=Machine()
        m.set('_avi_width',512,2);m.set('_avi_height',384,2)
        m.set('_avi_total',4859,4);m.set('_avi_rate',25,4);m.set('_avi_scale',1,4)
        m.set('_avi_period',40000,4)
        m.call('_avi_hud_init');m.set('_hud_frame',0xFFFFFFFE,4)
        hud=m.s['_hud_cmd']
        def word(index):
            a=hud+4*m.get(index,2)
            return int.from_bytes(m.cpu.memory[a:a+4],'little')
        frames=[1,*range(2,120),1450,*range(1451,1560),3000,3001,3002,100,101]
        for f in frames:
            m.set('_avi_frame',f,4);m.cpu.de=m.cpu.hl=0
            m.call('_avi_draw')
            s=f//25
            self.assertEqual((word('_hud_i_min'),word('_hud_i_sec')),(s//60,s%60),f)
            self.assertEqual(word('_hud_i_prog')>>16,f//(4859//1000+1),f)

    def test_pcm_frame_sample_uses_32_bits(self):
        m=Machine();m.set('_avi_rate',25,4);m.set('_avi_pcm_rate',22050,2)
        for frame in (0,1,249,250,65535,65536,1048576):
            # SDCC ABI 1: 32 бита в HLDE (DE — младшее слово).
            m.cpu.de=frame&65535;m.cpu.hl=frame>>16;m.call('_pcm_sample')
            self.assertEqual(m.cpu.de+(m.cpu.hl<<16),frame*22050//25)

    def test_bank_switch_copies_context_via_stack(self):
        m=Machine(bank='image')
        context=struct.pack('<HHHIBB',0x5D00,0xCAFE,0xABCD,0x0123FF01,4,0)
        m.cpu.set_memory_block(0xBFE0,context)
        m.cpu.set_memory_block(0x5D00,b'\x00\x70')
        m.cpu.sp=0x5C00;m.cpu.pc=m.s['_wc_video_bank']
        text=(m.out/'video/ftview.map').read_text()
        entry=int(re.search(r'^\s+([0-9A-F]{8})\s+_main_dispatch\s',text,re.M)[1],16)
        m.cpu.set_breakpoint(entry)
        for _ in range(50):
            m.cpu.ticks_to_stop=200000;m.cpu.run()
            if m.bank=='video' and m.cpu.pc==entry:break
            if m.cpu.pc==0x6006:m.api()
        else:self.fail('Video bank entry not reached')
        self.assertEqual(bytes(m.cpu.memory[0xBFE0:0xBFEC]),context)
        self.assertEqual(m.cpu.sp,0x5D00)
        self.assertEqual(bytes(m.cpu.memory[0x5D00:0x5D02]),b'\x00\x70')
        self.assertEqual(m.cpu.memory[0x6002],0x92)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--out',type=Path,default=OUT)
    args,rest=parser.parse_known_args()
    OUT=args.out
    unittest.main(argv=[sys.argv[0],*rest])
