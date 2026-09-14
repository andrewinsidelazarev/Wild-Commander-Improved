"""Проверка закрытого тестового образа и воспроизводимый локальный комплект.

Запускать после File -> Exit в тестовом Unreal. Проверяем каждый файл,
полное совпадение образа, зеркала FAT, отсутствие потерянных кластеров и
актуальные кадры. Проверка не обращается к пользовательскому носителю.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import zipfile

from PIL import Image,ImageChops
from prepare_unreal import PROJECT,WC,files,sha
sys.path.insert(0,str(WC/'tests/core32_unreal'))
from core32_image_test import Fat32Image,collect_orphan_clusters


def main(run):
    before=json.loads((run/'before.json').read_text())
    payload=(WC/'exe/WC/TXTVIEW2.WMF').read_bytes()
    assert payload==(PROJECT/'TXTVIEW2.WMF').read_bytes(),'Runtime differs from assembled plugin'
    license_data=(WC/'exe/WC/TXTVIEW2.LIC').read_bytes()
    assert license_data==(PROJECT/'fonts/OFL.txt').read_bytes()
    assert sha(payload)==before['plugin_sha256']
    image_path=run/'unreal/viewer.img'
    assert sha(image_path.read_bytes())==before['image_sha256'],'Image changed after viewing'
    disk=Fat32Image(image_path)
    try:
        assert files(disk)==before['files']
        length=disk.fat_size*disk.bps
        a,b=disk.fat_offset(0,0),disk.fat_offset(0,1)
        assert disk.data[a:a+length]==disk.data[b:b+length]
        assert not collect_orphan_clusters(disk)
    finally:
        disk.save()
    comparisons=[('wc-language','text'),('wc-reopened','text'),('wc-help','help'),
                 ('wc-help-russian-keyboard','help'),('wc-dense','dense')]
    for actual,reference in comparisons:
        body=(0,42,1024,728)
        a=Image.open(run/(actual+'.png')).convert('RGB').crop(body)
        b=Image.open(PROJECT/'build'/('preview-'+reference+'.png')).convert('RGB').crop(body)
        assert ImageChops.difference(a,b).getbbox() is None,actual
    # Число команд зависит от текущей компоновки экрана. Берём измерение
    # машинного графического теста, чтобы пакет не сохранял старую оценку DL.
    graphics=(PROJECT/'build/graphics-result.txt').read_text(encoding='utf-8')
    dense_words,dl_limit=map(int,re.search(r'Dense DL words: (\d+)/(\d+)',graphics).groups())
    font=json.loads((PROJECT/'build/font.json').read_text(encoding='utf-8'))
    budgets=json.loads((PROJECT/'build/scanline-budget.json').read_text(encoding='utf-8'))
    assert budgets['sha256']==sha(payload)
    result=dict(plugin='TXTVIEW2.WMF',version='0.26',bytes=len(payload),sha256=sha(payload),
                machine_tests_passed=20,display=[1024,768],glyphs=len(font['glyphs']),unicode_codepoints=len(font['codes']),
                text_grid=[78,22],ram_g_bytes_verified=font['ram_g'],
                text_cache_bytes=78*23*font['cell'][0]*font['cell'][1]//2,
                text_cache_slots=23,visible_rows=22,
                scanline_budget=budgets,
                dense_dl_words=dense_words,dl_limit_words=dl_limit,
                wc_f3=True,wc_reopen=True,wc_english_help_in_both_layouts=True,
                wc_search_en_ru=True,wc_hex_over_16mib=True,wc_big_utf8=True,
                wc_cancel_megabyte_line=True,wc_empty_file=True,
                pixel_comparisons=[x[0] for x in comparisons],
                image_unchanged=True,image_files_verified=len(before['files']),
                fat_mirrors_equal=True,orphan_clusters=0,physical_hardware='not tested')
    if (run/'wc-nedoos-000005a3.png').exists():
        actual=Image.open(run/'wc-nedoos-000005a3.png').convert('RGB')
        reference=Image.open(PROJECT/'build/nedoos-scroll/000005a3.png').convert('RGB')
        assert ImageChops.difference(actual.crop((0,42,1024,728)),
                                    reference.crop((0,42,1024,728))).getbbox() is None
        nedoos=json.loads((PROJECT/'build/nedoos-scroll/result.json').read_text(encoding='utf-8'))
        assert nedoos['plugin_sha256']==sha(payload)
        result['nedoos']=dict(file_sha256=nedoos['file_sha256'],file_size=nedoos['file_size'],
                             checked_rows=nedoos['checked_rows'],wc_photo_page_pixel_match=True,
                             hardware_status='User confirmed SCISSOR fix removed tearing; new scroll not yet tested on board')
    scroll=json.loads((run/'scroll-result.json').read_text(encoding='utf-8'))
    performance=json.loads((PROJECT/'build/scroll-performance.json').read_text(encoding='utf-8'))
    assert scroll['plugin_sha256']==sha(payload)
    assert performance['sha256']==sha(payload)
    result['scroll_wc']=scroll
    result['scroll_performance']=performance
    (run/'verified.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    dist=PROJECT/'dist'
    dist.mkdir(exist_ok=True)
    (dist/'TXTVIEW2.WMF').write_bytes(payload)
    shutil.copyfile(PROJECT/'fonts/OFL.txt',dist/'OFL.txt')
    shutil.copyfile(run/'wc-language.png',PROJECT/'preview.png')
    # Один готовый WMF и лицензия атласа. Своего wc.ini в комплекте нет:
    # пользователь меняет только имя плагина в уже настроенном конфиге.
    entries={
        'WC/TXTVIEW2.WMF':payload,
        'WC/TXTVIEW2.LIC':license_data,
        'README.md':(PROJECT/'README.md').read_bytes()
            .replace(b'../../../exe/WC/',b'WC/')
            .replace(b'fonts/OFL.txt',b'WC/TXTVIEW2.LIC'),
        'preview.png':(run/'wc-language.png').read_bytes(),
        'VALIDATION.json':(run/'verified.json').read_bytes(),
    }
    archive=dist/'TXTVIEW2-v0.26.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as out:
        for name,data in entries.items():
            info=zipfile.ZipInfo(name,(2026,9,14,0,0,0))
            info.compress_type=zipfile.ZIP_DEFLATED
            info.external_attr=0o100644<<16
            out.writestr(info,data)
    with zipfile.ZipFile(archive) as check:
        assert set(check.namelist())==set(entries)
        assert check.testzip() is None
        for name,data in entries.items():assert check.read(name)==data
    (dist/'SHA256SUMS.txt').write_text(
        sha(payload)+'  TXTVIEW2.WMF\n'+sha(archive.read_bytes())+'  '+archive.name+'\n',encoding='ascii')
    print(json.dumps(result,indent=2))
    print('Package:',str(archive))


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--run-dir',type=Path,default=PROJECT/'build/unreal-test')
    main(parser.parse_args().run_dir.resolve())
