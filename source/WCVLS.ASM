; WCVLS — структуры состояния Wild Commander, описатели окон и текстовые данные.
; Exact-диапазон: #7EA0..#8530. При сборке с базой #7EA0 файл побайтно совпадает
; с поставляемым boot.$C: 1681 байт, различий нет.
; Основные структуры:
;   WINDOW/WINDO2 — 36-байтовые описатели левой и правой панелей;
;   PALLIT — таблица сочетаний страниц/палитры;
;   PPFR..PHEP — состояние загрузчика и активного плагина;
;   BRRR..ERRR — кластеры, размер и сохранённые каталоги файловых операций;
;   INTPL/INTTM/INTPS — флаги обработчиков прерывания;
;   ENTRY — текущая 32-байтовая запись каталога;
;   ERWND/PBWND/MDWND/F5WND/HPWND/F11WND — описатели диалоговых окон.
; Поля 36-байтового описателя панели:
;   +0 тип, +1 маска курсора, +2/+3 X/Y, +4/+5 ширина/высота,
;   +6 цвет, +8 адрес буфера, +10 число строк, +12/+13 курсор и максимум,
;   +14/+15 цвета курсора, +16 верх списка, +18 число записей,
;   +20/+21 признаки конца/начала, +22 страница, +23 смещение,
;   +25 начальная и +26 текущая страница каталога, +27 страница драйвера,
;   +28 флаг активации, +29 устройство, +30 начало, +32 текущий указатель,
;   +34 флаг инициализации, +35 критерий сортировки.
; Значения ниже раньше приходили из MD20.ASM. Условия сохраняют совместимость
; как с отдельной exact-сборкой, так и с историческим верхнеуровневым файлом.
        IFNDEF CURmsk
CURmsk  EQU %00000111
        ENDIF
        IFNDEF WNDCLR
WNDCLR  EQU %00011111
        ENDIF
        IFNDEF CURclr
CURclr  EQU %01011000
        ENDIF
        IFNDEF TBG
TBG     EQU %00010111
        ENDIF
        IFNDEF CPPG1
CPPG1   EQU 30
        ENDIF
        IFNDEF CPPG2
CPPG2   EQU 31
        ENDIF
        IFNDEF RLPNL
RLPNL   EQU #1000
        ENDIF
        IFNDEF RRPNL
RRPNL   EQU #2000
        ENDIF
        IFNDEF CATMX
CATMX   EQU 9
        ENDIF
        IFNDEF WID1
WID1    EQU 80
        ENDIF
        IFNDEF WID2
WID2    EQU 90
        ENDIF
        IFNDEF HEIMAX
HEIMAX  EQU 36
        ENDIF
        IFNDEF DEFRQ
DEFRQ   EQU %00000001
        ENDIF
        IFNDEF DRVRS
DRVRS   EQU 7
        ENDIF
        IFNDEF RUNSPG
RUNSPG  EQU #957B
        ENDIF
        IFNDEF RUNHOB
RUNHOB  EQU #9367
        ENDIF
        IFNDEF LDPLG
LDPLG   EQU #973A
        ENDIF

; Левая панель.
WINDOW  DB 6+16,CURmsk
        DB 0,0
        DB 40,2
        DB WNDCLR
        DB 0
        DW #FFFF
        DB 2,0
        DB 1,0
        DB CURclr
        DB TBG
        DW 0
        DW 0
        DB 0,0
        DB CPPG1
        DW 0
        DB 0,0
        DB 0,0
        DB 1
        DW RLPNL
        DW RLPNL
        DB 0
        DB 0

; Правая панель.
WINDO2  DB 6+16,CURmsk
        DB 40,0
        DB 40,2
        DB WNDCLR
        DB 0
        DW #FFFF
        DB 2,0
        DB 1,0
        DB CURclr
        DB TBG
        DW 0
        DW 0
        DB 0,0
        DB CPPG2
        DW 0
        DB CATMX,0
        DB 1,0
        DB 1
        DW RRPNL
        DW RRPNL
        DB 0
        DB 0

; Сочетания страниц/палитры для режимов интерфейса.
PALLIT  DW #0000,#0010,#4000,#4010
        DW #0200,#0210,#4200,#4210
        DW #0000,#0018,#6000,#6018
        DW #0300,#0318,#6300,#6318
; Пятисимвольные признаки каталога и файла в списке панели.
SDIR    DB "<DIR>"
SFIL    DB " FILE"

CSEL    NOP
CNSL    NOP

; Состояние загрузки плагинов и указатели на их заголовки.
PPFR    NOP
PPGP    NOP
PPGM    NOP
PPG2    NOP
PHED    DS 2
PHEP    DS 2

LFLT    NOP
WID     DB WID1:NOP

AYZ80   DB DEFRQ
DFRQ    DB DEFRQ

DSA     NOP
DDA     NOP
DAS     NOP

IXBU    DS 2
SPBU    DS 2

; Рабочие 32-битные значения файловых операций.
; BRRR — кластер записи; ARRR — размер; CRRR — рабочий кластер;
; DRRR — сохранённый каталог; ERRR — каталог рекурсивного копирования.
BRRR    DS 4
ARRR    DS 4
CRRR    DS 4
DRRR    DS 4
ERRR    DS 4

IXHL    DS 2

PBNOW   DS 4

RSTA    NOP

STUS    NOP

MRCT    DS 2
MRRN    DS 2
AAHL    DS 2
AADE    DS 2

; Флаги вызовов из обработчика IM2: плагин, часы и PS/2.
INTPL   NOP
INTTM   NOP
INTPS   NOP

TTHL    DS 2
TTDE    DS 2

CLRN    NOP
LXY     DS 2

; Теневые значения видеорегистров, выводимые процедурой VPRT.
VVpag   NOP
VVmod   NOP

VYofL   NOP
VYofH   NOP
VXofL   NOP
VXofH   NOP

; Таймер бездействия и порог запуска плагина-заставки.
TABTM   DS 2
AFTM    DW 2048

TMR     DB 3,6,49-3
TTM     DB "XX:XX.XX"
; Текущая 32-байтовая запись каталога FAT.
ENTRY   DS 32
TXT00   DB "[  OK  ]"
TXT01   DB "[CANCEL]"
TXT00y  DB "[ YES  ]"
TXT01n  DB "[  NO  ]"
WCDIR   DB #10,"wc",0
WCINI   DB #00,"wc.ini",0
; Окно сообщения об ошибке.
ERWND   DB 4+16+128,0
        DB 255,255
        DB 60+2,3+2
        DB %00101111
        DB 0
        DW #0000
        DB 0,0
        DW ERHD
        DW ERSL
        DW 0
ERHD    DB #0E,#09,"ERROR:",0
ERSL    DB #0E,#09,"press any key",0

; Окно индикатора прогресса.
PBWND   DB 4+128,0
        DB 255,255
        DB 64+2,2+2
        DB %01011111
        DB 0
        DW #0000
        DB 0,0
        DW 0
        DW 0
        DW 0

; Диалог создания каталога и переименования.
MDWND   DB 3+16+128,0
        DB 255,255
        DB 38+2,1+2
        DB %01011111
        DB 0
        DW #0000
        DB 0,0

; Диалог копирования.
F5WND   DB 3+16+128,0
        DB 255,255
        DB 38+2,6
        DB %01111111
        DB 0
        DW #0000
        DB 2,0

; Диалог прерывания операции.
ABWND   DB 3+16+128,0
        DB 255,255
        DB 38+2,6
        DB %01111111
        DB 0
        DW #0000
        DB 2,0

; Окно справки.
HPWND   DB 4+16+128,0
        DB 255,255
        DB 38+2,6+2
        DB %01111111
        DB 0
        DW #0000
        DB 2,5
        DW ABHED
        DW 0
        DW ABTXT

; Сообщение об успешной загрузке плагина.
LGWND   DB 3+16+128,0
        DB 255,255
        DB 32+2,2+2
        DB %01111111
        DB 0
        DW #0000
        DB 0,0

; Меню загруженных плагинов.
F11WND  DB 5+16+128+64,0
        DB 255,255
        DB 32+2,2
        DB %01011111
        DB 0
        DW #0000
        DB 0,0

        DB 1,0
        DB %11100001
        DB 0

        DW F11TXT
        DW F11BOT
        DW 0

F11TXT  DB #0E,#09,"RUN PLUGIN",0
F11BOT  DB #0B,14,#09
        DB "DEL - delete plugin",0

; Сообщение о выбранном критерии сортировки.
SMWND   DB 4+16+128,0
        DB 255,255
        DB 24+2,3
        DB %01111111
        DB 0
        DW #0000
        DB 0,0

        DW 0
        DW 0
        DW SORTIP

; Диалог выбора устройства панели.
DSWND   DB 5+16+128+64,0
        DB 0,0
        DB 30+2,DRVRS+2
        DB %01111111
        DB 0
        DW #0000
        DB 0,0

        DB 1,DRVRS
        DB %11100000
        DB 0

        DW TXT4
        DW 0
        DW THDD

BASEOP  EQU 0
; Диалог выбора обработчика расширения.
GRWND   DB 5+128+64,CURmsk
        DB 0,0
        DB 24+2,BASEOP+2
        DB %01001111
        DB 0
        DW #0000
        DB 0,0

        DB 1,BASEOP
        DB %11110000
        DB 0

        DW 0
        DW 0
        DW 0

; Диалог выбора частоты и режима.
FRWND   DB 5+16+128+64,0
        DB 255,255
        DB 18+2,6+2
        DB %01111111
        DB 0
        DW #0000
        DB 2,0

        DB 1,4
        DB %11100000
        DB 0

        DW FRWNDH
        DW 0
        DW FREQS

FRWNDH  DB #0E,#09,"RUN File AT:",0
FREQS   DB #0E,"3.5 MHz",13
        DB #0E,"7.0 MHz",13
        DB #0E,"14 MHz",13
        DB #0E,"14+MHz",0

EXTZ    DB "SPG":DW RUNSPG
        DB "$C ":DW RUNHOB
        DB "WMF":DW LDPLG
        NOP
TXT6    DB #0E,#09,"Make Directory",0
TXT7    DB #0E,#09,"ReName",0
TXT8    DB #0E,#09,"Copy",0
TXT9    DB "Copy ",#FE:DW TXTD7:NOP
TXT10   DB #0E,"<0000 of 0000>",0
TXTB    DB #0E,#09,"Delete",0
TXTD    DB #0E,"Delete "
TXTD7   DB "     files/dirs?",0
TXTE    DB 2,#0E
        DB "Deleting is in Progress!",0
TXTF    DB #0E,#09,"Aborting",0
TXTG    DB #0E,"Abort operation?",0

TXTK    DB #0E,"DELETE PLUGIN?",0
TXTL    DB #0E,"Plugin already exists!"
        DB 13
        DB #0E,"RELOAD IT?",0

TCT0    DB "Name:",0

TER0    DB #0E,"Device Not Found!",0
TER1    DB #0E,"FAT32 Not Found!",0

TER2    DB #0E,"Not Enough Space!",0
TER2A   DB #0E
        DB "Source file is not found!",0
TER2B   DB #0E
        DB "Long Name is not valid!",0
TER2C   DB #0E
        DB "Short Name index FATALITY",0
TER2D   DB #0E
        DB "Name already exists!",0
TER2F   DB #0E,"DIR with same name "
        DB "already exists!",0
TER30   DB #0E,"DIR is not empty!",0
TER2X   DB #0E
        DB "UNKNOWN ERROR!!!",0

TERC1   DB #0E,"DIR not found (src)",0
TERC2   DB #0E,"Make DIR failed (dst)",0
TERC3   DB #0E,"DIR not found (dst)",0
TERC4   DB #0E,"UPDIR not found (src)",0
TERC5   DB #0E,"UPDIR not found (dst)",0
TERC6   DB #0E,"INDEX out of DIR",0
TERD7   DB #0E,"DIR name too long/"
        DB "END of buffer",0
TERD8   DB #0E,"File not found",0
TERCU   DB #0E,"Aborted by user!",0

TER3    DB #0E
        DB "This PLUGIN can't be run"
        DB " from menu!!!",0
TER4    DB #0E
        DB "Wrong version of Plugin!",0

TEM0    DB "LOADED!!!"

BETA    DB "Beta"

ABHED   DB #0E,#09,"ABOUT",0
ABTXT   DB #0B,9,#FE:DW TXTC:DB 13
        DB #0C,4
        DB #0E,"(C) KOSHI/MGN "
        DB 1,"2025",0
SORTIP  DB #0E,"  Sorting... ;P",0
TXT4    DB #0E,#09,"Select Device:",0
THDD    DB "IDE NEMO: Master",13
        DB #0B,6,"SD: Z-Controller",13
        DB #0B,5,"SD2: Z-Controller",13
        DB #0B,6,"SD: NeoGS",13
        DB "IDE SMUC: Master",13
        DB "IDE SMUC: Slave",13
        DB "IDE NEMO: Slave",0
WND     DB #0F,0
        DB 0,0
WND_W   DB 80
WND_H   DB 36
        DB %00000000

TXT1    DB #0E,5,5
TXTC
        DB "Wild Commander v1.10",0
TXT2    DB 7,7,"F1",6,1,"Help  "
        DB 7,7,"F2",8,1
F2TXT   DB "      "
        DB 7,7,"F3",6,1,"View  "
        DB 7,7,"F4",8,1
F4TXT   DB "      "
        DB 7,7,"F5",6,1,"Copy  "
        DB 7,7,"F6",8,1,"ReName"
        DB 7,7,"F7",6,1,"MkDir "
        DB 7,7,"F8",8,1,"Delete"
        DB 7,7,"F9",6,1,"SetUP "
        DB 7,7,"10",8,1,"Plugin"
        DB 7,7,32,6,1,"KOSHI/MGN"
        NOP
UPDIR   DB #10,"..",0
