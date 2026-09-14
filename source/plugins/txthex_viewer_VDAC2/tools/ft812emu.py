"""Официальный эмулятор FT812 для тестов: bt8xxemu.dll (Bridgetek) через ctypes.

Это тот же эмулятор чипа, что показывает экран VDAC2 в Unreal Speccy, —
проверка команд и пикселей дисплей-листа. Кадр берётся у DLL; совпадение
пикселей не доказывает соблюдение тактового бюджета физического FT812.

С чипом говорим так же, как Z80 через порты #77/#57: выбор микросхемы
(chip select) и обмен байтами по SPI. Команды хоста — три байта; запись в
память — три байта адреса со старшими битами 10 и данные; чтение — адрес
со старшими битами 00, пустой байт и данные.

DLL и её соседи лежат рядом со сборкой Unreal стенда ZiFi; другой путь можно
задать переменной окружения BT8XXEMU_DIR.
"""
import ctypes
import os
import threading
import time
from ctypes import (CFUNCTYPE, POINTER, Structure, byref, c_char_p, c_int, c_uint8, c_uint32,
                    c_void_p, c_wchar)
from pathlib import Path

DEFAULT_DIR = Path(__file__).resolve().parents[5] / 'FAT32 Driver' / 'build' / 'unreal-zifi'
API_VERSION = 12                    # BT8XXEMU_VERSION_API из bt8xxemu.h
MODE_FT812 = 0x0812
FLAG_COPROCESSOR = 0x04
FLAG_GRAPHICS_MULTITHREAD = 0x20
FRAME_COMPLETE = 0x02               # кадр дорисован целиком

# Адреса памяти и регистров FT81x (FT81X Series Programmer Guide).
RAM_G = 0x000000
RAM_DL = 0x300000
REG = 0x302000
REG_ID = REG + 0x000
REG_FRAMES = REG + 0x004
REG_HCYCLE = REG + 0x02C
REG_HOFFSET = REG + 0x030
REG_HSIZE = REG + 0x034
REG_HSYNC0 = REG + 0x038
REG_HSYNC1 = REG + 0x03C
REG_VCYCLE = REG + 0x040
REG_VOFFSET = REG + 0x044
REG_VSIZE = REG + 0x048
REG_VSYNC0 = REG + 0x04C
REG_VSYNC1 = REG + 0x050
REG_DLSWAP = REG + 0x054
REG_CSPREAD = REG + 0x068
REG_PCLK_POL = REG + 0x06C
REG_PCLK = REG + 0x070
REG_CMD_READ = REG + 0x0F8
REG_CMD_WRITE = REG + 0x0FC
REG_CMDB_SPACE = REG + 0x574
REG_CMDB_WRITE = REG + 0x578

# Команды хоста (первый байт трёхбайтной посылки).
HOST_ACTIVE = 0x00
HOST_SLEEP = 0x42
HOST_CLKEXT = 0x44
HOST_CLKSEL = 0x61
HOST_RST_PULSE = 0x68

# 1024x768 @ 59 Гц: как VM_1024_768_59Hz в TSLib (Zuma, HMM2 на VDAC2).
# Частота точек 64 МГц (множитель 8), строка 1344 такта, кадр 806 строк:
# 64 000 000 / (1344 * 806) = 59,08 Гц.
MODE_1024_768_59 = {
    'mul': 8,
    REG_HSYNC0: 24, REG_HSYNC1: 24 + 136, REG_HOFFSET: 24 + 136 + 160,
    REG_HSIZE: 1024, REG_HCYCLE: 24 + 136 + 160 + 1024,
    REG_VSYNC0: 3 - 1, REG_VSYNC1: 3 + 6 - 1, REG_VOFFSET: 3 + 6 + 29 - 1,
    REG_VSIZE: 768, REG_VCYCLE: 3 + 6 + 29 + 768,
}

_GRAPHICS = CFUNCTYPE(c_int, c_void_p, c_void_p, c_int, POINTER(c_uint32), c_uint32, c_uint32, c_int)
_LOG = CFUNCTYPE(None, c_void_p, c_void_p, c_int, c_char_p)


class _Params(Structure):
    """BT8XXEMU_EmulatorParameters (bt8xxemu.h, API 12)."""
    _fields_ = [('Main', c_void_p), ('Flags', c_int), ('Mode', c_int), ('MousePressure', c_uint32),
                ('ExternalFrequency', c_uint32), ('ReduceGraphicsThreads', c_uint32),
                ('MCUSleep', c_void_p), ('RomFilePath', c_wchar * 260), ('OtpFilePath', c_wchar * 260),
                ('CoprocessorRomFilePath', c_wchar * 260), ('Graphics', _GRAPHICS), ('Log', _LOG),
                ('Close', c_void_p), ('UserContext', c_void_p), ('Flash', c_void_p)]


class FT812:
    """Один запущенный чип. Все вызовы SPI — из того потока, что создал объект."""

    def __init__(self, dll_dir=None):
        dll_dir = Path(dll_dir or os.environ.get('BT8XXEMU_DIR') or DEFAULT_DIR)
        os.add_dll_directory(str(dll_dir))
        self.dll = ctypes.CDLL(str(dll_dir / 'bt8xxemu.dll'))
        d = self.dll
        d.BT8XXEMU_defaults.argtypes = [c_uint32, POINTER(_Params), c_int]
        d.BT8XXEMU_run.argtypes = [c_uint32, POINTER(c_void_p), POINTER(_Params)]
        d.BT8XXEMU_transfer.argtypes = [c_void_p, c_uint8]
        d.BT8XXEMU_transfer.restype = c_uint8
        d.BT8XXEMU_chipSelect.argtypes = [c_void_p, c_int]
        d.BT8XXEMU_destroy.argtypes = [c_void_p]
        self._lock = threading.Lock()
        self._want = False
        self._frame = None
        self.errors = []
        # обработчики держим в полях: иначе сборщик мусора удалит их под DLL
        self._on_graphics = _GRAPHICS(self._graphics)
        self._on_log = _LOG(self._log)
        params = _Params()
        d.BT8XXEMU_defaults(API_VERSION, byref(params), MODE_FT812)
        # Без окна/звука/клавиатуры. DynamicDegrade относится к загрузке
        # компьютера, а не к доказательству бюджета 1344 такта на FT812.
        params.Flags = FLAG_COPROCESSOR | FLAG_GRAPHICS_MULTITHREAD
        params.Graphics = self._on_graphics
        params.Log = self._on_log
        self.emu = c_void_p()
        d.BT8XXEMU_run(API_VERSION, byref(self.emu), byref(params))

    # --- обратные вызовы эмулятора (его собственные потоки) ----------------------------
    def _graphics(self, sender, context, output, buffer, hsize, vsize, flags):
        if self._want and output and (flags & FRAME_COMPLETE):
            data = ctypes.string_at(buffer, hsize * vsize * 4)
            with self._lock:
                if self._want:
                    self._frame = (hsize, vsize, data)
                    self._want = False
        return 1

    def _log(self, sender, context, kind, message):
        if kind == 0:
            self.errors.append(message.decode(errors='replace'))

    # --- SPI ------------------------------------------------------------------------------
    def select(self, on):
        self.dll.BT8XXEMU_chipSelect(self.emu, 1 if on else 0)

    def xfer(self, byte):
        return self.dll.BT8XXEMU_transfer(self.emu, byte)

    def host(self, command, param=0):
        self.select(1)
        self.xfer(command)
        self.xfer(param)
        self.xfer(0)
        self.select(0)

    def write(self, addr, data):
        """Записать байты data в память чипа с адреса addr."""
        self.select(1)
        self.xfer(0x80 | ((addr >> 16) & 0x3F))
        self.xfer((addr >> 8) & 0xFF)
        self.xfer(addr & 0xFF)
        transfer, emu = self.dll.BT8XXEMU_transfer, self.emu
        for b in data:
            transfer(emu, b)
        self.select(0)

    def read(self, addr, count):
        self.select(1)
        self.xfer((addr >> 16) & 0x3F)
        self.xfer((addr >> 8) & 0xFF)
        self.xfer(addr & 0xFF)
        self.xfer(0)                                    # пустой байт перед данными
        data = bytes(self.xfer(0) for _ in range(count))
        self.select(0)
        return data

    def wr8(self, addr, value):
        self.write(addr, bytes([value & 0xFF]))

    def wr16(self, addr, value):
        self.write(addr, (value & 0xFFFF).to_bytes(2, 'little'))

    def wr32(self, addr, value):
        self.write(addr, (value & 0xFFFFFFFF).to_bytes(4, 'little'))

    def rd8(self, addr):
        return self.read(addr, 1)[0]

    def rd32(self, addr):
        return int.from_bytes(self.read(addr, 4), 'little')

    # --- запуск чипа и режим ---------------------------------------------------------------
    def boot(self, mode=MODE_1024_768_59):
        """Сброс, внешний генератор, множитель частоты, ожидание REG_ID = #7C,
        затем развёртка режима. Порядок — как у TSLib (FT812 на VDAC2)."""
        self.host(HOST_RST_PULSE)
        time.sleep(0.02)
        self.host(HOST_CLKEXT)
        self.host(HOST_SLEEP)
        self.host(HOST_CLKSEL, mode['mul'] | 0xC0)
        self.host(HOST_ACTIVE)
        self.host(HOST_ACTIVE)
        for _ in range(200):
            if self.rd8(REG_ID) == 0x7C:
                break
            time.sleep(0.005)
        else:
            raise RuntimeError('FT812 не ответил: REG_ID != #7C')
        self.wr8(REG_PCLK, 0)
        for reg, value in mode.items():
            if reg != 'mul':
                self.wr16(reg, value)
        self.wr8(REG_PCLK_POL, 0)
        self.wr8(REG_CSPREAD, 0)
        self.wr8(REG_PCLK, 1)

    # --- сопроцессор -----------------------------------------------------------------------
    def cmd(self, data):
        """Отдать сопроцессору поток команд (кратно 4 байтам) через REG_CMDB_WRITE."""
        assert len(data) % 4 == 0, len(data)
        pos = 0
        while pos < len(data):
            space = int.from_bytes(self.read(REG_CMDB_SPACE, 4), 'little') & 0xFFC
            if space == 0:
                time.sleep(0.001)
                continue
            chunk = data[pos:pos + space]
            self.write(REG_CMDB_WRITE, chunk)
            pos += len(chunk)

    def wait_idle(self, timeout=10.0):
        """Ждать, пока сопроцессор выполнит всё записанное (READ == WRITE)."""
        t0 = time.time()
        while time.time() - t0 < timeout:
            rd, wr = self.rd32(REG_CMD_READ), self.rd32(REG_CMD_WRITE)
            if rd == 0xFFF:
                raise RuntimeError('сопроцессор FT812 сообщил об ошибке')
            if rd == wr:
                return
            time.sleep(0.002)
        raise TimeoutError('сопроцессор FT812 не закончил за отведённое время')

    # --- кадр ---------------------------------------------------------------------------------
    def frame(self, timeout=10.0, skip=2):
        """Готовый кадр чипа как PIL.Image (RGB). skip — сколько целых кадров
        пропустить, чтобы на экране точно был последний дисплей-лист."""
        from PIL import Image
        for _ in range(skip + 1):
            with self._lock:
                self._frame = None
                self._want = True
            t0 = time.time()
            while True:
                with self._lock:
                    got = self._frame
                if got:
                    break
                if time.time() - t0 > timeout:
                    raise TimeoutError('FT812 не выдал кадр')
                time.sleep(0.005)
        w, h, data = got
        return Image.frombuffer('RGBA', (w, h), data, 'raw', 'BGRA', 0, 1).convert('RGB')

    def close(self):
        if self.emu:
            self.dll.BT8XXEMU_destroy(self.emu)
            self.emu = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
