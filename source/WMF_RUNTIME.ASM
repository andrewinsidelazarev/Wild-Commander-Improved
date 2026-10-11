; Переменные ассоциации WMF #11. Резидент #5300..#5AA9, пул — страница #E9.
; При установке копируется из одноразового хвоста CORE32_EXT поверх его BSS.
; Рабочие таблицы #E8 сохраняют размер и начинают использоваться после копии.
; Прямые входы — внутренний контракт WC/PLM; номера публичного API не меняются.
        DEVICE ZXSPECTRUM128
        INCLUDE "PHYSICAL_MEMORY_MAP.ASM"
        INCLUDE "WMF_FORMAT.ASM"
        ORG WMF_RUNTIME_BASE
        JP REGISTER
        JP MATCH
        JP SKIP
        JP REPORT
        JP NEXT
        JP MENU_FIT
MNGC    EQU #68C1
LOAD512 EQU #4015
PHED    EQU #7F18
LOBU    EQU #B000
ENTRY   EQU #7F6B
BUX     EQU #5E00
F3ENTFL EQU #6017
ENV_CODE EQU #7107       ; операнд LD A,n перед EX AF,AF' запуска — A' плагина

; REGISTER: поток сразу за заголовком LOBU, таблица #60 в #C000.
; Успех: заголовок опубликован, поток перед кодом; CF=0. Отказ: CF=1,
; A=1 неверное описание, 2 нет памяти, 3 ошибка чтения. PHED не меняется.
; IX/IY сохраняются. BC/DE/HL/AF разрушаются; альтернативные — не трогаются.
REGISTER:
        PUSH IX
        CALL REGISTER_BODY
        POP IX
        PUSH AF
        LD A,#60
        CALL MNGC
        POP AF
        RET
REGISTER_BODY:
        LD HL,(PHED)
        LD A,H
        OR L
        JR NZ,.space
        LD A,2
        SCF
        RET
.space:
        LD IX,LOBU
        LD A,(IX+32)
        CP WMF_DYNAMIC_VERSION
        JP NZ,PUBLISH
        CALL DESCRIBE
        RET C
        LD (META_BYTES),HL
        LD (META_COUNT),DE
        LD (SECTORS),A
        LD (IX+WMF_META_PTR),0
        LD (IX+WMF_META_PTR+1),0
        OR A
        JP Z,PUBLISH
        CALL ALLOCATE
        RET C
        LD (META_PTR),HL
        LD A,WC_PHYS_WMF_META_PAGE
        CALL MNGC
        LD HL,(META_PTR)
        PUSH HL
        LD A,(SECTORS)
        LD B,A
        CALL LOAD512
        POP DE
        JP C,IO_ERROR
        ; EOC без CF тоже может означать короткое чтение: сверяем весь объём.
        LD A,(SECTORS)
        ADD A,A
        ADD A,D
        CP H
        JP NZ,IO_ERROR
        LD A,L
        OR A
        JP NZ,IO_ERROR
        CALL VALIDATE
        RET C
        LD HL,(META_PTR)
        LD (LOBU+WMF_META_PTR),HL
        LD A,#60
        CALL MNGC
PUBLISH:
        LD HL,LOBU
        LD DE,(PHED)
        LD BC,512
        LDIR
        LD (PHED),DE
        ; Последняя запись кончается ровно на #10000. Не писать нули в #0000.
        LD A,D
        OR E
        RET Z
        EX DE,HL
        LD B,0
.zero:  LD (HL),0
        INC HL
        DJNZ .zero
        OR A
        RET

; IX — заголовок #11. Проверить описание; HL=байты, DE=число записей,
; A=ceil(bytes/512). Пустой список требует bytes=count=0. Пул — 16 КиБ.
DESCRIBE:
        LD A,(IX+WMF_META_FORMAT)
        CP WMF_META_SCHEMA
        JP NZ,BAD
        LD L,(IX+WMF_META_BYTES)
        LD H,(IX+WMF_META_BYTES+1)
        LD E,(IX+WMF_META_COUNT)
        LD D,(IX+WMF_META_COUNT+1)
        LD A,H
        CP #40
        JP C,.size_ok
        JP NZ,BAD
        LD A,L
        OR A
        JP NZ,BAD
.size_ok:
        LD A,H
        OR L
        JR NZ,.nonempty
        LD A,D
        OR E
        JP NZ,BAD
        RET
.nonempty:
        LD A,D
        OR E
        JP Z,BAD
        ; Даже самая короткая запись занимает три байта; точный разбор ниже.
        PUSH HL
        OR A
        SBC HL,DE
        POP HL
        JP C,BAD
        LD A,L
        OR A
        LD A,H
        JR Z,.round
        INC A
.round: INC A
        SRL A
        OR A                            ; CF — результат проверки, не округления
        RET

; Карта занятости строится заново из живых заголовков. Поэтому удаление,
; замена и сдвиг записей не оставляют утечек и не требуют перехвата PLGDEL.
; Единица выделения — сектор, чтобы читать метаданные прямо на своё место.
ALLOCATE:
        LD HL,BUSY
        LD B,32
.clear: LD (HL),0
        INC HL
        DJNZ .clear
        LD IX,#C000
.record:
        PUSH IX
        POP HL
        LD DE,(PHED)
        OR A
        SBC HL,DE
        JR Z,.find
        LD A,(IX+32)
        CP WMF_DYNAMIC_VERSION
        JR NZ,.next
        CALL DESCRIBE
        RET C
        OR A
        JR Z,.next
        LD B,A
        LD A,(IX+WMF_META_PTR)
        OR A
        JP NZ,BAD
        LD A,(IX+WMF_META_PTR+1)
        SUB #C0
        JP C,BAD
        SRL A
        JP C,BAD
        LD C,A
        ADD A,B
        CP 33
        JP NC,BAD
        LD L,C
        LD H,0
        LD DE,BUSY
        ADD HL,DE
.mark:  LD (HL),1
        INC HL
        DJNZ .mark
.next:  LD DE,512
        ADD IX,DE
        JR .record
.find:  LD HL,BUSY
        LD B,32
        LD C,0
.scan:  LD A,(HL)
        INC HL
        OR A
        JR NZ,.busy
        INC C
        LD A,(SECTORS)
        CP C
        JR Z,.found
        JR .advance
.busy:  LD C,0
.advance:
        DJNZ .scan
        LD A,2
        SCF
        RET
.found: LD A,33
        SUB B
        SUB C
        ADD A,A
        ADD A,#C0
        LD H,A
        LD L,0
        OR A
        RET

; Разобрать ровно count записей в bytes байтах. Проверка до публикации.
; Нижний ASCII приводится к верхнему прямо в своей копии списка.
VALIDATE:
        LD HL,(META_PTR)
        LD BC,(META_BYTES)
        LD DE,(META_COUNT)
.record:
        LD A,D
        OR E
        JR Z,.end
        LD A,B
        OR C
        JP Z,BAD
        LD A,(HL)
        INC HL
        DEC BC
        OR A
        JP Z,BAD
        LD (LENGTH),A
        LD A,B
        OR C
        JP Z,BAD
        INC HL                          ; любой байт кода обработчика допустим
        DEC BC
        PUSH DE
        LD A,(LENGTH)
        LD E,A
.char:  LD A,B
        OR C
        JR Z,.bad_pop
        LD A,(HL)
        CP 33
        JR C,.bad_pop
        CP 127
        JR NC,.bad_pop
        CP "."
        JR Z,.bad_pop
        CP "/"
        JR Z,.bad_pop
        CP #5C
        JR Z,.bad_pop
        CP "*"
        JR Z,.bad_pop
        CP "?"
        JR Z,.bad_pop
        CALL UPPER
        LD (HL),A
        INC HL
        DEC BC
        DEC E
        JR NZ,.char
        POP DE
        DEC DE
        JR .record
.bad_pop:
        POP DE
        JP BAD
.end:   LD A,B
        OR C
        JP NZ,BAD
        RET

; SKIP: HL — сохранённый заголовок, DE — отдельный секторный буфер PLM.
; Поток стоит после первого сектора. Старый WMF — без чтений; #11 — ровно
; ceil(bytes/512) секторов. CF/короткое чтение отменяют загрузку кода.
; IX сохраняется; остальные основные регистры разрушаются.
SKIP:
        PUSH IX
        PUSH DE
        PUSH HL
        POP IX
        LD A,(IX+32)
        CP WMF_DYNAMIC_VERSION
        JR Z,.dynamic
        XOR A
        JR .done
.dynamic:
        CALL DESCRIBE
        JR C,.done
        OR A
        JR Z,.done
        LD (SKIP_LEFT),A
        POP HL
        PUSH HL
        LD (SKIP_BUFFER),HL
.sector:
        LD HL,(SKIP_BUFFER)
        LD B,1
        CALL LOAD512
        JR C,.io
        LD DE,(SKIP_BUFFER)
        INC D
        INC D
        OR A
        SBC HL,DE
        JR NZ,.io
        LD HL,SKIP_LEFT
        DEC (HL)
        JR NZ,.sector
        XOR A
        JR .done
.io:    LD A,3
        SCF
.done:  POP DE
        POP IX
        RET

; MATCH: DE=заголовок+64 в странице #60. Выход NZ/A=старый индекс или
; новый код обработчика; Z=нет совпадения. DE, IX/IY, альтернативные сохранены.
; Новые имена берутся из BUX целиком, поэтому расширение может быть длиннее 3.
MATCH:
        PUSH DE
        LD H,D
        LD L,32
        LD A,(HL)
        CP WMF_DYNAMIC_VERSION
        JR Z,.dynamic
        LD C,0
.legacy:
        LD HL,ENTRY+8
        LD A,(DE)
        OR A
        JR Z,.return
        PUSH DE
        LD B,3
.three: LD A,(DE)
        CP (HL)
        JR NZ,.miss
        INC DE
        INC HL
        DJNZ .three
.miss:  POP DE
        JR Z,.legacy_found
        INC DE
        INC DE
        INC DE
        INC C
        LD A,C
        CP 32
        JR C,.legacy
        XOR A
        JR .return
.legacy_found:
        LD A,1
        OR A
        LD A,C
.return:
        POP DE
        RET
.dynamic:
        LD L,WMF_META_COUNT
        LD C,(HL)
        INC HL
        LD B,(HL)
        INC HL
        LD E,(HL)
        INC HL
        LD D,(HL)
        LD A,B
        OR C
        JR Z,.return
        PUSH BC
        PUSH DE
        CALL FILE_EXTENSION
        POP HL
        POP BC
        JR Z,.return
        PUSH BC
        PUSH HL
        LD A,WC_PHYS_WMF_META_PAGE
        CALL MNGC
        POP HL
        POP BC
.record:
        LD A,B
        OR C
        JR Z,.restore
        PUSH BC
        LD B,(HL)
        INC HL
        LD C,(HL)
        INC HL
        LD A,(EXT_LENGTH)
        CP B
        JR NZ,.skip
        LD DE,(EXT_PTR)
.compare:
        LD A,(DE)
        CALL UPPER
        CP (HL)
        JR NZ,.skip
        INC HL
        INC DE
        DJNZ .compare
        LD A,1
        OR A
        LD A,C
        POP BC
        JR .restore
.skip:  LD E,B
        LD D,0
        ADD HL,DE
        POP BC
        DEC BC
        JR .record
.restore:
        PUSH AF
        LD A,#60
        CALL MNGC
        POP AF
        POP DE
        RET

FILE_EXTENSION:
        LD HL,BUX
        LD DE,0
        LD B,0
.next:  LD A,(HL)
        INC HL
        OR A
        JR Z,.end
        CP "."
        JR NZ,.continue
        LD D,H
        LD E,L
.continue:
        DJNZ .next
        XOR A                           ; нет NUL в 256 байтах — отказ
        RET
.end:   LD A,D
        OR E
        RET Z
        LD (EXT_PTR),DE
        DEC HL
        OR A
        SBC HL,DE
        LD A,L
        LD (EXT_LENGTH),A
        OR A
        RET
UPPER:  CP "a"
        RET C
        CP "z"+1
        RET NC
        SUB 32
        RET

; NEXT: DE — предыдущее header+64; CF=1 конец, иначе DE — следующая запись.
; PHED=0 означает полные 32 записи; переход #FFFF запрещён до чтения памяти.
NEXT:
.again: LD HL,512
        ADD HL,DE
        JR C,.end
        EX DE,HL
        LD HL,(PHED)
        LD A,H
        OR L
        JR Z,.route
        OR A
        SBC HL,DE
        JR C,.end
.route: LD H,D
        LD L,63
        LD A,(HL)
        BIT 0,A
        JR Z,.yes
        SRL A
        AND 1
        LD HL,F3ENTFL
        CP (HL)
        JR NZ,.again
.yes:   OR A
        RET
.end:   SCF
        RET

BAD:    LD A,1
        SCF
        RET
IO_ERROR:
        LD A,3
        SCF
        RET
REPORT: LD HL,BAD_TEXT
        CP 2
        JR NZ,.io
        LD HL,FULL_TEXT
.io:    CP 3
        JR NZ,.show
        LD HL,IO_TEXT
.show:  JP #90DE                         ; WCFX.ERR0, проверяется в BOOT.ASM
; Claude - 2026-10-11 - begin
; MENU_FIT — меню Shift+F3/Shift+Enter (WCVW EXTSEL): HL — поле +197
; заголовка в таблице #60 (окно #C000), файл — текущий (как у MATCH). NZ —
; плагин в меню: его список держит расширение файла — код формата в A'
; запуска (ENV_CODE), как у Enter/F3; A=1 — запуск как по Enter (A=#00), у
; просмотрщиков #04/#05/#15 — A=5 (A=#04); или это универсальный
; просмотрщик (+33 bit 1: открывает любой файл) — код #FF, A=5. Z — нет.
; Прежде в меню были все #04/#05/#15 для любого файла (Wild Player — и для
; MIDI), а плагины по расширению (#00, GS Player) — никогда, и выбранный
; плагин получал код формата от прошлого файла. HL, DE сохраняются.
MENU_FIT:
        PUSH DE
        PUSH HL
        LD DE,64-197
        ADD HL,DE
        EX DE,HL
        CALL MATCH                              ; NZ, A — код; DE — +64
        LD H,D                                  ; H — заголовок
        POP DE                                  ; DE — +197
        PUSH DE
        JR Z,.other
        LD (ENV_CODE),A
        LD A,(DE)
        CALL .viewer
        LD A,1
        JR NZ,.done                             ; не просмотрщик — как по Enter
.view:  LD A,5
        OR A
        JR .done
.other: LD A,(DE)
        CALL .viewer
        JR NZ,.no
        LD L,33
        BIT 1,(HL)
        JR Z,.no
        LD A,#FF                                ; любой файл: кода формата нет
        LD (ENV_CODE),A
        JR .view
.no:    XOR A
.done:  POP HL
        POP DE
        RET
.viewer:                                        ; Z — тип #04, #05 или #15
        CP #04
        RET Z
        CP #05
        RET Z
        CP #15
        RET
; Claude - 2026-10-11 - end
BAD_TEXT:  DB "Invalid WMF metadata",0
FULL_TEXT: DB "WMF metadata memory full",0
IO_TEXT:   DB "WMF metadata read error",0
META_BYTES: DS 2,0
META_COUNT: DS 2,0
META_PTR:   DS 2,0
SECTORS:    DB 0
LENGTH:     DB 0
SKIP_BUFFER: DS 2,0
SKIP_LEFT:  DB 0
EXT_PTR:    DS 2,0
EXT_LENGTH: DB 0
BUSY:       DS 32,0
WMF_RUNTIME_END:
        ASSERT WMF_RUNTIME_END <= WMF_RUNTIME_LIMIT, обработчик WMF налез на DEHR
