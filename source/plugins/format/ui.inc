; ui.inc — окна плагина: список устройств, параметры, ход записи, итог.
; У каждого экрана своё окно (одно на экране, размер у всех один), подсказка
; клавиш — по центру нижней рамки, как в WC Setup; содержимое — строки 1..9,
; симметрично относительно пятой. Нештатное (ошибка, предупреждение перед
; записью) — отдельным модальным окном в стиле окна ошибки WC (ERWND):
; красное поверх окна экрана, после ответа закрывается.

WIN_W           EQU 52
WIN_H           EQU 11
TEXT_W          EQU WIN_W-2
COL_WINDOW      EQU #5F
COL_CURSOR      EQU #F0                 ; цвет курсора списков WC
MODAL_W         EQU 46
MODAL_TEXT      EQU MODAL_W-2
COL_MODAL       EQU %00101111           ; как ERWND: фон красный, текст белый

; Окно экрана с подсказкой HL на нижней рамке (0 — без подсказки); прежнее
; окно закрывается. OpenScreenH — высотой A.
OpenScreen:
        LD A,WIN_H
OpenScreenH:
        PUSH AF
        PUSH HL
        CALL CloseMain
        LD HL,WindowTemplate
        LD DE,Window
        LD BC,22
        LDIR
        POP HL
        LD (Window+14),HL
        POP AF
        LD (Window+5),A
        LD IX,Window
        LD A,1
        CALL WLD
        LD A,1
        LD (WindowOpen),A
        RET
CloseMain:
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
        DB #84,0,255,255,WIN_W,WIN_H,COL_WINDOW,0
        DW 0
        DB 0,0
        DW Title,0,0,0,0
Title:  DB #0E,#09,"FAT32 FORMAT",0

; Модальное окно высотой A с заголовком HL и подсказкой DE на нижней рамке.
OpenModal:
        PUSH DE
        PUSH HL
        PUSH AF
        LD HL,ModalTemplate
        LD DE,Modal
        LD BC,22
        LDIR
        POP AF
        LD (Modal+5),A
        POP HL
        LD (Modal+12),HL
        POP DE
        LD (Modal+14),DE
        LD IX,Modal
        LD A,1
        JP WLD
CloseModal:
        LD IX,Modal
        LD A,2
        JP WLD
ModalTemplate:
        DB 4+16+128,0,255,255,MODAL_W,4,COL_MODAL,0
        DW 0
        DB 0,0
        DW 0,0,0,0,0
; Строка D модального окна: текст HL (до нуля) по центру.
ModalLine:
        LD B,0
        PUSH HL
.len:   LD A,(HL)
        OR A
        JR Z,.counted
        INC HL
        INC B
        JR .len
.counted:
        POP HL
        LD A,MODAL_TEXT
        SUB B
        SRL A
        INC A
        LD E,A
        LD C,B
        LD B,0
        LD A,C
        OR A
        RET Z
        LD IX,Modal
        LD A,3
        JP WLD

; Строки 1..9 пусты, цвет окна.
ClearRows:
        LD D,1
.row:   PUSH DE
        LD HL,Empty
        CALL Center
        LD A,COL_WINDOW
        CALL Paint
        POP DE
        INC D
        LD A,D
        CP WIN_H-1
        JR NZ,.row
        RET
Empty:  DB 0

; Строка D: текст HL (до нуля) по центру. Для нечётной разницы поле слева
; меньше на клетку.
Center:
        PUSH DE
        CALL FillLine
        LD B,0
.len:   LD A,(HL)
        OR A
        JR Z,.counted
        INC HL
        INC B
        LD A,B
        CP TEXT_W
        JR C,.len
.counted:
        LD A,B
        OR A
        JR Z,.print
        LD C,B
        LD B,0
        OR A
        SBC HL,BC                       ; HL — начало текста
        LD A,TEXT_W
        SUB C
        SRL A
        LD E,A
        LD D,0
        PUSH HL
        LD HL,Line
        ADD HL,DE
        EX DE,HL
        POP HL
        LDIR
.print: POP DE
; Вывести Line в строке D.
PrintLine:
        LD E,1
        LD HL,Line
        LD IX,Window
        LD BC,TEXT_W
        LD A,3
        JP WLD
; Цвет A — только что выведенной строке.
Paint:
        EX AF,AF'
        LD A,4
        JP WLD
; Line — пробелы; регистры, кроме A, целы.
FillLine:
        PUSH HL
        PUSH DE
        PUSH BC
        LD HL,Line
        LD DE,Line+1
        LD BC,TEXT_W-1
        LD (HL),32
        LDIR
        POP BC
        POP DE
        POP HL
        RET
; Строка D: текст HL с колонки 4 (список).
LeftText:
        PUSH DE
        CALL FillLine
        LD DE,Line+3
.copy:  LD A,(HL)
        OR A
        JR Z,.done
        LD (DE),A
        INC HL
        INC DE
        JR .copy
.done:  POP DE
        JR PrintLine

; --- список устройств -----------------------------------------------------

; Выход: CF=1 — Esc; иначе Dev, DevIndex. Загрузочное устройство выбрать
; нельзя (сообщение и снова список).
DeviceMenu:
        LD HL,FootMenu
        CALL OpenScreen
        LD A,46
        CALL WLD
.draw:  CALL MenuRows
.loop:  EI
        HALT
        LD A,23
        CALL WLD
        JR NZ,.esc
        LD A,22
        CALL WLD
        JR NZ,.enter
        LD A,17
        CALL WLD
        JR NZ,.up
        LD A,18
        CALL WLD
        JR Z,.loop
        LD A,(DevIndex)
        CP 6
        JR Z,.loop
        INC A
        JR .move
.up:    LD A,(DevIndex)
        OR A
        JR Z,.loop
        DEC A
.move:  LD (DevIndex),A
        JR .draw
.esc:   SCF
        RET
.enter: LD A,(DevIndex)
        LD HL,DevCodes
        LD E,A
        LD D,0
        ADD HL,DE
        LD A,(HL)
        LD (Dev),A
        LD HL,BootDev
        CP (HL)
        JR NZ,.ok
        LD HL,MsgBootDrive
        CALL ShowError                  ; окно списка под ним цело
        JR .loop
.ok:    LD A,46
        CALL WLD
        OR A
        RET
DevCodes:       DB DEV_SD1,DEV_SD2,DEV_NEMO,DEV_NEMO2,DEV_SMUC,DEV_SMUC2,DEV_NGS

; Строки 2..8: устройства, выбранное — цветом курсора.
MenuRows:
        LD B,0
.row:   PUSH BC
        LD A,B
        CALL DevNameLine                ; Line2 — имя и пометка загрузочного
        POP BC
        PUSH BC
        LD A,B
        ADD A,2
        LD D,A
        LD HL,Line2
        CALL LeftText                   ; HL и B — для PRIAT, не трогать
        POP DE                          ; D — номер строки списка
        PUSH DE
        LD A,(DevIndex)
        CP D
        LD A,COL_CURSOR
        JR Z,.paint
        LD A,COL_WINDOW
.paint: CALL Paint
        POP BC
        INC B
        LD A,B
        CP 7
        JR NZ,.row
        RET

; Line2 — имя устройства строки A списка и « (WC boot drive)» у загрузочного.
DevNameLine:
        LD DE,Line2
; То же с адреса DE; DE — на нуле за текстом.
DevNameAt:
        LD (DevIndexTmp),A
        PUSH DE
        LD HL,DevNames
        OR A
        JR Z,.found
        LD B,A
.skip:  LD A,(HL)
        INC HL
        OR A
        JR NZ,.skip
        DJNZ .skip
.found: POP DE
        CALL CopyZ
        LD HL,DevCodes
        LD A,(DevIndexTmp)
        PUSH DE
        LD E,A
        LD D,0
        ADD HL,DE
        POP DE
        LD A,(BootDev)
        CP (HL)
        JR NZ,.end
        LD HL,TxtBoot
        CALL CopyZ
.end:   XOR A
        LD (DE),A
        RET
DevNames:
        DB "SD card, Z-Controller slot 1",0
        DB "SD card, Z-Controller slot 2",0
        DB "IDE Nemo, master",0
        DB "IDE Nemo, slave",0
        DB "IDE SMUC, master",0
        DB "IDE SMUC, slave",0
        DB "SD card, NeoGS",0
TxtBoot:        DB " (WC boot drive)",0

; (HL) -> (DE) до нуля; DE — на нуле не ставится (за последним знаком).
CopyZ:  LD A,(HL)
        OR A
        RET Z
        LD (DE),A
        INC HL
        INC DE
        JR CopyZ

; --- сообщения ------------------------------------------------------------

; Окно без подсказки, текст HL (ход работы) в строке 5.
ShowBusy:
        PUSH HL
        LD HL,0
        CALL OpenScreen
        POP HL
        LD D,5
        CALL Center
        LD A,COL_WINDOW
        JP Paint

; Ошибка — модальное окно поверх окна экрана: текст HL — одна или две
; строки (через 0, вторая может быть пустой). Над текстом пустая строка под
; заголовком, под ним нижняя рамка с «Press any key» (как «Insert boot
; drive» ядра). Любая клавиша закрывает окно.
ShowError:
        PUSH HL
.next:  LD A,(HL)                       ; вторая строка — за нулём первой
        INC HL
        OR A
        JR NZ,.next
        LD A,(HL)
        OR A
        LD A,2+2
        JR Z,.height
        INC A
.height:
        PUSH HL
        LD HL,TitleError
        LD DE,FootKey
        CALL OpenModal
        POP HL
        LD D,3
        CALL ModalLine
        POP HL
        LD D,2
        CALL ModalLine
        CALL WaitKey
        JP CloseModal

; Дождаться отпускания, затем любой клавиши.
WaitKey:
        LD A,46
        CALL WLD
.wait:  EI
        HALT
        LD A,45
        CALL WLD
        JR Z,.wait
        LD A,46
        JP WLD

; --- параметры ------------------------------------------------------------

; Размер кластера и метка. Выход: CF=1 — Esc (к списку); CF=0 — Enter при
; верной разметке.
; Окно на строку ниже прочих: строки 1-3 — устройство, 5-6 — поля, 8 — итог;
; без пустых строк у рамок, отступы сверху и снизу равны.
Options:
        LD HL,FootOptions
        LD A,WIN_H-1
        CALL OpenScreenH
        LD A,(DevIndex)
        CALL DevNameLine
        LD HL,Line2
        LD D,1
        CALL Center
        LD A,COL_WINDOW
        CALL Paint
        CALL SizeLine
        LD D,2
        CALL Center
        LD A,COL_WINDOW
        CALL Paint
        CALL InfoLine
        LD D,3
        CALL Center
        LD A,COL_WINDOW
        CALL Paint
        LD A,46
        CALL WLD
.redraw:
        CALL Recalc
        CALL OptionRows
.loop:  EI
        HALT
        LD A,23
        CALL WLD
        JP NZ,.esc
        LD A,22
        CALL WLD
        JR NZ,.enter
        LD A,17
        CALL WLD
        JR NZ,.field0
        LD A,18
        CALL WLD
        JR NZ,.field1
        LD A,(Field)
        OR A
        JR NZ,.label
        LD A,19
        CALL WLD
        JR NZ,.smaller
        LD A,20
        CALL WLD
        JR Z,.loop
        LD A,(SpcIndex)
        CP 7
        JR Z,.loop
        INC A
        JR .spc
.smaller:
        LD A,(SpcIndex)
        OR A
        JR Z,.loop
        DEC A
.spc:   LD (SpcIndex),A
        JR .redraw
.field0:
        XOR A
        JR .field
.field1:
        LD A,1
.field: LD (Field),A
        JR .redraw
.label: LD A,24                         ; Backspace
        CALL WLD
        JR NZ,.back
        XOR A
        EX AF,AF'
        LD A,42                         ; KBSCN с раскладкой
        CALL WLD
        JR Z,.loop
        CALL LabelChar
        JR C,.loop
        LD C,A
        LD A,(LabelLen)
        CP 11
        JR Z,.loop
        LD HL,Label
        LD E,A
        LD D,0
        ADD HL,DE
        LD (HL),C
        INC A
        LD (LabelLen),A
        JP .redraw
.back:  LD A,(LabelLen)
        OR A
        JP Z,.loop
        DEC A
        LD (LabelLen),A
        JP .redraw
.esc:   SCF
        RET
.enter: LD A,(LayoutResult)
        OR A
        JP NZ,.loop                     ; разметки нет — Enter не действует
        RET

; Знак метки: A-Z (a-z — заглавными), 0-9, пробел, - и _. CF=1 — не годится.
LabelChar:
        CP 'a'
        JR C,.upper
        CP 'z'+1
        JR NC,.bad
        SUB 32
        RET
.upper: CP '_'                          ; между Z и a
        RET Z
        CP 'A'
        JR C,.digit
        CP 'Z'+1
        CCF
        RET
.digit: CP '0'
        JR C,.sign
        CP '9'+1
        CCF
        RET
.sign:  CP ' '
        RET Z
        CP '-'
        RET Z
.bad:   SCF
        RET

; Разметка для выбранного кластера: SpcReq и Layout; итог — LayoutResult.
Recalc:
        LD A,(SpcIndex)
        LD HL,SpcValues
        LD E,A
        LD D,0
        ADD HL,DE
        LD A,(HL)
        LD (SpcReq),A
        CALL Layout
        JR C,.bad
        XOR A
.bad:   LD (LayoutResult),A
        RET
SpcValues:      DB 0,1,2,4,8,16,32,64

; Строки 5, 6 (поля) и 8 (итог разметки). Подписи — колонкой с FIELD_L,
; значения — с VALUE_L (блок 30 знаков по центру строки); у выбранного поля
; цветом курсора — только значение.
FIELD_L         EQU (TEXT_W-30)/2
VALUE_L         EQU FIELD_L+15
OptionRows:
        LD DE,Line2                     ; «< Auto: 32 KB >»
        LD HL,TxtOpenArrow
        CALL CopyZ
        LD A,(SpcIndex)
        OR A
        JR NZ,.manual
        LD HL,TxtAuto
        CALL CopyZ
        LD A,(LayoutResult)
        OR A
        JR NZ,.close
        LD HL,TxtColon
        CALL CopyZ
.manual:
        CALL ClusterText
.close: LD HL,TxtCloseArrow
        CALL CopyZ
        XOR A
        LD (DE),A
        LD HL,TxtCluster
        LD D,5
        LD A,(Field)
        SUB 1                           ; CF=1 — выбрано это поле
        CALL FieldRow
        LD DE,Line2                     ; «[NO NAME____]»
        LD A,'['
        LD (DE),A
        INC DE
        LD HL,Label
        LD A,(LabelLen)
        LD B,A
        LD C,11
        OR A
        JR Z,.pad
.lab:   LD A,(HL)
        LD (DE),A
        INC HL
        INC DE
        DEC C
        DJNZ .lab
.pad:   LD A,C
        OR A
        JR Z,.shut
        LD A,'_'
.fill:  LD (DE),A
        INC DE
        DEC C
        JR NZ,.fill
.shut:  LD A,']'
        LD (DE),A
        INC DE
        XOR A
        LD (DE),A
        LD HL,TxtLabel
        LD D,6
        LD A,(Field)
        NEG                             ; CF=1 — выбрано это поле
        CALL FieldRow
        LD A,(LayoutResult)             ; строка 8 — итог
        OR A
        JR NZ,.error
        LD DE,Line2
        LD HL,TxtResult
        CALL CopyZ
        LD HL,Clusters
        CALL Decimal
        LD HL,TxtClusters
        CALL CopyZ
        XOR A
        LD (DE),A
        LD HL,Line2
        LD D,8
        CALL Center
        LD A,COL_WINDOW
        JP Paint
.error: DEC A
        ADD A,A
        LD L,A
        LD H,0
        LD DE,LayoutTexts
        ADD HL,DE
        LD A,(HL)
        INC HL
        LD H,(HL)
        LD L,A
        LD D,8
        CALL Center
        LD A,COL_WINDOW
        JP Paint
LayoutTexts:    DW MsgSmall,MsgFew,MsgMany,MsgReserved

; Строка D: подпись HL и значение Line2; при CF=1 значение — цветом курсора.
FieldRow:
        PUSH AF
        PUSH DE
        CALL FillLine
        LD DE,Line+FIELD_L
        CALL CopyZ
        LD HL,Line2
        LD DE,Line+VALUE_L
        LD B,0
.copy:  LD A,(HL)
        OR A
        JR Z,.print
        LD (DE),A
        INC HL
        INC DE
        INC B
        JR .copy
.print: POP DE
        PUSH BC
        PUSH DE
        CALL PrintLine
        LD A,COL_WINDOW
        CALL Paint
        POP DE
        POP BC
        POP AF
        RET NC
        LD C,B
        LD B,0
        LD E,1+VALUE_L
        LD HL,Line+VALUE_L
        LD IX,Window
        LD A,3
        CALL WLD
        LD A,COL_CURSOR
        JP Paint

; Размер кластера Spc в DE: «512 B» или «N KB».
ClusterText:
        LD A,(Spc)
        CP 1
        JR NZ,.kb
        LD HL,Txt512
        JP CopyZ
.kb:    SRL A                           ; КиБ = секторов / 2
        LD L,A
        LD H,0
        LD (Number),HL
        LD HL,0
        LD (Number+2),HL
        LD HL,Number
        CALL Decimal
        LD HL,TxtKb
        JP CopyZ

; --- размеры --------------------------------------------------------------

; HL -> Line2: «7.40 GB (15523840 sectors)» по DevSize.
SizeLine:
        LD DE,Line2
        CALL SizeText
        LD HL,TxtOpen
        CALL CopyZ
        LD HL,DevSize
        CALL Decimal
        LD HL,TxtSectors
        CALL CopyZ
        XOR A
        LD (DE),A
        LD HL,Line2
        RET

; Ёмкость DevSize в DE: до 1 ГиБ — «N.N MB», дальше «N.NN GB».
SizeText:
        PUSH DE
        LD HL,DevSize
        LD DE,Work
        CALL Copy32
        LD HL,Work
        LD BC,2048
        CALL Div32                      ; Work — МиБ, HL — остаток в секторах
        PUSH HL
        LD A,(Work+1)
        CP 4
        JR NC,.gb
        LD A,(Work+2)
        LD B,A
        LD A,(Work+3)
        OR B
        JR NZ,.gb
        POP HL                          ; десятые: остаток * 10 / 2048
        LD B,H
        LD C,L
        ADD HL,HL
        ADD HL,HL
        ADD HL,BC
        ADD HL,HL
        LD A,H
        SRL A
        SRL A
        SRL A                           ; / 2048 = старший байт / 8
        POP DE
        PUSH AF
        LD HL,Work
        CALL Decimal
        LD A,'.'
        LD (DE),A
        INC DE
        POP AF
        ADD A,'0'
        LD (DE),A
        INC DE
        LD HL,TxtMb
        JP CopyZ
.gb:    POP HL
        LD HL,Work
        LD BC,1024
        CALL Div32                      ; Work — ГиБ, HL — остаток в МиБ
        LD B,H                          ; сотые: остаток * 100 / 1024
        LD C,L
        LD DE,100
        PUSH BC
        POP BC
        CALL Mul16                      ; DE:HL = 100 * остаток
        LD (Number),HL
        LD (Number+2),DE
        LD HL,Number
        LD BC,1024
        CALL Div32
        LD A,(Number)
        POP DE
        PUSH AF
        LD HL,Work
        CALL Decimal
        LD A,'.'
        LD (DE),A
        INC DE
        POP AF
        LD L,A
        LD H,0
        LD C,10
        CALL Div16
        ADD A,'0'
        LD B,A
        LD A,L
        ADD A,'0'
        LD (DE),A
        INC DE
        LD A,B
        LD (DE),A
        INC DE
        LD HL,TxtGb
        JP CopyZ

; Строка 3: модель IDE и режим (LBA или CHS с геометрией); у SD — тип карты
; по CSD: v1 — SDSC, v2 до 32 ГиБ — SDHC, больше — SDXC.
InfoLine:
        LD DE,Line2
        LD A,(DevKind)
        CP KIND_SD
        JR NZ,.ide
        LD HL,TxtSdsc
        LD A,(CsdVersion)
        OR A
        JR Z,.copy
        LD HL,TxtSdhc
        LD A,(DevSize+3)                ; 32 ГиБ — #04000000 секторов
        CP 4
        JR C,.copy
        JR NZ,.xc
        LD A,(DevSize+2)
        LD B,A
        LD A,(DevSize+1)
        OR B
        LD B,A
        LD A,(DevSize)
        OR B
        JR Z,.copy
.xc:    LD HL,TxtSdxc
        JR .copy
.ide:   LD HL,Model
        LD A,(ModelLen)
        OR A
        JR Z,.mode
        LD C,A
        LD B,0
        LDIR
        LD A,','
        LD (DE),A
        INC DE
        LD A,' '
        LD (DE),A
        INC DE
.mode:  LD A,(DevKind)
        CP KIND_CHS
        LD HL,TxtLba
        JR NZ,.copy
        LD HL,TxtChs
        CALL CopyZ
        LD HL,(Cylinders)
        LD (Number),HL
        LD HL,0
        LD (Number+2),HL
        LD HL,Number
        CALL Decimal
        LD A,'/'
        LD (DE),A
        INC DE
        LD A,(DevHeads)
        CALL DecimalA
        LD A,'/'
        LD (DE),A
        INC DE
        LD A,(DevSpt)
        CALL DecimalA
        JR .end
.copy:  CALL CopyZ
.end:   XOR A
        LD (DE),A
        LD HL,Line2
        RET
DecimalA:
        LD L,A
        LD H,0
        LD (Number),HL
        LD HL,0
        LD (Number+2),HL
        LD HL,Number
; 32-битное (HL) десятичным числом в DE; DE — за последней цифрой.
Decimal:
        PUSH DE
        LD DE,DecWork
        CALL Copy32
        LD DE,DecDigits+10
        XOR A
        LD (DE),A
.digit: PUSH DE
        LD HL,DecWork
        LD BC,10
        CALL Div32
        POP DE
        DEC DE
        LD A,L
        ADD A,'0'
        LD (DE),A
        LD HL,DecWork
        PUSH DE
        LD DE,ZeroDword
        CALL Cmp32
        POP DE
        JR NZ,.digit
        EX DE,HL
        POP DE
        JP CopyZ
DecWork:        DD 0
DecDigits:      DS 11,0

; --- подтверждение --------------------------------------------------------

; Выход: CF=0 — Y; CF=1 — любая другая клавиша.
; Модальное окно «WARNING» поверх окна параметров: строки 2-4 — что
; пропадёт, строка 6 — вопрос; над текстом пустая строка под заголовком, под
; вопросом нижняя рамка.
Confirm:
        LD A,8
        LD HL,TitleWarning
        LD DE,0
        CALL OpenModal
        LD HL,TxtAllData
        LD D,2
        CALL ModalLine
        LD A,(DevIndex)
        CALL DevNameLine
        LD HL,Line2
        LD D,3
        CALL ModalLine
        CALL SizeLine
        LD D,4
        CALL ModalLine
        LD HL,TxtFormatQ
        LD D,6
        CALL ModalLine
        LD A,46
        CALL WLD
.wait:  EI
        HALT
        LD A,1
        EX AF,AF'
        LD A,42                         ; сырой стол: буквы строчные
        CALL WLD
        JR NZ,.key
        LD A,45
        CALL WLD
        JR Z,.wait
        XOR A
.key:   AND #DF
        CP 'Y'
        LD A,46
        PUSH AF
        CALL WLD
        CALL CloseModal
        POP AF
        RET Z                           ; CF=0 после CP при равенстве
        SCF
        RET

; --- ход записи -----------------------------------------------------------

; Окно хода: строка 3 — «Formatting <устройство>», 5 — полоса, 7 — проценты
; (DrawBar), на нижней рамке — «Esc - stop».
ShowProgress:
        LD HL,FootStop
        CALL OpenScreen
        LD DE,Line2
        LD HL,TxtFormatting
        CALL CopyZ
        LD A,(DevIndex)
        CALL DevNameAt
        LD HL,Line2
        LD D,3
        CALL Center
        LD A,COL_WINDOW
        JP Paint

; Полоса в строке 5 — как в окне копирования WC (WCINI.CP_DRAW): BAR_W
; клеток, слева направо #DB — пройдено, #B1 — осталось; в строке 7 —
; проценты Done/Total. Рисуется, когда меняется процент (BarPct).
BAR_W           EQU 40
DrawBar:
        LD HL,Done
        LD DE,BarDone
        CALL Copy32
        LD HL,Total
        LD DE,BarTotal
        CALL Copy32
.scale: LD A,(BarTotal+3)               ; оба ужать до Total < 512
        LD B,A
        LD A,(BarTotal+2)
        OR B
        JR NZ,.half
        LD A,(BarTotal+1)
        CP 2
        JR C,.scaled
.half:  LD HL,BarDone+3
        CALL Shr32
        LD HL,BarTotal+3
        CALL Shr32
        JR .scale
.scaled:
        LD HL,(BarDone)                 ; Done*100: 4D, 32D, 64D+32D+4D
        ADD HL,HL
        ADD HL,HL
        LD D,H
        LD E,L
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        LD B,H
        LD C,L
        ADD HL,HL
        ADD HL,BC
        ADD HL,DE
        LD (BarDone),HL
        LD HL,0
        LD (BarDone+2),HL
        LD BC,(BarTotal)
        LD A,B
        OR C
        RET Z
        LD HL,BarDone
        CALL Div32
        LD A,(BarDone)                  ; проценты, не больше 100
        CP 101
        JR C,.pct
        LD A,100
.pct:   LD HL,BarPct
        CP (HL)
        RET Z
        LD (HL),A
        CALL BarLine
        LD D,5
        CALL PrintLine
        LD A,COL_WINDOW
        CALL Paint
        LD DE,Line2                     ; «37%»
        LD A,(BarPct)
        CALL DecimalA
        LD A,'%'
        LD (DE),A
        INC DE
        XOR A
        LD (DE),A
        LD HL,Line2
        LD D,7
        CALL Center
        LD A,COL_WINDOW
        JP Paint
; Line — полоса для A процентов (0..100): клеток пройдено — A * 2 / 5.
BarLine:
        ADD A,A
        LD C,0
.five:  SUB 5
        JR C,.cells
        INC C
        JR .five
.cells: CALL FillLine
        LD HL,Line+(TEXT_W-BAR_W)/2
        LD B,BAR_W
.cell:  LD A,C
        OR A
        LD A,#B1                        ; осталось
        JR Z,.put
        DEC C
        LD A,#DB                        ; пройдено
.put:   LD (HL),A
        INC HL
        DJNZ .cell
        RET
; (HL) — старший байт 32-битного; сдвиг вправо на 1.
Shr32:  SRL (HL)
        DEC HL
        RR (HL)
        DEC HL
        RR (HL)
        DEC HL
        RR (HL)
        RET

; --- итог -----------------------------------------------------------------

; Удача — окно итога; отказ — модальное окно ошибки поверх окна хода.
Summary:
        LD A,(FormatResult)
        OR A
        JR NZ,.failed
        LD HL,FootKey
        CALL OpenScreen
        LD DE,Line2                     ; «Done: FAT32, 7.40 GB»
        LD HL,TxtDone
        CALL CopyZ
        CALL SizeText
        XOR A
        LD (DE),A
        LD HL,Line2
        LD D,3
        CALL Center
        LD A,COL_WINDOW
        CALL Paint
        LD DE,Line2                     ; «Cluster 32 KB, 236511 free clusters»
        LD HL,TxtClusterIs
        CALL CopyZ
        CALL ClusterText
        LD HL,TxtComma
        CALL CopyZ
        PUSH DE                         ; свободных — все, кроме корня
        LD HL,Clusters
        LD DE,Work
        CALL Copy32
        LD HL,Work
        LD BC,1
        CALL Sub32c
        POP DE
        LD HL,Work
        CALL Decimal
        LD HL,TxtFree
        CALL CopyZ
        XOR A
        LD (DE),A
        LD HL,Line2
        LD D,5
        CALL Center
        LD A,COL_WINDOW
        CALL Paint
        LD HL,TxtPanels
        LD D,7
        CALL Center
        LD A,COL_WINDOW
        CALL Paint
        JP WaitKey
.failed:
        DEC A
        ADD A,A
        LD L,A
        LD H,0
        LD DE,FormatTexts
        ADD HL,DE
        LD A,(HL)
        INC HL
        LD H,(HL)
        LD L,A
        JP ShowError
FormatTexts:    DW MsgWriteFail,MsgStopped,MsgVerifyFail

; --- тексты ---------------------------------------------------------------

; Подсказки — по центру нижней рамки (#0E), как в WC Setup.
FootMenu:       DB #0E,#09,"Up/Down - drive  Enter - choose  Esc - exit",0
FootOptions:    DB #0E,#09,"Arrows - set  Enter - format  Esc - back",0
FootKey:        DB #0E,#09,"Press any key",0
FootStop:       DB #0E,#09,"Esc - stop",0
TitleError:     DB #0E,#09,"ERROR",0
TitleWarning:   DB #0E,#09,"WARNING",0
MsgChecking:    DB "Checking the drive...",0
MsgMissing:     DB "Drive not found",0,0
MsgNoCsd:       DB "SD card did not report its size",0,0
MsgBadSize:     DB "Drive size or geometry not supported",0,0
MsgBootDrive:   DB "WC was started from this drive",0,"It cannot be formatted",0
MsgSmall:       DB "Drive too small for FAT32",0
MsgFew:         DB "Cluster too large for this drive",0
MsgMany:        DB "Cluster too small for this drive",0
MsgReserved:    DB "No layout for this drive",0
MsgWriteFail:   DB "Write error",0,"The drive has no file system now",0
MsgStopped:     DB "Formatting stopped",0,"The drive has no file system now",0
MsgVerifyFail:  DB "Read-back mismatch",0,"Check the drive",0
TxtCluster:     DB "Cluster size:",0
TxtOpenArrow:   DB "< ",0
TxtAuto:        DB "Auto",0
TxtColon:       DB ": ",0
TxtCloseArrow:  DB " >",0
TxtLabel:       DB "Volume label:",0
TxtResult:      DB "FAT32, ",0
TxtClusters:    DB " clusters",0
Txt512:         DB "512 B",0
TxtKb:          DB " KB",0
TxtMb:          DB " MB",0
TxtGb:          DB " GB",0
TxtOpen:        DB " (",0
TxtSectors:     DB " sectors)",0
TxtLba:         DB "LBA",0
TxtSdsc:        DB "SDSC card",0
TxtSdhc:        DB "SDHC card",0
TxtSdxc:        DB "SDXC card",0
TxtChs:         DB "CHS ",0
TxtAllData:     DB "All data will be lost on",0
TxtFormatQ:     DB "Format? (Y/N)",0
TxtFormatting:  DB "Formatting ",0
TxtDone:        DB "Done: FAT32, ",0
TxtClusterIs:   DB "Cluster ",0
TxtComma:       DB ", ",0
TxtFree:        DB " free clusters",0
TxtPanels:      DB "Panels on this drive show its new root.",0

Window:         DS 22,0
Modal:          DS 22,0
WindowOpen:     DB 0
DevIndexTmp:    DB 0
Line2:          DS 64,0
