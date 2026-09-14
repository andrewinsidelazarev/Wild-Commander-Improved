"""Открыть пример пользователя в WC и сравнить страницу фотографии с DLL."""
import argparse
import hashlib
import json
from pathlib import Path
import time
import check_unreal as wc


def main(run):
    wc.RUN=run.resolve()
    wc.EMU=wc.RUN/'unreal'
    data=wc.open_file('NEDOOS.TXT')
    assert wc.number(data,'FileSize')==0x7b8a
    assert wc.number(data,'Encoding',1)==0
    status_at=wc.SYMBOLS['PercentField']-0x8000
    assert data[status_at:status_at+4]==b'  0%'
    wc.key('0xD1')
    wc.wait_main()
    for _ in range(4):
        wc.key('DOWN')
        wc.wait_main()
    data=wc.wait_main()
    assert wc.number(data,'Top')==0x5a3
    wc.screenshot('wc-nedoos-000005a3','nedoos-scroll/000005a3.png')
    # Удержание обрабатывается обычным MainLoop: между шагами прокрутки
    # стенд не ждёт готовности и не подправляет RAM. Проходим оборот кольца.
    wc.key('0xC7')
    wc.wait_main()
    for _ in range(3):
        wc.request('vkey.req','DOWN 180 0\n')
        time.sleep(4.0)
    data=wc.wait_main()
    down_top=wc.number(data,'Top')
    assert down_top>0x5a3,hex(down_top)
    assert wc.number(data,'IoError',1)==0
    assert wc.number(data,'FtFault',1)==0
    assert int(data[status_at:status_at+3])==down_top*100//0x7b8a
    wc.screenshot('wc-nedoos-held-down')
    for _ in range(4):
        wc.request('vkey.req','UP 180 0\n')
        time.sleep(4.0)
    data=wc.wait_main()
    assert wc.number(data,'Top')==0
    assert data[status_at:status_at+4]==b'  0%'
    wc.screenshot('wc-nedoos-held-up','nedoos-scroll/00000000.png')
    wc.key('0xCF')
    data=wc.wait_main()
    assert data[status_at:status_at+4]==b'100%'
    wc.screenshot('wc-nedoos-end')
    wc.key('0xC7')
    wc.wait_main()
    for _ in range(19):
        wc.key('0xD1')
        wc.wait_main()
    data=wc.wait_main()
    assert wc.number(data,'Top')>0x3000
    assert wc.number(data,'IoError',1)==0
    assert wc.number(data,'FtFault',1)==0
    wc.screenshot('wc-nedoos-middle')
    wc.key('ESC')
    result=dict(plugin_sha256=hashlib.sha256((wc.PROJECT/'TXTVIEW2.WMF').read_bytes()).hexdigest(),
                held_down_top=down_top,held_up_top=0,percent_start=0,percent_end=100,
                photo_page_pixel_match=True,held_up_pixel_match=True)
    (wc.RUN/'scroll-result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print('WC: NEDOOS.TXT, 05A3 pixel match, held Down/Up, 0%/100%, 19 pages PASS',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--run-dir',type=Path,required=True)
    main(parser.parse_args().run_dir)
