"""PS2P.ASM: TAB, ARK, ARR, L7143_83..95; MD20.ASM: USPO_SAFE.

Здесь состояние клавиатуры, а не готовый результат API. make/break и кадры
меняют настоящие адреса WC; тесты могут читать/отравлять их независимо.
KBSCN(1) использует TAIE1: Shift и русская раскладка на него не влияют.
"""

TAB, ARR, ARK = 0x76B4, 0x76CB, 0x76CC
SCANS = bytes.fromhex('0e 16 1e 26 25 2e 36 3d 3e 46 45 4e 55 '
                      '15 1d 24 2d 2c 35 3c 43 44 4d 54 5b 5d '
                      '1c 1b 23 2b 34 33 3b 42 4b 4c 52 '
                      '1a 22 21 2a 32 31 3a 41 49 4a 29 79 7b 7c')
CHARS = "'1234567890-=qwertyuiop[]\\asdfghjkl;'zxcvbnm,./ +-*"
SPECIAL = {'escape': (4, 0x76), 'f1': (4, 5), 'enter': (13, 0x5A),
           'up': (5, 0x75), 'down': (7, 0x72), 'left': (6, 0x6B),
           'right': (8, 0x74), 'delete': (14, 0x71), 'shift': (2, 0x12)}


class Keyboard:
    def __init__(self, memory):
        self.memory = memory
        self.frames = 0
        self.any_calls = 0
        self.release_frames = 0
        memory[0x76C8] = 0xFF             # терминатор семи символьных ячеек

    def press(self, key):
        if len(key) == 1 and key.isupper():
            self.press('shift')          # физическая Shift+Y, KBSCN(1) остаётся 'y'
        if key == 'space':
            key = ' '
        if key in SPECIAL and key not in ('enter', 'delete'):
            slot, scan = SPECIAL[key]
        elif key in ('enter', 'delete') or len(key) == 1 and key.lower() in CHARS:
            scan = SPECIAL[key][1] if key in SPECIAL else SCANS[CHARS.index(key.lower())]
            slot = next((i for i in range(13, 20) if self.memory[TAB + i] == scan), None)
            if slot is None:
                slot = next((i for i in range(13, 20) if not self.memory[TAB + i]), None)
            if slot is None:
                return                  # все семь символьных ячеек заняты
        else:
            # Непечатное/неизвестное событие есть в TAB, но отсутствует в TAI0.
            slot, scan = 14, 0x7F
        if self.memory[TAB + slot] != scan:
            self.memory[TAB + slot] = scan
            self.memory[ARK], self.memory[ARR] = scan, 0xFF

    def release(self, key=None):
        if key is None:
            self.memory[TAB:TAB + 20] = bytes(20)
        else:
            if key == 'space': key = ' '
            scan = SPECIAL[key][1] if key in SPECIAL else (
                SCANS[CHARS.index(key.lower())] if len(key) == 1 and key.lower() in CHARS else 0x7F)
            for i in range(20):
                if self.memory[TAB + i] == scan:
                    self.memory[TAB + i] = 0
                    break               # KOF очищает найденную ячейку, ARK остаётся

    @property
    def held(self):
        return any(self.memory[TAB:TAB + 20])

    def frame(self):
        self.frames += 1
        if self.memory[ARR] not in (0, 0xFF):
            self.memory[ARR] -= 1         # PS2P L7143_101, раз в INT

    def eligible(self, scan, character=False):
        if not scan or scan == 0xFF:
            return False
        if scan != self.memory[ARK]:
            return character             # L83 и L89 различаются в этой ветке
        repeat = self.memory[ARR]
        if repeat == 0xFF:
            self.memory[ARR] = 0x19
            return True
        return repeat == 0

    def check(self, key):
        if key == 'space':
            scan = 0x29
            present = scan in self.memory[0x76C1:0x76C8]
        elif key == 'enter':
            scan = 0x5A
            present = scan in self.memory[0x76C1:0x76C8]
        else:
            slot, scan = SPECIAL[key]
            present = (scan in self.memory[0x76C1:0x76C8] if key == 'delete'
                       else self.memory[TAB + slot] == scan)
        return bool(present and self.eligible(scan))

    def character(self):
        scan = next((s for s in self.memory[0x76C1:0x76C9] if s), 0xFF)
        if not self.eligible(scan, character=True) or scan not in SCANS:
            return 0
        return ord(CHARS[SCANS.index(scan)])

    def any(self):
        self.any_calls += 1
        if not self.held:
            return 0
        self.memory[ARR] = 0x19           # ANYK НЕ является безвредным опросом
        return 0x19
