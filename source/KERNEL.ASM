; KERNEL — рабочая карта памяти и таблица API WildDOSFileCore.
; Метка CORE32 ставится физически по #C00C до DISP #4000; START и весь код
; после неё адресуются так, как исполняются после копирования.
; Ключевые области:
;   #0000..#1FFF — буфер перечисления каталога;
;   #3000..#31FF — сектор FAT; #3200/#3400 — два секторных буфера;
;   #37F8..#37FE — состояние итератора каталога;
;   #3800 — таблица входов текущего драйвера;
;   #3848 — общие переменные; #3868 — 32-байтовая FAT-запись;
;   #3889..#38CC — параметры FAT32, потоков и текущего каталога.
CORE32:
        DISP #4000
; Два смежных 8-КиБ диапазона используются перечислителем каталога.
; При переходе по цепочке каталогов хвост буфера сдвигается из верхней
; половины в нижнюю, после чего LOAD512 дополняет освободившуюся область.
GENBU   EQU #0000
GENBE   EQU #2000
NXTBU   EQU #0000
NXTBM   EQU #1000
NXTBE   EQU #2000
NXTBZ   EQU (high NXTBE-high NXTBU)/2

DRVR    EQU #3800
VALS    EQU DRVR+24*3
; Буфер управляющих значений драйвера расположен перед таблицей входов #3800.
; Исторический дамп исходников ошибочно отсчитывал эти четыре слова от VALS.
CGFL    EQU DRVR-2
CGPZ    EQU DRVR-4
CGHL    EQU DRVR-6
CGDE    EQU DRVR-8

SECBU   EQU #3000
SECBE   EQU SECBU+512
LOBU    EQU #3200
LOBE    EQU LOBU+512
LOBU2   EQU LOBE
LOBE2   EQU LOBU2+512
SELDEV  EQU DRVR
DEVINI  EQU DRVR+3
REINI   EQU DRVR+3*2

XPOZI   EQU DRVR+3*3
PROZ    EQU XPOZI+3

RDDSE   EQU PROZ+3
SDDSE   EQU RDDSE+3

RDD256  EQU SDDSE+3
; Состояние текущего потока по кластерной цепочке. NSDC — номер сектора
; внутри кластера, EOC — признак конца цепочки, ABT — запрос прерывания.
NSDC    EQU VALS
EOC     EQU NSDC+1

ABT     EQU EOC+1

BZN     EQU ABT+1
NR0     EQU BZN+1

CAHL    EQU NR0+2
CADE    EQU CAHL+2

LSTSE   EQU CADE+2

REZDE   EQU LSTSE+4

PR      EQU REZDE+2

CLHL    EQU PR+4
CLDE    EQU CLHL+2

LLHL    EQU CLDE+2

LTHL    EQU LLHL+4
LTDE    EQU LTHL+2
; ENTRY — рабочая 32-байтовая запись FAT32. EFLG, CLSDE/CLSHL и SIZIK
; указывают соответственно на атрибуты, старшую/младшую половины номера
; первого кластера и размер файла внутри этой записи.
ENTRY   EQU LTDE+2
EFLG    EQU ENTRY+11
CLSDE   EQU ENTRY+20
CLSHL   EQU ENTRY+26
SIZIK   EQU ENTRY+28
; Codex - 2026-07-16 - begin
; Младший байт BPB_ExtFlags: бит 7 отключает зеркалирование FAT, младшие четыре
; бита выбирают активную копию. В эталонном образе ENTRY+32 не использовался.
FATFLAGS EQU ENTRY+32
; Codex - 2026-07-16 - end
BREZS   EQU ENTRY+33
FSINF   EQU BREZS+2

; Параметры, извлечённые HDD из BPB FAT32: число FAT, размер одной FAT,
; секторов на кластер, корневой кластер, смещение раздела и начала областей.
BFATS   EQU FSINF+4
BFTSZ   EQU BFATS+1
BSECPC  EQU BFTSZ+4
BROOTC  EQU BSECPC+2

FSTFRC  EQU BROOTC+4

ADDTOP  EQU FSTFRC+4

SFAT    EQU ADDTOP+4
SDFAT   EQU SFAT+2

CUHL    EQU SDFAT+4
CUDE    EQU CUHL+2

NXDE    EQU CUDE+2
NXHL    EQU NXDE+2

LDHL    EQU NXHL+2

COUNT   EQU LDHL+2
DUHL    EQU COUNT+1
DUDE    EQU DUHL+2

DUBA    EQU DUDE+2
UUHL    EQU DUBA+1
BUHL    EQU UUHL+2
CLCNT   EQU BUHL+2

FCTS    EQU CLCNT+4
BUTS    EQU FCTS+4

LSTCAT  EQU BUTS+4
RECCAT  EQU LSTCAT+4

; START (#4000) — стабильная таблица внешнего API WildDOSFileCore.
; Каждый элемент занимает три байта, поэтому вызывающий код может обращаться
; к функции как START+3*N. Зарезервированные элементы ведут в Z0 и ничего не
; делают. Конкретные ABI процедур описаны перед их реализациями в CORE32.ASM.
START   JP Z0            ; +#00: зарезервировано (SELDEV находится в DRVR)
        JP DEVINI        ; +#03: инициализация активного драйвера
        JP Z0            ; +#06: зарезервировано (REINI находится в DRVR)
        JP HDD           ; +#09: найти и разобрать FAT32

        JP RDD           ; +#0C: чтение с текущей позиции драйвера
        JP SDD           ; +#0F: запись с текущей позиции драйвера

        JP GIPAG         ; +#12: перейти к первому сектору кластера
        JP LOAD512       ; +#15: потоковое чтение блоков по 512 байт
        JP SAVE512       ; +#18: потоковая запись блоков по 512 байт

        JP DOS_SWP       ; +#1B: выбрать и распаковать драйвер устройства

; Codex - 2026-07-17 - begin
        JP GLSTCAT       ; +#1E: установить активный каталог из 4 байт по HL
        JP TLSTCAT       ; +#21: получить активный каталог в 4 байта по DE
; Codex - 2026-07-17 - end

        JP SRHFCL        ; +#24: найти свободный кластер от FSTFRC
; Codex - 2026-07-17 - begin
        JP APPEND        ; +#27: дописать 0..512 байт в конец найденного файла
; Codex - 2026-07-17 - end
        JP MKSG          ; +#2A: создать FAT-цепочку заданного размера
        JP Z0            ; +#2D: зарезервировано
        JP RFRH          ; +#30: записать FSI_Nxt_Free в FSInfo

; Codex - 2026-07-17 - begin
        JP GENTRY        ; +#33: установить ENTRY из 32 байт по HL
        JP TENTRY        ; +#36: получить ENTRY в DE и сохранить контекст APPEND
; Codex - 2026-07-17 - end

        JP MKFILE        ; +#39: создать файл
        JP MKDIR         ; +#3C: создать каталог

        JP DELFL         ; +#3F: удалить файл или каталог
        JP RENAME        ; +#42: переименовать запись

        JP DLSG          ; +#45: освободить FAT-цепочку
        JP CHTOSE        ; +#48: преобразовать цепочку в список секторов

        JP Z0            ; +#4B: зарезервировано
        JP SRHDRN        ; +#4E: найти запись по имени

        JP LOAD256       ; +#51: чтение потоком по 256+256 байт
        JP LOADNON       ; +#54: проход цепочки без копирования данных

        JP NXTETY        ; +#57: следующая полная запись каталога
        JP NXTETY2       ; +#5A: следующая настраиваемая запись каталога
