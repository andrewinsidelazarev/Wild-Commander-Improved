; Поиск исходных байтов из TXTVIEW v0.26. Ввод WC — CP866.
; Удаляем только правые пробелы поля ввода. Внутренние пробелы — часть запроса.
; Максимум 40 CP866-символов даёт 120 байт UTF-8, что помещается в SearchBuffer.
BuildSearch:
        LD HL,InputBuffer+InputLength-1
        LD B,InputLength
.trim:
        LD A,(HL)
        CP " "
        JR NZ,.length
        DEC HL
        DJNZ .trim
.length:
        XOR A
        LD (SearchLength),A
        LD A,B
        OR A
        RET Z
        LD HL,InputBuffer
        LD DE,SearchBuffer
.loop:
        LD A,(HL)
        INC HL
        PUSH HL
        PUSH BC
        LD B,A
        LD A,(Encoding)
        OR A
        LD A,B
        JR Z,.single
        CP #80
        JR C,.single
        LD C,A
        LD A,(Encoding)
        CP 1
        LD A,C
        JR NZ,.utf
        SUB #80
        LD L,A
        LD H,0
        LD BC,DosToWindows
        ADD HL,BC
        LD A,(HL)
.single:
        LD (DE),A
        INC DE
        JR .next
.utf:
        SUB #80
        LD L,A
        LD H,0
        ADD HL,HL
        LD BC,Unicode866
        ADD HL,BC
        LD C,(HL)
        INC HL
        LD B,(HL)                      ; BC=Unicode, DE=выходной UTF-8
        LD A,B
        CP 8
        JR C,.two
        LD A,B
        RRCA
        RRCA
        RRCA
        RRCA
        AND 15
        OR #E0
        LD (DE),A
        INC DE
        LD A,B
        AND 15
        LD H,A
        LD A,C
        RLCA
        RLCA
        AND 3
        LD L,A
        LD A,H
        ADD A,A
        ADD A,A
        OR L
        OR #80
        LD (DE),A
        INC DE
        JR .last
.two:
        LD A,B
        ADD A,A
        ADD A,A
        LD H,A
        LD A,C
        RLCA
        RLCA
        AND 3
        OR H
        OR #C0
        LD (DE),A
        INC DE
.last:
        LD A,C
        AND #3F
        OR #80
        LD (DE),A
        INC DE
.next:
        POP BC
        POP HL
        DJNZ .loop
        EX DE,HL
        LD DE,SearchBuffer
        OR A
        SBC HL,DE
        LD A,L
        LD (SearchLength),A
        RET

SearchNext:
        LD A,(SearchLength)
        OR A
        RET Z
        CALL BeginCommand
        LD A,(SearchAgain)
        CP 1
        JR NZ,.advance
        LD HL,SearchStart
        LD DE,Position
        CALL Copy32
.advance:
        LD HL,Position
        LD DE,FileSize
        CALL Compare32
        JR NC,SearchNotFound
        LD HL,Position
        CALL Increment32
FindBytes:
        CALL DrawFooter
.candidate:
        LD HL,Position
        LD DE,Candidate
        CALL Copy32
        LD A,(SearchLength)
        LD B,A
        LD HL,SearchBuffer
.compare:
        CALL ReadByte
        JR C,.end
        CP (HL)
        JR NZ,.next
        INC HL
        DJNZ .compare
        LD HL,Candidate
        LD DE,SearchStart
        CALL Copy32
        LD HL,Candidate
        LD DE,Position
        CALL Copy32
        LD A,1
        LD (SearchAgain),A
        LD A,(HexMode)
        OR A
        JR Z,.found
        LD A,(Position)
        AND #F0
        LD (Position),A
.found:
        JP FinishCommand
.next:
        LD HL,Candidate
        LD DE,Position
        CALL Copy32
        LD HL,Position
        CALL Increment32
        JR .candidate
.end:
        LD A,(IoError)
        LD B,A
        LD A,(Cancelled)
        OR B
        JP NZ,FinishCommand
SearchNotFound:
        LD A,2
        LD (SearchAgain),A
        XOR A
        LD (AllowCancel),A
        JP DrawFooter

ViewWindow:
        DB 3,0,0,0,0,0,#17,0
        DW 0
        DB 0,0
MessageWindow:
        DB 4+16+128,0,255,255,66,17,#4F,0
        DW 0
        DB 0,0
MessageTitle:  DW 0
MessageBottom: DW 0
MessageBody:   DW 0
SearchWindow:
        DB 4+16+128,0,255,255,42,3,#4F,0
        DW 0
        DB 0,0
SearchTitle:   DW 0
        DW 0,0

LabelText: DB "TEXT"
LabelHex:  DB "HEX "
EncodingNames:
        DW Name866,Name1251,NameUtf8
Name866:  DB "CP866 "
Name1251: DB "CP1251"
NameUtf8: DB "UTF-8 "
