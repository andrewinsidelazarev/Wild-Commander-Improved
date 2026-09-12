"""Регрессии полного аудита TXTEDIT: настоящий Z80-код, модели API WC.

Ошибки файловой системы внедряются в API; это не проверка физической SD.
UI и интеграция отдельно проверяются в изолированном патченном Unreal.
"""
from __future__ import annotations
import argparse
import json
import random
import re
import time
from pathlib import Path
import test_txtedit_safety as safety
from test_txtedit_editing import Editor, TEXT_SIZE, PAGE_SIZE

class FeatureEditor(Editor):
    def __init__(self, *args, **kwargs):
        self.ui = []
        self.highlight_option = 3
        self.files = None
        self.read_data = None
        self.read_pos = 0
        self.read_calls = []
        self.invalid_maps = []
        self.short_write = False
        super().__init__(*args, **kwargs)

    def api(self):
        m = self.machine
        api = m.a
        if api in (0, 65, 80):
            # Deep save/restore calls need more stack than the EOF harness.
            # Keep the AF exchange stub and its temporary stack well away
            # from the real editor invocation stack at 0x7e00.
            self.memory[0x7000:0x7002] = b'\x08\xc9'
            saved_pc, saved_sp = m.pc, m.sp
            m.sp = 0x7100
            safety.put16(self.memory, m.sp, 0x7f00)
            m.pc = 0x7000
            for _ in range(3):
                m.ticks_to_stop = 1000
                m.run()
                if m.pc == 0x7f00:
                    break
            else:
                raise AssertionError('AF exchange failed')
            argument = m.a
            m.pc, m.sp = saved_pc, saved_sp
            if argument >= 64:
                # MD20.ASM API 65/80: CP #40; RET NC. The window is left
                # mapped to its previous page; the editor ignores this refusal.
                self.invalid_maps.append((api, argument, safety.get16(self.memory, m.sp)))
                m.a, m.f = argument, 0x02 | (0x40 if argument == 64 else 0) | (0x80 if argument >= 192 else 0)
                return
            self.map(0 if api == 80 else 0xc000,
                     ('plugin' if api == 0 else 'text', argument))
            m.a, m.f = 0, 0x40
            return
        if api == 5:
            self.map(0xc000, ('screen', 0))
            m.hl = 0xc000 + m.d * 256 + m.e
            m.a, m.f = 0, 0x40
            return
        if api == 83:
            m.a, m.f = self.highlight_option, 0 if self.highlight_option else 0x40
            return
        if api == 15:
            # Real GEDPL writes palette tables into the CURRENT #0000 bank.
            # Omitting this side effect hid corruption found in full Unreal.
            self.memory[0x1000:0x1020] = bytes(range(32))
            self.memory[0x11e0:0x1200] = bytes(range(32))
            self.memory[0x1200:0x1400] = bytes(512)
            self.memory[0x1440:0x1448] = bytes(8)
            self.map(0xc000, ('text', 0))
            m.a, m.f = 0, 0x40
            return
        if api == 3:
            self.ui.append(('print', m.de, bytes(self.memory[m.hl:m.hl + m.bc]).hex()))
        elif api == 10:
            # Status offsets are irrelevant to these probes. Preserve their
            # two-character output pointer advancement, as real NORK does.
            m.hl = (m.hl + 2) & 0xffff
        elif api in (1, 2, 9, 11, 46, 47):
            self.ui.append(('ui', api, m.ix, m.hl))
        elif api == 48 and self.read_data is not None:
            requested = m.b * 512
            data = self.read_data[self.read_pos:self.read_pos + requested]
            self.memory[m.hl:m.hl + len(data)] = data
            self.read_calls.append(len(data))
            m.hl = (m.hl + len(data)) & 0xffff
            self.read_pos += len(data)
            m.a = 0x0f if self.read_pos >= len(self.read_data) else 0
            m.f = 0
            return
        elif self.files is not None and api in (49, 59, 72, 74, 75):
            if api == 49 and self.short_write:
                m.hl = (m.hl + 512) & 0xffff
                m.a, m.f = 0x0f, 0
                self.files.calls.append(('short_write', m.b, 1))
                return
            return self.files.handle(self)
        else:
            raise AssertionError(f'Unexpected API {api}, return {safety.get16(self.memory, m.sp):04x}')
        m.a, m.f = 0, 0x40

    def select(self, start, end):
        assert self.pointer('LHLCR') == end
        self.set_pointer('BHLBLK', start)
        self.set_pointer('EHLBLK', end)
        self.memory[self.symbols['MARKED']] = 1

    def clipboard(self, data):
        self.flush()
        self.banks[('plugin', 1)][:len(data)] = data
        safety.put16(self.memory, self.symbols['CLIPSZ'], len(data))
        # Synchronise windows after external fixture changes.
        self.flush()

    def pattern(self, data):
        self.memory[self.symbols['STRBUFF']:self.symbols['STRBUFF'] + 40] = data.ljust(40, b' ')


def run_plain(h, label, *, de=0, hl=0, stop=None):
    m = h.machine
    m.sp = safety.STACK_BASE
    safety.put16(h.memory, m.sp, safety.RETURN_SENTINEL)
    m.pc = h.symbols[label]
    m.de, m.hl = de, hl
    if stop:
        m.set_breakpoint(h.symbols[stop])
    for _ in range(2000):
        m.ticks_to_stop = 100_000
        event = m.run()
        if event & safety.BREAKPOINT_HIT:
            if m.pc == safety.RETURN_SENTINEL or (stop and m.pc == h.symbols[stop]):
                return
            raise AssertionError(f'unexpected PC {m.pc:04x}, API {m.a}')
    raise AssertionError(f'{label} budget exceeded, PC {m.pc:04x}')


def calculate(expression, *, through_input=False, h=None):
    h = h or safety.MachineHarness()
    data = expression.encode('ascii')
    assert len(data) <= 40
    if through_input:
        start = h.symbols['CALCBUF']
        h.memory[start:start + 40] = data.ljust(40, b' ')
        run_plain(h, 'CALC_BUF_CONV', hl=start, de=h.symbols['BUF3'])
    else:
        start = h.symbols['BUF3']
        h.memory[start:start + len(data) + 1] = data + b'\0'
    converted = safety.c_string(h.memory, h.symbols['BUF3'])
    h.machine.bc = 0
    run_plain(h, 'DECODER', de=h.symbols['BUF3'])
    return dict(expression=expression, converted=converted, result=h.machine.bc,
                a=h.machine.a, carry=bool(h.machine.f & 1), zero=bool(h.machine.f & 0x40))


def value(e, name):
    start = e.symbols[name]
    return int.from_bytes(e.memory[start:start + 3], 'little')


def test_search():
    rng = random.Random(20260912)
    samples = [(b'aab', b'ab'), (b'aaab', b'aab'), (b'ababac', b'abac'),
               (b'xx\0abc', b'abc'), (b'abc', b'a'), (b'x' * 16383 + b'ab', b'ab')]
    for _ in range(100):
        samples.append((bytes(rng.choice(b'abc') for _ in range(90)),
                        bytes(rng.choice(b'abc') for _ in range(rng.randrange(1, 8)))))
    for data, pattern in samples:
        e = FeatureEditor(data, 0)
        e.pattern(pattern)
        e.invoke('STRBULL')
        assert not e.machine.f & 0x40, pattern
        e.invoke('GOSRH', de=len(pattern) - 1)
        found = data.find(pattern)
        safety.expect('search result', bool(e.machine.f & 1), found >= 0)
        if found >= 0:
            safety.expect('search cursor', e.pointer('LHLCR'), found + len(pattern))
        safety.expect('search preserves bytes', e.text(), data)
        assert not e.invalid_maps
    for length, cursor in [(0, 0), (3, 0), (3, 3), (0x80000, 0),
                           (0x90000, 0), (0x90000, 0x4001), (TEXT_SIZE - 2, 12345)]:
        data = bytes(65 + i // PAGE_SIZE % 24 if i % 80 != 79 else 13 for i in range(length))
        e = FeatureEditor(data, cursor, view_start=cursor - cursor % 80)
        e.pattern(b'ZZ')
        e.invoke('SEARCHNEXT')
        safety.expect('failed search preserves text', e.text(), data)
        safety.expect('failed search restores cursor', e.pointer('LHLCR'), cursor)
        safety.expect('failed search clean flag', e.memory[e.symbols['CHANGES']], 0)
        assert not e.invalid_maps, e.invalid_maps
    e = FeatureEditor(b'x' * 70000 + b'needle\rnext', 0)
    e.pattern(b'needle')
    e.invoke('SEARCHNEXT')
    safety.expect('full search long-line cursor', e.pointer('LHLCR'), 70006)
    safety.expect('full search column', value(e, 'CURCOL'), 70006)


def test_clipboard():
    for op, replacement in [('SMBADD', b'Z'), ('GO0D', b'\r'), ('ADDTAB', b'\t'),
                             ('PASTE', b'XY'), ('DELETE', b''), ('BSPACE', b''), ('CUT', b'')]:
        e = FeatureEditor(b'abcdef', 4)
        e.select(1, 4)
        e.clipboard(b'XY')
        e.invoke(op, a=ord('Z'))
        safety.expect('selection ' + op, e.text(), b'a' + replacement + b'ef')
    for start, count in [(0, 16383), (0, 16384), (3, 16384), (16383, 16384), (0, 16385)]:
        data = (b'ab\r' * ((start + count) // 3 + 1))[:start + count]
        e = FeatureEditor(data, len(data), view_start=max(0, len(data) - 20))
        e.select(start, start + count)
        e.clipboard(b'OLD')
        e.invoke('COPYX')
        expected = b'OLD' if count > PAGE_SIZE else data[start:]
        safety.expect('copy length', safety.get16(e.memory, e.symbols['CLIPSZ']), len(expected))
        safety.expect('copy contents', bytes(e.banks['plugin', 1][:len(expected)]), expected)
        if count <= PAGE_SIZE:
            e.invoke('PASTE')
            safety.expect('paste full clipboard', e.text(), data)
        assert not e.invalid_maps
    length = TEXT_SIZE - 4
    data = b'p\r' * ((length - 4) // 2) + b'ABCD'
    for selected in (False, True):
        e = FeatureEditor(data, length, view_start=length - 4)
        if selected:
            e.select(length - 2, length)
        e.clipboard(b'12345678')
        e.invoke('PASTE')
        safety.expect('failed paste atomicity', e.text(), data)
        safety.expect('failed paste selection', e.memory[e.symbols['MARKED']], int(selected))
        safety.expect('failed paste changed flag', e.memory[e.symbols['CHANGES']], 0)
        assert e.ui, 'capacity error must be visible'
        e.clipboard(b'12' if not selected else b'1234')
        e.invoke('PASTE')
        safety.expect('exact available space', e.text(), data + b'12' if not selected else data[:-2] + b'1234')


def test_io_and_status():
    for length in (589824, TEXT_SIZE - 2):
        data = bytes(65 + i // PAGE_SIZE % 24 if i % 80 != 79 else 13 for i in range(length))
        e = FeatureEditor(b'', 0)
        e.read_data = data.ljust((length + 511) // 512 * 512, b'?')
        e.memory[0x5800:0x5808] = b'big.txt\0'
        e.machine.bc = 0x5800
        e.invoke('PLUGIN', hl=length & 65535, de=length >> 16, stop='MAIN')
        safety.expect('startup palette must precede load', e.text(), data)
        assert not e.invalid_maps
    for declared, physical, success in [(1000, 512, False), (1000, 1024, True),
                                        (512, 512, True), (16385, 16384, False),
                                        (16385, 16896, True)]:
        e = FeatureEditor(b'', 0)
        e.read_data = b'Q' * physical
        address = e.symbols['DAHL']
        e.memory[address:address + 4] = declared.to_bytes(4, 'little')
        e.invoke('LOAD')
        safety.expect('read completeness', bool(e.machine.f & 0x40), success)
        if success:
            safety.expect('read bytes', e.text(), b'Q' * declared)
        assert not e.invalid_maps
    for short in (False, True):
        e = FeatureEditor(b'Q' * 999, 999)
        e.files = safety.SaveScenario()
        e.short_write = short
        e.memory[e.symbols['ENTRYN']:e.symbols['ENTRYN'] + 7] = b'wc.ini\0'
        e.invoke('SMBADD', a=ord('Q'))
        e.invoke('OFFSETS_PRINT')
        safety.expect('dirty star', e.memory[e.symbols['TAPTCHA']], ord('*'))
        e.invoke('QSAVE')
        e.invoke('OFFSETS_PRINT')
        safety.expect('save failure flag', bool(e.memory[e.symbols['SVERFLG']]), short)
        safety.expect('save dirty flag', e.memory[e.symbols['CHANGES']], int(short))
        safety.expect('save star', e.memory[e.symbols['TAPTCHA']], ord('*' if short else ' '))
        safety.expect('save text preserved', e.text(), b'Q' * 1000)
        if short:
            assert e.files.files == {'wc.ini': 'old'}, e.files.files
            assert not any(call[0] == 74 for call in e.files.calls), e.files.calls
    for length, cursor in [(0, 0), (16385, 16383), (524287, 262144),
                           (TEXT_SIZE - 2, 0), (TEXT_SIZE - 2, TEXT_SIZE - 3)]:
        data = bytes(65 + i % 26 if i % 60 != 59 else 13 for i in range(length))
        e = FeatureEditor(data, cursor, view_start=cursor - cursor % 60)
        e.invoke('PRTOSV')
        size = e.machine.de * 65536 + e.machine.hl
        safety.expect('normalized size', size, length)
        normalized = b''.join(bytes(e.banks['text', p]) for p in range(64))[:size]
        safety.expect('normalized data', normalized, data)
        e.invoke('TOWORK')
        safety.expect('restored gap', e.text(), data)
        assert not e.invalid_maps


def test_calculator():
    h = safety.MachineHarness()
    cases = {'0': 0, '65535': 65535, '#abcd': 43981, '%1011': 11,
             '1+2*3': 7, '(1+2)*3': 9, '100/4/5': 5, '7\\3': 1,
             '32768/129': 254, '32768/255': 128, '-1': 65535,
             '[#ABCD': 171, ']#ABCD': 205, ' 1 + 2 ': 3, '1 / 2': 0,
             '" "': 32, '"A "': 0x4120, '"AB"': 0x4142, '1--2': 3,
             '65535+1': 0, '1-2-3': 65532, '((((1))))': 1}
    for expression, expected in cases.items():
        result = calculate(expression, through_input=True, h=h)
        assert not result['carry'] and result['zero'], result
        safety.expect(expression, result['result'], expected)
    for expression in ['', '1+', '1**2', '()', '(1', '1)', '2(3)', 'foo', '1/0',
                       '7\\0', '#', '%', '%102', '#10000', '65536', '""', '"ABC"', '"A']:
        result = calculate(expression, through_input=True, h=h)
        assert result['carry'] and not result['zero'], result
        safety.expect('calculator stack restored', h.machine.sp, safety.STACK_BASE + 2)
    rng = random.Random(20260912)
    for _ in range(1200):
        left, right = rng.randrange(65536), rng.randrange(1, 65536)
        op = rng.choice('+-*/\\')
        expected = {'+': left + right, '-': left - right, '*': left * right,
                    '/': left // right, '\\': left % right}[op] & 65535
        result = calculate(f'#{left:X}{op}#{right:X}', h=h)
        assert not result['carry'] and result['zero'], result
        safety.expect(str(result), result['result'], expected)
    e = FeatureEditor(b'', 0)
    for expression, error in [('1/0', b'Error: division by zero'), ('1+', b'Error: invalid syntax'), ('2+3', b'')]:
        address = e.symbols['CALCBUF']
        e.memory[address:address + 40] = expression.encode().ljust(40, b' ')
        e.invoke('INSPCALC', stop='INSPMAIN')
        start = e.symbols['CALSTATUS']
        safety.expect('Inspector error field', bytes(e.memory[start:start + 24]).rstrip(), error)


def test_highlight():
    for initial, option, name, expected in [(False, 3, 'test.asm', 1), (False, 3, 'test.ASM', 1),
                                          (True, 3, 'test.txt', 0), (True, 2, 'test.asm', 0),
                                          (False, 1, 'test.txt', 1)]:
        e = FeatureEditor(b'abc', 0, initial)
        e.highlight_option = option
        address = e.symbols['ENTRYN']
        e.memory[address:address + len(name) + 1] = name.encode() + b'\0'
        e.invoke('NAMETOH')
        safety.expect('highlight mode', e.memory[e.symbols['HIGHLGT']], expected)
    for data in (b'abc\r123', b' \r123', b'abc\r\r123', b'abc\r\n123'):
        e = FeatureEditor(data, 0, True)
        row = len(re.split(b'\r\n|\r|\n', data))
        attrs = bytes(e.banks['screen', 0][row * 256 + 128:row * 256 + 131])
        safety.expect('number at line start', attrs, b'\x0f' * 3)
    data = b';' + b'x' * 200
    e = FeatureEditor(data, len(data), True)
    safety.expect('hidden semicolon context', e.banks['screen', 0][256 + 128], 4)
    e = FeatureEditor(b'a\tb', 2)
    e.select(1, 2)
    e.memory[e.symbols['REFFLG']] = 1
    e.invoke('REFRESH')
    attrs = bytes(e.banks['screen', 0][385:392])
    safety.expect('whole Tab selection', attrs, b'\x57' * 7)


def test_lines_and_navigation():
    for eol in (b'\r', b'\n', b'\r\n'):
        data = b'ab' + eol + b'c\td' + eol + b'ef'
        e = FeatureEditor(data, 0)
        safety.expect('EOL render', [e.row(i) for i in range(4)], [b'ab', b'c       d', b'ef', b''])
        for _ in range(3):
            e.invoke('GORG')
        safety.expect('Right across EOL', e.pointer('LHLCR'), 2 + len(eol))
        e.invoke('GOLF')
        safety.expect('Left across EOL', e.pointer('LHLCR'), 2)
        e.invoke('DELETE')
        safety.expect('Delete whole EOL', e.text(), b'abc\td' + eol + b'ef')
        e.invoke('GO0D')
        safety.expect('Enter style retained', e.text(), data)
        e.invoke('BSPACE')
        safety.expect('Backspace whole EOL', e.text(), b'abc\td' + eol + b'ef')
        lines = [b'a' * 80 if i % 3 == 0 else b'b' * 5 if i % 3 == 1 else b'c\td'
                 for i in range(80)]
        data = eol.join(lines)
        e = FeatureEditor(data, 70)
        for _ in range(7):
            e.invoke('GODW')
        for _ in range(7):
            e.invoke('GOUP')
        safety.expect('vertical target survives short lines', e.pointer('LHLCR'), 70)
        e.invoke('GOEND')
        safety.expect('CtrlEnd', e.pointer('LHLCR'), len(data))
        e.invoke('GOSTART')
        e.invoke('GOPD')
        e.invoke('GOPU')
        safety.expect('page navigation round-trip', e.pointer('LHLCR'), 0)
    for offset in (16382, 16383, 16384):
        data = b'a\r' * (offset // 2) + b'x' * (offset % 2) + b'\r\nB'
        e = FeatureEditor(data, offset, view_start=offset - offset % 2)
        e.invoke('GORG')
        safety.expect('CRLF page right', e.pointer('LHLCR'), offset + 2)
        e.invoke('GOLF')
        safety.expect('CRLF page left', e.pointer('LHLCR'), offset)
        e.invoke('GORG')
        e.invoke('BSPACE')
        safety.expect('CRLF page removal', e.text(), data[:offset] + b'B')
    e = FeatureEditor(b'abc\rdefgh', 3)
    e.invoke('GOSTART')
    e.invoke('GODW')
    safety.expect('CtrlHome resets target column', e.pointer('LHLCR'), 4)
    for length in (80, 128, 256, 16384, 65536, 70000):
        data = b'x' * length + b'\r\nshort\r\n' + b'y' * length
        e = FeatureEditor(data, length)
        safety.expect('full column', value(e, 'CURCOL'), length)
        safety.expect('horizontal offset', value(e, 'HSCROLL'), length - 79)
        safety.expect('visible cursor', e.memory[e.symbols['CRP']], 79)
        e.invoke('GODW')
        safety.expect('short intermediate line', e.pointer('LHLCR'), length + 7)
        e.invoke('GODW')
        safety.expect('restore long target column', e.pointer('LHLCR'), len(data))
        e.invoke('SSQ')
        safety.expect('Home full column', value(e, 'CURCOL'), 0)
        safety.expect('Home scroll', value(e, 'HSCROLL'), 0)
        e.invoke('SSE')
        safety.expect('End full column', value(e, 'CURCOL'), length)
        assert not e.invalid_maps
    e = FeatureEditor(b'\t' * 9000, 9000)
    safety.expect('Tab 24-bit column', value(e, 'CURCOL'), 72000)
    # Raw bytes survive normalization used by Save, including mixed EOL/Tab/NUL.
    data = b'a\r\nb\nc\rd\t\0e'
    e = FeatureEditor(data, 6)
    e.invoke('PRTOSV')
    safety.expect('mixed save size', e.machine.hl, len(data))
    safety.expect('mixed save bytes', bytes(e.banks['text', 0][:len(data)]), data)
    e.invoke('TOWORK')
    safety.expect('mixed restored bytes', e.text(), data)


def test_mixed_editing():
    # Independent byte-string model, including atomic CRLF steps and deletion.
    for highlight in (False, True):
        rng = random.Random(42)
        data, cursor = b'abc\r\ndef\r\nghi', 0
        e = FeatureEditor(data, cursor, highlight)
        for step in range(350):
            op = rng.choice(('SMBADD', 'ADDTAB', 'GO0D', 'BSPACE', 'DELETE', 'GOLF', 'GORG', 'SSQ', 'SSE'))
            byte = rng.choice(b'xyzABC')
            if op in ('SMBADD', 'ADDTAB', 'GO0D'):
                insert = bytes([byte]) if op == 'SMBADD' else (b'\t' if op == 'ADDTAB' else b'\r\n')
                data = data[:cursor] + insert + data[cursor:]
                cursor += len(insert)
            elif op in ('BSPACE', 'GOLF'):
                size = 2 if data[:cursor].endswith(b'\r\n') else min(1, cursor)
                if op == 'BSPACE':
                    data = data[:cursor - size] + data[cursor:]
                cursor -= size
            elif op in ('DELETE', 'GORG'):
                size = 2 if data[cursor:].startswith(b'\r\n') else min(1, len(data) - cursor)
                if op == 'DELETE':
                    data = data[:cursor] + data[cursor + size:]
                else:
                    cursor += size
            elif op == 'SSQ':
                cursor = max(data.rfind(b'\r', 0, cursor), data.rfind(b'\n', 0, cursor)) + 1
            elif op == 'SSE':
                m = re.search(b'[\r\n]', data[cursor:])
                cursor = cursor + m.start() if m else len(data)
            e.invoke(op, a=byte)
            safety.expect(f'mixed {step} {op} bytes', e.text(), data)
            safety.expect(f'mixed {step} {op} cursor', e.pointer('LHLCR'), cursor)
            assert not e.invalid_maps


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--group')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    tests = [test_search, test_clipboard, test_io_and_status, test_calculator,
             test_highlight, test_lines_and_navigation, test_mixed_editing]
    if args.group:
        tests = [test for test in tests if args.group in test.__name__]
        assert tests, args.group
    results = []
    for test in tests:
        start = time.monotonic()
        try:
            test()
            row = dict(test=test.__name__, passed=True)
        except (AssertionError, KeyError) as error:
            row = dict(test=test.__name__, passed=False, error=str(error)[:2000])
        row['seconds'] = round(time.monotonic() - start, 3)
        results.append(row)
        print(json.dumps(row, ensure_ascii=True), flush=True)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding='utf-8')
    return int(any(not row['passed'] for row in results))


if __name__ == '__main__':
    raise SystemExit(main())
