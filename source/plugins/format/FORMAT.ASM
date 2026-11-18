; FORMAT — разметка накопителя под FAT32 для Wild Commander. UTF-8 без BOM.
;
; Меню F10 (тип #03). Устройства — все, что знает WC: SD Z-Controller 1 и 2,
; IDE Nemo и SMUC (master, slave), SD через NeoGS. Загрузочное устройство WC
; (ячейка CMOS #B2, как GBD в MD20) в списке есть, но выбрать его нельзя:
; после форматирования WC с него не загрузится.
;
; Обмен — драйвером WC в своей странице 1 (W0), как у Chkdsk: копия страницы
; панели, DOS_SWP выбранного устройства, DEVINI; страница панели не трогается.
; Ёмкость: SD — регистр CSD (CMD9 по SPI Z-Controller; у карты NeoGS CMD9
; выполняет своя короткая программа на процессоре NeoGS, затем служба WC
; ставится заново — device.inc, NgsCsd), IDE — ответ IDENTIFY,
; который DEVINI драйвера оставляет в LOBU (#3000): LBA28 (слова 60-61) или,
; у диска без LBA, цилиндры * головки * секторы (слова 1, 3, 6; адресацию
; CHS ведёт драйвер WC с 2026-11-17, source/IDE_CHS.INC).
;
; Разметка (layout.inc, эталон tests/fat32_layout.py): MBR и один раздел на
; всё устройство — #0C (#0B у диска CHS), том FAT32 с выровненной областью
; данных, кластер по таблице Microsoft или выбранный. Быстрое форматирование:
; пишутся MBR, загрузочные секторы с копиями, FSInfo, обе FAT и корень.
; Порядок записи: сначала нули с LBA 0 (старых MBR и тома больше нет), затем
; служебная область тома, загрузочный сектор, MBR — последним. Оборванная
; запись оставляет устройство без тома, а не с полуготовым томом.
;
; После записи панели на этом устройстве монтируют новый том (DOS_SWP,
; DEVINI, HDD в их странице, путь — корень), плагин возвращает 3 (WC
; перечитывает обе панели).
        DEVICE ZXSPECTRUM128
        ORG 0
FileStart:
        DS 16,0
        DB "WildCommanderMDL",#10,0
        DB 2,0                          ; страница 0 — код, 1 — драйвер (W0)
        DB 0,(CodeEnd-CodeStart+511)/512
        DS 10,0
        DS 15,0
        DB 0
        DS 96,0                         ; расширений нет
        DB 0
        DD #FFFFFFFF
NameHeader:
        DB "FAT32 format"
        DS 32-($-NameHeader),32
        DB #03                          ; меню F10
        DS 6,0
        DS 24,0
        DS 32,0
        DS 252,0
        ASSERT $ == 512
        DISP #8000

        INCLUDE "consts.inc"

CodeStart:
Entry:
        CP 3
        JR Z,.f10
        XOR A                           ; только из меню F10
        RET
.f10:   PUSH IX
        LD (PanelIX),IX
        LD A,I
        PUSH AF
        LD HL,State
        LD DE,State+1
        LD BC,StateEnd-State-1
        LD (HL),0
        LDIR
        POP AF
        JP PO,.irqoff
        LD A,1
        LD (SavedIFF),A
.irqoff:
        LD A,(WC_PG0)
        LD (SavedPg0),A
        LD HL,ZERO_BUF
        LD DE,ZERO_BUF+1
        LD BC,ZERO_SECTORS*512-1
        LD (HL),0
        LDIR
        LD A,15                         ; GEDPL: основной текстовый режим
        CALL WLD
        CALL BootDevice
.menu:  CALL DeviceMenu
        JR C,.leave
        CALL Probe
        JR C,.menu
.options:
        CALL Options
        JR C,.menu
        CALL Confirm
        JR C,.options
        LD A,1                          ; запись началась: панели — заново
        LD (Touched),A
        CALL Format                     ; итог — FormatResult
        CALL Remount
        CALL Summary
.leave: CALL CloseMain
        LD A,46                         ; клавиша выхода не должна достаться WC
        CALL WLD
        POP IX
        LD A,(Touched)
        OR A
        LD A,0
        JR Z,.ret
        LD A,3                          ; перечитать обе панели
.ret:   LD B,A
        LD A,(SavedIFF)
        OR A
        LD A,B
        RET Z
        EI
        RET

        INCLUDE "device.inc"
        INCLUDE "write.inc"
        INCLUDE "ui.inc"
        INCLUDE "layout.inc"

        INCLUDE "state.inc"
CodeEnd:
        ASSERT CodeEnd <= ID_BUF
        ENT
        DS ((CodeEnd-CodeStart+511)/512)*512-(CodeEnd-CodeStart),0
FileEnd:
        SAVEBIN "build/FORMAT.WMF",FileStart,FileEnd-FileStart
