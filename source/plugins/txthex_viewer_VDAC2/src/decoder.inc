; Строгий декодер v0.26: DE и Decoded содержат Unicode BMP.
ReadChar:
        PUSH BC
        PUSH DE
        PUSH HL
        CALL DecodeChar
        JR C,.done
        LD (Decoded),DE
.done:
        POP HL
        POP DE
        POP BC
        RET
DecodeChar:
        CALL ReadByte
        RET C
        CP #80
        JR NC,.high
        LD E,A
        LD D,0
        OR A                            ; ASCII #00 — данные, CF не является EOF
        RET
.high:
        LD B,A
        LD A,(Encoding)
        OR A
        LD A,B
        JP Z,Byte866
        PUSH AF
        LD A,(Encoding)
        CP 1
        JR NZ,.utf
        POP AF
        LD HL,Unicode1251
        JP ByteTable
.utf:
        POP AF
        LD (UtfFirst),A
        LD B,A
        LD A,1
        LD (UtfSeen),A
        LD A,B
        CP #C2
        JP C,InvalidUtf
        CP #F5
        JP NC,InvalidUtf
        LD C,1
        CP #E0
        JR C,.two
        INC C
        CP #F0
        JR C,.three
        INC C
        AND 7
        JR .start
.three:
        AND 15
        JR .start
.two:
        AND 31
.start:
        LD E,A
        LD D,0
        LD A,C
        LD (UtfRemaining),A
        ; Дополнительные границы второго байта нужны до его потребления.
        CALL PeekByte
        JP C,InvalidUtf
        LD B,A
        LD A,(UtfFirst)
        CP #E0
        JR NZ,.surrogate
        LD A,B
        CP #A0
        JP C,InvalidUtf
.surrogate:
        LD A,(UtfFirst)
        CP #ED
        JR NZ,.overlong4
        LD A,B
        CP #A0
        JP NC,InvalidUtf
.overlong4:
        LD A,(UtfFirst)
        CP #F0
        JR NZ,.max
        LD A,B
        CP #90
        JP C,InvalidUtf
.max:
        LD A,(UtfFirst)
        CP #F4
        JR NZ,.continuation
        LD A,B
        CP #90
        JP NC,InvalidUtf
.continuation:
        CALL PeekByte
        JP C,InvalidUtf
        CP #80
        JP C,InvalidUtf
        CP #C0
        JP NC,InvalidUtf
        CALL ReadByte
        AND #3F
        LD B,A
        DUP 6
          SLA E
          RL D
        EDUP
        LD A,E
        OR B
        LD E,A
        LD HL,UtfRemaining
        DEC (HL)
        JR NZ,.continuation
        LD A,(UtfFirst)
        CP #F0
        JR C,.ok
        LD DE,#FFFD                    ; редкие символы вне BMP занимают одну клетку
.ok:
        OR A
        RET

InvalidUtf:
        LD A,1
        LD (UtfBad),A
        LD DE,#FFFD
        OR A
        RET
