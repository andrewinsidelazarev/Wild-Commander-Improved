"""Детерминированные таблицы кодировок и экранных строк TXTVIEW.WMF."""
from __future__ import annotations

import argparse
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "source/plugins/txthex_viewer/TABLES.INC"


def generate() -> str:
    lines = [
        "; Создано tools/make_txthex_tables.py; редактировать генератор.",
        "; Комментарии — UTF-8, байты экранных строк — CP866.",
        "; Таблицы соответствия получены из стандартных кодеков Python.",
    ]

    def data(label: str, values: list[int], word: bool = False) -> None:
        lines.append(label + ":")
        for start in range(0, len(values), 16):
            fmt = "#%04X" if word else "#%02X"
            lines.append("        " + ("DW " if word else "DB ") +
                         ",".join(fmt % n for n in values[start:start + 16]))

    def decode(byte: int, codec: str) -> str:
        return bytes([byte]).decode(codec, errors="replace")

    def encode(char: str, codec: str) -> int:
        return char.encode(codec, errors="replace")[0]

    def normalize(char: str) -> int:
        char = char.lower().replace("ё", "е")
        return ord(char) - ord("а") if "а" <= char <= "я" else 255

    data("Unicode866", [ord(decode(n, "cp866")) for n in range(128, 256)], True)
    data("WindowsTo866", [encode(decode(n, "cp1251"), "cp866") for n in range(128, 256)])
    data("DosToWindows", [encode(decode(n, "cp866"), "cp1251") for n in range(128, 256)])
    for name, codec in (("Letters866", "cp866"), ("Letters1251", "cp1251")):
        data(name, [normalize(decode(n, codec)) for n in range(128, 256)])
    # Набор частых русских сочетаний; это эвристика распознавания текста,
    # а не обещание однозначно различить любые последовательности байтов.
    pairs = """ст но то на ен ов ни ра во ко ро по пр ос го ал от ре ол ан
        не ли та ер ор ва ел ит ет ны ка ти те од ед ил ар ло за ле ве ри ла
        ес ое ьн да ок ме ма до об ря ьс ес ин ис де тв ак ем ьк зы чи ыл
        ыв сл уч ам ав ой им ом ог со тр мо ус ый ые ым их ть ся ец це чн
        ье ие ия ий ми из ди бл ыб аб ыт же жу жи ша ши ще щи ат аз ай кл
        лу че ту тс ач вы гр ру уп пы яв ча ят яд ры се ку св дн сч зн сп
        пл кр др бр вр ск зд жд ща хр бо бу ду зу су юд юс яч ящ ёт""".split()
    masks = [0] * 128
    for pair in pairs:
        first, second = map(normalize, pair)
        masks[first * 4 + second // 8] |= 1 << (second % 8)
    data("CommonBigrams", masks)

    def screen(label: str, text: str, size: int | None = None) -> None:
        lines.append("; " + text.replace("\r", " / "))
        raw = text.encode("cp866")
        if size is not None:
            assert len(raw) <= size, (label, len(raw), size)
            raw = raw.ljust(size, b" ")
        else:
            raw += b"\0"
        data(label, list(raw))

    screen("LabelAutoEnglish", "Auto:", 5)
    screen("LabelManualEnglish", "Man.:", 5)
    screen("FooterEnglish", "F8:Enc Tab:Mode F1:Help", 32)
    screen("IoEnglish", "READ ERR", 9)
    screen("BusyEnglish", "READING..", 9)
    screen("NotFoundEnglish", "NOT FOUND", 9)
    screen("TitleEnglish", "Text & HEX Viewer")
    screen("TitleRussian", "Просмотр текста и HEX")
    screen("CloseEnglish", "Press any key to close")
    screen("CloseRussian", "Нажмите любую клавишу")
    screen("MenuEnglish", "Select a file in a panel and press F3.\r"
           "Use Shift+F3 to choose this viewer explicitly.")
    screen("MenuRussian", "Выберите файл в панели и нажмите F3.\r"
           "Через Shift+F3 можно выбрать этот просмотрщик явно.")
    screen("ErrorEnglish", "Cannot open or read the selected file.\r"
           "Check the file and the storage device.")
    screen("ErrorRussian", "Не удалось открыть или прочитать выбранный файл.\r"
           "Проверьте файл и доступность носителя.")
    screen("SearchEnglish", "Find text")
    screen("SearchRussian", "Найти текст")
    screen("HelpEnglish", "Up/Down - one screen row; PgUp/PgDn - one page\r"
           "Home/End - start/end of file; Esc/Space - exit\r"
           "Tab - switch Text/HEX; both modes start at the beginning\r"
           "F8 - Auto -> CP866 -> CP1251 -> UTF-8 -> Auto\r"
           "F8 restarts at the beginning; the file is never changed\r"
           "Auto/Man. and the active encoding appear in the footer\r"
           "Ctrl+F - find text; Ctrl+G - find next (case sensitive)\r"
           "Esc cancels a long search or backward scan\r"
           "Long lines wrap; tabs use eight-column stops\r"
           "CR, LF, CRLF are supported; NUL does not end the file\r"
           "UTF-8 BOM is hidden; unavailable glyphs appear as '?'\r"
           "Single-byte detection is heuristic; use F8 if needed\r"
           "Offsets and file size are hexadecimal, up to FFFFFFFF\r"
           "FILEX.WMF speeds up seeking; no full-file load is needed")
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = generate()
    if args.check:
        if OUTPUT.read_text(encoding="utf-8") != expected:
            raise SystemExit("TABLES.INC устарел: запустите tools/make_txthex_tables.py")
        print("TXT/HEX tables: OK")
    else:
        OUTPUT.write_text(expected, encoding="utf-8", newline="\n")
        print(OUTPUT)


if __name__ == "__main__":
    main()
