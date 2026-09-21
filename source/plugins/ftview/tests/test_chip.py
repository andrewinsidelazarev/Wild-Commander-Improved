"""Z80 + официальный FT812: пиксели, видеорегистры, AVI и управление кадрами."""
import io
import argparse
import struct
import sys
import unittest

from test_ftview import Machine, picture, Image, PLUGIN, WC, OUT
import test_ftview
from pathlib import Path

sys.path.insert(0,str(WC/'source/plugins/txthex_viewer_VDAC2/tools'))
from ft812emu import FT812
import ft812emu
import time


def avi(frames=5, width=64, height=48, period=100000):
    """Небольшой настоящий RIFF/MJPEG без внешнего кодировщика/скачивания."""
    def chunk(tag,data):return tag+struct.pack('<I',len(data))+data+bytes(len(data)%2)
    def list_(tag,data):return chunk(b'LIST',tag+data)
    avih=struct.pack('<14I',period,20000,0,0,frames,0,1,0,width,height,0,0,0,0)
    strh=struct.pack('<4s4sIHHIIIIIIIIhhhh',b'vids',b'MJPG',0,0,0,0,period,1000000,
                     0,frames,0,0xFFFFFFFF,0,0,0,width,height)
    strf=struct.pack('<IiiHH4sIiiII',40,width,height,1,24,b'MJPG',width*height*3,0,0,0,0)
    header=list_(b'hdrl',chunk(b'avih',avih)+list_(b'strl',chunk(b'strh',strh)+chunk(b'strf',strf)))
    data=[]
    for n in range(frames):
        stream=io.BytesIO()
        Image.new('RGB',(width,height),(40+n*30%200,40,80)).save(stream,'JPEG')
        data.append(chunk(b'00dc',stream.getvalue()))
    return chunk(b'RIFF',b'AVI '+header+list_(b'movi',b''.join(data)))


def pcm_avi(frames=80, rate=22050, tag=1):
    from make_av_sync import chunk, list_chunk
    fps,width,height=25,64,48
    audio=bytes((i//17*13)%256 for i in range(frames*rate//fps))
    avih=struct.pack('<14I',40000,100000,0,0,frames,0,2,0,width,height,0,0,0,0)
    vh=struct.pack('<4s4sIHHIIIIIIIIhhhh',b'vids',b'MJPG',0,0,0,0,1,fps,0,frames,0,0xFFFFFFFF,0,0,0,width,height)
    vf=struct.pack('<IiiHH4sIiiII',40,width,height,1,24,b'MJPG',width*height*3,0,0,0,0)
    ah=struct.pack('<4s4sIHHIIIIIIIIhhhh',b'auds',bytes(4),0,0,0,0,1,rate,0,len(audio),0,0xFFFFFFFF,1,0,0,0,0)
    af=struct.pack('<HHIIHH',tag,1,rate,rate,1,8)  # 1 — PCM, 7 — µ-law
    head=list_chunk(b'hdrl',chunk(b'avih',avih)+list_chunk(b'strl',chunk(b'strh',vh)+chunk(b'strf',vf))+list_chunk(b'strl',chunk(b'strh',ah)+chunk(b'strf',af)))
    pos=rate//5;data=[chunk(b'01wb',audio[:pos])]
    for n in range(frames):
        out=io.BytesIO();Image.new('RGB',(width,height),(40+n*2%200,40,80)).save(out,'JPEG')
        data.append(chunk(b'00dc',out.getvalue()))
        end=min(len(audio),pos+rate//fps)
        if end>pos:data.append(chunk(b'01wb',audio[pos:end]));pos=end
    assert pos==len(audio)
    return chunk(b'RIFF',b'AVI '+head+list_chunk(b'movi',b''.join(data))),audio


class AudioMachine(Machine):
    def __init__(self,*args,action=None,**kw):
        super().__init__(*args,**kw)
        self.action,self.phase,self.runs=action,0,[]
        self.paused_at=None;self.paused_sample=None

    def api(self):
        key=self.cpu.a
        if key==0x32:self.runs.append({'audio':bytearray(),'drop':None})
        if 0x10<=key<=0x1C:
            frame=self.get('_avi_frame',4);pressed=False
            if self.action=='home' and not self.phase and key==0x1B and frame>=10:
                pressed=True;self.phase=1
            if self.action=='forward' and not self.phase and key==0x14 and frame>=3:
                pressed=True;self.phase=1
            if self.action=='pause' and key==0x10:
                if not self.phase and frame>=6:pressed=True;self.phase=1
                elif self.phase==1 and self.get('_avi_paused'):
                    if self.paused_at is None:
                        self.paused_at=time.monotonic();self.paused_sample=self.get('_pcm_played',4)
                    assert self.get('_pcm_played',4)==self.paused_sample,'PCM advances while paused'
                    if time.monotonic()-self.paused_at>.08:pressed=True;self.phase=2
            if frame==self.get('_avi_total',4) and self.get('_avi_paused'):
                self.cpu.memory[0x6004]=1
            self.cpu.f=0 if pressed else 0x40;self.api_calls.append(key);self.ret()
        else:super().api()

    def stub(self,name):
        if name=='_ft_write':
            address=self.arg(2,4)
            if 0xC0000<=address<0xD0000:
                ptr,count=self.arg(0,2),self.arg(6,2)
                self.runs[-1]['audio'].extend(self.cpu.memory[ptr:ptr+count])
                self.runs[-1]['drop']=self.get('_pcm_drop',4)
        # Цифровой звуковой курсор работает, но тест не выводит шум в RDS.
        if name=='_ft_wreg8' and self.arg(0,2)==0x2080:
            self.cpu.memory[self.cpu.sp+4]=0
        super().stub(name)


class ControlledMachine(Machine):
    def __init__(self,*a,action=None,**kw):
        super().__init__(*a,**kw)
        self.action,self.triggered=action,False

    def api(self):
        key=self.cpu.a
        if 0x10<=key<=0x1C:
            frame=self.get('_avi_frame',4)
            pressed=False
            if self.action=='home' and key==0x1B and frame==4 and not self.triggered:
                pressed=self.triggered=True
            if self.action=='forward' and key==0x14 and frame==1 and not self.triggered:
                pressed=self.triggered=True
            if frame==self.get('_avi_total',4) and frame:
                self.cpu.memory[0x6004]=1
            self.cpu.f=0 if pressed else 0x40
            self.api_calls.append(key);self.ret()
        else:super().api()


def windows_audio():
    """Звуковой тракт DLL (флаг 2) требует службы Windows Audio."""
    import subprocess
    try:
        out = subprocess.run(['sc', 'query', 'Audiosrv'], capture_output=True, text=True).stdout
    except OSError:
        return False
    return 'RUNNING' in out


class SeekMachine(Machine):
    """Right на кадре press, выход сразу после показа кадра назначения."""
    def __init__(self, *a, press=4, **kw):
        super().__init__(*a, **kw)
        self.press, self.target, self.shown = press, None, None

    def api(self):
        key = self.cpu.a
        if 0x10 <= key <= 0x1C:
            frame = self.get('_avi_frame', 4)
            pressed = False
            if self.target is None and key == 0x14 and frame >= self.press:
                pressed = True
                self.target = min(self.get('_avi_total', 4) - 1,
                                  frame - 1 + 10000000 // self.get('_avi_period', 4))
            if self.target is not None and frame > self.target and self.shown is None:
                # Esc (ABT) ставит ядро WC в любой момент: плагин может
                # прервать уже начатый следующий кадр. Сбоев до Esc быть не должно.
                self.shown = frame - 1
                self.failed_before_esc = self.get('_view_failed')
                self.cpu.memory[0x6004] = 1
            self.cpu.f = 0 if pressed else 0x40
            self.api_calls.append(key); self.ret()
        else:
            super().api()


class ChipTests(unittest.TestCase):
    def test_index_seek_decodes_target_frame(self):
        # Настоящий сопроцессор: после повторного CMD_VIDEOSTART поток —
        # заголовок до 'movi', выравнивающий JUNK и чанки с середины файла.
        from avigen import make_avi, jpeg
        colors = lambda n: (40 + n * 30 % 200, 40 + n * 7 % 150, 80)
        data, _, _ = make_avi(300, audio=False, frame=jpeg)
        with FT812() as chip:
            chip.boot()
            m = SeekMachine(data, chip=chip)
            m.call('_show_avi', limit=400000)
            self.assertEqual(m.failed_before_esc, 0)
            self.assertEqual(m.shown, m.target)
            self.assertEqual(m.target, 253)
            self.assertTrue(m.gipags)
            self.assertGreater(m.get('_avi_seek_pos', 4), 0)
            # До цели декодировано лишь несколько кадров от точки входа.
            decoded = sum(d[:4] == struct.pack('<I', 0xFFFFFF41)
                          for a, d in m.writes if a == 0x302578)
            self.assertLess(decoded, 12)
            chip.wait_idle(); frame = chip.frame()
            want = colors(253)
            got = frame.getpixel((512, 350))
            for c in range(3):
                self.assertAlmostEqual(got[c], want[c], delta=10, msg=(got, want))
            self.assertFalse(chip.errors)

    def test_gs_audio_drives_real_decoder(self):
        from gsemu import find_rom
        if not find_rom():
            self.skipTest('GS ROM not found')
        from test_gs import GSPlayer, booted_gs, pcm_sample
        from avigen import make_avi, jpeg
        data, pcm, _ = make_avi(50, frame=jpeg, split=576)
        g = booted_gs(test_ftview.OUT)
        boot = Machine(bank='image', gs=g)
        boot.call('_gs_boot', limit=200000)
        self.assertEqual(boot.cpu.a, 1)
        g.samples.clear()
        with FT812() as chip:
            chip.boot()
            m = GSPlayer(data, chip=chip, gs=g,
                         actions=[(lambda f, m: f >= 30, 0x14)])
            m.call('_show_avi', limit=2000000)
            self.assertEqual(m.get('_view_failed'), 0)
            self.assertEqual(m.get('_pcm_gs'), 1)
            self.assertEqual(m.get('_avi_frame', 4), 50)
            left = [v for _, c, v in g.samples if c == 0]
            # Right с кадра 29 упирается в последний кадр 49.
            k = 0
            while k < len(left) and left[k] == pcm[k]:
                k += 1
            s = pcm_sample(49)
            self.assertEqual(left[k:], list(pcm[s:]))
            self.assertGreater(k, pcm_sample(20))
            chip.wait_idle(); frame = chip.frame()
            self.assertAlmostEqual(frame.getpixel((512, 350))[0], 40 + 49 * 30 % 200, delta=10)
            self.assertFalse(chip.errors)

    def test_pcm_sound_seek_pause_and_eof(self):
        if not windows_audio():
            self.skipTest('FT812 audio emulation needs the Windows Audio service (Audiosrv) running')
        original=ft812emu.FLAG_COPROCESSOR
        ft812emu.FLAG_COPROCESSOR |= 2  # включаем цифровой playback clock DLL
        try:
            for tag,action in [(1,a) for a in (None,'home','forward','pause')]+[(7,None),(7,'home')]:
                data,audio=pcm_avi(tag=tag)
                with self.subTest(tag=tag,action=action),FT812() as chip:
                    chip.boot();m=AudioMachine(data,chip=chip,action=action)
                    # µ-law сделан для FT812 и при загруженном GS: признак
                    # GS есть, самой карты нет — обмен с ней сорвал бы тест.
                    if tag==7:m.set('_gs_loaded',1)
                    m.call('_show_avi',limit=500000)
                    self.assertEqual(m.get('_view_failed'),0,(action,m.get('_pcm_played',4),m.get('_pcm_written',4)))
                    self.assertEqual(m.get('_avi_pcm_rate',2),22050)
                    self.assertEqual(m.get('_pcm_underruns',2),0)
                    self.assertEqual(m.get('_avi_frame',4),80)
                    self.assertEqual(m.get('_pcm_live'),0)
                    if action:self.assertGreater(m.phase,0)
                    # PCM8 беззнаковый переводится в знаковый LINEAR, µ-law —
                    # родной формат FT812: байты идут как есть.
                    flip=128 if tag==1 else 0
                    for run in m.runs:
                        if run['drop'] is None:continue
                        drop=run['drop'];sent=bytes(run['audio'])
                        self.assertEqual(sent,bytes(x^flip for x in audio[drop:drop+len(sent)]))
                    self.assertIn((0x3020C4,0 if tag==1 else 1),m.regs)
                    self.assertFalse(chip.errors)
        finally:ft812emu.FLAG_COPROCESSOR=original

    def test_native_media_fifo_must_finish_video(self):
        # Настоящий FT812 освобождает параметры PLAYVIDEO в командном FIFO
        # ещё во время воспроизведения. Без команды-барьера старый код выходил
        # после 8192 байт из 68634, а модель транспорта этого не обнаруживала.
        data = avi(100, 64, 48, 10000)
        with FT812() as chip:
            chip.boot()
            m = Machine(data, chip=chip)
            m.cpu.a = 1  # bool native, ABI SDCC 1.
            m.call('_avi_restart', limit=200000)
            self.assertEqual(m.get('_view_failed'), 0)
            # Последний media-блок может включать неиспользованный индекс,
            # но у этой фикстуры после кадров нет ни idx1, ни JUNK.
            self.assertEqual(m.media, data + bytes(-len(data) % 4))
            self.assertEqual(m.get('_avi_left', 4), 0)
            chip.wait_idle()
            expected = 40 + 99 * 30 % 200
            self.assertAlmostEqual(chip.frame().getpixel((512, 384))[0], expected, delta=8)
            self.assertFalse(chip.errors)

    def test_avi_extreme_aspect_draw(self):
        # Только раскладка: узкий/высокий кадр не должен дать нулевую ширину
        # или переполнение промежуточной высоты. Кадры здесь одноцветные.
        with FT812() as chip:
            chip.boot()
            for width,height in ((1,2047),(2047,1),(48,64)):
                m=Machine(chip=chip)
                m.set('_avi_width',width,2);m.set('_avi_height',height,2)
                m.set('_avi_total',10,4);m.set('_avi_frame',1,4)
                m.set('_avi_period',40000,4)
                chip.write(0,b'\x00\xF8'*(width*height))
                m.call('_avi_hud_init')  # размер и масштаб считаются раз на файл
                m.cpu.de=m.cpu.hl=0      # адрес кадра (u32 в HLDE, ABI 1)
                m.call('_avi_draw')
                self.assertEqual(m.get('_view_failed'),0)
                chip.wait_idle();frame=chip.frame()
                self.assertGreater(frame.getpixel((511,349))[0],200)
            self.assertFalse(chip.errors)

    def test_images_and_timing(self):
        timing=[0x30202C,0x302030,0x302034,0x302038,0x30203C,0x302040,
                0x302044,0x302048,0x30204C,0x302050,0x302070]
        with FT812() as chip:
            chip.boot();before=[chip.rd32(a) for a in timing]
            for fmt,size in [('JPEG',(64,48)),('JPEG',(1024,32)),('JPEG',(32,1024)),('PNG',(128,96))]:
                with self.subTest(fmt=fmt,size=size):
                    m=Machine(picture(fmt,size),chip=chip)
                    m.call('_show_jpg_png',bytes([fmt=='JPEG']))
                    self.assertEqual(m.get('_view_failed'),0)
                    chip.wait_idle();frame=chip.frame()
                    self.assertGreater(frame.getpixel((512,384))[0],150)
                    self.assertEqual([chip.rd32(a) for a in timing],before)
            self.assertFalse(chip.errors)

    def test_avi_bar_and_seek(self):
        for action in (None,'home','forward'):
            with self.subTest(action=action),FT812() as chip:
                chip.boot();m=ControlledMachine(avi(),chip=chip,action=action)
                m.call('_show_avi',limit=100000)
                self.assertEqual(m.get('_view_failed'),0)
                self.assertEqual(m.get('_avi_frame',4),5)
                if action:self.assertTrue(m.triggered)
                commands=[data for addr,data in m.writes if addr==0x302578]
                decoded=sum(data[:4]==struct.pack('<I',0xFFFFFF41) for data in commands)
                # home: 4 кадра до перехода, пятый уже декодирован наперёд
                # и отброшен перезапуском потока, затем 5 кадров заново.
                self.assertEqual(decoded,10 if action=='home' else 5)
                chip.wait_idle();frame=chip.frame()
                # Центр последнего кадра и заполненная полоса прогресса.
                red=frame.getpixel((512,350))[0]
                self.assertTrue(140<=red<=175,red)
                self.assertGreater(frame.getpixel((512,712))[0],200)
                frame.save(OUT/('avi-'+str(action)+'.png'))
                self.assertFalse(chip.errors)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--out',type=Path,default=OUT)
    args,rest=parser.parse_known_args()
    OUT=test_ftview.OUT=args.out
    unittest.main(argv=[sys.argv[0],*rest])
