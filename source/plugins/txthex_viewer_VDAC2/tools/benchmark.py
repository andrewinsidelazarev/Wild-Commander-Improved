"""Замеры тактов настоящего Z80 до/после оптимизации просмотрщика.

Чтение диска и диспетчер WC подменяются тестовым API, FT812 — официальной DLL.
Это стоимость кода плагина в стенде, а не время SD-карты на реальной плате.
Раздельно измеряем разбор страницы и построение/передачу её дисплей-листа.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import sys

PROJECT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(PROJECT/'tests'))
from harness import Viewer,WMF
from test_viewer import SAMPLE


def measure(viewer,symbol):
    original=viewer.m.run
    ticks=0

    def counted():
        nonlocal ticks
        # В установленном модуле getter ticks_to_stop имеет опечатку.
        # Считываем тот же четырёхбайтовый счётчик, что и машинные регрессии WC.
        before=int.from_bytes(viewer.m._StateBase__ticks_to_stop,'little')
        result=original()
        ticks+=before-int.from_bytes(viewer.m._StateBase__ticks_to_stop,'little')
        return result

    viewer.m.run=counted
    try:
        viewer.call(symbol)
    finally:
        viewer.m.run=original
    return ticks


def benchmark():
    russian='Съешь ещё этих мягких французских булок. Привет, мир!\n'*22
    cases={
        'ascii':('The quick brown fox jumps over the lazy dog. 0123456789\n'*22).encode(),
        'cp866':russian.encode('cp866'),
        'cp1251':russian.encode('cp1251'),
        'utf8_cyrillic':russian.encode(),
        'utf8_languages':SAMPLE.encode(),
        'dense_ascii':b'W'*78*22,
        'hex':bytes(range(256))*2,
    }
    rows={}
    for name,content in cases.items():
        v=Viewer(content,chip=True,detect=False)
        try:
            v.call('FT_Boot')
            v.call('FT_LoadAssets')
            detection=measure(v,'DetectEncoding')
            v.put('HexMode',int(name=='hex'),1)
            parse,draw=[],[]
            for _ in range(3):
                v.call('GoHome')
                v.put('FtReady',0,1)
                parse.append(measure(v,'DrawPage'))
                v.put('FtReady',1,1)
                draw.append(measure(v,'PresentScreen'))
            assert not v.chip.errors,v.chip.errors
            p,d=map(lambda values:int(statistics.median(values)),(parse,draw))
            rows[name]=dict(bytes=len(content),encoding=v.get('Encoding',1),
                            detect_ticks=detection,parse_ticks=p,draw_ticks=d,page_ticks=p+d,
                            first_draw_ticks=draw[0],first_page_ticks=p+draw[0])
        finally:
            v.close()
    return dict(sha256=hashlib.sha256(WMF).hexdigest(),
                unit='Z80 T-states; WC/disk API mocked; FT812 emulator',
                note='draw/page median redraw the same grid; first_draw/page include initial RAM_G cache fill',
                cases=rows)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--baseline',type=Path)
    args=parser.parse_args()
    result=benchmark()
    if args.baseline:
        before=json.loads(args.baseline.read_text(encoding='utf-8'))
        result['baseline_sha256']=before['sha256']
        for name,row in result['cases'].items():
            row['page_speedup']=round(before['cases'][name]['page_ticks']/row['page_ticks'],3)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,indent=2),flush=True)
