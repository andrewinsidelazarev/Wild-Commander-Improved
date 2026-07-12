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
        DB "TRD"
        DS 31*3
;-------
        DB 0
;-------
        DW #0000,#000A; MAX SIZE
;-------
        DB "TEST FOR FUNCTIO"
        DB "N number 52     "
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
TXT     EQU #9000
TX2     EQU TXT+#0100
TX3     EQU TXT+#0200

LOBU    EQU #A000
LOBUND  EQU #C000
;---------------------------------------
PLUGIN  PUSH IX
        LD (DAHL),HL,(DADE),DE

        LD IX,PLWND:CALL PRWOW

        LD HL,TXT0,DE,#000C,BC,12:CALL PRSRW
        LD A,%11110111:CALL PRIAT

        LD HL,TXT,DE,TXT+1,BC,1024-1
        LD (HL),L
        LDIR

        LD DE,LOBU,(ADDR),DE
        LD BC,LOBUND
        LD A,52:CALL WLD

MAIN    EI:HALT:CALL HEXSCR,GENHEX

        CALL ESC:JR Z,MAIN

        LD IX,PLWND:CALL RRESB
        LD A,(ESTAT)
        POP IX
        RET
;---------------------------------------
GENHEX  LD DE,(ADDR)
        LD HL,TXT
        LD B,12
AFF     LD A,(DE):INC DE:CALL NORK
        LD A,(DE):INC DE:CALL NORK
        LD A,(DE):INC DE:CALL NORK
        LD A,(DE):INC DE:CALL NORK:INC L
        LD A,(DE):INC DE:CALL NORK
        LD A,(DE):INC DE:CALL NORK
        LD A,(DE):INC DE:CALL NORK
        LD A,(DE):INC DE:CALL NORK:INC L
        LD A,(DE):INC DE:CALL NORK
        LD A,(DE):INC DE:CALL NORK
        LD A,(DE):INC DE:CALL NORK
        LD A,(DE):INC DE:CALL NORK:INC L
        LD A,(DE):INC DE:CALL NORK
        LD A,(DE):INC DE:CALL NORK
        LD A,(DE):INC DE:CALL NORK
        LD A,(DE):INC DE:CALL NORK:INC L
        LD A,L
        AND #C0:ADD A,64:JR NC,$+3:INC H
        LD L,A
        DJNZ AFF
        RET

HEXSCR
        LD HL,TXT+#00,DE,#0101,BC,35:CALL PRSRW
        LD HL,TXT+#40,DE,#0201,BC,35:CALL PRSRW
        LD HL,TXT+#80,DE,#0301,BC,35:CALL PRSRW
        LD HL,TXT+#C0,DE,#0401,BC,35:CALL PRSRW
        LD HL,TX2+#00,DE,#0501,BC,35:CALL PRSRW
        LD HL,TX2+#40,DE,#0601,BC,35:CALL PRSRW
        LD HL,TX2+#80,DE,#0701,BC,35:CALL PRSRW
        LD HL,TX2+#C0,DE,#0801,BC,35:CALL PRSRW
        LD HL,TX3+#00,DE,#0901,BC,35:CALL PRSRW
        LD HL,TX3+#40,DE,#0A01,BC,35:CALL PRSRW
        LD HL,TX3+#80,DE,#0B01,BC,35:CALL PRSRW
        LD HL,TX3+#C0,DE,#0C01,BC,35:CALL PRSRW
        RET
;---------------------------------------
PRWOW   LD A,1:JP WLD
RRESB   LD A,2:JP WLD
PRSRW   LD A,3:JP WLD
PRIAT   EXA:LD A,4:JP WLD
;-------
NORK    EXA:LD A,10:JP WLD
;-------
ESC     LD A,23:JP WLD
;---------------------------------------
PLWND   DB 0,0
        DB 22,7;     X,Y
        DB 35+2,16;  W,H
        DB %01111111;PAPER+INK
        DB 0
        DW #0000;    BUFFER
        DB 0,0;      LINES
;-------
TXT0    DB "HELLO WORLD!"
;---------------------------------------
ADDR    DS 2

DAHL    DS 2
DADE    DS 2

ESTAT   NOP
;---------------------------------------
