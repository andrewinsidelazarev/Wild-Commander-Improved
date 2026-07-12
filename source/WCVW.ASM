; WCVW — исходная подсистема просмотровщиков, запуска форматов и плагинов,
; точно восстановленная для SJASMPlus. Exact-диапазон: #9149..#9B7B.
; Основные процедуры:
;   NXTFL/PRVFL #9149/#9152 — переход к следующему или предыдущему файлу;
;   EXTZEL #915B — выбор расширения; VIEW #92BA — просмотр или запуск файла;
;   RUNSPG #957B — загрузка Spectrum Program; F11MENU #9906 — меню плагинов;
;   PLGE #9B01 — разбор и запуск выбранного плагина.
; Карта ниже закрепляет аппаратные константы и адреса ABI соседних модулей.
; Файл включается в MODULE WCVW, поэтому короткие исторические имена изолированы.

; Общая RAM, буферы, страницы и аппаратные порты.
HEI     EQU #600E
F3ENTFL EQU #6017
LOBU    EQU #B000
LOBULO  EQU #B200
LOBUL2  EQU #B400
PLHPG   EQU #60
PLGPG   EQU #61
PLEPG   EQU #A0
PLGOV   EQU #02
PLGCV   EQU #10
MAXOP   EQU 8
BASIC48 EQU #03
MTXPG   EQU #00
DBPG    EQU #F4
D5PG    EQU #F5
D2PG    EQU #F6
MLZ4    EQU #FE00
DEHR1   EQU #FEE9

Vmod    EQU #00AF
Vpag    EQU #01AF
PW0     EQU #10AF
PW1     EQU #11AF
PW2     EQU #12AF
PW4     EQU #13AF
PE0     EQU #21AF
DMASL   EQU #1AAF
DMASH   EQU #1BAF
DMASX   EQU #1CAF
DMADL   EQU #1DAF
DMADH   EQU #1EAF
DMADX   EQU #1FAF
DMA_N   EQU #26AF
DMA_C   EQU #27AF
DMA_T   EQU #28AF
STS     EQU #27AF

; Точки входа MD20, PS2P и WCIF.
GED     EQU #699F
MNG8    EQU #68B1
MNGC    EQU #68C1
MNGC_PL EQU #68F9
NOPING  EQU #6999
BOF     EQU #6A8F
NYAU    EQU #709D
NYAA    EQU #70A3
ENV     EQU #7106
RAJT    EQU #70C1
AJT     EQU #70C3
CrDN    EQU #6285
CrUP    EQU #628E
CrPU    EQU #6296
CrPD    EQU #629F
YN      EQU #6673
ESC     EQU #749A
PRWOW   EQU #792C
RRESB   EQU #7ACE

; Стабильный runtime-API WildDOS.
GIPAG   EQU #4012
LOAD512 EQU #4015

;-------
NXTFL   CALL CRDN,WCFX.STATUS:JP VIEW
PRVFL   CALL CRUP,WCFX.STATUS:JP VIEW
;---------------------------------------
EXTZEL  CALL GETEN:RET Z
        LD A,H:OR L:RET Z
        CALL WCFX.TOBUX
        LD HL,BRRR:CALL GIPAG

EXTSEL  CALL GED

        LD A,(IX+2):ADD A,2
        LD (GRWND+2),A

        LD A,(IX+3)
        ADD A,(IX+12)
        ADD A,2; Высота окна включает верхнюю и нижнюю рамки.
        LD (GRWND+3),A

        PUSH IX
        LD A,(PHED+1),C,0
        CP #C2:JR C,GEE

        LD A,PLHPG:CALL MNGC
        LD HL,#C000+197,DE,LOBU

ZkL2    LD A,(HL)
        CP #04:JR Z,GREEGO
        CP #05:JR Z,GREEGO
        CP #15:JR Z,GREEGO
        LD BC,512:JR GREE
GREEGO  LD BC,7:ADD HL,BC:LD C,24:LDIR
        LD BC,512-24-7
GREE    ADD HL,BC
        LD A,(PHED+1):CP H:JR NZ,ZkL2

        XOR A
        EX DE,HL:LD (HL),A

        LD HL,LOBU,DE,24,BC,MAXOP*256
GREEOP  LD A,(HL):OR A:JR Z,GEE
        ADD HL,DE:INC C:DJNZ GREEOP

GEE     LD A,C
        LD IX,GRWND
        PUSH AF
        ADD A,BASEOP:LD (IX+13),A
        CP (IX+12):JR NC,W850
        LD (IX+12),1
W850    ADD A,2:LD (IX+5),A
        LD A,(IX+3):ADD A,(IX+5)
        LD BC,(HEI):CP C:JR C,W85
        LD A,(IX+3):SUB (IX+5),3
        LD (IX+3),A
W85     CALL PRWOW
        POP BC

        LD A,B:OR A:JR Z,ET
        LD HL,LOBU,DE,#01+(BASEOP+1)*256
SPIG2   PUSH BC
        PUSH HL,DE:LD BC,24:CALL PRSRW
        POP DE,HL
        LD BC,24:ADD HL,BC:INC D
        POP BC:DJNZ SPIG2

ET      EI:HALT:CALL CURSOR
        CALL UPPP,NZ,CrUP
        CALL DWWW,NZ,CrDN

        CALL ENKE:JR NZ,ES
        CALL ESC:JR Z,ET

        CALL RRESB
        POP IX
        RET
;-------
ES      CALL RRESB
        POP IX

        LD A,(GRWND+12)
        PUSH AF:LD A,PLHPG:CALL MNGC
        POP BC
        LD DE,#C000+197-512
ESLG    LD HL,(PHED)
        OR A:SBC HL,DE:RET C
        LD HL,512:ADD HL,DE
        LD A,(HL):EX DE,HL
        CP #04:JR Z,DSL
        CP #05:JR Z,DSL
        CP #15:JR NZ,ESLG
DSL     DJNZ ESLG

        LD BC,0-197
        LD A,#04,(NYAA),A:CALL PLGE
        XOR A:LD (NYAA),A
        JP GED
;-------
CHEXT   LD A,(DE):OR A:RET Z
        CP (HL):JR NZ,HE
        INC HL,DE
        LD A,(DE):CP (HL):JR NZ,H2
        INC HL,DE
        LD A,(DE):CP (HL):JR Z,S7
        DEC HL,DE
H2      DEC HL,DE
HE      INC DE,DE,DE,DE,DE
        JR CHEXT

S7      INC DE:LD A,(DE),L,A
        INC DE:LD A,(DE),H,A
        LD A,1:OR A
        RET

CHext   LD BC,0,(HE),BC
        CALL CHEXT
        LD BC,#1313,(HE),BC
        RET
;-------
; Вызов по F3.
VIEW    CALL GETEN:JP Z,GED
        LD A,H:OR L:JP Z,GED
        LD A,1
        JR EXEcute

; Вызов по Enter.
VIE     XOR A
EXEcute LD (F3ENTFL),A
        CALL WCFX.TOBUX
        LD HL,BRRR:CALL GIPAG

        CALL GOPLG
        OR A:JP Z,GED
        DEC A:JR Z,VIK
        DEC A:JP Z,NXTFL
        DEC A; После GOPLG здесь A становится равным нулю.
        DEC A:JP Z,PRVFL

VIK     LD A,(F3ENTFL):OR A:JP NZ,EXTSEL
        LD HL,ENTRY+8
        LD DE,EXTZ
        CALL CHEXT:JP Z,EXTSEL,(HL)
;-------
SER13D  LD C,13
SER     LD A,(HL)
        OR A:RET Z:INC HL
        CP C:RET Z
        JP SER
;---------------------------------------
FSM     CALL GED

        PUSH IX
        LD IX,FRWND:CALL PRWOW

        LD A,1:CALL YN
MSPG    EI:HALT:CALL CURSOR
        XOR A:CALL YN

        CALL UPPP,NZ,CrUP
        CALL DWWW,NZ,CrDN

        CALL ESC:JR NZ,CSPG
        CALL ENKE:JR Z,MSPG
;-------
        LD A,#FF:CALL YN:JR NZ,CSPG

        LD A,(IX+12)
        LD C,0
        DEC A:JR Z,AS
        LD C,1
        DEC A:JR Z,AS
        LD C,2
        DEC A:JR Z,AS
        LD C,3
AS      LD A,C,(BOF),A

        CALL RRESB
        POP IX

        LD A,1:OR A
        RET
;-------
CSPG    CALL RRESB
        POP IX
        XOR A
        RET
;---------------------------------------
RUNHOB  CALL FSM:RET Z

        LD HL,#0200,B,1:CALL LOAD512
        LD HL,(#020B),A,H:CP #A0:RET NC
        LD DE,(#0209),A,D:CP #60:RET C

        EXX
        LD A,%00100000,(VVmod),A
        CALL WCINI.DINT
        XOR A:CALL MNGC,TURBOof
        LD HL,HOBAT,DE,#5B00,BC,96:LDIR
        LD HL,MNG0D,DE,#5B60,BC,32:LDIR
        EXX

        LD HL,512-17:ADD HL,DE
        PUSH DE
        JP #5B00

HOBAT   PUSH DE
THG     LD A,H:CP #60:JR C,THg
        LD B,1:CALL LOAD512
        CP #0F:JR NZ,THG
THg     POP DE
        LD HL,#0200+17,BC,512-17:LDIR

        DI
        LD A,63,I,A:IM 1
        LD IY,#5C3A

        LD HL,#5800,DE,HL:INC DE
        LD BC,#0300-1,(HL),L:LDIR

        LD BC,Vmod:XOR A:OUT (C),A
        CALL #5B60
        LD BC,#7FFD,A,16:OUT (C),A
        RET
;---------------------------------------
K       EQU #0000
MLZP    EQU #0D00
HRSP    EQU #0E00
LOB3    EQU #1000
;-------
SPG1    ; Формат SPG версии 1.0.
        CP #10:JP NZ,GED

        LD A,%00100000,(VVmod),A
        CALL WCINI.DINT

        LD A,D5PG:CALL MNGC
        LD HL,#C000,DE,HL:INC DE
        LD (HL),L,BC,#4000-1:LDIR

        LD HL,(LOB2+#30),(SPG_SA+1),HL
        LD HL,(LOB2+#32),(SPG_SP+1),HL
        LD HL,(LOB2+#38),(SPG_RZ+1),HL

        LD A,(LOB2+#34),(SPG_PG+1),A
        LD A,(LOB2+#35)
        LD C,A
        AND %00000011:LD (BOF),A

        LD A,C:AND %00000100
        LD A,#F3:JR Z,$+4:LD A,#FB
        LD (SPG_IT),A

        LD HL,LOB2,DE,LOB3,BC,1024:LDIR
        LD HL,SPGRZ,DE,K,BC,Y-SPGRZ:LDIR

        LD A,MTXPG+1:CALL MNGC
        LD HL,MLZ4,DE,MLZP,BC,256:LDIR
        LD HL,DEHR1,DE,HRSP,BC,512:LDIR
        JP K
;-------
SPGRZ   LD IX,LOB3+256
        LD A,DBPG:CALL MNG8

        LD B,0
KOVR    LD A,(IX):INC IX
        LD C,A
        AND %00011111:ADD A,A,A,#C0
        LD H,A
        LD L,0
        INC IX
        LD A,(IX):INC IX
        CP #02:JR NZ,$+4:LD A,D2PG
        CP #05:JR NZ,$+4:LD A,D5PG
        CALL MNGC

        LD A,(IX-2)
        LD E,A:AND %11000000
 .2      RLCA
        LD D,A

        LD A,E:AND %00011111:INC A
        PUSH BC,IX
        LD B,A
        LD A,D:OR A:JR NZ,SPGPKD
        CALL LOAD512
PKDE    POP IX,BC
        LD A,C
        AND %10000000:JR NZ,ARBLKZ
        DJNZ KOVR
        JR ARBLKZ
;-------
SPGPKD  DEC A:JR Z,SPGMLZ
SPGHRS  PUSH HL:LD HL,#8000:CALL LOAD512
        POP DE
        DI
        LD (SPBU),SP
        LD IX,#8000
        CALL HRSP
SPGPE   LD SP,(SPBU)
        JR PKDE

SPGMLZ  PUSH HL:LD HL,#8000:CALL LOAD512
        POP DE
        DI
        LD (SPBU),SP
        LD HL,#8000
        CALL MLZP
        JR SPGPE
;-------
ARBLKZ  LD A,D2PG:CALL MNG8
        LD A,2:CALL MNGC
        LD HL,#8000,DE,#C000
        LD BC,#4000:LDIR

        DI:CALL TURBOof

        LD A,D5PG:CALL MNG8
        LD A,5:CALL MNGC
        LD HL,#8000,DE,#C000
        LD BC,#4000:LDIR

        LD BC,Vpag,A,5:OUT (C),A
        LD BC,Vmod:XOR A:OUT (C),A

        LD A,63,I,A:IM 1
SPG_PG  LD A,0,BC,PW4:OUT (C),A
        LD A,2,B,high PW2:OUT (C),A
        LD A,5,B,high PW1:OUT (C),A

        LD HL,SPGRZD-SPGRZ+K
        LD DE,(SPG_RZ+1-SPGRZ+K)
        LD BC,16:LDIR

        LD HL,#2758:EXX
        LD IY,#5C3A
        LD BC,DMA_T:XOR A:OUT (C),A

SPG_SA  LD HL,0
SPG_SP  LD SP,#6000
SPG_RZ  JP 0
;-------
SPGRZD  LD BC,PE0,A,%00000001:OUT (C),A
        LD B,high PW0,A,BASIC48:OUT (C),A
SPG_IT  DI
        JP (HL)
Y
;---------------------------------------
PAGER   EQU #5300
LOB2    EQU #B000
;-------
RUNSPG  LD HL,LOB2,B,2:CALL LOAD512
        LD HL,LOB2+32,DE,WCINI.IDNT,B,12
        CALL WCINI.RAZ:JP NZ,GED

        LD A,(HL):CP 3:JP NC,SPG1
        CP 2:JR C,OF4
; Формат SPG версии 0.2.
        LD A,15,(VrS+1),A
        LD A,16,(V2A+1),A,(V2F+1),A
        LD A,4,(V2B+1),A
        LD A,15,(V2C+1),A
; Форматы SPG версий 0.0 и 0.1.
OF4     ; Отладочный вызов SPGLOG в поставляемой версии отключён.

        CALL FSM:RET Z:CALL TURBOof

        LD A,%00100000,(VVmod),A
        CALL WCINI.DINT

        LD HL,LOB2+1024,B,2:CALL LOAD512
        LD HL,LOB2,DE,PAGER,BC,#0800
        LDIR

        LD HL,MANAG0,DE,PAGER,BC,32:LDIR
        XOR A:CALL MNGC
;-------
V2A     LD A,8,(STUS),A; Счётчик.
        LD HL,(PAGER+64),(SAR+1),HL

        LD A,(PAGER+66),(SPA+1),A
        LD HL,(PAGER+74)
        LD A,H:CP #40:JR NC,NSPZ
        LD HL,(SPBU)
NSPZ    LD (SSPA+1),HL

        LD HL,(PAGER+68),(V2E+1),HL

        LD HL,(PAGER+76)
        LD A,H:OR L:JR Z,V2Di
        LD (V2D+1),HL
V2Di    LD BC,(PAGER+78)
        LD A,B:OR C:JR Z,MAA
        LD A,B:OR A:JR Z,MAA:LD B,1
        LD A,C:CP #41:JR C,MAA:LD C,0
MAA     LD (LAA+1),BC

        LD IX,PAGER+128
GROP    LD A,(IX+2):CP 14:JR C,NSPL
        LD A,13
NSPL    LD (SPGL+1),A

        LD A,(IX+3)
VrS     AND 7
        CALL MNGC

        LD HL,PAGER+512,E,(IX),D,(IX+1)
        LD BC,#0600
        CALL LC
        EX DE,HL
        LD A,H:CP #A0:JR C,DIPL
        PUSH IX
SPGL    LD B,1:SLA B,B
        LD A,B:OR A:CALL NZ,LOAD512
        POP IX

V2B     LD DE,8:ADD IX,DE

        LD A,(STUS):DEC A
        LD (STUS),A:JR NZ,GROP
;-------
DIPL    DI
        LD A,63,I,A:IM 1
        LD IY,#5C3A

        LD BC,Vmod:XOR A:OUT (C),A
        CALL MNG0D
        LD BC,#7FFD,A,16:OUT (C),A


        LD HL,PAGER
V2E     LD DE,0
        LD BC,32
        LDIR

LAA     LD BC,0,A,B:OR C:JR Z,SPA
        LD HL,PAGER+192
V2D     LD DE,#5B00
        LDIR

SPA     LD A,0
V2C     AND 7
        CALL PAGER


NNx     LD A,(V2C+1):CP 7:JR Z,SSPA
        LD HL,PAGER+49,E,5
OUTZ    LD C,(HL):INC HL
        LD B,(HL):INC HL
        LD A,B:OR C:JR Z,OUTz
        LD A,(HL)
        OUT (C),A
OUTz    INC HL
        DEC E:JR NZ,OUTZ

SSPA    LD SP,0
SAR     JP 0
;-------
LC      LD A,(STUS)
V2F     CP 8:RET NZ
        LD A,D:CP #A0:JR NC,V01

        LD (SREZ+4),DE
        ADD A,6:LD D,A
        PUSH DE
        LD HL,(SAR+1),(SR1+1),HL
        LD DE,PAGER+#20,(SAR+1),DE
        LD HL,SREZ,BC,16:LDIR
        POP DE
        RET
V01     LDIR
        RET
SREZ    LD HL,PAGER+512
        LD DE,0
        LD BC,#0600
        LDIR
SR1     JP 0
;-------
MANAG0  ; Вход: A — номер страницы от 0 до 15.
        PUSH BC
        LD BC,PW4:OUT (C),A
        POP BC
        RET
;---------------------------------------
PLER    LD HL,TER4:JP WCFX.ERR0
;---------------------------------------
RELOAD7 LD A,(PPFR):OR A:RET NZ

        PUSH HL
        LD HL,TXTL,DE,#0100
        CALL WCFX.DLME
        POP HL:RET Z

        PUSH HL:CALL PLGDINI
        POP HL
        LD L,0:INC H,H:CALL PLGDEL
        JR LDRE
;-------
LDPLG   CALL GED:XOR A
        LD (LOBULO),A
LDPL2   LD (PPFR),A

        LD HL,LOBU,B,1:CALL LOAD512
        CALL LOPTION

LDRE    LD A,(LOBU+32)
        CP PLGOV:JR C,PLER
        CP PLGCV+1:JR NC,PLER

        LD HL,WCINI.IDNT2,DE,LOBU+16,B,16
        CALL WCINI.RAZ:RET NZ
;-------
        LD A,(PPGM),(PPGP),A,(LOBU),A
        LD HL,(LOBU+34):ADD A,L
        RET C:CP PLEPG-PLGPG:RET NC
        LD (PPG2),A

        LD A,PLHPG:CALL MNGC

        LD A,(PHED+1):CP #40:RET C
        CALL PDCHECK:JP C,RELOAD7
        LD HL,LOBU,DE,(PHED)
        LD BC,512:LDIR:LD (PHED),DE
        EX DE,HL:LD B,0:CALL NOPING

        LD HL,LOBU+36
WALK    LD A,(HL):INC HL:CALL MNGC_PL
        LD A,(HL):INC HL:OR A:JR Z,LGW
        PUSH HL
        LD B,A,HL,#C000:CALL LOAD512
        POP HL
        JR WALK

LGW     LD A,(PPG2),(PPGM),A
        LD A,(PPFR),C,1:OR A:JR NZ,ALPL

        PUSH IX
        LD IX,LGWND:CALL PRWOW

        LD HL,LOBU+512,B,32:CALL NOPING
        LD HL,LOBU+165+31
        LD B,32,A,B:CALL NOMI
        LD C,B:SUB B:SRL A:LD B,A
        LD DE,LOBU+512,A,31:SUB B
        LD E,A,B,0
        LD A,C:OR A:JR Z,$+4:LDDR

        LD HL,LOBU+512,DE,257,BC,32:CALL PRSRW
        LD A,%01110001:CALL PRIAT
        LD HL,TEM0,DE,#020D,BC,9:CALL PRSRW

        CALL USPO
        CALL NUSP

        CALL RRESB
        POP IX

        PUSH IX:LD IX,WND:CALL WCINI.TXT2PR
        POP IX

        LD C,#FF
ALPL    LD A,(LOBU+197)
        LD HL,LOBU+198
        CP C:RET Z
        CP #11:JR C,MIMI
        CP #16:CALL C,WCINI.EDTPR
MIMI    CP #01:CALL Z,RAJT
        RET
;-------
PDCHECK LD HL,#C000+165
PDC     LD BC,(PHED)
        OR A:SBC HL,BC:RET NC
        ADD HL,BC

        PUSH HL
        LD DE,LOBU+165
        LD B,32
DCH     LD A,(DE):CP (HL):JR NZ,PDCH
        INC HL,DE
        DJNZ DCH
        POP HL
        SCF
        RET

PDCH    POP HL
        LD BC,512:ADD HL,BC
        JR PDC
;-------
PLGCL   LD A,PLHPG:CALL MNGC
        LD HL,#C000,(PHED),HL
        LD B,0:CALL NOPING
        XOR A
        LD (PPGP),A
        LD (PPGM),A
        RET
;-------
NOMI    CP (HL):RET NZ:DEC HL:DJNZ $-3
        RET
;---------------------------------------
PARmaxL EQU 32; Максимальная длина параметра.
PARmaxC EQU 10; Максимальное число параметров.
OPTmaxC EQU 10; Максимальное число опций.

LOPTION LD HL,LOBU+1,B,PARmaxC
        CALL NOPING
        EXX:LD HL,LOBU+1
        EXX

        LD DE,LOBU+260
LPARS   LD HL,LOBULO,A,(HL):OR A:RET Z
        LD (LcurSPO+1),DE
        LD A,(DE),(LcurSL+1),A:INC DE
        OR A:RET Z
        CP 252:RET NC
        LD A,(DE),(LdefOP+1),A:INC DE
        LD HL,LOBUL2
        LD (HL),"-":INC HL
        LD B,PARmaxL
LoptCP  LD A,(DE)
        CP OPTmaxC+1:JR C,LcurOPT
        LD (HL),A:INC HL,DE
        DJNZ LoptCP
        RET
LcurOPT OR A:RET Z
        EXA:LD A,B:CP PARmaxL:RET Z
        EXA:LD (HL),#FF
        LD (LoptCNT+2),A:INC DE
        PUSH DE:LD HL,LOBUL2,DE,LOBULO
        CALL WCINI.SRHSQ
        POP DE:JR Z,LdefOP
LoptCNT LD BC,0
        LD A,(HL):OR A:RET Z
        CP "=":JR NZ,$+3:INC HL
LoCNT   PUSH BC:CALL WCINI.SUU
        POP BC:INC BC:JR Z,LnotDEF
        DEC DE,DE
        DJNZ LoCNT
LdefOP  LD C,0
LnotDEF LD A,C
        EXX:LD (HL),A:INC HL:LD A,L
        EXX:CP PARmaxC+1+1:RET NC
LcurSL  LD HL,0
LcurSPO LD DE,0:ADD HL,DE:EX DE,HL
        JR LPARS
;---------------------------------------
F11MENU PUSH IX
MNU     LD A,(PHED+1):CP #C2:JP C,F1E

        LD A,PLHPG:CALL MNGC
        LD HL,#C000+165,DE,LOBU

ZkL     LD BC,32:LDIR
        LD BC,512-32:ADD HL,BC
        LD A,(PHED+1):CP H:JR NZ,ZkL

        EX DE,HL:LD BC,0-LOBU:ADD HL,BC
        SRL H:RR L
        SRL H:RR L
        SRL H:RR L
        SRL H:RR L
        SRL H:RR L
        LD A,L

        LD IX,F11WND
        PUSH AF
        LD (IX+13),A
        ADD A,2:LD (IX+5),A:CALL PRWOW
        POP BC

        LD HL,LOBU,DE,#0101
SPIG    PUSH BC
        PUSH HL,DE
        LD BC,32:CALL PRSRW
        POP DE,HL
        LD BC,32:ADD HL,BC:INC D
        POP BC
        DJNZ SPIG
;-------
F11MC   EI:HALT:CALL CURSOR

        CALL UPPP,NZ,CrUP
        CALL DWWW,NZ,CrDN
        CALL LFFF,NZ,CrPU
        CALL RGGG,NZ,CrPD

        CALL DELE,NZ,PSDEL:JP NZ,MNU

        CALL ESC:JR NZ,F1e
        CALL ENKE:JR NZ,PSEXE
        JR F11MC
;-------
F1e     CALL RRESB
F1E     POP IX
        RET
;---------------------------------------
PSEXE   LD A,PLHPG:CALL MNGC

        LD A,(IX+12):DEC A
        LD H,0,L,A
 .9      ADD HL,HL
        LD BC,#C000:ADD HL,BC
        LD DE,LOBU,BC,512:LDIR

        CALL RRESB
        POP IX

        LD A,(LOBU+197)
        CP #11:JR Z,TOAJT
        CP #13:JR Z,TOAJT
        CP #15:JR Z,TOAJT
        CP 5:JR Z,TOAJT
        CP 2:JR Z,TOAJT
        CP 3:JR NZ,PSER
TOAJT   LD A,3:CALL AJT
        CP 3:CALL Z,WCFX.SEXY
        RET
;-------
PSER    LD HL,TER3:JP WCFX.ERR0
;---------------------------------------
PSDEL   LD HL,TXTK,DE,#0100
        CALL WCFX.DLME:RET Z

        CALL PLGDINI

        LD A,(IX+12)
        LD H,A,L,0
        ADD HL,HL
        LD BC,#C000:ADD HL,BC
        CALL PLGDEL

        CALL RRESB
        LD A,1,(IX+12),A
        OR A
        RET

PLGDINI LD A,PLHPG:CALL MNGC
        LD HL,0,DE,1,BC,512-1
        LD (HL),L
        LDIR
        RET
PLGDEL  LD DE,HL:DEC D,D
        LD A,(DE)
        PUSH DE
        PUSH HL
        LD HL,0:SBC HL,DE:LD BC,HL
        POP HL:LDIR
        LD HL,(PHED)
        LD BC,0-512:ADD HL,BC
        LD (PHED),HL
        POP HL

        CALL PSMOVE:LD A,C,(PPGM),A
        RET

PSMOVE  ; Вход: A — логическая страница; HL — заголовки для исправления.

        LD C,A

PSM     LD DE,(PHED)
        OR A:SBC HL,DE:RET NC:ADD HL,DE
        LD A,(HL),(HL),C
        PUSH HL
        LD DE,34:ADD HL,DE
        LD B,(HL):CALL PSMDMA
        POP HL
        LD DE,512:ADD HL,DE
        JR PSM

PSMDMA  ; Вход: A — исходная логическая страница;
;               C — логическая страница назначения; B — длина в страницах.
;         Выход: C — логическая страница назначения.

        ADD A,PLGPG:LD E,A
        LD A,C:ADD A,PLGPG
        LD D,A
        CALL DMAPG:DJNZ $-3
        RET

DMAPG   PUSH BC
        LD HL,0
        LD BC,STS:INF:JP M,$-2
        LD B,high DMASL:OUT (C),L
        LD B,high DMASH:OUT (C),H
        LD B,high DMASX:OUT (C),E
        LD B,high DMADL:OUT (C),L
        LD B,high DMADH:OUT (C),H
        LD B,high DMADX:OUT (C),D

        LD B,high DMA_T,A,31:OUT (C),A
        LD B,high DMA_N,A,255:OUT (C),A
        LD B,high DMA_C,A,%00000001:OUT (C),A
        LD B,high STS:INF:JP M,$-2
        POP BC:INC C,D,E
        RET
;---------------------------------------
GOPLG   LD A,PLHPG:CALL MNGC

        LD DE,#C000+64-512
PLG     LD HL,(PHED)
        OR A:SBC HL,DE:JR C,PF

        LD HL,511:ADD HL,DE
        LD A,(HL):INC HL:EX DE,HL
        OR A:JR Z,OLDPLG
        SRL A:AND %00000001
        LD HL,(F3ENTFL)
        CP L:JR Z,OLDPLG
        JR PLG

OLDPLG  LD HL,ENTRY+8
        PUSH DE:CALL CHext:EX DE,HL
        POP DE:JR Z,PLG

        SCF:SBC HL,DE
        LD A,L
        LD C,255:INC C:SUB 3:JR NZ,$-3
        LD A,C,(ENV+1),A

        LD BC,0-64
PLGE    EX DE,HL:ADD HL,BC
        LD (PHEP),HL
        LD DE,LOBU,BC,256:LDIR
;-------
        LD BC,(ARRR)
        LD DE,(ARRR+2)
        LD HL,(LOBU+161+2)
        OR A:SBC HL,DE:JR C,PF,NZ,Pf
        LD HL,(LOBU+161)
        OR A:SBC HL,BC:JR C,PF

Pf      CALL NYAU:CP 3:CALL Z,WCFX.SEXY

        EI:HALT
        RET
;-------
PF      LD A,1
        RET
;-------
RATM    LD A,PLHPG:CALL MNGC

        LD HL,#C000+197,DE,(PHED),BC,512

RAT     OR A:SBC HL,DE:JR NC,CAF
        ADD HL,DE
        LD A,(HL):ADD HL,BC
        CP 2:JR NZ,RAT
        LD BC,0-(512+197):ADD HL,BC
        LD DE,LOBU,BC,256:LDIR
        CALL AJT
CAF     LD HL,0
        JR MAF
;-------
TMAFK   CALL TAB4E:JR NZ,CAF
        LD HL,(TABTM):INC HL
        LD DE,(AFTM)
        OR A:SBC HL,DE:JR NC,RATM
        ADD HL,DE
MAF     LD (TABTM),HL
        RET
;---------------------------------------
