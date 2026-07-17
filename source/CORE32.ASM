; Codex - 2026-07-17 - begin
; CORE32 — осмысленный исходник WildDOSFileCore #35 с исправлениями.
; Физический исполняемый диапазон в payload: #C000..#DBFD; загрузчик копирует
; START..END из #C00C..#DBFD в рабочий диапазон #4000..#5BF1.
; Основные процедуры рабочего образа:
;   START #4000 — 31-элементная таблица API;
;   NXTETY2 #4067 и NXTETY #413F — перечисление каталога;
;   LOAD512 #43A0 / SAVE512 #4398 — потоковый обмен;
;   CURIT #44A5 — загрузка записи FAT;
;   GIPAG #44D7 — позиционирование на первом секторе кластера;
;   MKSG #4880 — создание FAT-цепочки; DLSG #49B4 — удаление цепочки;
;   SRHDRN #4A4C — поиск записи; MKFILE #4D34 / MKDIR #4D5B — создание;
;   DELFL #4CDD / RENAME #4D13 — удаление и переименование;
;   HDD #4E71 — поиск раздела и проверка FAT32;
;   DOS_SWP #4FF8 — выбор, распаковка и запуск драйвера;
;   DEHR #5AAA — распаковщик драйверов; END #5BF2 — конец рабочего образа.
; Codex - 2026-07-17 - end
; ALASM-конструкция .N повторяет всю цепочку команд строки. Здесь она явно
; выражена DUP/EDUP; это устраняет прежнюю потерю #50 байт и ошибки алгоритмов.
; Четыре слова итератора каталога находятся по #37F8..#37FE перед драйвером,
; поэтому загрузка нового драйвера в #3800 их не уничтожает.
        ORG #C000

; INSTALL_WILDDOS — физический загрузчик ядра; LC000 сохранено как исторический
; алиас адреса. Входных параметров нет.
; Копирует исполняемую часть START..END из #C00C в #4000 и возвращается.
; Codex - 2026-07-17 - begin
; Побочный эффект: рабочий диапазон #4000..#5BF1 полностью перезаписывается.
; Codex - 2026-07-17 - end
INSTALL_WILDDOS:
LC000:
        LD HL,CORE32,DE,#4000
        LD BC,END-START
; Codex - 2026-07-16 - begin
        JP WDOS_INSTALL_COPY
; Codex - 2026-07-16 - end

        INCLUDE "KERNEL.ASM"
; Codex - 2026-07-16 - begin
; Вызов функции расширения: байт сразу после CALL является номером строки
; таблицы в физической странице #E0. Шлюз сам сдвигает адрес возврата.
        MACRO CALL_WDOS_EXTENSION extension_id
        CALL EXTENSION_GATE
        DB extension_id
        ENDM
; Codex - 2026-07-16 - end
RMFL2   LD A,L:AND #F0:LD L,A
        LD C,32:ADD HL,BC
        JP NXFL2
; NXTETY2 — получить следующую подходящую запись активного каталога.
; Вход: DE — адрес выходного буфера; A — маска результата:
;   бит 7: выдавать только короткие имена; бит 4: добавить время создания;
;   бит 3: добавить дату создания; бит 2: добавить размер;
;   биты 1..0: 0 — любая запись, 1 — файл, 2 — каталог, 3 — резерв.
; Выход: Z — конец каталога; NZ — запись помещена в буфер, DE указывает за
; ней. Формат: выбранные поля, признак, имя и завершающий ноль.
; Побочные эффекты: изменяет состояние итератора CG*, при необходимости читает
; продолжение цепочки через LOAD512. Процедура использует самоподстановки BT*
; и NxMR, поэтому не является повторно-входимой.
NXTETY2

        LD C,A
        XOR A:BIT 7,C:JR Z,$+3:INC A
        LD (BT7+1),A
        XOR A:BIT 4,C:JR Z,$+3:INC A
        LD (BT4+1),A
        XOR A:BIT 3,C:JR Z,$+3:INC A
        LD (BT3+1),A
        XOR A:BIT 2,C:JR Z,$+3:INC A
        LD (BT2+1),A
        LD A,C:AND %00000011
        LD (BT0+1),A

        PUSH DE
        LD A,(CGFL):OR A:CALL Z,NXTINI
        POP DE

        LD HL,NXFF2,(NxMR+1),HL
NXFF2   LD HL,(CGPZ),B,0
NXFL2   LD A,H:CP high NXTBE:JR NC,NXMR
        LD A,(HL)
        OR A:RET Z
        CP #E5:JR Z,RMFL2

        LD C,11:ADD HL,BC
        LD A,(HL):BIT 3,A:JR NZ,RMFL2
        EXA
BT0     LD A,0
        OR A:JR Z,BT1
        DEC A:JR NZ,BT01
        EXA:BIT 4,A:JR NZ,RMFL2,Bt1
BT01    EXA:BIT 4,A
DIR_FILTER_REJECT_BRANCH:
        JR Z,RMFL2

Bt1     EXA
BT1     LD C,16-11:ADD HL,BC
BT2     LD A,0:OR A:JR Z,BT3
        LD C,28-16:ADD HL,BC
 DUP 4
         LDI
 EDUP
        LD C,16:SBC HL,BC

BT3     LD A,0:OR A:JR Z,BT4
 DUP 2
         LDI
 EDUP
 DUP 2
         DEC L
 EDUP

BT4     LD A,0:OR A:JR Z,BT8
 DUP 2
         DEC L
 EDUP
 DUP 2
         LDI
 EDUP

BT8     RES 4,L:CALL LNCRC

        EXA:LD (DE),A:INC DE
BT7     LD A,0:OR A:JP Z,NXTE2
        LD A,L:AND #F0:LD L,A
        JP Snm

; Codex - 2026-07-16 - begin
NXMR    LD A,(EOC):OR A:RET NZ
; Codex - 2026-07-16 - end

        PUSH DE
        LD HL,NXTBE-#0300
        LD DE,NXTBM-#0300
        LD BC,#0300:LDIR

        LD HL,DE,(CGPZ),HL
        LD B,NXTBZ/2:CALL LOAD512
        LD (HL),0
        POP DE
NxMR    JP 0

RMFL    LD C,32-11:ADD HL,BC:JP NXFL
RMFL1   LD C,32:ADD HL,BC:JP NXFL
; NXTETY — получить следующую полную запись активного каталога.
; Вход: DE — адрес выходного буфера.
; Выход: Z — конец каталога; NZ — запись создана, DE указывает за ней.
; Формат результата: первый кластер (4), размер (4), дата (2), время (2),
; инвертированный признак каталога, имя переменной длины и нулевой байт.
; Побочные эффекты совпадают с NXTETY2: обновляются CG* и поток LOAD512;
; выходной буфер заполняется последовательно командами LDI.
NXTETY

        PUSH DE
        LD A,(CGFL):OR A:CALL Z,NXTINI
        POP DE

        LD HL,NXFF,(NxMR+1),HL
NXFF    LD HL,(CGPZ),B,0
NXFL    LD A,H:CP high NXTBE:JR NC,NXMR
        LD A,(HL)
        OR A:RET Z
        CP #E5:JR Z,RMFL1

        LD C,11:ADD HL,BC
        LD A,(HL):BIT 3,A:JR NZ,RMFL
        EXA
        LD C,15:ADD HL,BC
 DUP 2
         LDI
 EDUP
        LD C,8:SBC HL,BC
 DUP 2
         LDI
 EDUP
        ADD HL,BC
 DUP 4
         LDI
 EDUP
        LD C,16:SBC HL,BC

 DUP 2
         LDI
 EDUP
 DUP 2
         DEC L
 EDUP

 DUP 2
         DEC L
 EDUP
 DUP 2
         LDI
 EDUP

        RES 4,L:CALL LNCRC

        EXA
        AND #10
        XOR #10:LD (DE),A:INC DE

NXTE2   OR A:LD C,32:SBC HL,BC:JP C,SNM
        LD A,(HL):CP #0F:JP NZ,SNM
        EXA

 DUP 2
         INC L
 EDUP
        CP (HL):JP NZ,SNM2

        LD C,1
        LD (CGHL),HL,(CGDE),DE
        LD A,L:AND #F0:LD L,A

LNPARS  LD A,(HL)
        BIT 6,A:JR Z,$+4:SET 6,C
        CP C:JR NZ,SNM3:INC C

        INC L
 DUP 5
         CALL UCH:JR NC,SNMX
 EDUP
 DUP 3
         INC L
 EDUP
 DUP 6
         CALL UCH:JR NC,SNMX
 EDUP
 DUP 2
         INC L
 EDUP
 DUP 2
         CALL UCH:JR NC,SNMX
 EDUP
        DEC L

        LD A,C:CP #40:JR NC,NXLEXI

        OR A:LD C,64-1:SBC HL,BC
        LD C,A:JR C,SNM3
        JR LNPARS

NXLEXI  XOR A:LD (DE),A:INC DE
        LD HL,(CGHL)
        LD C,32+16+3:ADD HL,BC
        LD (CGPZ),HL
Nhdd    XOR A:INC A
        RET

SNMX    JR NZ,NXLEXI
SNM3    LD HL,(CGHL),DE,(CGDE)
SNM2    LD A,L:AND #F0:LD L,A
        LD C,32:JR SNM+2
SNM     LD C,21:ADD HL,BC

Snm     LD B,8
SNA     LD A,(HL)
        CALL Acs:LD (DE),A:INC DE,L
        DJNZ SNA

        LD B,8
SNM_    DEC DE:LD A,(DE)
        CP " ":JR NZ,$+4:DJNZ SNM_
        INC DE

        LD A,L:AND #F0:OR 8:LD L,A
        PUSH DE
        LD A,".",(DE),A:INC DE
        LD A,(HL):CALL Acs:LD (DE),A:INC DE,L
        LD A,(HL):CALL Acs:LD (DE),A:INC DE,L
        LD A,(HL):CALL Acs:LD (DE),A:INC DE,L
        POP BC
        BIT 4,(HL):JR Z,SNMD
 DUP 3
         DEC DE:LD A,(DE):CP 32:JR NZ,SNm
 EDUP
        LD DE,BC
        JR SNMD
SNm     INC DE

SNMD    XOR A:LD (DE),A:INC DE
        LD BC,21:ADD HL,BC

        LD (CGPZ),HL
        XOR A:INC A
        RET
UCH     INC L
        LD A,(HL):OR A:JR NZ,UCHX
        DEC L:LD A,(HL):INC L,L
        OR A:JR Z,UCHE
        LD (DE),A:INC DE
        CP #80:RET C
UCH_    XOR A:RET
UCh_    INC L:XOR A:RET
UCHE    XOR A:INC A:RET

UCHX    CP 4:JR NZ,UCh_
        DEC L:LD A,(HL):INC L,L
        CP #01:JR Z,HYO
        CP #10:JR C,UCH_
        CP #3F+1:JR C,DGG
        CP #4F+1:JR C,DEE
        CP #51:JR Z,LYO
        XOR A
        RET
DGG     ADD A,#70:LD (DE),A:INC DE
        SCF:RET
DEE     ADD A,#A0:LD (DE),A:INC DE
        SCF:RET
HYO     LD A,#F0,(DE),A:INC DE:SCF:RET
LYO     LD A,#F1,(DE),A:INC DE:SCF:RET
Acs     CP #80:JR NC,RU3
        CP #40+1:RET C
        CP #5B:RET NC
        SET 5,A
        RET
RU3     CP #F0:JR NZ,$+3:INC A
        CP #F1:RET Z
        CP #A0:RET NC
        CP #90:JR NC,RU4
        SET 5,A:RET
RU4     ADD A,#50:RET
LNCRC   XOR A
 DUP 11
         RRCA:ADD A,(HL):INC L
 EDUP
        RET
NXTINI  LD HL,1
        LD (CGFL),HL

        LD HL,LSTCAT:CALL GIPAG

        LD HL,NXTBU,(CGPZ),HL,B,NXTBZ
        CALL LOAD512
        LD (HL),0
        RET

GENTRY
; Codex - 2026-07-17 - begin
        ; Три компактных шлюза занимают исходные 17 байт GENTRY/TENTRY и
        ; сохраняют адрес Z0. APPEND больше не лежит под рабочим стеком #5C00.
        CALL_WDOS_EXTENSION WDOS_EXT.ID_COPY_TO_ENTRY
        RET
TENTRY
        ; Копирование ENTRY одновременно запоминает точный сектор и слот,
        ; найденные SRHDRN. Контекст нужен последующему APPEND.
        CALL_WDOS_EXTENSION WDOS_EXT.ID_COPY_ENTRY_AND_CAPTURE
        RET
APPEND  CALL_WDOS_EXTENSION WDOS_EXT.ID_APPEND_BYTES
        RET
        NOP
        NOP
; Codex - 2026-07-17 - end
Z0      RET

GLSTCAT
        LD DE,LSTCAT,BC,4:LDIR
        LD (CGFL),BC
        RET

TLSTCAT
        LD HL,LSTCAT,BC,4:LDIR
        RET

RDD
        PUSH BC
        CALL XPOZI
        POP HL
; Codex - 2026-07-16 - begin
        JP SAFE_RDDSE
; Codex - 2026-07-16 - end

SDD
        PUSH BC
        CALL XPOZI
        POP HL
; Codex - 2026-07-16 - begin
        JP SAFE_SDDSE
; Codex - 2026-07-16 - end

; Codex - 2026-07-16 - begin
LOADNON LD DE,Z0
        CALL_WDOS_EXTENSION WDOS_EXT.ID_STREAM_WITH_HANDLER
        RET

LOAD256 LD DE,RDD256
        CALL_WDOS_EXTENSION WDOS_EXT.ID_STREAM_WITH_HANDLER
        RET

; SAVE512 — потоково записать B блоков по 512 байт из памяти с адреса HL.
; Вход и выход соответствуют LOAD512. На время вызова подменяет цель NW0 на
; Codex - 2026-07-17 - begin
; SAFE_SDDSE; общий эпилог затем нормализует цель к SAFE_RDDSE, а не к
; произвольному прежнему обработчику. Поэтому общий поток не реентерабелен.
; Codex - 2026-07-17 - end
; Побочные эффекты: пишет носитель и продвигает LTHL/LTDE, NSDC и текущую
; позицию драйвера по кластерной цепочке.
; Codex - 2026-07-17 - begin
; Нельзя оставлять страницу расширения #E0 в окне #C000 на время записи:
; PIO-драйвер Nemo читает буфер непосредственно оттуда. Обработчики чтения и
; записи лежат в одной странице #51, поэтому достаточно сменить младший байт.
SAVE512 LD A,low SAFE_SDDSE
        LD (NW0+1),A
        JP LOAD512
; Codex - 2026-07-17 - end
; Codex - 2026-07-16 - end

; LOAD512 — потоково прочитать B блоков по 512 байт в память с адреса HL.
; Если NSDC=EOC=0, начальный кластер берётся из CUHL/CUDE и позиционируется
; через GIPAG. Выход: HL — адрес сразу после обработанных данных; A — текущее
; значение EOC (ноль до конца цепочки). Побочные эффекты: LDHL хранит адрес
; буфера, LTHL/LTDE — LBA потока, NSDC — сектор внутри кластера; при переходе
; между кластерами читается FAT через CURIT. ABT сбрасывается в начале.
LOAD512

        XOR A:LD (ABT),A
        CALL LPREX:JR NZ,RH

        LD A,B:CALL NEWCLA
; Codex - 2026-07-16 - begin
; Codex - 2026-07-17 - begin
        ; Загрузки HL и A не меняют CF. При ошибке пропустить OR A, восстановить
        ; обработчик чтения и вернуть установленный перенос вызывающему коду.
; Codex - 2026-07-17 - end
; Codex - 2026-07-16 - end

RH      LD HL,(LDHL)
; Codex - 2026-07-16 - begin
; Codex - 2026-07-17 - begin
        ; Штатный EOC=#0F возвращается с CF=0; ошибка #FF сохраняет CF=1.
        LD A,(EOC)
        JR C,LOAD512_RESTORE_HANDLER
        OR A
LOAD512_RESTORE_HANDLER:
        JP STREAM_RESTORE_READ_HANDLER
; Codex - 2026-07-17 - end
; Codex - 2026-07-16 - end

LPREX   LD (LDHL),HL
        LD A,(EOC):OR A:RET NZ
        LD A,(NSDC):OR A:JR NZ,RX

        PUSH BC:LD HL,CUHL:CALL GIPAG
        POP BC
        RET
RX      XOR A
        RET
NEWCLA  LD (BZN),A

NXTC    LD HL,(LTHL),DE,(LTDE):CALL PROZ

        LD HL,BZN
        LD A,(BSECPC),BC,(NSDC)
        SUB C:LD B,A
        LD A,(HL):OR A:RET Z
        SUB B:JR NC,KN
        ADD A,B:LD B,A:XOR A
KN      LD (HL),A

        LD A,B,(NR0),A
        LD HL,(LDHL)
NW0     CALL SAFE_RDDSE
; Codex - 2026-07-16 - begin
        LD A,(ABT):OR A
        JR Z,LOAD512_IO_OK
        CALL_WDOS_EXTENSION WDOS_EXT.ID_STREAM_IO_ERROR
        RET
LOAD512_IO_OK:
; Codex - 2026-07-16 - end
        LD (LDHL),HL

        LD HL,LTHL,DE,LLHL,BC,4:LDIR

        LD HL,(LTHL),DE,(LTDE)
        LD BC,(NR0):ADD HL,BC:JR NC,$+3:INC DE
        LD (LTHL),HL,(LTDE),DE

        LD HL,NSDC,A,C:ADD A,(HL)
        LD (HL),A

        LD BC,(BSECPC)
; Codex - 2026-07-17 - begin
        ; NXTC находится в пределах JR; короткая ветка сохраняет раскладку
        ; следующих процедур после добавления общего восстановления NW0.
        CP C:JR C,NXTC
; Codex - 2026-07-17 - end

        LD HL,(CUHL),DE,(CUDE)
; Codex - 2026-07-17 - begin
        ; Короткая ветка компенсирует эпилог восстановления NW0 без сдвига ABI.
        CALL CURIT,GIPAG:JR Z,NXTC
; Codex - 2026-07-17 - end
        RET

SRHFCL  LD HL,FSTFRC,DE,CAHL,BC,4:LDIR
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_INIT_FREE_SCAN
; Codex - 2026-07-16 - end
SRHFC

        LD HL,(CAHL),DE,(CADE)
        CALL CURIT:RET C

; Codex - 2026-07-16 - begin
FC      CALL_WDOS_EXTENSION WDOS_EXT.ID_CHECK_FREE_SCAN_LIMIT
        RET C
; Codex - 2026-07-16 - end
        LD A,(HL):INC HL
        OR (HL):INC HL
        OR (HL):INC HL
        OR (HL):INC HL:JR Z,GETZE

        EX DE,HL
        LD HL,CAHL
; Codex - 2026-07-17 - begin
        INC (HL):JR NZ,AGA:INC HL
; Codex - 2026-07-17 - end
        INC (HL):JR NZ,AGA:INC HL
        INC (HL):JR NZ,AGA:INC HL
        INC (HL)
AGA     EX DE,HL
; Codex - 2026-07-17 - begin
        LD A,H:CP high SECBE:JR C,FC
; Codex - 2026-07-17 - end

; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_NEXT_FREE_FAT_SECTOR
        RET C
; Codex - 2026-07-16 - end
        JP FC
GETZE   EXX
        LD HL,(CAHL),DE,(CADE)
        PUSH HL:LD HL,CAHL:CALL INC4b
        POP HL
        XOR A
        RET

; CURIT — найти 32-битную FAT32-запись заданного кластера.
; Вход: DE:HL — номер кластера. Выход при успехе: CF=0, HL указывает на его
; четырёхбайтовую запись внутри SECBU; при выходе за BFTSZ возвращается CF=1.
; Побочные эффекты: вычисляет относительный сектор FAT в LSTSE, переводит его
; в абсолютный LBA через SFAT/ADDTOP и читает один сектор в SECBU.
CURIT

        CALL DEL128
 DUP 2
         SLA C:RL B
 EDUP

        PUSH BC
        LD (LSTSE+2),DE,(LSTSE),HL

; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_FAT_SECTOR_IN_RANGE
        JR NC,FATEND
JK      CALL_WDOS_EXTENSION WDOS_EXT.ID_POSITION_FAT_READ
; Codex - 2026-07-16 - end
; Codex - 2026-07-16 - begin
        LD HL,SECBU,A,1
        CALL_WDOS_EXTENSION WDOS_EXT.ID_READ_SECTORS
        JR C,FATEND
; Codex - 2026-07-16 - end
        POP BC
        LD HL,SECBU:ADD HL,BC
        XOR A
        RET
FATEND  POP BC
        SCF
        RET

; GIPAG — установить драйвер на первый сектор указанного кластера.
; Вход: HL указывает на четырёхбайтовый номер кластера. Нулевое значение
; заменяется корневым кластером BROOTC. Выход: Z — позиция вычислена; NZ —
; встретился маркер конца цепочки. Побочные эффекты: сбрасывает NSDC/EOC,
; сохраняет кластер в CUHL/CUDE, LBA в CLHL/CLDE и вызывает XPOZI.
GIPAG
        CALL TOS

        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A:OR H,E,D:JR Z,RDIR

; Codex - 2026-07-16 - begin
        EX DE,HL
        CALL_WDOS_EXTENSION WDOS_EXT.ID_CLASSIFY_FAT_LINK
        JR NC,GIPAG_LINK_VALID
        CALL_WDOS_EXTENSION WDOS_EXT.ID_FAT_LINK_ERROR
        RET
GIPAG_LINK_VALID:
        JR Z,MDC
; Codex - 2026-07-16 - end
POM     LD (CUHL),HL,(CUDE),DE

        LD BC,2:OR A:SBC HL,BC:JR NC,$+3:DEC DE

        LD A,(BSECPC):CALL UMNOX2
        LD BC,(SDFAT):CALL ADD4B
        EX DE,HL
        LD BC,(SDFAT+2):ADD HL,BC
        EX DE,HL
        CALL XSPOZ
        CALL XPOZI
        XOR A
        RET

RDIR    LD HL,(BROOTC),DE,(BROOTC+2)
        JR POM

; Codex - 2026-07-16 - begin
; Codex - 2026-07-17 - begin
; Штатный интерфейс WC завершает цикл COPYF только при A=#0F. Значение #FF
; зарезервировано расширением для ошибки потока и отличается установленным CF.
MDC     LD A,#0F
        LD (EOC),A
        OR A
        RET
; Codex - 2026-07-17 - end
; Codex - 2026-07-16 - end

XSPOZ   LD BC,(ADDTOP),(CLHL),BC
        LD BC,(ADDTOP+2),(CLDE),BC
        JP ADD4BF

SVHDFL

        LD A,(EFLG):AND #10
        CALL ENTREZ:RET NZ
        LD (CGDE),HL

        LD HL,(LSTCAT),DE,(LSTCAT+2)
SHDFL   LD (CUHL),HL,(CUDE),DE
        CALL TOS
NXDCL   LD HL,LOBU,B,1:CALL LOAD512
        LD HL,LOBU,DE,32,B,16
        XOR A
FIEL    CP (HL):JP Z,FELD
        ADD HL,DE
        DJNZ FIEL
; Codex - 2026-07-16 - begin
FIIL    LD A,(EOC):OR A:JR Z,NXDCL
; Codex - 2026-07-16 - end
        CALL SRHFCL:JR C,IEL
        LD (BUTS),HL,(BUTS+2),DE
        EXX
        LD A,#FF
        DEC HL:LD (HL),#0F
        DEC HL:LD (HL),A
        DEC HL:LD (HL),A
        DEC HL:LD (HL),A
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        JR NZ,IEL
; Codex - 2026-07-16 - end

        LD HL,(CUHL),DE,(CUDE)
        CALL CURIT:JR C,IEL
        EX DE,HL
        LD HL,BUTS,BC,4:LDIR
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        JR NZ,IEL
; Codex - 2026-07-16 - end

        LD HL,BUTS
        CALL GIPAG:LD A,255:RET NZ

        LD HL,SECBU,B,0
 DUP 2
         CALL NOPING
 EDUP

        LD HL,(LTHL),DE,(LTDE)
        PUSH HL,DE
; Codex - 2026-07-16 - begin
        LD HL,SECBU,A,1:CALL SAFE_SDDSE
        JR NZ,SVHDFL_ZERO_IO_ERROR

        LD A,(BSECPC)
        LD HL,SECBU
        CALL_WDOS_EXTENSION WDOS_EXT.ID_ZERO_CLUSTER_TAIL
        JR NZ,SVHDFL_ZERO_IO_ERROR
        POP DE,HL
        CALL XPOZI
        JP NXDCL

SVHDFL_ZERO_IO_ERROR:
        POP DE,HL
        JR IEL
; Codex - 2026-07-16 - end

IEL     LD A,16:OR A:RET

FELD    EX DE,HL
        LD HL,(CGDE)
VYG     LD BC,32:LDIR
        LD BC,0-64:ADD HL,BC
        LD A,H:CP high NXTBM:JR C,FFLD

        LD A,E:OR A:JR NZ,VYG
        BIT 0,D:JR NZ,VYG
        LD (CGDE),HL
        CALL FFld
; Codex - 2026-07-16 - begin
        RET NZ
; Codex - 2026-07-16 - end
        JP FIIL

FFLD    XOR A:LD (DE),A
FFld    LD HL,(LLHL),DE,(LLHL+2)
        CALL PROZ
        LD HL,LOBU
; Codex - 2026-07-16 - begin
        LD A,1:CALL SAFE_SDDSE
        RET NZ
; Codex - 2026-07-16 - end

        LD HL,(FCTS),DE,(FCTS+2)
        XOR A
        RET

ENTREZ

        LD DE,NXTBU
        LD BC,255+1
        PUSH DE
        LD (DE),A,(ENTRY+11),A:INC DE
        LDIR
        POP HL
        LD (CGDE),HL
        INC HL:CALL ENVAL:LD A,1:RET NZ

        LD HL,(FCTS),(CLSHL),HL
        LD HL,(FCTS+2),(CLSDE),HL

        LD HL,(CGDE):CALL LNLNGcs
        JP Z,ENnvl
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_REFINE_NAME_CLASSIFICATION
; Codex - 2026-07-16 - end

        LD B,11,HL,ENTRY
SNCC    LD A,(HL):OR A:JR Z,LONG
        CALL SNCEN:JR Z,LONG
        CALL CAPS_SV:JR Z,LONG
        CALL ACS:LD (HL),A
        INC HL:DJNZ SNCC

        LD HL,ENTRY
        LD DE,NXTBM
        PUSH DE:LD BC,33:LDIR
        LD HL,NXTBU:CALL SRHDRN:LD A,4
        POP HL:RET NZ
        XOR A
        RET
LONG    LD DE,ENTRY

        LD B,8,HL,NXTBU
FO      INC HL:LD A,(HL)
KO      CALL ACS
        CALL ENCEN:JR Z,KZ
        CALL SNCEN:JR NZ,KC
KZ      LD A,R:AND %01111111:JR KO
KC      CP " ":JR NZ,$+4:LD A,"_"
        LD (DE),A:INC DE:DJNZ FO
        PUSH DE:LD B,3:CALL NOP32
        POP DE

        LD HL,NXTBU:BIT 4,(HL):JR NZ,NN
        INC HL
        XOR A:LD BC,256:CPIR:DEC HL

        LD B,4
UR      DEC HL:LD A,(HL)
        OR A:JR Z,NN
        CP ".":JR Z,NB
        DJNZ UR:JR NN

NB      LD B,3
Nb      INC HL:LD A,(HL)
        CALL ACS,SNCEN:JR Z,NN
        LD (DE),A:INC DE:DJNZ Nb
NN      LD HL,ENTRY,DE,NXTBM,BC,32:LDIR
        LD DE,NXTBM+11,(CGDE),DE

        LD HL,NXTBM-32,A,#30
        LD B,5,(HL),A:INC HL:DJNZ $-2

BURA    LD HL,NXTBM-32+3
        PUSH HL:CALL INDEX:LD A,2
        POP HL:RET NZ

        LD DE,NXTBM+7
        LD BC,#03FF,A,#30
ZZBZ    LDD:CP (HL):JR Z,$+4:DJNZ ZZBZ
        LD A,#7E,(DE),A

        LD HL,NXTBM,DE,ENTRY,BC,12:LDIR
        CALL FNDSN:JR NZ,BURA

        LD HL,NXTBM
        CALL LNCRC:LD (CRC+1),A

        LD HL,NXTBM+32
        LD DE,NXTBU+1
        LD BC,#0001
DNB     LD (HL),C:INC C,HL
 DUP 5
         CALL OEM2UC
 EDUP
        LD (HL),#0F:INC HL
        LD (HL),#00:INC HL
CRC     LD (HL),0:INC HL
 DUP 6
         CALL OEM2UC
 EDUP
        LD (HL),#00:INC HL
        LD (HL),#00:INC HL
 DUP 2
         CALL OEM2UC
 EDUP
        LD A,(DE):OR A:JR NZ,DNB

        LD (HL),0
        LD BC,0-32:ADD HL,BC:SET 6,(HL)

        PUSH HL
        LD HL,NXTBU
        CALL SRHDRN:LD A,3
        POP HL:RET NZ
        XOR A
        RET
INDEX   LD B,3
XED     LD A,(HL):CP #39:JR C,DEX
        LD (HL),#30:DEC HL:DJNZ XED
        XOR A:INC A
        RET
DEX     INC (HL):XOR A:RET
FNLZ    LD (HL),B:INC HL
        LD (HL),B:INC HL
        LD B,#FF
        RET
OEM2UC  LD A,(DE):OR A:JR Z,FNLZ:INC DE
        PUSH BC
        LD C,A,B,0:CP #80:CALL NC,ORU
        LD (HL),C:INC HL
        LD (HL),B:INC HL
        POP BC
        RET
ORU     LD B,4
        CP #F0:LD C,#01:RET Z
        CP #F1:LD C,#51:RET Z
        CP #B0:JR NC,OR2
        SUB #70:LD C,A:RET
OR2     CP #F0:RET NC
        CP #E0:RET C
        SUB #A0:LD C,A:RET
; Codex - 2026-07-16 - begin
; Старая процедура отвергала ровно 255 символов. Реализация вынесена в
; расширение, а размер исходного диапазона сохранён для стабильности адресов.
ENVAL   CALL_WDOS_EXTENSION WDOS_EXT.ID_VALIDATE_NAME
        RET
ENnvl   LD A,1:OR A:RET
        DS 41-($-ENVAL),0
        ASSERT $-ENVAL == 41, изменился размер стабильного блока ENVAL
; Codex - 2026-07-16 - end
SNCEN   CP #2B:RET Z
        CP #2C:RET Z
        CP #2E:RET Z
        CP #3B:RET Z
        CP #3D:RET Z
        CP #5B:RET Z
        CP #5D:RET Z
        RET

ENCEN   CP #20:JR C,MU

        CP #22:RET Z
        CP #2A:RET Z
        CP #2F:RET Z
        CP #3A:RET Z
        CP #3C:RET Z
        CP #3E:RET Z
        CP #3F:RET Z
        CP #5C:RET Z
        CP #7C
        RET
MU      CP A
        RET

CAPS_SV CP "A":RET C
        CP "Z"+1:JR NC,CAPS_sv
        XOR A
        RET
CAPS_sv CP #80:RET C
        CP #9F+1:JR NC,CAPS_YO
        XOR A
        RET
CAPS_YO CP #F0:RET

ERG2    LD HL,FCTS:CALL DLSG
        LD HL,FCTS,DE,FSTFRC,BC,4:LDIR
ERG1    LD A,16:OR A
        RET
; MKSG — выделить FAT-цепочку для объекта длиной DE:HL байт.
; Вход: DE:HL — 32-битный размер. Выход: Z — цепочка записана; FCTS содержит
; её первый кластер, FSTFRC — следующую подсказку свободного кластера.
; При нехватке места возвращает NZ и A=16; уже собранная часть освобождается
; через DLSG. Побочные эффекты: GENBU временно хранит номера кластеров,
; CURIT/SDDSE читают и изменяют секторы FAT, LSTSE отслеживает текущий сектор.
MKSG

        CALL DEL512
        LD A,(BSECPC):CALL DELITX2

        LD (CLCNT+2),DE
        LD (CLCNT+0),HL

        CALL SGENBU:JR C,ERG1
ROSTIK  CALL PREPFC:JR C,ERG2
        CALL BUtoFAT:RET Z
        CALL SGENB2:JR C,ERG2
        JR ROSTIK
SGENBU  LD HL,GENBU,(GARY),HL

        CALL SRHFCL:RET C
        LD (FCTS),HL,(FCTS+2),DE
GENB    LD (FSTFRC),HL,(FSTFRC+2),DE

        LD A,H,C,L
        LD HL,(GARY)
        LD (HL),C:INC HL
        LD (HL),A:INC HL
        LD (HL),E:INC HL
        LD (HL),D:INC HL
        LD (GARY),HL
        XOR A
        RET
SGENB2  CALL SRHFC:RET C
        JR GENB
PREPFC  LD HL,(CLCNT):DEC HL
        LD (CLCNT),HL
        LD A,H:OR L:JR Z,EOFG

AMM     EXX
        LD A,H:CP high SECBE
        JR C,ARM
        CALL SRHFC:RET C
        JR AR2
ARM     CALL FC
AR2     LD (FSTFRC),HL,(FSTFRC+2),DE
        LD A,H,C,L
        LD HL,(GARY)
        LD (HL),C:INC HL
        LD (HL),A:INC HL
        LD (HL),E:INC HL
        LD (HL),D:INC HL
        LD A,H:CP high GENBE:RET NC
        LD (GARY),HL
        JP PREPFC
EOFG    LD HL,(CLCNT+2)
        LD A,H:OR L:JR NZ,AmM

        LD DE,#0FFF
        LD HL,(GARY)
        LD (HL),E:INC HL
        LD (HL),E:INC HL
        LD (HL),E:INC HL
        LD (HL),D:INC HL
        LD (GARY),HL
        RET
AmM     DEC HL:LD (CLCNT+2),HL:JR AMM
BUtoFAT LD HL,GENBU
GENFC   LD C,(HL):INC HL
        LD B,(HL):INC HL
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        PUSH HL
        LD HL,BC:CALL CURIT:EX DE,HL
        POP HL

GNFC    LD (UUHL),HL
        LD BC,4:LDIR

; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_IS_EOC_BEFORE_HL
        JR Z,LSTSR
        LD A,H:CP high GENBE:JR NC,LSTsr
; Codex - 2026-07-16 - end

        LD HL,(UUHL)
        LD C,(HL):INC HL
        LD B,(HL):INC HL
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD (BUHL),HL

        LD HL,BC:CALL DEL128
        LD BC,(LSTSE)
        OR A:SBC HL,BC:JR NZ,GGC
        EX DE,HL:LD BC,(LSTSE+2)
        OR A:SBC HL,BC:JR Z,GFC

; Codex - 2026-07-16 - begin
GGC     CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        RET NZ
; Codex - 2026-07-16 - end
        LD HL,(UUHL)
        JP GENFC

GFC     LD H,0,L,A
 DUP 2
         SLA L:RL H
 EDUP
        LD BC,SECBU:ADD HL,BC
        EX DE,HL
        LD HL,(BUHL)
        JR GNFC
; Codex - 2026-07-16 - begin
LSTSR   CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        RET NZ
; Codex - 2026-07-16 - end
        XOR A
        RET
LSTsr   CALL LSTSR
        LD HL,(UUHL),DE,GENBU,BC,4:LDIR
        LD (GARY),DE

        XOR A:INC A
        RET

; DLSG — освободить FAT-цепочку.
; Вход: HL указывает на четырёхбайтовый номер первого кластера.
; Процедура идёт по цепочке, сохраняет следующий номер в первых четырёх байтах
; LOBU, зануляет каждую FAT-запись и записывает изменённые секторы через SDDSE.
; FSTFRC сбрасывается в ноль; устойчивого прикладного значения флагов на выходе
; код не задаёт, результат записи определяется драйвером SDDSE.
DLSG

        LD DE,LOBU,BC,4:LDIR
        LD HL,0
        LD (FSTFRC),HL
        LD (FSTFRC+2),HL
LWT     LD HL,(LOBU),DE,(LOBU+2)
        LD A,D:OR E,H,L:RET Z
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_CLASSIFY_FAT_LINK
        RET Z
        JR NC,DLSG_LINK_VALID
        CALL_WDOS_EXTENSION WDOS_EXT.ID_FAT_LINK_ERROR
        RET
DLSG_LINK_VALID:
; Codex - 2026-07-16 - end

; Codex - 2026-07-16 - begin
        CALL CURIT
        JR NC,DLSG_ENTRY_VALID
        CALL_WDOS_EXTENSION WDOS_EXT.ID_FAT_LINK_ERROR
        RET
DLSG_ENTRY_VALID:
; Codex - 2026-07-16 - end
GOCE    LD DE,LOBU,C,0
 DUP 3
         LD A,(HL),(HL),C,(DE),A:INC L,E
 EDUP
        LD A,(HL),(HL),C,(DE),A

        LD HL,(LOBU),DE,(LOBU+2)
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_CLASSIFY_FAT_LINK
        JR Z,Ne
        JR C,DLSG_BAD_LINK
; Codex - 2026-07-16 - end
        CALL DEL128
        LD BC,(LSTSE)
        OR A:SBC HL,BC:JR NZ,NE:EX DE,HL
        LD BC,(LSTSE+2)
        OR A:SBC HL,BC:JR NZ,NE

        LD H,0,L,A
 DUP 2
         SLA L:RL H
 EDUP
        LD BC,SECBU:ADD HL,BC
        JP GOCE

; Codex - 2026-07-16 - begin
NE      CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        RET NZ
        JP LWT
Ne      CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        RET
; Codex - 2026-07-16 - end
; Codex - 2026-07-16 - begin
DLSG_BAD_LINK:
        CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        RET NZ
        CALL_WDOS_EXTENSION WDOS_EXT.ID_FAT_LINK_ERROR
        RET
; Codex - 2026-07-16 - end

; SRHDRN — найти запись по имени в активном каталоге LSTCAT.
; Вход: HL указывает на буфер [флаг, имя длиной 1..255, 0].
; Выход: Z — запись не найдена; NZ — ENTRY содержит 32-байтовую запись,
; DE:HL — номер её первого кластера, BC — адрес записи в LOBU или LOBU2.
; Побочные эффекты: LOBU/LOBU2 заполняются секторами каталога; CGDE хранит
; шаблон имени, а состояние CG*, LLHL и поток LOAD512 продвигаются по цепочке.
SRHDRN

        LD (CGDE),HL:CALL LNLNG:RET Z
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_REFINE_NAME_CLASSIFICATION
        CALL_WDOS_EXTENSION WDOS_EXT.ID_RESET_DIR_HISTORY
; Codex - 2026-07-16 - end

FNDSN   LD HL,LSTCAT,DE,CUHL,BC,4:LDIR
        CALL TOS

        LD HL,LOBU,B,1:CALL LOAD512

        LD HL,LOBU
ANNA    CALL ENTCH:JR Z,FND
        LD BC,32:ADD HL,BC
        LD A,H:CP high LOBU2:JR C,ANNA

; Codex - 2026-07-16 - begin
        ; Штатный конец цепочки имеет код #0F, ошибка потока — #FF. OR #F0
        ; сводит оба к #FF, а INC возвращает Z («не найдено») и не даёт
        ; полному каталогу уйти в бесконечное чтение после конца цепочки.
HDR     LD A,(EOC):OR #F0:INC A:RET Z
HDR_CONTINUE:
; Codex - 2026-07-16 - end
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_PREVIOUS_DIR_LBA
; Codex - 2026-07-16 - end
        PUSH HL
        LD HL,LOBU2,B,1:CALL LOAD512
        POP HL
AnnA    CALL ENTCH:JR Z,FND
        LD BC,32:ADD HL,BC
        LD A,H:CP high LOBE2:JR C,AnnA

; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_PRESERVE_OLDER_DIR_SECTOR
; Codex - 2026-07-16 - end
        EXX
        LD HL,LOBU2,DE,LOBU,BC,512:LDIR
        EXX:LD BC,0-512:ADD HL,BC
        JR HDR

FND     OR A:RET Z
        LD HL,(CLSHL)
        LD DE,(CLSDE)
        XOR A:INC A
        RET
NOP32   LD A," ",(DE),A:INC DE:DJNZ $-2
        RET
LNe     XOR A:RET
LNLNGcs LD A,#C9,(ACS),A
        CALL LNLNG
        EXA:XOR A:LD (ACS),A
        EXA
        RET
LNLNG   LD A,(HL):INC HL
        AND %11101111:JR NZ,LNe

        LD BC,256:XOR A:CPIR:JR NZ,LNe
        LD A,256-1:SUB C:JR Z,LNe

        LD HL,(CGDE)
        BIT 4,(HL):JR NZ,KAT

MURMUR  LD C,12+1:SUB C:JR NC,NESN
        ADD A,C
        LD C,A:ADD HL,BC

        EXA
        LD B,4,DE,ENTRY+8
FEL     LD A,(HL):DEC C:JR Z,FEL4
        CP ".":JR Z,FELE
        DEC HL:DJNZ FEL
FEL4    EXA
        LD C,A
        LD B,3
FEL3    CALL NOP32
FEL2    LD DE,ENTRY
        LD A,C:CP 8+1:JR NC,NESN

        LD B,A,A,8:SUB B:LD C,A
        LD HL,(CGDE)
FEEL    INC HL:LD A,(HL):CALL ACS
        LD (DE),A:INC DE:DJNZ FEEL

        LD B,C,A,B:OR A:CALL NZ,NOP32
        JR ENTch

FELE    LD B,3
FEL5    INC HL:LD A,(HL):OR A:JR Z,FEL3
        CALL ACS
        LD (DE),A:INC DE
        DJNZ FEL5
        JR FEL2
KAT     CP 3+1:JR NC,MURMUR
        LD C,A
        INC HL:LD A,(HL):CP "."
        DEC HL:LD A,C:JR NZ,MURMUR
        INC HL,HL:LD A,(HL):CP "."
        DEC HL,HL:LD A,C:JR NZ,MURMUR


        LD DE,ENTRY
        LD B,A,A,11:SUB B:LD C,A
KaT     INC HL:LD A,(HL):CALL ACS
        LD (DE),A:INC DE:DJNZ KaT

        LD B,C:CALL NOP32
        JR ENTch

NESN    XOR A:LD (ENTRY),A
ENTch   XOR A:INC A:RET
ENTCH   LD A,(HL)
        OR A:RET Z
        CP #E5:JR Z,ENTch

        LD A,L:ADD A,11:LD L,A
        BIT 3,(HL):JP NZ,ENTCHe

        LD DE,(CGDE)
        LD A,(HL):AND #10:LD B,A
        LD A,(DE):CP B:JP NZ,ENTCHe

        LD A,(ENTRY):OR A:JR Z,LNEB
        LD A,L:AND #F0:LD L,A
        LD B,11,DE,ENTRY
SNCH    LD A,(DE):CP (HL):JR NZ,LNEB
        INC DE,L:DJNZ SNCH
        JP ENTFND

LNEB    LD A,L:AND #F0:LD L,A
        CALL LNCRC
        LD (CGHL),HL

        LD BC,0-30:ADD HL,BC
; Codex - 2026-07-16 - begin
        CP (HL):JP NZ,ENTCHE
        LD A,H:CP high LOBU:JP C,ENTCHE
; Codex - 2026-07-16 - end
 DUP 2
         DEC L
 EDUP
; Codex - 2026-07-16 - begin
        LD A,(HL):CP #0F:JP NZ,ENTCHE
; Codex - 2026-07-16 - end

        LD DE,(CGDE):INC DE
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_BEGIN_LFN_COMPARE
; Codex - 2026-07-16 - end
        LD A,L:AND #F0:LD L,A

        LD B,1
LNPARZ  LD A,(HL)
        BIT 6,A:JR Z,$+4:SET 6,B
        CP B:JR NZ,ENTCHE:INC B

        INC L
 DUP 5
         CALL ULNP:JR NC,ENTST
 EDUP
 DUP 3
         INC L
 EDUP
 DUP 6
         CALL ULNP:JR NC,ENTST
 EDUP
 DUP 2
         INC L
 EDUP
 DUP 2
         CALL ULNP:JR NC,ENTST
 EDUP
        DEC L

        LD A,B:CP #40:JP NC,ENTFNDx

        LD BC,0-(64-1):ADD HL,BC:LD B,A
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_MAP_OLDER_LFN_POINTER
        JR C,ENTCHE
        JR LNPARZ
; Codex - 2026-07-16 - end
ENTST   JR NZ,ENTFNDL
ENTCHE  LD HL,(CGHL)
ENTCHe  LD A,L:AND #F0:LD L,A
        XOR A:INC A
        RET

ENTFNDx LD A,(DE):OR A:JR NZ,ENTCHE
ENTFNDL LD HL,(CGHL)
ENTFND  LD A,L:AND #F0:LD L,A
        PUSH HL:LD DE,ENTRY,BC,32:LDIR
        POP BC
; Codex - 2026-07-16 - begin
        XOR A:LD A,1
; Codex - 2026-07-16 - end
        RET
; Codex - 2026-07-16 - begin
ULNP    CALL_WDOS_EXTENSION WDOS_EXT.ID_COMPARE_LFN_CHAR
        RET
; Codex - 2026-07-16 - end
ACS     NOP
        CP #80:JR NC,RUS
        CP #60+1:RET C
        CP #7B:RET NC
        RES 5,A
        RET
RUS     CP #A0:RET C
        CP #B0:JR NC,RU2
        RES 5,A
        RET
RU2     CP #E0:RET C
        CP #F2:RET NC
        CP #F1:JR NZ,$+3:DEC A
        CP #F0:RET Z
        SUB #50
        RET
UCS     INC L
        LD A,(HL):OR A:JR NZ,UCSX
        DEC L:LD A,(HL):INC L,L
        OR A:JR Z,UCSE
        CP #80:RET C
UCS_    XOR A:RET
UCSE    LD A,#FF:RET

UCSX    CP 4:JR NZ,UCS_
        DEC L:LD A,(HL):INC L,L
        CP #01:JR Z,Hyo
        CP #10:JR C,UCS_
        CP #3F+1:JR C,Dgg
        CP #4F+1:JR C,Dee
        CP #51:JR Z,Lyo
        JR UCS_
Dgg     ADD A,#70:RET
Dee     ADD A,#A0:RET
Hyo     LD A,#F0:RET
Lyo     LD A,#F1:RET

; DELFL — удалить файл или каталог по имени.
; Вход: HL указывает на [флаг, имя, 0]. Выход: Z — запись не найдена;
; NZ — запись помечена #E5 и её кластерная цепочка освобождена.
; Побочные эффекты: DELEN записывает сектор каталога через STAMP, FCTS получает
; первый кластер удаляемого объекта, DLSG изменяет FAT. Проверка пустоты
; каталога здесь не выполняется и должна быть сделана вызывающим кодом.
DELFL

        CALL DELEN:RET Z
DELCHA  PUSH AF:LD HL,FCTS:CALL DLSG
        POP AF
        RET

DELEN   CALL SRHDRN:LD A,8:RET Z

        LD (FCTS+0),HL
        LD (FCTS+2),DE

; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_DELETE_ENTRY_WITH_LFN
        JR NZ,DELEN_WRITE_ERROR
; Codex - 2026-07-16 - end
        XOR A:INC A
        RET
; Codex - 2026-07-16 - begin
DELEN_WRITE_ERROR:
        XOR A
        RET
; Codex - 2026-07-16 - end
STAMP   PUSH HL
        LD HL,(LLHL),DE,(LLHL+2)
        CALL PROZ
        POP HL

; Codex - 2026-07-16 - begin
        LD A,1:JP SAFE_SDDSE
; Codex - 2026-07-16 - end
; RENAME — создать запись с новым именем и удалить старую.
; Вход: HL — [флаг, старое имя, 0], DE — новое имя с нулевым окончанием.
; Выход: NZ — переименование завершено; Z — старая запись не найдена либо
; новую запись создать не удалось. Побочные эффекты: FCTS сохраняет кластер,
; SVHDFL записывает новую запись, DELEN помечает старую запись #E5.
RENAME

        PUSH HL,DE
        CALL SRHDRN:LD A,8
        LD (FCTS+0),HL
        LD (FCTS+2),DE
        POP HL,DE:RET Z

        PUSH DE:CALL SVHDFL
        POP HL:JR NZ,ZIR

        CALL DELEN:RET Z

        XOR A:INC A:RET
ZIR     CP A:RET
; MKFILE — создать файл и выделить ему цепочку кластеров.
; Вход: HL указывает на [атрибут, размер DE:HL в четырёх байтах, имя, 0].
; Выход: Z — успех; NZ — ошибка выделения или записи каталога.
; Побочные эффекты: размер копируется в SIZIK, имя временно хранится через
; CGHL, MKSG изменяет FAT, SVHDFL создаёт ENTRY; при ошибке записи новая
; цепочка откатывается через DELCHA/DLSG.
MKFILE

        LD A,(HL),(EFLG),A:INC HL
        LD DE,SIZIK,BC,4:LDIR
        LD (CGHL),HL

        LD HL,(SIZIK),DE,(SIZIK+2)
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_ALLOCATE_FILE
        RET NZ
; Codex - 2026-07-16 - end
        LD HL,(CGHL)
        CALL SVHDFL:JP NZ,DELCHA
        XOR A
        RET

; MKDIR — создать каталог.
; Вход: HL указывает на имя с нулевым окончанием. Выход: Z — успех; NZ —
; ошибка выделения или записи записи каталога. Выделяется минимум один сектор,
; создаются записи «.» и «..», первый сектор каталога записывается из LOBU,
; остальные секторы кластера зануляются безопасным циклом расширения. Ошибка
; низкоуровневой записи немедленно возвращается как NZ.
MKDIR

        LD (CGHL),HL
        LD HL,0,(SIZIK),HL,(SIZIK+2),HL
        LD A,#10,(EFLG),A
        LD DE,0,HL,512
        CALL MKSG:RET NZ
        LD HL,(CGHL)
        CALL SVHDFL:JP NZ,DELCHA
        LD HL,FCTS
        CALL GIPAG

        LD HL,ENTRY
        LD (HL),".":INC HL
        LD (HL),#20:INC HL
        LD A,32,B,9:CALL NOPING+1
        LD HL,(CUHL),(CLSHL),HL
        LD HL,(CUDE),(CLSDE),HL
        LD HL,ENTRY,DE,LOBU,BC,32:LDIR

        LD HL,ENTRY+1
        LD (HL),"."
        LD HL,(LSTCAT),(CLSHL),HL
        LD HL,(LSTCAT+2),(CLSDE),HL
        LD HL,ENTRY,BC,32:LDIR

        LD HL,DE:INC DE
        LD BC,512
        LD (HL),0
        LDIR
        LD HL,LOBU
; Codex - 2026-07-16 - begin
        LD A,1:CALL SAFE_SDDSE
        RET NZ

        LD A,(BSECPC)
        LD HL,LOBU+64
        CALL_WDOS_EXTENSION WDOS_EXT.ID_ZERO_CLUSTER_TAIL
        RET NZ
; Codex - 2026-07-16 - end
        XOR A
        RET

; Codex - 2026-07-16 - begin
RFRH    CALL_WDOS_EXTENSION WDOS_EXT.ID_RFRH_SAFE
        RET
; Codex - 2026-07-16 - end
CHTOSE

        LD (DABC),BC
        LD (DADE),DE
CKAGO   LD (DAHL),HL

        CALL GIPP:RET Z
        CALL CLUSSEC
        LD DE,(DABC)
        OR A:SBC HL,DE:RET NC

        LD HL,(DAHL)
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A:EX DE,HL

        CALL CURIT
        JR CKAGO

CLUSSEC

        LD BC,HL
        LD A,(BSECPC)
        LD HL,(DADE)
USS     LD (HL),C:INC HL
        LD (HL),B:INC HL
        LD (HL),E:INC HL
        LD (HL),D:INC HL
        LD (DADE),HL:DEC A:RET Z

        INC BC
        EXA:LD A,B:OR C:JR NZ,$+3:INC DE
        EXA
        JR USS

GIPP

        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A:OR H,E,D:RET Z
; Codex - 2026-07-16 - begin
        EX DE,HL
        CALL_WDOS_EXTENSION WDOS_EXT.ID_CLASSIFY_FAT_LINK
        JR C,GIPP_BAD_LINK
        RET Z
; Codex - 2026-07-16 - end

        LD BC,2:OR A:SBC HL,BC:JR NC,$+3:DEC DE

        LD A,(BSECPC):CALL UMNOX2
        LD BC,(SDFAT):CALL ADD4B
        EX DE,HL
        LD BC,(SDFAT+2):ADD HL,BC
        EX DE,HL
        CALL XSPOZ

        XOR A:INC A
        RET
; Codex - 2026-07-16 - begin
GIPP_BAD_LINK:
        CALL_WDOS_EXTENSION WDOS_EXT.ID_RECORD_FAT_LINK_ERROR
        XOR A
        RET
; Codex - 2026-07-16 - end

; HDD — найти доступный раздел FAT32 и заполнить рабочие параметры BPB.
; Входных регистров нет; драйвер должен быть выбран и позиционироваться через
; XPOZI/RDDSE. Выход: Z — FAT32 найдена и параметры готовы; NZ — подходящий
; раздел или корректный BPB не найден. Распознаются типы #05/#0B/#0C/#0F,
; включая переход по цепочке расширенных разделов.
; Побочные эффекты: LOBU используется для MBR/загрузочного сектора; задаются
; ADDTOP, BSECPC, BREZS, FSINF, BFATS, BFTSZ, BROOTC, SFAT и SDFAT; текущие
; кластеры, каталог, CGFL и подсказка FSTFRC сбрасываются.
HDD

        LD HL,0,DE,HL
        LD (CUHL),HL,(CUDE),HL
        LD (DAHL),HL,(DADE),HL
        LD (DUHL),HL,(DUDE),HL
        CALL XPOZI
; Codex - 2026-07-16 - begin
        LD HL,LOBU,A,1:CALL SAFE_RDDSE
        RET NZ
; Codex - 2026-07-16 - end

        LD A,3,(COUNT),A,(ZES),A

        LD HL,LOBU+446+4,DE,16,B,4
KKO     LD A,(HL)
        CP #05:JR Z,OKK
        CP #0B:JR Z,OKK
        CP #0C:JR Z,OKK
        CP #0F:JR Z,OKK
        ADD HL,DE
        DJNZ KKO

; Codex - 2026-07-16 - begin
; После единственной попытки разобрать сектор 0 как superfloppy вернуть ошибку,
; а не снова переходить в Nhdd и бесконечно читать тот же неисправный BPB.
FHDD    LD A,(ZES):OR A:JR NZ,FHDD_EXTENDED
        INC A
        RET
FHDD_EXTENDED:
; Codex - 2026-07-16 - end

        LD DE,(DADE),HL,(DAHL)
        CALL XPOZI

; Codex - 2026-07-16 - begin
        LD HL,LOBU:LD A,1:CALL SAFE_RDDSE
        RET NZ
; Codex - 2026-07-16 - end

        LD HL,COUNT:DEC (HL):JP Z,NHDD

        LD HL,LOBU+446+16,B,16
        XOR A:OR (HL):INC HL:DJNZ $-2
        JP NZ,NHDD

        LD HL,(LOBU+446+16+8)
        LD DE,(LOBU+446+16+8+2)
        LD (CLHL),HL,(CLDE),DE
        LD HL,(DAHL),DE,(DADE)
        CALL ADD4BF
        LD (DADE),DE,(DAHL),HL
        CALL XPOZI

; Codex - 2026-07-16 - begin
        LD HL,LOBU,A,1:CALL SAFE_RDDSE
        RET NZ
; Codex - 2026-07-16 - end

        LD HL,(LOBU+446+8)
        LD DE,(LOBU+446+8+2)
        CALL ADD4BF
        JR LDBPB

OKK     INC HL,HL,HL,HL
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A
        EX DE,HL

LDBPB   LD (ADDTOP),HL,(ADDTOP+2),DE
        CALL XPOZI

        LD HL,LOBU
; Codex - 2026-07-16 - begin
        LD A,1:CALL SAFE_RDDSE
        RET NZ
; Codex - 2026-07-16 - end

        LD HL,(LOBU+11)
        LD A,H:DEC A,A:OR L:JP NZ,FHDD
        LD A,(LOBU+13):OR A:JP Z,FHDD
        LD A,(LOBU+14):OR A:JP Z,FHDD
        LD A,(LOBU+16):OR A:JP Z,FHDD

        LD HL,(LOBU+17),A,H:OR L
        LD HL,(LOBU+22):OR H,L
        JP NZ,FHDD
        LD HL,(LOBU+36):OR H,L
        LD HL,(LOBU+36+2):OR H,L
        JP Z,FHDD

        LD A,(LOBU+13),(BSECPC),A
        LD B,8:SRL A:JR C,NER:DJNZ $-4:LD A,1
NER     OR A:JP NZ,FHDD
        LD HL,(LOBU+14),(BREZS),HL
        LD HL,(LOBU+48),DE,0
        CALL XSPOZ
        LD (FSINF),HL,(FSINF+2),DE

; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_LOAD_FAT_CONFIG
        JP NZ,FHDD
; Codex - 2026-07-16 - end

        LD HL,(BFTSZ),DE,(BFTSZ+2)
        LD BC,(BFATS),B,0
        CALL UMN4B
        PUSH HL,DE
        LD HL,(BREZS)
        LD (SFAT),HL
        POP DE,BC
        CALL ADD4B
        LD (SDFAT),HL,(SDFAT+2),DE

        LD HL,0
        LD (CUHL),HL
        LD (CUDE),HL
        LD (LSTCAT),HL
        LD (LSTCAT+2),HL
        LD (CGFL),HL

        LD HL,FSTFRC,B,4:CALL NOPING

        CALL TOS
        RET

NHDD    LD HL,(DUHL),DE,(DUDE)
        XOR A:LD (ZES),A
        JP LDBPB

; DOS_SWP — активировать один из встроенных драйверов носителя.
; Вход: A=0 Nemo master, 1 SD ZC, 2 SD NGS, 3 SMUC master,
; A=4 SMUC slave, 5 Nemo slave, 6 второй SD ZC.
; Выбранный HR-packed блок DR1..DR4 распаковывается DEHR в DRVR=#3800;
; для slave-вариантов B преобразуется в A и передаётся SELDEV.
; Побочные эффекты: полностью заменяет таблицу и код драйвера по #3800,
; вызывает его SELDEV; IX сохраняется вокруг распаковки и выбора устройства.
DOS_SWP

        LD B,0
        LD HL,DR1:OR A:JR Z,DRR
        LD HL,DR2:DEC A:JR Z,DRR
        LD HL,DR3:DEC A:JR Z,DRR
        LD HL,DR4:DEC A:JR Z,DRR
        INC B:DEC A:JR Z,DRR
        LD HL,DR1:DEC A:JR Z,DRR
        LD HL,DR2

DRR     PUSH IX
        LD DE,DRVR
; Codex - 2026-07-16 - begin
; Расширение выполняет прежнюю распаковку и применяет проверенную runtime-
; заплатку только к SD-ZC. NOP сохраняет адреса GARY и четырёх packed-блоков.
        CALL_WDOS_EXTENSION WDOS_EXT.ID_UNPACK_DRIVER
        CALL SELDEV
        NOP
; Codex - 2026-07-16 - end
        POP IX
        RET

DEL128

        LD A,L:EXA
        LD A,L,L,H,H,E,E,D,D,0
        RLA
        RL L,H,E,D
        EXA
        AND 127
        LD B,0,C,A
        RET

DEL512
        LD A,L,L,H,H,E,E,D,D,0
        LD BC,1:OR A:CALL NZ,ADD4B
        LD A,2

DELITX2

        CP 2:RET C
        LD C,0
        SRL A
L33T    SRL D:RR E,H,L,C
        SRL A:JR NC,L33T

        LD A,C:OR A:RET Z
        LD BC,1

ADD4B   ADD HL,BC:RET NC:INC DE
        RET

UMNOX2

        CP 2:RET C
        SRL A
L33t    SLA L:RL H,E,D
        SRL A:JR NC,L33t
        RET

UMNOG
        LD DE,HL
        LD A,B,B,C,C,A:INC C
        XOR A:DEC B:JR Z,ODN
BSR     ADD HL,DE
        DJNZ BSR
ODN     LD B,A
        DEC C
        JR NZ,BSR
        RET

INC4b   LD B,4
EkE     INC (HL):RET NZ:INC HL:DJNZ EkE
        RET

ADD4BF
        EX DE,HL
        LD BC,(CLDE)
        ADD HL,BC
        EX DE,HL
        LD BC,(CLHL)
        ADD HL,BC:JR NC,KNH
        INC DE
KNH     LD (CLHL),HL
        LD (CLDE),DE
        RET

UMN4B
        LD A,B,B,C,C,A:INC C
        OR A:JR NZ,TEKNO
        DEC B:JR Z,UMN1
        INC B
TEKNO   XOR A
        CP B:JR NZ,TYS
        DEC C
TYS     DEC B
        PUSH HL,BC
        LD HL,DE
        CP B:JR Z,NEGRY
EFRO    ADD HL,DE
        DJNZ EFRO
        LD B,A
NEGRY   DEC C:JR NZ,EFRO
        LD (REZDE),HL
        POP BC,HL
        LD DE,HL
        CP B:JR Z,NEGRA
OFER    ADD HL,DE
        JR C,INCDE
ENJO    DJNZ OFER
        LD B,A
NEGRA   DEC C:JR NZ,OFER
        LD DE,(REZDE)
UMN1    RET
INCDE   EXX
        LD HL,(REZDE)
        INC HL
        LD (REZDE),HL
        EXX
        JR ENJO
TOS     XOR A:LD (NSDC),A,(EOC),A
        RET

NOPING  XOR A:LD (HL),A:INC HL:DJNZ $-2
        RET
; Codex - 2026-07-16 - begin
; Бывший NOPCLA полагался на продвижение LTHL/LTDE внутри XPOZI, но игнорировал
; результат SDDSE. Цикл перенесён в расширение и останавливается при ошибке.
; Компактная первая половина безопасных точек сбрасывает ABT, сохраняя число
; секторов и признак направления в AF.
SAFE_RDDSE:
        OR A
        JR SAFE_IO_PREPARE
SAFE_SDDSE:
        SCF
SAFE_IO_PREPARE:
        PUSH AF
        XOR A
        LD (ABT),A
        POP AF
        JP SAFE_IO_DISPATCH
        ASSERT $ <= #5115, исправления CORE32 пересекли служебные данные
        DS #5115-$,0
; Codex - 2026-07-16 - end
; Рабочие данные заключительной части ядра.
; GARY — текущая позиция в GENBU при построении цепочки MKSG.
; DABC/DAHL/DADE — временные 32-битные значения CHTOSE.
; ZES — состояние обхода расширенных разделов в HDD.
; Codex - 2026-07-16 - begin
; Состояние фиксированного расширения занимает часть прежнего нулевого
; промежутка; адреса исходных данных GARY и драйверов остаются неизменными.
EXT_LFN_LEADING            DS 1
EXT_DIR_PREVIOUS_LBA       DS 4
EXT_DIR_OLDER_LBA          DS 4
EXT_DIR_OLDER_VALID        DS 1
EXT_DIR_PREVIOUS_DIRTY     DS 1
EXT_DIR_OLDER_DIRTY        DS 1
EXT_DIR_EXPECTED_SEQUENCE  DS 1
EXT_DIR_LFN_CHECKSUM       DS 1

; Шлюз сохраняет оба набора AF/BC/DE/HL и IX в стековом кадре, поэтому
; вложенный вызов из MKSG/LOAD512 безопасен. IY не используется и остаётся
; неизменным. Байт номера функции читается из потока сразу после CALL.
EXTENSION_GATE:
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL
        PUSH IX
        EX AF,AF'
        EXX
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL
        EXX
        EX AF,AF'

        LD IX,0
        ADD IX,SP
        LD L,(IX+18)
        LD H,(IX+19)
        LD A,(HL)
        INC HL
        LD (IX+18),L
        LD (IX+19),H
        LD L,A

        LD A,I
        DI
        LD D,0
        JP PO,EXTENSION_GATE_IFF_SAVED
        INC D
EXTENSION_GATE_IFF_SAVED:
        LD BC,#13AF
        IN A,(C)
        LD E,A
        LD A,WDOS_EXTENSION_PAGE
        OUT (C),A
        PUSH DE
        JP WDOS_EXT.GATE_CONTINUE

        ASSERT EXTENSION_GATE == #5123, изменился фиксированный шлюз SD-ZC
; Codex - 2026-07-16 - begin
; Вторая половина безопасной точки выбирает исходный вход драйвера по CF.
; После возврата Z означает успех, NZ — ненулевой общий код ABT.
SAFE_IO_DISPATCH:
        JR NC,SAFE_IO_READ
        CALL SDDSE
        JR SAFE_IO_RESULT
SAFE_IO_READ:
        CALL RDDSE
SAFE_IO_RESULT:
        LD A,(ABT)
        OR A
        RET
; Codex - 2026-07-16 - end
        ASSERT $ <= #516D, исправления CORE32 не помещаются перед данными
        DS #516D-$,0
; Codex - 2026-07-16 - end
GARY    DS 2

DABC    DS 2
DAHL    DS 2
DADE    DS 2
ZES     NOP

; Четыре точных HR-packed драйвера. DR1=Nemo, DR2=SD ZC, DR3=SD NGS,
; DR4=SMUC; DOS_SWP выбирает master/slave режим после распаковки. Для ZC/NGS
; сохранены минимальные exact-потоки: доступный MHMT создаёт совместимые, но
; побайтно другие блоки. Распакованные ASM отдельно проверяются build.ps1.
DR1     INCBIN "DOSpNEMO.CPD"
; Codex - 2026-07-17 - begin
; На реальном Z-Controller экспериментальная замена низкоуровневого пути
; записи привела к общему отказу копирования и удаления, хотя Unreal принимал
; тот же обмен. В боевой сборке возвращён точный штатный HR-блок SD-ZC;
; высокоуровневые исправления FAT, каталогов и APPEND от него не зависят.
DR2     INCBIN "DOSpSDZC35.CPD"
        ASSERT $-DR2 == 676, изменился точный штатный HR-блок SD-ZC
; Codex - 2026-07-17 - end
DR3     INCBIN "DOSpSDNGS35.CPD"
DR4     INCBIN "DOSpSMUC.CPD"
; DEHR — распаковщик HR-блока.
; Вход: HL — адрес packed-заголовка, DE — адрес назначения. Заголовок содержит
; распакованный и packed-размеры; процедура при необходимости сдвигает поток,
; затем распаковывает данные вперёд в память DE. Выходной DE указывает за
; записанными данными. Изменяются AF, BC, DE, HL, IX и альтернативные регистры;
; DOS_SWP отдельно сохраняет IX вызывающего кода.
DEHR    INCLUDE "DEHR2.ASM"
        ASSERT DR1 == #5176
        ASSERT DR2 == #535D
        ASSERT DR3 == #5601
        ASSERT DR4 == #5933
        ASSERT DEHR == #5AAA
        ASSERT $ == #5BC7
; Codex - 2026-07-16 - begin
; Фиксированное продолжение шлюза обязано исполняться после отключения страницы
; #E0, поэтому оно находится в безопасном промежутке перед IM2 и стеком.
EXTENSION_GATE_AFTER:
; Codex - 2026-07-16 - begin
; Основной набор регистров остаётся в альтернативном наборе до конца эпилога.
; Возвращаемый AF' временно хранится в HL; иначе вложенный SD-вызов затирал
; находящийся в A' счётчик секторов номером восстанавливаемой страницы.
        EX AF,AF'
        EXX
        PUSH AF
        POP HL
        POP DE
        LD A,E
        LD BC,#13AF
        OUT (C),A
        LD A,D
        OR A
        DUP 9
        POP BC
        EDUP
        JR Z,EXTENSION_GATE_KEEP_DI
        PUSH HL
        POP AF
        EXX
        EX AF,AF'
        EI
        RET
EXTENSION_GATE_KEEP_DI:
        PUSH HL
        POP AF
        EXX
        EX AF,AF'
        RET
; Codex - 2026-07-16 - end
; Codex - 2026-07-17 - begin
; Общий поток всегда возвращается с обработчиком чтения. Сохранение HL не
; затрагивает возвращаемые AF/BC/DE и оставляет флаги штатного EOC либо ошибки.
STREAM_RESTORE_READ_HANDLER:
        PUSH HL
        LD HL,NW0+1
        LD (HL),low SAFE_RDDSE
        POP HL
        RET
; Codex - 2026-07-17 - end
        ASSERT $ <= #5BF4, шлюз пересёк физический хвост CORE32
; Codex - 2026-07-16 - end
END
; Codex - 2026-07-16 - begin
        ASSERT END <= #5BF4, нарушена рабочая длина WildDOS
; Codex - 2026-07-16 - end
        ENT
; Физический адрес условного перехода используется WC как точка подстановки
; в генерируемом фрагменте фильтра каталога. Само ядро видит её по #40CD,
; а внешний код обращается к исходному образу по #C0D9.
LC069_5 EQU CORE32 + DIR_FILTER_REJECT_BRANCH - START
        ASSERT LC069_5 == #C0D9, нарушен адрес подстановки фильтра каталога
; Codex - 2026-07-16 - begin
        ASSERT $ <= #DC00, нарушена физическая граница WildDOS
; Codex - 2026-07-16 - end
