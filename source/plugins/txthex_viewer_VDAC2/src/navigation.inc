; История и навигация из TXTVIEW v0.26.
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
        LD (PageGridValid),A
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
        LD A,(PageGridValid)
        OR A
        JP NZ,ScrollDown
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
        LD A,(PageGridValid)
        OR A
        JP NZ,ScrollUp
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

; Однострочная прокрутка читает только новую границу. До успешного чтения
; Top, RowOffsets, PageAfter и готовые полосы не меняются. Ошибка и Esc
; используют обычный откат команды; частичная LineGlyphs не показывается.
ScrollDown:
        LD HL,RowOffsets+4
        LD DE,FileSize
        CALL Compare32
        JP NC,ScrollIdle
        LD HL,RowOffsets+4
        LD DE,ScrollTop
        CALL Copy32
        LD HL,PageAfter
        LD DE,Position
        CALL Copy32
        CALL RenderRow
        CALL ScrollCheck
        JP NZ,FinishCommand
        LD HL,RowOffsets+4
        LD DE,RowOffsets
        LD BC,(SCREEN_ROWS-1)*4
        LDIR
        LD HL,PageAfter
        LD DE,RowOffsets+(SCREEN_ROWS-1)*4
        CALL Copy32
        LD HL,Position
        LD DE,PageAfter
        CALL Copy32
        LD A,(RowRing)
        LD B,A
        INC A
        CP CACHE_ROWS
        JR C,.ring
        XOR A
.ring:
        LD (RowRing),A
        LD A,B
        OR A
        JR NZ,.spare
        LD A,CACHE_ROWS
.spare:
        DEC A                         ; невидимая полоса станет нижней
        JR ScrollCommit
ScrollUp:
        CALL ScrollCheck
        JP NZ,FinishCommand
        LD HL,Position
        LD DE,Top
        CALL Compare32
        JP Z,ScrollIdle
        LD HL,Position
        LD DE,ScrollTop
        CALL Copy32
        CALL RenderRow
        CALL ScrollCheck
        JP NZ,FinishCommand
        LD HL,RowOffsets+(SCREEN_ROWS-1)*4
        LD DE,PageAfter                ; старая последняя строка ушла за экран
        CALL Copy32
        LD HL,RowOffsets+(SCREEN_ROWS-1)*4-1
        LD DE,RowOffsets+SCREEN_ROWS*4-1
        LD BC,(SCREEN_ROWS-1)*4
        LDDR
        LD HL,ScrollTop
        LD DE,RowOffsets
        CALL Copy32
        LD A,(RowRing)
        OR A
        JR NZ,.ring
        LD A,CACHE_ROWS
.ring:
        DEC A
        LD (RowRing),A
ScrollCommit:
        ; Dirty=0: обновить только эту физическую полосу (код slot+2).
        ; При отложенной передаче нескольких изменений нужен полный обход.
        PUSH AF
        ADD A,2
        LD B,A
        LD A,(GridDirty)
        OR A
        LD A,B
        JR Z,.dirty
        LD A,1
.dirty:
        LD (GridDirty),A
        POP AF
        CALL SlotAddress
        EX DE,HL
        CALL MapGrid
        LD HL,LineGlyphs
        LD BC,SCREEN_COLUMNS*2
        LDIR
        LD HL,ScrollTop
        LD DE,Top
        CALL Copy32
ScrollIdle:
        XOR A
        LD (AllowCancel),A
        JP DrawFooter
ScrollCheck:
        LD A,(IoError)
        LD B,A
        LD A,(Cancelled)
        OR B
        RET

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
