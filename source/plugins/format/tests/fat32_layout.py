"""Эталон разметки FORMAT.WMF: MBR с одним разделом и том FAT32.

Независимая от Z80 модель того, что пишет плагин (source/plugins/format):
по ёмкости устройства, его виду и выбранному кластеру — начало и длина
раздела, резерв, размер FAT, число кластеров, а затем и все записываемые
секторы. Тесты сверяют с ней расчёт плагина (исполняется на Z80) и образы
после форматирования в эмуляторе; сами образы проверяет ещё и Windows chkdsk.

Правила (docs в README плагина):
* SD — раздел с 8192 (4 МиБ), начало области данных кратно 8192;
* IDE с LBA — раздел с 2048 (1 МиБ), область данных кратна 2048;
* IDE без LBA (CHS) — раздел со второй головки цилиндра 0 (LBA = секторов на
  дорожке) до конца последнего цилиндра, область данных кратна кластеру;
* кластер «авто» — таблица Microsoft (fatgen103) для FAT32;
* резерв от 32 секторов, растёт до выравнивания области данных;
* FAT — по формуле fatgen103 (с запасом), две копии, корень — кластер 2.
"""
from dataclasses import dataclass

SD, IDE_LBA, IDE_CHS = 'sd', 'lba', 'chs'
MIN_CLUSTERS, MAX_CLUSTERS = 65525, 0x0FFFFFF5 - 2
LBA28 = (1 << 28) - 1


def auto_spc(sectors):
    """Таблица fatgen103 (DskTableFAT32): секторов на кластер по длине тома."""
    for limit, spc in ((66600, 0), (532480, 1), (16777216, 8), (33554432, 16), (67108864, 32)):
        if sectors <= limit:
            return spc
    return 64


@dataclass
class Layout:
    kind: str
    device: int          # секторов на устройстве (для CHS — C*H*S)
    start: int           # LBA раздела
    length: int          # секторов в разделе
    spc: int
    reserved: int
    fat: int             # секторов в одной FAT
    clusters: int
    heads: int = 255
    spt: int = 63

    @property
    def data(self):
        return self.start + self.reserved + 2 * self.fat


class LayoutError(ValueError):
    pass


def layout(kind, device, spc=None, heads=None, spt=None):
    """Разметка или LayoutError (мал для FAT32, кластеров слишком много/мало)."""
    if kind == IDE_CHS:
        start, end, align = spt, device, None
    else:
        if kind == IDE_LBA:
            device = min(device, LBA28)
        start = 8192 if kind == SD else 2048
        end, align = device, start
        heads, spt = 255, 63
    if end <= start:
        raise LayoutError('device too small')
    length = end - start
    if spc is None:
        spc = auto_spc(length)
        if not spc:
            raise LayoutError('too small for FAT32')
    align = align or spc
    reserved = 32
    tmp2 = (256 * spc + 2) // 2
    fat = -(-(length - reserved) // tmp2)
    data = start + reserved + 2 * fat
    reserved += -data % align
    if reserved > 0xFFFF:
        raise LayoutError('reserved area too long')
    clusters = (length - reserved - 2 * fat) // spc
    if clusters < MIN_CLUSTERS:
        raise LayoutError('too few clusters for FAT32')
    if clusters > MAX_CLUSTERS:
        raise LayoutError('too many clusters for FAT32')
    assert fat * 128 >= clusters + 2
    return Layout(kind, device, start, length, spc, reserved, fat, clusters, heads, spt)


def chs(lba, heads, spt):
    """Кортеж CHS для записи MBR; за пределами 1024 цилиндров — 1023/254/63."""
    c, rest = divmod(lba, heads * spt)
    h, s = divmod(rest, spt)
    if c > 1023:
        return 1023, heads - 1 if heads <= 255 else 254, spt
    return c, h, s + 1


def chs_bytes(c, h, s):
    return bytes([h, ((c >> 2) & 0xC0) | s, c & 0xFF])


def mbr(lay, signature):
    out = bytearray(512)
    out[440:444] = signature.to_bytes(4, 'little')
    entry = bytearray(16)
    entry[1:4] = chs_bytes(*chs(lay.start, lay.heads, lay.spt))
    entry[4] = 0x0B if lay.kind == IDE_CHS else 0x0C
    entry[5:8] = chs_bytes(*chs(lay.start + lay.length - 1, lay.heads, lay.spt))
    entry[8:12] = lay.start.to_bytes(4, 'little')
    entry[12:16] = lay.length.to_bytes(4, 'little')
    out[446:462] = entry
    out[510:512] = b'\x55\xAA'
    return bytes(out)


def boot_sector(lay, serial, label=b'NO NAME    '):
    b = bytearray(512)
    b[0:3] = b'\xEB\x58\x90'
    b[3:11] = b'MSWIN4.1'
    b[11:13] = (512).to_bytes(2, 'little')
    b[13] = lay.spc
    b[14:16] = lay.reserved.to_bytes(2, 'little')
    b[16] = 2
    b[21] = 0xF8
    b[24:26] = lay.spt.to_bytes(2, 'little')
    b[26:28] = lay.heads.to_bytes(2, 'little')
    b[28:32] = lay.start.to_bytes(4, 'little')
    b[32:36] = lay.length.to_bytes(4, 'little')
    b[36:40] = lay.fat.to_bytes(4, 'little')
    b[44:48] = (2).to_bytes(4, 'little')
    b[48:50] = (1).to_bytes(2, 'little')
    b[50:52] = (6).to_bytes(2, 'little')
    b[64] = 0x80
    b[66] = 0x29
    b[67:71] = serial.to_bytes(4, 'little')
    b[71:82] = label
    b[82:90] = b'FAT32   '
    b[90:94] = b'\xFA\xF4\xEB\xFD'                  # CLI; HLT; JMP $-1
    b[510:512] = b'\x55\xAA'
    return bytes(b)


def fsinfo(lay):
    f = bytearray(512)
    f[0:4] = (0x41615252).to_bytes(4, 'little')
    f[484:488] = (0x61417272).to_bytes(4, 'little')
    f[488:492] = (lay.clusters - 1).to_bytes(4, 'little')
    f[492:496] = (3).to_bytes(4, 'little')
    f[508:512] = (0xAA550000).to_bytes(4, 'little')
    return bytes(f)


def fat_head():
    head = bytearray(512)
    head[0:12] = bytes.fromhex('F8FFFF0F' 'FFFFFFFF' 'FFFFFF0F')
    return bytes(head)


def label_entry(label):
    e = bytearray(32)
    e[0:11] = label
    e[11] = 0x08
    return bytes(e)


def sectors(lay, serial, label=b'NO NAME    ', disk_signature=0):
    """Все записываемые секторы: {LBA: 512 байт}; остальные секторы до конца
    корня — нули (их тоже пишет плагин, сюда не входят)."""
    out = {0: mbr(lay, disk_signature)}
    p = lay.start
    boot = boot_sector(lay, serial, label)
    out[p] = boot
    out[p + 1] = fsinfo(lay)
    out[p + 6] = boot
    out[p + 7] = fsinfo(lay)
    for copy in range(2):
        out[p + lay.reserved + copy * lay.fat] = fat_head()
    if label != b'NO NAME    ':
        root = bytearray(512)
        root[0:32] = label_entry(label)
        out[lay.data] = bytes(root)
    return out


def zeroed(lay):
    """Диапазоны [начало, конец) секторов, которые плагин обнуляет."""
    p = lay.start
    return [(1, p), (p + 2, p + 6), (p + 8, p + lay.reserved),
            (p + lay.reserved, lay.data), (lay.data, lay.data + lay.spc)]
