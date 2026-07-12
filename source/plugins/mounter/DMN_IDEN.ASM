;---------------------------------------
STATUS  EQU #00AF

CMD     EQU #F0;Command/State
DRV     EQU #FFD0;Drive/Head
CYLH    EQU #B0;CYL High
CYLL    EQU #90;CYL Low
SECR    EQU #70;SEC
BLKS    EQU #50;Counter
ERRO    EQU #30;Error/Ext
DATH    EQU #11;Data High
DATL    EQU #10;Data Low
;---------------------------------------
DRVRE   DB #E0;MASTER (#F0 SLAVE)
;---------------------------------------
COMAH   LD BC,CMD:OUT (C),A:RET
READY   LD BC,CMD:IN A,(C):RLCA:RET NC
        JR READY
WAITDRQ LD BC,CMD:IN A,(C):AND 8:RET NZ
        JR WAITDRQ
;---------------------------------------
PROZ    PUSH DE
        LD A,(HL):INC HL
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD H,(HL),L,A

;DE,cyl H,head L,sec
        LD A,H:CP #FF:JR Z,POT
        AND %00001111:LD H,A
        LD A,(DRVRE)
        OR H
        LD BC,DRV:OUT (C),A
        LD BC,SECR:OUT (C),L
        LD BC,CYLH:OUT (C),D
        LD BC,CYLL:OUT (C),E
        POP HL
        LD A,1:OR A
        RET
;-------
POT     POP HL
        RET
;---------------------------------------
RDDSEne ;i:HL(4) - Sector number
;             DE - Address

        CALL PROZ:RET Z

        LD BC,BLKS,A,1:OUT (C),A
        LD A,#20:CALL COMAH,READY

        CALL WAITDRQ
        CALL READS
        CALL READY
        LD A,1:OR A
        RET
;---------------------------------------
SDDSEne ;i:HL(4) - Sector number
;             DE - Address

        CALL PROZ:RET Z

        LD BC,BLKS,A,1:OUT (C),A
        LD A,#30:CALL COMAH,READY

        CALL WAITDRQ
        CALL SAVDS
        CALL READY
        LD A,1:OR A
        RET
;---------------------------------------
;READ 512b from IDE Device BUFFER
READS   LD BC,STATUS:IN A,(C)
        AND %00000011:JP NZ,RDO

        LD C,low DATL,D,8
RD1
 .64     INI
        DEC D:JP NZ,RD1
        RET
;-------
RDO     LD E,low DATL
        LD D,low DATH
        LD A,#10
RE1
 .16     LD C,E:INI:LD C,D:INI
        DEC A:JP NZ,RE1
        RET

;---------------------------------------
;SAVE 512b to IDE Device BUFFER
SAVDS   LD BC,STATUS:IN A,(C)
        AND %00000011:JP NZ,SVO

        LD C,low DATL,D,8
SV1
 .64     OUTI
        DEC D:JP NZ,SV1
        RET
;-------
SVO     LD C,low DATH
        LD A,#80
SA1     INC HL
        OUTD:DEC C:OUTI:INC C
 .2      INC HL
        OUTD:DEC C:OUTI:INC C
        INC HL
        DEC A:JP NZ,SA1
        RET

;---------------------------------------
