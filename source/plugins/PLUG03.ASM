;EXAMPLE OF PLUGIN
;(C) BUDDER/MGN/2012
;---------------------------------------
        IFNDEF __ALASM_CORG_ACTIVE
        ORG #6000
        DISP #6000
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL #6000
__ALASM_CORG_LOGICAL DEFL #6000
__ALASM_CORG_DISP DEFL 1
        ELSE
__ALASM_CORG_END DEFL __ALASM_CORG_CODE + ($ - __ALASM_CORG_LOGICAL)
__ALASM_CORG_NEW DEFL #6000
        IF __ALASM_CORG_NEW > __ALASM_CORG_END
        DS __ALASM_CORG_NEW - __ALASM_CORG_END,0
        ENDIF
        IF __ALASM_CORG_DISP
        ENT
        ENDIF
        DISP #6000
__ALASM_CORG_CODE DEFL __ALASM_CORG_NEW
__ALASM_CORG_LOGICAL DEFL #6000
__ALASM_CORG_DISP DEFL 1
        ENDIF
;-------
WLD     EQU #6006
;---------------------------------------
;HEADER:
        DS 16
        DB "WildCommanderMDL";    Header
        DB #02;                  Version
        DB 0;                       Type
        DB 1; Pages
        DB 0; Page to #8000
;-------
        DB 0,1; CODE

 .5      DB 0,0
;-------
        DS 16
;-------
        DS 32*3
;-------
        DB 0
;-------
        DW #6000,#0000; MAX SIZE
;-------
        DB "SCREEEN SAVER UB"
        DB "ER SUPER COOL!  "
;-------
        DB 2;0-BY EXTENSION ONLY
;            1-IF LOADED
;            2-BY TIMER
;---------------------------------------
        IFNDEF __ALASM_CORG_ACTIVE
        ORG #6200
        DISP #8000
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL #6200
__ALASM_CORG_LOGICAL DEFL #8000
__ALASM_CORG_DISP DEFL 1
        ELSE
__ALASM_CORG_END DEFL __ALASM_CORG_CODE + ($ - __ALASM_CORG_LOGICAL)
__ALASM_CORG_NEW DEFL #6200
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
;-------
LOBU    EQU #A000
;---------------------------------------
PLUGIN  PUSH IX
        LD (DAHL),HL,(DADE),DE

        LD IX,PLWND:CALL PRWOW

        LD HL,TXT0,DE,#000B,BC,12:CALL PRSRW
        LD A,%11110111:CALL PRIAT

;LD DE,LOBU,BC,LOBUND
;LD A,52:CALL WLD

MAIN    EI:HALT
        CALL ESC:JR Z,MAIN

        LD IX,PLWND:CALL RRESB
        LD A,(ESTAT)
        POP IX
        RET
;---------------------------------------
PRWOW   LD A,1:JP WLD
RRESB   LD A,2:JP WLD
PRSRW   LD A,3:JP WLD
PRIAT   EXA:LD A,4:JP WLD
;-------
ESC     LD A,23:JP WLD
;---------------------------------------
PLWND   DB 0,0
        DB 23,7;     X,Y
        DB 32+2,16;  W,H
        DB %01111111;PAPER+INK
        DB 0
        DW #0000;    BUFFER
        DB 0,0;      LINES
;-------
TXT0    DB "SCREEN SAVER"
;---------------------------------------
DAHL    DS 2
DADE    DS 2

ESTAT   NOP
;---------------------------------------
