; DIDESMUC — exact-драйвер IDE SMUC для WildDOSFileCore #35.
; Рабочая база #3800, размер runtime-образа #0387 (903 байта).
; SHA-256 точного runtime-образа: f9985ca2f5595979a02198991e9d412ed2cf43215def0c6310ebeac1edd4c635.
; ABI таблицы переходов:
;   #3800 SELDEV  — настроить SMUC и выбрать A=0 master либо A<>0 slave;
;   #3803 SMUCini — обнаружить и инициализировать IDE, Z=успех;
;   #3806 REINI   — повторно выбрать накопитель;
;   #3809 XPOZI   — DE:HL=LBA, сохранить позицию и подготовить регистры IDE;
;   #380C PROZ    — подготовить внутреннюю позицию без изменения LTHL/LTDE;
;   #380F RDDSE   — HL=буфер, A=число читаемых секторов по 512 байт;
;   #3812 SDDSE   — HL=буфер, A=число записываемых секторов по 512 байт;
;   #3815 RDD256  — чтение A блоков по 256 байт.
; Обмен идёт через регистры SMUC; длинные циклы явно выражены DUP/EDUP.

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

CMD     EQU #FFBE
DRV     EQU #FEBE
CYLH    EQU #FDBE
CYLL    EQU #FCBE
SECR    EQU #FBBE
BLKS    EQU #FABE
ERRO    EQU #F9BE
DATH    EQU #D8BE
DATL    EQU #F8BE

CONF    EQU #FFBA

LOBU    EQU #3000

        JP SELDEV
        JP SMUCini
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
DRVRE   NOP


; Установить линейную позицию и преобразовать LBA28 в регистры IDE.
XPOZI   LD (LTHL),HL,(LTDE),DE
PROZ    LD A,H,H,D,D,E,E,A


        LD (BLKNUM),HL
        LD (BLKNUM+2),DE
        RET

REREG   PUSH HL,DE
        LD HL,(BLKNUM)
        LD DE,(BLKNUM+2)

        LD A,H:AND %00001111:LD H,A
        LD A,(DRVRE)
        OR H
        LD BC,DRV:OUT (C),A
        LD BC,SECR:OUT (C),L
        LD BC,CYLH:OUT (C),D
        LD BC,CYLL:OUT (C),E
        POP DE,HL
        RET


RPOZ    LD BC,DRV:IN A,(C):AND #0F
        LD H,A
        LD BC,SECR:IN L,(C)
        LD BC,CYLH:IN D,(C)
        LD BC,CYLL:IN E,(C)
        RET


; Прочитать A секторов из текущей позиции IDE в буфер HL.
RDDSE   EXA:CALL DRDY
        EXA
        LD BC,BLKS:OUT (C),A
        EXA
        CALL REREG
        LD A,#20:CALL COMD
        EXA
RDH1    EXA
        CALL WAITDRQ
        CALL READS
        CALL READY
        EXA:DEC A:JR NZ,RDH1
        RET


; Записать A секторов из буфера HL в текущую позицию IDE.
SDDSE   EXA:CALL DRDY
        EXA
        LD BC,BLKS:OUT (C),A
        EXA
        CALL REREG
        LD A,#30:CALL COMD
        EXA
SDH1    EXA
        CALL WAITDRQ
        CALL SAVDS
        CALL READY
        EXA:DEC A:JR NZ,SDH1
        RET


COMM    LD BC,CMD:OUT (C),A:RET
COMD    LD BC,CMD:OUT (C),A
READY   CALL LOLL:RLCA:RET NC
        JR READY

LOLL    LD BC,CMD:IN A,(C):RET

WAITDRQ CALL LOLL:AND 8:RET NZ
        JR WAITDRQ

DRDY    CALL LOLL:RLCA:JR C,DRDY
        LD BC,DRV,A,(DRVRE):OUT (C),A
DRD     CALL LOLL
        AND %11000000
        CP %01000000:RET Z
        JR DRD

ERROR_7 CALL LOLL:RRCA:RET

YDET    CALL LOLL:BIT 7,A:RET Z
        EI:HALT
        DEC HL:LD A,H:OR L:JR NZ,YDET
        INC A
        RET

DRQWT   CALL LOLL:AND 8:RET NZ
        EI:HALT
        DEC HL:LD A,H:OR L:JR NZ,DRQWT
        RET

; Включить интерфейс SMUC и выбрать master/slave.
SELDEV  LD BC,CONF,L,%00000001:OUT (C),L

        OR A:JR NZ,SEL_SLA
SEL_MAS LD A,#E0:JR SEL_SLA+2
SEL_SLA LD A,#F0
        LD (DRVRE),A
        LD BC,DRV:OUT (C),A
        RET
SET_CHA LD A,(DRVRE)
        LD BC,DRV:OUT (C),A
REINI   RET


; Проверить наличие IDE-команды IDENTIFY и корректность адресных регистров.
SMUCini CALL SET_CHA
        LD A,#08:CALL COMM

        LD HL,256:CALL YDET:JR NZ,RU

        LD DE,0
        LD HL,2
        CALL XPOZI,REREG
        LD A,#EC:CALL COMM

        LD HL,256:CALL YDET:JR NZ,RU
        LD HL,32:CALL DRQWT:JR Z,RU
        CALL RPOZ
        PUSH HL,DE:LD HL,LOBU:CALL READS
        POP DE,HL

        LD A,D:OR E,H:JR NZ,RU
        LD A,L:CP 2:JR Z,KRU

RU      LD A,1:OR A
        RET

KRU     XOR A
        RET


; Прочитать 512 байт через чередующиеся старший и младший порты данных.
READS   LD E,high DATL
        LD D,high DATH
        LD C,low DATL,A,#08
RE1
        DUP 32
        LD B,E:INI:LD B,D:INI
        EDUP
        DEC A:JP NZ,RE1
        RET


; Записать 512 байт через чередующиеся старший и младший порты данных.
SAVDS   LD E,high DATL+1
        LD D,high DATH+1
        LD C,low DATL,A,#80
SA1     INC HL
        LD B,D:OUTD
        LD B,E:OUTI
        DUP 2
        INC HL
        EDUP
        LD B,D:OUTD
        LD B,E:OUTI
        INC HL
        DEC A:JP NZ,SA1
        RET

; Прочитать A блоков по 256 байт.
RDD256  EXA:CALL DRDY
        EXA
        LD BC,BLKS:OUT (C),A
        EXA
        CALL REREG
        LD A,#20:CALL COMD
        EXA

RDS256  EXA
        CALL WAITDRQ

        LD E,high DATL
        LD D,high DATH
        LD C,low DATL

        DUP 2
        CALL HUU
        EDUP

        CALL READY
        EXA:DEC A:JP NZ,RDS256
        RET

HUU     LD A,#10
HUD
        DUP 8
        LD B,E:INI:LD B,D:INI
        EDUP
        DEC A:JP NZ,HUD
        INC H
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
