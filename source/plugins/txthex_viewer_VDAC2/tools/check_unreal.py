"""Клавиатурная проверка настоящего WC в отдельном Unreal с VDAC2.

В RAM ничего не записываем: только запросы клавиш и снимков отладочного стенда.
Кадр берём из клиентской области окна эмулятора графического чипа.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import time

from PIL import Image,ImageChops
from capture_ft import capture

PROJECT=Path(__file__).resolve().parents[1]
SYMBOLS={n:int(v,16) for n,v in re.findall(r'^([^:]+):\s+EQU\s+(0x[0-9a-fA-F]+)$',
                                       (PROJECT/'build/TXTVIEW2.sym').read_text(),re.M)}
RUN=PROJECT/'build/unreal-test'
EMU=RUN/'unreal'
PAGE=None


def request(name,text):
    path=EMU/name
    assert not path.exists(),f'Pending {name}'
    tmp=path.with_suffix('.tmp')
    tmp.write_text(text,encoding='ascii')
    tmp.rename(path)
    limit=time.monotonic()+10
    while path.exists() and time.monotonic()<limit:
        time.sleep(.02)
    assert not path.exists(),f'Unreal did not consume {name}'


def dump(page):
    request('dump.req',f'{page:X}\n')
    time.sleep(.03)
    data=(EMU/'statedump.bin').read_bytes()
    assert len(data)==32768
    return data


def key(code,mods=0):
    request('vkey.req',f'{code} 4 {mods}\n')
    time.sleep(.22)
    with (RUN/'actions.log').open('a') as log:
        log.write(f'{code} mods={mods}\n')


def number(data,name,size=4):
    at=SYMBOLS[name]-0x8000
    return int.from_bytes(data[at:at+size],'little')


def names(screen):
    return [screen[row*256+46:row*256+89].split(b'\0')[0].strip().lower()
            for row in range(2,35)]


def wait_main(timeout=35):
    global PAGE
    limit=time.monotonic()+timeout
    while time.monotonic()<limit:
        dump(0)
        state=(EMU/'zstate.txt').read_text().splitlines()[0]
        if f'pc={SYMBOLS["MainLoop"]+1:04X}' in state:
            PAGE=int(re.search(r'pc_page=([0-9A-F]+)',state).group(1),16)
            return dump(PAGE)
        time.sleep(.08)
    raise AssertionError('Viewer not ready: '+state)


def open_file(name):
    limit=time.monotonic()+30
    needle=name.lower().encode()
    while needle not in names(dump(0)):
        assert time.monotonic()<limit,'WC panels not ready'
        time.sleep(.1)
    # После сортировки/перерисовки читаем фактический порядок ещё раз.
    key('0xC7')
    index=names(dump(0)).index(needle)
    for _ in range(index): key('DOWN')
    key('F3')
    data=wait_main()
    at=SYMBOLS['FileName']-0x8000
    assert data[at+1:at+257].split(b'\0')[0].lower()==needle
    assert number(data,'FtReady',1)==1
    assert number(data,'FtFault',1)==0
    return data


def screenshot(name,expected=None):
    dump(0)
    time.sleep(.2)
    frame=capture(int((EMU/'unreal.pid').read_text()))
    assert frame.size==(1024,768),frame.size
    frame.save(RUN/(name+'.png'))
    if expected:
        reference=Image.open(PROJECT/'build'/expected).convert('RGB')
        body=(0,SYMBOLS['HEADER_BOTTOM']+2,1024,SYMBOLS['FOOTER_TOP'])
        assert ImageChops.difference(frame.crop(body),reference.crop(body)).getbbox() is None, name


def probe():
    screen=dump(0)
    print((EMU/'zstate.txt').read_text().splitlines()[0],flush=True)
    print(names(screen),flush=True)


def smoke():
    data=open_file('LANGUAGE.TXT')
    assert number(data,'Encoding',1)==2
    screenshot('wc-language','preview-text.png')
    key('F1')
    time.sleep(.3)
    screenshot('wc-help','preview-help.png')
    key('SPACE')
    wait_main()
    key('0xD1')
    data=wait_main()
    # Все 22 строки языкового примера теперь помещаются на первой странице.
    # PgDn в EOF не должен открывать пустой экран; переход проверяем на DENSE.TXT.
    assert number(data,'Top')==0
    screenshot('wc-language-tail')
    key('0xC7')
    wait_main()
    for choice in (1,2,3,0):
        key('F8')
        data=wait_main()
        assert number(data,'Choice',1)==choice
    key('TAB')
    data=wait_main()
    assert number(data,'HexMode',1)==1
    screenshot('wc-hex')
    key('ESC')
    data=open_file('DENSE.TXT')
    screenshot('wc-dense','preview-dense.png')
    key('0xD1')
    data=wait_main()
    assert number(data,'Top')==78*22
    key('ESC')
    data=open_file('LANGUAGE.TXT')
    assert number(data,'Top')==0
    screenshot('wc-reopened','preview-text.png')
    key('ESC')
    print('VDAC2: F3, Unicode, F1, paging, F8, HEX, dense page and reopen PASS',flush=True)


def extended():
    data=open_file('SEARCH.TXT')
    for _ in range(3):
        key('F8')
        data=wait_main()
    assert number(data,'Encoding',1)==2
    key('0x21',1)                      # Ctrl+F
    time.sleep(.3)
    data=dump(PAGE)
    assert number(data,'Modal',1)==2
    at=SYMBOLS['InputBuffer']-0x8000
    key('0xC7')
    for _ in range(len(data[at:at+40].rstrip())):key('0xD3')
    # WC #4000..#7FFF постоянно в физической странице 5. Дамп — пара
    # физических страниц, а не линейное адресное пространство процессора.
    if dump(5)[0x381a]&1:key('0x2A',1)
    for code,mods in [('0x16',2),('0x31',0),('0x17',0),('0x2E',0),('0x18',0),('0x20',0),('0x12',0)]:
        key(code,mods)
    data=dump(PAGE)
    at=SYMBOLS['InputBuffer']-0x8000
    assert data[at:at+40].rstrip()==b'Unicode',data[at:at+40]
    screenshot('wc-find-input')
    key('ENTER')
    data=wait_main()
    assert number(data,'Top')==4118
    screenshot('wc-found')
    key('0x22',1)                      # Ctrl+G: в файле только одно вхождение
    data=wait_main()
    assert number(data,'SearchAgain',1)==2
    key('0xC7')
    wait_main()
    key('0x21',1)
    key('0xC7')
    for _ in range(7):key('0xD3')
    key('0x2A',1)                      # Ctrl+Shift: штатный переключатель WC
    assert dump(5)[0x381a]&1
    for code,mods in [('0x22',2),('0x23',0),('0x30',0),('0x20',0),('0x14',0),('0x31',0)]:
        key(code,mods)
    data=dump(PAGE)
    assert data[at:at+40].rstrip()=='Привет'.encode('cp866'),data[at:at+40]
    screenshot('wc-find-russian')
    key('ENTER')
    data=wait_main()
    assert number(data,'Top')==4105
    key('F1')
    screenshot('wc-help-russian-keyboard','preview-help.png')
    key('SPACE')
    wait_main()
    key('ESC')
    print('VDAC2: search EN/RU, English help in RUS and next/not-found PASS',flush=True)
    large()


def large(resume=False):
    data=wait_main(180) if resume else open_file('BIGBIN.BIN')
    assert number(data,'FileSize')==16*1024*1024+7
    assert number(data,'HexMode',1)==1
    if not resume:
        key('0xCF')
        # READ_AT обходит FAT-цепочку синхронно. На образе с кластерами по
        # одному сектору переход в конец 16 МиБ дольше обычной перерисовки.
        data=wait_main(180)
    assert number(data,'Top')==16*1024*1024
    screenshot('wc-big-hex-end')
    key('ESC')
    data=open_file('BIGUTF.TXT')
    assert number(data,'FileSize')>2_000_000
    assert number(data,'Encoding',1)==2
    key('0xCF')
    data=wait_main(120)
    assert number(data,'Top')>2_000_000
    assert number(data,'IoError',1)==0
    screenshot('wc-big-utf8-end')
    key('ESC')
    data=open_file('LONG.TXT')
    assert number(data,'FileSize')>=1024*1024
    key('0xCF')
    key('ESC')
    data=wait_main()
    assert number(data,'Top')==0
    assert number(data,'FtReady',1)==1
    key('ESC')
    data=open_file('EMPTY.TXT')
    assert number(data,'FileSize')==0
    assert number(data,'Top')==0
    screenshot('wc-empty')
    key('ESC')
    print('VDAC2: 16 MiB HEX, big UTF-8, Esc cancellation and empty file PASS',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=('probe','smoke','extended','large','open'))
    parser.add_argument('--run-dir',type=Path,default=RUN)
    parser.add_argument('--file',default='LANGUAGE.TXT')
    args=parser.parse_args()
    RUN=args.run_dir.resolve()
    EMU=RUN/'unreal'
    if args.action=='probe': probe()
    elif args.action=='open':
        print(number(open_file(args.file),'FileSize'),flush=True)
        screenshot('wc-open')
    elif args.action=='smoke': smoke()
    elif args.action=='extended': extended()
    else: large()
