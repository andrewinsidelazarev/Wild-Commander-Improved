; Экранные строки ограничены шириной окна, а не длиной входной строки.
; Смещения всегда указывают на исходные байты. CR, LF и CRLF поддерживаются
; одновременно; Tab разворачивается до восьмиколоночной позиции. Байты NUL
; и прочие управляющие символы показываются точкой и не завершают файл.

ClearLine:
        LD HL,LineBuffer
        LD B,90
        LD A," "
.loop:
        LD (HL),A
        INC HL
        DJNZ .loop
        XOR A
        LD (Column),A
        RET

TextRow:
        CALL ClearLine
.loop:
        CALL ReadChar
        RET C
        CP 13
        JR Z,ConsumeLF
        CP 10
        RET Z
        CP 9
        JR Z,.tab
        CP 32
        JR C,.control
        CP #7F
        JR NZ,.emit
.control:
        LD A,"."
.emit:
        CALL EmitCharacter
        JR NZ,.loop
        JP ConsumeEol
.tab:
        LD A," "
        CALL EmitCharacter
        JP Z,ConsumeEol
        LD A,(Column)
        AND 7
        JR NZ,.tab
        JR .loop

; A=экранный байт. Z означает достижение правого края. Не вызывается при
; Column>=Width: размер массива LineBuffer и граница окна совпадают.
EmitCharacter:
        LD HL,LineBuffer
        LD C,A
        LD A,(Column)
        LD E,A
        LD D,0
        ADD HL,DE
        LD (HL),C
        INC A
        LD (Column),A
        LD HL,Width
        CP (HL)
        RET

; Полная строка с ровно Width символами и CRLF не должна давать лишнюю
; пустую экранную строку. Посмотрим вперёд, но обычный символ не потребим.
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

; HEX-строка: 8 разрядов смещения, 16 HEX-байтов и 16 исходных символов.
; Каждое чтение отдельно ограничено FileSize: неполный последний ряд
; никогда не раскрывает секторный хвост или старые данные кэша.
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

; RenderRow сохраняет обе границы строки в кольцо. История — ускоритель,
; а не ограничитель: после 256 строк старые записи можно восстановить из файла.
RenderRow:
        LD HL,Position
        LD DE,RowBegin
        CALL Copy32
        LD A,(HexMode)
        OR A
        JP NZ,HexRow
        CALL TextRow
        JP RememberRow

DrawPage:
        LD IX,ViewWindow
        LD HL,Top
        LD DE,Position
        CALL Copy32
        XOR A
        LD (DrawY),A
.loop:
        ; Сохраняем начала строк текущего экрана для Down/PageDown.
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
        LD A,(DrawY)
        INC A
        LD D,A
        LD E,0
        CALL PrintLine
        LD HL,DrawY
        INC (HL)
        LD A,(Rows)
        CP (HL)
        JR NZ,.loop
        LD HL,Position
        LD DE,PageAfter
        CALL Copy32
        CALL DrawHeader
        JP DrawFooter

; Вызов PRSRW возвращает HL за диапазоном и B=его длина; PRIAT использует
; именно эти выходы. Нельзя подставлять фиксированные 80/90 в иной видеомоде.
PrintLine:
        LD IX,ViewWindow
        LD HL,LineBuffer
        LD A,(Width)
        LD C,A
        LD B,0
        LD A,3
        CALL WLD
        LD A,#17
        EX AF,AF'
        LD A,4
        JP WLD

RememberRow:
        LD A,(IoError)
        LD B,A
        LD A,(Cancelled)
        OR B
        RET NZ
        LD HL,RowBegin
        LD DE,Position
        CALL Compare32
        RET NC
        LD A,(HistIndex)
        CALL HistoryAddress
        EX DE,HL
        LD HL,RowBegin
        CALL Copy32
        LD HL,Position
        CALL Copy32
        LD HL,HistIndex
        INC (HL)
        LD HL,(HistCount)
        LD A,H
        OR A
        RET NZ
        INC HL
        LD (HistCount),HL
        RET

HistoryAddress:
        LD L,A
        LD H,0
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        LD DE,HISTORY
        ADD HL,DE
        RET

; Position=исходная граница, результат Position=предыдущая экранная строка.
; При промахе кольца сначала находим начало физической строки, затем
; воспроизводим её переносы. Для очень длинной строки это линейный проход;
; он отменяется Esc, а найденные переходы попадают в кольцо для следующего Up.
PreviousRow:
        LD HL,Position
        LD DE,Target
        CALL Copy32
        LD HL,Target
        LD DE,TextStart
        CALL Compare32
        RET Z
        JP C,.first
        LD HL,(HistCount)
        LD A,H
        OR L
        JR Z,.slow
        LD B,L
        LD A,(HistIndex)
        LD C,A
.lookup:
        DEC C
        PUSH BC
        LD A,C
        CALL HistoryAddress
        LD DE,4
        ADD HL,DE
        PUSH HL
        LD DE,Target
        CALL Compare32
        POP HL
        POP BC
        JR Z,.found
        DJNZ .lookup
        JR .slow
.found:
        LD DE,-4
        ADD HL,DE
        LD DE,Position
        JP Copy32
.slow:
        CALL DrawFooter                 ; длинное восстановление видно пользователю
        ; Сначала пропускаем разделитель непосредственно перед Target.
        LD HL,Position
        CALL Decrement32
        CALL PeekByte
        RET C
        CP 10
        JR NZ,.not_lf
        CALL AtTextStart
        JR Z,.rescan
        LD HL,Position
        CALL Decrement32
        CALL PeekByte
        RET C
.not_lf:
        CP 13
        JR NZ,.back
        CALL AtTextStart
        JR Z,.rescan
        LD HL,Position
        CALL Decrement32
.back:
        CALL PeekByte
        RET C
        CP 10
        JR Z,.after_separator
        CP 13
        JR Z,.after_separator
        CALL AtTextStart
        JR Z,.rescan
        LD HL,Position
        CALL Decrement32
        JR .back
.after_separator:
        LD HL,Position
        CALL Increment32
.rescan:
        LD HL,Position
        LD DE,Candidate
        CALL Copy32
        CALL RenderRow
        LD A,(IoError)
        LD B,A
        LD A,(Cancelled)
        OR B
        RET NZ
        LD HL,Position
        LD DE,Target
        CALL Compare32
        JR C,.rescan
        LD HL,Candidate
        LD DE,Position
        JP Copy32
.first:
        LD HL,TextStart
        LD DE,Position
        JP Copy32
AtTextStart:
        LD HL,Position
        LD DE,TextStart
        JP Compare32

; Команда навигации меняет Top только после успешного чтения/сканирования.
; При отмене Top остаётся прежним; при ошибке нижняя строка сообщает о сбое.
BeginCommand:
        XOR A
        LD (IoError),A
        LD (Cancelled),A
        LD (WC_ABORT),A                 ; прежний Esc не отменяет новую команду
        LD A,1
        LD (AllowCancel),A
        LD HL,Top
        LD DE,Position
        JP Copy32
FinishCommand:
        XOR A
        LD (AllowCancel),A
        LD A,(IoError)
        LD B,A
        LD A,(Cancelled)
        OR B
        JR NZ,.failed
        LD HL,Position
        LD DE,Top
        CALL Copy32
        JP DrawPage
.failed:
        ; Восстанавливаем исходный экран. Ошибка остаётся в строке состояния,
        ; отмена не превращается в ошибку чтения и не закрывает просмотрщик.
        LD A,(IoError)
        OR A
        JP NZ,DrawFooter
        ; Нажатие отмены не должно затем закрыть просмотрщик в MainLoop.
        ; Дожидаемся отпускания и очищаем защёлку, которую обновлял INT.
        LD A,46
        CALL WLD
        XOR A
        LD (Cancelled),A
        LD (WC_ABORT),A
        JP DrawFooter

GoHome:
        XOR A
        LD (IoError),A
        LD (Cancelled),A
        LD (HistIndex),A
        LD HL,0
        LD (HistCount),HL
        LD HL,Top
        CALL Zero32
        LD A,(HexMode)
        OR A
        RET NZ
        LD HL,TextStart
        LD DE,Top
        JP Copy32

ToggleMode:
        LD A,(HexMode)
        XOR 1
        LD (HexMode),A
        CALL GoHome
        JP DrawPage

GoDown:
        CALL BeginCommand
        LD A,(HexMode)
        OR A
        JR NZ,.hex
        LD HL,RowOffsets+4
        JR .candidate
.hex:
        LD HL,Position
        LD BC,16
        CALL Add32BC
        JR C,.done
        LD HL,Position
.candidate:
        PUSH HL
        LD DE,FileSize
        CALL Compare32
        POP HL
        JR NC,.done
        LD DE,Position
        CALL Copy32
        JP FinishCommand
.done:
        LD HL,Top
        LD DE,Position
        CALL Copy32
        JP FinishCommand

GoUp:
        CALL BeginCommand
        CALL StepUp
        JP FinishCommand
StepUp:
        LD A,(HexMode)
        OR A
        JP Z,PreviousRow
        LD HL,(Position)
        LD DE,16
        OR A
        SBC HL,DE
        LD (Position),HL
        LD HL,(Position+2)
        LD DE,0
        SBC HL,DE
        LD (Position+2),HL
        RET NC
        LD HL,Position
        JP Zero32

PageUp:
        CALL BeginCommand
        LD A,(Rows)
        LD (RowsLeft),A
.loop:
        CALL StepUp
        LD A,(IoError)
        LD B,A
        LD A,(Cancelled)
        OR B
        JR NZ,.done
        LD HL,RowsLeft
        DEC (HL)
        JR NZ,.loop
.done:
        JP FinishCommand

PageDown:
        CALL BeginCommand
        LD HL,PageAfter
        LD DE,FileSize
        CALL Compare32
        JP NC,FinishCommand
        LD HL,PageAfter
        LD DE,Position
        CALL Copy32
        JP FinishCommand

GoEnd:
        CALL BeginCommand
        CALL DrawFooter
        LD HL,FileSize
        LD DE,Position
        CALL Copy32
        LD HL,(FileSize)
        LD DE,(FileSize+2)
        LD A,H
        OR L
        OR D
        OR E
        JP Z,FinishCommand
        LD A,(HexMode)
        OR A
        JR Z,.text
        LD HL,Position
        CALL Decrement32
        LD A,(Position)
        AND #F0
        LD (Position),A
        JP FinishCommand
.text:
        LD HL,Position
        LD DE,TextStart
        CALL Compare32
        JP Z,FinishCommand
        LD A,(Rows)
        LD (RowsLeft),A
.loop:
        CALL PreviousRow
        LD A,(IoError)
        LD B,A
        LD A,(Cancelled)
        OR B
        JR NZ,.done
        LD HL,RowsLeft
        DEC (HL)
        JR NZ,.loop
.done:
        JP FinishCommand
