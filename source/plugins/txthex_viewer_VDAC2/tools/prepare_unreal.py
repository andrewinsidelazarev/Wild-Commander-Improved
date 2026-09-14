"""Изолированный WC с TXTVIEW2 первым просмотрщиком по F3 и VDAC2=1.

Копируем известный исправный стенд, рабочий образ пользователя не меняем.
Образ и подготовленные файлы проверяем побайтно до запуска Unreal.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys

PROJECT = Path(__file__).resolve().parents[1]
WC = PROJECT.parents[2]
BASE = WC/'Build/txtview-rename-20260914'
sys.path.insert(0,str(WC/'tests/core32_unreal'))
sys.path.insert(0,str(PROJECT/'tests'))
from core32_image_test import Fat32Image, UPDATE
from test_viewer import SAMPLE


def sha(data):
    return hashlib.sha256(data).hexdigest()


def files(disk):
    wc=disk.find_entry(disk.root_cluster,'WC')['cluster']
    return {f'{directory}/{entry["name"]}':sha(disk.read_file(directory,entry['name']))
            for directory in (disk.root_cluster,wc) for entry in disk.parse_dir(directory)
            if not entry['attr'] & 0x18 and entry['name'] not in ('.','..')}


def prepare(run, extra_file=None):
    assert not run.exists(), f'Refusing to overwrite existing run: {run}'
    run.mkdir(parents=True)
    emu=run/'unreal'
    emu.mkdir()
    for name in ('Unreal.exe','Unreal.ini','CMOS','NVRAM','bpx.ini','boot.$b',
                 'bass.dll','bt8xxemu.dll','ft8xxemu.dll','libmpsse.dll',
                 'codex_wc_real.ps1','viewer.img'):
        shutil.copy2(BASE/'unreal'/name,emu/name)
    shutil.copytree(BASE/'unreal/rom',emu/'rom')
    ini=(emu/'Unreal.ini').read_bytes()
    assert ini.count(b'TS_VDAC2=0')==1
    (emu/'Unreal.ini').write_bytes(ini.replace(b'TS_VDAC2=0',b'TS_VDAC2=1'))
    shutil.copy2(BASE/'keys.ps1',run/'keys.ps1')
    payload=(WC/'exe/WC/TXTVIEW2.WMF').read_bytes()
    disk=Fat32Image(emu/'viewer.img')
    try:
        wc=disk.find_entry(disk.root_cluster,'WC')['cluster']
        ini=disk.read_file(wc,'wc.ini')
        assert ini.count(b'\rTXTVIEW.WMF\r')==1
        UPDATE.write_file_any(disk,wc,'wc.ini',ini.replace(b'\rTXTVIEW.WMF\r',b'\rTXTVIEW2.WMF\r'))
        UPDATE.write_file_any(disk,wc,'TXTVIEW2.WMF',payload)
        UPDATE.write_file_any(disk,wc,'TXTVIEW2.LIC',(WC/'exe/WC/TXTVIEW2.LIC').read_bytes())
        UPDATE.write_file_any(disk,disk.root_cluster,'LANGUAGE.TXT',SAMPLE.encode('utf-8'))
        UPDATE.write_file_any(disk,disk.root_cluster,'DENSE.TXT',b'W'*78*40)
        UPDATE.write_file_any(disk,disk.root_cluster,'SEARCH.TXT',
                              ('first line\n'+'x'*4094+'Привет Unicode!\n').encode('utf-8'))
        if extra_file:
            UPDATE.write_file_any(disk,disk.root_cluster,'NEDOOS.TXT',extra_file.read_bytes())
        assert disk.read_file(wc,'TXTVIEW2.WMF')==payload
        manifest=dict(plugin_sha256=sha(payload),files=files(disk))
    finally:
        disk.save()
    manifest['image_sha256']=sha((emu/'viewer.img').read_bytes())
    (run/'before.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print(str(run),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--run-dir',type=Path,default=PROJECT/'build/unreal-test')
    parser.add_argument('--extra-file',type=Path)
    args=parser.parse_args()
    prepare(args.run_dir.resolve(),args.extra_file)
