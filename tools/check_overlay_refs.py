# Claude - 2026-10-10 - begin
"""Ссылки загрузочной части расширения на оверлей FILEX (по листингу сборки).

Оверлей (CORE32_EXT.ASM, от OVERLAY_START до OVERLAY_END) появляется в #E8
только после ранней установки FILEX.WMF; до неё на его месте HALT. Код вне
оверлея — загрузочная часть страницы #E8 и резидентные блоки — не должен
ссылаться на метки оверлея: такой путь при старте (монтирование, поиск wc.ini,
загрузка плагинов) остановил бы машину. Единственное исключение — строки
таблицы входов шлюза (ENTRY_TABLE): номера функций оверлея зовут только после
старта, их список печатается для сверки.

    python check_overlay_refs.py Build/CORE32_EXT.lst

Код выхода 1 — найдены ссылки вне таблицы.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

LINE = re.compile(r'^[ \d]{4}[+\- ] [0-9A-F]{4}')       # номер строки и адрес
SOURCE_COLUMN = 24                                          # исходник — с 25-й колонки
LABEL = re.compile(r'^([A-Za-z_][\w]*|\.[\w]+):?(?=\s|$|:)')
TOKEN = re.compile(r'(?<![\w@.])(\.?[A-Za-z_][\w]*(?:\.[\w]+)?)')
SKIP = {'A', 'B', 'C', 'D', 'E', 'H', 'L', 'I', 'R', 'AF', 'BC', 'DE', 'HL', 'IX', 'IY', 'SP',
        'NZ', 'Z', 'NC', 'PO', 'PE', 'P', 'M', 'IXH', 'IXL', 'IYH', 'IYL'}


def code_part(source: str) -> str:
    out, quote = [], None
    for ch in source:
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in '"\'':
            quote = ch
            continue
        if ch == ';':
            break
        out.append(ch)
    return ''.join(out)


def main(path: Path) -> int:
    rows = []
    for raw in path.read_text(encoding='utf-8', errors='replace').splitlines():
        if LINE.match(raw) and len(raw) > SOURCE_COLUMN:
            if raw[11:12] == '~':                           # ветка IF не взята
                continue
            source = raw[SOURCE_COLUMN:]
            if source.startswith('>'):                      # повтор DUP
                source = ' ' + source[1:]
            rows.append(source)
    # Секция оверлея и её метки.
    start = next(i for i, s in enumerate(rows) if s.startswith('OVERLAY_START:'))
    end = next(i for i, s in enumerate(rows) if s.startswith('OVERLAY_END:'))
    overlay, glob = set(), None
    for s in rows[start:end]:
        m = LABEL.match(s)
        if m:
            name = m.group(1)
            if name.startswith('.'):
                overlay.add(f'{glob}{name}')
            else:
                glob = name
                overlay.add(name)
    overlay.discard('OVERLAY_START')
    # Ссылки вне оверлея.
    found, table, glob, in_table = [], [], None, False
    for index, s in enumerate(rows):
        if start <= index < end:
            continue
        m = LABEL.match(s)
        if m and not m.group(1).startswith('.'):
            glob = m.group(1)
            in_table = glob == 'ENTRY_TABLE'
            if glob == 'ENTRY_TABLE_END':
                in_table = False
        code = code_part(LABEL.sub('', s, count=1) if m else s).strip()
        if not code or code.split()[0].upper() in ('ASSERT', 'IF', 'IFDEF', 'IFNDEF', 'DS', 'EQU'):
            continue
        if ' EQU ' in f' {code.upper()} ':
            continue
        for token in TOKEN.findall(code):
            name = f'{glob}{token}' if token.startswith('.') else token
            if name.upper() in SKIP or name not in overlay:
                continue
            (table if in_table else found).append((glob, code, name))
    for glob, code, name in table:
        print(f'table  {code:40} -> {name}')
    for glob, code, name in found:
        print(f'BOOT   {glob}: {code:40} -> {name}')
    print(f'overlay labels {len(overlay)}, table entries {len(table)}, boot references {len(found)}')
    return 1 if found else 0


if __name__ == '__main__':
    raise SystemExit(main(Path(sys.argv[1])))
# Claude - 2026-10-10 - end
