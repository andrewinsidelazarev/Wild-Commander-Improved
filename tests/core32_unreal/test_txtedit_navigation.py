"""Регрессии видимого курсора, скорости навигации и отказа от сохранения.

Исполняется собранный Z80. Модели API проверяют управление, реальная
клавиатура и запись образа дополнительно проверяются в патченном Unreal.
"""
import json
import random
import sys

import test_txtedit_safety as safety
from test_txtedit_editing import Editor


def screen(editor):
    editor.flush()
    return bytes(editor.banks['screen', 0])


def cursor(editor, row, column):
    m, s = editor.memory, editor.symbols
    assert m[s['CRFLG']], 'Cursor is absent'
    assert bytes(m[s['CRP']:s['CRP'] + 2]) == bytes([column, row])
    data = screen(editor)
    # При обычном цвете 07 активная клетка имеет инвертированный атрибут F0.
    assert data[row * 256 + 128 + column] == 0xf0


def test_empty_line_cursor():
    for eol in (b'\r', b'\n', b'\r\n'):
        text = eol.join([b'first', b'', b'third', b'', b''])
        editor = Editor(text, 0)
        for row in range(1, 6):
            cursor(editor, row, 0)
            if row < 5:
                editor.invoke('GODW')
        for row in range(4, 0, -1):
            editor.invoke('GOUP')
            cursor(editor, row, 0)
        assert editor.text() == text
    editor = Editor(b'', 0)
    for operation in ('GOLF', 'GOUP', 'GODW', 'GORG', 'SSQ', 'SSE'):
        editor.invoke(operation)
        cursor(editor, 1, 0)


def test_navigation_screen():
    rng = random.Random(12092026)
    for width, height in ((80, 25), (90, 36)):
        for highlight in (False, True):
            text = b'\r\n'.join([b'LD A,12 ; comment', b'', b'\t"long;string" ' * 14,
                                  b'x', b'\t', b'ordinary line'] * 8)
            e = Editor(text, 0, highlight)
            e.memory[e.machine.ix + 4:e.machine.ix + 6] = bytes([width, height])
            e.invoke('REFRESH')
            operations = ['GODW'] * 40 + ['GOUP'] * 40
            operations += [rng.choice(['GORG', 'GOLF', 'GOUP', 'GODW', 'SSQ', 'SSE'])
                           for _ in range(160)]
            for operation in operations:
                e.invoke(operation)
                actual = screen(e)
                assert e.memory[e.symbols['CRFLG']], (operation, 'invisible cursor')
                e.invoke('REFRESH')
                assert screen(e) == actual, (width, height, highlight, operation,
                                             'cursor-only update differs from redraw')
            assert e.text() == text
            assert not e.memory[e.symbols['CHANGES']]
            # Установка/снятие выделения также должна обновить весь его цвет.
            e.invoke('GOSTART')
            e.set_pointer('BHLBLK', 0)
            e.memory[e.symbols['REFFLG']] = e.symbols['MDLTR']
            e.invoke('GORG')
            assert e.memory[e.symbols['MARKED']]
            e.memory[e.symbols['REFFLG']] = 0
            e.invoke('GORG')
            assert not e.memory[e.symbols['MARKED']]
            actual = screen(e)
            e.invoke('REFRESH')
            assert screen(e) == actual


def test_navigation_latency():
    results = []
    for highlight in (False, True):
        e = Editor((b'0123456789' * 8 + b'\r') * 60, 20, highlight)
        run = e.machine.run
        total = [0]
        def counted():
            # У установленного z80 ошибочен getter ticks_to_stop. Читаем
            # документированное поле его state image, записываем через setter.
            before = int.from_bytes(e.machine._StateBase__ticks_to_stop, 'little')
            event = run()
            after = int.from_bytes(e.machine._StateBase__ticks_to_stop, 'little')
            total[0] += (before - after) & 0xffffffff
            return event
        e.machine.run = counted
        e.invoke('GORG')
        # Менее одного кадра при 3.5 МГц, без стоимости моделей WC.
        assert total[0] < 70_000, (highlight, total[0])
        results.append(dict(highlight=highlight, tstates=total[0]))
        # Нижняя/верхняя граница окна: 33 готовые строки и одна новая.
        e.memory[e.machine.ix + 4:e.machine.ix + 6] = bytes([90, 36])
        e.invoke('REFRESH')
        for _ in range(33):
            e.invoke('GODW')
        total[0] = 0
        e.invoke('GODW')
        assert total[0] < 400_000, ('scroll down too slow', total[0])
        results.append(dict(highlight=highlight, scroll='down', tstates=total[0]))
        for _ in range(33):
            e.invoke('GOUP')
        total[0] = 0
        e.invoke('GOUP')
        assert total[0] < 400_000, ('scroll up too slow', total[0])
        results.append(dict(highlight=highlight, scroll='up', tstates=total[0]))
    print('Navigation latency:', json.dumps(results))


class ExitEditor(safety.MachineHarness):
    def __init__(self, key=0, yes=False, cancel=False, changed=True):
        super().__init__()
        self.key, self.yes, self.cancel = key, yes, cancel
        self.enter = not key and not cancel
        self.memory[self.symbols['CHANGES']] = int(changed)
        self.machine.ix = self.symbols['PLWND']
        self.calls = []
        # HALT получает реальное маскируемое прерывание в модели Z80.
        self.memory[0x38] = 0xc9
        self.machine.set_breakpoint(self.symbols['QSAVE'])

    def run_exit(self):
        m = self.machine
        m.sp = safety.STACK_BASE
        safety.put16(self.memory, m.sp, safety.RETURN_SENTINEL)
        m.pc = self.symbols['SAVECH']
        for _ in range(200):
            if m.pc == safety.RETURN_SENTINEL:
                return bool(m.f & 1)
            if m.pc == self.symbols['QSAVE']:
                self.calls.append('save')
                self.memory[self.symbols['SVERFLG']] = 0
                self.return_from_api()
                continue
            m.ticks_to_stop = 1000
            m.run()
            if m.pc == safety.WLD:
                api = m.a
                self.calls.append(api)
                if api == 8:
                    m.f = 0x40 if self.yes else 0
                elif api == 23:
                    m.f = 0 if self.cancel else 0x40
                elif api == 22:
                    m.f = 0 if self.enter else 0x40
                elif api == 42:
                    # Упрощённый KBSCN забирает scan-код Enter, хотя печатного
                    # символа не возвращает. ENKE должен вызываться раньше.
                    self.enter = False
                    m.a, m.f = self.key, 0 if self.key else 0x40
                elif api in (1, 2, 11, 46):
                    m.f = 0x40
                else:
                    raise AssertionError(('unexpected API', api))
                self.return_from_api()
            elif m.halted:
                m.on_handle_active_int()
        raise AssertionError(f'SAVECH stuck at {m.pc:04x}')


def test_exit_decisions():
    for key, yes, cancel, changed, want_save, want_cancel in (
            (ord('n'), True, False, True, False, False),
            (ord('N'), True, False, True, False, False),
            (0, False, False, True, False, False),
            (ord('y'), False, False, True, True, False),
            (0, True, False, True, True, False),
            (0, True, True, True, False, True),
            (0, True, False, False, False, False)):
        e = ExitEditor(key, yes, cancel, changed)
        assert e.run_exit() == want_cancel
        assert ('save' in e.calls) == want_save, e.calls
        assert not any(api in e.calls for api in (49, 72, 74, 75))


if __name__ == '__main__':
    for test in (test_empty_line_cursor, test_navigation_screen,
                 test_navigation_latency, test_exit_decisions):
        test()
        print('PASS', test.__name__, flush=True)
