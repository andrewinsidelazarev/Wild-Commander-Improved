"""Локальная сборка FTView. SDCC 4.3, стековый ABI SDK, контроль границ WMF."""
from pathlib import Path
import argparse
import ctypes
import hashlib
import json
import os
import re
import shutil
import subprocess

from intelhex import IntelHex

ROOT = Path(__file__).resolve().parent


def compiler_path(path):
    """SDCC/ASlink не понимают кириллицу: передаём существующий короткий путь."""
    path = str(Path(path).resolve())
    if os.name == 'nt':
        buf = ctypes.create_unicode_buffer(32768)
        if not ctypes.windll.kernel32.GetShortPathNameW(path, buf, len(buf)):
            raise OSError('Cannot obtain short path: ' + path)
        path = buf.value
    if not path.isascii():
        raise RuntimeError('Build path needs an ASCII alias: ' + path)
    return path


def build(out):
    out.mkdir(parents=True, exist_ok=True)
    manifest=json.loads((ROOT/'vendor/manifest.json').read_text(encoding='utf-8'))
    for name, expected in manifest['files'].items():
        assert hashlib.sha256((ROOT/'vendor'/name).read_bytes()).hexdigest()==expected, name
    compiler = shutil.which('sdcc')
    assembler = shutil.which('sdasz80')
    if not compiler or not assembler:
        raise RuntimeError('SDCC and sdasz80 must be in PATH')
    log = []

    def run(args):
        p = subprocess.run(args, cwd=compiler_path(out), capture_output=True)
        log.append(p.stdout + p.stderr)
        (out/'build.log').write_bytes(b''.join(log))
        if p.returncode:
            raise RuntimeError(p.stdout.decode(errors='replace') + p.stderr.decode(errors='replace'))

    # SDK использует ABI 0, стандартная библиотека SDCC 4.3 — ABI 1.
    # Глобальный --sdcccall 0 ломает memcmp и 32-битное умножение! Сохраняем
    # современный ABI для C/stdlib, а старый явно закрепляем за функциями SDK.
    # Производные заголовки живут только в каталоге сборки; vendor неизменен.
    abi = out/'sdk_abi'; abi.mkdir(exist_ok=True)
    # Отметка сборки — четыре знака хеша исходников плагина. Видна в окне
    # «About» и в окне ошибки: по ней сразу понятно, какая версия стоит у
    # пользователя, и не приходится гадать по времени файла.
    digest = hashlib.sha256()
    for f in sorted((ROOT/'src').iterdir()):
        if f.is_file():
            digest.update(f.name.encode() + f.read_bytes())
    build_id = digest.hexdigest()[:4]
    (abi/'build_id.h').write_text(
        '// Сгенерировано build.py: отметка сборки плагина.\n'
        '#define BUILD_ID "%s"\n' % build_id, encoding='utf-8')
    for part,name in (('ft812','ft812lib.h'),('tsconf','tslib.h'),('sdk','sdklib.h')):
        source = (ROOT/'vendor'/part/name).read_text()
        source = re.sub(r'^(?!typedef)([^\n;{}]+\([^\n;{}]*\))\s*;',
                        r'\1 __sdcccall(0);',source,flags=re.M)
        (abi/name).write_text(source, encoding='utf-8')
    # В исходном SDK весь ESP32 включается одним C-файлом. SDCC сохраняет
    # даже неиспользуемые функции этого translation unit. Отбираем замыкание
    # прямых вызовов esp_* для XM/XMZ; исходник vendor остаётся неизменным.
    # В этом SDK нет косвенных вызовов esp_* или таблиц указателей функций.
    esp = (ROOT/'vendor/esp32/esp32.c').read_text()
    functions = {}
    for match in re.finditer(r'^(?:void|u8|u32|int) (esp_\w+)\([^\n]*\)\s*\{', esp, re.M):
        end, depth = match.end(), 1
        while depth:
            depth += (esp[end] == '{') - (esp[end] == '}')
            end += 1
        functions[match[1]] = (match.start(), end)
    used = set(re.findall(r'\besp_\w+(?=\s*\()', (ROOT/'src/main.c').read_text(encoding='utf-8'))) & functions.keys()
    while True:
        expanded = used | {n for name in used for n in
                          re.findall(r'\besp_\w+(?=\s*\()', esp[slice(*functions[name])])
                          if n in functions}
        if expanded == used:
            break
        used = expanded
    for name, (start, end) in sorted(functions.items(), key=lambda item: item[1][0], reverse=True):
        if name not in used:
            esp = esp[:start] + esp[end:]
    (abi/'esp32.c').write_text(esp, encoding='utf-8')
    common = ['-mz80', '--std-sdcc11', '--sdcccall', '1', '--opt-code-size', '--no-std-crt0']
    inc = ['-I'+compiler_path(abi), '-I'+compiler_path(ROOT/'src')]
    inc += ['-I'+compiler_path(ROOT/'vendor'/part) for part in ('sdk','tsconf','ft812','esp32')]
    libs = [compiler_path(ROOT/'vendor'/part/name) for part,name in
            (('ft812','ft812.lib'),('tsconf','ts.lib'),('sdk','sdk.lib'))]
    run([assembler, '-o', 'crt0.rel', compiler_path(ROOT/'src/crt0.s')])
    # Драйвер исполняется процессором General Sound с адреса #5000, поэтому
    # собирается отдельно и попадает в банк изображений массивом байтов.
    (out/'gs').mkdir(exist_ok=True)
    run([assembler, '-plosgffw', 'gs/gsdrv.rel', compiler_path(ROOT/'src/gsdrv.s')])
    run([shutil.which('sdldz80') or 'sdldz80', '-n', '-m', '-w', '-i', 'gs/gsdrv.ihx', 'gs/gsdrv.rel'])
    gh = IntelHex(str(out/'gs/gsdrv.ihx'))
    gs_org = gh.minaddr()
    gs_code = bytes(gh.tobinarray(start=gs_org, end=gh.maxaddr()))
    gs_map = (out/'gs/gsdrv.map').read_text()
    gs_version = int(re.search(r'^VERSION\s*=\s*(\d+)', (ROOT/'src/gsdrv.s').read_text(encoding='utf-8'), re.M)[1])
    # Код GS не должен попасть в окно ЦАП #6000..#7FFF, в память ПЗУ GS и в
    # таблицу IM2 #5C00..#5D00 (стек — под #5E00). Обработчик стоит ровно по
    # адресу из таблицы (#5050), инициализация перед ним не должна его налезть.
    gs_sym = {n: int(a, 16) for a, n in re.findall(r'^\s+([0-9A-F]{8})\s+(\w+)', gs_map, re.M)}
    assert gs_org == 0x5000 and gs_org + len(gs_code) <= 0x5C00, (hex(gs_org), len(gs_code))
    assert gs_sym['gs_isr'] == 0x5050 and gs_sym['gs_init_end'] <= 0x5050, gs_sym
    (abi/'gsdrv.h').write_text(
        '// Сгенерировано build.py из src/gsdrv.s: код драйвера General Sound.\n'
        '#define GS_DRIVER_ORG 0x%04X\n#define GS_DRIVER_VERSION %d\n'
        'static const u8 gs_driver[%d] = {\n%s\n};\n' % (
            gs_org, gs_version, len(gs_code),
            ',\n'.join(', '.join('0x%02X' % b for b in gs_code[i:i+16]) for i in range(0, len(gs_code), 16))),
        # build.ps1 требует UTF-8 от всех текстов под source/, и от этого тоже.
        encoding='utf-8')
    banks = {}
    payloads = []
    # Банк списка роликов (страница 10) — окно выбора по Enter в плеере.
    for bank, number in (('image', 0), ('video', 9), ('list', 10)):
        (out/bank).mkdir(exist_ok=True)
        prefix = bank + '/'
        define = {9: ['-DFTVIEW_VIDEO_BANK'], 10: ['-DFTVIEW_LIST_BANK']}.get(number, [])
        run([compiler, *common, *inc, *define, '-c', compiler_path(ROOT/'src/main.c'),
             '-o', prefix+'main.rel'])
        link = [compiler, *common, '--code-loc', '0x8006', '--data-loc', '0xBD00',
                'crt0.rel', prefix+'main.rel', *libs, '-o', prefix+'ftview.hex']
        run(link)

        def areas():
            return {name: (int(addr,16),int(size,16)) for name,addr,size in re.findall(
                r'^(_\w+)\s+([0-9A-F]{8})\s+([0-9A-F]{8})\s+=',
                (out/bank/'ftview.map').read_text(), re.M)}

        # _HOME должен находиться за CODE именно этого банка. DATA и общий
        # кадр не выпускаются в файл: инициализация выполняется при входе.
        code_end = sum(areas()['_CODE'])
        run(link + ['-Wl-b_HOME=0x%04X' % code_end])
        layout = areas()
        symbols = {n:int(a,16) for a,n in re.findall(r'^\s+([0-9A-F]{8})\s+(_\w+)\s+',
                   (out/bank/'ftview.map').read_text(),re.M)}
        for name, addr in {'_fs_buf':0xC000, '_ret_sp':0xBFE0, '_ret_ix':0xBFE2,
                           '_ret_iy':0xBFE4, '_filesize':0xBFE6, '_file_ext':0xBFEA,
                           '_call_type':0xBFEB, '_gs_loaded':0xBFEC, '_ft_state':0xBFED,
                           '_wc_video_bank':0xBF80, **({'_hud_cmd':0xBB80} if number == 9 else {})}.items():
            assert symbols[name] == addr, (bank,name,symbols[name])
        for name,(addr,size) in layout.items():
            if not size:
                continue
            if name in ('_CODE','_HOME'):
                # Видеобанк держит шаблон HUD AVI в #BB80..#BCFF (hud_cmd).
                limit = 0xBB80 if number == 9 else 0xBD00
                assert 0x8006 <= addr and addr+size <= limit, (bank,name,addr,size)
            elif name == '_DATA':
                assert addr == 0xBD00 and addr+size <= 0xBF80, (bank,name,addr,size)
            elif name.startswith('_DABS'):
                # SDCC создаёт отдельные ABS-области для __at. Их конкретные
                # адреса проверены по символам выше; HEX не должен содержать
                # ни их инициализаторов, ни байтов, заходящих в DATA.
                pass
            elif name == '_HEADER0':
                assert size == 6
            elif name.startswith('_BANKSWITCH'):
                assert size == 69
            else:
                raise AssertionError(('Unexpected nonempty section',bank,name,addr,size))
        ih = IntelHex(str(out/bank/'ftview.hex'))
        assert ih.minaddr() == 0x8000 and ih.maxaddr() == 0xBFC4
        assert all(a < 0xBD00 or 0xBF80 <= a <= 0xBFC5 for a in ih.addresses())
        # WMF читает полезную нагрузку секторными блоками в порядке таблицы.
        # Полная страница содержит также закреплённый шлюз около её конца.
        ih.padding = 0  # детерминированное начальное состояние DATA в каждом банке
        payload = bytes(ih.tobinarray(start=0x8000,end=0xBFFF))
        (out/bank/'payload.bin').write_bytes(payload)
        payloads.append(payload)
        banks[bank] = dict(page=number, bytes=len(payload), areas=layout,
                          sha256=hashlib.sha256(payload).hexdigest(),
                          map_sha256=hashlib.sha256((out/bank/'ftview.map').read_bytes()).hexdigest())
    # До CALL API 79 шлюзы должны совпадать побайтно. После переключения
    # исполняется JP main_dispatch, связанный уже с адресами видеобанка.
    # far_call целиком одинаков: переключение идёт посреди его кода.
    for other in payloads[1:]:
        assert payloads[0][0x3F80:0x3FA5] == other[0x3F80:0x3FA5]
        assert payloads[0][0x3FA7:0x3FC5] == other[0x3FA7:0x3FC5]
        # Вход #8003 ведёт в far_entry своего банка.
        assert payloads[0][3] == other[3] == 0xC3
    run([compiler,*common,*inc,'-DN_BLK0=32','-DN_BLK9=32','-DN_BLK10=32',
         compiler_path(ROOT/'src/wc_h.c'),'-o','header.hex'])
    hh = IntelHex(str(out/'header.hex'))
    header = bytes(hh.tobinarray(start=hh.minaddr(),end=hh.maxaddr()))
    assert len(header) == 512 and header[34] == 11
    assert header[36:44] == bytes([0,32,9,32,10,32,1,0])
    binary = header+b''.join(payloads)
    (out/'FTVIEW.WMF').write_bytes(binary)
    shutil.copyfile(out/'video/ftview.map',out/'ftview.map')
    gs_symbols = {n: int(a, 16) for a, n in re.findall(r'^\s+([0-9A-F]{8})\s+(\w+)\s', gs_map, re.M)}
    report = dict(build_id=build_id, banks=banks, map_sha256=hashlib.sha256((out/'ftview.map').read_bytes()).hexdigest(), bytes=len(binary),sha256=hashlib.sha256(binary).hexdigest(),areas=banks['video']['areas'],
                  gs=dict(org=gs_org, bytes=len(gs_code), version=gs_version,
                          sha256=hashlib.sha256(gs_code).hexdigest(),
                          symbols={n: a for n, a in gs_symbols.items() if n.startswith('gs_')}),
                  sdcc=subprocess.check_output([compiler,'--version']).decode().splitlines()[0])
    (out/'build.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=ROOT/'obj')
    build(parser.parse_args().out.resolve())
