; DIDENEMO — exact-драйвер IDE Nemo для WildDOSFileCore #35.
; Рабочая база #3800, размер runtime-образа #03BF (959 байт).
; SHA-256 точного runtime-образа: 9e093cc840ab0a810332232b9e74b36c9f09068c39452b1900876e9ccf4d6756.
; ABI таблицы переходов:
;   #3800 SELDEV  — выбрать устройство: A=0 master, A<>0 slave;
;   #3803 NEMOini — обнаружить и инициализировать IDE, Z=успех;
;   #3806 REINI   — пустая повторная инициализация;
;   #3809 XPOZI   — DE:HL=LBA, сохранить позицию и подготовить регистры IDE;
;   #380C PROZ    — подготовить внутреннюю позицию без изменения LTHL/LTDE;
;   #380F RDDSE   — HL=буфер, A=число читаемых секторов по 512 байт;
;   #3812 SDDSE   — HL=буфер, A=число записываемых секторов по 512 байт;
;   #3815 RDD256  — чтение A блоков по 256 байт.
; Быстрый путь использует DMA TS-Conf, резервный путь — порты IDE Nemo.
; DUP/EDUP повторяет всю бывшую ALASM-цепочку команд, а не один оператор.

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

STATUS  EQU #00AF

CMD     EQU #F0
DRV     EQU #FFD0
CYLH    EQU #B0
CYLL    EQU #90
SECR    EQU #70
BLKS    EQU #50
ERRO    EQU #30
DATH    EQU #11
DATL    EQU #10

LOBU    EQU #3000

        JP SELDEV
        JP NEMOini
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
REINI   RET

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

; Выбрать master/slave и записать соответствующий код drive/head.
SELDEV  OR A:JR NZ,SEL_SLA
SEL_MAS LD A,#E0:JR SEL_SLA+2
SEL_SLA LD A,#F0
        LD (DRVRE),A
        LD BC,DRV:OUT (C),A
        RET
SET_CHA LD A,(DRVRE)
        LD BC,DRV:OUT (C),A
        RET


; Проверить наличие IDE-команды IDENTIFY и корректность адресных регистров.
NEMOini CALL SET_CHA
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


; Прочитать 512 байт: DMA для выровненного буфера либо портовый цикл.
READS   LD BC,STATUS:IN A,(C)
        AND %00000011:JR NZ,OLDRDS
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

        LD B,high DMA_C,A,%01000011:OUT (C),A
        LD DE,512:ADD HL,DE
        INF:JP M,$-2
        RET

OLDRDS  LD E,low DATL
        LD D,low DATH
        LD A,#20
RE1
        DUP 8
        LD C,E:INI:LD C,D:INI
        EDUP
        DEC A:JP NZ,RE1
        RET


; Записать 512 байт: DMA для выровненного буфера либо портовый цикл.
SAVDS   LD BC,STATUS:IN A,(C)
        AND %00000011:JR NZ,OLDSVS
        LD A,L:OR A:JR NZ,OLDSVS
        BIT 0,H:JR NZ,OLDSVS

        LD BC,#4000
        LD A,H
        SUB B:JR C,MA3:INC C
        SUB B:JR C,MA3:INC C
        SUB B:JR C,MA3:INC C
        SUB B
MA3     ADD A,B:LD D,A
        LD B,#60,A,(BC)

        LD BC,STS:INF:JP M,$-2

        LD B,high DMASX:OUT (C),A
        DEC B:OUT (C),D
        DEC B:OUT (C),L

        LD B,high DMA_T:XOR A:OUT (C),A
        LD B,high DMA_N:DEC A:OUT (C),A

        LD B,high DMA_C,A,%11000011:OUT (C),A
        LD DE,512:ADD HL,DE
        INF:JP M,$-2
        RET

OLDSVS  LD C,low DATH
        LD A,#80
SA1     INC HL
        OUTD:DEC C:OUTI:INC C
        DUP 2
        INC HL
        EDUP
        OUTD:DEC C:OUTI:INC C
        INC HL
        DEC A:JP NZ,SA1
        RET

; Прочитать половинные блоки с поддержкой DMA и портового резерва.
RDD256  EXA:CALL DRDY
        EXA
        LD BC,BLKS:OUT (C),A
        EXA
        CALL REREG
        LD A,#20:CALL COMD
        EXA

RDS256  EXA
        CALL WAITDRQ

        LD BC,STATUS:IN A,(C)
        AND %00000011:JR NZ,OLDR256

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

        LD B,high DMA_C,A,%01011011:OUT (C),A
        DUP 4
        INC H
        EDUP
        INF:JP M,$-2

ENDR256 CALL READY
        EXA:DEC A:JR NZ,RDS256
        RET

OLDR256 LD D,2
HU2     LD A,#20
        LD C,low DATL
HUD
        DUP 4
        INI:INC C:INI:DEC C
        EDUP
        DEC A:JP NZ,HUD
        INC H
        DEC D:JR NZ,HU2
        JR ENDR256

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
