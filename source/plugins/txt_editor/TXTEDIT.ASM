;Ilich Editor v0.71
;(C) KOSHI/MGN 2024
;-----------------------------------------------------------------------------------------
HEADER  EQU #6000
BINAR   EQU HEADER+512

        IFNDEF __ALASM_CORG_ACTIVE
        ORG HEADER
        DISP HEADER
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL HEADER
__ALASM_CORG_LOGICAL DEFL HEADER
__ALASM_CORG_DISP DEFL 1
        ELSE
__ALASM_CORG_END DEFL __ALASM_CORG_CODE + ($ - __ALASM_CORG_LOGICAL)
__ALASM_CORG_NEW DEFL HEADER
        IF __ALASM_CORG_NEW > __ALASM_CORG_END
        DS __ALASM_CORG_NEW - __ALASM_CORG_END,0
        ENDIF
        IF __ALASM_CORG_DISP
        ENT
        ENDIF
        DISP HEADER
__ALASM_CORG_CODE DEFL __ALASM_CORG_NEW
__ALASM_CORG_LOGICAL DEFL HEADER
__ALASM_CORG_DISP DEFL 1
        ENDIF
WLD     EQU #6006; Plugin System Call Point
TMN     EQU #6009; Timer
HEI     EQU #600E; Height (25,30,36)
WC_LANG EQU #781A; LANG из фиксированного блока PS2P: 0=ENG, 1=RUS.

CYC     EQU #2BAF;      Cache
CACHE   EQU %00000100; #8000 Only!

TABSIZE EQU 8

DFCOL   EQU %00000111; Default Color
DFCOLI  EQU %11110000; DC inverted
MDCOL   EQU %01010111; Marked Color
MDCOL2  EQU %01010101; MC Ink=Paper
HLACOL  EQU %00000110; Punctuation
HLBCOL  EQU %00000100; Comment
HLCCOL  EQU %00001110; ( ) + - * /
HLDCOL  EQU %00001111; Digits
HLQCOL  EQU %00000011; Quotes

CLCWNDC EQU %01001111; Inspector Window Color
SRHWNDC EQU %01001111; Search Window Color
NFNWNDC EQU %00101111; Not Found Window Color

MDLTR   EQU 1; Marked LeftToRight

LNZ     EQU 1; Upper offset on Screen
LNZ2    EQU 1; Lower offset on Screen
IND     EQU 4; Page UP Ind. for MARKED
PGZ     EQU 0; TXT Buffer Start Page
PGM     EQU #3F; TXT Buffer End Page

;Save As: Abort Error Code
SASAEC  EQU 254

;Calc Buffer
CBUF    EQU #C000-#500
CBUF1   EQU CBUF+256

;DECOD2 Buffer
D2BUF   EQU CBUF1+256

;Buffer
BUF2    EQU D2BUF+256;Const1,0,Const2,0 for EXPs
BUF3    EQU BUF2+256;Source EXP
SPSAFE  EQU BUF3

;Calc Prefx
C1B     EQU #01;1 Byte Index
C2B     EQU #02;2 Byte Index

CLA     EQU #04;Constant Index
CP1     EQU #05;+
CP2     EQU #06;-
CP3     EQU #07;*
CP4     EQU #08;/
CP5     EQU #09;\ Mod
CP6     EQU #0A;[ Hi
CP7     EQU #0B;] Low
;-----------------------------------------------------------------------------------------
;PLUGIN HEADER
        DS 16; Reserved
        DB "WildCommanderMDL"; Header
        DB #10; v0.16 of Plugin System Needed
        DB 0; Reserved
        DB 2; Pages
        DB 0; Page to #8000

        DB 0,1+(ENDPL-PLUGIN)/512; Main Code (page and size)
 .5      DB 0,0

        DS 16

        DS 32*3; File extensions

        DB 0

        DW #FFFE,#000F; Max File Size

        DB "TXT Editor v0.71                "; Plugin Name
        DB #15,"Edit  "; F4 Option Text
        DB "Edit with TXT Editor    "; Green Menu Text
;-------
        DS 32;+228
;-------
PAR1    DB PAR1END-PAR1;Structure size
        DB 1;Default option
        DB "highlight"
        DB 3;Options count
        DB "on",0
        DB "off",0
        DB "auto",0
PAR1END NOP;END TOKEN
;-------------------------------------------------------------------------------
        IFNDEF __ALASM_CORG_ACTIVE
        ORG BINAR
        DISP #8000
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL BINAR
__ALASM_CORG_LOGICAL DEFL #8000
__ALASM_CORG_DISP DEFL 1
        ELSE
__ALASM_CORG_END DEFL __ALASM_CORG_CODE + ($ - __ALASM_CORG_LOGICAL)
__ALASM_CORG_NEW DEFL BINAR
        IF __ALASM_CORG_NEW > __ALASM_CORG_END
        DS __ALASM_CORG_NEW - __ALASM_CORG_END,0
        ENDIF
        IF __ALASM_CORG_DISP
        ENT
        ENDIF
        DISP #8000
__ALASM_CORG_CODE DEFL __ALASM_CORG_NEW
__ALASM_CORG_LOGICAL DEFL #8000
__ALASM_CORG_DISP DEFL 1
        ENDIF

; Рабочее имя отнесено за код, но остаётся внутри собственной страницы плагина.
; #B900 — заголовок, #BA00 — клетка подсветки, #BB00..#BFFF — Inspector.
; ASSERT в конце запрещает сборку, если код дойдёт до атрибута/размера FLMAKE.
ENTRYN  EQU #B700
FLLOAD  EQU ENTRYN-1
FLMAKE  EQU ENTRYN-5

WHEAD   EQU ENTRYN+512
;-------
PLUGIN  LD (DAHL),HL,(DADE),DE

        EXA
        XOR A
        LD (ESTA),A
        LD (CHANGES),A
        LD (MARKED),A,(REFFLG),A
        LD (F10MENU),A
        LD (SVERFLG),A
        LD A," ",(TAPTCHA),A
        LD A,#FF,(HELP_HINT_LANG),A; При каждом открытии заново вывести подпись F1.
        EXA

        CP #03:CALL Z,NO_FILE_FLAG

        LD HL,BC
        LD DE,ENTRYN
        LD BC,256:LDIR

        LD BC,CYC,A,CACHE:OUT (C),A; Cache ON (#8000-#BFFF only)

; API GEDPL пишет таблицы палитры по #1000/#11E0..#1447 в текущем окне #0000.
; Поэтому сначала подключаем ещё свободную текстовую страницу 0 и вызываем
; GEDPL, и лишь ПОТОМ загружаем файл. Вызов после LOAD/DETECT_EOL повреждал
; занятую страницу: в Unreal обнаружено 584 изменённых байта большого файла.
        XOR A:CALL MNG0VPL,GEDPL
        CALL LOAD:JR Z,PLUGIN_LOAD_OK

; При ошибке чтения не открываем редактор с частично заполненным буфером.
        LD IX,ERWND:CALL PRWOW
        LD HL,MSG_READ_ERROR,DE,#0100:CALL TXTPR
        CALL USPO,NUSP
        CALL RRESB
        XOR A
        RET

PLUGIN_LOAD_OK CALL DETECT_EOL
        LD HL,CURCOL,DE,CURCOL+1,BC,8,(HL),0:LDIR
        LD IX,PLWND:CALL PRWOW

        CALL NAMETOH

        XOR A
        LD (CRX),A
        LD A,PGZ
        LD (PGHLP+2),A
        LD (LNHLP+2),A
        LD (LHLCR+2),A
        LD HL,0
        LD (PGHLP),HL
        LD (LNHLP),HL
        LD (LHLCR),HL

        CALL REFRESH
        LD HL,#0100,A,#FE:CALL ISTR
MAIN    EI:HALT:CALL OFFSETS_PRINT
        LD A,#FC:CALL ISTR,STUPD
        CALL EDITOR_STATUS

        CALL SHIFT:JR Z,NOSHFT

        CALL LFFF:LD A,5:JR NZ,DADAN
        CALL UPPP:LD A,6:JR NZ,DADAN

        CALL DWWW:LD A,1:JR NZ,DADAN
        CALL END:LD A,2:JR NZ,DADAN
        CALL PGDN:LD A,3:JR NZ,DADAN
        CALL RGGG:LD A,4:JR Z,NOSHFT
DADAN   LD (DADAH+1),A,C,A

        LD A,(MARKED):OR A:JR NZ,DADA
        LD A,C:CP 5:JR NC,DADAEX
        LD HL,LHLCR,DE,BHLBLK,BC,3:LDIR
DADA    LD A,MDLTR,(REFFLG),A
DADAH   LD A,0
        DEC A:PUSH AF:CALL Z,GODW:POP AF
        DEC A:PUSH AF:CALL Z,SSE:POP AF
        DEC A:PUSH AF:CALL Z,GOPD:POP AF
        DEC A:PUSH AF:CALL Z,GORG:POP AF
        DEC A:PUSH AF:CALL Z,GOLF:POP AF
        DEC A:CALL Z,GOUP

DADAEX  XOR A:LD (REFFLG),A
        JP MAIN

NOSHFT  CALL CTRL:JR Z,NOAD
        CALL ALT:JR NZ,CTRLALT_COMBO

        CALL HOME,NZ,GOSTART:JP NZ,MAIN
        CALL END,NZ,GOEND:JP NZ,MAIN

        LD A,1:CALL KBSCN
        CP "s":CALL Z,QSAVE

        CP "f":CALL Z,SEARCH
        CP "g":CALL Z,SEARCHNEXT

        CP "c":CALL Z,COPY
        CP "v":CALL Z,PASTE
        CP "x":CALL Z,CUT
        JP MAIN

CTRLALT_COMBO LD A,1:CALL KBSCN
              CP "s":CALL Z,SAVEAS
              JP MAIN

NOAD    CALL TABK,NZ,ADDTAB

        CALL HOME,NZ,SSQ
        CALL END,NZ,SSE

        CALL ENKE,NZ,GO0D
        CALL BSPC,NZ,BSPACE
        CALL DEL,NZ,DELETE
;-------
        XOR A:CALL KBSCN,NZ,SMBADD

        CALL LFFF,NZ,GOLF
        CALL RGGG,NZ,GORG
        CALL UPPP,NZ,GOUP
        CALL DWWW,NZ,GODW
        CALL PGUP,NZ,GOPU
        CALL PGDN,NZ,GOPD

        CALL F3,NZ,INSPECTOR:JP NZ,MAIN
        CALL F2,NZ,HIGHLIGHT_SWITCH
        CALL F1,NZ,F1MENU
        CALL ESC:JP Z,MAIN
;-------
EXIT    CALL SAVECH:JP C,MAIN
        CALL RRESB
        LD A,(ESTA)
        RET
;---------------------------------------
NO_FILE_FLAG LD A,1,(F10MENU),A,(CHANGES),A
             LD BC,TXTNAME
             RET
;---------------------------------------
; Ctrl+Home: перенести зазор к BOF и сбросить полную целевую колонку.
; Иначе следующий Down возвращал старую колонку вместо начала строки.
GOSTART      CALL CRM13U
GGSTART      CALL CRM13U:JP C,GGSTART
             LD A,PGZ,(PGHLP+2),A
             LD HL,0,(PGHLP),HL:CALL REFRESH
             CALL SYNC_COLUMN
             LD A,1:OR A:RET
;-------
; Ctrl+End: перенести зазор к EOF; показать последние строки окна.
; Каждый CRM13D сам подключает обе страницы: обработка CRLF меняет окно #0000.
GOEND        CALL CRM13D
GGEND        CALL CRM13D:JP C,GGEND
             LD HL,LHLCR,DE,PGHLP,BC,3:LDIR
             LD A,(IX+5):SUB LNZ+1+LNZ2
             LD B,A
GEND         PUSH BC:CALL PGMUZ
             POP BC:JR NC,Gend
             DJNZ GEND
Gend         CALL REFRESH,SYNC_COLUMN
             LD A,1:OR A:RET
;-------
;Move Page Up
GOPU         CALL CRM13U
             LD A,(IX+5):SUB LNZ+1
             LD B,A
PGU_CUR_MOVE PUSH BC:CALL CRM13U,PGMUZ
             POP BC:JR NC,FILE_UP_FND
             DJNZ PGU_CUR_MOVE
             CALL STEP_RIGHT
FILE_UP_FND  LD A,(CRX):CALL CRMFWD
             JP REFRESH
;-------
;Move Page Down
GOPD         LD A,(IX+5):SUB LNZ+1
             LD B,A
PGD_CUR_MOVE PUSH BC:CALL CRM13D,C,PGMD
             POP BC:JR NC,FILE_END_FND
             DJNZ PGD_CUR_MOVE
FILE_END_FND LD A,(CRX):CALL CRMFWD
             JP REFRESH
;-------
;Move Cursor Upward
GOUP    CALL NAV_BEGIN,CRM13U
        CALL CRM13U,C,STEP_RIGHT
        LD A,(CRX):CALL CRMFWD
        LD A,(CRP+1)
        CP LNZ:CALL Z,PGMUZ
        JP NAV_REFRESH
;-------
;Move Cursor Downward
GODW    CALL NAV_BEGIN,CRM13D:JR NC,GOD
        LD A,(CRX):CALL CRMFWD
        LD A,(CRP+1):INC A,A
        CP (IX+5):CALL NC,PGMD
GOD     JP NAV_REFRESH
;-------
;Move Cursor Left
GOLF    CALL NAV_BEGIN,STEP_LEFT
        CALL NAV_REFRESH,SYNC_COLUMN
        RET
; Край окна больше не ограничивает движение: REFRESH прокрутит длинную строку.
GORG    CALL NAV_BEGIN,STEP_RIGHT:RET NC
        CP 13:JR Z,GORG_EOL
        CP 10:JR NZ,GORG_DRAW
GORG_EOL LD A,(CRP+1):INC A,A:CP (IX+5):CALL NC,PGMD
GORG_DRAW CALL NAV_REFRESH,SYNC_COLUMN:RET
;-------
GO0D    LD BC,1
        LD A,(EOL_SECOND):OR A:JR Z,ENTER_ROOM
        INC BC
ENTER_ROOM CALL EDIT_ROOM:JP NC,BUFFER_FULL
        CALL MARK_KILL
        LD A,(EOL_FIRST):CALL INCLCR
        LD A,(EOL_SECOND):OR A:CALL NZ,INCLCR
        LD A,(CRP+1):INC A,A:CP (IX+5):CALL NC,PGMD
G0dno   CALL REFRESH,SYNC_COLUMN:JP CHA
;-------
; Проверяем замену до удаления выделения. При OVR в заполненном файле
; свободное место не нужно, пока заменяется существующий обычный байт.
SMBADD  PUSH AF
        LD A,(MARKED):OR A:JR Z,SMB_ROOM_OK
        LD BC,1:CALL EDIT_ROOM:JR C,SMB_ROOM_OK
        POP AF:JP BUFFER_FULL
SMB_ROOM_OK CALL MARK_KILL
        POP BC:LD A,B:JR NZ,INSM

        LD BC,(INOV):BIT 0,C:JR Z,INSM
        PUSH AF:CALL INCCUR
        POP BC:JR NC,OVR_EOF
        CP 13:JR Z,OVR_NEWLINE
        CP 10:JR Z,OVR_NEWLINE
        LD A,B
        CALL DECLCRN
        CALL REFRESH
        CALL SYNC_COLUMN
        JP CHA
OVR_EOF LD A,B:JR INSM; На EOF режим замены дописывает новый символ.
OVR_NEWLINE LD A,B
OVRM    PUSH AF:CALL DECCUR
        POP AF
INSM    CALL INCLCR:RET NC
        CALL REFRESH
        CALL SYNC_COLUMN
        JP CHA
;-------
; Tab — настоящий байт #09. Экран разворачивает его до позиции, кратной 8.
; Замена выделения атомарна; при нехватке памяти выделение остаётся нетронутым.
ADDTAB  LD BC,1:CALL EDIT_ROOM:JP NC,BUFFER_FULL
        CALL MARK_KILL
        LD A,9:CALL INCLCR:JP G0dno
;-------
SSQ     CALL NAV_BEGIN,CRM13U,C,STEP_RIGHT
        CALL NAV_REFRESH
        CALL SYNC_COLUMN
        RET
SSE     CALL NAV_BEGIN,CRM13D,C,STEP_LEFT
        CALL NAV_REFRESH
        CALL SYNC_COLUMN
        RET
;-------
; Delete/Backspace удаляют перенос CRLF целиком, даже между страницами.
; Проверка соседа выполняется до удаления; одиночные CR и LF тоже допустимы.
DELETE  CALL MARK_KILL:JR NZ,Bspc
        CALL PEEK_RIGHT:RET NC
        PUSH AF:CALL INCRCR:POP AF
        CP 13:JR NZ,Bspc
        CALL PEEK_RIGHT:JR NC,Bspc
        CP 10:CALL Z,INCRCR:JR Bspc
BSPACE  CALL MARK_KILL:JR NZ,Bspc
        CALL PEEK_LEFT:RET NC
        PUSH AF:CALL DECLCR:POP AF
        CP 10:JR NZ,Bspc
        CALL PEEK_LEFT:JR NC,Bspc
        CP 13:CALL Z,DECLCR
Bspc    CALL REFRESH,SYNC_COLUMN:JP CHA
;-------
STUPD   AND %10000000:RLCA:LD (INOV),A:RET
;-------
CHA     LD A,1,(CHANGES),A:RET
;---------------------------------------
MARK_KILL LD A,(MARKED):OR A:RET Z

          LD A,(BHLBLK+2),BC,(PGHLP+2)
          CP C:JR C,MARKCURGG,Z,$+4,NC,MARKCUROK
          LD HL,(BHLBLK),DE,(PGHLP)
          OR A:SBC HL,DE:JR Z,MARKCUROK,NC,MARKCUROK
MARKCURGG LD HL,BHLBLK,DE,PGHLP,BC,3:LDIR

          LD A,(IX+5):SUB LNZ+1+IND
          LD B,A
GMARKPG   PUSH BC:CALL PGMUZ
          POP BC:JR NC,GMARKGG
          DJNZ GMARKPG
GMARKGG   CALL MARKCUROK
          SCF
          RET

MARKCUROK LD HL,BHLBLK,DE,LHLCR,BC,3:LDIR
          LD A,1:OR A
          RET
;---------------------------------------
MRK_REF LD HL,LHLCR,DE,EHLBLK,BC,3:LDIR
        LD A,(BHLBLK+2)
        LD HL,(EHLBLK+2)
        CP L:JR C,MRK_OK,Z,$+4,NC,MRK_BAD
        LD HL,(BHLBLK),DE,(EHLBLK)
        OR A:SBC HL,DE:JR C,MRK_OK
MRK_BAD XOR A:JR REFA
MRK_OK  LD A,1:JR REFA
REFRESH LD A,(REFFLG):OR A:JR NZ,MRK_REF
REFA    LD (MARKED),A
        JP PAGE
;---------------------------------------
        INCLUDE "TEXT_VIEW.INC"
;---------------------------------------
COLcommeON LD A,1,(HLCFLG),A
COLcomment LD A,HLBCOL:JP COLFIN
;----------
COLquote   CP #22:JR NZ,COLquoteGO
           XOR A:JP COLquoteOF
COLquoteON LD A,1
COLquoteOF LD (HLQFLG),A
COLquoteGO LD A,HLQCOL:JP COLFIN
;----------
COLhex     CP "0":JR C,COLhexOF
           CP "F"+1:JR NC,COLhexOF
COLhexGO   LD A,HLDCOL:JP COLFIN
COLhexON   LD A,1,(HLhexFLG),A:JP COLhexGO
COLhexOF   XOR A:LD (HLhexFLG),A:JP DEFCOL
;----------
FILLnCOL   PUSH HL,BC
           LD (DE),A,(PREVchar),A

           LD B,0
HLCFLG     EQU $-1
           DEC B:JR Z,COLcomment

           LD B,0
HLQFLG     EQU $-1
           DEC B:JR Z,COLquote

           CP ";":JR Z,COLcommeON
           CP #22:JR Z,COLquoteON
           CP "#":JR Z,COLhexON
           CP "%":JR Z,COLhexON;bin

           CP " ":JP Z,DEFCOL
           LD C,HLACOL
           CP ",":JP Z,COLfin
           CP ":":JR Z,COLfin
           CP ".":JR Z,COLfin

           LD C,HLCCOL
           CP "(":JR Z,COLfin
           CP ")":JR Z,COLfin
           CP "+":JR Z,COLfin
           CP "-":JR Z,COLfin
           CP "*":JR Z,COLfin
           CP "/":JR Z,COLfin
           CP "[":JR Z,COLfin
           CP "]":JR Z,COLfin
           CP "\\":JR Z,COLfin
           CP "<":JR Z,COLfin
           CP ">":JR Z,COLfin
           CP "{":JR Z,COLfin
           CP "}":JR Z,COLfin
           CP "=":JR Z,COLfin

           LD B,0
HLhexFLG   EQU $-1
           DEC B:JP Z,COLhex

           LD B,0
HLdecFLG   EQU $-1
           DEC B:JR Z,COLdec
           CP "0":JR C,DEFCOL
           CP "9"+1:JR NC,DEFCOL
COLdecON   LD A,(PREVCHAR)
           LD HL,SEPARATORS,BC,SEPLEN
           CPIR:JR Z,COLdecCHK
           LD HL,OPERATORS,BC,OPLEN
           CPIR:JR NZ,DEFCOL
COLdecCHK  LD A,1,(HLdecFLG),A:JP COLdecGO           
COLdec     CP "0":JR C,DEFCOL
           CP "9"+1:JR NC,DEFCOL
COLdecGO   LD A,HLDCOL:JP COLFIN

DEFCOL     LD C,DFCOL
COLfin     XOR A:LD (HLhexFLG),A,(HLdecFLG),A
           LD A,C
COLFIN     SET 7,E:LD (DE),A
           RES 7,E

PREVchar   EQU $+1
           LD A,0,(PREVCHAR),A

           INC E
           POP BC,HL
           RET
COLfinSEP  LD BC,SEPARATORS
           OR A:SBC HL,BC
           LD BC,SEPARATORcol-1
           ADD HL,BC
           LD C,(HL)
           JP COLfin
COLfinOPER LD BC,OPERATORS
           OR A:SBC HL,BC
           LD BC,OPERATORcol-1
           ADD HL,BC
           LD C,(HL)
           JP COLfin
;---------------------------------------
CURTAT  ;Set Cursor
        LD HL,(CRPOZ):LD A,H:OR L:RET Z
        LD (CRFLG),A
        BIT 7,L:RET NZ
        SET 7,L
; Быстрое перемещение возвращает исходный атрибут предыдущей клетки.
; Его нельзя вычислять обратной инверсией: бит 7 принудительно включается,
; а цвет может принадлежать синтаксической подсветке или выделению.
        LD (CURSOR_ADDR),HL
        LD A,(HL),(CURSOR_ATTR),A
        LD A,(HL):OR A:JR Z,CURCLE
        RRD
        SET 7,(HL)
        RET
CURCLE  LD (HL),DFCOLI:RES 7,L
        LD (HL)," "
        RET
;-------
ESTRCLR ;Clearing End Of String
        LD C," "
        LD A,(IX+4):SUB L:RET Z:RET C
        LD B,A,(HL),C:INC L:DJNZ $-2
        RET
;---------------------------------------
DZT     LD DE,#3FFF:JP ZZT
FAST    LD A,(RHLCR+2):INC A
        CP PGM+1:JR NC,DZT
        LD (RHLCR+2),A
        PUSH BC:CALL MNGCVPL
        POP BC
        SET 7,D
        SET 6,D
        JP FASTB

; Быстрый перенос зазора до следующего EOL. Вход: LHLCR/RHLCR; выход:
; C — перенос найден и поглощён целиком, NC — достигнут EOF. AF/BC/DE/HL
; меняются, IX сохраняется. Tab/NUL не завершают строку. Пара CRLF может
; пересекать страницу: второй байт читается через проверенный PEEK_RIGHT.
CRM13D  LD A,(LHLCR+2)
        EXA:LD A,80:CALL WLD;=CALL MNG0VPL
        LD A,(RHLCR+2)
        EXA:LD A,65:CALL WLD;=CALL MNGCVPL
        LD C,#0D+1
CR13D   LD HL,(LHLCR)
        LD DE,(RHLCR)
        SET 7,D
        SET 6,D
CR13DD  INC DE:BIT 7,D:JR Z,FAST
FASTB   LD A,(DE),(HL),A

        INC HL:BIT 6,H:JR NZ,FAST2
FAST2B  CP 13:JR Z,CR_DOWN_CR
        CP 10:JP NZ,CR13DD
        CALL ZZT:SCF:RET
CR_DOWN_CR CALL ZZT,PEEK_RIGHT:JR NC,CR_DOWN_DONE
           CP 10:CALL Z,INCCUR
CR_DOWN_DONE SCF:RET
ZZT     LD (LHLCR),HL
        RES 7,D
        RES 6,D
        LD (RHLCR),DE
        RET
;-------
FAST2   PUSH AF
        LD A,H:AND %00111111:LD H,A
        LD A,(LHLCR+2):INC A
        LD (LHLCR+2),A
        PUSH BC:CALL MNG0VPL
        POP BC
        POP AF
        JP FAST2B
;---------------------------------------     
AZT     LD HL,0:JP AZZ
FAZT    LD A,H:AND %00111111:LD H,A
        LD A,(LHLCR+2):CP PGZ:JR Z,AZT:DEC A
        LD (LHLCR+2),A
        PUSH BC:CALL MNG0VPL
        POP BC
        JP FAZTB

; Аналогичный проход назад: остановка ПЕРЕД целым переносом, C=найден EOL,
; NC=BOF. Левый LF поглощает предшествующий CR, но одиночный LF допустим.
CRM13U  LD A,(LHLCR+2)
        EXA:LD A,80:CALL WLD;=CALL MNG0VPL
        LD A,(RHLCR+2)
        EXA:LD A,65:CALL WLD;=CALL MNGCVPL
        LD C,#0D+1
CR13U   LD HL,(LHLCR)
        LD DE,(RHLCR)
        SET 7,D
        SET 6,D

CR13UU  DEC HL:BIT 7,H:JR NZ,FAZT
FAZTB   LD A,(HL),(DE),A
        
        DEC DE:BIT 6,D:JR Z,FAZT2
FAZT2B  CP 10:JR Z,CR_UP_LF
        CP 13:JP NZ,CR13UU
        CALL AZZ:SCF:RET
CR_UP_LF CALL AZZ,PEEK_LEFT:JR NC,CR_UP_DONE
         CP 13:CALL Z,DECCUR
CR_UP_DONE SCF:RET
AZZ     LD (LHLCR),HL
        RES 7,D
        RES 6,D
        LD (RHLCR),DE
        RET

FAZT2   SET 6,D
        PUSH AF
        LD A,(RHLCR+2):DEC A
        LD (RHLCR+2),A
        PUSH BC:CALL MNGCVPL
        POP BC
        POP AF      
        JP FAZT2B
;---------------------------------------
INCTMP  LD HL,(LNTMP):INC HL
        LD A,H:CP #40:JR NC,AKIRA
        LD (LNTMP),HL
        RET

AKIRA   AND %00111111:LD H,A
        LD A,(LNTMP+2):INC A
        CP PGM+1:RET NC
        LD (LNTMP+2),A
        LD (LNTMP),HL
        RET
;---------------------------------------
INCLN   LD HL,(LNHLP):INC HL
        LD A,H:CP #40:JR NC,CRASH
        LD (LNHLP),HL
        SCF
        RET

CRASH   AND %00111111:LD H,A
        LD A,(LNHLP+2):INC A
        CP PGM+1:RET NC
        LD (LNHLP+2),A
        LD (LNHLP),HL
        SCF
        RET
;---------------------------------------
INCPG   LD HL,(PGHLP),E,(HL):INC HL
        LD A,H:CP #40:JR NC,ILYA
        LD (PGHLP),HL
        SCF
        RET

ILYA    AND %00111111:LD H,A
        LD A,(PGHLP+2):INC A
        CP PGM+1:RET NC
        LD (PGHLP+2),A
        LD (PGHLP),HL
        PUSH DE
;CALL MNG0VPL
        EXA:LD A,80:CALL WLD
        POP DE
        SCF
        RET
;---------------------------------------
INCLCR  ;Increment Left Cursor
;        i: A - Char to Add
;        o:NC - Failed
;           C - OK

        PUSH AF
; На последнем байте последней страницы нельзя даже временно перейти на #40.
; Проверяем границу до записи символа, чтобы отказ не менял буфер.
        LD A,(LHLCR+2):CP PGM:JR NZ,INCLCR_MAP
        LD HL,(LHLCR):INC HL
        LD A,H:CP #40:JR NC,INCLCR_FULL
INCLCR_MAP
        LD A,(LHLCR+2)
        EXA:LD A,80:CALL WLD;=CALL MNG0VPL
        POP DE
        LD HL,(LHLCR),(HL),D:INC HL
        LD A,H:CP #40:JR NC,GRAD
        LD A,(LHLCR+2)
GRADB   LD DE,(RHLCR)
        PUSH HL:OR A:SBC HL,DE
        POP HL:JR NZ,LEQR
        LD BC,(RHLCR+2):CP C:RET Z

LEQR    LD (LHLCR+2),A
        LD (LHLCR),HL
        SCF
        RET
;-------
GRAD    AND %00111111:LD H,A
        LD A,(LHLCR+2):INC A
        CP PGM+1:RET NC
        JP GRADB
INCLCR_FULL POP AF:OR A:RET
;---------------------------------------
DECLCRN LD C,A
        LD HL,(LHLCR):DEC HL
        LD A,H:CP #40:JR NC,NULL
        LD A,(LHLCR+2)
NULLB   PUSH HL,BC:CALL MNG0VPL
        POP BC,HL
        LD (HL),C
        SCF
        RET
NULL    AND %00111111:LD H,A
        LD A,(LHLCR+2)
        CP PGZ:RET Z:DEC A
        JP NULLB
;---------------------------------------
DECLCR  LD HL,(LHLCR):DEC HL
        LD A,H:CP #40:JR NC,CRASX
CRASXB  LD (LHLCR),HL
        SCF
        RET
CRASX   AND %00111111:LD H,A
        LD A,(LHLCR+2)
        CP PGZ:RET Z:DEC A
        LD (LHLCR+2),A
        JP CRASXB
;-------
INCRCR  LD HL,(RHLCR):INC HL
        LD A,H:CP #40:JR NC,GRADX
GRADXB  LD (RHLCR),HL
        SCF
        RET
GRADX   AND %00111111:LD H,A
        LD A,(RHLCR+2):INC A
        CP PGM+1:RET NC
        LD (RHLCR+2),A
        JP GRADXB

;---------------------------------------
CRAS    AND %00111111:LD H,A
        LD A,(LHLCR+2)
        CP PGZ:RET Z:DEC A
        LD (LHLCR+2),A
        JP CRASB

DECCUR  LD HL,(LHLCR):DEC HL
        LD A,H:CP #40:JR NC,CRAS
CRASB   LD (LHLCR),HL
;-------
        LD A,(LHLCR+2)
        EXA:LD A,80:CALL WLD;=CALL MNG0VPL

        LD HL,(LHLCR)
        LD A,(HL)
        PUSH AF
        LD A,(RHLCR+2)
        EXA:LD A,80:CALL WLD;=CALL MNG0VPL

        LD HL,(RHLCR)
        POP AF
        LD (HL),A
;-------
        EXA
        LD HL,(RHLCR):DEC HL
        LD A,H:CP #40:JR NC,CRASh
CRAShB  LD (RHLCR),HL
        EXA
        SCF
        RET
;-------
CRASh   AND %00111111:LD H,A
        LD A,(RHLCR+2):DEC A
        LD (RHLCR+2),A
        JP CRAShB
;---------------------------------------
CRASH2  AND %00111111:LD H,A
        LD A,(RHLCR+2):INC A
        CP PGM+1:RET NC
        LD (RHLCR+2),A
        JP CRASH2B

INCCUR  LD HL,(RHLCR):INC HL
        LD A,H:CP #40:JR NC,CRASH2
CRASH2B LD (RHLCR),HL
;-------
        LD A,(RHLCR+2)
        EXA:LD A,80:CALL WLD;=CALL MNG0VPL

        LD HL,(RHLCR)
        LD A,(HL)
        PUSH AF
        LD A,(LHLCR+2)
        EXA:LD A,80:CALL WLD;=CALL MNG0VPL

        LD HL,(LHLCR)
        POP AF
        LD (HL),A
;-------
        EXA
        LD HL,(LHLCR):INC HL
        LD A,H:CP #40:JR NC,CRASh2
CRASh2B LD (LHLCR),HL
        EXA
        SCF
        RET
;-------
CRASh2  AND %00111111:LD H,A
        LD A,(LHLCR+2):INC A
        LD (LHLCR+2),A
        JP CRASh2B
;---------------------------------------
GENERATE_FILE LD HL,0
              LD (DAHL),HL
              LD (DADE),HL
              LD (LHLCR),HL
              XOR A:LD (LHLCR+2),A
              LD HL,#3FFF,(RHLCR),HL
              LD A,PGM,(RHLCR+2),A
              LD A,13,(EOL_FIRST),A
              XOR A:LD (EOL_SECOND),A:RET
;-------
LOAD    LD A,(F10MENU):OR A:JR NZ,GENERATE_FILE

; Пустой файл не имеет кластерной цепочки. Весь буфер является зазором:
; служебный пробел не нужен и не должен попадать в текст после первого ввода.
        LD HL,(DAHL)
        LD DE,(DADE)
        LD A,L:OR H,E,D:JR Z,GENERATE_FILE

        CALL LOADFL:RET NZ

LOOAD   LD HL,(DAHL)
        LD DE,(DADE)
        CALL LNT3
        LD (SHLA+2),A
        LD (SHLA),HL

        LD A,PGM,(DHLA+2),A
        LD HL,#3FFF,(DHLA),HL

        LD HL,(DAHL)
        LD DE,(DADE)
        CALL LDDRR
        LD A,(DHLA+2),(RHLCR+2),A
        LD HL,(DHLA),(RHLCR),HL

        XOR A:LD (LHLCR+2),A
        LD HL,0,(LHLCR),HL
        XOR A
        RET
;-------
; Полностью прочитать заявленный размер DADE:DAHL, максимум #000FFFFE.
; API читает сектора по 512 байт, поэтому последняя порция округляется вверх.
; IO_REMAIN — оставшиеся секторы; одна страница вмещает максимум 32 сектора.
; Проверяются и статус, и фактическое продвижение HL: ранний EOC не должен
; подставлять старую память вместо недостающих данных. Z=полный успех,
; NZ=ошибка; AF/BC/DE/HL меняются. До успеха LOAD не формирует рабочий текст.
LOADFL  LD HL,(DAHL),DE,(DADE)
        LD A,D:OR A:JP NZ,LOADFL_ERROR
        LD A,E:CP 16:JP NC,LOADFL_ERROR
        CP 15:JR NZ,LOAD_SIZE_VALID
        LD A,H:AND L:CP #FF:JP Z,LOADFL_ERROR
LOAD_SIZE_VALID LD A,D:OR E,H,L:JP Z,LOADFL_OK
        LD BC,511:ADD HL,BC:JR NC,$+3:INC DE
        DUP 9
         SRL D:RR E:RR H:RR L
        EDUP
        LD (IO_REMAIN),HL
        XOR A:LD (APG),A
LFL     LD A,(APG):CALL MNGCVPL
        LD HL,(IO_REMAIN),B,32
        LD A,H:OR A:JR NZ,LOAD_COUNT_READY
        LD A,L:CP 32:JR NC,LOAD_COUNT_READY
        LD B,A
LOAD_COUNT_READY LD A,B,(IO_COUNT),A
        LD HL,#C000:CALL LOAD512
        JR C,LOADFL_ERROR
        PUSH AF:CALL CHECK_TRANSFER:POP BC
        JR NZ,LOADFL_ERROR
        LD A,B:OR A:JR Z,LOAD_STATUS_OK
        CP #0F:JR NZ,LOADFL_ERROR
LOAD_STATUS_OK LD (IO_STATUS),A
        LD A,(IO_COUNT),C,A,B,0
        LD HL,(IO_REMAIN):OR A:SBC HL,BC:LD (IO_REMAIN),HL
        LD A,H:OR L:JR Z,LOADFL_OK
        LD A,(IO_STATUS):OR A:JR NZ,LOADFL_ERROR
        LD HL,APG:INC (HL)
        LD A,(HL):CP PGM+1:JR NC,LOADFL_ERROR
        JR LFL

LOADFL_ERROR LD A,#FF:OR A:RET
LOADFL_OK    XOR A:RET

; LOAD/SAVE512 возвращают HL за фактически обработанными секторами.
; Вход: HL=ответ API, IO_COUNT=запрос 1..32. Выход: Z=объём совпал,
; NZ=короткая/неожиданная передача; AF/BC/DE/HL меняются. Вычитание по модулю
; 65536 учитывает переход #FFFF -> #0000 при полной порции в 16 КиБ.
CHECK_TRANSFER LD A,(IO_COUNT):ADD A,A:LD D,A,E,0
               LD BC,#C000:OR A:SBC HL,BC
               OR A:SBC HL,DE:RET

;---------------------------------------
LDDRR   ;i: [DE,HL] - Lenght
;              SHLA - Source
;              DHLA - Dest

        LD A,L:OR H,E,D:RET Z
        LD (LHLA),HL
        LD (LHLA+2),DE

DDRR    LD A,(LHLA+3):OR A:RET NZ
        LD A,(SHLA+2):CALL MNG0VPL
        LD A,(DHLA+2):CALL MNGCVPL
        LD HL,(SHLA)
        LD DE,(DHLA)
        PUSH HL:OR A:SBC HL,DE
        POP HL:LD BC,HL
        JR C,$+4:LD BC,DE
        INC BC

        PUSH HL,DE
        LD DE,(LHLA+2)
        LD HL,(LHLA)
        OR A:SBC HL,BC:JR NC,$+3:DEC DE
        LD A,D:OR E,H,L:JR NZ,$+4:LD D,1

        LD (LHLA+2),DE
        LD (LHLA),HL
        LD A,D:OR A:JR Z,CRH
        ADD HL,BC:LD BC,HL
CRH     POP DE,HL

        LD A,D:AND %00111111:OR #C0
        LD D,A
        LDDR

        LD A,D
        CP #C0:JR NC,MGN
        EXA
        LD A,(DHLA+2):DEC A
        LD (DHLA+2),A
        EXA
MGN     AND %00111111
        LD D,A

        LD A,H
        CP #40:JR C,MGN2
        AND %00111111
        LD H,A
        LD A,(SHLA+2):DEC A
        LD (SHLA+2),A

MGN2    LD (SHLA),HL
        LD (DHLA),DE
        JP DDRR

;---------------------------------------
ADD_END_OF_FILE LD A,(DHLA+2):CALL MNGCVPL
                LD DE,(DHLA)
                SET 7,D
                SET 6,D
                XOR A:LD (DE),A
                ;LD A,1:OUT (254)
                RET
;-------
LDIRR   ;i: [DE,HL] - Lenght
;           SHLA(3) - Source
;           DHLA(3) - Dest
;        o: DHLA(3) - New Value (where stopped)
;           SHLA(3) - PGM+1 with offset 0

        LD A,L:OR H,E,D:JR Z,ADD_END_OF_FILE
        LD (LHLA),HL
        LD (LHLA+2),DE

DIRR    LD A,(LHLA+3):OR A:RET NZ
        LD A,(SHLA+2):CALL MNG0VPL
        LD A,(DHLA+2):CALL MNGCVPL
        LD HL,(SHLA)
        LD DE,(DHLA)
        SET 7,D
        SET 6,D

UBAL    LDI
        BIT 6,D:JR Z,DDEST
BALLU   BIT 6,H:JP Z,UBAL

DSORC   LD HL,#0000
        LD A,(SHLA+2):INC A
        LD (SHLA+2),A
        CP PGM+1:JR NC,DSE
        CALL MNG0VPL
        JP UBAL
DDEST   LD A,(DHLA+2):INC A
        LD (DHLA+2),A
        CALL MNGCVPL
        LD DE,#C000
        JP BALLU

DSE     LD (SHLA),HL
        XOR A:LD (DE),A
        RES 6,D
        RES 7,D
        LD (DHLA),DE
        RET
;---------------------------------------
SAVECH  LD A,(CHANGES):OR A:RET Z

        PUSH IX
        LD IX,WMWND:CALL PRWOW
        LD HL,ME01,DE,#0100:CALL TXTPR

        LD A,#02:CALL YN
SDM     EI:HALT
        XOR A:CALL YN
        CALL ESC:JR NZ,BACK2EDIT
; Enter проверяем до общего чтения символа: KBSCN(1) забирает событие
; клавиши даже тогда, когда её scan-код не переводится в печатный символ.
        CALL ENKE:JR NZ,SAVECH_ENTER
; WC API 8 обслуживает только стрелки. Раньше N игнорировалась, выбранным
; оставалось YES, и следующий Enter сохранял файл вопреки отказу пользователя.
; Для Y/N берём латинскую таблицу без зависимости от текущей раскладки/Caps.
        LD A,1:CALL KBSCN
        OR #20:CP "n":JR Z,SAVECH_NO
        CP "y":JR Z,SAVECH_YES
        JR SDM
; Считываем решение, пока диалог ещё открыт, и выбираем ветвь до любых
; других вызовов WC. Ветвь NO вообще не вызывает файловые операции.
SAVECH_ENTER LD A,#FF:CALL YN:JR NZ,SAVECH_NO
SAVECH_YES CALL USPO,RRESB
        CALL QSAVE:LD A,(SVERFLG):OR A:JR NZ,BACK2edit
        JR NOCH
SAVECH_NO CALL USPO,RRESB
NOCH    POP IX
        XOR A
        RET

BACK2EDIT CALL RRESB
BACK2edit POP IX
          SCF
          RET
;---------------------------------------
LNT3    ;i: [DE,HL] - File Lenght
;        o:      HL - Offset in Page
;                 A - Page

        LD BC,1
        OR A:SBC HL,BC:JR NC,$+3:DEC DE

        LD A,H
; В исходном ALASM префикс .2 повторял обе команды, а не только SLA A.
        DUP 2
        SLA A:RL E
        EDUP

        LD A,H:AND %00111111
        LD H,A
        LD A,E
        RET
;---------------------------------------
PRTOSV  ;Prepare data to Save
;        i:no
;        o:[DE,HL] - file size

        CALL NORMFL
        LD A,(DHLA+2); A - file size, in pages (0-PGM)
        LD BC,(DHLA); BC - file size offset in last page (0-#3FFF)

YORGE   ;i:ABC - size in pages(A)+offset(BC)
;        o:[DE,HL] - size in bytes

        PUSH BC
        LD HL,0,DE,HL
        OR A:LD BC,#4000:CALL NZ,YOYO
        POP BC
        ADD HL,BC:JR NC,$+3:INC DE
        RET
YOYO    ADD HL,BC:JR NC,$+3:INC DE
        DEC A:JR NZ,YOYO
        RET

;---------------------------------------
TOWORK  ;Prepare data to Work

        CALL DECSRC
        LD HL,(DHLA)
        LD A,(DHLA+2)

        PUSH HL
        LD HL,SHLA
        LD DE,DHLA
        LD BC,3:LDIR
        POP HL

        LD (SHLA),HL
        LD (SHLA+2),A
        CALL DECSRC

        LD HL,(LHLB)
        LD DE,(LHLB+2)
        CALL LDDRR
        RET

DECSRC  LD HL,(SHLA):DEC HL
        LD A,H:CP #40:JR NC,GRDX
GRDXB   LD (SHLA),HL
        RET
GRDX    AND %00111111:LD H,A
        LD A,(SHLA+2):DEC A
        CP PGM+1:RET NC
        LD (SHLA+2),A
        JP GRDXB

;---------------------------------------
NORMFL  ;Preparing data for Save into File

        CALL RCRTD; save right_cursor
        CALL INCRCR; inc(right_cursor)
        JR C,SIZE_OK
        LD HL,#4000,(RHLCR),HL

SIZE_OK LD HL,LHLCR,DE,DHLA,BC,3:LDIR; left cursor to dest
        LD HL,RHLCR,DE,SHLA,C,3:LDIR; right cursor to source

        LD BC,(SHLA+2)
        LD A,PGM:SUB C
        LD BC,(SHLA)
        LD HL,#4000:OR A:SBC HL,BC
        LD BC,HL
        CALL YORGE; ABC->[DE,HL]

        LD (LHLB),HL
        LD (LHLB+2),DE; save block size for restoring
        CALL LDIRR; copy data from SHLA to DHLA, size in [DE,HL]
        CALL DCRTR; restore right_cursor
        RET

RCRTD   LD HL,RHLCR,DE,RHLCR2,BC,3:LDIR:RET; Save RHLCR(3)
DCRTR   LD HL,RHLCR2,DE,RHLCR,BC,3:LDIR:RET; Restore RHLCR(3)
;---------------------------------------
NAMETOH ;Name To Window Header

        LD HL,WHEAD,DE,HL:INC DE
        LD BC,80,(HL),32:LDIR

        LD HL,ENTRYN
        LD DE,WHEAD
        LD B,80-10
NMTHD   LD A,(HL):CP 32:JR C,BAX
        LD (DE),A:INC HL,DE
        DJNZ NMTHD

BAX     PUSH HL
        LD HL,WHEAD
        LD DE,#0006
        LD BC,80-16:CALL PRSRW

        XOR A:LD (HIGHLGT),A
        LD A,1:CALL PRM_PL
        POP HL:RET Z

        DEC A:JR Z,HiLiON
        DEC A:RET Z
;EXT Check (if .asm OR .ini then turn on Syntax HiLi)
        LD BC,5,A,".":CPDR:RET NZ:INC HL,HL        
        LD DE,ASMEXT:PUSH HL:CALL EXTckHL:POP HL
        LD DE,INIEXT
EXTckHL LD B,3
EXT_NEXT LD A,(HL):OR #20
         LD C,A,A,(DE):CP C:RET NZ
         INC HL,DE:DJNZ EXT_NEXT
HiLiON  LD A,1,(HIGHLGT),A
        RET

OFFSETS_PRINT LD A,(CHANGES):OR A:LD A," ":JR Z,OFFSET_SYMBOL
              LD A,"*"
OFFSET_SYMBOL LD HL,TAPTCHA:CP (HL):JR Z,OFFSETS_PRI
              LD (HL),A,DE,#0005,BC,1:CALL PRSRW

OFFSETS_PRI   LD HL,LHLOFF,A,(LHLCR+2):CALL NORK
                        LD A,(LHLCR+1):CALL NORK
                        LD A,(LHLCR+0):CALL NORK
              LD HL,BHLOFF,A,(BHLBLK+2):CALL NORK
                        LD A,(BHLBLK+1):CALL NORK
                        LD A,(BHLBLK+0):CALL NORK
              LD HL,EHLOFF,A,(EHLBLK+2):CALL NORK
                        LD A,(EHLBLK+1):CALL NORK
                        LD A,(EHLBLK+0):CALL NORK
              LD HL,OFFSETS,D,(IX+5),E,#39,BC,OFFSETSEND-OFFSETS:DEC D:JP PRSRW
;---------------------------------------
INSPECTOR PUSH IX
          LD IX,CALCWND:CALL PRWOW

          EXX:LD HL,CALCBUFL:EXX
          LD HL,CALCBUF,DE,#0101,BC,#1800,A,#FD:CALL ISTR
INSPMAIN  EI:HALT
          CALL ENKE:JR NZ,INSPCALC
          CALL TABK:JR NZ,INSP_EXIT
          CALL ESC:JR NZ,INSP_EXIT

          XOR A:CALL ISTR
          LD A,2:CALL ISTR
          PUSH IX:LD IX,PLWND:CALL EDITOR_STATUS
          POP IX
          JR INSPMAIN          

INSP_EXIT CALL RRESB
          POP IX
          LD A,1:OR A
          RET

; Inspector обязан проверять CF до форматирования BC. При ошибке выводим
; причину и прочерки во всех числовых полях; успешный расчёт очищает причину.
INSPCALC  LD HL,CALCBUF,DE,BUF3:CALL CALC_BUF_CONV
          LD BC,0
          LD DE,BUF3,A,(DE):OR A:CALL NZ,DECODER
          JR C,INSP_ERROR
          PUSH BC
          LD HL,CALSTATUS,B,24,A," ":CALL FILL_FIELD
          POP BC

          LD HL,CALHEX
          LD A,B:PUSH BC:CALL NORK:POP BC
          LD A,C:PUSH BC:CALL NORK:POP HL

          EXX:LD DE,CALDEC:EXX
          LD DE,0:PUSH HL:CALL DECZON2:POP DE

          LD HL,CALBIN
          LD A,D:CALL BINZON
          INC HL
          LD A,E:CALL BINZON

          CALL INSP_REFRESH
          JP INSPMAIN
INSP_ERROR CP 26:LD HL,CALC_BAD_TEXT:JR NZ,INSP_ERROR_TEXT
           LD HL,CALC_ZERO_TEXT
INSP_ERROR_TEXT LD DE,CALSTATUS,BC,24:LDIR
           LD HL,CALDEC,B,5,A,"-":CALL FILL_FIELD
           LD HL,CALHEX,B,4:CALL FILL_FIELD
           LD HL,CALBIN,B,17:CALL FILL_FIELD
           LD A," ",(CALBIN+8),A
           CALL INSP_REFRESH:JP INSPMAIN
; A=заполнитель, HL=поле, B=длина 1..255. HL продвигается за поле, A сохранён.
FILL_FIELD LD (HL),A:INC HL:DJNZ FILL_FIELD:RET
;---------
; HL=поле ввода из 40 байт, DE=буфер минимум 41 байт. Удаляются только
; пробелы ВНЕ кавычек. Старое завершение на первом пробеле превращало 1 / 2
; в 1. C хранит состояние кавычек; выход всегда ограничен и завершён нулём.
CALC_BUF_CONV LD B,CALCBUFL,C,0
BUF_CONV      LD A,(HL):INC HL
              CP #22:JR NZ,BUF_QUOTE_READY
              LD A,C:XOR 1:LD C,A,A,#22
BUF_QUOTE_READY CP " ":JR NZ,BUF_KEEP
              LD A,C:OR A:JR Z,BUF_NEXT
              LD A," "
BUF_KEEP      LD (DE),A:INC DE
BUF_NEXT      DJNZ BUF_CONV
END_CONV      XOR A:LD (DE),A
              RET
;---------
INSP_REFRESH LD HL,CALCA,DE,#0101:JP TXTPR
;---------------------------------------
BINZON  LD B,8
BINBIN  RLA:LD C,"1":JR C,BINU:DEC C
BINU    LD (HL),C:INC HL:DJNZ BINBIN
        RET
;---------------------------------------
DELIT4P PUSH IX
        LD IX,0-1
NAZE    OR A
PBSTH   LD BC,0:INC IX
        EX DE,HL:SBC HL,BC:JR C,ND
PBSTL   LD BC,0
        EX DE,HL:SBC HL,BC:JR NC,PBSTH
        DEC DE
        LD A,D:INC A:JR NZ,NAZE
        LD A,E:INC A:JR NZ,NAZE
        INC DE

        ADD HL,BC
        EX DE,HL
        LD BC,(PBSTH+1)
ND      ADD HL,BC
        EX DE,HL
        PUSH IX
        POP BC
        LD A,C:ADD A,#30
        POP IX
        RET
;-------
DECZON2 ;i: HL,Number
;          DE',TXT Address to decode

        LD BC,10000,(PBSTL+1),BC
        LD BC,0,(PBSTH+1),BC
        CALL DELIT4P
        PUSH HL
        EXX:LD (DE),A:INC DE
        POP HL
DECZ2   LD BC,1000
        CALL DELIT
        LD (DE),A:INC DE
DECZ1   LD BC,100
        CALL DELIT
        LD (DE),A:INC DE
DECZ    LD C,10
        CALL DELIT
        LD (DE),A:INC DE
        LD C,1
        CALL DELIT
        LD (DE),A:INC DE
        RET
;-------
DELIT   LD A,#FF
        OR A
DLIT    INC A
        SBC HL,BC:JP NC,DLIT
        ADD HL,BC,A,#30
        RET
;---------------------------------------
        INCLUDE "CALCULATOR.INC"
;---------------------------------------
SEARCHNEXT JR GOsrh7

SEARCH  PUSH IX
        LD IX,SRHWND:CALL PRWOW

        LD C,0
        CALL STRBULL:JR Z,SRHZERO
        INC DE:LD C,E
SRHZERO EXX:LD HL,STRBUFFL:EXX
        LD HL,STRBUFF,DE,#0101,B,#28,A,#FD:CALL ISTR
SRHMAIN EI:HALT
        PUSH IX:LD IX,PLWND:CALL EDITOR_STATUS
        POP IX
        CALL ENKE:JR NZ,GOSRH7
        CALL ESC:JR NZ,SRHEXIT

        XOR A:CALL ISTR
        LD A,2:CALL ISTR
        JR SRHMAIN

SRHEXIT CALL RRESB
        POP IX
        XOR A
        RET

GOSRH7  CALL RRESB:POP IX
GOsrh7  CALL STRBULL:RET Z
        CALL PRTOBACK
        CALL GOSRH:JR NC,COMEBACK

        CALL MEASURE_CURSOR
        LD HL,LINESTART,DE,PGHLP,BC,3:LDIR
        LD A,(IX+5):SUB LNZ+1+LNZ2:SRL A
        LD B,A
SRHGE   PUSH BC:CALL PGMUZ
        POP BC:JR NC,SRHge
        DJNZ SRHGE
SRHge   CALL REFRESH,SYNC_COLUMN
SRHET   CALL REFRESH
        XOR A
        RET

COMEBACK PUSH IX
         LD IX,NFNDWND:CALL PRWOW

; GOSRH уже перенёс весь хвост влево. Обратное копирование начинает с его
; ФАКТИЧЕСКОГО конца; старые координаты курсора задают лишь итоговый зазор.
; Прежний код подставлял старый конец и запрашивал страницу #FF. WC отказывал
; в подключении, но копирование продолжалось в прежнюю страницу и портило файл.
         LD HL,LHLCR,DE,DHLA,BC,3:LDIR
         LD HL,0,(SHLA),HL
         LD A,PGM+1,(SHLA+2),A
         LD HL,SEARCH_OLD_L,DE,LHLCR,BC,3:LDIR
         LD HL,RHLCR2,DE,RHLCR,C,3:LDIR
         CALL TOWORK

         CALL USPO
         CALL NUSP
         CALL RRESB
         POP IX
         JR SRHET
PRTOBACK PUSH DE
         LD HL,LHLCR,DE,SEARCH_OLD_L,BC,3:LDIR
         CALL RCRTD
         CALL INCRCR
         JR C,SEARCH_SIZE_OK
         LD HL,#4000,(RHLCR),HL
SEARCH_SIZE_OK
         LD HL,LHLCR,DE,DHLA,BC,3:LDIR
         LD HL,RHLCR,DE,SHLA,C,3:LDIR

         LD BC,(SHLA+2)
         LD A,PGM:SUB C
         LD BC,(SHLA)
         LD HL,#4000:OR A:SBC HL,BC
         LD BC,HL
         CALL YORGE
         LD (LHLB),HL
         LD (LHLB+2),DE
         CALL DCRTR
         POP DE
         RET
;-------
SRHDZT    LD DE,#3FFF:JP SRHZZT
SRHFAST   LD A,(RHLCR+2):INC A
          CP PGM+1:JR NC,SRHDZT
          LD (RHLCR+2),A
          PUSH BC:CALL MNGCVPL
          POP BC
          SET 7,D
          SET 6,D
          JP SRHFASTB
;-------
GOSRH     INC DE:LD A,E,(PATLEN),A
          LD HL,STRBUFF:ADD HL,DE:LD (HL),0,(STRBUFA),HL
          CALL SEARCH_PREFIXES

          LD A,(LHLCR+2):CALL MNG0VPL
          LD A,(RHLCR+2):CALL MNGCVPL
          LD BC,(LHLCR)
          LD DE,(RHLCR)
          SET 7,D
          SET 6,D
SRHFRST   LD HL,STRBUFF
SRH13DD   LD A,(HL):OR A:JR Z,SRHFOUND
          INC DE:BIT 7,D:JR Z,SRHFAST
SRHFASTB  LD A,(DE),(BC),A
SRH_COMPARE CP (HL):JR Z,SRHNXT
          PUSH AF,BC,DE
          LD A,L:SUB low STRBUFF:JR Z,SRH_NO_PREFIX
          LD L,A,H,0,DE,KMPFAIL:ADD HL,DE
          LD L,(HL),H,0,DE,STRBUFF:ADD HL,DE
          POP DE,BC,AF
          JP SRH_COMPARE
SRH_NO_PREFIX LD HL,STRBUFF
          POP DE,BC,AF
SRHNXTB   INC BC:BIT 6,B:JR NZ,SRHFAST2
SRHFAST2B JP SRH13DD; EOF — физический конец буфера; NUL внутри файла является данными.
SRHNXT    INC HL:JP SRHNXTB
SRHFOUND  SCF
SRHZZT    LD HL,(STRBUFA),(HL)," "
          LD (LHLCR),BC
          RES 7,D
          RES 6,D
          LD (RHLCR),DE
          RET
;-------
SRHFAST2  PUSH AF
          LD A,B:AND %00111111:LD B,A
          LD A,(LHLCR+2):INC A
          LD (LHLCR+2),A
          PUSH BC:CALL MNG0VPL
          POP BC
          POP AF
          JP SRHFAST2B
;-------
STRBULL LD DE,STRBUFFL-1
        LD HL,STRBUFF+STRBUFFL-1
        LD B,STRBUFFL
STRSTRS LD A,(HL):CP " ":RET NZ
        DEC HL,DE:DJNZ STRSTRS
STRSTR  XOR A
        RET

; Для каждого префикса образца сохраняем длину его наибольшей собственной
; границы: начала, совпадающего с концом. При несовпадении GOSRH использует
; эту таблицу и повторно проверяет тот же байт; поэтому ab находится в aab.
; PATLEN=1..40, STRBUFF=образец; выход KMPFAIL[0..PATLEN], AF/BC/DE/HL меняются.
; Текстовые страницы не затрагиваются. Маленький предел позволяет простой
; полный перебор границ без сложного дополнительного состояния.
SEARCH_PREFIXES LD HL,KMPFAIL,(HL),0
                LD A,1,(PF_LEN),A
PREFIX_LENGTH   LD A,(PF_LEN):DEC A:LD (PF_CAND),A
PREFIX_TRY      LD A,(PF_CAND):OR A:JR Z,PREFIX_STORE
                LD B,A,A,(PF_LEN):SUB B
                LD L,A,H,0,DE,STRBUFF:ADD HL,DE
PREFIX_COMPARE  LD A,(DE):CP (HL):JR NZ,PREFIX_SHORTER
                INC HL,DE:DJNZ PREFIX_COMPARE
                JR PREFIX_STORE
PREFIX_SHORTER  LD HL,PF_CAND:DEC (HL):JR PREFIX_TRY
PREFIX_STORE    LD A,(PF_LEN),C,A,B,0,HL,KMPFAIL:ADD HL,BC
                LD A,(PF_CAND),(HL),A
                LD HL,PF_LEN:INC (HL):LD B,(HL)
                LD A,(PATLEN):CP B:JR NC,PREFIX_LENGTH
                RET
;---------------------------------------
; Строка состояния основного окна, включая вызовы из Search/Inspector/Save As.
; Вход: IX=PLWND; AF/BC/DE/HL меняются, IX сохраняется. LANG читается из
; фиксированного блока WC, описанного в PS2P.ASM. Повторно вызывать ISTR(#FC)
; здесь нельзя: строковый редактор уже обработал Insert и Ctrl+Shift, и второй
; вызов мог бы ещё раз переключить режим по тому же нажатию.
EDITOR_STATUS LD A,(WC_LANG):AND 1:LD B,A
              LD A,(HELP_HINT_LANG):CP B:JR Z,EDITOR_STATUS_MODE
              LD A,B,(HELP_HINT_LANG),A
              LD HL,HELP_HINT_EN:OR A:JR Z,EDITOR_STATUS_HINT
              LD HL,HELP_HINT_RU
; Обе подписи занимают ровно 24 клетки с пробелами в конце. Поэтому переход
; RUS -> ENG стирает длинный русский хвост и не задевает индикатор ENG/INS.
; Рисуем только при смене раскладки, чтобы не добавлять перерисовку на стрелки.
EDITOR_STATUS_HINT LD A,(IX+5):DEC A:LD D,A,E,0:CALL TXTPR
EDITOR_STATUS_MODE LD A,#03:JP ISTR
;---------------------------------------
F1MENU  PUSH IX
; Заголовок, нижняя подсказка и весь текст справки выбираются по одной
; текущей раскладке при каждом F1. Всегда копируем все три указателя,
; в том числе при возврате RUS -> ENG: язык прошлой страницы не запоминается.
; IX вызывающего окна сохраняется; AF/BC/DE/HL используются как рабочие.
        LD HL,F1_TEXT_EN
        LD A,(WC_LANG):AND 1:JR Z,F1_SELECT_TEXT
        LD HL,F1_TEXT_RU
F1_SELECT_TEXT LD DE,F1WND_TEXT,BC,6:LDIR
        LD IX,F1WND:CALL PRWOW
        CALL USPO
        CALL NUSP
        CALL RRESB
        POP IX
        RET
;---------------------------------------
HIGHLIGHT_SWITCH LD A,(HIGHLGT):XOR 1:LD (HIGHLGT),A:JP PAGE
;---------------------------------------
COPY    LD A,(MARKED):OR A:JR Z,NOCOPY
        CALL COPYX:LD A,D:OR E:JP Z,CLIPBOARD_ERROR
NOCOPY  CALL REFRESH
        XOR A
        RET

COPYX   CALL COPY_SIZE:RET NC
        LD A,1:CALL MNGC_PL
        LD HL,BHLBLK,DE,LNTMP,BC,3:LDIR

        LD A,(LNTMP+2):CALL MNG0VPL
        LD HL,(LNTMP)
        LD DE,#C000

COPYPG  LD A,(EHLBLK+2)
        LD BC,(LNTMP+2)
        CP C:JR Z,COPYBTE,NC,COPYbte,COPYERR
COPYBTE LD A,(EHLBLK+1)
        CP H:JR Z,COPYCHE,C,COPYERR
COPYbte LDI
        LD A,D:CP #C0:JR C,COPY_FULL_END
        LD A,H:CP #40:JR NC,COPYINCPG
        JP COPYPG

COPYCHE LD A,(EHLBLK)
        CP L:JR Z,COPYEND,NC,COPYbte
COPYERR LD DE,0:RET; При отказе сохраняем старые байты и длину clipboard.
COPY_FULL_END LD DE,#4000
COPYend LD (CLIPSZ),DE
        RET
COPYEND LD A,D:AND %00111111:LD D,A
        JR COPYend

COPYINCPG LD A,H:AND %00111111:LD H,A
          LD A,(LNTMP+2):INC A
          LD (LNTMP+2),A
          PUSH HL,DE:CALL MNG0VPL
          POP DE,HL
           JP COPYPG

; Проверить размер выделения ДО записи в clipboard. Вход: BHLBLK/EHLBLK.
; C=допустимо, DE=1..#4000; NC=отказ, DE=0. AF/BC/DE/HL меняются.
; Ровно 16 КиБ разрешены; больше 16 КиБ не повреждают предыдущее копирование.
COPY_SIZE LD A,(BHLBLK+2),C,A
          LD A,(EHLBLK+2):SUB C:JR C,COPY_SIZE_BAD
          CP 2:JR NC,COPY_SIZE_BAD
          LD HL,(EHLBLK),DE,(BHLBLK)
          OR A:JR Z,COPY_SIZE_SUB
          LD BC,#4000:ADD HL,BC
COPY_SIZE_SUB OR A:SBC HL,DE:JR C,COPY_SIZE_BAD
          LD A,H:OR L:JR Z,COPY_SIZE_BAD
          LD A,H:CP #40:JR C,COPY_SIZE_OK,NZ,COPY_SIZE_BAD
          LD A,L:OR A:JR NZ,COPY_SIZE_BAD
COPY_SIZE_OK LD DE,HL:SCF:RET
COPY_SIZE_BAD LD DE,0:XOR A:RET

; BC=полная длина вставки (1..#4000). C=вся замена помещается, NC=отказ;
; AF/DE/HL меняются, BC сохраняется. Выделение учитывается как свободное место,
; но не удаляется до успешной проверки. Новый левый указатель строго меньше
; RHLCR: два служебных байта зазора остаются зарезервированы даже на EOF.
EDIT_ROOM LD HL,(LHLCR),A,(LHLCR+2),D,A
          LD A,(MARKED):OR A:JR Z,ROOM_ADD
          LD HL,(BHLBLK),A,(BHLBLK+2),D,A
ROOM_ADD  ADD HL,BC
          BIT 6,H:JR Z,ROOM_PAGE
          RES 6,H:INC D
ROOM_PAGE LD A,(RHLCR+2):CP D:JR C,ROOM_FULL,Z,ROOM_OFFSET
          SCF:RET
ROOM_OFFSET LD DE,(RHLCR):OR A:SBC HL,DE:RET
ROOM_FULL OR A:RET
;---------------------------------------
CUT     LD A,(MARKED):OR A:RET Z
        CALL COPYX:LD A,D:OR E:JR Z,CLIPBOARD_ERROR
        CALL MARK_KILL
        JP Bspc

CLIPBOARD_ERROR LD HL,MSG_CLIPBOARD:JR EDIT_ERROR
BUFFER_FULL    LD HL,MSG_BUFFER_FULL
EDIT_ERROR      PUSH IX,HL
                LD IX,ERWND:CALL PRWOW
                POP HL:LD DE,#0100:CALL TXTPR
                CALL USPO,NUSP
                CALL RRESB
                POP IX
                XOR A
                RET
;---------------------------------------
PASTE   LD HL,(CLIPSZ),A,H:OR L:RET Z
        LD BC,HL:CALL EDIT_ROOM:JP NC,BUFFER_FULL
        CALL MARK_KILL

        LD A,1:CALL MNGC_PL
        LD HL,#C000,BC,(CLIPSZ)

PASTEBT LD A,(HL):INC HL
        PUSH HL,BC:CALL INCLCR
        POP BC,HL:JR NC,PASTERR
        DEC BC:LD A,B:OR C:JR NZ,PASTEBT

PASTERR
PASTEND CALL REFRESH
        LD A,(CRFLG):OR A:CALL Z,PASTEGG
        CALL SYNC_COLUMN
        CALL CHA
        XOR A
        RET

PASTEGG  LD HL,LHLCR,DE,PGHLP,BC,3:LDIR

         LD A,(IX+5):SUB LNZ+1+LNZ2
         LD B,A
GPASTEPG PUSH BC:CALL PGMUZ
         POP BC:JR NC,GPAGG
         DJNZ GPASTEPG
GPAGG    JP REFRESH
;---------------------------------------
QSAVE   LD A,(F10MENU):OR A:JP NZ,SAVEAS

        PUSH IX
        LD IX,SVWND:CALL PRWOW

        CALL PRTOSV
        LD (DAHL),HL
        LD (DADE),DE

; Сначала полностью записываем новый файл под свободным служебным именем.
; Исходный файл до успешного завершения SAVE512 не изменяется.
        CALL FILE_SIZE_COPY
        CALL SAFE_STORE:JR NZ,MKER

        LD A,3,(ESTA),A
        XOR A:LD (CHANGES),A,(SVERFLG),A
BTZF    CALL TOWORK
        CALL RRESB
QSAVE_EXIT
        POP IX
        CALL REFRESH_EDITOR
        XOR A
        RET
;-------
MKER    LD (SVERFLG),A

; Окно "Saving..." закрываем до окна ошибки, чтобы у каждого диалога был
; отдельный законченный цикл PRWOW/RRESB.
        CALL TOWORK
        CALL RRESB
        PUSH IX
        LD IX,ERWND:CALL PRWOW
        LD HL,MSG_SAVE_ERROR,DE,#0100:CALL TXTPR
        CALL USPO,NUSP
        CALL RRESB
        POP IX
        JR QSAVE_EXIT
;---------------------------------------
SAVEAS  PUSH IX
; При ошибке Save As редактор должен продолжать работать со старым именем.
        LD HL,ENTRYN,DE,SAVEAS_OLD_NAME,BC,256:LDIR
        LD IX,SAVEASWND:CALL PRWOW

; Input File Name
        CALL SAVEASI:JR NZ,SASABRT

        CALL PRTOSV
        LD (DAHL),HL
        LD (DADE),DE

        CALL FILE_SIZE_COPY
        LD HL,FLMAKE,(HL),#00
        CALL MKFILE:JR NZ,MKER2
        LD A,3,(ESTA),A
        CALL SAVEDAT:JR Z,SAVEAS_WRITTEN

; MKFILE уже создал новое имя, но данные записались не полностью. Такой файл
; нельзя оставлять пользователю как будто это успешный Save As.
        CALL DROP_ACTIVE_SAVEAS:JR MKER2

SAVEAS_WRITTEN
        LD A,3,(ESTA),A
        XOR A:LD (CHANGES),A,(F10MENU),A,(SVERFLG),A
BTZF2   CALL TOWORK
SASEXIT CALL RRESB
SAVEAS_FINISH
        POP IX

; После успешного Save As обновляем имя и режим подсветки в заголовке окна.
        LD A,(SVERFLG):OR A:CALL Z,NAMETOH
        CALL REFRESH_EDITOR
        XOR A
        RET
;-------
SASABRT LD A,SASAEC,(SVERFLG),A:JR SASEXIT
MKER2   PUSH AF
        LD HL,SAVEAS_OLD_NAME,DE,ENTRYN,BC,256:LDIR
        POP AF:LD (SVERFLG),A

; Сначала закрываем окно Save As, затем показываем ошибку отдельным циклом.
        CALL TOWORK
        CALL RRESB
        PUSH IX
        LD IX,ERWND:CALL PRWOW
        LD HL,MSG_SAVE_ERROR,DE,#0100:CALL TXTPR
        CALL USPO,NUSP
        CALL RRESB
        POP IX
        JR SAVEAS_FINISH
;-------
; QSAVE может быть вызван из диалога выхода, где IX указывает на WMWND.
; REFRESH с этим IX рисовал строки редактора внутри координат диалога и оставлял
; на экране прямоугольный мусор. Для полной перерисовки всегда нужен PLWND.
REFRESH_EDITOR PUSH IX
               LD IX,PLWND:CALL REFRESH
               POP IX
               RET
;-------
SAVEASI CALL ENTRY_TO_STRING

        EXX:LD HL,SASBUFL:EXX
        LD HL,SASBUF,DE,#0101,BC,#1400,A,#FD:CALL ISTR
ASMAIN  EI:HALT
        CALL ENKE:JR NZ,STRING_TO_ENTRY
        CALL ESC:RET NZ

        XOR A:CALL ISTR
        LD A,2:CALL ISTR
        PUSH IX:LD IX,PLWND:CALL EDITOR_STATUS
        POP IX
        JR ASMAIN
;-------
STRING_TO_ENTRY LD HL,SASBUF+SASBUFL
                LD B,SASBUFL
STE             DEC HL:LD A,(HL):CP " ":JR NZ,STE2
                DJNZ STE
; Пустая строка раньше запускала LDIR с BC=0, то есть копирование 65536 байт.
                LD A,1:OR A:RET
STE2            LD HL,SASBUF
                LD DE,ENTRYN
                LD C,B,B,0:LDIR
                LD A,C,(DE),A
                XOR A
                RET
;-------
ENTRY_TO_STRING LD HL,ENTRYN
                LD DE,SASBUF
                LD B,SASBUFL
ETS             LD A,(HL):CP 32:JR C,ETSFILL
                LD (DE),A:INC HL,DE
                DJNZ ETS
                RET
ETSFILL         LD A," "
                LD (DE),A:INC DE:DJNZ $-2
                RET
;---------------------------------------
; Возврат: Z — записаны ровно ceil(file_size/512) секторов, NZ — ошибка.
; SAVE512 ограничен физическим концом FAT-цепочки, а не логическим размером.
; Прежний B=32 поэтому записывал до 16 КиБ кластерного хвоста даже для wc.ini.
; DAHL/DADE после FILE_SIZE_COPY больше не нужны как размер и служат счётчиком.
SAVEDAT LD HL,(FLMAKE+1),DE,(FLMAKE+3)
        LD A,D:OR E,H,L:RET Z; MKFILE уже создал пустой файл, писать нечего.
        LD BC,511:ADD HL,BC:JR NC,$+3:INC DE
        DUP 9
         SRL D:RR E:RR H:RR L
        EDUP
        LD A,D:OR E:JR NZ,SAVEDAT_ERROR
        LD A,H:OR L:JR Z,SAVEDAT_ERROR
        LD (DAHL),HL

        LD A,PGZ,(SVD+1),A
SVD     LD A,0
        CALL MNGCVPL
        LD HL,SVD+1:INC (HL)

        LD HL,(DAHL),B,32
        LD A,H:OR A:JR NZ,SAVEDAT_COUNT_READY
        LD A,L:CP 32:JR NC,SAVEDAT_COUNT_READY
        LD B,A
SAVEDAT_COUNT_READY
        LD A,B:LD (DADE),A,(IO_COUNT),A
        LD HL,#C000:CALL SAVE512
        JR C,SAVEDAT_ERROR
        PUSH AF:CALL CHECK_TRANSFER:POP BC
        JR NZ,SAVEDAT_ERROR
        LD A,B
        OR A:JR Z,SAVEDAT_STATUS_OK
        CP #0F:JR NZ,SAVEDAT_ERROR
SAVEDAT_STATUS_OK
        LD (DADE+1),A
        LD A,(DADE):LD C,A,B,0
        LD HL,(DAHL):OR A:SBC HL,BC:LD (DAHL),HL
        LD A,H:OR L:JR Z,SAVEDAT_OK
        LD A,(DADE+1):OR A:JR NZ,SAVEDAT_ERROR
        JP SVD
SAVEDAT_ERROR LD A,#FF:OR A:RET
SAVEDAT_OK    XOR A:RET
;---------------------------------------
FILE_SIZE_COPY LD HL,(DAHL)
               LD DE,(DADE)
SIZE_NOT_ZERO  LD (FLMAKE+1+0),HL
               LD (FLMAKE+1+2),DE
               RET
;---------------------------------------
; Удалить недописанный файл Save As. ENTRYN пока содержит введённое новое имя.
; Возвращаем NZ независимо от результата DELFL: операция сохранения не удалась.
DROP_ACTIVE_SAVEAS
        LD HL,FLLOAD,(HL),#00
        CALL DELFL
        LD A,#FF:OR A:RET
;---------------------------------------
; Реальная SD-ZC зависает внутри FILEX MOVE_RENAME даже после холодной
; перезагрузки EVO. Используем проверенную транзакционную замену через
; RENAME/rollback. MKFILE также не выполняет дополнительную запись FSInfo.
; Возврат: Z — новое содержимое опубликовано; NZ — сохранение не завершено.
SAFE_STORE
        LD HL,FLMAKE+1,DE,TMPMAKE+1,BC,4:LDIR
        JP SAFE_STORE_LEGACY

SAFE_STORE_LEGACY
        CALL SAFE_NAMES:RET NZ

        LD HL,TMPMAKE:CALL MKFILE:RET NZ
        LD A,3,(ESTA),A
        CALL SAVEDAT:JR Z,SAFE_STORE_WRITTEN

; При ошибке SAVE512 временный файл содержит недописанные либо старые сектора,
; поэтому не выдаём его за recovery-копию и пытаемся убрать из каталога.
        LD HL,TMPQUERY:CALL DELFL
        LD A,1:OR A:RET

; Фиксация: старую цепочку оставляем под резервным именем, затем публикуем
; записанную временную копию под исходным именем.
SAFE_STORE_WRITTEN
        LD HL,FLLOAD,(HL),#00
        LD DE,BAKQUERY_NAME
        CALL RENAM:JR Z,SAFE_STORE_ERROR

        LD HL,TMPQUERY
        LD DE,ENTRYN
        CALL RENAM:JR NZ,SAFE_STORE_DONE

; Если второе переименование не удалось, возвращаем старому файлу его имя.
; Даже при неудаче отката обе цепочки остаются в каталоге под служебными именами.
        LD HL,BAKQUERY
        LD DE,ENTRYN
        CALL RENAM
SAFE_STORE_ERROR LD A,1:OR A:RET

SAFE_STORE_DONE
; Новое содержимое уже доступно под исходным именем. Ошибка удаления резервной
; копии не угрожает данным: файл WCEBAK?.$$$ останется для восстановления.
        LD HL,BAKQUERY:CALL DELFL
        XOR A:RET
;---------------------------------------
; Выбираем пару свободных имён WCETMP0.$$$/WCEBAK0.$$$ ... 9.
; Существующие служебные файлы никогда не удаляются: это могут быть данные
; после прежнего аварийного сохранения.
SAFE_NAMES LD A,"0"
SAFE_NAMES_LOOP
        LD (SAFE_SLOT),A
        LD (TMPMAKE_DIGIT),A
        LD (TMPQUERY_DIGIT),A
        LD (BAKQUERY_DIGIT),A

        LD HL,TMPQUERY:CALL FENTRY:JR NZ,SAFE_NAMES_NEXT
        LD HL,BAKQUERY:CALL FENTRY:JR NZ,SAFE_NAMES_NEXT
        XOR A:RET

SAFE_NAMES_NEXT
        LD A,(SAFE_SLOT):INC A:CP ":":JR C,SAFE_NAMES_LOOP
        LD A,1:OR A:RET
;---------------------------------------
PRM_PL  EXA:LD A,83:JP WLD

MNGC_PL EXA:LD A,0:JP WLD
MNG0_PL EXA:LD A,78:JP WLD
MNG8_PL EXA:LD A,79:JP WLD
PRWOW   LD A,1:JP WLD
RRESB   LD A,2:JP WLD
PRSRW   LD A,3:JP WLD
PRIAT   EXA:LD A,4:JP WLD
GADRW   LD A,5:JP WLD
CURSOR  LD A,6:JP WLD
CURSER  LD A,7:JP WLD
YN      EXA:LD A,8:JP WLD
ISTR    EXA:LD A,9:JP WLD

NORK    EXA:LD A,10:JP WLD
TXTPR   LD A,11:JP WLD
MEZZ    EXA:LD A,12:JP WLD
DMAPL   EXA:LD A,13:JP WLD
GEDPL   LD A,15:JP WLD
;-------
KBSCN   EXA:LD A,42:JP WLD

SPKE    LD A,16:JP WLD
UPPP    LD A,17:JP WLD
DWWW    LD A,18:JP WLD
LFFF    LD A,19:JP WLD
RGGG    LD A,20:JP WLD
TABK    LD A,21:JP WLD
ENKE    LD A,22:JP WLD
BSPC    LD A,24:JP WLD
PGUP    LD A,25:JP WLD
PGDN    LD A,26:JP WLD
DEL     LD A,43:JP WLD
ESC     LD A,23:JP WLD
HOME    LD A,27:JP WLD
END     LD A,28:JP WLD
F1      LD A,29:JP WLD
F2      LD A,30:JP WLD
F3      LD A,31:JP WLD
F5      LD A,33:JP WLD
F10     LD A,38:JP WLD
ALT     LD A,39:JP WLD
SHIFT   LD A,40:JP WLD
CTRL    LD A,41:JP WLD
USPO    LD A,46:JP WLD
NUSP    LD A,47:JP WLD
;-------
LOAD512 LD A,48:JP WLD
LOAD256 LD A,60:JP WLD
LOADNON LD A,61:JP WLD

SAVE512 LD A,49:JP WLD
FENTRY  LD A,59:JP WLD
GFILE   LD A,62:JP WLD
MKFILE  LD A,72:JP WLD
RENAM   LD A,74:JP WLD
DELFL   LD A,75:JP WLD
;-------
MNGV_PL EXA:LD A,64:JP WLD
MNGCVPL EXA:LD A,65:JP WLD
MNG0VPL EXA:LD A,80:JP WLD
GVmod   EXA:LD A,66:JP WLD
GYoff   LD A,67:JP WLD
GXoff   LD A,68:JP WLD
;---------------------------------------
;COLORING CONSTANTS(F2 mode):

OPLEN        EQU OPERATORcol-OPERATORS
SEPLEN       EQU SEPARATORcol-SEPARATORS

OPERATORS    DB "(){}<>=+-*/\\[]"
OPERATORcol  DS 14,HLCCOL ;OPCOL

SEPARATORS   DB ".,: "
SEPARATORcol DS 3,HLACOL:DB DFCOL ;SEPCOL

PREVCHAR     NOP
;---------------------------------------
PLWND   DB 5+16,0
        DB 0,0;      X,Y
        DB 0,0;      W,H
        DB %00010111;PAPER+INK
        DB 0
        DW #0; BUFFER
        DB 0,0;LINES

        DB 1,5;        CURnow,CURmax
        DB %11110001,0;CURcolor

        DW TAPT
        DW TAPB
        DW 0
;-------
TAPT    DB #8,#1
        DB "File:"
TAPTCHA DB " ",0

TAPB    DB #8,#1
        DB " F1 - Help page                         "
        DB "                                        "
        DB "          "
        DB 0

HELP_HINT_LANG DB #FF
HELP_HINT_EN DB #8,#1," F1 - Help page         ",0
; «Страница помощи» в однобайтовой экранной кодировке CP866, а не в UTF-8.
HELP_HINT_RU DB #8,#1," F1 - ",#91,#E2,#E0,#A0,#AD,#A8,#E6,#A0
             DB " ",#AF,#AE,#AC,#AE,#E9,#A8,"   ",0

OFFSETS DB "#"
LHLOFF  DB "000000 #"
BHLOFF  DB "000000/#"
EHLOFF  DB "000000"
OFFSETSEND
;-------
SAVEASWND DB 4+16+128,0
          DB 255,255;  X,Y
          DB 20+2,1+2; W,H
          DB %01111111;PAPER+INK
          DB 0
          DW #0; BUFFER
          DB 0,0;LINES

          DW SAVEAST
          DW 0
          DW 0
SAVEAST   DB #9,#E,"Save as...",0
;-------
SVWND   DB 4+16+128,0
        DB 255,255;  X,Y
        DB 20+2,1+2; W,H
        DB %01111111;PAPER+INK
        DB 0
        DW #0; BUFFER
        DB 0,0;LINES

        DW 0
        DW 0
        DW SAVINGM
SAVINGM DB #E,"Saving...",0
;-------
WMWND   DB 4+16+128,0
        DB 255,255;  X,Y
        DB 40+2,4+2; W,H
        DB %01111111;PAPER+INK
        DB 0
        DW #0; BUFFER
        DB 2,0;LINES

        DW WARNING
        DW 0
        DW 0
WARNING DB #9,#E,"WARNING!",0
;-------
ERWND   DB 4+16+128,0
        DB 255,255;  X,Y
        DB 40+2,2+2; W,H
        DB %00101111;PAPER+INK
        DB 0
        DW #0; BUFFER
        DB 0,0;LINES

        DW ERT
        DW ERB
        DW 0
ERT     DB #9,#E,"ERROR:",0
ERB     DB #9,#E,"press any key",0

MSG_CLIPBOARD  DB #E,"Clipboard overflow!!!",0
MSG_BUFFER_FULL DB #E,"Text buffer is full. Nothing inserted.",0
MSG_SAVE_ERROR DB #E,"Save ERROR! Original file preserved.",0
MSG_READ_ERROR DB #E,"Read ERROR! File was not opened.",0
;-------
ME01    DB #0E,"Save changes? (Y/N)",0
;-------
SRHWND  DB 4+16+128,0
        DB 255,255;  X,Y
        DB 40+2,1+2; W,H
        DB SRHWNDC;PAPER+INK
        DB 0
        DW #0; BUFFER
        DB 0,0;LINES

        DW SRHT
        DW 0
        DW 0
SRHT    DB #9,#E,"SEARCH:",0
;-------
NFNDWND DB 4+16+128,0
        DB 255,255;  X,Y
        DB 30+2,1+2; W,H
        DB NFNWNDC;PAPER+INK
        DB 0
        DW #0; BUFFER
        DB 0,0;LINES

        DW 0
        DW 0
        DW NFND
NFND    DB #E,"Not found!!!",0
;-------
CALCWND DB 4+16,0
        DB 255,255
        DB 24+2,7+2
        DB CLCWNDC
        DB 0
        DW #0
        DB 6,3

        DW CALCT
        DW 0
        DW CALCA

CALCT   DB #9,#E,"Inspector:",0
CALCA   DB 13
        DB 13
        DB " DEC:"
CALDEC  DB "00000"
        DB "    HEX:#"
CALHEX  DB "0000",13
        DB " BIN:%"
CALBIN  DB "00000000 00000000",13
        DB 13
CALSTATUS DS 24," "
          DB 0
CALC_BAD_TEXT DB "Error: invalid syntax   "
CALC_ZERO_TEXT DB "Error: division by zero "
;-------
F1WND   DB 4+16+128,0
        DB 255,255;X,Y
        DB 64,21;  W,H
        DB %01111111
        DB 0
        DW #0
        DB 0,0

F1WND_TEXT DW F1T
        DW F1B
        DW F1A
F1_TEXT_EN DW F1T,F1B,F1A
F1_TEXT_RU DW F1T_RU,F1B_RU,F1A_RU
F1T     DB #9,#E,"Text editor help",0
F1B     DB #9,#E,"Press any key to close",0
; Английская справка выбирается только для английской раскладки.
; 19 строк текста помещаются внутри окна высотой 21, включая рамку и заголовок.
F1A     DB "Controls:",#D
        DB 1,"Esc - Exit; Y saves, N discards, Esc cancels",#D
        DB #D
        DB 1,"Ctrl+S - Save changes",#D
        DB 1,"Ctrl+Alt+S - Save as",#D
        DB 1,"Ctrl+F - Find text",#D
        DB 1,"Ctrl+G - Find next",#D
        DB 1,"Ctrl+Home / Ctrl+End - Start / end of file",#D
        DB 1,"Ctrl+C / Ctrl+X / Ctrl+V - Copy / Cut / Paste",#D
        DB 1,"Shift+Right/Down/PgDn/End - Extend selection",#D
        DB 1,"Shift+Left/Up - Adjust selection",#D
        DB 1,"Enter - New line; Tab - Insert tab",#D
        DB #D
        DB 1,"Ctrl+Shift - Switch English / Russian keyboard",#D
        DB #D
        DB "Other controls:",#D
        DB 1,"PgUp, PgDn, Home, End, Delete, Backspace, Insert, CapsLock",#D
        DB 1,"F2 - Toggle syntax highlighting",#D
        DB 1,"F3 - Inspector / calculator",#D
        NOP
F1A_EN_END
        INCLUDE "HELP_RU.INC"
;---------------------------------------
F10MENU NOP; !=0 if started from F10 menu

ESTA    NOP; ExitState
CHANGES NOP; !=0 if text changed
MARKED  NOP; =1 if marked block is active (another color fill proc)
HIGHLGT NOP; =1 if syntax highlight is on
REFFLG  NOP

SVERFLG NOP; save error flag (QSAVE,SAVEAS)

; Служебные имена безопасного сохранения. Цифра выбирается SAFE_NAMES.
TMPMAKE DB 0                       ; атрибут
        DS 4,0                    ; размер файла LE32
TMPMAKE_NAME DB "WCETMP"
TMPMAKE_DIGIT DB "0"
        DB ".$$$",0

TMPQUERY DB 0                     ; искать только файл
TMPQUERY_NAME DB "WCETMP"
TMPQUERY_DIGIT DB "0"
        DB ".$$$",0
TMPQUERY_END

BAKQUERY DB 0                     ; искать только файл
BAKQUERY_NAME DB "WCEBAK"
BAKQUERY_DIGIT DB "0"
        DB ".$$$",0

SAFE_SLOT DB "0"

; Имя активного файла восстанавливается, если Save As завершился ошибкой.
SAVEAS_OLD_NAME DS 256

;File-size
DAHL    DS 2; Low
DADE    DS 2; High

;Loading
APG     NOP ; Active Page
IO_REMAIN DW 0
IO_COUNT DB 0
IO_STATUS DB 0

LHLA    DS 4; Lenght
LHLB    DS 4
SHLA    DS 3; Source Position [Offset(2)+Page(1)]
DHLA    DS 3; Dest. Position  [Offset(2)+Page(1)]

TXTNAME DB "notepad.txt",0; File name blank (if started from F10 menu)
ASMEXT  DB "asm"; -EXT check for syntax highlight
INIEXT  DB "ini"; /

;TXT-editing
CRX     NOP ; CURSOR X representation
CRY     NOP ; CURSOR Y representation
CRXX    DS 2; Col
CRYY    DS 2; Ln
XY      DS 2; temp. XY (uses in Line Print)

INOV    NOP ; 0-INS, 1-OVER

LHLCR   DS 3; Left Cursor Position [Offset(2)+Page(1)]
RHLCR   DS 3; Right Cursor Position [Offset(2)+Page(1)]
LHLCR2  DS 3
RHLCR2  DS 3

PGHLP   DS 3; TXT Page Start Address [Offset(2)+Page(1)]
LNHLP   DS 3; TXT Line --//--
LNTMP   DS 3; Temp For Mark

BHLBLK  DS 3; Block Begin Address [Offset(2)+Page(1)]
EHLBLK  DS 3; Block End Address [--//--]

CLIPSZ  DW 0; Clipboard size

;Cursor
CRPOZ   DS 2; Address on Screen (Line Print)
CRP     DS 2; Cursor Address on Screen (REFRESH)
CRFLG   NOP ; =0 if Cursor Out of Screen (REFRESH)
LINE_EOF NOP ; Остаток окна после физического конца текста только очищается.

;Search
STRBUFA  DW 0;         Address of stop token
SEARCH_OLD_L DS 3
PATLEN   DB 0
PF_LEN   DB 0
PF_CAND  DB 0
KMPFAIL  DS 41
STRBUFF  DS 40," ";    Searching string
STRBUFFL EQU $-STRBUFF;String Size
         NOP

;Inspector
CALCBUF  DS 40," "
CALCBUFL EQU $-CALCBUF
         NOP

;Save As
SASBUF   DS 255," "
SASBUFL  EQU $-SASBUF

;Calc
BUX      DS 2
DBC      DS 2
DSP      DS 2
BUF2A    DS 2;Const buf
BUF2I    NOP ;Index
;---------------------------------------
ENDPL
        ASSERT ENDPL <= FLMAKE; Код и данные не перекрывают буфер имени/размера.
;---------------------------------------
;---------------------------------------
