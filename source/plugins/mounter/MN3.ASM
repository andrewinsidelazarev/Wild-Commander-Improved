;MODULE n2 (vTR-DOS)
;(C) KOSHI/MGN 2019
;---------------------------------------
;PAGE in RAM: #FE
;     TABLES: #FC,#FD
;   RAM DISK: #C0-#E7
;-------
        OUTPUT "mn3o.ccb"
;-------
PGAB    EQU #FC
RAMD    EQU #C0;RAM disk Start Page

MDL2    EQU #8000
MDLDRV  EQU MDL2+8
BLKT1   EQU MDLDRV+4;SD1 block/byte address flag
BLKT2   EQU MDLDRV+5;SD2 block/byte address flag

PW3     EQU #13AF
;-------
        IFNDEF __ALASM_CORG_ACTIVE
        ORG MDL2
        DISP MDL2
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL MDL2
__ALASM_CORG_LOGICAL DEFL MDL2
__ALASM_CORG_DISP DEFL 1
        ELSE
__ALASM_CORG_END DEFL __ALASM_CORG_CODE + ($ - __ALASM_CORG_LOGICAL)
__ALASM_CORG_NEW DEFL MDL2
        IF __ALASM_CORG_NEW > __ALASM_CORG_END
        DS __ALASM_CORG_NEW - __ALASM_CORG_END,0
        ENDIF
        IF __ALASM_CORG_DISP
        ENT
        ENDIF
        DISP MDL2
__ALASM_CORG_CODE DEFL __ALASM_CORG_NEW
__ALASM_CORG_LOGICAL DEFL MDL2
__ALASM_CORG_DISP DEFL 1
        ENDIF
        JP HANDLER

        IFNDEF __ALASM_CORG_ACTIVE
        ORG MDLDRV
        DISP MDLDRV
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL MDLDRV
__ALASM_CORG_LOGICAL DEFL MDLDRV
__ALASM_CORG_DISP DEFL 1
        ELSE
__ALASM_CORG_END DEFL __ALASM_CORG_CODE + ($ - __ALASM_CORG_LOGICAL)
__ALASM_CORG_NEW DEFL MDLDRV
        IF __ALASM_CORG_NEW > __ALASM_CORG_END
        DS __ALASM_CORG_NEW - __ALASM_CORG_END,0
        ENDIF
        IF __ALASM_CORG_DISP
        ENT
        ENDIF
        DISP MDLDRV
__ALASM_CORG_CODE DEFL __ALASM_CORG_NEW
__ALASM_CORG_LOGICAL DEFL MDLDRV
__ALASM_CORG_DISP DEFL 1
        ENDIF
;Driver Type:
; 0 - RS232
; 1 - Nemo Master
; 2 - Nemo Slave
; 3 - SD (ZC): RDDSEsd, SDDSEsd
; 4 - not used (SDngs)
; 5 - RAM DISK
; 6 - Smuc Master
; 7 - Smuc Slave
; 8 - SD2 (SZ)

        DB #FF;A
        DB #FF;B
        DB #FF;C
        DB #FF;D

        IFNDEF __ALASM_CORG_ACTIVE
        ORG MDL2+16
        DISP MDL2+16
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL MDL2+16
__ALASM_CORG_LOGICAL DEFL MDL2+16
__ALASM_CORG_DISP DEFL 1
        ELSE
__ALASM_CORG_END DEFL __ALASM_CORG_CODE + ($ - __ALASM_CORG_LOGICAL)
__ALASM_CORG_NEW DEFL MDL2+16
        IF __ALASM_CORG_NEW > __ALASM_CORG_END
        DS __ALASM_CORG_NEW - __ALASM_CORG_END,0
        ENDIF
        IF __ALASM_CORG_DISP
        ENT
        ENDIF
        DISP MDL2+16
__ALASM_CORG_CODE DEFL __ALASM_CORG_NEW
__ALASM_CORG_LOGICAL DEFL MDL2+16
__ALASM_CORG_DISP DEFL 1
        ENDIF
        DB 0,"vTR-DOS MDLn2!",0

        IFNDEF __ALASM_CORG_ACTIVE
        ORG MDL2+32
        DISP MDL2+32
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL MDL2+32
__ALASM_CORG_LOGICAL DEFL MDL2+32
__ALASM_CORG_DISP DEFL 1
        ELSE
__ALASM_CORG_END DEFL __ALASM_CORG_CODE + ($ - __ALASM_CORG_LOGICAL)
__ALASM_CORG_NEW DEFL MDL2+32
        IF __ALASM_CORG_NEW > __ALASM_CORG_END
        DS __ALASM_CORG_NEW - __ALASM_CORG_END,0
        ENDIF
        IF __ALASM_CORG_DISP
        ENT
        ENDIF
        DISP MDL2+32
__ALASM_CORG_CODE DEFL __ALASM_CORG_NEW
__ALASM_CORG_LOGICAL DEFL MDL2+32
__ALASM_CORG_DISP DEFL 1
        ENDIF
 .4      DS 8,#FF
        IFNDEF __ALASM_CORG_ACTIVE
        ORG MDL2+#0200
        DISP MDL2+#0200
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL MDL2+#0200
__ALASM_CORG_LOGICAL DEFL MDL2+#0200
__ALASM_CORG_DISP DEFL 1
        ELSE
__ALASM_CORG_END DEFL __ALASM_CORG_CODE + ($ - __ALASM_CORG_LOGICAL)
__ALASM_CORG_NEW DEFL MDL2+#0200
        IF __ALASM_CORG_NEW > __ALASM_CORG_END
        DS __ALASM_CORG_NEW - __ALASM_CORG_END,0
        ENDIF
        IF __ALASM_CORG_DISP
        ENT
        ENDIF
        DISP MDL2+#0200
__ALASM_CORG_CODE DEFL __ALASM_CORG_NEW
__ALASM_CORG_LOGICAL DEFL MDL2+#0200
__ALASM_CORG_DISP DEFL 1
        ENDIF
SECBU   DS 512
        DS 512
;---------------------------------------
        IFNDEF __ALASM_CORG_ACTIVE
        ORG MDL2+#1000
        DISP MDL2+#1000
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL MDL2+#1000
__ALASM_CORG_LOGICAL DEFL MDL2+#1000
__ALASM_CORG_DISP DEFL 1
        ELSE
__ALASM_CORG_END DEFL __ALASM_CORG_CODE + ($ - __ALASM_CORG_LOGICAL)
__ALASM_CORG_NEW DEFL MDL2+#1000
        IF __ALASM_CORG_NEW > __ALASM_CORG_END
        DS __ALASM_CORG_NEW - __ALASM_CORG_END,0
        ENDIF
        IF __ALASM_CORG_DISP
        ENT
        ENDIF
        DISP MDL2+#1000
__ALASM_CORG_CODE DEFL __ALASM_CORG_NEW
__ALASM_CORG_LOGICAL DEFL MDL2+#1000
__ALASM_CORG_DISP DEFL 1
        ENDIF
;-------
HANDLER ;i:HL - Address
;           D - Track (0-159)
;           E - Sector (0-15)

;           B - Drive:
;               0/1/2/3 - A/B/C/D

;           C - Operation:
;               5/6 - Read/Write

        EXX:LD BC,PW3:IN A,(C):LD (PWND3),A
        EXX
;-------
        LD A,H:CP #40:RET C
        LD A,E:CP 16:RET NC
        LD A,B:CP 4:RET NC
;-------
        LD A,B
        EXX
        LD HL,MDLDRV,B,0,C,A:ADD HL,BC
        LD A,(HL)
        EXX

        CP #00:JR Z,RS232
        CP #01:JP Z,NEMOM
        CP #02:JP Z,NEMOS
        CP #03:JP Z,SD1ZC;SD1
        CP #05:JP Z,RAMDSK
        CP #08:JP Z,SD2ZC;SD2

        LD A,7:OUT (254),A
        RET
;---------------------------------------
RAMDSK  LD A,D
        CP 160:RET NC

        LD A,C
        CP #05:JR Z,RAMRE
        CP #06:JR Z,RAMSA
        RET
;-------
RAMRE   PUSH HL
        CALL CPA
        EX DE,HL:LD DE,SECBU
        LD BC,256:LDIR
        POP DE
        LD HL,SECBU:CALL NEVA
        RET
;-------
RAMSA   PUSH DE
        EX DE,HL
        LD HL,SECBU:CALL NEVA2
        POP DE
        CALL CPA
        LD HL,SECBU,BC,256:LDIR
        RET
;---------------------------------------
CPA     LD B,D
 .2      SRL D
        LD A,RAMD:ADD A,D:CALL MNGC

        LD A,B:AND %00000011
 .4      RLCA
        OR #C0
        ADD A,E
        LD D,A,E,0
        RET
;---------------------------------------
RS232   LD A,D
        CP 160:RET NC

        LD A,C
        CP #05:JR Z,RSRE
        CP #06:JR Z,RSSA
        RET
;-------
RSRE    PUSH HL:LD HL,SECBU:RST #20
        POP DE
        LD HL,SECBU:CALL NEVA
        RET
RSSA    PUSH DE,BC
        EX DE,HL
        LD HL,SECBU:CALL NEVA2
        POP BC,DE
        LD HL,SECBU:RST #20
        RET
;---------------------------------------
CSCN    LD L,D,D,0,H,D
 .4      ADD HL,HL
        ADD HL,DE
        ADD HL,HL
        LD A,L
        PUSH AF:AND %11111100:LD L,A
        LD DE,#C000:ADD HL,DE
        LD DE,#2000
        LD A,B:AND 1:JR Z,$+3:ADD HL,DE
        LD A,B:AND 2:RRCA:ADD A,PGAB
        POP BC
        RET
;---------------------------------------
NEMOS   LD A,#F0:JR NEMO
NEMOM   LD A,#E0
NEMO    LD (DRVRE),A
        PUSH BC
        PUSH HL
        CALL CSCN
        PUSH BC:CALL REIDE
        POP AF
        POP DE
        LD HL,SECBU,BC,256
        AND %00000010:JR Z,$+3:ADD HL,BC
        POP BC
        LD A,C
        CP #05:JR Z,READ
        CP #06:JR Z,SAVE
        RET
;-------
READ    JP NEVA
SAVE    CALL NEVA2
        JP SAIDE
;---------------------------------------
SD2ZC   LD A,(BLKT2)
        EXA:LD A,%00001011:JR SDZC
SD1ZC   LD A,(BLKT1)
        EXA:LD A,%00000001
SDZC    LD (SDNUM),A
        EXA:LD (BLKT),A
        PUSH BC
        PUSH HL
        CALL CSCN
        PUSH BC:CALL RESD
        POP AF
        POP DE
        LD HL,SECBU,BC,256
        AND %00000010:JR Z,$+3:ADD HL,BC
        POP BC
        LD A,C
        CP #05:JR Z,READ
        CP #06:JR Z,SAVE3
        RET
;-------
SAVE3   CALL NEVA2
        JP SASD
;---------------------------------------
NEVA2   LD A,1,(FG),A
        CALL NEVA
        XOR A:LD (FG),A
        RET
NEVA    LD A,D
        CP #C0:JR NC,NC000
        CP #80:JR NC,N8000
        CP #40:JR NC,N4000
        RET
;-------
NC000   LD A,(PWND3):JP NNN
;-------
N8000   LD A,#40:ADD A,D:LD D,A
        LD A,2:CALL NNN:JR NC,TDO
        LD A,(PWND3)
TOO     CALL MNGC
        LD DE,#C000,B,E
        CALL LDIRR

TDO     LD A,(PWND3)
        JP MNGC
;-------
N4000   LD A,#80:ADD A,D:LD D,A
        LD A,5:CALL NNN:JR NC,TDO
        LD A,2
        JR TOO
;-------
NNN     CALL MNGC
        LD A,D:AND #3F:CP #3F:JR Z,N_N
NN      LD BC,256:CALL LDIRR
        XOR A
        RET
N_N     LD A,E:OR A:JR Z,NN
        XOR A:LD B,A
        SUB E:LD C,A
        PUSH DE:CALL LDIRR
        POP BC
        SCF
        RET
;-------
LDIRR   LD A,(FG):OR A:JR NZ,DIRR
        LDIR
        RET
DIRR    EX DE,HL:LDIR
        EX DE,HL
        RET
;---------------------------------------
REIDE   LD (PGDUB),A:CALL MNGC
        LD (HLDUB),HL
        LD DE,SECBU
        JP RDDSEne
SAIDE   LD A,(PGDUB):CALL MNGC
        LD HL,(HLDUB)
        LD DE,SECBU
        JP SDDSEne
;-------
RESD    LD (PGDUB),A:CALL MNGC
        LD (HLDUB),HL
        LD DE,SECBU
        JP RDDSEsd
SASD    LD A,(PGDUB):CALL MNGC
        LD HL,(HLDUB)
        LD DE,SECBU
        JP SDDSEsd
;---------------------------------------
MNGC    EXX:LD BC,PW3:OUT (C),A
        EXX
        RET
;---------------------------------------
PWND0   DB #FF
PWND1   DB #05
PWND2   DB #02
PWND3   NOP

PGDUB   NOP
HLDUB   DS 2

FG      NOP
;---------------------------------------
        INCLUDE "DMN_SDZ.ASM"
        INCLUDE "DMN_IDEN.ASM"
;---------------------------------------
