; Формат HEX и ограниченные чтения из TXTVIEW v0.26.
HexRow:
        CALL ClearLine
        LD HL,Position
        LD DE,FileSize
        CALL Compare32
        RET NC
        LD HL,Position
        LD DE,LineBuffer
        CALL Hex32
        LD B,16
        LD DE,LineBuffer+9
        LD HL,LineBuffer+58
.loop:
        CALL ReadByte
        RET C
        PUSH AF
        CP 32
        JR C,.dot
        CP #7F
        JR NZ,.ascii
.dot:
        LD A,"."
.ascii:
        LD (HL),A
        INC HL
        POP AF
        CALL Hex8
        INC DE
        DJNZ .loop
        RET

; HL -> LE32, DE -> 8 печатных HEX-цифр. BC/HL/DE/AF разрушаются.
Hex32:
        LD BC,3
        ADD HL,BC
        LD B,4
.loop:
        LD A,(HL)
        CALL Hex8
        DEC HL
        DJNZ .loop
        RET
; A -> две HEX-цифры по DE. BC/HL сохраняются, DE увеличивается на 2.
Hex8:
        PUSH AF
        RRCA
        RRCA
        RRCA
        RRCA
        CALL .nibble
        POP AF
.nibble:
        AND 15
        ADD A,"0"
        CP "9"+1
        JR C,.digit
        ADD A,7
.digit:
        LD (DE),A
        INC DE
        RET
