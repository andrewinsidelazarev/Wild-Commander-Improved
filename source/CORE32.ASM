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
; таблицы в физической странице WC_PHYS_CORE32_EXT_PAGE. Шлюз сам сдвигает
; адрес возврата.
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
;   бит 7: выдавать только короткие имена;
;   бит 6: в полях битов 4 и 3 — время и дата ИЗМЕНЕНИЯ (+22/+24), а не
;          создания (с 2026-09-26; старое ядро бит не знает и отдаёт создание);
;   бит 4: добавить время создания (с битом 6 — изменения);
;   бит 3: добавить дату создания (с битом 6 — изменения);
;   бит 2: добавить размер;
;   биты 1..0: 0 — любая запись, 1 — файл, 2 — каталог, 3 — резерв.
; Выход: Z — конец каталога; NZ — запись помещена в буфер, DE указывает за
; ней. Формат: выбранные поля (размер 4, дата 2, время 2), признак, имя и
; завершающий ноль. Штамп не из календаря — 2026-01-01 00:00 (см. BT3).
; Z бывает и при отказе чтения: NXTINI/NXMR ставят ноль в начало
; непрочитанного, отличает его ABT≠0 (той страницы, где шло перечисление;
; до следующего обмена с носителем). Так же — недопустимый первый кластер
; каталога (GIPAG: ABT=#FE; NXTINI тогда не читает).
; Побочные эффекты: изменяет состояние итератора CG*, при необходимости читает
; продолжение цепочки через LOAD512. Маска целиком хранится операндом BT7, NxMR
; тоже самоподстановка, поэтому процедура не является повторно-входимой.
NXTETY2
; Claude - 2026-09-26 - begin
; Прежде каждый бит маски раскладывался в свой флаг BT* (по 9 байт на флаг);
; теперь маска — одним байтом, и её читают сами проверки. Освободившееся место
; — под дату и время записи (BT3): с битом 6 — изменения, штамп проверяется.
; Адреса NXTETY2 и NXTETY прежние.
        LD (BT7+1),A
; Claude - 2026-09-26 - end
        PUSH DE
        LD A,(CGFL):OR A:CALL Z,NXTINI
        POP DE

        LD HL,NXFF2,(NxMR+1),HL
NXFF2   LD HL,(CGPZ),B,0
NXFL2   LD A,H:CP high NXTBE:JP NC,NXMR         ; JP: за BT3 NXMR дальше JR
        LD A,(HL)
        OR A:RET Z
        CP #E5:JR Z,RMFL2

        LD C,11:ADD HL,BC
        LD A,(HL):BIT 3,A:JR NZ,RMFL2
        EXA
BT0     LD A,(BT7+1):AND %00000011:JR Z,BT1    ; биты 1..0 маски: тип записи
        DEC A:JR NZ,BT01
        EXA:BIT 4,A:JR NZ,RMFL2,Bt1
BT01    EXA:BIT 4,A
        JR Z,RMFL2

Bt1     EXA
BT1     LD C,16-11:ADD HL,BC
BT2     LD A,(BT7+1):AND %00000100:JR Z,BT3    ; бит 2 маски: размер
        LD C,28-16:ADD HL,BC
 DUP 4
         LDI
 EDUP
        LD C,16:SBC HL,BC

; Claude - 2026-09-26 - begin
; Бит 3 маски — дата записи, бит 4 — время; с битом 6 — изменения (+24, +22),
; без него — создания (+16, +14). Здесь HL — +16 записи, B=0. Штамп проходит
; CHECK_STAMP расширения: даты или времени нет в календаре — выводится
; 2026-01-01 00:00; сама запись в буфере не меняется. B=0 после вызова —
; снова (его ждёт NXTE2).
BT3     LD A,(BT7+1)
        BIT 6,A:JR Z,.creation
        LD C,8:ADD HL,BC                        ; +16 -> +24: изменение
.creation:
        PUSH HL
        PUSH DE
        LD E,(HL):INC L:LD D,(HL)               ; DE — дата
        DEC L:DEC L
        LD B,(HL):DEC L:LD L,(HL):LD H,B        ; HL — время
        PUSH AF
        CALL_WDOS_EXTENSION WDOS_EXT.ID_CHECK_STAMP
        POP AF
        EX (SP),HL                              ; HL — буфер, в стеке — время
        BIT 3,A:JR Z,.time
        LD (HL),E:INC HL:LD (HL),D:INC HL       ; дата
.time:
        POP DE
        BIT 4,A:JR Z,.done
        LD (HL),E:INC HL:LD (HL),D:INC HL       ; время
.done:
        EX DE,HL                                ; DE — за выводом
        POP HL                                  ; +16 или +24
        LD B,0
; Claude - 2026-09-26 - end

BT8     RES 4,L:RES 3,L                         ; +16 или +24 -> начало записи
        CALL LNCRC

        EXA:LD (DE),A:INC DE
BT7     LD A,0:RLA:JP NC,NXTE2                  ; операнд — маска, бит 7 — в CF
        LD A,L:AND #F0:LD L,A
        JP Snm

; Codex - 2026-07-16 - begin
; Claude - 2026-09-26 - begin
; Буфер NXTBU пройден: конец цепочки (EOC=#0F) или отказ чтения (#FF) — конец
; перечисления: Z, A=0, как у нулевой записи. Прежде «OR A:RET NZ» отдавал NZ
; без новой записи: полный каталог от 8 КиБ (ноль за последней записью
; попадал за NXTBE) перечислялся без конца. 2 байта — из выравнивания перед
; NXTETY.
NXMR    LD A,(EOC):CP 1:SBC A,A:RET Z           ; EOC=0: A=#FF, NZ — дальше
; Claude - 2026-09-26 - end
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
; Claude - 2026-09-21 - begin
; FAT_CACHE_GENERATION — поколение содержимого FAT, общее для всех файловых
; страниц (лежит в окне #4000). FAT_CACHE_BUMP увеличивает его при записи FAT,
; монтировании, смене и инициализации драйвера, начале чтения каталога.
; Страница, чей FATTAG не совпадает, перечитывает сектор FAT. Начало с 1:
; нулевой FATTAG свежей страницы (после DOS_SWP) никогда не совпадает, а
; старший байт #FF (метка CURIT_INVALIDATE) недостижим. С 2026-09-26 лежит
; здесь, в выравнивании перед NXTETY (данные: исполнение сюда не доходит —
; выше безусловный JP), — прежнее место перед SNCEN ушло под PLAIN_ALIAS.
FAT_CACHE_GENERATION:
        DB 1,0,0,0
; Claude - 2026-09-21 - end
; Claude - 2026-09-26 - begin
        ; NXTETY2 после переделки маски короче: вход NXTETY — на прежнем месте.
        ASSERT $ <= #413F, NXTETY2 не помещается перед NXTETY
        DS #413F-$,0
        ASSERT $ == #413F, сдвинулся вход NXTETY
; Claude - 2026-09-26 - end
; NXTETY — получить следующую полную запись активного каталога.
; Вход: DE — адрес выходного буфера.
; Выход: Z — конец каталога; NZ — запись создана, DE указывает за ней.
; Формат результата: первый кластер (4), размер (4), время изменения (2),
; дата изменения (2), инвертированный признак каталога, имя переменной длины
; и нулевой байт. Время и дата вместе — ключ сортировки панели по дате.
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
; Claude - 2026-09-24 - begin
        ; Время и дата ИЗМЕНЕНИЯ (+22, +24) подряд, как в записи FAT: панель
        ; показывает их в строке информации и сортирует по ним (Ctrl+F5) как по
        ; одному 32-битному ключу. Прежде здесь копировались дата и время
        ; создания (+16, +14). Размер фрагмента прежний: два байта — NOP.
        LD C,10:SBC HL,BC                       ; +32 -> +22
 DUP 4
         LDI
 EDUP
        LD A,L:AND #E0:LD L,A                   ; к началу записи
        NOP
        NOP
; Claude - 2026-09-24 - end
        CALL LNCRC

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
; Claude - 2026-09-21 - begin
        ; 13 символов записи LFN: 5, пропуск атрибута/типа/суммы, 6, пропуск
        ; кластера, 2. Прежние 13 развёрнутых CALL UCH заменены циклом UCHN:
        ; освобождённые 32 байта занимает проверка кэша FAT перед GENTRY.
        LD B,5:CALL UCHN:JR NC,SNMX
        INC L:INC L:INC L
        LD B,6:CALL UCHN:JR NC,SNMX
        INC L:INC L
        LD B,2:CALL UCHN:JR NC,SNMX
; Claude - 2026-09-21 - end
        DEC L

        LD A,C:CP #40:JR NC,NXLEXI

        OR A:LD C,64-1:SBC HL,BC
        LD C,A:JR C,SNM3
        JR LNPARS
; Claude - 2026-09-21 - begin
; UCHN — принять B символов UTF-16 подряд через UCH (HL — младший байт
; очередного символа, DE — выход). Выход: CF=1 — все B символов приняты;
; CF=0 — отказ UCH с его же Z/NZ (Z — несовпадение, NZ — конец имени), как
; ждёт SNMX. B=0 на обоих выходах: ниже BC служит смещением при B=0.
; С 2026-09-25 — через UCH_BOUNDED: на 255-м знаке поля CGDE имя кончается
; (повреждённый каталог с LFN длиннее 255 писал за поле вызывающего).
UCHN    CALL UCH_BOUNDED:JR NC,UCHN_STOP
        DJNZ UCHN
        SCF
        RET
UCHN_STOP:
        LD B,0
        RET
; Claude - 2026-09-21 - end

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
; Codex - 2026-09-08 - begin
; Три одинаковых преобразования сведены в цикл. Освободившийся участок вместе
; с прежними четырьмя NOP хранит обработчик ошибки поиска; SNMD не сдвигается.
; Claude - 2026-09-21 - begin
; С 2026-09-21 весь участок NXLEXI..NXTINI сдвинут на 32 байта вниз циклом
; UCHN в LNPARS; внешних ссылок на эти адреса нет, GENTRY и далее на месте.
; Claude - 2026-09-21 - end
SFN_EXTENSION_START:
        LD B,3
SFN_EXTENSION_CHAR:
        LD A,(HL):CALL Acs:LD (DE),A:INC DE,L
        DJNZ SFN_EXTENSION_CHAR
        POP BC
        JR SFN_EXTENSION_TRIM
; Обычный FENTRY сохраняет Z="не найдено" при I/O-ошибке. Во время ENTREZ
; нулевая маска типов даёт NZ, чтобы ошибку нельзя было принять за свободное
; имя. CF отличает ошибку от занятого SFN и останавливает подбор суффикса.
FIND_IO_ERROR:
        LD A,(FIND_TYPE_MASK+1)
        CP #10
        LD A,#FF
        SCF
        RET
        DS SFN_EXTENSION_START+26-$,0
        ASSERT $ == SFN_EXTENSION_START+26, изменился размер SFN formatter
SFN_EXTENSION_TRIM:
; Codex - 2026-09-08 - end
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
NXTINI
; Claude - 2026-09-21 - begin
        ; Новое перечисление каталога (выбор каталога, обновление панелей после
        ; плагина) снимает кэш FAT всех страниц. Это страховка от плагинов,
        ; которые пишут FAT мимо SAVE_FAT_SECTOR прямыми вызовами драйвера.
        CALL FAT_CACHE_BUMP
; Claude - 2026-09-21 - end
        LD HL,1
        LD (CGFL),HL

; Claude - 2026-09-27 - begin
        ; Прежде «LD HL,LSTCAT:CALL GIPAG». DIR_LIST_OPEN сначала проверяет
        ; цепочку каталога (DIR_CHAIN расширения): замкнутая или уходящая за
        ; том вешала перечисление (Codex R26-02); испорчена — как отказ
        ; GIPAG (CF=1, ABT=#FE), дальше CALL NC,LOAD512 не читает. Длина та же.
        CALL_WDOS_EXTENSION WDOS_EXT.ID_DIR_LIST_OPEN
        DS 2,0
; Claude - 2026-09-27 - end

        LD HL,NXTBU,(CGPZ),HL,B,NXTBZ
; Claude - 2026-09-26 - begin
        ; Недопустимый первый кластер (GIPAG: CF=1, ABT=#FE, EOC=#FF) — не
        ; читать: LOAD512 обнулил бы ABT, и отказ выглядел бы пустым каталогом
        ; (Codex R24-01: F5 такого каталога — пустая копия без сообщения).
        ; Ноль в начале NXTBU — конец перечисления, ABT остаётся. Флаги GIPAG
        ; команды LD выше не меняют; длина прежняя.
        CALL NC,LOAD512
; Claude - 2026-09-26 - end
        LD (HL),0
        RET

; Claude - 2026-09-21 - begin
; STREAM_CACHE_GEN — вторая половина проверки кэша сектора FAT (первая —
; STREAM_CACHE_SECTOR): признак страницы FATTAG равен текущему поколению
; FAT_CACHE_GENERATION, то есть после чтения сектора потоком FAT никто не
; писал, том и драйвер не менялись.
; Вход: A — номер записи в секторе FAT (0..127). Выход: Z — кэш действителен,
; HL = SECBU+4*A (адрес записи, как у CURIT); NZ — перечитать сектор.
; Разрушает BC, DE; при Z флаг CF=0.
STREAM_CACHE_GEN:
        LD C,A
        LD HL,FAT_CACHE_GENERATION
        LD DE,FATTAG
        LD B,4
STREAM_CACHE_GEN_BYTE:
        LD A,(DE)
        CP (HL)
        RET NZ
        INC HL
        INC DE
        DJNZ STREAM_CACHE_GEN_BYTE
        ; Адрес записи = (SECBU/1024*256+A)*4, поэтому SECBU кратен 1024.
        ASSERT SECBU % 1024 == 0, SECBU должен быть кратен 1024
        LD L,C
        LD H,SECBU/1024
        ADD HL,HL
        ADD HL,HL
        RET

; DEVINI_INVALIDATE — вход +#03 таблицы START. DEVINI драйверов IDE Nemo/SMUC
; читает IDENTIFY прямо в #3000 (SECBU), поэтому кэш FAT сбрасывается до
; вызова драйвера. Входных регистров у DEVINI нет.
DEVINI_INVALIDATE:
        CALL FAT_CACHE_BUMP
        JP DEVINI
        ; GENTRY/TENTRY/APPEND/Z0 и следующие входы остаются на прежних адресах.
        ASSERT $ <= #4350, проверка кэша FAT не помещается перед GENTRY
        DS #4350-$,0
        ASSERT $ == #4350, сдвинулся GENTRY
; Claude - 2026-09-21 - end
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
; Нельзя оставлять страницу расширения в окне #C000 на время записи:
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
; Claude - 2026-09-21 - begin
        ; Переход к следующему кластеру: сначала кэш сектора FAT в SECBU этой
        ; страницы, при промахе — прежний путь расширения, где CF от CURIT
        ; проверяется до разыменования записи в GIPAG.
        CALL STREAM_NEXT_CACHED
; Claude - 2026-09-21 - end
        JR Z,NXTC
        RET
; Claude - 2026-09-21 - begin
        ; SRHFCL остаётся на прежнем адресе: на него ссылается FILEX.WMF.
        DS 1,0
        ASSERT $ == #4449, сдвинулся SRHFCL
; Claude - 2026-09-21 - end

SRHFCL  LD HL,FSTFRC,DE,CAHL,BC,4:LDIR
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_INIT_FREE_SCAN
; Codex - 2026-07-16 - end
SRHFC

        ; Общий переход проверяет границу data-области и выполняет wrap,
        ; в том числе после заполнения GENBU или свободного последнего слота.
        CALL_WDOS_EXTENSION WDOS_EXT.ID_NEXT_FREE_FAT_SECTOR
        RET C

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
; Claude - 2026-09-21 - begin
        ; Тот же 32-битный инкремент CADE:CAHL, что и в GETZE. B и DE здесь
        ; не живут: CHECK_FREE_SCAN_LIMIT на каждом шаге FC и так их разрушает.
        CALL INC4b
        EX DE,HL
        LD A,H:CP high SECBE:JR C,FC
        ; SRHFC — ровно прежний хвост: переход к следующему сектору FAT с
        ; проверкой границы и wrap (NEXT_FREE_FAT_SECTOR), RET C, затем FC.
        JR SRHFC
; Claude - 2026-09-21 - end
GETZE   EXX
        LD HL,(CAHL),DE,(CADE)
        PUSH HL:LD HL,CAHL:CALL INC4b
        POP HL
        XOR A
        RET

; Claude - 2026-09-21 - begin
; STREAM_NEXT_CACHED — переход потока LOAD512/SAVE512 (и LOADNON/LOAD256) к
; следующему кластеру цепочки. Вход: DE:HL — текущий кластер (CUHL/CUDE).
; Выход как у GIPAG: Z — следующий кластер установлен; NZ/CF=0 — EOC (#0F);
; CF=1 — ошибка FAT/носителя (ABT/EOC выставлены).
; Попадание: SECBU этой страницы уже хранит сектор FAT этого кластера (LSTSE)
; и FATTAG совпадает с поколением FAT. Тогда нет ни чтения сектора, ни трёх
; шлюзов CURIT; GIPAG получает ту же запись в SECBU, что вернул бы CURIT.
; Промах: прежний STREAM_NEXT_CLUSTER (CURIT с чтением, проверка CF, пометка
; FAT_CACHE_TAG, GIPAG).
STREAM_NEXT_CACHED:
        PUSH DE
        PUSH HL
        CALL STREAM_CACHE_SECTOR
        CALL Z,STREAM_CACHE_GEN
        JR NZ,STREAM_NEXT_MISS
        POP BC
        POP BC
; Claude - 2026-09-27 - begin
        ; Прежде JP GIPAG: нулевая ссылка (свободный кластер) уходила в ветвь
        ; RDIR — поток шёл по корневому каталогу (Codex R26-03). STREAM_LINK
        ; расширения отвергает ноль и зовёт GIPAG. 2 байта — из добивки
        ; перед CURIT.
        CALL_WDOS_EXTENSION WDOS_EXT.ID_STREAM_LINK
        RET
; Claude - 2026-09-27 - end
STREAM_NEXT_MISS:
        POP HL
        POP DE
        CALL_WDOS_EXTENSION WDOS_EXT.ID_STREAM_NEXT_CLUSTER
        RET
; Claude - 2026-09-21 - end

; CURIT — найти 32-битную FAT32-запись заданного кластера.
; Вход: DE:HL — номер кластера. Выход при успехе: CF=0, HL указывает на его
; четырёхбайтовую запись внутри SECBU; при выходе за BFTSZ возвращается CF=1.
; Побочные эффекты: вычисляет относительный сектор FAT в LSTSE, переводит его
; в абсолютный LBA через SFAT/ADDTOP и читает один сектор в SECBU.
; Claude - 2026-09-21 - begin
; CURIT по-прежнему читает сектор при каждом вызове; кэшем SECBU пользуется
; только переход потока STREAM_NEXT_CACHED. Сам CURIT снимает признак кэша
; FATTAG страницы, поэтому правки SECBU после него кэшу не видны.
; Claude - 2026-09-21 - end
; Вход CURIT зафиксирован: на #44A5 ссылаются внешние плагины и заголовок
; этого файла. Изменения выше (потоковый переход по FAT, голова SRHFC)
; поглощаются добивкой, как это сделано перед SNCEN.
        ASSERT $ <= #44A5, исправления перед CURIT не помещаются
        DS #44A5-$,0
        ASSERT $ == #44A5, сдвинулся фиксированный вход CURIT
CURIT

; Claude - 2026-09-21 - begin
        ; Любой вызов CURIT снимает признак кэша FAT страницы до того, как ниже
        ; изменятся LSTSE и SECBU: вызывающий код вправе править запись в SECBU.
        ; Поток после удачного чтения снова помечает сектор (FAT_CACHE_TAG).
        CALL CURIT_INVALIDATE           ; FATTAG недействителен, затем DEL128
; Claude - 2026-09-21 - end
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
        ASSERT $ == #44D7, сдвинулся фиксированный вход GIPAG
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
; Первый кластер — маркер конца цепочки: EOC=#0F, NZ, CF=0 (пустая цепочка).
; Значение #FF зарезервировано расширением для ошибки потока и отличается
; установленным CF. (Цикл COPYF давно ведёт размер — COPY_CHUNK, не A=#0F.)
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
        CALL ENTREZ_ANY_TYPE:RET NZ
        LD (CGDE),HL

; Claude - 2026-09-27 - begin
        ; Прежде «LD HL,(LSTCAT),DE,(LSTCAT+2):LD (CUHL),HL,(CUDE),DE:CALL
        ; TOS». DIR_STREAM_OPEN — то же после проверки цепочки каталога:
        ; замкнутая цепочка вешала поиск места под запись (Codex R26-02);
        ; испорчена — отказ носителя до любой записи. Длина та же.
SHDFL   CALL_WDOS_EXTENSION WDOS_EXT.ID_DIR_STREAM_OPEN
        JP C,SVHDFL_READ_ERROR
        DS 10,0
; Claude - 2026-09-27 - end
; Claude - 2026-09-26 - begin
; Отказ чтения сектора каталога (CF=1, EOC=#FF) прежде не проверялся: FIEL
; искал свободное место в прежнем содержимом LOBU, а FIIL принимал EOC=#FF
; за конец цепочки и продлевал каталог за текущим кластером — ссылка FAT на
; остаток каталога затиралась, записи чужих файлов пропадали, а операция
; сообщала успех; бывало и так, что новая запись ложилась за маркером конца
; каталога и была не видна (аудит, А.1). Теперь — выход с ошибкой носителя
; (A=#FF) до любой записи.
; LOAD512 оставляет в L ноль (HL — за целым сектором), поэтому хватает LD H.
NXDCL   LD HL,LOBU,B,1:CALL LOAD512
        JP C,SVHDFL_READ_ERROR
        LD H,high LOBU
        LD DE,32,B,16
; Claude - 2026-09-26 - end
        XOR A
FIEL    CP (HL):JP Z,FELD
        ADD HL,DE
        DJNZ FIEL
; Claude - 2026-09-27 - begin
; Свободного места нет. Не конец цепочки — читать дальше; конец — продлить
; каталог (DIR_GROW расширения): не дальше 4096 секторов (65536 записей
; FAT32) — иначе после записи проверка цепочки (DIR_CHAIN) отвергла бы каталог
; целиком (Codex R27-01); затем SRHFCL, как прежде. Каталог полон или нет
; места — A=16, отказ чтения FAT при поиске — A=#FF: выход RET C. Длина
; прежняя (было «LD A,(EOC):OR A:JR Z,NXDCL:CALL SRHFCL:JR C,IEL»).
FIIL    CALL_WDOS_EXTENSION WDOS_EXT.ID_DIR_GROW
        JR Z,NXDCL
        RET C
        DS 4,0
; Claude - 2026-09-27 - end
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

; Claude - 2026-09-26 - begin
; Новый кластер уже занят (EOC), но ещё не в цепочке каталога. Прежде он
; вписывался в цепочку до обнуления: отказ записи нулей оставлял в каталоге
; прежнее содержимое свободного кластера — обрывки записей удалённых файлов
; становились живыми, и F8 по такой записи освобождал цепочку чужого файла
; (аудит, А.2). Теперь сначала обнуление, потом ссылка: отказ до ссылки —
; каталог прежний, кластер потерян; ссылка легла или нет — кластер пустой.
; Нули пишутся из LOBU: его всё равно перечитывает NXDCL, а сектор FAT в
; SECBU затирать незачем. GIPAG меняет CUHL/CUDE, поэтому последний кластер
; каталога — в стек.
        LD HL,(CUHL),DE,(CUDE)
        PUSH HL,DE
        LD HL,BUTS
        CALL GIPAG
        JR NZ,SVHDFL_ZERO_IO_ERROR

        LD HL,LOBU,B,0
 DUP 2
         CALL NOPING
 EDUP
        LD HL,LOBU,A,1:CALL SAFE_SDDSE
        JR NZ,SVHDFL_ZERO_IO_ERROR

        LD A,(BSECPC)
        LD HL,LOBU
        CALL_WDOS_EXTENSION WDOS_EXT.ID_ZERO_CLUSTER_TAIL
        JR NZ,SVHDFL_ZERO_IO_ERROR

        POP DE,HL                               ; последний кластер каталога
        CALL CURIT:JR C,IEL
        EX DE,HL
        LD HL,BUTS,BC,4:LDIR
        CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        JR NZ,IEL

        ; Поток — на начало нового кластера. Тот же GIPAG выше уже прошёл для
        ; этого же кластера, поэтому без проверки.
        LD HL,BUTS
        CALL GIPAG
        JP NXDCL

SVHDFL_ZERO_IO_ERROR:
        POP DE,HL
SVHDFL_READ_ERROR:
        LD A,#FF:OR A:RET                       ; отказ носителя
; Claude - 2026-09-26 - end

IEL     LD A,16:OR A:RET
; Claude - 2026-09-26 - begin
        ; Блок сохраняет прежнюю длину: FELD и всё за ней — на прежних
        ; адресах (старый FILEX.WMF с новым ядром работает по-прежнему).
        ASSERT $ <= #45FB, SVHDFL не помещается перед FELD
        DS #45FB-$,0
        ASSERT $ == #45FB, сдвинулась FELD
; Claude - 2026-09-26 - end

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
; Claude - 2026-09-26 - begin
        INC HL
        CALL_WDOS_EXTENSION WDOS_EXT.ID_VALIDATE_NAME   ; прежде — через ENVAL
        LD A,1:RET NZ
; Claude - 2026-09-26 - end

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
; Claude - 2026-09-26 - begin
; Имя укладывается в 8.3 и в короткую запись не шло лишь из-за заглавных букв
; (их сохраняет длинное имя) — короткое имя делается из самого этого имени,
; заглавными, без «~n», если такого в каталоге нет (PLAIN_ALIAS расширения;
; так делает и Windows). Прежде у «boot.$C» выходило «BOOTJ$~1.$C», и ПЗУ, что
; ищет в корне короткое «BOOT    $C», файла не находило. Иначе — «~n», как
; прежде. CF — каталог не прочитан (как у FIND_ALIAS ниже).
LONG    CALL_WDOS_EXTENSION WDOS_EXT.ID_PLAIN_ALIAS
        RET C
        JP Z,LFN_ENTRIES
; Claude - 2026-09-26 - end
        LD DE,ENTRY

; Основа 8.3 — 8 знаков подряд из NXTBU+1 (и за концом короткого имени):
; недопустимый знак и ноль заменяются случайным допустимым (LD A,R). Хвост
; NXTBU за концом имени обнулён (VALIDATE_NAME, с 2026-09-25) — прежде сюда
; попадали остатки прежнего имени из буфера вызывающего («A» → AZPRIV~1).
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
; Claude - 2026-09-25 - begin
        ; Прежде CALL ACS,SNCEN: конец имени (0) и управляющие знаки проходили
        ; в расширение 8.3 — у «README.md» оно было «MD»+#00, у однобуквенного
        ; ещё и байт буфера за концом имени: недопустимые в DIR_Name байты.
        ; Теперь расширение на таком знаке кончается. Длина та же — адреса
        ; дальше не сдвигаются.
        CALL SFN_EXT_CHAR
        NOP:NOP:NOP
; Claude - 2026-09-25 - end
        JR Z,NN
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
; Codex - 2026-09-08 - begin
; После очередной цифры можно закончить только если ОБЕ оставшиеся слева
; позиции нулевые. Одиночный ноль десятков в 100..109 не завершает число.
ZZBZ    LDD:CP (HL):JR NZ,SUFFIX_MORE
        DEC HL:CP (HL):INC HL
        JR Z,SUFFIX_DONE
SUFFIX_MORE:
        DJNZ ZZBZ
SUFFIX_DONE:
; Codex - 2026-09-08 - end
        LD A,#7E,(DE),A

        LD HL,NXTBM,DE,ENTRY,BC,12:LDIR
        CALL FIND_ALIAS:RET C:JR NZ,BURA

LFN_ENTRIES:
        LD HL,NXTBM
        CALL LNCRC:LD (CRC+1),A

        LD HL,NXTBM+32
        LD DE,NXTBU+1
        LD BC,#0001
DNB     LD (HL),C:INC C,HL
        CALL OEM5UC
        LD (HL),#0F:INC HL
        LD (HL),#00:INC HL
CRC     LD (HL),0:INC HL
        CALL OEM6UC
        LD (HL),#00:INC HL
        LD (HL),#00:INC HL
        CALL OEM2UC_PAIR
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
; Codex - 2026-09-08 - begin
; Общие хвосты вместо 13 развёрнутых CALL. B по-прежнему хранит 0/#FF для
; UTF-16 terminator/padding; счётчик DJNZ здесь использовать нельзя.
OEM6UC  CALL OEM2UC
OEM5UC  CALL OEM2UC
        CALL OEM2UC
        CALL OEM2UC
OEM2UC_PAIR:
        CALL OEM2UC
; Codex - 2026-09-08 - end
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
; расширение (ID_VALIDATE_NAME); с 2026-09-26 его зовёт сам ENTREZ, прокладка
; ENVAL убрана — её байты ушли под вход PLAIN_ALIAS в LONG.
ENnvl   LD A,1:OR A:RET
; Codex - 2026-09-08 - begin
; Создание записи проверяет единое пространство SFN/LFN файлов и каталогов.
; WildDOS уже не реентерабелен (ACS, NW0, буферы поиска). Маска меняется только
; на время ENTREZ и восстанавливается при любом его возврате, включая ошибку.
; Входной A=тип и весь возвращаемый AF сохраняются.
ENTREZ_ANY_TYPE:
        PUSH AF
        XOR A:LD (FIND_TYPE_MASK+1),A
        POP AF
        CALL ENTREZ
        PUSH AF
        LD A,#10:LD (FIND_TYPE_MASK+1),A
        POP AF
        RET
; Для сравнения кандидата также с существующими LFN нужен настоящий текст
; SFN, а не атрибут и следующие за ним метаданные NXTBM. Snm уже умеет OEM,
; точку и пробельное дополнение. Запрос занимает #0FF0..#0FFD; трёхзначный
; счётчик лежит отдельно по #0FE1..#0FE3, исходный LFN остаётся в NXTBU.
FIND_ALIAS:
        LD HL,NXTBM,DE,NXTBM-16+1
        CALL Snm
        LD HL,NXTBM-16
        LD (HL),0
        LD (CGDE),HL
        JP FNDSN
; Claude - 2026-09-26 - begin
; FAT_CACHE_GENERATION (4 байта данных) перенесено отсюда в выравнивание перед
; NXTETY #413F: здесь эти байты ушли под вход PLAIN_ALIAS в LONG (ENTREZ).
; Claude - 2026-09-26 - end
        ASSERT $ <= #481F, исправления имён не помещаются перед SNCEN
        DS #481F-$,0
        ASSERT $ == #481F, изменился фиксированный адрес SNCEN
; Codex - 2026-09-08 - end
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
; её первый кластер, FSTFRC — последний найденный кластер как курсор поиска.
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
        ; BUtoFAT: CF=1 означает как завершённую цепочку, так и ошибку записи;
        ; Z/NZ при возврате сохраняет различие для вызывающего APPEND.
        CALL BUtoFAT:RET C
        ; LSTsr уже перенёс последний кластер в начало GENBU. Продолжить
        ; через PREPFC: отдельный поиск здесь пропускал декремент счётчика.
        ; Пересинхронизация SECBU не нужна: последний CURIT в BUtoFAT
        ; перечитывает тот же сектор FAT, в котором стоит продолжение скана.
        JR ROSTIK
SGENBU  LD HL,GENBU,(GARY),HL

        CALL SRHFCL:RET C
        LD (FCTS),HL,(FCTS+2),DE
; MKSG держит продолжение текущего FAT-сектора в альтернативном наборе
; регистров. Здесь и в AR2 обязана остаться прямая запись: вызов шлюза
; расширения внутри этого цикла разрушал продолжение поиска и мог включить
; занятый кластер соседнего файла в новую цепочку.
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
; Остаток включает последний добавленный кластер. Заём в high16 возникает
; только при исходном low16=0, а завершение определяется всем DE:HL.
PREPFC  LD HL,(CLCNT),DE,(CLCNT+2)
        LD A,H:OR L:JR NZ,.low_ready
        DEC DE
.low_ready:
        DEC HL
        LD (CLCNT),HL,(CLCNT+2),DE
        LD A,H:OR L,D,E:JR Z,EOFG

AMM     EXX
        LD A,H:CP high SECBE
        JR C,ARM
        CALL SRHFC:RET C
        JR AR2
ARM     CALL FC:RET C
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
EOFG    LD DE,#0FFF
        LD HL,(GARY)
        LD (HL),E:INC HL
        LD (HL),E:INC HL
        LD (HL),E:INC HL
        LD (HL),D:INC HL
        LD (GARY),HL
        RET
BUtoFAT LD HL,GENBU
GENFC   LD C,(HL):INC HL
        LD B,(HL):INC HL
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        PUSH HL
; Claude - 2026-09-25 - begin
        ; CURIT_CHECKED: при ошибке CURIT выход из BUtoFAT, а не правка SECBU.
        LD HL,BC:CALL CURIT_CHECKED:EX DE,HL
; Claude - 2026-09-25 - end
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
        ; SAVE_FAT_SECTOR уже оставил Z/NZ и A результата. CF помечает
        ; окончание BUtoFAT; это не скрывает ненулевую ошибку записи.
        SCF
        RET
LSTsr   CALL LSTSR
        RET NZ                          ; ошибка промежуточного сброса GENBU
        LD HL,(UUHL),DE,GENBU,BC,4:LDIR
        LD (GARY),DE

        XOR A:INC A
        RET

; Claude - 2026-09-21 - begin
; CURIT_INVALIDATE — первый шаг CURIT: снять признак кэша FAT текущей страницы
; (FATTAG+3=#FF; у FAT_CACHE_GENERATION такого старшего байта не бывает) и
; перейти в DEL128. A разрушается, как и прежде при DEL128.
CURIT_INVALIDATE:
        LD A,#FF
        LD (FATTAG+3),A
        JP DEL128
; Claude - 2026-09-21 - end

; DLSG — освободить FAT-цепочку.
; Вход: HL указывает на четырёхбайтовый номер первого кластера.
; Процедура идёт по цепочке, сохраняет следующий номер в первых четырёх байтах
; LOBU, зануляет каждую FAT-запись и записывает изменённые секторы через SDDSE.
; FSTFRC получает голову освобождаемой цепочки, которая после успешной записи
; FAT является точной подсказкой; пустая цепочка прежнюю подсказку не меняет.
; Устойчивого прикладного значения флагов на выходе код не задаёт, результат
; записи определяется драйвером SDDSE.
; Каждая ссылка — ID_CLASSIFY_DATA: недопустимая, за областью данных тома или
; кластер корня — ошибка FAT_LINK_ERROR, освобождённое до неё записано
; (Claude, 2026-09-27: запись файла на кластере корня освобождала корень,
; Codex R28-01).
; Вход DLSG зафиксирован так же, как CURIT и GIPAG: на #49B4 ссылаются уже
; собранные плагины и заголовок файла. Компенсация обязана стоять ДО метки —
; добивка внутри процедуры восстанавливает только LWT и всё, что ниже.
        ASSERT $ <= #49B4, исправления перед DLSG не помещаются
        DS #49B4-$,0
        ASSERT $ == #49B4, сдвинулся фиксированный вход DLSG
DLSG

        LD DE,LOBU,BC,4:LDIR
        CALL_WDOS_EXTENSION WDOS_EXT.ID_NOTE_FREED_CHAIN
        DS 5,0
LWT     LD HL,(LOBU),DE,(LOBU+2)
        LD A,D:OR E,H,L:RET Z
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_CLASSIFY_DATA
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
        CALL_WDOS_EXTENSION WDOS_EXT.ID_CLASSIFY_DATA
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
        ASSERT $ == #4A4C, изменился адрес поиска для существующего FILEX.WMF
SRHDRN

        LD (CGDE),HL:CALL LNLNG:RET Z
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_REFINE_NAME_CLASSIFICATION
        CALL_WDOS_EXTENSION WDOS_EXT.ID_RESET_DIR_HISTORY
; Codex - 2026-07-16 - end

        ASSERT $ == #4A5B, изменился фиксированный адрес FNDSN
; Claude - 2026-09-27 - begin
        ; Прежде «LD HL,LSTCAT,DE,CUHL,BC,4:LDIR:CALL TOS». DIR_STREAM_OPEN — то
        ; же после проверки цепочки каталога (DIR_CHAIN): замкнутая цепочка
        ; вешала поиск (Codex R26-02); испорчена — отказ чтения. Длина та же.
FNDSN   CALL_WDOS_EXTENSION WDOS_EXT.ID_DIR_STREAM_OPEN
        JP C,FIND_IO_ERROR
        DS 7,0
; Claude - 2026-09-27 - end

        LD HL,LOBU,B,1:CALL LOAD512
        JP C,FIND_IO_ERROR

        ; LOAD512 возвращает HL после целого сектора: младший байт остаётся 0.
        LD H,high LOBU
ANNA    CALL ENTCH:JR Z,FND
        LD BC,32:ADD HL,BC
        LD A,H:CP high LOBU2:JR C,ANNA

; Codex - 2026-07-16 - begin
        ; Ошибки #FF уже перехвачены по CF после LOAD512. Здесь остаются
        ; обычное чтение (0) и штатный конец цепочки (#0F).
HDR     LD A,(EOC):CP #0F:RET Z
HDR_CONTINUE:
; Codex - 2026-07-16 - end
; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_PREVIOUS_DIR_LBA
; Codex - 2026-07-16 - end
        PUSH HL
        LD HL,LOBU2,B,1:CALL LOAD512
        POP HL
        JP C,FIND_IO_ERROR
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
        ; ENTFND вернул A=1; OR A уже установил NZ/CF=0, LD их не меняют.
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
; Codex - 2026-09-08 - begin
        LD A,(DE):XOR (HL)
FIND_TYPE_MASK:
        AND #10
        JP NZ,ENTCHe
; Codex - 2026-09-08 - end

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
; Побочные эффекты: DELEN записывает сектор каталога через расширение
; DELETE_ENTRY_WITH_LFN (прежняя STAMP удалена), FCTS получает
; первый кластер удаляемого объекта, DLSG изменяет FAT. Проверка пустоты
; каталога здесь не выполняется и должна быть сделана вызывающим кодом.
; Claude - 2026-09-25 - begin
; Z также при отказе записи каталога (DELEN, A=0) и при отказе освобождения
; цепочки (DLSG): тело — DELFL_CHECKED перед MKFILE, адреса здесь прежние.
DELFL
        JP DELFL_CHECKED
        DS 1,0
; Claude - 2026-09-25 - end
DELCHA  PUSH AF:LD HL,FCTS:CALL DLSG
        POP AF
        RET

DELEN   CALL SRHDRN:LD A,8:RET Z

        LD (FCTS+0),HL
        LD (FCTS+2),DE

; Codex - 2026-07-16 - begin
        CALL_WDOS_EXTENSION WDOS_EXT.ID_DELETE_ENTRY_WITH_LFN
; Codex - 2026-07-16 - end
; Claude - 2026-09-21 - begin
        ; DELETE_ENTRY_WITH_LFN завершается через WRITE_SECTORS: CF=1 ровно при
        ; ошибке записи (NZ). Прежние ветки: успех A=1/NZ, ошибка A=0/Z, CF=0
        ; в обоих случаях. Та же выдача на два байта короче.
        CCF
        SBC A,A
        AND 1
        RET

; Прежняя STAMP здесь удалена: после переноса удаления SFN/LFN в расширение на
; неё не осталось ни одной ссылки в ядре, расширении, FILEX и WC.
; STREAM_CACHE_SECTOR — первая половина проверки кэша сектора FAT: SECBU этой
; страницы хранит сектор FAT кластера DE:HL (LSTSE равен номеру сектора).
; Вход: DE:HL — кластер. Выход: Z — совпадает, тогда CF=0; A — номер записи
; в секторе (0..127). Разрушает BC, DE, HL и AF' (через DEL128, как CURIT).
STREAM_CACHE_SECTOR:
        CALL DEL128                     ; DE:HL=сектор, A=запись, CF=0
        LD BC,(LSTSE)
        SBC HL,BC
        RET NZ
        EX DE,HL
        LD BC,(LSTSE+2)
        SBC HL,BC
        RET
        ASSERT $ <= #4D13, проверка кэша FAT не помещается перед RENAME
        DS #4D13-$,0
        ASSERT $ == #4D13, сдвинулся фиксированный вход RENAME
; Claude - 2026-09-21 - end
; RENAME — создать запись с новым именем и удалить старую.
; Вход: HL — [флаг, старое имя, 0], DE — новое имя с нулевым окончанием.
; Выход: NZ — переименование завершено; Z — нет: старая запись не найдена
; либо её поиск не прочитал каталог (A=8), новую создать не удалось (A — код
; SVHDFL), отказ носителя (A=0 или #0F; #FF — исход неизвестен). Побочные
; эффекты: FCTS сохраняет кластер, SVHDFL записывает новую запись, DELEN
; помечает старую запись #E5. Если старую удалить не удалось, новая тоже
; удаляется (без цепочки), чтобы две записи не делили одну цепочку; не
; удался и откат — A=#FF, обе могут остаться (с 2026-09-25; коды и все ветки
; — у RENAME_ENTRY расширения).
RENAME
; Claude - 2026-09-25 - begin
        ; Сама последовательность — в расширении (RENAME_ENTRY): там же откат,
        ; если прежнюю запись удалить не удалось. Адрес входа и выход прежние.
        CALL_WDOS_EXTENSION WDOS_EXT.ID_RENAME
        RET

; CURIT для BUtoFAT (GENFC). При CF=1 — сектор FAT не прочитан либо кластер
; за FAT — прежде указатель HL был мусорным: LDIR правил устаревший SECBU, и
; SAVE_FAT_SECTOR записывал его на место другого сектора FAT, по чужим
; цепочкам. Теперь BUtoFAT сразу выходит с ошибкой (CF=1, NZ, A=#FF), как при
; ошибке записи: уже связанная часть цепочки остаётся потерянными кластерами,
; чужие записи FAT не трогаются.
CURIT_CHECKED:
        CALL CURIT
        RET NC
        POP HL                          ; возврат в GENFC
        POP HL                          ; указатель GENBU (PUSH HL в GENFC)
        LD A,#FF
        OR A
        SCF
        RET                             ; из BUtoFAT

; DELFL: запись удалена (DELEN, NZ), но цепочку освободить не удалось (DLSG
; вернул NZ) — прежде возвращался «успех», и сбой FAT скрывался. Теперь
; неудача: Z, A=0, как у отказа записи каталога в DELEN.
DELFL_CHECKED:
        CALL DELEN:RET Z
        LD HL,FCTS:CALL DLSG
        LD A,1:JR Z,$+3:DEC A
        OR A
        RET
        DS #4D34-$,0
        ASSERT $ == #4D34, сдвинулся фиксированный вход MKFILE
; Claude - 2026-09-25 - end
; MKFILE — создать файл и выделить ему цепочку кластеров.
; Вход: HL указывает на [атрибут, размер DE:HL в четырёх байтах, имя, 0].
; Выход: Z — успех (DE:HL — первый кластер); NZ — ошибка выделения или записи
; каталога, A — код (#FF — отказ носителя: при записи каталога и при записи
; FAT во время выделения в MKSG — IO_RESULT расширения отдаёт #FF, FEEM пишет
; «UNKNOWN ERROR!!»).
; Побочные эффекты: размер копируется в SIZIK, имя временно хранится через
; CGHL, MKSG изменяет FAT и оставляет новую подсказку в RAM, SVHDFL создаёт
; ENTRY. При отказе SVHDFL — MKFILE_FAIL: по имени или месту цепочка
; освобождается (DELCHA/DLSG; отказ записи FAT не проверяется — тогда могут
; остаться потерянные кластеры); при отказе носителя запись могла лечь, и
; цепочка освобождается, только если повторный поиск её точно не нашёл.
MKFILE

        LD A,(HL),(EFLG),A:INC HL
        LD DE,SIZIK,BC,4:LDIR
        LD (CGHL),HL

        LD HL,(SIZIK),DE,(SIZIK+2)
; Claude - 2026-09-27 - begin
        ; MKSG — здесь, вне шлюза, при прерываниях вызывающего, как в исходном
        ; WC. С 2026-07-16 его звал ALLOCATE_FILE внутри шлюза, и выделение
        ; файла в гигабайт (~4900 тактов на кластер) шло при DI минуту и
        ; дольше (Codex R28-02 — о том же для предобхода F5). Размер 0 — без
        ; MKSG: DEC в нём сделал бы из счётчика #FFFFFFFF. Итог разбирает
        ; ALLOCATE_FILE: пустой — FCTS=0, отказ — 16 или #FF (отказ чтения FAT).
        LD A,H:OR L,D,E
        CALL NZ,MKSG
        CALL_WDOS_EXTENSION WDOS_EXT.ID_ALLOCATE_FILE
        RET NZ
        JP MKFILE_TAIL                          ; SVHDFL — за MKDIR
        DS #4D5B-$,0
        ASSERT $ == #4D5B, сдвинулся фиксированный вход MKDIR
; Claude - 2026-09-27 - end

; MKDIR — создать каталог.
; Вход: HL указывает на имя с нулевым окончанием. Выход: Z — успех; NZ —
; ошибка, A — код (16 — нет места, 1–4 — имя, из них 2 — исчерпаны суффиксы
; ~N короткого имени; #FF — отказ носителя, в том числе при записи FAT в
; MKSG: IO_RESULT расширения отдаёт #FF, FEEM пишет «UNKNOWN ERROR!!»).
; Выделяется минимум один сектор, создаются записи «.» и «..», первый сектор
; каталога записывается из LOBU, остальные секторы кластера зануляются
; безопасным циклом расширения.
MKDIR
; Claude - 2026-09-25 - begin
        ; Сама процедура — в расширении (MKDIR_ENTRY): тело каталога («.», «..»
        ; и обнулённый хвост кластера) пишется до записи в родителе; отказ
        ; тела освобождает цепочку (попытка DELCHA), отказ носителя при
        ; записи в родителе проверяется повторным поиском (сектор мог лечь).
        ; Прежде запись публиковалась первой, и отказ записи тела оставлял
        ; каталог со старым мусором свободного кластера. Адрес входа и выход
        ; прежние; место прежнего тела занято помощниками ниже (до RFRH,
        ; #4DE5).
        CALL_WDOS_EXTENSION WDOS_EXT.ID_MKDIR
        RET

; Глубина рекурсивных F5 и F8 (WCFX). Стеки обхода лежат в странице TVBPG
; окна #C000: у DIRCOPY — индексы по 2 байта на уровень, у DIRTREM — имена
; (короткий псевдоним и байт длины). Прежде они росли без проверки, и запись
; за #FFFF уходила в страницу потока #0000; DIRTREM ловил переполнение лишь
; после записи. Очень глубокое дерево или зацикленный каталог испорченного
; тома теперь дают «DIR name too long/END of buffer» (код 7), пока до конца
; страницы остаётся 256 байт.
DCIN_TAIL:                              ; DIRCOPY: HL — новая вершина стека
        LD A,H:INC A
        LD B,7:JP Z,@WCFX.ERMAIN
        LD (@WCFX.DDIRS+1),HL
        JP @WCFX.ZANOVOC
RECBUF_DEPTH:                           ; DIRTREM: перед обходом подкаталогов
        CALL @WCFX.RECBUF
        LD A,(@WCFX.DDIRS+2):INC A      ; старший байт вершины стека имён
        RET NZ
        POP HL                          ; возврат в DDIRZ
        LD B,7:JP @WCFX.DTRER0

; Знак расширения короткого имени для длинного (LONG): A — знак имени.
; Выход: Z — расширение кончается (конец имени, управляющий или недопустимый
; в 8.3 знак); NZ — A прописной и годен.
SFN_EXT_CHAR:
        CALL ACS
        CALL ENCEN:RET Z
        JP SNCEN

; UCH для NXTETY2 (LNPARS через UCHN) с пределом длины: имя собирается в поле
; вызывающего с CGDE, и в нём 255 знаков и ноль. Повреждённый каталог с
; 20 записями LFN по 13 знаков давал 260 и писал за это поле; теперь на
; 255-м знаке имя кончается, как на терминаторе UCH (NZ, CF=0).
UCH_BOUNDED:
        PUSH HL
        PUSH DE
        LD HL,(CGDE)
        EX DE,HL
        OR A
        SBC HL,DE                       ; знаков уже в поле
        LD DE,255
        SBC HL,DE                       ; CF=1 — меньше 255
        POP DE
        POP HL
        JP C,UCH
        XOR A:INC A
        RET

; Claude - 2026-09-27 - begin
; Хвост MKFILE (место его входа до MKDIR #4D5B занято вызовом MKSG): запись в
; каталог. Успех — Z, A=0, как прежде; отказ — в MKFILE_FAIL (A — код).
; Claude - 2026-09-25: прежде JP NZ,DELCHA — при отказе носителя, после
; которого запись всё же легла, цепочка освобождалась под живой записью
; (аудит Codex).
MKFILE_TAIL:
        LD HL,(CGHL)
        CALL SVHDFL
        JR Z,MKFILE_FAIL.ok
; Claude - 2026-09-27 - end
; MKFILE: SVHDFL отказал, A — код. Без ошибки носителя (ABT=0) — имя или
; место, в родителе не писали: освободить цепочку (DELCHA — попытка: при
; отказе записи FAT могут остаться потерянные кластеры). При ошибке носителя сектор
; с записью мог лечь: ENTRY_LANDED расширения ищет нормализованный запрос
; NXTBU. Запись есть с нашим кластером — успех (DE:HL — кластер, как у
; штатного выхода); записи нет — освободить (A=#FF); неизвестно — цепочку
; не трогать (потерянные кластеры лучше записи на свободный кластер).
MKFILE_FAIL:
        LD B,A
        LD A,(ABT):OR A
        LD A,B
        JR Z,.drop
        CALL_WDOS_EXTENSION WDOS_EXT.ID_ENTRY_LANDED
        LD A,#FF
        JR C,.keep
        JR Z,.drop
        LD HL,(FCTS),DE,(FCTS+2)
.ok:
        XOR A
        RET
.drop:
        OR A
        JP DELCHA
.keep:
        OR A
        RET

; Цикл F5 COPYF (WCFX, SVNG) звал LOAD512 и SAVE512 без проверки: при отказе
; чтения в копию уходило прежнее содержимое буфера #C000, при отказе записи
; оставалась недописанная копия полного размера, а F5 сообщал успех. Здесь
; обёртка чтения (прежде — в конце WCINI; перенесена ради места под сжатое
; расширение; обёртка записи с 2026-09-27 — WCFX.COPY_SAVE: место ушло под
; хвост MKFILE). Отказ (CF=1) — @COPY_FAIL в MD20: попытка удалить
; недописанную копию в каталоге назначения (результат DELFL не проверяется —
; при его отказе копия может остаться под своим именем либо без имени,
; потерянными кластерами), окно прогресса закрывается, «UNKNOWN ERROR!!»,
; выход NZ — как у любой ошибки COPYF (B=255 у DIRCOPY). ABT сбрасывается в
; обоих контекстах: ошибка уже показана.
COPY_LOAD:
        CALL LOAD512                    ; контекст источника
        RET NC
        XOR A:LD (ABT),A
        CALL @WCFX.SWPPAND              ; -> назначение
        JP @COPY_FAIL

; WCINI.OTHER_REFRESH: каталога соседней панели больше нет — она уходит в
; корень своего устройства (путь «N:\»), затем показ (@DELRF_SHOW, MD20).
DELRF_ROOT:
        LD HL,0
        LD (@BRRR),HL
        LD (@BRRR+2),HL
        CALL @WCINI.RPATH
        JP @DELRF_SHOW
        DS #4DE5-$,0
        ASSERT $ == #4DE5, сдвинулся RFRH за MKDIR
; Claude - 2026-09-25 - end

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
; кластеры, каталог и CGFL сбрасываются; FSTFRC загружается из проверенного
; FSInfo либо получает безопасное начальное значение 2.
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

        CALL_WDOS_EXTENSION WDOS_EXT.ID_LOAD_FREE_HINT
; Claude - 2026-09-21 - begin
        ; Смонтирован (возможно, другой) том: кэш FAT всех страниц недействителен.
        ; Прежние четыре NOP заняты вызовом; размер HDD не изменился.
        CALL FAT_CACHE_BUMP
        NOP
; Claude - 2026-09-21 - end

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
; Claude - 2026-09-21 - begin
        CALL SELDEV_INVALIDATE          ; сброс кэша FAT и прежний SELDEV(A)
; Claude - 2026-09-21 - end
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

; Claude - 2026-09-21 - begin
; На месте прежней UMNOG: на неё не было ни одной ссылки в ядре, расширении,
; FILEX и WC. Размер и адрес INC4b сохранены.
; FAT_CACHE_TAG — пометить SECBU текущей страницы как кэш сектора LSTSE для
; текущего поколения FAT. Вызывается расширением после удачного CURIT потока.
; HL (указатель CURIT на запись) сохраняется, BC и DE разрушаются.
FAT_CACHE_TAG:
        PUSH HL
        LD HL,FAT_CACHE_GENERATION
        LD DE,FATTAG
        LD BC,4
        LDIR
        POP HL
        RET
        DB 0
; FAT_CACHE_BUMP — сделать недействительным кэш FAT всех страниц сразу:
; увеличить 32-битный FAT_CACHE_GENERATION (продолжение — INC4b).
; Разрушает HL, B и флаги; A, C и DE сохраняются.
FAT_CACHE_BUMP:
        LD HL,FAT_CACHE_GENERATION
        ASSERT $ == #5099, сдвинулся INC4b после FAT_CACHE_BUMP
; Claude - 2026-09-21 - end
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

; Шлюз передаёт функции оба входных набора AF/BC/DE/HL и IX, а затем
; возвращает оба выходных набора и IX без собственных разрушений. IY не
; используется. Состояние страницы/IFF и регистры каждого вложенного вызова
; находятся в его стековом кадре. Байт ID читается до переключения страницы.
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

        LD IX,0
        ADD IX,SP
        LD L,(IX+18)
        LD H,(IX+19)
        LD A,(HL)
        LD L,A

        ; WC IM2 увеличивает #6009 до вызова обработчиков плагинов. Если IRQ
        ; совпал с LD A,I на NMOS Z80, P/V может оказаться ложным нулём.
        ; Изменение счётчика между двумя чтениями обнаруживает такой IRQ.
        ; Первый снимок хранится в B текущего кадра, не в общей RAM-ячейке.
        LD A,(#6009)
        LD B,A
        LD D,1
EXTENSION_GATE_READ_IFF:
        LD A,I
        DI
        JP PE,EXTENSION_GATE_IFF_SAVED
        LD A,(#6009)
        SUB B
        LD D,A
EXTENSION_GATE_IFF_SAVED:
        LD BC,#13AF
        IN A,(C)
        LD E,A
        LD A,WC_PHYS_CORE32_EXT_PAGE
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
        ASSERT $ <= #516C, исправления CORE32 не помещаются перед GARY
        DS #516C-$,0
        ; Один байт сохраняет историческое размещение GARY и точных драйверов.
        ; Страница FILEX хранится в операнде резидентного шлюза по #6A48.
        DB #FF
        ASSERT $ == #516D, изменился адрес GARY
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
; тот же обмен. Поэтому packed-блок и распакованный runtime остаются точными
; штатными; высокоуровневые исправления FAT, каталогов и APPEND от них не
; зависят.
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
; CORE32_EXT, поэтому оно находится в безопасном промежутке перед IM2 и стеком.
EXTENSION_GATE_AFTER:
; Codex - 2026-07-16 - begin
; GATE_FINISH уже заменил входной кадр выходными регистрами функции.
; Сначала возвращаем страницу, затем снимаем все девять пар. Флаг Z выбора
; EI/DI живёт до последнего POP AF; промежуточный EX AF сохраняет его.
        POP DE
        LD A,E
        LD BC,#13AF
        OUT (C),A
        LD A,D
        OR A
        EXX
        POP HL
        POP DE
        POP BC
        EXX
        EX AF,AF'
        POP AF
        EX AF,AF'
        POP IX
        POP HL
        POP DE
        POP BC
        JR Z,EXTENSION_GATE_KEEP_DI
        POP AF
        EI
EXTENSION_GATE_RET_EI:
        RET
EXTENSION_GATE_KEEP_DI:
        POP AF
EXTENSION_GATE_RET_DI:
        RET
; Claude - 2026-09-21 - begin
; SELDEV_INVALIDATE — продолжение DOS_SWP после распаковки драйвера: носитель,
; драйвер и VALS страницы другие, поэтому кэш FAT всех страниц сбрасывается
; до SELDEV. A (выбор master/slave или слота SD) сохраняется FAT_CACHE_BUMP.
SELDEV_INVALIDATE:
        CALL FAT_CACHE_BUMP
        JP SELDEV
; Claude - 2026-09-21 - end
        ASSERT $ <= #5BEA, эпилог шлюза пересёк восстановление потока
        DS #5BEA-$,0
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
        ASSERT $ <= @PLUGIN_REFRESH_BOTH, ядро пересекло резидентный обработчик
; Codex - 2026-07-16 - end
END
; Codex - 2026-07-16 - begin
        ; Установщик использует DE сразу после LDIR ядра как адрес следующего
        ; копирования. Проверяем точное соседство, а не только отсутствие
        ; пересечения: иначе изменение длины молча сдвинет обработчик в RAM.
        ASSERT END == @PLUGIN_REFRESH_BOTH, изменилось начало резидентного обработчика
; Codex - 2026-07-16 - end
        ENT
; Claude - 2026-09-26 - begin
; Прежде здесь адрес #C0D9 (#40CD в ядре, JR Z фильтра типа записи в NXTETY2)
; считался точкой подстановки, которую WC берёт из физического образа. Это
; ошибка разметки: #C0D9 в WCIF — пара символов рамки «└» и «┘» (строка OMS
; исторического исходника: LD DE,#C0D9,C,#C4:CALL FLL), к ядру не относится.
; Привязки к #40CD больше нет.
; Claude - 2026-09-26 - end
; Codex - 2026-07-16 - begin
        ASSERT $ <= #DC00, нарушена физическая граница WildDOS
; Codex - 2026-07-16 - end
