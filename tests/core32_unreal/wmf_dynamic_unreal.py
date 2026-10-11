"""Изолированный Unreal: WMF #11, 1001 ассоциация, запуск через клавиатуру.

python tests/core32_unreal/wmf_dynamic_unreal.py prepare --out Build/wmf-... --base Build/.../unreal
python tests/core32_unreal/wmf_dynamic_unreal.py run --out Build/wmf-...
Старт/закрытие окна — отдельно; RAM только читается через dump.req.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import wmf_metadata
from core32_image_test import Fat32Image, UPDATE

CASES = [(f'T{i:04}.E{i:04}', i % 256) for i in (0, 63, 69, 255, 256, 999)]
CASES += [('LONG.LoNgExTeNsIoN', 255)]


def fixture():
    header = bytearray(512)
    header[16:32] = b'WildCommanderMDL'
    header[32:38] = bytes((16, 0, 1, 0, 0, 1))
    header[64:67] = b'TST'
    header[161:165] = bytes([255]) * 4
    header[165:197] = b'Dynamic WMF test'.ljust(32, b' ')
    # Запомнить причину, A' и число запусков в собственной странице плагина.
    # Возврат без UI; дамп после нажатия клавиши доказывает настоящий вызов.
    code = bytes.fromhex('32 00 81 08 32 01 81 08 21 02 81 34 AF C9').ljust(512, b'\0')
    entries = [dict(extension=f'E{i:04}', handler=i % 256) for i in range(1000)]
    entries.append(dict(extension='LONGEXTENSION', handler=255))
    return wmf_metadata.rewrite(bytes(header) + code, entries)


def prepare(out, base, reclaim_filler=False):
    emu = out / 'unreal'
    if emu.exists():
        raise ValueError('use a fresh output directory; existing emulator is preserved')
    emu.mkdir(parents=True)
    for name in ('Unreal.exe', 'Unreal.ini', 'CMOS', 'NVRAM', 'boot.$b', 'bass.dll',
                 'bt8xxemu.dll', 'ft8xxemu.dll', 'libmpsse.dll', 'fix.img'):
        shutil.copy2(base / name, emu / name)
    shutil.copytree(base / 'rom', emu / 'rom')
    image = Fat32Image(emu / 'fix.img')
    if reclaim_filler:
        # Только новая копия стенда: прежние тесты заполняли весь том этим
        # файлом. Исходный образ base/fix.img никогда не открывается на запись.
        folder = image.find_entry(image.root_cluster, 'FILLER')
        if not folder or not folder['attr'] & UPDATE.ATTR_DIRECTORY:
            raise ValueError('fixture FILLER directory is absent')
        filler = image.find_entry(folder['cluster'], 'BIG.BIN')
        if not filler or filler['attr'] & UPDATE.ATTR_DIRECTORY:
            raise ValueError('fixture FILLER/BIG.BIN is absent')
        image.free_chain(filler['cluster'])
        image.mark_deleted(folder['cluster'], filler)
    wc = image.find_entry(image.root_cluster, 'WC')['cluster']
    manifest = {}
    for relative in ('boot.$C', 'WC/FILEX.WMF', 'WC/PLM.WMF', 'WC/TXTVIEW.WMF'):
        data = (ROOT / 'exe' / relative).read_bytes()
        parent = wc if relative.startswith('WC/') else image.root_cluster
        name = Path(relative).name
        UPDATE.write_file_any(image, parent, name, data)
        assert image.read_file(parent, name) == data
        manifest[relative] = hashlib.sha256(data).hexdigest()
    data = fixture()
    (out / 'DYNAMIC.WMF').write_bytes(data)
    UPDATE.write_file_any(image, wc, 'DYNAMIC.WMF', data)
    manifest['WC/DYNAMIC.WMF'] = hashlib.sha256(data).hexdigest()
    ini = image.read_file(wc, 'wc.ini').decode('cp866')
    ini = re.sub(r'\[PLUGINS\].*?(?=\[LPANEL\])',
                 '[PLUGINS]\rFILEX.WMF\rPLM.WMF\rDYNAMIC.WMF\rTXTVIEW.WMF\r\r', ini,
                 flags=re.S | re.I)
    for key, value in [('SavePaths', 0), ('SavePosition', 0), ('ScreenSaver', 0), ('CSORT', 1)]:
        ini = re.sub(r'(?i)\b' + key + r'=\d+', f'{key}={value}', ini)
    UPDATE.write_file_any(image, wc, 'wc.ini', ini.encode('cp866'))
    folder = UPDATE.ensure_dir(image, image.root_cluster, '000WMF')
    for name, _ in CASES:
        UPDATE.write_file_any(image, folder, name, b'WMF test\r\n')
    UPDATE.write_file_any(image, folder, 'OLD.TXT', b'Legacy viewer still works.\r\n')
    image.save()
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps(manifest, indent=2), flush=True)


class Probe:
    def __init__(self, out):
        self.out, self.emu, self.ui = out, out / 'unreal', self

    def request(self, name, text):
        target = self.emu / name
        assert not target.exists(), f'pending request: {name}'
        temp = target.with_suffix('.tmp')
        temp.write_text(text, encoding='ascii')
        temp.rename(target)
        deadline = time.monotonic() + 10
        while target.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        assert not target.exists(), f'Unreal did not consume {name}'

    def key(self, code):
        self.request('vkey.req', f'{code} 4 0\n')
        time.sleep(.22)
        with (self.out / 'ui-actions.log').open('a') as log:
            log.write(code + '\n')

    def dump(self, page):
        output, state = self.emu / 'statedump.bin', self.emu / 'zstate.txt'
        for old in (output, state):
            old.unlink(missing_ok=True)
        self.request('dump.req', f'{page:X}\n')
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            time.sleep(.03)
            try:
                data, text = output.read_bytes(), state.read_text()
            except (FileNotFoundError, PermissionError):
                continue
            if len(data) == 32768 and 'pc_hist=' in text and text.endswith('\n'):
                return data
        raise AssertionError('Incomplete Unreal dump')

    def ready(self):
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            self.dump(5)
            state = (self.emu / 'zstate.txt').read_text().splitlines()[0]
            if 'pc=604A pc_page=05 sp=5FFE' in state:
                return
            time.sleep(.15)
        raise AssertionError('WC did not return to main loop: ' + state)

    def screen_text(self):
        page = self.dump(0)
        return [page[r*256:r*256+90].replace(b'\0', b' ').decode('cp866').rstrip()
                for r in range(36)]

    def pool_state(self):
        vars_page = self.dump(5)
        end = int.from_bytes(vars_page[0x3F18:0x3F1A], 'little') or 0x10000
        page = self.dump(0x60)
        return dict(table=[dict(index=i, base=page[i*512],
                                name=page[i*512+165:i*512+197].decode('cp866').rstrip())
                           for i in range((end - 0xC000) // 512)])


def select(probe, name, key='ENTER'):
    probe.ui.key('0xC7')  # Home
    text = probe.screen_text()
    rows = [i for i, row in enumerate(text) if name.casefold() in row.casefold()]
    if not rows:
        raise AssertionError(f'{name!r} missing from panel:\n' + '\n'.join(text))
    row = rows[0]
    assert 2 <= row < 34, (row, name)
    for _ in range(row - 2):
        probe.ui.key('DOWN')
    probe.ui.key(key)
    time.sleep(.4)


def run(out):
    p = Probe(out)
    p.ready()
    state = p.pool_state()
    dynamic = next(h for h in state['table'] if h['name'] == 'Dynamic WMF test')
    assert dynamic['base'] == 255, state  # регистрация без загрузки кода
    table = p.dump(0x60)
    start = dynamic['index'] * 512
    record = table[start:start+512]
    assert record[32] == 17 and int.from_bytes(record[50:52], 'little') == 1001
    ptr = int.from_bytes(record[52:54], 'little') - 0xC000
    length = int.from_bytes(record[48:50], 'little')
    metadata_before = p.dump(0xE9)[ptr:ptr+length]
    assert metadata_before == fixture()[512:512+length]
    select(p, '000WMF')
    p.ready()
    results = []
    for number, (name, handler) in enumerate(CASES, 1):
        key = 'ENTER' if number % 2 else 'F3'
        select(p, name, key)
        p.ready()
        state = p.pool_state()
        dynamic = next(h for h in state['table'] if h['name'] == 'Dynamic WMF test')
        assert dynamic['base'] != 255, (name, state)
        code = p.dump(0x61 + dynamic['base'])
        got = list(code[0x100:0x103])
        assert got == [0, handler, number], (name, got, handler, number)
        results.append(dict(file=name, key=key, handler=got[1], calls=got[2]))
        print(results[-1], flush=True)
    assert p.dump(0xE9)[ptr:ptr+length] == metadata_before
    select(p, 'OLD.TXT', 'F3')
    time.sleep(.7)
    legacy = '\n'.join(p.screen_text())
    assert 'Legacy viewer still works.' in legacy, legacy
    p.ui.key('ESC')
    p.ready()
    (out / 'unreal-results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
    (out / 'final-screen.txt').write_text('\n'.join(p.screen_text()), encoding='utf-8')
    (out / 'legacy-screen.txt').write_text(legacy, encoding='utf-8')
    print('Unreal: 7 extension launches + legacy viewer OK', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'run'])
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--base', type=Path)
    parser.add_argument('--reclaim-filler', action='store_true')
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.out.resolve(), args.base.resolve(), args.reclaim_filler)
    else:
        run(args.out.resolve())
