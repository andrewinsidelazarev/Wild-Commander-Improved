; Весь видимый интерфейс английский. ISTR используется только как проверенный
; редактор CP866-поля: его служебное окно остаётся в памяти текстового экрана,
; а пользователю показываем поле и курсор собственным дисплей-листом FT812.
SelectLanguage:
        RET
MessageBox:
        LD (MessageBody),HL
        PUSH IX
        CALL MapGrid
        LD HL,TitleEnglish
        LD (MessageTitle),HL
        LD HL,CloseEnglish
        LD (MessageBottom),HL
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
ShowHelp:
        LD A,1
        LD (Modal),A
        CALL PresentScreen
        LD A,46
        CALL WLD
        LD A,47
        CALL WLD
        LD A,46
        CALL WLD
        XOR A
        LD (Modal),A
        JP PresentScreen
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
        CALL MapGrid
        LD HL,SearchEnglish
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
        LD A,2
        LD (Modal),A
        CALL PresentScreen
.loop:
        EI
        HALT
        LD A,22
        CALL WLD
        JR NZ,.accept
        LD A,23
        CALL WLD
        JR NZ,.cancel
        CALL MapGrid
        LD IX,SearchWindow
        XOR A
        CALL InputString
        LD A,2
        CALL InputString
        LD A,3
        CALL InputString
        CALL PresentScreen
        JR .loop
.cancel:
        CALL .close
        POP IX
        JP DrawFooter
.accept:
        CALL .close
        POP IX
        CALL BuildSearch
        LD A,(SearchLength)
        OR A
        JP Z,DrawFooter
        XOR A
        LD (SearchAgain),A
        CALL BeginCommand
        JP FindBytes
.close:
        CALL MapGrid
        LD IX,SearchWindow
        LD A,2
        CALL WLD
        LD A,46
        CALL WLD
        XOR A
        LD (Modal),A
        RET
InputString:
        EX AF,AF'
        LD A,9
        JP WLD

TitleEnglish: DB "TXT/HEX - VDAC2",0
CloseEnglish: DB "Press any key",0
OpenError: DB "Cannot open or read the selected file.",0
VideoError: DB "VDAC2 / FT812 did not respond.",13,"Check the board and try again.",0
MenuInfo: DB "Select a file and press F3.",13,"Or choose TXT / HEX - VDAC2 with Shift+F3.",0
SearchEnglish: DB "Find text",0
