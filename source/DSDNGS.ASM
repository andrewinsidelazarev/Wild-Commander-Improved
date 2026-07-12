; DSDNGS — exact-драйвер SD через NGS для WildDOSFileCore #35.
; Рабочая база host-кода #3800, полный runtime-размер #0562 (1378 байт).
; SHA-256 точного runtime-образа: 468c306c1f10a6956faae65472315f37d78117779ceabd8ee371e2e72ede4ebe.
; ABI таблицы переходов host-драйвера:
;   #3800 SELDEV — проверить NGS, загрузить и запустить его SD-службу;
;   #3803 NGSINI — опросить готовность службы, Z=успех;
;   #3806 REINI  — пустая повторная инициализация;
;   #3809 XPOZI  — DE:HL=LBA, сохранить текущую позицию;
;   #380C PROZ   — DE:HL=LBA, обновить внутренний BLKNUM;
;   #380F RDDSE  — HL=буфер, A=число читаемых секторов по 512 байт;
;   #3812 SDDSE  — HL=буфер, A=число записываемых секторов по 512 байт;
;   #3815 RDD256 — пустая операция, чтение 256 байт не поддерживается.
; Host общается через GSCOM=#BB/GSDAT=#B3. Встроенная NGS-служба хранится с
; физического #39F0, исполняется на NGS с #4000 и обслуживает команды #10/#12.
; Метка TOGS обязана ссылаться на физический UDAFF до смены логической фазы ORG.

        IFNDEF __ALASM_CORG_ACTIVE
        ORG #6000
        DISP #3800
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL #6000
__ALASM_CORG_LOGICAL DEFL #3800
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
        DISP #3800
__ALASM_CORG_CODE DEFL __ALASM_CORG_NEW
__ALASM_CORG_LOGICAL DEFL #3800
__ALASM_CORG_DISP DEFL 1
        ENDIF

GSCOM   EQU #BB
GSDAT   EQU #B3

GAFF    JP SELDEV
        JP NGSINI
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

; Передать команду NGS и дождаться освобождения командного порта.
SENDCOM OUT (GSCOM),A
GSWC    IN A,(GSCOM)
        RRCA:JR C,GSWC
        RET

; Передать байт данных NGS и дождаться его приёма.
SENDDAT OUT (GSDAT),A
GSWD    IN A,(GSCOM)
        RLCA:JR C,GSWD
        RET

; Проверить, отвечает ли ранее загруженная SD-служба NGS.
NGSINI
FANK    LD A,#20:OR A:RET NZ

        LD A,#20:CALL SENDCOM
        IN A,(GSDAT)
        OR A
REINI   RET

; Синхронизировать NGS, загрузить 1 КиБ службы по адресу #4000 и запустить её.
SELDEV  LD A,#80:OUT (#33),A
        EI
        DUP 2
        HALT
        EDUP
        LD A,#F3:OUT (GSCOM),A
        CALL DIK:JR Z,WSE

        XOR A:OUT (GSDAT),A
        LD A,#1D:OUT (GSCOM),A

        CALL DIK:JR Z,WSE

        IN A,(GSDAT)
        CP #8B:LD A,1:JR NZ,WSE

        XOR A:OUT (GSDAT),A
        LD A,#14:CALL SENDCOM
        LD A,#04:CALL SENDDAT

        XOR A:CALL SENDDAT
        LD A,#40:CALL SENDDAT

        LD HL,TOGS,BC,#0400
WAV     LD A,(HL):CALL SENDDAT:INC HL
        DEC BC:LD A,B:OR C:JR NZ,WAV

        XOR A:OUT (GSDAT),A
        LD A,#13:CALL SENDCOM
        LD A,#40:CALL SENDDAT

        XOR A:OUT (GSCOM),A
        DEC A
WSE     INC A
        LD (FANK+1),A
        RET

DIK     LD B,#30
D_K     HALT:HALT
        DEC B:LD A,1:RET Z
        IN A,(GSCOM):RRA:JR C,D_K
        XOR A:INC A
        RET

; Сохранить LBA в общем и внутреннем состоянии драйвера.
XPOZI   LD (LTHL),HL,(LTDE),DE
PROZ    LD (BLKNUM),HL,(BLKNUM+2),DE
        RET

; Передать службе номер операции, LBA и число секторов.
SNDPAR  LD DE,(BLKNUM)

        OUT (#B3),A
        PUSH AF
        LD A,B:CALL SENDCOM

        LD A,E:CALL SENDDAT
        LD A,D:CALL SENDDAT
        LD A,(BLKNUM+2):CALL SENDDAT
        LD A,(BLKNUM+3):CALL SENDDAT
        XOR A:OUT (#BB),A,(#B3),A
        LD E,A
        POP AF

        LD D,A
RDD256  RET

; Получить от NGS A секторов по host-протоколу.
RDDSE   LD B,#10:CALL SNDPAR
LAWL    IN A,(#BB):RLCA:JR NC,$-3
        LD B,128
SGI     IN A,(#BB):RLCA:JR NC,$-3
        IN A,(#B3):LD (HL),A:INC HL
        IN A,(#BB):RLCA:JR NC,$-3
        IN A,(#B3):LD (HL),A:INC HL
        IN A,(#BB):RLCA:JR NC,$-3
        IN A,(#B3):LD (HL),A:INC HL
        IN A,(#BB):RLCA:JR NC,$-3
        IN A,(#B3):LD (HL),A:INC HL
        DJNZ SGI
        DEC D:JR NZ,LAWL

        XOR A
        JP SENDCOM

; Передать NGS A секторов по host-протоколу.
SDDSE   LD B,#12:CALL SNDPAR
LOL     IN A,(#BB):RLCA:JR C,$-3
        LD A,(HL):OUT (#B3),A:INC HL
        IN A,(#BB):RLCA:JR C,$-3
        LD A,(HL):OUT (#B3),A:INC HL
        DEC DE:LD A,E:OR D:JR NZ,LOL
        JP SENDCOM

UDAFF


SCTRL   EQU #11
SD_SEND EQU #13
SD_RSTR EQU #14

CMD_1   EQU %01000000+1
CMD_12  EQU %01000000+12
CMD_16  EQU %01000000+16
CMD_17  EQU %01000000+17
CMD_24  EQU %01000000+24
ACMD_41 EQU %01000000+41
CMD_55  EQU %01000000+55
CMD_58  EQU %01000000+58

SEC_BUF EQU #5000
TOGS   EQU UDAFF

        IFNDEF __ALASM_CORG_ACTIVE
        ORG #6000+UDAFF-GAFF
        DISP #4000
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL #6000+UDAFF-GAFF
__ALASM_CORG_LOGICAL DEFL #4000
__ALASM_CORG_DISP DEFL 1
        ELSE
__ALASM_CORG_END DEFL __ALASM_CORG_CODE + ($ - __ALASM_CORG_LOGICAL)
__ALASM_CORG_NEW DEFL #6000+UDAFF-GAFF
        IF __ALASM_CORG_NEW > __ALASM_CORG_END
        DS __ALASM_CORG_NEW - __ALASM_CORG_END,0
        ENDIF
        IF __ALASM_CORG_DISP
        ENT
        ENDIF
        DISP #4000
__ALASM_CORG_CODE DEFL __ALASM_CORG_NEW
__ALASM_CORG_LOGICAL DEFL #4000
__ALASM_CORG_DISP DEFL 1
        ENDIF
TOGS_CODE:
        DI
        LD SP,#6000
        LD A,%00000000:OUT (#0F),A


CMD_STR IN A,(#05)
CMD_CHK IN A,(#04):RRCA:JR NC,$-3
        IN A,(#01)
        OR A:JR Z,CMD_STR
        CP #10:JR Z,RD_SEC
        CP #12:JP Z,SV_SEC
        CP #20:JR Z,SDINI
        CP #F3:JP Z,0
        CP #F4:JP Z,0
        JR CMD_CHK

; Инициализировать SD на стороне процессора NGS.
SDINI   CALL SD_INIT
        OUT (#03),A
        JR CMD_STR

; Обработать host-команду чтения секторов.
RD_SEC  CALL RD_PAR

        IN A,(#02)
        LD A,L

RDGS    PUSH AF
        LD HL,SEC_BUF
        PUSH DE,BC
        CALL RDSINGL
        POP BC,DE
        INC DE
        LD A,D:OR E:JR NZ,$+3:INC BC

        LD HL,SEC_BUF
ORIGA   IN A,(#04):RLCA:JR C,$-3
        LD A,(HL):OUT (#03),A:INC L
        IN A,(#04):RLCA:JR C,$-3
        LD A,(HL):OUT (#03),A:INC L
        IN A,(#04):RLCA:JR C,$-3
        LD A,(HL):OUT (#03),A:INC L
        IN A,(#04):RLCA:JR C,$-3
        LD A,(HL):OUT (#03),A:INC L
        IN A,(#04):RLCA:JR C,$-3
        LD A,(HL):OUT (#03),A:INC L
        IN A,(#04):RLCA:JR C,$-3
        LD A,(HL):OUT (#03),A:INC L
        IN A,(#04):RLCA:JR C,$-3
        LD A,(HL):OUT (#03),A:INC L
        IN A,(#04):RLCA:JR C,$-3
        LD A,(HL):OUT (#03),A:INC HL
        LD A,H:CP #52:JR C,ORIGA

        POP AF
        DEC A:JR NZ,RDGS
        JP CMD_STR

; Обработать host-команду записи секторов.
SV_SEC  CALL RD_PAR
        IN A,(#02)
        LD A,L

SVGS    PUSH AF
        LD HL,SEC_BUF
ORIGA2  IN A,(#04):RLCA:JR NC,$-3
        IN A,(#02):LD (HL),A:INC L
        IN A,(#04):RLCA:JR NC,$-3
        IN A,(#02):LD (HL),A:INC HL
        LD A,H:CP #52:JR C,ORIGA2

        LD HL,SEC_BUF
        PUSH DE,BC
        CALL SVSINGL
        POP BC,DE
        INC DE
        LD A,D:OR E:JR NZ,$+3:INC BC

        POP AF
        DEC A:JR NZ,SVGS
        JP CMD_STR

RD_PAR  IN A,(#05)
        IN A,(#02):LD L,A:CALL WTD
        IN A,(#02):LD E,A:CALL WTD
        IN A,(#02):LD D,A:CALL WTD
        IN A,(#02):LD C,A:CALL WTD
        IN A,(#02):LD B,A
WTD     IN A,(#04)
        RLCA:RET C
        JR WTD

READS   PUSH BC,DE
        LD BC,SD_RSTR
        INIR
        INIR

        IN A,(C):DS 2
        IN A,(C)
        POP DE,BC
        RET

SAVDS   PUSH BC,DE
        LD BC,SD_SEND,A,#FE

        OUT (C),A:DS 2
        OTIR
        OTIR

        LD A,#FF
        OUT (C),A:DS 2
        OUT (C),A
        POP DE,BC
        RET


RDSINGL CALL CMD17:JR NZ,$
        CALL WTDO:CP #FE:JR NZ,$
        CALL READS,SNB
        CALL WTBY
        JP CSH

SVSINGL LD A,B:OR C,D,E,A,3:RET Z

        CALL CMD24:JR NZ,$
        CALL SAVDS,DRESP,SNB
        CALL WTBY
        JP CSH

CMD00   DB %01000000+0:DS 4:DB #95
CMD08   DB %01000000+8,0,0,1,#AA,#87
CMD16   DB %01000000+16,0,0,2,0,#FF

SD_INIT CALL CSH
        LD DE,512+10:CALL CYCL

        LD DE,8000
SDWT    DEC DE:LD A,D:OR E:JP Z,NOSD
        CALL CMD0:JR NZ,SDWT
        DEC A:JR NZ,SDWT

        CALL CMD8
        PUSH AF
        DUP 2
        IN E,(C):DS 2
        EDUP
        IN H,(C):DS 2
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
        LD BC,SD_RSTR
        IN A,(C):DS 2
        DUP 3
        IN L,(C):DS 2
        EDUP
        BIT 6,A:JR Z,FBS


        LD A,1
SDFND   LD (BLKT),A
        XOR A
        JR CSH

FBS     CALL CMDi6:JR NZ,NOSD
        OR A:JR Z,SDFND

NOSD    LD A,1:RET

CSH     PUSH BC,AF
        LD A,1+#80:OUT (SCTRL),A
        LD BC,SD_SEND,A,#FF:OUT (C),A
        POP AF,BC
        RET
CSL     PUSH BC,AF
        LD A,1+#00:OUT (SCTRL),A
        LD BC,SD_SEND,A,#FF:OUT (C),A
        POP AF,BC
        JP WAIT

SNB     PUSH BC,AF
        LD B,16
SnB     XOR A:IN A,(SD_RSTR):DJNZ SnB
        POP AF,BC
        RET

CYCL    LD BC,SD_SEND
Cy      LD A,#FF:OUT (C),A
        DEC DE:LD A,D:OR E:JR NZ,Cy
        RET

CMDo    CALL CSH
        CALL CSL
CMDx    PUSH BC
        LD BC,SD_SEND
        OUT (C),A:NOP
        XOR A
        OUT (C),A:DS 2
        OUT (C),A:DS 2
        OUT (C),A:DS 2
        OUT (C),A:NOP
        DEC A:OUT (C),A
        POP BC
        RET
CMD1    LD A,CMD_1:CALL CMDo:JP RESP
CMD55   LD A,CMD_55:CALL CMDo:JP RESP
CMD58   LD A,CMD_58:CALL CMDo:JP RESP

ACMD41  CALL CMD55
        CALL CSH
        CALL CSL

        LD BC,SD_SEND,A,ACMD_41
        OUT (C),A:LD L,0:NOP
        OUT (C),H:DS 2
        OUT (C),L:DS 2
        OUT (C),L:DS 2
        OUT (C),L:NOP
        DEC L:OUT (C),L
        JR RESP

CMD17   LD A,CMD_17
CMDz    CALL CSH
        CALL CSL
        PUSH HL,DE,BC

        LD L,C,H,B

        LD C,A,A,(BLKT):OR A:JR NZ,CMzz
        EX DE,HL:ADD HL,HL
        EX DE,HL:ADC HL,HL
        LD H,L,L,D,D,E,E,A

CMzz    LD A,C,BC,SD_SEND
        OUT (C),A:DS 2
        OUT (C),H:DS 2
        OUT (C),L:DS 2
        OUT (C),D:DS 2
        OUT (C),E
        LD A,#FF:OUT (C),A
        POP BC,DE,HL
        JR RESP
CMD24   LD A,CMD_24:JR CMDz

CMDi6   LD HL,CMD16:JR CMD
CMD8    LD HL,CMD08:JR CMD
CMD0    LD HL,CMD00
CMD     CALL CSH
        CALL CSL
        LD BC,SD_SEND
        DUP 6
        OUTI
        EDUP

        LD BC,SD_RSTR
RESP    PUSH DE,BC
        LD BC,SD_RSTR,D,10
RESp    IN A,(C):BIT 7,A:JR Z,REZ
        DEC D:JR NZ,RESp:INC D
REZ     POP BC,DE
        RET

DRESP   PUSH BC,AF
        LD BC,SD_RSTR
        IN A,(C):CP #FF:JR Z,$-4
        AND #1F:CP 5:JR NZ,$
        IN A,(C):OR A:JR Z,$-3
        POP AF,BC
        RET

WTBY    PUSH BC,AF
        LD BC,SD_RSTR:IN A,(C):OR A:JR Z,$-3
        POP AF,BC
        RET

WTDO    PUSH BC
        LD BC,SD_RSTR
        IN A,(C):CP #FF:JR Z,$-4
        POP BC
        RET

WAIT    PUSH BC,AF
        LD BC,SD_RSTR
        IN A,(C):INC A:JR NZ,$-3
        POP AF,BC
        RET

BLKT    NOP
