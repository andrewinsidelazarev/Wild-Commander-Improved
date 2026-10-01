; SOW и строки в странице кода. Рабочее окно повторяет PBWND WC:
; 42x7, #5F, строки 1/4 пустые, 2 — текст, 3 — счёт, 5 — полоса.
ShowWindow:
        LD HL,WindowTemplate
        JP OpenWindow
Options:
        LD HL,DriveTemplate
        CALL OpenWindow
        LD A,46                        ; отпустить Enter запуска файла
        CALL WLD
; Меню дисководов — одна строка «A B C D» (пользователь, 2026-10-01): выбранная
; буква выделена цветом курсора, влево/вправо двигают выбор; на краях он
; остаётся на месте (по кругу не нужно).
; Клавиши опрашиваются раз в кадр, как в главном цикле WC: проверки Esc/Enter/
; стрелок сами отличают первое нажатие от автоповтора. NUSP (API 47) перед ними
; ставить нельзя: он взводит задержку автоповтора (#76CB), и проверка той же
; клавиши полсекунды отвечает «не нажата» — меню не двигалось и не выбиралось.
.draw: CALL DriveLine
.loop: EI
        HALT
        LD A,23
        CALL WLD
        JP NZ,UserAbort
        LD A,22
        CALL WLD
        JR NZ,.choose
        LD A,19
        CALL WLD
        JR NZ,.left
        LD A,20
        CALL WLD
        JR Z,.loop
        LD A,(Drive)
        CP 3
        JR Z,.loop                      ; на D вправо некуда: по кругу не ходим
        INC A
        JR .move
.left: LD A,(Drive)
        OR A
        JR Z,.loop                      ; на A влево некуда
        DEC A
.move: LD (Drive),A
        JR .draw
.choose:
        XOR A
        RET
; Строка меню по центру окна и выделение выбранного дисковода: буквы стоят
; через 7 знакомест, поля слева и справа равны (9 и 9 из 40).
DriveLine:
        LD HL,DriveRow
        LD D,3
        CALL CenterText
        LD A,#5F                        ; печать цвета не меняет: снять прежнее
        EX AF,AF'                       ; выделение со всей строки
        LD A,4
        CALL WLD
        LD A,(Drive)
        LD B,A
        ADD A,'A'
        LD (DriveMark+1),A
        LD A,B
        ADD A,A
        ADD A,A
        ADD A,A
        SUB B                           ; дисковод * 7
        ADD A,9                         ; X первой буквы 1+9, выделение на знак левее
        LD E,A
        LD D,3
        LD HL,DriveMark
        LD BC,3
        LD IX,Window
        LD A,3
        CALL WLD
        LD A,#F0                        ; цвет курсора списков WC
        EX AF,AF'
        LD A,4
        JP WLD
DriveRow: DB "A      B      C      D",0
DriveMark: DB " A "
OpenWindow:
        LD DE,Window
        LD BC,22
        LDIR
        LD IX,Window
        LD A,1
        CALL WLD
        LD A,1
        LD (WindowOpen),A
        RET
CloseWindow:
        LD A,(WindowOpen)
        OR A
        RET Z
        LD IX,Window
        LD A,2
        CALL WLD
        XOR A
        LD (WindowOpen),A
        RET
WindowTemplate:
        DB #84,0,255,255,42,7,#5F,0
        DW 0
        DB 0,0
        DW Title,0,0,0,0
DriveTemplate:
        DB #84,0,255,255,42,7,#5F,0
        DW 0
        DB 0,0
        DW DriveTitle,0,0,0,0
Title: DB #0E,#09,"FDI2FDD",0            ; центр/инверсия, как WCVLS.TXT8
DriveTitle: DB #0E,#09,"REAL DRIVE",0
Empty: DB 0

; CP_CENTER: собрать всю строку, затем одна запись 40 знаков.
; Для нечётной длины разница полей неизбежна в одну клетку.
CenterText:
        PUSH DE
        PUSH HL
        LD HL,Line
        LD DE,Line+1
        LD BC,39
        LD (HL),32
        LDIR
        POP HL
        PUSH HL
        LD B,40
        LD C,0
.len:  LD A,(HL)
        OR A
        JR Z,.length
        INC HL
        INC C
        DJNZ .len
.length:
        LD A,40
        SUB C
        SRL A
        LD E,A
        LD D,0
        EX DE,HL
        LD DE,Line
        ADD HL,DE
        EX DE,HL
        POP HL
        LD B,0
        LD A,C
        OR A
        JR Z,.out
        LDIR
.out:  POP DE
        LD E,1
        LD HL,Line
        LD IX,Window
        LD BC,40
        LD A,3
        JP WLD
Message:
        LD D,2
        JP CenterText
Warning:
        LD A,(Drive)
        ADD A,'A'
        LD (WarningDrive),A
        LD HL,WarningText
        CALL Message
        LD A,#2F                        ; предупреждение — белым по красному, как
        EX AF,AF'                       ; окна ошибок WC (ERWND)
        LD A,4
        CALL WLD
        LD HL,ContinueText              ; строки 2 и 4, между ними пустая: окно
        LD D,4                          ; симметрично (пустые 1, 3 и 5)
        CALL CenterText
        CALL ReadKey
        AND #DF                        ; KBSCN(1): буквы нижнего регистра
        CP 'Y'
        JP NZ,UserAbort                 ; Enter/Esc/Space/неизвестные тоже отмена
        LD A,46
        CALL WLD
        LD HL,Empty                     ; убрать предупреждение и вернуть строке
        LD D,2                          ; цвет окна: дальше в ней имя файла
        CALL CenterText
        LD A,#5F
        EX AF,AF'
        LD A,4
        CALL WLD
        LD HL,Empty
        LD D,4
        CALL CenterText
        XOR A
        RET
; Дождаться отпускания, затем новой клавиши. Выход: A=#1B — Esc, #0D — Enter,
; символ сырого стола KBSCN или 0 — любая другая клавиша. Опрос раз в кадр,
; без NUSP: после него KBSCN и проверки клавиш полсекунды молчат (задержка
; автоповтора), и «Y» читалась бы как «не Y». ANYK — последним: он тоже
; взводит задержку.
ReadKey:
        LD A,46
        CALL WLD
.wait: EI
        HALT
        LD A,23
        CALL WLD
        LD A,#1B
        RET NZ
        LD A,22
        CALL WLD
        LD A,#0D
        RET NZ
        LD A,1
        EX AF,AF'
        LD A,42
        CALL WLD
        RET NZ
        LD A,45
        CALL WLD
        JR Z,.wait
        XOR A
        RET
UserAbort:
        LD A,ERR_BREAK
        SCF
        RET
WarningText: DB "All data on disk "
WarningDrive: DB "A will be destroyed!",0
ContinueText: DB "Continue? (Y/N)",0

Progress:
        LD HL,FileName+1
        CALL Message
        LD HL,(TracksDone)
        LD DE,Counter+1
        CALL Decimal4
        LD HL,(TracksTotal)
        LD DE,Counter+9
        CALL Decimal4
        LD HL,Counter
        LD D,3
        CALL CenterText
        LD HL,(TracksDone)
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL                       ; CP: сначала доля 0..64
        LD DE,(TracksTotal)
        LD A,D
        OR E
        RET Z
        LD B,0
.divide:
        OR A
        SBC HL,DE
        JR C,.divided
        INC B
        JR .divide
.divided:
        LD A,B
        LD HL,0
        LD DE,40
        OR A
        JR Z,.scale
        LD B,A
.mul:  ADD HL,DE
        DJNZ .mul
.scale:
        ADD HL,HL
        ADD HL,HL                       ; H=доля*40/64, CP_SCALE
        LD A,H
        LD HL,Bar
        LD B,40
        LD C,A
.bar:  LD A,C
        OR A
        LD A,#B1                        ; ▒, CP_DRAW_REST
        JR Z,.rest
        LD A,#DB                        ; █, CP_DRAW_FULL
        DEC C
.rest: LD (HL),A
        INC HL
        DJNZ .bar
        LD HL,Bar
        LD BC,40
        LD DE,#0501
        LD IX,Window
        LD A,3
        JP WLD
Counter: DB "<0000 of 0000>",0

; Выбор в открытом окне: R/I/A, Enter=Retry, Esc=Abort.
ErrorChoice:
        LD (ErrorCode),A
        PUSH IY
        CALL ForceIdle
        LD A,(ErrorCode)
        CP ERR_VERIFY
        LD HL,MsgWrite
        JR NZ,.text
        LD HL,MsgVerify
.text: CALL Message
        LD HL,Choices
        LD D,3
        CALL CenterText
.key:  CALL ReadKey
        CP #1B
        JR Z,.abort
        CP #0D
        JR Z,.retry
        AND #DF
        CP 'A'
        JR Z,.abort
        CP 'I'
        JR Z,.ignore
        CP 'R'
        JR NZ,.key
.retry:
        LD A,1
        LD (NeedSpin),A                 ; за время диалога мотор встал: раскрутить заново
        XOR A
        LD (#6004),A                    ; Esc из диалога не должен оборвать повтор
        POP IY
        CALL ProgressPreserved
        CALL MapTrack
        XOR A
        RET
.ignore:
        LD A,1
        LD (NeedSpin),A
        XOR A
        LD (#6004),A
        POP IY
        CALL MarkIgnored
        CALL ProgressPreserved
        CALL MapTrack
        LD A,1
        OR A
        RET
.abort:
        POP IY
        JP UserAbort
ProgressPreserved:
        PUSH IY
        CALL Progress
        POP IY
        RET
Choices: DB "Retry / Ignore / Abort",0
; Итог в том же окне: строка 2 — «Done» или причина отказа, строка 4 —
; «Press any key to exit»; счётчик и полоса убираются (пользователь, 10-01).
Summary:
        LD A,(Result)
        OR A
        JR NZ,.error
        LD HL,(IgnoredDone)
        LD DE,StatsIgnored
        CALL Decimal4
        LD HL,(IgnoredDone)
        LD A,H
        OR L
        LD HL,MsgDone
        JR Z,.done
        LD HL,DoneIgnored
.done: CALL Message
        LD HL,(ApproxDone)
        LD DE,StatsSectors
        CALL Decimal4
        LD HL,(ApproxBytes)
        LD DE,(ApproxBytes+2)
        CALL DecimalBytes
        LD HL,(ApproxDone)
        LD A,H
        OR L
        LD HL,Stats                     ; строка 3: замены в секторах с плохим CRC
        JR NZ,.tail
        LD HL,Empty
.tail: LD D,3
        CALL CenterText
        LD HL,MsgAnyKey
        LD A,(Reselect)
        OR A
        JR Z,.key
        LD HL,MsgAnyDrive
.key:   LD D,4
        CALL CenterText
        LD HL,Empty                     ; полосу прогресса убрать
        LD D,5
        JP CenterText
.error:
        ADD A,A
        LD E,A
        LD D,0
        LD HL,Messages
        ADD HL,DE
        LD E,(HL)
        INC HL
        LD D,(HL)
        EX DE,HL
        LD A,(Result)
        CP ERR_IMAGE
        JR NZ,.message
        LD DE,(ImageReason)
        LD A,D
        OR E
        JR Z,.message
        EX DE,HL
.message:
        CALL Message
        LD HL,Empty
        JR .tail
DoneIgnored: DB "Done; Ignored "
StatsIgnored: DB "0000",0
Stats: DB "CRC changed: "
StatsSectors: DB "0000 / "
StatsBytes: DB "000000 bytes",0
; DE:HL — число заменённых байтов (до 172*5632, шесть цифр).
DecimalBytes:
        LD (Number32),HL
        LD (Number32+2),DE
        LD IX,StatsBytes
        LD IY,Divisors32
        LD B,6
.digit: LD C,'0'
.sub:   LD HL,(Number32)
        LD E,(IY+0)
        LD D,(IY+1)
        OR A
        SBC HL,DE
        PUSH HL
        LD HL,(Number32+2)
        LD E,(IY+2)
        LD D,(IY+3)
        SBC HL,DE
        JR C,.out
        LD (Number32+2),HL
        POP HL
        LD (Number32),HL
        INC C
        JR .sub
.out:   POP HL
        LD (IX+0),C
        INC IX
        LD DE,4
        ADD IY,DE
        DJNZ .digit
        RET
Divisors32: DD 100000,10000,1000,100,10,1
Decimal4:
        LD BC,1000
        CALL .digit
        LD BC,100
        CALL .digit
        LD BC,10
        CALL .digit
        LD BC,1
.digit: LD A,'0'-1
.sub:  INC A
        OR A
        SBC HL,BC
        JR NC,.sub
        ADD HL,BC
        LD (DE),A
        INC DE
        RET
Messages:
        DW MsgDone,MsgImage,MsgFile,MsgDrive,MsgDisk,MsgWP
        DW MsgSeek,MsgWrite,MsgVerify,Empty,MsgTimeout,MsgNoFdc
MsgProbe: DB "Checking drive...",0
MsgChecking: DB "Checking FDI table...",0
MsgDone: DB "Done",0
MsgImage: DB "Invalid or unsupported FDI",0
MsgOffset: DB "FDI offset beyond EOF",0
MsgCapacity: DB "Track exceeds safe DD capacity",0
MsgSizeCode: DB "Unsupported sector size",0
MsgFile: DB "File read failed",0
MsgDrive: DB "Drive not found",0
MsgDisk: DB "No disk in drive",0
MsgWP: DB "Disk is write protected",0
MsgSeek: DB "Seek failed",0
MsgWrite: DB "Write failed",0
MsgVerify: DB "Verification failed",0
MsgTimeout: DB "Controller timeout",0
MsgNoFdc: DB "Floppy disk controller not found",0
MsgAnyKey: DB "Press any key to exit",0
MsgAnyDrive: DB "Press any key to select drive",0
