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
    # Тихий сигнал (±8 около #80): эмулятор выводит звук в Windows, а
    # проверкам нужна лишь смена байтов.
    audio=bytes(0x78+(i//17*13)%16 for i in range(frames*rate//fps))
    avih=struct.pack('<14I',40000,100000,0,0,frames,0,2,0,width,height,0,0,0,0)
    vh=struct.pack('<4s4sIHHIIIIIIIIhhhh',b'vids',b'MJPG',0,0,0,0,1,fps,0,frames,0,0xFFFFFFFF,0,0,0,width,height)
    vf=struct.pack('<IiiHH4sIiiII',40,width,height,1,24,b'MJPG',width*height*3,0,0,0,0)
    ah=struct.pack('<4s4sIHHIIIIIIIIhhhh',b'auds',bytes(4),0,0,0,0,1,rate,0,len(audio),0,0xFFFFFFFF,1,0,0,0,0)
    af=struct.pack('<HHIIHH',tag,1,rate,rate,1,8)  # 1 — PCM
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
        # Поток ролика начинается заново (начало, перемотка) — новый отрезок звука.
        if name=='@GIPAG':self.runs.append({'audio':bytearray(),'drop':None})
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
    # until_paused: Esc только после паузы в конце ролика. Нажатие в сам
    # момент конца отменяет отрисовку последнего кадра (fifo_wait считает
    # ABT отменой), а проверке конца ролика нужна именно она.
    def __init__(self,*a,action=None,until_paused=False,**kw):
        super().__init__(*a,**kw)
        self.action,self.triggered,self.until_paused=action,False,until_paused

    def api(self):
        key=self.cpu.a
        if 0x10<=key<=0x1C:
            frame=self.get('_avi_frame',4)
            pressed=False
            if self.action=='home' and key==0x1B and frame==4 and not self.triggered:
                pressed=self.triggered=True
            if self.action=='forward' and key==0x14 and frame==1 and not self.triggered:
                pressed=self.triggered=True
            if frame==self.get('_avi_total',4) and frame and (
                    not self.until_paused or self.get('_avi_paused')):
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
    """Right на кадре press; Esc — в момент отрисовки кадра назначения."""
    def __init__(self, *a, press=4, **kw):
        super().__init__(*a, **kw)
        self.press, self.target, self.shown, self.expected = press, None, None, None
        self.watch = {self.s['_avi_draw']: self.on_draw}

    def api(self):
        key = self.cpu.a
        if 0x10 <= key <= 0x1C:
            frame = self.get('_avi_frame', 4)
            pressed = False
            if self.expected is None and key == 0x14 and frame >= self.press:
                pressed = True
                self.expected = min(self.get('_avi_total', 4) - 1,
                                    frame - 1 + 10000000 // self.get('_avi_period', 4))
            self.cpu.f = 0 if pressed else 0x40
            self.api_calls.append(key); self.ret()
        else:
            super().api()

    def on_draw(self):
        # Нажатие, пойманное во время декодирования, плеер обрабатывает после
        # показа кадра: цель тогда на кадр дальше ожидаемой. Берём его цель.
        if self.bank != 'video' or self.expected is None:
            return
        drawn, target = self.get('_avi_frame', 4) - 1, self.get('_avi_target', 4)
        if self.shown is None:
            if target >= self.expected and drawn == target:
                self.target = self.shown = target
                self.failed_before_esc = self.get('_view_failed')
        elif drawn > self.shown:
            # Esc (ABT) ставит ядро WC в любой момент: следующий кадр не
            # успевает смениться, на экране остаётся цель.
            self.cpu.memory[0x6004] = 1


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
            self.assertEqual(m.expected, 253)
            self.assertIn(m.target, (253, 254))
            self.assertTrue(m.gipags)
            self.assertGreater(m.get('_avi_seek_pos', 4), 0)
            # До цели декодировано лишь несколько кадров от точки входа.
            decoded = sum(d[:4] == struct.pack('<I', 0xFFFFFF41)
                          for a, d in m.writes if a == 0x302578)
            self.assertLess(decoded, 12)
            chip.wait_idle(); frame = chip.frame()
            want = colors(m.target)
            got = frame.getpixel((512, 350))
            for c in range(3):
                self.assertAlmostEqual(got[c], want[c], delta=10, msg=(got, want))
            self.assertFalse(chip.errors)

    def test_frame_bilinear_full_screen_with_panel(self):
        # Кадр 4:3 растягивается на весь экран с билинейной фильтрацией
        # (BITMAP_SIZE 1024×768 в показанном дисплей-листе), панель управления
        # — поверх низа кадра на тёмной полосе.
        with FT812() as chip:
            chip.boot()
            m = ControlledMachine(avi(), chip=chip)
            m.call('_show_avi', limit=100000)
            self.assertEqual(m.get('_view_failed'), 0)
            self.assertEqual(m.get('_avi_frame', 4), 5)
            chip.wait_idle(); frame = chip.frame()
            dl = struct.unpack('<2048I', chip.read(0x300000, 8192))
            sizes = [w for w in dl if w >> 24 == 0x08 and (w >> 9 & 511, w & 511) == (1024 & 511, 768 & 511)]
            self.assertEqual([w >> 20 & 1 for w in sizes], [1])
            self.assertAlmostEqual(frame.getpixel((512, 350))[0], 40 + 4 * 30 % 200, delta=10)
            self.assertAlmostEqual(frame.getpixel((512, 20))[0], 40 + 4 * 30 % 200, delta=10)
            self.assertLess(frame.getpixel((600, 765))[0], 40 + 4 * 30 % 200 - 40)
            self.assertFalse(chip.errors)

    def test_stream_stops_at_movi_end(self):
        # Хвост файла — готовая таблица перемотки и idx1 — не читается с SD и
        # не идёт в media FIFO: у длинного ролика он до мегабайта, и его
        # передача приходилась на последние 1–2 с. За последним чанком
        # сопроцессор получает страницу хвоста: пока он не дочитает свой запас,
        # последний кадр не заканчивается (в конце ролика — Reason 04).
        from avigen import make_avi, jpeg, embed_index, chunk
        data = embed_index(make_avi(60, audio=False, frame=jpeg)[0])
        at = data.index(b'movi') - 8
        movi_end = at + 8 + struct.unpack_from('<I', data, at + 4)[0]
        # Хвост длиннее подаваемой страницы: проверяем именно обрезание.
        data = bytearray(data + chunk(b'JUNK', bytes(8192)))
        data[4:8] = struct.pack('<I', len(data) - 8)
        data = bytes(data)
        self.assertGreater(len(data) - movi_end, 4096)
        with FT812() as chip:
            chip.boot()
            m = ControlledMachine(data, chip=chip)
            m.call('_show_avi', limit=400000)
            self.assertEqual(m.get('_view_failed'), 0)
            self.assertEqual(m.get('_avi_frame', 4), 60)
            tail = min(movi_end + 4096, len(data))
            # За концом movi в FIFO уходят нули: в хвосте есть последователь-
            # ности '00dc', и сопроцессор принимал их за ещё один кадр.
            self.assertEqual(bytes(m.media),
                             data[:movi_end] + bytes(tail - movi_end - tail % 4))
            self.assertLessEqual(max(p + c for p, c in m.reads), (tail + 511) // 512 * 512)
            chip.wait_idle(); frame = chip.frame()
            self.assertAlmostEqual(frame.getpixel((512, 350))[0], 40 + 59 * 30 % 200, delta=10)
            self.assertFalse(chip.errors)

    def test_header_promises_more_frames_than_movi(self):
        # Заголовок AVI часто обещает больше кадров, чем лежит в movi (чужие
        # файлы, оборванная запись). Плеер запрашивал у сопроцессора кадр,
        # которого нет: данных больше не было, VIDEOFRAME не заканчивался и в
        # самом конце ролика выпадало окно Reason 04. Теперь конец потока —
        # это конец ролика: число кадров исправляется по факту.
        from avigen import make_avi, jpeg
        frames = 20
        # Без idx1: за концом movi файл кончается, сопроцессору нечем закончить
        # несуществующий кадр — он и не отвечает, пока плеер его ждёт.
        data = bytearray(make_avi(frames, audio=False, frame=jpeg, index=False)[0])
        at = data.index(b'avih') + 8
        struct.pack_into('<I', data, at + 16, frames + 1)   # dwTotalFrames
        at = data.index(b'strh') + 8
        struct.pack_into('<I', data, at + 32, frames + 1)   # dwLength
        with FT812() as chip:
            chip.boot()
            m = ControlledMachine(bytes(data), chip=chip, until_paused=True)
            m.call('_show_avi', limit=400000)
            state = (m.get('_fail_at'), m.get('_avi_frame', 4), m.get('_avi_total', 4),
                     m.get('_avi_left', 4), m.get('_avi_end', 4), len(data))
            self.assertEqual(m.get('_view_failed'), 0, state)
            self.assertEqual(m.get('_avi_frame', 4), frames, state)
            self.assertEqual(m.get('_avi_total', 4), frames, state)
            # Плеер встал на паузу на последнем настоящем кадре, как в конце
            # обычного ролика: Space начнёт просмотр сначала.
            self.assertEqual(m.get('_avi_paused'), 1, state)
            chip.wait_idle()
            expected = 40 + (frames - 1) * 30 % 200
            self.assertAlmostEqual(chip.frame().getpixel((512, 350))[0], expected, delta=10)
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
            # Совпадения тестовой пилы делают поиск первого расхождения
            # ненадёжным; хвост после перемотки известен целиком.
            tail = list(pcm[pcm_sample(49):])
            k = len(left) - len(tail)
            self.assertEqual(left[k:], tail)
            self.assertEqual(left[:k], list(pcm[:k]))
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
            for action in (None,'home','forward','pause'):
                data,audio=pcm_avi()
                with self.subTest(action=action),FT812() as chip:
                    chip.boot();m=AudioMachine(data,chip=chip,action=action)
                    m.call('_show_avi',limit=500000)
                    self.assertEqual(m.get('_view_failed'),0,(action,m.get('_pcm_played',4),m.get('_pcm_written',4)))
                    self.assertEqual(m.get('_avi_pcm_rate',2),22050)
                    self.assertEqual(m.get('_pcm_underruns',2),0)
                    self.assertEqual(m.get('_avi_frame',4),80)
                    self.assertEqual(m.get('_pcm_live'),0)
                    if action:self.assertGreater(m.phase,0)
                    # PCM8 беззнаковый переводится в знаковый LINEAR.
                    for run in m.runs:
                        if run['drop'] is None:continue
                        drop=run['drop'];sent=bytes(run['audio'])
                        self.assertEqual(sent,bytes(x^128 for x in audio[drop:drop+len(sent)]))
                    self.assertIn((0x3020C4,0),m.regs)
                    # После выхода звук FT812 стоит. Запись в REG_PLAYBACK_PLAY
                    # запускает воспроизведение при любом значении: прежний
                    # «PLAY = 0» перезапускал кольцо с LOOP = 1, и последний
                    # фрагмент играл по кругу до сброса.
                    self.assertNotIn((0x3020CC,0),m.regs)
                    time.sleep(.2)
                    self.assertEqual(chip.rd8(0x3020CC)&1,0,action)
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
            # Ролик и его размер — как после avi_first (show_avi).
            m.set('_avi_cluster', m.chain[0], 4); m.set('_avi_size', len(data), 4)
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
                self.assertGreater(frame.getpixel((511,383))[0],200)
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

    def test_list_window_over_paused_frame(self):
        # Enter на третьем кадре: полупрозрачное окно списка поверх показанного
        # кадра, курсор на текущем ролике и за нажатиями вниз. Выбранный ролик
        # играет на настоящем декодере до конца.
        from avigen import jpeg
        from test_ftview import ListMachine, list_volume
        color = lambda n: (40 + n * 30 % 200, 40 + n * 7 % 150, 80)
        snaps = {}
        with FT812() as chip:
            chip.boot()

            class Snap(ListMachine):
                def api(self):
                    poll = self.polls + 1
                    if self.bank == 'list' and self.cpu.a == 0x11 and poll in (1, 3) and poll not in snaps:
                        chip.wait_idle(); snaps[poll] = chip.frame()
                    super().api()

            m = Snap(chip=chip, keys=[(0x16,), (), (0x12,), (), (0x12,), (), (0x16,)], enter_at=3)
            files = list_volume(m, frame=jpeg)
            beta, zeta = files[b'BETA    AVI'], files[b'ZETACL~1AVI']
            m.objects[0] = [o for o in m.objects if o[0][0] == beta[0]][0]
            m.set('_filesize', beta[1], 4)
            m.call('_show_avi', limit=400000)
            self.assertEqual(m.get('_view_failed'), 0)
            self.assertEqual(m.get('_avi_cluster', 4), zeta[0])
            self.assertEqual(m.get('_avi_frame', 4), 6)
            chip.wait_idle(); last = chip.frame()
            self.assertFalse(chip.errors)
        self.assertEqual(sorted(snaps), [1, 3])
        paused = color(2)
        for poll, row in ((1, 3), (3, 4)):
            shot = snaps[poll]
            shot.save(OUT / ('avi-list-%d.png' % poll))
            # Кадр виден вне окна, внутри — затемнён; полоса выбора — синяя
            # на строке курсора (ROWY 112, строка 32 точки).
            for c in range(3):
                self.assertAlmostEqual(shot.getpixel((40, 384))[c], paused[c], delta=12)
            self.assertLess(max(shot.getpixel((900, 650))), 40)
            y = 112 + row * 32 + 12
            bar = shot.getpixel((900, y))
            self.assertGreater(bar[2], 150, (poll, bar))
            self.assertLess(bar[0], 90, (poll, bar))
            self.assertLess(max(shot.getpixel((900, y + 32))), 60)
            # Заголовок — белый текст.
            title = [shot.getpixel((x, 84)) for x in range(120, 400)]
            self.assertTrue(any(min(p) > 200 for p in title))
        self.assertAlmostEqual(last.getpixel((512, 384))[0], color(5)[0], delta=12)

    def test_list_long_names_fit_window(self):
        # Длинные имена обрезаются по ширине строки окна с «...»: текст не
        # заходит за отступ 28 точек от правого края окна (x = 900), но
        # доходит почти до него. Снимок — obj/avi-list-long.png.
        from avigen import jpeg
        from test_ftview import ListMachine, long_volume, LONG_NAMES, SFN_ONLY, list_shown
        snaps = {}
        with FT812() as chip:
            chip.boot()

            class Snap(ListMachine):
                def api(self):
                    if self.bank == 'list' and self.cpu.a == 0x11 and self.polls + 1 == 1 and not snaps:
                        chip.wait_idle(); snaps[1] = chip.frame()
                    super().api()

            m = Snap(chip=chip, keys=[(0x16,), (), (0x17,)], enter_at=3)
            files = long_volume(m, frame=jpeg)
            m.call('_show_avi', limit=400000)
            self.assertEqual(m.get('_view_failed'), 0)
            self.assertFalse(chip.errors)
        shot = snaps[1]
        shot.save(OUT / 'avi-list-long.png')
        # Порядок строк — как у ключей сортировки: латиница заглавными,
        # кириллица после неё.
        latin = [list_shown(n) for n in LONG_NAMES if ord(n[0]) < 0x400] + ['BETA', *SFN_ONLY.values()]
        rows = sorted(latin, key=str.upper) + [list_shown(n) for n in LONG_NAMES if ord(n[0]) >= 0x400]
        for row, name in enumerate(rows):
            if name == 'BETA':
                continue
            y0 = 112 + row * 32
            band = [max(shot.getpixel((x, y))) for y in range(y0 + 4, y0 + 22) for x in range(903, 925)]
            self.assertLess(max(band), 120, (row, name))
            if name.endswith('...'):
                near = [max(shot.getpixel((x, y))) for y in range(y0 + 4, y0 + 22) for x in range(850, 900)]
                self.assertGreater(max(near), 180, (row, name))


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--out',type=Path,default=OUT)
    args,rest=parser.parse_known_args()
    OUT=test_ftview.OUT=args.out
    unittest.main(argv=[sys.argv[0],*rest])
