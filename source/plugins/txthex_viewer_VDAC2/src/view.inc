; Сначала читаем нужные строки в RAM Z80, затем передаём кадр FT812. Это
; исключает обращение драйвера SD к общей SPI-шине при выбранном FT812.
; В сетке храним 16-битные номера глифов, а не байты CP866: Unicode не теряется.
ClearLine:
        LD HL,LineBuffer
        LD DE,LineBuffer+1
        LD BC,89
        LD (HL)," "
        LDIR
        LD HL,LineGlyphs
        LD DE,LineGlyphs+1
        LD BC,SCREEN_COLUMNS*2-1
        LD (HL),0                      ; глиф 0 = обычный пробел U+0020
        LDIR
        XOR A
        LD (Column),A
        RET
TextRow:
        CALL ClearLine
.loop:
        CALL ReadCluster
        RET C
        CP 13
        JP Z,ConsumeLF
        CP 10
        RET Z
        CP 9
        JR Z,.tab
        CALL EmitGlyph
        JR NZ,.loop
        JP ConsumeEol
.tab:
        LD HL,0
        CALL EmitGlyph
        JP Z,ConsumeEol
        LD A,(Column)
        AND 7
        JR NZ,.tab
        JR .loop
EmitGlyph:
        EX DE,HL
        LD A,(Column)
        LD L,A
        LD H,0
        ADD HL,HL
        LD BC,LineGlyphs
        ADD HL,BC
        LD (HL),E
        INC HL
        LD (HL),D
        INC A
        LD (Column),A
        LD HL,Width
        CP (HL)
        RET
ConsumeEol:
        CALL PeekByte
        RET C
        CP 13
        JR Z,.cr
        CP 10
        RET NZ
        JP ReadByte
.cr:
        CALL ReadByte
ConsumeLF:
        CALL PeekByte
        RET C
        CP 10
        RET NZ
        JP ReadByte
RenderRow:
        LD HL,Position
        LD DE,RowBegin
        CALL Copy32
        LD A,(HexMode)
        OR A
        JR NZ,.hex
        CALL TextRow
        JP RememberRow
.hex:
        CALL HexRow
        LD HL,LineBuffer
        LD DE,LineGlyphs
        LD B,SCREEN_COLUMNS
.convert:
        PUSH BC
        PUSH HL
        PUSH DE
        LD A,(HL)
        CALL Byte866
        CALL LookupGlyph
        POP DE
        LD A,L
        LD (DE),A
        INC DE
        LD A,H
        LD (DE),A
        INC DE
        POP HL
        POP BC
        INC HL
        DJNZ .convert
        RET
DrawPage:
        XOR A
        LD (PageGridValid),A
        LD (RowRing),A
        LD HL,Top
        LD DE,Position
        CALL Copy32
        XOR A
        LD (DrawY),A
        LD HL,GRID
        LD (GridWrite),HL
.loop:
        LD A,(DrawY)
        LD L,A
        LD H,0
        ADD HL,HL
        ADD HL,HL
        LD DE,RowOffsets
        ADD HL,DE
        EX DE,HL
        LD HL,Position
        CALL Copy32
        CALL RenderRow
        CALL MapGrid
        LD DE,(GridWrite)
        LD HL,LineGlyphs
        LD BC,SCREEN_COLUMNS*2
        LDIR
        LD (GridWrite),DE
        LD HL,DrawY
        INC (HL)
        LD A,SCREEN_ROWS
        CP (HL)
        JR NZ,.loop
        LD HL,Position
        LD DE,PageAfter
        CALL Copy32
        ; Кольцо содержит одну невидимую полосу. Полный кадр начинается с
        ; RowRing=0, поэтому запасная полоса последняя. Инициализируем также
        ; её глифы: зеркало и bitmap впервые заполнятся общим CachePage.
        LD HL,GRID+SCREEN_ROWS*SCREEN_COLUMNS*2
        LD DE,GRID+SCREEN_ROWS*SCREEN_COLUMNS*2+1
        LD BC,SCREEN_COLUMNS*2-1
        LD (HL),0
        LDIR
        LD A,1
        LD (GridDirty),A
        CALL ScrollCheck
        LD A,0
        JR NZ,.valid
        INC A
.valid:
        LD (PageGridValid),A
DrawFooter:
        JP PresentScreen
DrawHeader:
        RET

; A = физическая полоса 0..22, HL = её сетка глифов в видеостранице Z80.
; При Up/Down сетка, её зеркало и bitmap в RAM_G сохраняют свои места:
; меняется только RowRing, а освободившаяся полоса принимает новую строку.
SlotAddress:
        LD HL,GRID
        LD DE,SCREEN_COLUMNS*2
        OR A
        RET Z
        LD B,A
.loop:
        ADD HL,DE
        DJNZ .loop
        RET
