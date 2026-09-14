"""Точный пример пользователя: CP866 nedoos.txt, фото со смещением 05A3.

Разбор всего файла сравнивается с независимым разбиением CRLF/переносов.
На странице фотографии сверяются все байты кэша RAM_G и сохраняются DL
и кадр официальной DLL. Результат не является приёмкой физической платы.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

PROJECT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(PROJECT/'tests'))
from harness import Viewer,FONT,WMF
from scanline_budget import display_words,profile


def reference(data, start=0):
    at=start
    while at<len(data):
        begin=at
        row=bytearray()
        while len(row)<78 and at<len(data):
            value=data[at]
            at+=1
            if value in (10,13):
                if value==13 and data[at:at+1]==b'\n': at+=1
                break
            if value==9:
                row.extend(b' '*min(8-len(row)%8,78-len(row)))
            else:
                row.append(value)
        else:
            if data[at:at+2]==b'\r\n': at+=2
            elif data[at:at+1] in (b'\r',b'\n'): at+=1
        yield begin,at,row.decode('cp866').rstrip()


def main(path,output):
    data=path.read_bytes()
    output.mkdir(parents=True,exist_ok=True)
    checked=0
    v=Viewer(data)
    assert v.get('Encoding',1)==0
    v.call('GoHome')
    v.put('Position',0)
    for begin,end,text in reference(data):
        assert v.get('Position')==begin
        v.call('TextRow')
        assert v.get('Position')==end,(begin,end,v.get('Position'))
        assert v.line()==text,(begin,v.line(),text)
        checked+=1
    v.close()
    v=Viewer(data,chip=True)
    try:
        v.call('FT_Boot')
        v.call('FT_LoadAssets')
        v.put('FtReady',1,1)
        reports={}
        for top in (0,0x5a3,len(data)//2):
            v.put('Top',top)
            lines=v.draw()
            want=[r[2] for r in reference(data,top)][:22]
            want+=['']*(22-len(want))
            assert lines==want
            v.call('MapGrid')
            atlas=(PROJECT/'build/font.l4').read_bytes()
            cell=FONT['cell'][0]*FONT['cell'][1]//2
            ids=v.ids(0x2000,count=78*22)
            expected=b''.join(atlas[i*cell:(i+1)*cell] for i in ids)
            assert v.chip.read(len(atlas),len(expected))==expected
            words=display_words(v)
            name=f'{top:08x}'
            v.chip.frame().save(output/(name+'.png'))
            (output/(name+'.dl')).write_bytes(struct.pack('<'+'I'*len(words),*words))
            reports[name]=dict(lines=lines,profile=profile(words),cache_bytes_verified=len(expected))
        assert not v.chip.errors,v.chip.errors
    finally:
        v.close()
    result=dict(file_sha256=hashlib.sha256(data).hexdigest(),file_size=len(data),
                plugin_sha256=hashlib.sha256(WMF).hexdigest(),checked_rows=checked,
                cases=reports,physical_hardware='not verified by this test')
    (output/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('Rows:',checked,'; page/cache/DLL: PASS; output:',output)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('file',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    main(args.file,args.output)
