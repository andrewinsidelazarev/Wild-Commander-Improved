; Пользовательский интерфейс, английская помощь и поиск.
; Все выводимые строки хранятся в CP866 (TABLES.INC); комментарии — UTF-8.
; API ISTR также возвращает CP866. Перед поиском запрос преобразуется в
; выбранную кодировку файла, но исходный файл остаётся только для чтения.
; По требованию пользователя нижний бар и вся страница помощи всегда
; английские, независимо от WC_LANG. Раскладка влияет на отдельные диалоги.

SelectLanguage:
        LD A,(WC_LANG)
        AND 1
        RET Z
        EX DE,HL
        RET

DrawHeader:
        CALL ClearLine
        LD HL,FileName+1
        LD DE,LineBuffer
        LD A,(Width)
        LD B,A
.loop:
        LD A,(HL)
        OR A
        JR Z,.print
        CP 32
        JR NC,.put
        LD A,"."
.put:
        LD (DE),A
        INC HL
        INC DE
        DJNZ .loop
.print:
        LD DE,0
        JP PrintLine

; Фиксированные поля укладываются в минимальную ширину 80. Номер позиции
; и размер имеют восемь HEX-разрядов, без старого ограничения адреса 24 битами.
DrawFooter:
        CALL ClearLine
        LD HL,LabelText
        LD A,(HexMode)
        OR A
        JR Z,.mode
        LD HL,LabelHex
.mode:
        LD DE,LineBuffer
        LD BC,4
        LDIR
        LD HL,LabelAutoEnglish
        LD A,(Choice)
        OR A
        JR Z,.choice
        LD HL,LabelManualEnglish
.choice:
        LD DE,LineBuffer+5
        LD BC,5
        LDIR
        LD A,(Encoding)
        LD L,A
        LD H,0
        ADD HL,HL
        LD DE,EncodingNames
        ADD HL,DE
        LD E,(HL)
        INC HL
        LD D,(HL)
        EX DE,HL
        LD DE,LineBuffer+10
        LD BC,6
        LDIR
        LD HL,Top
        LD DE,LineBuffer+18
        CALL Hex32
        LD A,"/"
        LD (DE),A
        INC DE
        LD HL,FileSize
        CALL Hex32
        LD HL,FooterEnglish
        LD DE,LineBuffer+37
        LD BC,32
        LDIR
        LD A,(IoError)
        OR A
        JR Z,.search
        LD HL,IoEnglish
        JR .status
.search:
        LD A,(AllowCancel)
        OR A
        JR Z,.not_busy
        LD HL,BusyEnglish
        JR .status
.not_busy:
        LD A,(SearchAgain)
        CP 2
        JR NZ,.print
        LD HL,NotFoundEnglish
.status:
        LD DE,LineBuffer+71
        LD BC,9
        LDIR
.print:
        LD A,(Rows)
        INC A
        LD D,A
        LD E,0
        JP PrintLine

ShowHelp:
        ; Помощь целиком английская: явно задаём также заголовок и нижнюю
        ; подсказку окна. WC_LANG не изменяем даже временно, чтобы показ F1
        ; не переключал раскладку следующего ввода и не влиял на прерывания.
        LD HL,HelpEnglish
        LD (MessageBody),HL
        LD HL,TitleEnglish
        LD (MessageTitle),HL
        LD HL,CloseEnglish
        LD (MessageBottom),HL
        CALL ShowMessageBox
        JP DrawFooter                   ; восстановить английские подписи бара

; HL=размеченный текст. Каждый показ заново задаёт центрирование и буфер
; фона: PRWOW меняет эти поля. IX вызывающего окна сохраняется.
MessageBox:
        LD (MessageBody),HL
        LD HL,TitleEnglish
        LD DE,TitleRussian
        CALL SelectLanguage
        LD (MessageTitle),HL
        LD HL,CloseEnglish
        LD DE,CloseRussian
        CALL SelectLanguage
        LD (MessageBottom),HL
ShowMessageBox:
        ; Общий показ уже подготовленного окна. Поля строк устанавливает
        ; вызывающий путь; здесь не выбираем язык повторно. IX сохраняется
        ; вокруг всех вызовов WC, независимо от типа сообщения.
        PUSH IX
        LD HL,#FFFF
        LD (MessageWindow+2),HL
        LD HL,0
        LD (MessageWindow+8),HL
        LD IX,MessageWindow
        LD A,1
        CALL WLD
        LD A,46
        CALL WLD
        LD A,47
        CALL WLD
        LD A,46
        CALL WLD
        LD A,2
        CALL WLD
        POP IX
        RET

SearchKey:
        LD A,41
        CALL WLD
        RET Z
        LD A,40
        CALL WLD
        RET NZ
        LD A,39
        CALL WLD
        RET NZ
        LD A,1
        EX AF,AF'
        LD A,42
        CALL WLD
        CP "f"
        JP Z,SearchDialog
        CP "g"
        JP Z,SearchNext
        RET

SearchDialog:
        PUSH IX
        LD HL,SearchEnglish
        LD DE,SearchRussian
        CALL SelectLanguage
        LD (SearchTitle),HL
        LD HL,#FFFF
        LD (SearchWindow+2),HL
        LD HL,0
        LD (SearchWindow+8),HL
        LD IX,SearchWindow
        LD A,1
        CALL WLD
        EXX
        LD HL,InputLength
        EXX
        LD HL,InputBuffer
        LD DE,#0101
        LD BC,InputLength*256
        LD A,#FD
        CALL InputString
        LD HL,#01FF
        LD A,#FE
        CALL InputString
.loop:
        EI
        HALT
        LD A,22
        CALL WLD
        JR NZ,.accept
        LD A,23
        CALL WLD
        JR NZ,.cancel
        XOR A
        CALL InputString
        LD A,2
        CALL InputString
        LD A,3
        CALL InputString
        JR .loop
.cancel:
        LD A,2
        CALL WLD
        POP IX
        JP DrawFooter
.accept:
        LD A,2
        CALL WLD
        POP IX
        CALL BuildSearch
        LD A,(SearchLength)
        OR A
        RET Z
        XOR A
        LD (SearchAgain),A
        CALL BeginCommand
        JP FindBytes
InputString:
        EX AF,AF'
        LD A,9
        JP WLD

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
