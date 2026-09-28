;---------------------------------------
; Вывод TGV на FT812 платы VDAC2.
;
; Кадр TGV (256 точек в строке, байт на точку, своя палитра TS-Conf на 256
; цветов) уходит в RAM_G FT812 как есть: формат PALETTED565, палитра
; пересчитывается из RGB555 TS-Conf в RGB565. Растягивает кадр сам FT812 —
; в 4 раза с билинейным сглаживанием, 256x126 -> 1024x504, — и сам ставит
; его по центру экрана 1024x768 (VERTEX2II, отступ сверху (768-504)/2).
;
; Развёртка FT812 — стандартная 1024x768@59 (64 МГц/(1344*806) = 59,084 Гц),
; как в FTView: другую частоту монитор ставил со сдвигом. TGV снят под кадры
; TS-Conf: кадр ролика — 4 кадра TS-Conf (48,828 Гц), 12,207 кадра/с, под это
; время и звук. На FT812 это 4,84 его кадра, поэтому кадры ролика держатся то
; 5, то 4 кадра FT812 по дробному графику (FTT.FTTF) по счётчику кадров
; самого FT812 (REG_FRAMES): в среднем ровно темп TS-Conf, со звуком вровень.
;
; FT812 и SD-карта сидят на одной шине SPI Z-контроллера: с FT812 говорит
; только основной цикл, между вызовами чтения WC, а не прерывание. Кадр
; читается с SD прежним путём (LSHOW) в видеостраницы TS-Conf; оттуда DMA
; отдаёт его строки FT812, пропуская вторую половину каждой строки
; (шаг строки в видеопамяти 512 байт).
;
; Без VDAC2 (регистр состояния TS-Conf) ничего из этого не работает, и вывод
; идёт на TS-Conf, как раньше.
;---------------------------------------
FT_CTRL EQU #77                  ; Z-контроллер: кто выбран на шине SPI
FT_DATA EQU #57                  ; Z-контроллер: байт обмена
FT_SEL  EQU #07                  ; выбран FT812
FT_IDLE EQU #03                  ; никто не выбран
FT_STAT EQU #00AF                ; состояние TS-Conf: биты 2..0 = 7 — VDAC2
FT_DSL  EQU #1AAF                ; DMA: источник, биты 7..0
FT_DSH  EQU #1BAF                ;      биты 13..8
FT_DSX  EQU #1CAF                ;      физическая страница
FT_DLEN EQU #26AF                ; слов в пачке - 1
FT_DCTR EQU #27AF                ; запуск; при чтении бит 7 — DMA занят
FT_DNUM EQU #28AF                ; пачек - 1
FT_RSPI EQU #82                  ; DMA: ОЗУ -> SPI
FT_VID  EQU #87                  ; режим TS-Conf «на экране FT812», как в FTView
FTR_ID  EQU #2000                ; регистры FT812 #30xxxx: ID (#7C)
FTR_FRM EQU #2004                ; счётчик кадров
FTR_CPU EQU #2020                ; сброс сопроцессора
FTR_SWP EQU #2054                ; смена дисплей-листа
FT_PALH EQU #03                  ; палитры в RAM_G: #30000+(банк-1)*#200
FT_PB   EQU #B400                ; буфер палитры RGB565 (512 байт)
FT_STI  EQU 4                    ; кадров FT812 на кадр ролика: целая часть
FT_STF  EQU #D7                  ;                              дробная, /256

;---------------------------------------
; Найти VDAC2 и запустить FT812 — до заливки звука: запуск занимает доли
; секунды, а звук MP3 начинается сразу после заливки. Экран пока на TS-Conf.
; Выход: FTOK=1 — FT812 готов (чёрный экран, развёртка 1024x768@59).
FTBOOT  XOR A:LD (FTON),A:LD (FTOK),A
        LD BC,FT_STAT:IN A,(C):AND 7:CP 7:RET NZ
; Команды хоста — порядок и параметры FTView (vdac2_init), кадр между ними.
        LD HL,FTHOSTS
FTS1    LD A,(HL):INC HL:CP #FF:JR Z,FTS2
        LD C,(HL):INC HL
        PUSH HL:CALL FTHOST:POP HL
        JR FTS1
FTS2    LD B,100                 ; до 2 с: ID #7C и сопроцессор после сброса
FTS3    PUSH BC
        EI:HALT
        LD HL,FTR_ID:CALL FTRD16
        LD A,L:CP #7C:JR NZ,FTS4
        LD HL,FTR_CPU:CALL FTRD16
        LD A,H:OR L
FTS4    POP BC
        JR Z,FTS5
        DJNZ FTS3                ; флаг Esc (ABT) здесь не смотрим: он может
                                 ; остаться от прошлого ролика
; VDAC2 есть, а FT812 не ответил — сказать об этом и выводить на TS-Conf.
        LD HL,TXTFT:JP SHOWMSG
FTS5    LD HL,FTREG1:CALL FTREGS
        LD A,#30:LD HL,0:CALL FTWR   ; RAM_DL: пока чёрный экран
        LD HL,FTDLB,BC,12*256+FT_DATA:OTIR
        CALL FTOFF
        LD HL,FTR_SWP:LD E,2:CALL FTWR8
        LD HL,FTREG2:CALL FTREGS
        LD A,1:LD (FTOK),A
        RET

; После заголовка и звука: показывать на FT812. Выход: CF=0 — экран на FT812.
FTSTART LD A,(FTOK):OR A:SCF:RET Z
; Кадр TGV — до 192 строк: x4 это не больше 768.
        LD HL,(LNZ):ADD HL,HL
        LD A,H:OR A:SCF:RET NZ
        LD A,L:CP 193:CCF:RET C
        LD (FTDLL),A             ; BITMAP_LAYOUT: высота кадра
        LD L,A:LD H,0:ADD HL,HL:ADD HL,HL
        LD A,L:LD (FTDLZ),A      ; BITMAP_SIZE: высота на экране (x4)
        LD A,H:AND 1:LD (FTDLZ+1),A
        LD A,H:SRL A:OR 8:LD (FTDLH),A   ; BITMAP_SIZE_H: ширина 1024
        EX DE,HL:LD HL,768:OR A:SBC HL,DE
        SRL H:RR L               ; HL = отступ сверху (768-высота)/2
        LD A,L:RLCA:RLCA:RLCA:RLCA:AND #F0:LD (FTDLV+1),A
        LD A,L:RRCA:RRCA:RRCA:RRCA:AND #0F:LD C,A
        LD A,H:RLCA:RLCA:RLCA:RLCA:AND #F0:OR C:LD (FTDLV+2),A
        LD A,FT_VID:CALL GVmod   ; монитор — на FT812
        XOR A:LD (FTGO),A:LD (FTUL),A
        INC A:LD (FTON),A
        OR A
        RET

; Основной цикл при выводе на FT812: читать кадры, отдавать их FT812,
; менять по сроку. Прерывание плеера (I_N_T) здесь выключено.
MAINFT  LD A,(PGNA):AND #30:LD (FTPG),A
        CALL LSHOW:JP Z,NXFL
        LD A,(PGNA):AND #30:LD C,A
        LD A,(FTPG):CP C:JR Z,FTM1
        RRCA:RRCA:RRCA:RRCA:INC A
        CALL FTUP                ; прочитан новый кадр — в RAM_G
FTM1    CALL FTPOLL
        LD A,(ABT):OR A:JR Z,MAINFT
        JP EXIT

; Сменить кадр, когда подошёл срок. FTT.FTTF — точное время следующего кадра
; ролика в кадрах FT812 (8.8); показывается он с ближайшего к этому времени
; кадра FT812 — округление, а не отбрасывание дроби: ошибка не больше
; полкадра FT812 (±8,5 мс) и без сдвига в одну сторону. Новый дисплей-лист
; FT812 берёт со следующего кадра, поэтому пишем его кадром раньше. Опрос
; идёт чаще раза за кадр FT812: из основного цикла, между порциями чтения
; (BLKZ) и страницами DMA.
FTPOLL  LD A,(FTON):OR A:RET Z
        LD A,(PGV):INC A:CP 5:JR C,$+4:LD A,1
        LD C,A                   ; следующий банк
        LD A,(PGNA):AND #30:RRCA:RRCA:RRCA:RRCA:INC A
        CP C:RET Z               ; ещё читается с SD
        LD A,(FTUL):CP C:RET Z   ; ещё уходит в FT812
        PUSH BC
        LD HL,FTR_FRM:CALL FTRD16
        POP BC
        LD A,(FTGO):OR A:JR Z,FTSW   ; первый кадр — сразу
        LD DE,(FTT)
        LD A,(FTTF):RLCA:AND 1   ; дробь от половины и выше — к следующему
        ADD A,E:LD E,A:JR NC,$+3:INC D
        DEC DE                   ; писать список кадром раньше
        PUSH HL
        OR A:SBC HL,DE
        POP HL
        RET M                    ; рано
        LD HL,(FTT):JR FTSW2     ; по графику: опоздание нагоняется
FTSW    INC HL                   ; первый кадр — со следующего кадра FT812
        XOR A:LD (FTTF),A
; Следующий срок: +4,8399 кадра FT812 (59,084 Гц / 12,207 кадра/с) в формате
; 8.8: 4 + #D7/256 = 4,8398 — за 3 минуты расхождение около 2 мс.
FTSW2   LD A,(FTTF):ADD A,FT_STF:LD (FTTF),A
        LD DE,FT_STI:ADC HL,DE:LD (FTT),HL
        LD A,1:LD (FTGO),A
        LD A,C:LD (PGV),A
        CALL FTDL
; Первый кадр: звук — когда FT812 его действительно показал (REG_DLSWAP
; обнулился — список сменился), а не когда список записан.
        LD A,(SNDGO):OR A:RET Z
        LD BC,4000               ; с запасом на кадр FT812 (~17 мс)
FTSW3   PUSH BC
        LD HL,FTR_SWP:CALL FTRD16
        POP BC
        LD A,L:OR A:JR Z,FTSW4
        DEC BC:LD A,B:OR C:JR NZ,FTSW3
FTSW4   JP SNDST
; Дисплей-лист банка A (1..4) и смена списка со следующего кадра FT812.
FTDL    DEC A:LD B,A
        ADD A,A:LD (FTDLP+1),A   ; палитра: #30000+(банк-1)*#200
        CALL FTSLOT              ; точки кадра банка
        LD DE,FTDLS:LDI:LDI:LDI
        LD A,#30:LD HL,0:CALL FTWR
        LD HL,FTDLT,BC,FTDLN*256+FT_DATA:OTIR
        CALL FTOFF
        LD HL,FTR_SWP:LD E,2:JP FTWR8

; Отдать FT812 кадр банка A (1..4): палитру и точки.
FTUP    LD (FTUL),A:LD (FTG),A
; Палитра банка лежит с #0200*банк (её читает LSHOW); RGB555 -> RGB565:
; красный и зелёный сдвигаются на бит влево, синий остаётся на месте.
        ADD A,A:LD H,A:LD L,0
        LD DE,FT_PB:LD B,0
FTU1    LD A,(HL):INC HL         ; GGGBBBBB
        LD C,A:AND #1F:LD (FTT5),A
        LD A,C:ADD A,A:PUSH AF   ; CF — старший бит G младшего байта
        AND #C0:LD C,A:LD A,(FTT5):OR C
        LD (DE),A:INC DE
        POP AF
        LD A,(HL):INC HL         ; 0RRRRRGG
        RLA                      ; RRRRRGGG
        LD (DE),A:INC DE
        DJNZ FTU1
        LD A,(FTG):DEC A:ADD A,A:LD H,A:LD L,0
        LD A,FT_PALH:CALL FTWR
        LD HL,FT_PB,BC,FT_DATA:OTIR:OTIR
        CALL FTOFF
; Точки: видеостраницы банка (физические #20+(банк-1)*16...) по 32 строки.
        LD A,(FTG):DEC A:LD B,A
        RLCA:RLCA:RLCA:RLCA:ADD A,#20:LD (FTPP),A
        CALL FTSLOT              ; адрес кадра банка в RAM_G
        LD E,(HL):INC HL:LD D,(HL):INC HL:LD A,(HL)
        LD (FTAD),DE:LD (FTAX),A
        LD HL,(LNZ):ADD HL,HL:LD A,L:LD (FTLL),A
FTU2    LD A,(FTLL):CP 33:JR C,$+4:LD A,32
        LD D,A
        LD A,(FTLL):SUB D:LD (FTLL),A
        PUSH DE
        LD A,(FTAX):LD HL,(FTAD):CALL FTWR
        POP DE
        LD A,(FTPP):LD E,A
        CALL FTLINES
        CALL FTOFF
        LD HL,(FTAD):LD BC,#2000:ADD HL,BC:LD (FTAD),HL
        JR NC,$+6:LD HL,FTAX:INC (HL)    ; перенос через границу 64 КБ
        LD HL,FTPP:INC (HL)
        CALL FTPOLL
        LD A,(FTLL):OR A:JR NZ,FTU2
        XOR A:LD (FTUL),A
        RET

; Адрес кадра банка B+1 в RAM_G (3 байта, младшим вперёд). Выход: HL.
; Кадр — до 192 строк по 256 байт (48 КБ), поэтому кадры лежат с шагом
; #C000; палитры — за ними, с #30000.
FTSLOT  LD A,B:ADD A,A:ADD A,B
        LD E,A:LD D,0:LD HL,FTSLT:ADD HL,DE
        RET
FTSLT   DB #00,#00,#00           ; банк 1: #000000
        DB #00,#C0,#00           ; банк 2: #00C000
        DB #00,#80,#01           ; банк 3: #018000
        DB #00,#40,#02           ; банк 4: #024000

; D строк страницы E: по 256 байт с шагом 512 — DMA ОЗУ -> SPI на строку.
FTLINES LD H,0
FTL1    XOR A:LD BC,FT_DSL:OUT (C),A
        LD A,H:LD B,HIGH FT_DSH:OUT (C),A
        LD A,E:LD B,HIGH FT_DSX:OUT (C),A
        LD A,127:LD B,HIGH FT_DLEN:OUT (C),A
        XOR A:LD B,HIGH FT_DNUM:OUT (C),A
        LD A,FT_RSPI:LD B,HIGH FT_DCTR:OUT (C),A
FTL2    IN A,(C):RLCA:JR C,FTL2
        INC H:INC H
        DEC D:JR NZ,FTL1
        RET

;---------------------------------------
; SPI FT812 (как в TXTVIEW2: ft812.asm).
FTSELS  LD A,FT_SEL:OUT (FT_CTRL),A:RET
FTOFF   LD A,FT_IDLE:OUT (FT_CTRL),A:RET

; Команда хоста A с параметром C; затем кадр паузы.
FTHOST  PUSH AF:CALL FTSELS:POP AF
        OUT (FT_DATA),A
        LD A,C:OUT (FT_DATA),A
        XOR A:OUT (FT_DATA),A
        CALL FTOFF
        EI:HALT
        RET

; Начать запись с адреса A:HL (A — биты 21..16). Чип остаётся выбранным.
FTWR    PUSH AF:CALL FTSELS:POP AF
        OR #80:OUT (FT_DATA),A
        LD A,H:OUT (FT_DATA),A
        LD A,L:OUT (FT_DATA),A
        RET

; Записать байт E в регистр #30:HL.
FTWR8   LD A,#30:CALL FTWR
        LD A,E:OUT (FT_DATA),A
        JP FTOFF

; Прочитать 16 бит регистра #30:HL. Выход: HL.
FTRD16  CALL FTSELS
        LD A,#30:OUT (FT_DATA),A
        LD A,H:OUT (FT_DATA),A
        LD A,L:OUT (FT_DATA),A
        OUT (FT_DATA),A          ; пустой байт: чип готовит данные
        IN A,(FT_DATA)           ; ответ на пустой байт не нужен
        IN A,(FT_DATA):LD L,A
        IN A,(FT_DATA):LD H,A
        JP FTOFF

; Таблица «регистр #30xxxx, длина, значение»; конец — нулевой регистр.
FTREGS  LD E,(HL):INC HL:LD D,(HL):INC HL
        LD A,D:OR E:RET Z
        LD B,(HL):INC HL
        EX DE,HL:LD A,#30:CALL FTWR:EX DE,HL
FTR1    LD A,(HL):INC HL:OUT (FT_DATA),A
        DJNZ FTR1
        CALL FTOFF
        JR FTREGS

; Команды хоста: PWRDOWN, ACTIVE, SLEEP, CLKEXT, CLKSEL x8 (64 МГц),
; ACTIVE, RST_PULSE.
FTHOSTS DB #43,0,#00,0,#42,0,#44,0,#61,8+#40,#00,0,#68,0,#FF

; Развёртка 1024x768@59 — как в FTView и TXTVIEW2: строка 1344 точки (24 до
; синхроимпульса, 136 импульс, 160 после, 1024 видимых), кадр 806 строк.
; Нестандартную частоту (48,8 Гц) монитор ставил со сдвигом картинки.
FTREG1  DW #2070:DB 1,0          ; PCLK: вывод стоит
        DW #202C:DB 2:DW 1344    ; HCYCLE
        DW #2030:DB 2:DW 320     ; HOFFSET
        DW #2038:DB 2:DW 24      ; HSYNC0
        DW #203C:DB 2:DW 160     ; HSYNC1
        DW #2040:DB 2:DW 806     ; VCYCLE
        DW #2044:DB 2:DW 37      ; VOFFSET
        DW #204C:DB 2:DW 2       ; VSYNC0
        DW #2050:DB 2:DW 8       ; VSYNC1
        DW #2034:DB 2:DW 1024    ; HSIZE
        DW #2048:DB 2:DW 768     ; VSIZE
        DW #2064:DB 1,0          ; SWIZZLE
        DW #206C:DB 1,0          ; PCLK_POL
        DW #2068:DB 1,0          ; CSPREAD
        DW 0
FTREG2  DW #257C:DB 1,0          ; ADAPTIVE_FRAMERATE
        DW #2098:DB 4:DD #8000   ; GPIOX_DIR
        DW #209C:DB 4:DD #9200   ; GPIOX
        DW #2070:DB 1,1          ; PCLK: 64 МГц, вывод пошёл
        DW #20AC:DB 1,0          ; INT_EN
        DW 0

; Чёрный экран до первого кадра.
FTDLB   DD #02000000             ; CLEAR_COLOR_RGB(0,0,0)
        DD #26000007             ; CLEAR(1,1,1)
        DD #00000000             ; DISPLAY

; Дисплей-лист кадра; поля помечены — их заполняют FTSTART и FTDL.
FTDLT   DD #02000000             ; CLEAR_COLOR_RGB(0,0,0)
        DD #26000007             ; CLEAR(1,1,1)
        DD #05000000             ; BITMAP_HANDLE(0)
FTDLS   DD #01000000             ; BITMAP_SOURCE: кадр банка
        DB 0                     ; BITMAP_LAYOUT(PALETTED565, 256, высота)
FTDLL   EQU $-1
        DB #00,#72,#07
FTDLZ   DB 0,0,#10,#08           ; BITMAP_SIZE(BILINEAR, BORDER, 1024, высота*4)
        DD #28000000             ; BITMAP_LAYOUT_H(0, 0)
FTDLH   DB 8,0,0,#29             ; BITMAP_SIZE_H(1024>>9, высота*4>>9)
        DD #15000040             ; BITMAP_TRANSFORM_A: 64/256 — x4
        DD #19000040             ; BITMAP_TRANSFORM_E: x4
FTDLP   DD #2A030000             ; PALETTE_SOURCE: палитра банка
        DD #1F000001             ; BEGIN(BITMAPS)
FTDLV   DD #80000000             ; VERTEX2II(0, отступ сверху, 0, 0)
        DD #21000000             ; END
        DD #00000000             ; DISPLAY
FTDLN   EQU $-FTDLT

FTOK    NOP                      ; 1 — FT812 запущен (FTBOOT)
FTON    NOP                      ; 1 — вывод на FT812
FTGO    NOP                      ; 1 — первый кадр показан
FTUL    NOP                      ; банк, который сейчас уходит в FT812
FTG     NOP
FTPG    NOP
FTPP    NOP
FTAX    NOP
FTLL    NOP
FTT5    NOP
FTAD    DW 0
FTT     DW 0                     ; кадр FT812 для следующей смены
FTTF    NOP                      ; и его дробная часть (/256)
