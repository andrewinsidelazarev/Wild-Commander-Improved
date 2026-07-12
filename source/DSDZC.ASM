; DSDZC — exact-драйвер SD-интерфейса ZC для WildDOSFileCore #35.
; Рабочая база #3800, размер runtime-образа #048C (1164 байта).
; SHA-256 точного runtime-образа: 12b4323aa4b70a7e009ae6003852b8d372acd9d8b62428f496055d8ebe1af2db.
; ABI таблицы переходов:
;   #3800 SELDEV — выбрать первый или второй интерфейс: A=0/#6015, A<>0/#6016;
;   #3803 SDINI  — определить SD/MMC, настроить адресацию и размер блока;
;   #3806 REINI  — пустая повторная инициализация;
;   #3809 XPOZI  — DE:HL=LBA, сохранить текущую позицию;
;   #380C PROZ   — DE:HL=LBA, обновить внутренний BLKNUM;
;   #380F RDDSE  — HL=буфер, A=число читаемых секторов по 512 байт;
;   #3812 SDDSE  — HL=буфер, A=число записываемых секторов по 512 байт;
;   #3815 RDD256 — чтение A блоков по 256 байт.
; Порты интерфейса: CONF=#77, DATA=#57; выровненные буферы обслуживает DMA TS-Conf.
; ALASM-списки IN A,A и OUT A,A здесь развёрнуты в две реальные команды.

        IFNDEF __ALASM_CORG_ACTIVE
        ORG 0
        DISP #3800
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL 0
__ALASM_CORG_LOGICAL DEFL #3800
__ALASM_CORG_DISP DEFL 1
        ELSE
__ALASM_CORG_END DEFL __ALASM_CORG_CODE + ($ - __ALASM_CORG_LOGICAL)
__ALASM_CORG_NEW DEFL __ALASM_CORG_END
        IF __ALASM_CORG_NEW > __ALASM_CORG_END
        DS __ALASM_CORG_NEW - __ALASM_CORG_END,0
        ENDIF
        IF __ALASM_CORG_DISP
        ENT
        ENDIF
        DISP #3800
__ALASM_CORG_CODE DEFL __ALASM_CORG_NEW
__ALASM_CORG_LOGICAL DEFL #3800
__ALASM_CORG_DISP DEFL 1
        ENDIF

SDBSF   EQU #6000+21
SDBSF2  EQU SDBSF+1

CONF    EQU #77
DATA    EQU #57

CMD_1   EQU %01000000+1
CMD_12  EQU %01000000+12
CMD_16  EQU %01000000+16
CMD_18  EQU %01000000+18
CMD_25  EQU %01000000+25
ACMD_41 EQU %01000000+41
CMD_55  EQU %01000000+55
CMD_58  EQU %01000000+58

        JP SELDEV
        JP SDINI
        JP REINI

        JP XPOZI
        JP PROZ

        JP RDDSE
        JP SDDSE

        JP RDD256

        DUP 16
        DS 3
        EDUP

NSDC    NOP
EOC     NOP

ABT     NOP

BZN     DB 4
NR0     DW 4

CAHL    DS 2
CADE    DS 2

LSTSE   DS 4

REZDE   DS 2

PR      DS 4

CLHL    DS 2
CLDE    DS 2

LLHL    DS 4

LTHL    DS 2
LTDE    DS 2

ENTRY   DS 11
EFLG    DB 0,0
        DB #00
        DW #0000:DW #0000
        DW #0000
CLSDE   DS 2
        DW #0000:DW #0000
CLSHL   DS 2
SIZIK   DS 4
        NOP

BREZS   DS 2
FSINF   DS 4

BFATS   NOP
BFTSZ   DS 4
BSECPC  DS 2
BROOTC  DS 4

FSTFRC  DW 2,0

ADDTOP  DS 4

SFAT    DS 2
SDFAT   DS 4

CUHL    DS 2
CUDE    DS 2

NXDE    DS 2
NXHL    DS 2

LDHL    DS 2
COUNT   NOP
DUHL    DS 2
DUDE    DS 2

DUBA    NOP
UUHL    DS 2
BUHL    DS 2
GARY    DS 2
CLCNT   DS 2
FCTS    DS 4
BUTS    DS 4

LSTCAT  DS 4
RECCAT  DS 4

BLKNUM  DS 4

BLKT    NOP


; Сохранить LBA в общем и внутреннем состоянии драйвера.
XPOZI   LD (LTHL),HL,(LTDE),DE
PROZ    LD (BLKNUM),HL,(BLKNUM+2),DE
REINI   RET


; Многоблочное чтение SD командой CMD18.
RDDSE   LD DE,(BLKNUM)
        LD BC,(BLKNUM+2)
        EXA
        CALL CMD18:JR NZ,$
        EXA
RD1     EXA
        CALL WTDO:CP #FE:JR NZ,$-5
        CALL READS
        EXA:DEC A:JR NZ,RD1

        CALL CMD12,SNB
        CALL WTBY
        JP CSH

; Многоблочная запись SD командой CMD25.
SDDSE   LD DE,(BLKNUM)
        LD BC,(BLKNUM+2)
        EXA
        XOR A:IN A,(CONF):AND 2:RET NZ

        CALL CMD25,WAIT
        EXA
SD1     EXA:CALL SAVDS,DRESP
        EXA:DEC A:JR NZ,SD1

SDND    LD BC,DATA,A,#FD:OUT (C),A:CALL SNB
        CALL WTBY
        JP CSH

; Принять 512 байт через DMA либо два INIR.
READS   PUSH BC,DE

        LD A,L:OR A:JR NZ,OLDRDS
        BIT 0,H:JR NZ,OLDRDS

        LD BC,#4000
        LD A,H
        SUB B:JR C,MAK:INC C
        SUB B:JR C,MAK:INC C
        SUB B:JR C,MAK:INC C
        SUB B
MAK     ADD A,B:LD D,A
        LD B,#60,A,(BC)

        LD BC,STS:INF:JP M,$-2

        LD B,high DMADX:OUT (C),A
        DEC B:OUT (C),D
        DEC B:OUT (C),L

        LD B,high DMA_T:XOR A:OUT (C),A
        LD B,high DMA_N:DEC A:OUT (C),A

        LD B,high DMA_C,A,%01000010:OUT (C),A
        LD DE,512:ADD HL,DE
        INF:JP M,$-2

RDSEX   LD BC,DATA:IN A,(C):IN A,(C)
        POP DE,BC
        RET

OLDRDS  LD BC,DATA
        DUP 2
        INIR
        EDUP
        JR RDSEX


; Передать 512 байт через DMA либо два OTIR.
SAVDS   PUSH BC,DE
        LD BC,DATA,A,#FC:OUT (C),A

        LD A,L:OR A:JR NZ,OLDSVS
        BIT 0,H:JR NZ,OLDSVS

        LD BC,#4000
        LD A,H
        SUB B:JR C,MAS:INC C
        SUB B:JR C,MAS:INC C
        SUB B:JR C,MAS:INC C
        SUB B
MAS     ADD A,B:LD D,A
        LD B,#60,A,(BC)

        LD BC,STS:INF:JP M,$-2

        LD B,high DMASX:OUT (C),A
        DEC B:OUT (C),D
        DEC B:OUT (C),L

        LD B,high DMA_T:XOR A:OUT (C),A
        LD B,high DMA_N:DEC A:OUT (C),A

        LD B,high DMA_C,A,%11000010:OUT (C),A
        LD DE,512:ADD HL,DE
        INF:JP M,$-2

SVSEX   LD BC,DATA,A,#FF:OUT (C),A:OUT (C),A
        POP DE,BC
        RET

OLDSVS
        DUP 2
        OTIR
        EDUP
        JR SVSEX

; Прочитать A половинных блоков, сохраняя потоковую позицию.
RDD256  LD DE,(BLKNUM)
        LD BC,(BLKNUM+2)
        EXA:CALL CMD18
        EXA

RDS256  EXA
        CALL WTDO:CP #FE:JR NZ,$

        LD BC,#4000
        LD A,H
        SUB B:JR C,MA2:INC C
        SUB B:JR C,MA2:INC C
        SUB B:JR C,MA2:INC C
        SUB B
MA2     ADD A,B:LD D,A
        LD B,#60,A,(BC)

        LD BC,STS:INF:JP M,$-2

        LD B,high DMADX:OUT (C),A
        DEC B:OUT (C),D
        DEC B:OUT (C),L

        LD B,high DMA_T,A,1:OUT (C),A
        LD B,high DMA_N,A,127:OUT (C),A

        LD B,high DMA_C,A,%01011010:OUT (C),A
        DUP 4
        INC H
        EDUP
        INF:JP M,$-2

        LD BC,DATA
        DUP 2
        IN A,(C)
        EDUP

        EXA:DEC A:JR NZ,RDS256

        CALL CMD12
        JP CSH

CMD00   DB %01000000+0:DS 4:DB #95
CMD08   DB %01000000+8,0,0,1,#AA,#87
CMD16   DB %01000000+16,0,0,2,0,#FF

; Выполнить последовательность инициализации SD v1/v2 или MMC.
SDINI   CALL CSH
        LD DE,512+10:CALL CYCL

        LD DE,8000
SDWT    DEC DE:LD A,D:OR E:JP Z,NOSD
        CALL CMD0:JR NZ,SDWT
        DEC A:JP NZ,SDWT

        CALL CMD8
        PUSH AF
        DUP 2
        IN E,(C)
        EDUP
        IN H,(C)
        IN L,(C)
        POP AF:JR NZ,SDWT
        BIT 2,A:JR Z,SDNEW

SDOLD   LD DE,8000
AA      DEC DE:LD A,D:OR E:JR Z,LC
        LD H,0
        CALL ACMD41:JR NZ,AA
        CP 1:JR Z,AA
        OR A:JR NZ,LC

        JR FBS

LC      LD DE,8000
OO      DEC DE:LD A,D:OR E:JR Z,NOSD
        CALL CMD1:JR NZ,OO
        CP 1:JR Z,OO
        OR A:JR NZ,NOSD

        JR FBS

SDNEW   LD DE,#01AA
        OR A:SBC HL,DE:JR NZ,NOSD

        LD DE,8000
YY      DEC DE:LD A,D:OR E:JR Z,NOSD
        LD H,#40
        CALL ACMD41:JR NZ,YY
        CP 1:JR Z,YY
        OR A:JR NZ,NOSD


        CALL CMD58:JR NZ,NOSD
        LD BC,DATA
        IN A,(C)
        DUP 3
        IN L,(C)
        EDUP
        BIT 6,A:JR Z,FBS


        LD A,1
SDFND   LD (BLKT),A
SDBS    LD (SDBSF),A
        XOR A
        JR CSH

FBS     CALL CMDi6:JR NZ,NOSD
        OR A:JR Z,SDFND

NOSD
        XOR A:INC A
        RET

CSH     PUSH BC,AF
        LD BC,CONF,A,%00000011:OUT (C),A
        LD BC,DATA,A,#FF:OUT (C),A
        POP AF,BC
        RET
CSL     PUSH BC,AF
        LD BC,CONF
CS_ON   LD A,%00000001:OUT (C),A
        LD BC,DATA,A,#FF:OUT (C),A
        POP AF,BC
        JP WAIT

SNB     PUSH BC,AF
        LD B,16
SnB     XOR A:IN A,(DATA):DJNZ SnB
        POP AF,BC
        RET

CYCL    LD BC,DATA
Cy      LD A,#FF:OUT (C),A
        DEC DE:LD A,D:OR E:JR NZ,Cy
        RET

CMDo    CALL CSH
        CALL CSL
CMDx    PUSH BC
        LD BC,DATA:OUT (C),A
        XOR A
        OUT (C),A
        OUT (C),A
        OUT (C),A
        OUT (C),A
        DEC A:OUT (C),A
        POP BC
        RET
CMD1    LD A,CMD_1:CALL CMDo:JP RESP
CMD12   LD A,CMD_12:CALL CMDx
        XOR A:IN A,(DATA)
        JP RESP
CMD55   LD A,CMD_55:CALL CMDo:JP RESP
CMD58   LD A,CMD_58:CALL CMDo:JP RESP

ACMD41  CALL CMD55
        CALL CSH
        CALL CSL

        LD BC,DATA,A,ACMD_41:OUT (C),A
        LD L,0
        OUT (C),H
        OUT (C),L
        OUT (C),L
        OUT (C),L
        DEC L:OUT (C),L
        JP RESP

CMD18   LD A,CMD_18
CMDz    CALL CSH
        CALL CSL
        PUSH HL,DE,BC

        LD L,C,H,B

        LD C,A,A,(BLKT):OR A:JR NZ,CMzz
        EX DE,HL:ADD HL,HL
        EX DE,HL:ADC HL,HL
        LD H,L,L,D,D,E,E,A

CMzz    LD A,C,BC,DATA:OUT (C),A
        OUT (C),H
        OUT (C),L
        OUT (C),D
        OUT (C),E
        LD A,#FF:OUT (C),A
        POP BC,DE,HL
        JP RESP
CMD25   LD A,CMD_25:JR CMDz

CMDi6   LD HL,CMD16:JR CMD
CMD8    LD HL,CMD08:JR CMD
CMD0    LD HL,CMD00
CMD     CALL CSH
        CALL CSL
        LD BC,DATA
        DUP 6
        OUTI
        EDUP

RESP    PUSH DE,BC
        LD BC,DATA,D,10
RESp    IN A,(C):BIT 7,A:JR Z,REZ
        DEC D:JR NZ,RESp:INC D
REZ     POP BC,DE
        RET

DRESP   PUSH BC,AF
        LD BC,DATA
        IN A,(C):CP #FF:JR Z,$-4
        AND #1F:CP 5:JR NZ,ER
        IN A,(C):OR A:JR Z,$-3
        POP AF,BC
        RET
ER      AND 15:ADD A,240
        LD BC,#0FAF:OUT (C),A
        CALL SDND
        JR $

WTBY    PUSH BC,AF
        LD BC,DATA:IN A,(C):OR A:JR Z,$-3
        POP AF,BC
        RET

WTDO    PUSH BC
        LD BC,DATA:IN A,(C):CP #FF:JR Z,$-4
        POP BC
        RET

WAIT    PUSH BC,AF
        LD BC,DATA:IN A,(C):INC A:JR NZ,$-3
        POP AF,BC
        RET

; Пропатчить chip-select и адрес глобального флага первого/второго ZC.
SELDEV  OR A:LD A,%00000001,HL,SDBSF
        JR Z,SDn1
SDn2    LD A,%00001011:INC HL
SDn1    LD (CS_ON+1),A
        LD (SDBS+1),HL
        RET

STS     EQU #27AF

DMASL   EQU #1AAF
DMASH   EQU #1BAF
DMASX   EQU #1CAF
DMADL   EQU #1DAF
DMADH   EQU #1EAF
DMADX   EQU #1FAF

DMA_T   EQU #28AF
DMA_N   EQU #26AF
DMA_C   EQU #27AF
