; Текст страницы заранее собран в RAM_G: одна bitmap-полоса на строку.
; FT812 заново читает ВЕСЬ дисплей-лист на каждой растровой строке.
; 1997 слов прежнего плотного кадра не укладывались в HCYCLE=1344/PCLK=1.
; CMD_MEMCPY выполняется только при изменении сетки и не попадает в RAM_DL.
        MACRO DLW value
          LD HL,(value) & #FFFF
          LD DE,((value) >> 16) & #FFFF
          CALL Cmd_Word
        ENDM
        MACRO LABEL text, ypos, limit
          LD HL,ypos
          LD (PenY),HL
          LD HL,text
          LD B,limit
          CALL DrawString
        ENDM

PresentScreen:
        LD A,(FtReady)
        OR A
        RET Z
        LD A,(FtFault)
        OR A
        RET NZ
        LD A,(Modal)
        OR A
        JR NZ,.begin
        LD A,(GridDirty)
        OR A
        CALL NZ,CachePage
        LD A,(FtFault)
        OR A
        RET NZ
.begin:
        CALL Cmd_Begin
        DLW #FFFFFF00                 ; CMD_DLSTART
        LD HL,FrameSetup
        LD BC,FrameSetupEnd-FrameSetup
        CALL Cmd_Block
        LD HL,FontSetup
        LD BC,FontSetupEnd-FontSetup
        CALL Cmd_Block
        ; Атлас хранит столбцы подряд: (s,t)=(y,x). NEAREST сохраняет L4.
        DLW #15000000                 ; BITMAP_TRANSFORM_A(0)
        DLW #16000100                 ; BITMAP_TRANSFORM_B(256)
        DLW #17000000                 ; BITMAP_TRANSFORM_C(0)
        DLW #18000100                 ; BITMAP_TRANSFORM_D(256)
        DLW #19000000                 ; BITMAP_TRANSFORM_E(0)
        DLW #1A000000                 ; BITMAP_TRANSFORM_F(0)
        DLW #1F000001                 ; BEGIN(BITMAPS)
        ; Компактная верхняя панель содержит только режим, кодировку и позицию.
        ; FileName нужен файловому API WC, но отдельной строки на экране не имеет.
        CALL StatusLine
        DLW #0496A7BF
        LABEL StatusBuffer,BAR_TEXT_Y,78
        DLW #04D9E5F5
        LD A,(Modal)
        CP 1
        JP Z,.help
        CP 2
        JP Z,.search
        ; Handle 31 свободен от шрифта. Полоса содержит 78 глифов подряд,
        ; поэтому её исходная высота 936, а видимые размеры — 936x34.
        DLW #0500001F
        DLW #07000000 | (2 << 19) | (FONT_STRIDE << 9) | ((SCREEN_COLUMNS*12) & 511)
        DLW #28000001                 ; BITMAP_LAYOUT_H: высота 512..1023
        DLW #08000000 | (((SCREEN_COLUMNS*12) & 511) << 9) | 34
        DLW #29000004                 ; BITMAP_SIZE_H: ширина 512..1023
        LD HL,TEXT_TOP
        LD (PenY),HL
        LD A,(RowRing)
        LD C,A
        LD B,SCREEN_ROWS
.row:
        PUSH BC
        LD A,C
        CALL StripAddress
        CALL Cmd_Word                  ; BITMAP_SOURCE этой полосы
        LD HL,34
        LD (PenX),HL
        CALL Translations
        LD HL,31*128                   ; VERTEX2II: handle 31, cell 0
        CALL Glyph
        POP BC
        LD HL,(PenY)
        LD DE,TEXT_STEP
        ADD HL,DE
        LD (PenY),HL
        INC C
        LD A,C
        CP CACHE_ROWS
        JR C,.source_ready
        LD C,0
.source_ready:
        DJNZ .row
        JP .footer
.help:
        LD HL,HelpLines
        LD DE,TEXT_TOP+12
.help_row:
        LD (PenY),DE
        LD E,(HL)
        INC HL
        LD D,(HL)
        INC HL
        LD A,D
        OR E
        JP Z,.footer
        PUSH HL
        EX DE,HL
        LD B,78
        CALL DrawString
        LD HL,(PenY)
        LD DE,34
        ADD HL,DE
        EX DE,HL
        POP HL
        JR .help_row
.search:
        DLW #0438BDF8
        LABEL SearchEnglish,TEXT_TOP+36,78
        DLW #04E2E8F0
        LABEL InputBuffer,TEXT_TOP+100,40
        ; ISTR хранит горизонтальную позицию курсора в #7824. Это тот же
        ; опубликованный блок PS2P, что WC_LANG; окно имеет ширину ровно 40.
        LD A,(#7824)
        CP 40
        JR C,.cursor
        XOR A
.cursor:
        LD L,A
        LD H,0
        ADD HL,HL
        ADD HL,HL
        LD D,H
        LD E,L
        ADD HL,HL
        ADD HL,DE
        LD DE,32
        ADD HL,DE
        LD (PenX),HL
        LD HL,TEXT_TOP+124
        LD (PenY),HL
        CALL Translations
        LD HL,"^"-32
        CALL Glyph
        DLW #0496A7BF
        LABEL SearchHint,TEXT_TOP+176,78
        LABEL SearchHint2,TEXT_TOP+216,78
.footer:
        ; Старшие поля размеров не являются общими для всех handles,
        ; поэтому настройка полосы 31 не меняет геометрию глифов панелей.
        DLW #0496A7BF
        LABEL Shortcuts,FOOTER_TOP+BAR_TEXT_Y,78
        DLW #21000000                 ; END
        DLW 0                         ; DISPLAY
        DLW #FFFFFF01                 ; CMD_SWAP
        CALL Cmd_End
        CALL FT_WaitIdle
        RET NC
        LD A,1
        LD (FtFault),A
        RET

; HL=байтовая строка CP866, B=предел. Входы DrawString — постоянная память
; #8000; таблица Unicode может безопасно переключать нижнее окно страниц.
DrawString:
        PUSH HL
        PUSH BC
        LD HL,34
        LD (PenX),HL
        CALL Translations
        POP BC
        POP HL
.loop:
        LD A,(HL)
        OR A
        RET Z
        PUSH HL
        PUSH BC
        CP 32
        JR NC,.valid
        LD A,"."
.valid:
        CALL Byte866
        CALL LookupGlyph
        CALL Glyph
        POP BC
        POP HL
        INC HL
        DJNZ .loop
        RET

Translations:
        XOR A
        LD (TranslatedX),A
        DLW #2B000000                 ; VERTEX_TRANSLATE_X(0)
        LD A,(PenY+1)
        AND 2
        LD HL,0
        JR Z,.y
        LD HL,#2000                   ; 512 точек в единицах 1/16
.y:
        LD DE,#2C00
        CALL Cmd_Word
        ; Явно ограничиваем растровую обработку текущей строки. Высота
        ; исходной транспонированной полосы 936 не должна расширять работу
        ; за пределы её видимой высоты 34. SCISSOR использует абсолютные
        ; координаты, независимо от VERTEX_TRANSLATE_Y для области >511.
        ; Все 34 ряда глифа, включая диакритики и нижние выносные элементы,
        ; остаются внутри отсечения; соседние строки могут перекрываться.
        LD HL,(PenY)
        LD DE,#1B00                   ; SCISSOR_XY(0,PenY)
        CALL Cmd_Word
        DLW #1C000000 | (1024 << 12) | 34
        RET

; HL=глиф, PenX/PenY=пиксели. Для пробела двигаем перо без команды, но
; размер плотного кадра рассчитан также для случая без единого пробела.
Glyph:
        LD (GlyphNumber),HL
        LD A,H
        OR L
        JR Z,.advance
        LD A,(PenX+1)
        AND 2
        JR Z,.vertex
        LD A,(TranslatedX)
        OR A
        JR NZ,.vertex
        INC A
        LD (TranslatedX),A
        DLW #2B002000
.vertex:
        LD HL,(GlyphNumber)
        LD A,(PenY)
        AND 15
        RLCA
        RLCA
        RLCA
        RLCA
        OR H
        LD H,A
        LD A,(PenY+1)
        AND 1
        LD E,A
        LD A,(PenY)
        DUP 4
          SRL E
          RRA
        EDUP
        AND 31
        LD E,A
        LD A,(PenX)
        AND 7
        RRCA
        RRCA
        RRCA
        OR E
        LD E,A
        LD A,(PenX+1)
        AND 1
        LD D,A
        LD A,(PenX)
        DUP 3
          SRL D
          RRA
        EDUP
        OR #80
        LD D,A
        CALL Cmd_Word
.advance:
        LD HL,(PenX)
        LD DE,12
        ADD HL,DE
        LD (PenX),HL
        RET

StatusLine:
        LD HL,StatusTemplate
        LD DE,StatusBuffer
        LD BC,StatusTemplateEnd-StatusTemplate
        LDIR
        LD HL,LabelText
        LD A,(HexMode)
        OR A
        JR Z,.mode
        LD HL,LabelHex
.mode:
        LD DE,StatusBuffer
        LD BC,4
        LDIR
        LD A,(Choice)
        OR A
        JR Z,.encoding
        LD HL,ManualLabel
        LD DE,StatusBuffer+6
        LD BC,4
        LDIR
.encoding:
        LD A,(Encoding)
        ADD A,A
        LD L,A
        LD H,0
        LD DE,EncodingNames
        ADD HL,DE
        LD E,(HL)
        INC HL
        LD D,(HL)
        EX DE,HL
        LD DE,StatusBuffer+12
        LD BC,6
        LDIR
        LD HL,Top
        LD DE,StatusBuffer+29
        CALL Hex32
        LD HL,FileSize
        LD DE,StatusBuffer+40
        CALL Hex32
        LD HL,ReadyLabel
        LD A,(SearchAgain)
        CP 2
        JR NZ,.busy
        LD HL,NotFoundLabel
.busy:
        LD A,(AllowCancel)
        OR A
        JR Z,.error
        LD HL,BusyLabel
.error:
        LD A,(IoError)
        OR A
        JR Z,.status
        LD HL,IoLabel
.status:
        LD DE,StatusBuffer+52
        LD BC,18
        LDIR
        JP ScrollPercent

; Целый процент Top/FileSize. Если виден конец файла, выводим 100%,
; включая короткий/пустой файл. Считаем точно для всех 32-битных размеров:
; 100 сложений с остатком вместо переполняющегося произведения Top*100.
; При переносе из бита 31 вычитание делителя обязательно; остаток после
; него снова меньше FileSize. Здесь нет файловых API и переключения банков.
ScrollPercent:
        LD HL,PageAfter
        LD DE,FileSize
        CALL Compare32
        JR NC,.end
        LD HL,Top
        LD DE,FileSize
        CALL Compare32
        JR NC,.end
        LD HL,PercentRemainder
        CALL Zero32
        LD BC,100*256
.loop:
        PUSH BC
        LD HL,(PercentRemainder)
        LD BC,(Top)
        ADD HL,BC
        LD (PercentRemainder),HL
        LD HL,(PercentRemainder+2)
        LD BC,(Top+2)
        ADC HL,BC
        LD (PercentRemainder+2),HL
        JR C,.subtract
        LD HL,PercentRemainder
        LD DE,FileSize
        CALL Compare32
        JR C,.next
.subtract:
        LD HL,(PercentRemainder)
        LD DE,(FileSize)
        OR A
        SBC HL,DE
        LD (PercentRemainder),HL
        LD HL,(PercentRemainder+2)
        LD DE,(FileSize+2)
        SBC HL,DE
        LD (PercentRemainder+2),HL
        POP BC
        INC C
        JR .count
.next:
        POP BC
.count:
        DJNZ .loop
        LD A,C
        LD B,"0"-1
.tens:
        INC B
        SUB 10
        JR NC,.tens
        ADD A,10+"0"
        LD (PercentField+2),A
        LD A,B
        CP "0"
        RET Z
        LD (PercentField+1),A
        RET
.end:
        LD HL,"1" | ("0" << 8)
        LD (PercentField),HL
        LD A,"0"
        LD (PercentField+2),A
        RET

; Векторная основа: тёмная рабочая область и две компактные панели.
; По левому краю нет декоративной полосы: весь фон занимает полезную ширину.
; VERTEX2F со стандартной дробной частью имеет предел +1023.9375 пикселя.
; Координата 1024 дала бы отрицательный X. Правая грань 1023 и ширина линии
; в один пиксель закрывают край экрана без знакового переполнения координат.
FrameSetup:
        ; Отсечение в конце прошлого DL не должно влиять на CLEAR и панели.
        DD #1B000000,#1C400300          ; полный экран 1024x768
        DD #020B1220,#26000007,#04121E30,#1F000009,#0E000010
        DD #40000000 | (0 << 19) | (0 << 4)
        DD #40000000 | (1023 << 19) | (HEADER_BOTTOM << 4)
        DD #40000000 | (0 << 19) | (FOOTER_TOP << 4)
        DD #40000000 | (1023 << 19) | (767 << 4)
        DD #04293850
        DD #40000000 | (0 << 19) | ((HEADER_BOTTOM-1) << 4)
        DD #40000000 | (1023 << 19) | (HEADER_BOTTOM << 4)
        DD #40000000 | (0 << 19) | ((FOOTER_TOP-1) << 4)
        DD #40000000 | (1023 << 19) | (FOOTER_TOP << 4)
        DD #21000000
FrameSetupEnd:
Shortcuts: DB "F1 Help   Tab TXT/HEX   F8 Encoding   Ctrl+F Find   Ctrl+G Next   Esc Close",0
StatusTemplate: DB "TEXT  Auto: UTF-8     OFFSET 00000000 / 00000000    Ready             "
        DS 74-($-StatusTemplate)," "
        DB "  0%",0                    ; последние четыре колонки верхней строки
StatusTemplateEnd:
ManualLabel: DB "Man."
ReadyLabel: DB "Ready             "
NotFoundLabel: DB "Text not found    "
BusyLabel: DB "Working... Esc    "
IoLabel: DB "Read error        "
SearchHint: DB "Enter  Find     Esc  Cancel     Ctrl+Shift  Keyboard language",0
SearchHint2: DB "Case sensitive. Input: Latin / Russian (CP866), up to 40 characters.",0
HelpLines:
        DW Help0,Help1,Help2,Help3,Help4,Help5,Help6,Help7,Help8,Help9,Help10,Help11,Help12,Help13,Help14,0
Help0: DB "KEYBOARD & TEXT",0
Help1: DB "Up / Down         Move by one screen row",0
Help2: DB "PgUp / PgDn       Move by one page",0
Help3: DB "Home / End        Start / end of file",0
Help4: DB "Tab               Switch TXT / HEX; restart at beginning",0
Help5: DB "F8                Auto > CP866 > CP1251 > UTF-8 > Auto",0
Help6: DB "Ctrl+F / Ctrl+G   Find text / find next (case sensitive)",0
Help7: DB "Esc               Cancel a long scan; close when idle",0
Help8: DB "Space             Close viewer",0
Help9: DB "Long lines wrap. Tab stops: 8 columns. CR, LF and CRLF supported.",0
Help10: DB "UTF-8 BOM is hidden. Latin, Greek and extended Cyrillic glyphs.",0
Help11: DB "Unknown or invalid characters use a replacement glyph.",0
Help12: DB "Auto detection is heuristic. Use F8 if the text looks wrong.",0
Help13: DB "Offsets / sizes are HEX, up to FFFFFFFF. File is read only.",0
Help14: DB "Press any key to return.",0

GraphicsState:
FtReady: DB 0
Modal: DB 0
GridDirty: DB 0
CacheValidGrid: DB 0
RowRing: DB 0                          ; физическая полоса верхней экранной строки
PageGridValid: DB 0                    ; RowOffsets и кольцо собраны для текущего Top
PercentRemainder: DD 0
TranslatedX: DB 0
Decoded: DW 0
Wanted: DW 0
Mid: DW 0
Cluster: DW 0
MarkPosition: DD 0
GridWrite: DW 0
PenX: DW 0
PenY: DW 0
GlyphNumber: DW 0
StatusBuffer: DS 80,0
PercentField: EQU StatusBuffer+74
LineGlyphs: DS SCREEN_COLUMNS*2,0
GraphicsStateEnd:

; Сетка находится в свободной видеостранице; #3000 — её последний
; переданный снимок. Код не обращается к диску при выбранном FT812.
; Вход: GridDirty=1 (все полосы) или 2..24 (одна полоса), FtReady=1.
; Выход: FtFault при отказе FIFO; иначе
; GridDirty=0, CacheValidGrid=1. AF/BC/DE/HL меняются, IX/IY сохраняются.
; 22 видимых полосы и одна запасная занимают 365976 байт после атласа,
; всего 949824 < 1 МиБ. При прокрутке копирование идёт в невидимую полосу,
; затем CMD_SWAP одновременно меняет позиции всех готовых строк.
; Сравнение с предыдущей сеткой исключает копирование неизменённых клеток.
CachePage:
        CALL MapGrid
        CALL Cmd_Begin
        LD A,(GridDirty)
        CP 1
        JR Z,.full
        SUB 2
        PUSH AF
        CALL SlotAddress
        POP AF
        LD BC,SCREEN_COLUMNS
        JR .address
.full:
        XOR A
        LD HL,GRID
        LD BC,SCREEN_COLUMNS*CACHE_ROWS
.address:
        PUSH HL
        PUSH BC
        CALL StripAddress
        LD (CopyGlyphPacket+4),HL
        LD A,E
        LD (CopyGlyphPacket+6),A
        POP BC
        POP HL
        LD D,H
        LD E,L
        SET 4,D                        ; #2xxx -> #3xxx, зеркало этой полосы
.cell:
        PUSH BC
        LD C,(HL)
        INC HL
        LD B,(HL)
        INC HL
        PUSH HL
        LD A,(DE)
        XOR C
        LD H,A
        LD A,C
        LD (DE),A
        INC DE
        LD A,(DE)
        XOR B
        OR H
        LD H,A
        LD A,B
        LD (DE),A
        INC DE
        PUSH DE
        LD A,(CacheValidGrid)
        OR A
        JR Z,.copy
        LD A,H
        OR A
        JR Z,.next
.copy:
        ; 24-битный адрес = номер глифа * 204: 3 * 17 * 4.
        ; При переходах #FFFF/#1FFFF старший байт не теряется.
        LD H,B
        LD L,C
        LD D,B
        LD E,C
        ADD HL,HL
        ADD HL,DE
        LD D,H
        LD E,L
        XOR A
        DUP 4
          ADD HL,HL
          ADC A,A
        EDUP
        ADD HL,DE
        ADC A,0
        DUP 2
          ADD HL,HL
          ADC A,A
        EDUP
        LD (CopyGlyphPacket+8),HL
        LD (CopyGlyphPacket+10),A
        LD HL,CopyGlyphPacket
        LD BC,16
        CALL Cmd_Block
.next:
        LD HL,(CopyGlyphPacket+4)
        LD DE,FONT_CELL_BYTES
        ADD HL,DE
        LD (CopyGlyphPacket+4),HL
        JR NC,.advanced
        LD HL,CopyGlyphPacket+6
        INC (HL)
.advanced:
        POP DE
        POP HL
        POP BC
        DEC BC
        LD A,B
        OR C
        JP NZ,.cell
        CALL Cmd_End
        CALL FT_WaitIdle
        JR C,.fault
        LD A,(FtFault)
        OR A
        RET NZ
        LD (GridDirty),A
        INC A
        LD (CacheValidGrid),A
        RET
.fault:
        LD A,1
        LD (FtFault),A
        RET

; A = физическая полоса 0..22. DE:HL = BITMAP_SOURCE её bitmap в RAM_G.
; До 22 коротких сложений дешевле передачи даже одной лишней строки;
; старший байт учитывает переходы через 64 КиБ, D — код команды #01.
StripAddress:
        LD HL,FONT_RAM_BYTES & #FFFF
        LD C,FONT_RAM_BYTES >> 16
        LD DE,SCREEN_COLUMNS*FONT_CELL_BYTES
        OR A
        JR Z,.ready
        LD B,A
.loop:
        ADD HL,DE
        JR NC,.next
        INC C
.next:
        DJNZ .loop
.ready:
        LD E,C
        LD D,1
        RET
CopyGlyphPacket:
        DD #FFFFFF1D,0,0,FONT_CELL_BYTES ; CMD_MEMCPY(dst,src,bytes)
        ASSERT FONT_CELL_BYTES = 204
        ASSERT FONT_RAM_BYTES+SCREEN_COLUMNS*CACHE_ROWS*FONT_CELL_BYTES <= #100000
