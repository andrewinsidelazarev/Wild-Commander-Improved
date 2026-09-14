"""Стоимость настоящих Up/Down, включая чтение строки и передачу FT812.

Время WC/дискового API подменено стендом; такты Z80 и команды FIFO реальны.
В каждом шаге меняется позиция, поэтому замер не маскирует работу повтором
неизменённой страницы. --baseline сравнивает те же входные данные.
"""
import argparse
import hashlib
import json
import statistics
from pathlib import Path
from benchmark import Viewer, WMF, measure


def benchmark(nedoos):
    cases = {'nedoos': nedoos.read_bytes(),
             'utf8': ''.join(f'{i:04} Привет, Україна! Καλημέρα! ế о́\n' for i in range(200)).encode(),
             'hex': bytes(range(256))*40}
    result = dict(sha256=hashlib.sha256(WMF).hexdigest(),
                  unit='Z80 T-states; WC/disk API mocked; FT812 DLL', cases={})
    for name, content in cases.items():
        v = Viewer(content, chip=True)
        try:
            v.call('FT_Boot')
            v.call('FT_LoadAssets')
            v.put('FtReady', 1, 1)
            v.put('HexMode', int(name == 'hex'), 1)
            v.call('GoHome')
            v.call('DrawPage')
            row = {}
            for command in ('GoDown', 'GoUp'):
                ticks, copies = [], []
                for _ in range(12):
                    v.commands.clear()
                    ticks.append(measure(v, command))
                    copies.append(v.commands.count(b'\x1d\xff\xff\xff'))
                    assert not v.get('IoError', 1)
                    assert not v.get('FtFault', 1)
                row[command] = dict(median_ticks=int(statistics.median(ticks)),
                                    min_ticks=min(ticks), max_ticks=max(ticks),
                                    max_glyph_copies=max(copies))
            result['cases'][name] = row
        finally:
            v.close()
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('nedoos', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline', type=Path)
    args = parser.parse_args()
    result = benchmark(args.nedoos)
    if args.baseline:
        before = json.loads(args.baseline.read_text())
        result['baseline_sha256'] = before['sha256']
        for name, row in result['cases'].items():
            for cmd, values in row.items():
                values['speedup'] = round(before['cases'][name][cmd]['median_ticks']/values['median_ticks'], 2)
    args.output.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(result, indent=2), flush=True)
