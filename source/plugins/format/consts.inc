; consts.inc — адреса WC, порты и буферы плагина.

WLD             EQU #6006
WC_PG0          EQU #6000
WC_PG3          EQU #6003
PORT_W0         EQU #10AF
PORT_MEMCFG     EQU #21AF
PORT_CACHE      EQU #2BAF
PORT_DMA        EQU #27AF
CACHE_WC        EQU %00000010           ; маска WC: кэш только у W1
CORE_DOS_SWP    EQU #401B
CORE_DEVINI     EQU #4003
CORE_HDD        EQU #4009
DRV_XPOZI       EQU #3809
DRV_RDDSE       EQU #380F
DRV_SDDSE       EQU #3812
DRV_ABT         EQU #384A
DRV_LOBU        EQU #3000               ; IDENTIFY после DEVINI IDE
WINDOW          EQU #7EA0               ; панели WC (WCVLS; сверяет AUTOEXEC)
WINDO2          EQU #7EC4
PANEL_PAGE      EQU 27                  ; +27 страница драйвера (#F0+)
PANEL_INIT      EQU 28
PANEL_DEV       EQU 29
PANEL_PATH      EQU 30                  ; +30/31 начало пути в #F7, +32/33 конец
PNLPG           EQU #F0
RPPG            EQU #F7
SD_CONF         EQU #77
SD_DATA         EQU #57

SECTOR_BUF      EQU #AE00               ; строится MBR/BPB/FSInfo (кратно 512)
VERIFY_BUF      EQU #AC00               ; чтение для сверки
ID_BUF          EQU #AA00               ; копия IDENTIFY
ZERO_BUF        EQU #B000               ; 8 нулевых секторов
ZERO_SECTORS    EQU 8

DEV_NEMO        EQU 0                   ; номера DOS_SWP
DEV_SD1         EQU 1
DEV_NGS         EQU 2
DEV_SMUC        EQU 3
DEV_SMUC2       EQU 4
DEV_NEMO2       EQU 5
DEV_SD2         EQU 6
