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
# Фиксированные входы WildDOS для внешних плагинов (CORE32.ASM, KERNEL.ASM).
KERNEL_STUBS = {0x44A5: '@CURIT', 0x44D7: '@GIPAG', 0x4021: '@TLSTCAT'}
# Банки кода в WMF: смещение секторного блока за заголовком, страница API 79
# и физическая страница окна #8000 (PAGE2) в модели.
BANK_OFFSET = {'image': 0, 'video': 16384, 'list': 32768}
BANK_PAGE = {'image': 0x89, 'video': 0x92, 'list': 0x93}
BANK_BY_NUMBER = {0: 'image', 9: 'video', 10: 'list'}
# ПЗУ FT812 для модели: ROM_FONTROOT и ширины символов шрифта 28 (сняты с
# эмулятора Bridgetek) — по ним банк списка обрезает имена.
FONT_ROOT = 0x201EE0
FONT28 = bytes.fromhex('00000000000000000000000000000000000000000000000000000000000000000506070e0b100e0407080a0c040a06090c0c0c0c0c0c0c0c0c0c06060b0d0b0a130d0e0d0e0c0c0e0f060c0e0c130f0e0e0e0d0c0e0d0e120d0e0d060907090b070b0b0b0c0b080b0b06060b06120b0c0b0c070b080c0b100b0b0b0805070e05')


def rom_read(addr, count):
    for base, data in ((0x2FFFFC, FONT_ROOT.to_bytes(4, 'little')), (FONT_ROOT + 148 * 12, FONT28)):
        if base <= addr and addr + count <= base + len(data):
            return data[addr - base:addr - base + count]
    raise AssertionError(('ROM read outside the model', hex(addr), count))
# Поля структуры AVI_SHARED (avi_index.c) под прежними именами переменных.
AVI_FIELDS = {'_avi_pcm_rate': 2, '_avi_movi_start': 4, '_avi_movi_end': 8,
              '_avi_total': 12, '_avi_rate': 16, '_avi_scale': 20, '_avi_bytes': 24,
              '_avi_pcm_total': 28, '_avi_target': 32, '_avi_seek_pos': 36,
              '_avi_seek_frame': 40, '_avi_seek_audio': 44, '_avi_write': 48,
              '_avi_period': 52, '_avi_width': 56, '_avi_height': 58, '_avi_cluster': 60,
              '_avi_size': 64}


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
        offset=512+BANK_OFFSET[bank]
        self.cpu.set_memory_block(0x8000,self.binary[offset:offset+16384])
        self.pages = {}
        self.data, self.pos, self.reads, self.skips = data,0,[],[]
        self.chip, self.fail_read, self.space = chip,fail_read,space
        self.writes, self.regs, self.api_calls, self.windows = [],[],[],[]
        self.ts, self.spi = {}, bytearray()
        self.banks = {page:bytes(16384) for page in range(0x8A,0x92)}
        self.media = bytearray()
        self.ramg = bytearray(0x100000)
        self.native_playing = False
        self.media_read = 0
        self.gs, self.gs_ticks = gs, 0
        self.cpu.memory[0x6002]=BANK_PAGE[bank]
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
        # Остальные объекты тома (каталог, другие ролики) — add_object().
        # Каталог читается до конца цепочки (eoc): LOAD512 за ним возвращает
        # HL без сдвига и EOC=#0F, как ядро. Файл за концом читать нельзя.
        self.objects=[(self.chain,data,False)]
        self.eoc=False
        self.dir_cluster=0
        self.curits,self.gipags=[],[]
        self.cpu.memory[0x3894]=spc
        self.cpu.memory[0x6000]=self.cpu.memory[0x600B]=0xF0
        self.kernel_cluster(self.chain[0])
        self.stubs = {self.s[n]:n for n in STUBS if n in self.s}
        self.stubs.update(KERNEL_STUBS)
        self.stub_list()
        for a in list(self.stubs)+[0x6006,0x7000]:
            self.cpu.set_breakpoint(a)
        self.preset_cluster()

    def preset_cluster(self):
        """Первый кластер ролика: плеер берёт его в avi_first (CUHL после
        GIPAGPL), банк
        изображений — в far_entry. Функциям, которые тест вызывает напрямую,
        он нужен заранее."""
        # Видеобанк начинает с заведомо чужого кластера: его обязан заменить
        # avi_first, иначе GIPAG модели укажет на отсутствующую цепочку.
        if '_avi' in self.s:
            self.set('_avi_cluster',self.objects[0][0][0] if self.bank!='video' else 0x0BADC0DE,4)

    @staticmethod
    def dir_entry(name,cluster,size,attr=0x20):
        """Запись каталога FAT32: имя 8.3, атрибут, кластер (+20/+26), размер."""
        return (name+bytes([attr])+bytes(8)+struct.pack('<H',cluster>>16)+bytes(4)+
                struct.pack('<HI',cluster&0xFFFF,size))

    def add_object(self,data,chain=None,eoc=False):
        """Файл или каталог тома; возвращает первый кластер цепочки."""
        count=max(1,-(-len(data)//(self.spc*512)))
        if chain is None:
            used=set(self.fat)|{c for ch,_,_ in self.objects for c in ch}
            start=max(used|{2})+1
            chain=list(range(start,start+count))
        chain=list(chain)
        assert len(chain)>=count
        self.fat.update(zip(chain,chain[1:]));self.fat[chain[-1]]=0x0FFFFFFF
        self.objects.append((chain,data,eoc))
        return chain[0]

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
        offset=512+BANK_OFFSET[bank]
        # В WC оба банка получают входной кадр: main() банка изображений
        # пишет его, шлюз копирует в видеобанк. Тест, начатый прямо в
        # видеобанке, при первом переходе переносит кадр так же.
        first=bank not in self.pages
        self.cpu.set_memory_block(0x8000,self.pages.get(bank, self.binary[offset:offset+16384]))
        self.cpu.memory[0x6002]=BANK_PAGE[bank]
        if preserve_context or (first and bank=='image'):self.cpu.set_memory_block(0xBFE0,context)
        if first:self.preset_cluster()
        self.stubs={self.s[n]:n for n in STUBS if n in self.s}
        self.stubs.update(KERNEL_STUBS)
        self.stub_list()
        for a in self.stubs:self.cpu.set_breakpoint(a)

    # Список роликов в конце ролика (avi_list) читает каталог. Без каталога
    # тома (list_volume, ListMachine) он заменён ответом «закрыт Esc»:
    # вызовы считаются, поток и чтения SD остаются как без списка.
    list_model = False
    list_calls = 0

    def stub_list(self):
        if not self.list_model and '_avi_list' in self.s:
            self.stubs[self.s['_avi_list']] = '_avi_list'

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
            elif self.eoc and self.pos>=len(self.data):
                m.a,m.f=0x0F,0  # конец цепочки: HL без сдвига, CF=0
            else:
                assert self.pos < len(self.data),(self.pos,len(self.data))
                part=self.data[self.pos:self.pos+count].ljust(count,b'\xA5')
                m.set_memory_block(m.hl,part)
                self.pos+=count
                m.hl+=count
                m.a,m.f=0,0x40
        elif m.a==0x32:
            self.chain,self.data,self.eoc=self.objects[0]
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
            # TURBOPL WC оставляет кэш TS-Conf только окну #4000 (MD20.ASM).
            self.ts[0x2B]=0x02
            m.a,m.f=0,0x40
        elif m.a==79:
            # MNG8_PL: номер функции в таблице ядра десятичный (MD20.ASM).
            page=m._Z80State__alt_af[1]
            assert page in BANK_BY_NUMBER, ('Code bank',page)
            self.select_bank(BANK_BY_NUMBER[page])
        elif m.a==0x01:
            # PRWOW: окно WC. Тексты — указатели в его структуре: +12
            # заголовок, +14 подвал, +16 текст окна.
            def window_text(off):
                a=int.from_bytes(m.memory[m.ix+off:m.ix+off+2],'little')
                return bytes(m.memory[a:a+128]).split(bytes(1))[0].decode('cp866')
            self.windows.append([window_text(12),window_text(14),window_text(16)])
            m.a,m.f=0,0x40
        elif m.a in (0x42,0x02,0x2E,0x2F):
            # RRESB — снять окно; USPO/NUSP — ждать, пока клавиши отпущены,
            # и затем нажатия любой: окно сообщения закрывается сразу.
            m.a,m.f=0,0x40
        elif m.a==0x2D:
            m.a,m.f=0,0x40  # _ANYK: ни одна клавиша не нажата
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
            assert count>0,'Zero-length SDK read'
            if self.chip:data=self.chip.read(addr,count)
            elif addr>=0x200000:data=rom_read(addr,count)   # ПЗУ: шрифт списка
            else:
                assert addr+count<=0x100000,'SDK read outside RAM_G'
                data=self.ramg[addr:addr+count]
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
            for chain,data,eoc in self.objects:
                if cluster in chain:break
            else:raise AssertionError(('GIPAG outside file chains',cluster))
            self.chain,self.data,self.eoc=chain,data,eoc
            index=self.chain.index(cluster)
            self.gipags.append((cluster,index))
            self.pos=index*self.spc*512
            self.kernel_cluster(cluster)
            m.f=0x40
            m.bc=m.de=0xDEAD;m.ix=m.iy=0xBEEF
        elif name=='_avi_list':
            self.list_calls+=1
            m.a=0  # bool, SDCC sdcccall(1): false — Esc, ролик не выбран
        elif name=='@TLSTCAT':
            # KERNEL.ASM +#21: LSTCAT (4 байта) по DE через LDIR.
            m.set_memory_block(m.de,self.dir_cluster.to_bytes(4,'little'))
            m.de=(m.de+4)&0xFFFF;m.hl=0xDEAD;m.bc=0  # HL — за LSTCAT в ядре
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
        # Шаблон HUD живёт в hud_cmd (#BB80..#BCFF), за ним — DATA плагина.
        # Самый длинный вариант (звук на FT812, код отказа GS) не должен
        # выйти за буфер.
        for gs in (1,0):
            for paused in (0,1):
                m=Machine()
                cmdl=m.s['_hud_cmd']-128;end=0xBD00
                m.set('_avi_width',512,2);m.set('_avi_height',384,2)
                m.set('_avi_pcm_rate',22050,2);m.set('_pcm_gs',gs);m.set('_avi_paused',paused)
                m.set('_hud_left',750,2)  # панель управления видна
                m.cpu.memory[0xBFED]=0x81|5<<2
                guard=bytes(m.cpu.memory[end:end+64])
                m.call('_avi_hud_build')
                self.assertLessEqual(m.get('_hud_len',2),end-cmdl-128,(gs,paused))
                self.assertEqual(bytes(m.cpu.memory[end:end+64]),guard,(gs,paused))

    def test_hud_frame_is_bilinear(self):
        # Кадр растягивается с билинейной фильтрацией всегда: слово BITMAP_SIZE
        # кадра 1024×768, бит 20. Старший байт #08 бывает и у параметров
        # CMD_NUMBER (FT_OPT_RIGHTX), поэтому слово узнаём и по размеру.
        m=Machine()
        m.set('_avi_width',512,2);m.set('_avi_height',384,2)
        m.call('_avi_hud_init');m.set('_hud_left',750,2)
        m.call('_avi_hud_build')
        hud=m.s['_hud_cmd'];n=m.get('_hud_len',2)//4
        words=struct.unpack('<%dI'%n,bytes(m.cpu.memory[hud:hud+4*n]))
        sizes=[w for w in words if w>>24==0x08 and (w>>9&511,w&511)==(1024&511,768&511)]
        self.assertEqual([w>>20&1 for w in sizes],[1])

    def test_hud_panel_hides(self):
        # Панель управления (тёмная полоса BEGIN(RECTS), полоса прокрутки,
        # текст CMD_TEXT) — только пока взведён hud_left или на паузе; кадр
        # показывается всегда.
        m=Machine()
        m.set('_avi_width',512,2);m.set('_avi_height',384,2)
        m.set('_avi_total',4859,4);m.set('_avi_rate',25,4);m.set('_avi_scale',1,4)
        m.set('_avi_period',40000,4)
        m.call('_avi_hud_init');m.set('_hud_frame',0xFFFFFFFE,4)
        hud=m.s['_hud_cmd']
        for left,paused,panel in ((750,0,True),(0,0,False),(0,1,True),(1,0,True)):
            m.set('_hud_left',left,2);m.set('_avi_paused',paused)
            m.set('_avi_frame',7,4);m.cpu.de=m.cpu.hl=0
            m.call('_avi_draw')
            n=m.get('_hud_len',2)//4
            words=struct.unpack('<%dI'%n,bytes(m.cpu.memory[hud:hud+4*n]))
            self.assertEqual(0x1F000009 in words,panel,(left,paused))      # BEGIN(RECTS)
            self.assertEqual(0xFFFFFF0C in words,panel,(left,paused))      # CMD_TEXT
            self.assertIn(0x1F000001,words)                                # BEGIN(BITMAPS)

    def test_hud_counters_follow_frames(self):
        # Время и полоса HUD считаются приращениями: сверяем с делением на
        # соседних кадрах, через границу минуты и после прыжков.
        m=Machine()
        m.set('_avi_width',512,2);m.set('_avi_height',384,2)
        m.set('_avi_total',4859,4);m.set('_avi_rate',25,4);m.set('_avi_scale',1,4)
        m.set('_avi_period',40000,4)
        m.call('_avi_hud_init');m.set('_hud_frame',0xFFFFFFFE,4)
        m.set('_hud_left',750,2)  # панель управления видна
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

    def test_playback_stop_only_when_playing(self):
        # Остановка звука FT812: пустой отрезок (длина 0, LOOP 0, PLAY 1 —
        # руководство FT81x), и только если звук идёт (PLAY читается 1).
        # PLAY = 0 при LOOP = 1 перезапускал кольцо; лишний запуск звукового
        # блока при звуке на GS роняет эмулятор Bridgetek без звукового
        # устройства Windows.
        class Playing(Machine):
            playing = 0

            def stub(self, name):
                if name == '_ft_rreg8' and self.arg(0, 2) == 0x20CC:
                    self.cpu.hl = self.playing; self.ret(); return
                super().stub(name)

        for bank in ('video', 'image'):
            for playing, regs in ((1, [(0x3020B8, 0), (0x3020C8, 0), (0x3020CC, 1)]),
                                  (0, [])):
                m = Playing(bank=bank); m.playing = playing
                m.call('_ft_pb_stop')
                self.assertEqual(m.regs, regs, (bank, playing))

    def test_end_of_audio_is_not_a_failure(self):
        # Кольцо FT812 доиграло записанное и пошло по кругу: пока данные в
        # файле есть — это опустошение (сбой), а в конце ролика — просто
        # конец звука (в заголовке сэмплов объявлено больше, чем в movi).
        for left, failed in ((0x1000, 1), (0, 0)):
            with self.subTest(left=left):
                m = Machine()
                m.set('_avi_pcm_rate', 22050, 2)
                m.set('_pcm_gs', 0)
                m.set('_avi_pcm_total', 40000, 4)
                m.set('_pcm_drop', 0, 4)
                m.set('_pcm_written', 30000, 4)
                m.set('_pcm_played', 30001, 4)
                m.set('_pcm_live', 1)
                m.set('_avi_left', left, 4)
                m.call('_pcm_poll')
                self.assertEqual(m.get('_view_failed'), failed)
                self.assertEqual(m.get('_fail_at'), 11 if failed else 0)
                self.assertEqual(m.get('_pcm_played', 4), 30001 if failed else 30000)
                self.assertEqual(m.get('_pcm_live'), 0)

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


class IndexTests(unittest.TestCase):
    """Таблица перемотки плеера против эталона avigen.seek_table: по idx1 и
    готовая из файла (JUNK FTViewConvert перед idx1)."""
    CASES = [dict(frames=1), dict(frames=7, audio=False), dict(frames=60), dict(frames=60, split=576),
             dict(frames=120, fps=24), dict(frames=400, split=576, lead=0),
             dict(frames=90, rate=11025, fps=30), dict(frames=6000, audio=False),
             dict(frames=5500, rate=8000, split=300)]

    def build(self, data):
        m = Machine(data, bank='image')
        m.call('_avi_probe', limit=20000)
        m.cpu.hl = m.s['_avi']
        m.call('_index_build', limit=200000)
        count = m.get('_index_count', 2)
        writes = [d for a, d in m.writes if 0xD0000 <= a < 0xE0000]
        return m, (m.get('_index_state'), m.get('_index_step', 2), bytes(m.ramg[0xD0000:0xD0000 + count * 12])), writes

    def test_idx1_table_matches_reference(self):
        from avigen import make_avi, seek_table
        for case in self.CASES + [dict(frames=30, index=False)]:
            with self.subTest(**case):
                data = make_avi(**case)[0]
                ref = seek_table(data)
                m, (state, step, table), writes = self.build(data)
                self.assertEqual(m.get('_view_failed'), 0)
                if ref is None:
                    self.assertEqual(state, 2)
                    continue
                self.assertEqual((state, step, table), (1, ref[0], ref[1]))
                self.assertEqual(len(writes), len(ref[1]) // 12)   # по записи на чанк idx1

    def test_embedded_table_is_loaded_in_bulk(self):
        from avigen import make_avi, seek_table, embed_index
        for case in self.CASES:
            with self.subTest(**case):
                data = make_avi(**case)[0]
                ref = seek_table(data)
                m, got, writes = self.build(embed_index(data))
                self.assertEqual(m.get('_view_failed'), 0)
                self.assertEqual(got, (1, ref[0], ref[1]))
                # Порции буфера чтения (FS_BUF_SIZE = 4 КиБ), а не запись на
                # каждый чанк idx1.
                self.assertLessEqual(len(writes), len(ref[1]) // 4096 + 2)

    def test_foreign_or_stale_table_falls_back_to_idx1(self):
        from avigen import make_avi, seek_table, embed_index, avi_fields
        data = make_avi(120, split=576)[0]
        ref = seek_table(data)
        good = embed_index(data)
        f = avi_fields(data)
        at = f['movi_end'] + (f['movi_end'] & 1) + 8     # данные JUNK
        for name, offset, value in (('magic', 7, b'2'), ('total', 22, b'\x79'), ('step 0', 8, b'\0\0'),
                                    ('count > max', 10, struct.pack('<H', 5461)), ('pcm_rate', 12, b'\x23')):
            with self.subTest(name):
                bad = bytearray(good)
                bad[at + offset:at + offset + len(value)] = value
                m, got, writes = self.build(bytes(bad))
                self.assertEqual(m.get('_view_failed'), 0)
                self.assertEqual(got, (1, ref[0], ref[1]))
                self.assertEqual(len(writes), len(ref[1]) // 12)

    def test_truncated_table_does_not_fail_playback(self):
        from avigen import make_avi, embed_index, avi_fields
        data = embed_index(make_avi(120, split=576)[0])
        f = avi_fields(data)
        cut = bytearray(data[:f['movi_end'] + 8 + 44 + 100])   # обрыв посреди записей, idx1 нет
        cut[4:8] = struct.pack('<I', len(cut) - 8)
        m, (state, _, _), _ = self.build(bytes(cut))
        self.assertEqual(m.get('_view_failed'), 0)
        self.assertEqual(state, 2)


class CacheTests(unittest.TestCase):
    def test_code_window_cached_at_14mhz(self):
        # Код и переменные плагина — в окне #8000: на 14 МГц без кэша каждое
        # обращение к памяти идёт с ожиданием. Кэш включается после TURBOPL,
        # который сам оставляет только окно #4000.
        from avigen import make_avi
        m=Machine(make_avi(8,audio=False)[0])
        m.call('_show_avi',limit=20000)
        self.assertIn(0x0E,m.api_calls)
        self.assertEqual(m.ts.get(0x2B),0x06)


class EscTests(unittest.TestCase):
    def test_esc_during_avi_exits_at_once(self):
        # Esc во время просмотра ставит ABT (#6004) прерыванием WC. Модель
        # ставит ABT после последнего кадра, а API Esc (#17) отвечает «не
        # нажата» — как короткое нажатие, отпущенное за время перемотки или
        # построения индекса. main_start выходит в WC сразу, не ждёт второго Esc.
        from avigen import make_avi
        data,_,_=make_avi(12,audio=False)
        m=Machine(data)
        m.cpu.set_memory_block(0xBFE0,(0x5D00).to_bytes(2,'little'))  # ret_sp: адрес возврата call()
        m.cpu.memory[0xBFEA]=4   # file_ext = EXT_AVI
        m.cpu.memory[0xBFED]=1   # ft_state: VDAC2 найден
        m.call('_main_start',limit=20000)
        self.assertEqual(m.get('_avi_frame',4),12)
        self.assertEqual(m.cpu.a,0)             # WC_EXIT
        self.assertNotIn(0x17,m.api_calls)      # Esc не опрашивалась



def sfn_sum(sfn):
    """Контрольная сумма короткого имени FAT (её несут части длинного)."""
    s=0
    for b in sfn:s=((s>>1)|(s<<7))+b&255
    return s


def lfn_entries(name,sfn,checksum=None,deleted=False):
    """Части длинного имени FAT32 перед записью sfn: последняя — первой."""
    u=[ord(c) for c in name]
    if len(u)%13:u+=[0]+[0xFFFF]*(12-len(u)%13)
    n=len(u)//13;s=sfn_sum(sfn) if checksum is None else checksum
    out=b''
    for i in range(n,0,-1):
        e=bytearray(32);e[0]=0xE5 if deleted else i|(0x40 if i==n else 0)
        e[11]=0x0F;e[13]=s
        for j,o in enumerate((1,3,5,7,9,14,16,18,20,22,24,28,30)):
            e[o:o+2]=u[(i-1)*13+j].to_bytes(2,'little')
        out+=bytes(e)
    return out


def list_volume(m,frame=None):
    """Каталог с роликами, чужими AVI и прочими записями; текущий — BETA.AVI.

    frame(n) — кадры роликов (настоящие JPEG для test_chip.py).
    """
    from avigen import make_avi
    def avi(frames,handler=b'MJPG'):
        return make_avi(frames,audio=False,frame=frame)[0].replace(b'vidsMJPG',b'vids'+handler,1)
    d=bytearray(m.dir_entry(b'.          ',0,0,0x10)+m.dir_entry(b'..         ',0,0,0x10))
    files={}
    def add(sfn,data,name=None,**kw):
        c=m.add_object(data)
        if name:d.extend(lfn_entries(name,sfn,**kw))
        d.extend(m.dir_entry(sfn,c,len(data)))
        files[sfn]=(c,len(data))
    add(b'ZETACL~1AVI',avi(6),'Zeta clip.avi')
    add(b'BETA    AVI',avi(12))
    add(b'NOTES   TXT',b'text')
    add(bytes([0x91,0xE3,0xAF,0xA5,0xE0])+b'~1 AVI',avi(3),'Супер клип.avi')
    add(b'01INTR~1AVI',avi(3),'01 intro.avi')
    add(b'XVID    AVI',avi(3,b'XVID'))
    add(b'GAMMA   AVI',avi(5),'Wrong name.avi',checksum=0x55)
    add(bytes([0xF0])+b'LKA~1  AVI',avi(3),'Ёлка.avi')
    add(b'ALPHAV~1AVI',avi(4,b'mjpg'),'alpha video.avi')
    add(b'FAKE    AVI',b'hello, not a RIFF file')
    add(bytes([0x8A,0x88,0x8D,0x8E])+b'    AVI',avi(3))
    add(b'AVERYL~1AVI',avi(2),'A very long video file name that exceeds the limit.avi')
    # «холод.AVI» без длинного имени: первый байт «х» (#E5) FAT хранит как #05.
    add(bytes([0x05,0xAE,0xAB,0xAE,0xA4])+b'   AVI',avi(3))
    d.extend(lfn_entries('Deleted clip.avi',b'DELETE~1AVI',deleted=True))
    d.extend(m.dir_entry(bytes([0xE5])+b'ELETE~1AVI',0,100))
    d.extend(m.dir_entry(b'MOVIES  AVI',0,0,0x10))
    d.extend(bytes(-len(d)%512+512))
    m.dir_cluster=m.add_object(bytes(d),eoc=True)
    return files



# Строка окна списка под имя (WX1 - WX0 - 56) и размер записи таблицы.
LIST_NAME_PX = 776
LIST_ENTRY_SIZE = 124
LIST_NAME_MAX = 96
TRANSLIT = ['a', 'b', 'v', 'g', 'd', 'e', 'zh', 'z', 'i', 'y', 'k', 'l', 'm', 'n', 'o', 'p',
            'r', 's', 't', 'u', 'f', 'kh', 'ts', 'ch', 'sh', 'shch', '', 'y', '', 'e', 'yu', 'ya']


def list_shown(name):
    """Имя в списке, как его строит банк списка: без «.avi», кириллица
    транслитом, шире строки окна — самое длинное начало с «...»."""
    lfn = name[:104]
    if len(lfn) > 4 and lfn[-4:].lower() == '.avi':
        lfn = lfn[:-4]
    out = ''
    for c in lfn:
        o = ord(c)
        if 0x410 <= o < 0x450:
            t = TRANSLIT[(o - 0x410) & 31]
            out += (t[:1].upper() if o < 0x430 else t[:1]) + t[1:]
        elif c in 'Ёё':
            out += ('Y' if c == 'Ё' else 'y') + 'o'
        else:
            out += (' ' if c == '_' else c) if 0x20 <= o < 0x7F else '?'
    width = lambda s: sum(FONT28[ord(ch)] for ch in s)
    stored = out[:LIST_NAME_MAX]
    if len(out) <= LIST_NAME_MAX and width(stored) <= LIST_NAME_PX:
        return stored
    dots = 3 * FONT28[ord('.')]
    keep = max(k for k in range(len(stored) + 1) if width(stored[:k]) + dots <= LIST_NAME_PX)
    return stored[:keep].rstrip(' ') + '...'


LONG_NAMES = ['An extremely long file name that certainly does not fit into the list window '
              'at all and goes on.avi',
              'W' * 60 + '.avi',
              'Short name.AVI',
              'Name with dots v1.2.avi',
              'Очень длинное русское название видеоролика про щуку и ёжика, которое '
              'в окно не помещается.avi',
              # 250 символов — 20 частей LFN: номер части больше не
              # переполняет байт смещения и не затирает начало имени.
              'Zebra ' + 'x' * 240 + '.avi',
              'my_video_clip_2026.avi']
# Только короткое имя: подчёркивание и здесь — пробел.
SFN_ONLY = {b'A_B     AVI': 'A B'}


def long_volume(m, frame=None):
    """Каталог с длинными именами и текущим BETA.AVI (только короткое имя)."""
    from avigen import make_avi
    data = make_avi(12, audio=False, frame=frame)[0]
    d = bytearray()
    files = {}
    for n, name in enumerate(LONG_NAMES):
        sfn = b'LONG%d~1 AVI' % n
        c = m.add_object(data)
        d.extend(lfn_entries(name, sfn))
        d.extend(m.dir_entry(sfn, c, len(data)))
        files[name] = c
    for sfn, shown in SFN_ONLY.items():
        c = m.add_object(data)
        d.extend(m.dir_entry(sfn, c, len(data)))
        files[shown] = c
    beta = m.add_object(data)
    d.extend(m.dir_entry(b'BETA    AVI', beta, len(data)))
    files['BETA'] = beta
    d.extend(bytes(-len(d) % 512 + 512))
    m.dir_cluster = m.add_object(bytes(d), eoc=True)
    m.objects[0] = [o for o in m.objects if o[0][0] == beta][0]
    m.set('_filesize', len(data), 4)
    return files


class ListMachine(Machine):
    """Плеер с каталогом роликов. keys[n] — коды API клавиш, нажатых при n-м
    опросе окна списка (опрос list_keys начинается со «вверх», #11). В плеере
    Enter (#16) нажимается один раз, начиная с кадра enter_at. Список
    открывается и сам в конце ролика: когда keys кончились, опросом позже
    нажимается Esc (ABT) — окно закрывается, как у пользователя."""
    list_model = True

    def __init__(self,*a,keys=(),enter_at=None,**kw):
        super().__init__(*a,**kw)
        self.keys,self.polls,self.enter_at=list(keys),-1,enter_at

    def api(self):
        key=self.cpu.a
        if self.bank=='list' and (0x10<=key<=0x1C or key==0x2D):
            if key==0x11:
                self.polls+=1
                if self.polls>len(self.keys):self.cpu.memory[0x6004]=1
            held=self.keys[self.polls] if 0<=self.polls<len(self.keys) else ()
            self.cpu.a,self.cpu.f=0,0 if key in held else 0x40
            self.api_calls.append(key);self.ret()
        elif (self.bank=='video' and key==0x16 and self.enter_at is not None and
              self.get('_avi_frame',4)>=self.enter_at):
            self.enter_at=None
            self.cpu.a,self.cpu.f=0,0
            self.api_calls.append(key);self.ret()
        else:super().api()


class ListTests(unittest.TestCase):
    """Enter в плеере: список роликов MJPG каталога (банк списка, страница 10)."""
    SHOWN=['01 intro','A very long video file name that exceeds the limit','alpha video',
           'BETA','GAMMA','Zeta clip','Yolka','KINO','Super klip','kholod']

    def volume(self,m):
        return list_volume(m)

    def texts(self,m):
        """Строки CMD_TEXT последнего окна (с последнего CMD_DLSTART)."""
        stream=b''.join(d for a,d in m.writes if a==0x302578)
        stream=stream[stream.rindex(struct.pack('<I',0xFFFFFF00)):]
        out,i=[],0
        while True:
            i=stream.find(struct.pack('<I',0xFFFFFF0C),i)
            if i<0:return out
            end=stream.index(0,i+12);out.append(stream[i+12:end].decode());i=end

    def run_list(self,keys):
        """far_entry банка списка: кадр 512×384 растянут на 1024×768."""
        m=ListMachine(bank='list',keys=keys)
        files=self.volume(m)
        c,_=files[b'BETA    AVI']
        m.cpu.set_memory_block(0xFF00+56,struct.pack('<HHI',512,384,c))   # AVI_FAR
        m.cpu.set_memory_block(0xFE00,bytes(6)+struct.pack('<HHII',1024,768,128,128))
        m.cpu.hl=0xFE00
        m.call('_far_entry',limit=5000)
        return m,files,self.result(m)

    @staticmethod
    def result(m):
        """Выбор: признак в блоке списка, кластер и размер — в копии AVI_FAR."""
        chosen=m.cpu.memory[0xFE00]
        cluster,size=struct.unpack_from('<II',bytes(m.cpu.memory[0xFF00+60:0xFF00+68]))
        return chosen,cluster,size

    def names(self,m):
        base,n=m.s['_list_e'],m.get('_list_count')
        e=LIST_ENTRY_SIZE
        return [bytes(m.cpu.memory[base+e*i+24:base+e*i+e]).split(bytes(1))[0].decode()
                for i in range(n)]

    def test_list_sorted_filtered_and_on_current(self):
        # Enter ещё держится с плеера (опрос 0) — не выбор; вниз дважды и Enter.
        m,files,result=self.run_list([(0x16,),(),(0x12,),(),(0x12,),(),(0x16,)])
        self.assertEqual(self.names(m),self.SHOWN)
        self.assertEqual(m.get('_list_sel'),5)
        self.assertEqual(result,(1,*files[b'ZETACL~1AVI']))
        shown=self.texts(m)
        self.assertEqual(shown[0],'Videos in this folder')
        self.assertEqual([t for t in shown if t in self.SHOWN],self.SHOWN)
        self.assertIn('Up/Down select | Enter play | Esc back',shown)
        self.assertEqual(m.cpu.memory[0x6004],0)
        # Первый сектор прочитан у каждого *.AVI, и только у них.
        self.assertEqual(sorted({c for c,_ in m.gipags}-{m.dir_cluster}),
                         sorted(c for n,(c,_) in files.items() if n.endswith(b'AVI')))

    def test_esc_keeps_video_enter_on_current_replays(self):
        # Esc — назад к ролику. Enter — запуск выбранного, в том числе
        # текущего: плеер начнёт его с начала (в конце ролика — ещё раз).
        for keys,replay in (([(0x16,),(),(0x17,)],0),([(),(0x16,)],1),
                            ([(0x12,),(0x12,0x16),(0x16,),(0x11,),(),(0x16,)],1)):
            with self.subTest(keys=keys):
                m,files,(chosen,cluster,size)=self.run_list(keys)
                self.assertEqual(chosen,replay)
                self.assertEqual(m.get('_list_sel'),3)
                if replay:self.assertEqual((cluster,size),files[b'BETA    AVI'])

    def test_navigation_keys_and_autorepeat(self):
        # End, Home, PgDn, PgUp и удержание «вниз»: шаг сразу, после 0,4 с
        # удержания (21 тик) — раз в три тика: 27 опросов — ещё три шага.
        # Первый опрос — клавиши, державшиеся при открытии окна, не в счёт.
        # Выбор — Enter на последнем положении, и на текущем ролике тоже.
        cases=[([(),(0x1C,),(),(0x16,)],9),([(),(0x1B,),(),(0x16,)],0),
               ([(),(0x1A,),(),(0x16,)],9),([(0x1C,),(),(0x16,)],3),
               ([(),(0x11,),(),(0x19,),(),(0x16,)],0),
               ([()]+[(0x12,)]*27+[(),(0x16,)],3+1+3)]
        for keys,sel in cases:
            with self.subTest(sel=sel,keys=len(keys)):
                m,files,(chosen,cluster,_)=self.run_list(keys)
                self.assertEqual(m.get('_list_sel'),sel)
                self.assertEqual(chosen,1)
                self.assertEqual(cluster,m.get('_list_e',4) if not sel else
                                 int.from_bytes(m.cpu.memory[m.s['_list_e']+LIST_ENTRY_SIZE*sel:
                                                             m.s['_list_e']+LIST_ENTRY_SIZE*sel+4],'little'))

    def test_empty_folder_message(self):
        m=ListMachine(bank='list',keys=[(),(0x12,),(0x16,)])
        d=m.dir_entry(b'NOTES   TXT',m.add_object(b'x'),1)+bytes(512-32)
        m.dir_cluster=m.add_object(d,eoc=True)
        m.cpu.set_memory_block(0xFF00+56,struct.pack('<HHI',512,384,3))
        m.cpu.hl=0xFE00
        m.call('_far_entry',limit=5000)
        self.assertEqual(m.cpu.memory[0xFE00],0)
        self.assertIn('No MJPEG AVI files here',self.texts(m))

    def test_enter_switches_video(self):
        # Плеер: Enter на третьем кадре, в списке — другой ролик: его плеер
        # играет покадрово, с первого кадра до конца. В обе стороны: BETA
        # (12 кадров) -> Zeta clip.avi (6) и обратно. Переход на ролик крупнее
        # ловит размер файла у банка изображений: с прежним разбор заголовка
        # отвергал RIFF, и ролик уходил в штатный PLAYVIDEO.
        for start,moves,end,frames in ((b'BETA    AVI',(0x12,0x12),b'ZETACL~1AVI',6),
                                       (b'ZETACL~1AVI',(0x11,0x11),b'BETA    AVI',12)):
            with self.subTest(start=start):
                keys=[(0x16,),()]+[k for key in moves for k in ((key,),())]+[(0x16,)]
                m=ListMachine(keys=keys,enter_at=3)
                files=self.volume(m)
                first,chosen=files[start],files[end]
                # Ролик, с которым WC запустил плагин.
                m.objects[0]=[o for o in m.objects if o[0][0]==first[0]][0]
                m.set('_filesize',first[1],4)
                m.call('_show_avi',limit=200000)
                self.assertEqual(m.get('_view_failed'),0)
                self.assertIn(0x16,m.api_calls)
                self.assertFalse(m.native_playing)
                self.assertEqual(m.get('_avi_cluster',4),chosen[0])
                self.assertEqual(m.get('_avi_size',4),chosen[1])
                self.assertEqual(m.get('_avi_total',4),frames)
                self.assertEqual(m.get('_avi_frame',4),frames)
                # Поток нового ролика открыт его первым кластером.
                self.assertIn((chosen[0],0),m.gipags)
    def test_list_opens_at_end_of_video(self):
        # Ролик доиграл — список роликов каталога открывается сам: Enter в
        # плеере не нажимали. Вниз и Enter — следующий ролик (GAMMA); в его
        # конце снова список, Enter на текущем — GAMMA ещё раз с начала; в
        # третий раз клавиши кончились — Esc: последний кадр на паузе.
        m=ListMachine(keys=[(),(0x12,),(),(0x16,),(),(0x16,)])
        files=self.volume(m)
        beta,gamma=files[b'BETA    AVI'],files[b'GAMMA   AVI']
        m.objects[0]=[o for o in m.objects if o[0][0]==beta[0]][0]
        m.set('_filesize',beta[1],4)
        lists=[]
        entry=symbols(m.out,'list')['_list_run']
        m.watch={entry:lambda:lists.append(1) if m.bank=='list' else None}
        m.call('_show_avi',limit=400000)
        self.assertEqual(m.get('_view_failed'),0)
        # Три списка — три конца: BETA, GAMMA и GAMMA после повтора с начала.
        # Без повтора (Enter на текущем — «назад») списков было бы два.
        self.assertEqual(len(lists),3)
        self.assertEqual(m.get('_avi_cluster',4),gamma[0])
        self.assertEqual(m.get('_avi_total',4),5)
        self.assertEqual(m.get('_avi_frame',4),5)
        self.assertEqual(m.get('_avi_paused'),1)

    def clips(self,count,current,keys):
        """Каталог CLIP00..: в обратном порядке, чтобы список сортировал."""
        from avigen import make_avi
        m=ListMachine(bank='list',keys=keys)
        data=make_avi(1,audio=False)[0]
        d=bytearray();cluster={}
        for n in reversed(range(count)):
            c=cluster[n]=m.add_object(data)
            d.extend(m.dir_entry(b'CLIP%02d  AVI'%n,c,len(data)))
        d.extend(bytes(-len(d)%512+512))
        m.dir_cluster=m.add_object(bytes(d),eoc=True)
        m.cpu.set_memory_block(0xFF00+56,struct.pack('<HHI',64,48,cluster[current]))
        m.cpu.set_memory_block(0xFE00,bytes(6)+struct.pack('<HHII',1024,768,16,16))
        m.cpu.hl=0xFE00
        m.call('_far_entry',limit=20000)
        rows=[t for t in self.texts(m) if t.startswith('CLIP')]
        return m,cluster,rows

    def test_long_list_scrolls_around_cursor(self):
        # 40 роликов, 17 строк: текущий — посередине окна, у конца списка окно
        # упирается в последнюю строку; PgUp — на 17 строк вверх.
        m,cluster,rows=self.clips(40,30,[(),(0x16,)])
        self.assertEqual((m.get('_list_sel'),m.get('_list_top')),(30,22))
        self.assertEqual(rows,['CLIP%02d'%n for n in range(22,39)])
        m,cluster,rows=self.clips(40,38,[(),(0x1C,),(),(0x19,),(),(0x16,)])
        self.assertEqual((m.get('_list_sel'),m.get('_list_top')),(22,22))
        self.assertEqual(rows,['CLIP%02d'%n for n in range(22,39)])
        self.assertEqual(self.result(m)[:2],(1,cluster[22]))

    def test_full_table_keeps_current(self):
        # Таблица на 80 роликов. Каталог идёт от CLIP89 вниз: в неё попали
        # CLIP89..CLIP10, а текущий CLIP03 встал на место последнего (CLIP10).
        m,cluster,rows=self.clips(90,3,[(),(0x17,)])
        self.assertEqual(m.get('_list_count'),80)
        self.assertEqual(self.names(m),['CLIP03']+['CLIP%02d'%n for n in range(11,90)])
        self.assertEqual(m.get('_list_sel'),0)

    def test_long_names_cut_to_window(self):
        # Имена без «.avi» (и у коротких имён, и у длинных, в любом регистре);
        # шире строки окна (776 точек шрифта 28 от WX0 + 28) — самое длинное
        # начало, за которым помещается «...». Ширины — таблица шрифта из ПЗУ.
        m=ListMachine(bank='list',keys=[(),(0x17,)])
        files=long_volume(m)
        m.cpu.set_memory_block(0xFF00+56,struct.pack('<HHI',64,48,files['BETA']))
        m.cpu.set_memory_block(0xFE00,bytes(6)+struct.pack('<HHII',1024,768,4096,4096))
        m.cpu.hl=0xFE00
        m.call('_far_entry',limit=5000)
        names=self.names(m)
        want=[list_shown(n) for n in LONG_NAMES]+['BETA',*SFN_ONLY.values()]
        self.assertEqual(sorted(names),sorted(want))
        width=lambda s:sum(FONT28[ord(c)] for c in s)
        for name in names:
            self.assertLessEqual(width(name),LIST_NAME_PX,name)
            self.assertFalse(name.lower().endswith('.avi'),name)
        self.assertEqual(want[1],'W'*42+'...')
        self.assertEqual(want[2:4],['Short name','Name with dots v1.2'])
        self.assertTrue(want[0].endswith('...') and want[4].endswith('...'))
        self.assertTrue(want[5].startswith('Zebra xxx') and want[5].endswith('...'),want[5])
        self.assertIn('my video clip 2026',names)
        self.assertIn('A B',names)
        self.assertFalse(any('_' in n for n in names),names)
        # Окно получило те же строки; таблица кончается до блоков #FE00.
        self.assertEqual(sorted(t for t in self.texts(m) if t in want),sorted(want))
        self.assertLessEqual(m.s['_list_e']+80*LIST_ENTRY_SIZE,0xFE00)

    def test_foreign_codec_reports_message(self):
        # AVI с чужим кодеком плеер не отдаёт штатному PLAYVIDEO (он покажет
        # мусор), а сообщает «Unsupported video codec». Регистр FOURCC не
        # важен: mjpg играется как MJPG.
        from avigen import make_avi
        # Обрезанный файл (размер в RIFF больше длины) разбор заголовка бросает
        # ещё до кодека, поэтому кодек проверяется отдельно, перед показом.
        for handler, cut, played in ((b'XVID', False, False), (b'XVID', True, False),
                                     (b'mjpg', False, True)):
            with self.subTest(handler=handler, cut=cut):
                data = make_avi(6, audio=False)[0].replace(b'vidsMJPG', b'vids' + handler, 1)
                if cut: data = data[:len(data) // 2]
                m = Machine(data)
                m.cpu.set_memory_block(0xBFE0, (0x5D00).to_bytes(2, 'little'))  # ret_sp
                m.cpu.memory[0xBFEA] = 4   # file_ext = EXT_AVI
                m.cpu.memory[0xBFED] = 1   # ft_state: VDAC2 найден
                m.call('_main_start', limit=100000)
                self.assertFalse(m.native_playing)
                if played:
                    self.assertEqual((m.get('_view_failed'), m.get('_avi_frame', 4)), (0, 6))
                    self.assertEqual(m.windows, [])
                else:
                    self.assertEqual(m.get('_view_failed'), 3)   # VIEW_CODEC
                    self.assertEqual(m.get('_avi_frame', 4), 0)
                    self.assertEqual(len(m.windows), 1)
                    header, _, text = m.windows[0]
                    self.assertIn('Cannot play video', header)
                    self.assertIn('Unsupported video codec.', text)
                    self.assertIn('FTView plays MJPEG AVI.', text)

    def test_error_window_shows_reason(self):
        # В окне отказа видно место, где плеер сдался (fail_at): редкий сбой
        # у пользователя разбирается по номеру, а не по догадкам.
        from avigen import make_avi
        m = Machine(make_avi(6, audio=False)[0], fail_read=1)
        m.cpu.set_memory_block(0xBFE0, (0x5D00).to_bytes(2, 'little'))
        m.cpu.memory[0xBFEA] = 4   # file_ext = EXT_AVI
        m.cpu.memory[0xBFED] = 1   # ft_state: VDAC2 найден
        m.call('_main_start', limit=100000)
        code = m.get('_fail_at')
        # 7 — разбор заголовка (банк изображений) не дочитал файл.
        self.assertEqual((m.get('_view_failed'), code), (1, 7))
        self.assertEqual(len(m.windows), 1)
        self.assertIn('Cannot display file', m.windows[0][0])
        self.assertIn('Reason %02d' % code, m.windows[0][2])


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--out',type=Path,default=OUT)
    args,rest=parser.parse_known_args()
    OUT=args.out
    unittest.main(argv=[sys.argv[0],*rest])
