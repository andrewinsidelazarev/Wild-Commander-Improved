; WCINI — исходная подсистема настройки и файла wc.ini, точно восстановленная
; для SJASMPlus. Исходный exact-диапазон в boot.$C: #9B7C..#AB9E; с выносом
; настроек в SETUP.WMF модуль короче, конец — по меткам (FONT32L3 за ним).
; Диалог настроек (F9) и запись wc.ini из ядра убраны: настройки правит и
; пишет обычный плагин SETUP.WMF, ядро только читает wc.ini при старте.
; Адреса ниже — исторические, по ним сверялся исходный образ.
; Основные процедуры и таблицы:
;   MPATH/RPATH/PPATH #A00B/#A064/#A08C — пути и позиции панелей;
;   FINI #A0CE — главный вход; VDAC #A13E — видео, память и DMA;
;   LINI #A243 / INILOAD #A285 — поиск и загрузка wc.ini;
;   PARSING #A2E3 — разбор секций; SUPL #A329 — загрузка плагинов;
;   SORT #A4F4 — сортировка панели; DINT/RAZ #A721/#A72B — разбор числа;
;   STARTU #AAA2 — таблица секций; PLresCP #AB93 — резидентный шлюз.
; Добавлены 2026-09-25 (за PLresCP, адреса плавают): DEL_REFRESH/OTHER_REFRESH
; — соседняя панель после F8 и кода плагина 3; DIRCOPY_INSIDE — отказ F5
; каталога в собственный подкаталог.
; Внешняя карта ниже закрепляет адреса ABI других exact-модулей. Файл
; включается в MODULE WCINI, поэтому исторические короткие имена не конфликтуют.

; Общая RAM, размеры структур и страницы памяти.
FLG     EQU 16
ELN     EQU 17
HEIMIN  EQU 25
HEIMID  EQU 30
PPATHLN EQU 40
PPATHL2 EQU 45
INTM    EQU #5BFF
PG0     EQU #6000
PG4     EQU #6001
PG8     EQU #6002
Fun     EQU #6006
FEP     EQU #600B
CNFv    EQU #600D
HEI     EQU #600E
TXTmdCO EQU #600F
INIflg  EQU #6010
RSQBC   EQU #6011
PLresAD EQU #6020
PLresLN EQU 40
TXTBU   EQU #5EA0
RSQB    EQU #8000
LOBU    EQU #B000
LOBULO  EQU #B200
CURO    EQU #C000
RAPNL   EQU #1FFC

MTXPG   EQU #00
TVvPG   EQU #08
PNLPG   EQU #F0
INIPG   EQU #F2
RPPG    EQU #F7

Vmod    EQU #00AF
STS     EQU #27AF
DMASL   EQU #1AAF
DMADX   EQU #1FAF
DMA_N   EQU #26AF
DMA_C   EQU #27AF
DMA_T   EQU #28AF

; Точки входа MD20, PS2P, WCIF и файловых подсистем.
CrDN    EQU #6285
CrUP    EQU #628E
Lup     EQU #6372
ORIGA2  EQU #63CD
ORI     EQU #63D1
ORIGA   EQU #63ED
MNGC    EQU #68C1
CAT3    EQU #68D6
CAT1    EQU #68E6
MNG8_PL EQU #6922
NOPING  EQU #6999
GEDPL   EQU #699F
INTTMPL EQU #6A7B
TSBC    EQU #6E24
SAVECD  EQU #6F20
FENTRY  EQU #6F2C
GDIR    EQU #6F58
MKfile  EQU #6F5E
MKdir   EQU #6F7B
FNDELFL EQU #6F81
ESC     EQU #749A
CURSER  EQU #7CF2
PRWOW   EQU #792C
RRESB   EQU #7ACE
ERR0    EQU WCFX.ERR0

; Стабильный runtime-API WildDOS.
GIPAG   EQU #4012
LOAD512 EQU #4015
SAVE512 EQU #4018
GLSTCAT EQU #401E
SRHDRN  EQU #404E

; Данные WCVLS, WCVW и двоичные ресурсы после WCINI.
; Codex - 2026-07-17 - begin
; Байт, освобождённый перед строками интерфейса для суффикса версии, сдвигает
; только WND_W и TXT1; TXT2 и последующие адреса остаются историческими.
WND_W   EQU #848A
TXT1    EQU #848D
; Codex - 2026-07-17 - end
TXT2    EQU #84A6
F2TXT   EQU #84B8
F4TXT   EQU #84D0
SER13D  EQU #92FD
LDPL2   EQU #9741
PLGCL   EQU #9865
; Шрифт и распаковщики лежат HR-потоками сразу за WCINI (BOOT.ASM), а WCINI
; становится короче по мере выноса настроек в SETUP.WMF: адреса берутся по
; меткам, а не прежним числом #AB9F.
; Claude - 2026-09-26 - begin
FONT_PACKED     EQU @FONT32L3_PACKED    ; шрифт, #800 байт после распаковки
DECODERS_PACKED EQU @DECODERS_PACKED    ; MLZ50F (#E9 байт), за ним DEHR1M (#117)
DEHR            EQU @WDOS.DEHR          ; распаковщик ядра, #5AAA
; Claude - 2026-09-26 - end
MLZ4    EQU #FE00                       ; MLZ50F в странице #01, DEHR1M — с #FEE9

C000    EQU #C000

;---------------------------------------
; Найти в тексте DE образец HL, кончающийся #FF. Выход: NZ и HL — за
; совпадением; Z — не найден. Осталось от записи wc.ini: им же просмотрщик
; (WCVW) ищет свои параметры в строке плагина.
SRHSQ   LD A,(DE):OR A:RET Z
        CP (HL):INC DE:JR NZ,SRHSQ
        LD BC,HL
SSQM    INC HL:LD A,(HL):INC A:JR Z,SSQ
        LD A,(DE):OR A:RET Z
        CP (HL):INC DE:JR Z,SSQM
        LD HL,BC
        JR SRHSQ
SSQ     EX DE,HL
        LD A,1:OR A
        RET
;---------------------------------------
PATH    LD A,(LFLT):BIT 0,A:JR NZ,LPATH

        LD IX,WINDOW:CALL DRACT,ORIGA
        LD IX,WINDO2:CALL DRACT,ORIGA
        RET

LPATH   LD IX,WINDOW
        LD HL,RLPNL+C000:CALL SIMUL

        LD IX,WINDO2
        LD HL,RRPNL+C000:CALL SIMUL

        CALL MNGP
        LD A,(RAPNL+#C000)
        CP #42:JR Z,MEL
        CP #41:JR NZ,RRAP
        LD IX,WINDOW:CALL DRACT

MEL     LD A,(LFLT):BIT 1,A:RET Z
        CALL RAP
        LD A,(HL):INC A:LD C,A
        LD A,(IX+5):SUB 2,(IX+10)
        CP C:JP C,WLIT
        DEC HL:LD E,(HL)
        DEC HL:LD D,(HL)
        LD H,0,L,C
        ADD HL,DE

        PUSH DE
        EX DE,HL
        LD L,(IX+18)
        LD H,(IX+19)
        OR A:SBC HL,DE
        POP DE:JP C,WLIT

        LD (IX+12),C
        LD (IX+16),E
        LD (IX+17),D
        JP WLIT

ARAP    CALL RAP
        LD A,(IX+12):DEC A:LD (HL),A
        DEC HL:LD A,(IX+16),(HL),A
        DEC HL:LD A,(IX+17),(HL),A
        RET
RAP     CALL MNGP
        LD L,(IX+30)
        LD A,(IX+31):ADD A,#C0:LD H,A
        DEC HL
        RET

RRAP    CALL RAP
        XOR A
        LD (HL),A:DEC HL
        LD (HL),A:DEC HL
        LD (HL),A
        LD A,#42
        LD (RAPNL+#C000),A
        RET
;-------
SIMUL   CALL MNGP
        LD C,(HL):INC HL
        LD A,(HL):INC HL:CP ":":JP NZ,FI
        LD A,(HL):INC HL:CP "\\":JP NZ,FI
        LD A,C:SUB #30:CP DRVRS:JP NC,FI
        LD (IX+29),A,(IX+28),0

        LD (IX+34),1
        PUSH AF
        PUSH HL:CALL DRACT,ORIGA2,PANELI
        POP HL
        POP AF
        LD (IX+34),0
        CP (IX+29):JR NZ,FAIL

SIMZ    CALL MNGP

        LD A,(HL):CP #FF:JR Z,EXCE
        LD B,127,DE,TXTBU+1
SIMC    LD A,(HL):INC HL
        CP "\\":JR Z,SIME
        LD (DE),A:INC DE
        DJNZ SIMC:JR FAIL

SIME    XOR A:LD (DE),A
        PUSH HL
        LD HL,TXTBU,(HL),#10
        CALL SRHDRN
        LD (BRRR),HL,(BRRR+2),DE
        POP HL:JR Z,FAIL

        PUSH HL:LD HL,BRRR:CALL GLSTCAT
        POP HL

        PUSH HL
        LD A,(IX+22):CALL MNGC
        LD L,(IX+23)
        LD H,(IX+24)
        LD DE,CURO,BC,0,A,1:CALL Lup
        POP HL
        JP SIMZ

EXCE    LD DE,0-C000:ADD HL,DE
        LD (IX+32),L
        LD (IX+33),H
        JP FOLD
FAIL    LD (IX+28),0
FI      CALL RRAP
        CALL DRACT,ORIGA
        RET
;-------
MPATH   LD A,RPPG:CALL MNG0
        LD L,(IX+30)
        LD H,(IX+31):DEC HL
        XOR A
        LD (HL),A:DEC HL
        LD (HL),A:DEC HL
        LD (HL),A

        EX DE,HL
        LD E,(IX+32)
        LD D,(IX+33)
        LD A,".":CP (HL):JR Z,SPATH
APATH   LD B,255
ApA     LD A,(HL):INC HL
        OR A:JR Z,EDPA
        LD (DE),A:INC DE
        DJNZ ApA
EDPA    LD A,"\\",(DE),A:INC DE

EPATH   LD A,#FF,(DE),A
        LD (IX+32),E
        LD (IX+33),D
ZIP     JP FRST
SPATH   INC HL:CP (HL):JR NZ,LNPT
        INC HL:LD A,(HL)
        DEC HL:OR A:JR NZ,LNPT
        LD B,255
        DEC DE
SiP     DEC DE:LD A,(DE)
        CP "\\":JR Z,SIP
        CP ":":JR Z,ZIP
        DJNZ SiP
SIP     INC DE
        JR EPATH
LNPT    DEC HL
        JP APATH
;-------
RPATH   LD A,(IX+34):OR A:RET NZ
        LD A,RPPG:CALL MNG0

        LD L,(IX+30)
        LD H,(IX+31)
        LD A,(IX+29)
        ADD A,#30
        LD (HL),A:INC HL
        LD (HL),":":INC HL
        LD (HL),"\\":INC HL
        LD (HL),#FF
        LD (IX+32),L
        LD (IX+33),H
        JP FRST
;-------
PPATH   LD A,RPPG:CALL MNG0

        LD L,(IX+30)
        LD H,(IX+31)

        LD DE,HL
        LD B,PPATHLN
PPATH1  EQU $-1
AG      LD A,(DE):INC DE:CP #FF:JR Z,$+4
        DJNZ AG
        LD A,PPATHLN
PPATH2  EQU $-1
        SUB B
        LD C,A
        PUSH BC
        LD B,0,C,A
        LD DE,#0000:CALL PRSRW
        POP BC
        LD E,C
        LD HL,TXTBU
        LD C,B
        LD A,B:OR A:JR Z,PPO
        LD A," ",(HL),A:INC HL:DJNZ $-2
        LD B,0
        LD HL,TXTBU,D,0:CALL PRSRW
PPO     JP FRST
;---------------------------------------
INIA    EQU #0000
INIB    EQU #1000

FINI    CALL VDAC
        CALL LINI:OR A:JR NZ,IERR
;-------
INIOK   LD A,1,(INIflg),A
        CALL PARSING
;-------
        LD HL,ENTRY,B,32:CALL NOPING
        JP USPO;F7F

IERR    PUSH AF:CALL GEDPL
        POP AF
        LD DE,#010C
        LD HL,IFM1,BC,26:DEC A:JR Z,IERP
        LD HL,IFM2,BC,20:DEC A:JR Z,IERP
        DEC A:JR Z,INOINI
        LD HL,IFM4,BC,19
IERP    PUSH HL,BC,DE
        LD IX,IMWND:CALL PRWOW
        LD HL,IFM,DE,#000E
        LD BC,15:CALL PRSRW
        LD A,%11110001:CALL PRIAT
        POP DE,BC,HL
        CALL PRSRW
        CALL USPO
        CALL NUSP;F7F
        JP RRESB

; wc.ini нет: сказать, где взять настройки, и стартовать со встроенным
; минимумом плагинов — «WC Setup» окажется в меню F10, и F2 в нём создаст
; файл. Строка подсказки занимает окно по центру: колонки 2..41 из 1..42.
INOINI  LD HL,IFM3,BC,IFM3L,E,2
        CALL IERP
        LD A,INIPG:CALL MNG0            ; окно #0000 — снова страница INIA
        LD HL,DEFINI,DE,INIA,BC,DEFINIL:LDIR
        JR INIOK

VDAC    LD BC,Vmod:IN A,(C):AND %00000111
        LD (CNFv),A

        LD HL,RSQB
        LD (RSQBC),HL
        LD HL,%1000001100011110,(HEI),HL

        LD A,#C3,(Fun),A
        LD HL,FUN,(Fun+1),HL

        LD A,5,(PG4),A
        LD A,2,(PG8),A

        XOR A:CALL MNGC
        LD HL,0,(#C000),HL
        LD BC,STS:INF:JP M,$-2

        LD B,high DMA_N,A,255:OUT (C),A
        LD B,high DMA_T,A,18-1:OUT (C),A
        XOR A
        LD B,high DMASL:OUT (C),A
        INC B:OUT (C),A
        INC B:OUT (C),A
        LD B,high DMADX:OUT (C),A
        DEC B:OUT (C),A:INC A,A
        DEC B:OUT (C),A
        LD B,high DMA_C,A,%00000100:OUT (C),A
;-------
        CALL PLGCL

; Claude - 2026-09-26 - begin
; Шрифт и пара распаковщиков — из HR-потоков образа распаковщиком ядра DEHR
; (#5AAA: его уже поставил WDOS.INSTALL_WILDDOS, до FINI). Прежде здесь были
; LDIR из несжатых копий. DEHR портит IX и оба набора BC/DE/HL — IX сохраняется.
; Источники в окне #8000 не меняются, поэтому шрифт распаковывается дважды.
VDAC_RESOURCES:
        LD A,MTXPG+1:CALL MNGC
        PUSH IX
        LD HL,FONT_PACKED
        LD DE,#C000
        CALL DEHR                               ; шрифт — в #01
        LD HL,DECODERS_PACKED
        LD DE,MLZ4
        CALL DEHR                               ; MLZ50F с #FE00, DEHR1M с #FEE9
        LD A,TVvPG+1:CALL MNGC
        LD HL,FONT_PACKED
        LD DE,#C000
        CALL DEHR                               ; шрифт — в #09
        POP IX
; Claude - 2026-09-26 - end
        LD A,PNLPG:CALL MNG0,MNG0I
        RET

GEDZ    LD IX,WND
        LD A,(WINDOW+3):OR A:JR Z,TXT2PR
        LD DE,32,B,E:CALL GADRW
        XOR A:CALL PRIAT

        LD HL,TXT1,DE,0:CALL TXTPR
        LD HL,TTM
        LD DE,WID1-8
        LD A,(HEI):CP HEIMAX:JR NZ,GMS
        LD DE,WID2-8
GMS     LD BC,8:CALL PRSRW
        LD A,%00011111:CALL PRIAT

TXT2PR  LD HL,TXT2,A,(HEI):DEC A
        LD D,A,E,0:JP TXTPR

EDTPR   PUSH IX
        LD IX,WND
        PUSH AF
        LD DE,F2TXT
        SUB #11:JR Z,F2PR
        DEC A:JR Z,F2PR
        LD DE,F4TXT
F2PR    LD BC,6:LDIR
        POP AF
        POP IX
        RET

LINI    LD A,INIPG:CALL MNG0
        CALL GBD
        CALL TSBC:LD A,1:RET NZ
;-------
        LD HL,WCDIR:CALL SRHDRN:LD A,2:RET Z
        LD (BRRR),HL,(BRRR+2),DE
        LD HL,BRRR:CALL GLSTCAT

        LD HL,WCINI:CALL SRHDRN:LD A,3:RET Z

        LD (BRRR),HL,(BRRR+2),DE
        LD HL,BRRR:CALL GIPAG
;-------
        CALL INILOAD:LD A,4:RET NZ
        XOR A
        RET
;---------------------------------------
INILOAD CALL INXSe

        LD DE,IDNT3,B,19
        CALL RAZ:RET NZ:NOP

        ; IDNT3 проверяет совместимый префикс версии. Оставшийся суффикс
        ; пропускается до CR тем же флагом C, что и комментарий. Сохраняем
        ; сам CR, поэтому работают старый заголовок и новые версии с хвостом.
        LD DE,INIA,BC,1
INIF    LD A,D:CP high INIB:JR NC,INILE
        LD A,H:AND 1:OR L
        CALL Z,INXSE:JR Z,INILE
        LD A,(HL)
        CP #0A:JR C,INILE,Z,INiF
        CP #0D:CALL Z,SKIPE
        CP ";":CALL Z,SKIPS

        INC C:DEC C:JR NZ,INiF
        LD (DE),A
        INC DE
INiF    INC HL
        JR INIF

INILE   XOR A:LD (DE),A:RET
;-------
SKIPS   LD C,1:RET
SKIPE   LD C,0:RET
;-------
INXSE   LD A,B:CP #0F:RET Z
        PUSH BC,DE:CALL INXSe
        POP DE,BC:LD B,A
        XOR A:INC A
        RET

INXSe   LD HL,INIB,B,1
        PUSH HL:CALL LOAD512
        POP HL
        RET
;---------------------------------------
PARSING LD HL,INIA
PARS    LD A,(HL)
        CP "[":CALL Z,SUEXE:JR Z,PARS
        CALL SER13D
        LD A,(HL)
        OR A:RET Z
        LD A,H:CP high INIB:RET NC
        JR PARS

SUEXE   LD DE,STARTU:INC HL
SUfnd   LD A,(DE):INC A:RET Z
        CALL SUU:JR Z,SUexe
        JR SUfnd

SUU     PUSH HL:CALL RAZ0:INC DE
        POP HL:RET Z
        XOR A
        EX DE,HL:LD BC,16:CPIR:INC HL,HL
        EX DE,HL
        INC A
        RET

SUexe   LD A,(DE),(SUmod+1),A:INC DE
        LD A,(DE),(SUmod+2),A
SUmod   CALL 0
        XOR A
        RET
;-------
SUPL    PUSH HL
        LD IX,INIWND:CALL PRWOW
        CALL GEDPL
        POP HL

        LD DE,#0000
        LD BC,TXTIL:CALL PRMESS
; INILOAD вырезает комментарии до CR, поэтому строка «;CLOCK.WMF…» приходит
; сюда пустой. Раньше пустая строка кончала секцию, и всё ниже выключенного
; плагина молча не грузилось, а WC Setup выключает плагин как раз «;» в
; начале его строки. Секцию кончает только «[» или конец текста.
RSI     CALL SER13D
        LD A,(HL)
        CP #0D:JR Z,RSI
        CALL ICE:RET Z

        PUSH HL
        PUSH DE:CALL SERNLOD
        POP DE
        CALL NZ,PLPRNAM
        POP HL
        JR RSI
;-------
SUPAL   LD A,0:EXA:JR SUPA
SUPAR   LD A,1:EXA

SUPA    CALL SER13D,ICE:RET Z

        LD DE,PANN:CALL SUpa
        JR SUPA

SUpa    LD A,(DE):INC A:RET Z
        CALL SUU:JR Z,SUexe
        JR SUpa

CPCL    LD A,(HL):INC HL
        CP " ":JR Z,CPC
        CP "=":JR Z,CPC
        CP #0E:JR NC,CPCL
        DEC HL
        LD A,"1":JR $+3
CPC     LD A,(HL)

        LD HL,WINDOW
        EXA:OR A:JR Z,$+5:LD HL,WINDO2
        EXA
        SUB #30
        RET
;-------
SUPAD   PUSH HL:CALL CPCL
        LD DE,29:ADD HL,DE
        CP DRVRS:JR C,$+4:LD A,1
        LD (HL),A
        POP HL
        RET
SUPAI   PUSH HL:CALL CPCL
        LD DE,10:ADD HL,DE
        AND 1:ADD A,A
        LD (HL),A
        POP HL
        RET
SUPAS   PUSH HL:CALL CPCL
        LD DE,35:ADD HL,DE
        AND 7                           ; 4 — по дате; 5..7 SORD не сортирует
        LD (HL),A
        POP HL
        RET

ICE     LD A,(HL)
        OR A:RET Z
        CP #0D:RET Z
        CP "["
        RET
;-------
SUL     CALL SER13D,ICE:RET Z

        LD DE,SETUP:CALL SUpa
        JR SUL
SUL1    PUSH HL:CALL CPCL
        AND %00000011
        LD (DFRQ),A
        POP HL
        RET

SUL2    PUSH HL:CALL CPCL
        AND %00000001
        LD HL,LFLT:OR (HL):LD (HL),A
        POP HL
        RET

SUL3    PUSH HL:CALL CPCL
        LD HL,%0001111010000011
        JR NZ,$+5
        LD HL,%0001100101000011
        CP 2:JR NZ,$+5
        LD HL,%0010010011000011

        LD A,H,(HEI),A:CP HEIMAX
        LD A,L,(TXTmdCO),A:JR NZ,SUL3E
        LD A,WID2,(WID),A,(WND_W),A
        LD A,WID2/2
        LD (WINDOW+4),A
        LD (WINDO2+4),A
        LD (WINDO2+2),A
        LD A,PPATHL2
        LD (PPATH1),A,(PPATH2),A

SUL3E   POP HL
        RET

SUL4    PUSH HL:CALL CPCL
        AND %00000001:ADD A,A
        LD HL,LFLT:OR (HL):LD (HL),A
        POP HL
        RET

SUL5    PUSH HL:CALL CPCL
        LD HL,#FFFF
        AND 15:JR Z,SUL5E
        LD B,A:INC HL
        LD DE,49*60
NEADD   ADD HL,DE:DJNZ NEADD
SUL5E   LD (AFTM),HL
        POP HL
        RET

SUL6    PUSH HL:CALL CPCL:JR Z,SUL6OFF

        LD A,1
        LD (INTTM),A
        LD (INTTMPL),A
        LD (WINDOW+3),A
        LD (WINDO2+3),A
        INC A:LD (ORI),A
SUL6OFF POP HL
        RET
;-------
SERNLOD CALL GENNAM,SRHDRN:RET Z
        LD (BRRR),HL,(BRRR+2),DE
        LD HL,BRRR:CALL GIPAG

        LD A,1:CALL LDPL2
        LD A,1:OR A
        RET
;-------
GENNAM  LD DE,LOBU+1
        LD B,255
GENA    LD A,(HL)
        CP ";":JR Z,GENEND
        CP " ":JR C,GENEND
        JR NZ,NOiniPM:INC HL
        LD A,(HL)
        CP "-":JR NZ,NOiniPm:INC HL
        LD A,(HL)
        CP " ":DEC HL:JR NZ,INIprm
NOiniPm DEC HL:LD A,(HL)
NOiniPM LD (DE),A:INC HL,DE
        DJNZ GENA
GENEND  XOR A:LD (DE),A
        LD HL,LOBU,(HL),A
        RET
;-------
INIprm  PUSH DE
        LD DE,LOBULO
        LD B,255
INIyoyo LD A,(HL)
        CP #20:JR C,INIprND,Z,INIprNX
        CP ";":JR Z,INIprND
        LD (DE),A:INC DE
INIprNX INC HL
        DJNZ INIyoyo
INIprND XOR A:LD (DE),A
        POP DE
        JR GENEND
;-------
PLPRNAM PUSH DE
        LD IX,INIWND
        LD HL,LOBU+165,BC,32:CALL PRSRW
        LD A,%00001111:CALL PRIAT
        POP DE
        INC D
        RET
;-------
PRMESS  PUSH HL,DE
        LD IX,INIWND
        LD HL,BC:CALL TXTPR
        POP DE,HL
        INC D
        RET
;---------------------------------------
SORT    XOR A:LD (SWAP+1),A
        LD A,(IX+19):OR A:JR NZ,SORD
        LD A,(IX+18):CP 2:RET C

SORD    LD A,(IX+35)
        OR A:RET Z
        DEC A:JP Z,BYNM
        DEC A:JR Z,BYEX
        DEC A:JP Z,BYSZ
        DEC A:JP Z,BYDT                 ; 4 — по дате изменения (Ctrl+F5)
        RET
;-------
DDNET   CALL CAT3
        CALL CAT1

        LD DE,0
        INC E:LD A,(DE):LD L,A
        INC E:LD A,(DE):LD H,A
 .2      DEC E
        LD BC,ELN:ADD HL,BC
        LD A,"."
        CP (HL):RET NZ:INC HL
        CP (HL):RET NZ
        LD E,4
        RET
;-------
IINET   INC E:LD A,(DE),C,A
        INC E:LD A,(DE),D,A,A,C
        ADD A,FLG:JR NC,$+3:INC D:LD E,A

        INC L:LD A,(HL)
        INC L:LD H,(HL)
        ADD A,FLG:JR NC,$+3:INC H:LD L,A
        RET
;-------
BYEX    CALL DDNET
CA9     LD (C_DE),DE
        EX DE,HL

        LD (CYK+1),HL

        LD BC,5:ADD HL,BC
        LD A,(HL); младший байт адреса внутри страницы
        INC L:OR (HL):RET Z; нулевое слово означает отсутствие адреса #C000+
 .2      DEC L

CYK3    LD DE,(CYK+1)
        LD (C_HL3+1),HL
        INC L:LD A,(HL)
        INC L:OR (HL)
 .2      DEC HL
        CALL Z,SWAP:JR Z,CA9

        INC E:LD A,(DE),C,A
        INC E:LD A,(DE),D,A,E,C:INC DE
        INC L:LD A,(HL)
        INC L:LD H,(HL),L,A:INC HL

        LD A,(DE)
        CP (HL):JR Z,$+6,NC,TZER3,C_HL3
        INC HL,DE
        LD A,(DE)
        CP (HL):JR Z,$+6,NC,TZER3,C_HL3
        INC HL,DE
        LD A,(DE)
        CP (HL):JR Z,$+6,NC,TZER3,C_HL3

        LD A,E:ADD A,ELN-3
        JR NC,$+3:INC D:LD E,A
        LD A,L:ADD A,ELN-3
        JR NC,$+3:INC H:LD L,A

KPUK    LD B,255
CHAK3   LD A,(HL),C,A
        CP #5B:JR NC,CKF3
        CP #41:JR C,CKF3:SET 5,C
CKF3    LD A,(DE)
        CP #5B:JR NC,CKS3
        CP #41:JR C,CKS3:SET 5,A
CKS3    CP C:JR Z,NXC3,NC,TZER3
C_HL3   LD HL,0
 .3      INC L
        INC HL
        JP CYK3
;-------
NXC3    INC HL,DE:DJNZ CHAK3
        LD HL,(C_HL3+1)
 .3      INC L
        INC HL
        JP CYK3
TZER3   LD A,1,(SWAP+1),A
        LD HL,(C_HL3+1)
        LD (CYK+1),HL

 .3      INC L
        INC HL
        JP CYK3
;-------
BYSZ    CALL DDNET
CA8     LD (C_DE),DE
        EX DE,HL

        LD (CYK+1),HL

        LD BC,5:ADD HL,BC
        LD A,(HL)
        INC L:OR (HL):RET Z
 .2      DEC L

CYK2    LD DE,(CYK+1)
        LD (C_HL2+1),HL
        INC L:LD A,(HL)
        INC L:OR (HL)
 .2      DEC HL
        CALL Z,SWAP:JR Z,CA8

        CALL IINET

        LD A,(DE)
        CP (HL):JR Z,BJK,NC,TZER2,C_HL2
; Размер — 32 бита на +8..+11 элемента, сравнение со старшего байта +11.
; Прежде сравнение начиналось с +8 — младшего байта размера, за которым шли
; байты кластера, и 256 байт стояли раньше 100 (исправлено 2026-09-24).
BJK     LD BC,0-(FLG-11)
        ADD HL,BC:EX DE,HL
        ADD HL,BC:EX DE,HL
        LD B,4
CHaK2   LD A,(DE)
        CP (HL):JR Z,NXc2,NC,TZER2,C_HL2
NXc2    DEC HL,DE:DJNZ CHaK2

        LD BC,ELN-7                     ; от +7 к имени на +17
        ADD HL,BC:EX DE,HL
        ADD HL,BC:EX DE,HL

        LD B,255
CHAK2   LD A,(DE)
        CP (HL):JR Z,NXC2,NC,TZER2
C_HL2   LD HL,0
 .3      INC L
        INC HL
        JP CYK2
;-------
NXC2    INC HL,DE:DJNZ CHAK2
        LD HL,(C_HL2+1)
 .3      INC L
        INC HL
        JP CYK2
TZER2   LD A,1,(SWAP+1),A
        LD HL,(C_HL2+1)
        LD (CYK+1),HL

 .3      INC L
        INC HL
        JP CYK2
;-------
; По дате и времени изменения, новые сверху. Каталоги, как и в других режимах,
; отдельно от файлов. Ключ — 32 бита на +12..+15 элемента (время, затем дата:
; так их кладёт NXTETY), сравнение со старшего байта.
BYDT    CALL DDNET
CA10    LD (C_DE),DE
        EX DE,HL

        LD (CYK+1),HL

        LD BC,5:ADD HL,BC
        LD A,(HL)
        INC L:OR (HL):RET Z
 .2      DEC L

CYK4    LD DE,(CYK+1)
        LD (C_HL4+1),HL
        INC L:LD A,(HL)
        INC L:OR (HL)
 .2      DEC HL
        CALL Z,SWAP:JR Z,CA10

        CALL IINET

        LD A,(DE)
        CP (HL):JR Z,BJD,NC,TZER4,C_HL4
BJD     DEC HL,DE                       ; +15 — старший байт даты
        LD B,4
CHaK4   LD A,(DE)
        CP (HL):JR Z,NXc4,C,TZER4,C_HL4
NXc4    DEC HL,DE:DJNZ CHaK4
C_HL4   LD HL,0
 .3      INC L
        INC HL
        JP CYK4
TZER4   LD A,1,(SWAP+1),A
        LD HL,(C_HL4+1)
        LD (CYK+1),HL

 .3      INC L
        INC HL
        JP CYK4
;-------
BYNM    CALL DDNET
CA7     LD (C_DE),DE
        EX DE,HL

        LD (CYK+1),HL

        LD BC,5:ADD HL,BC
        LD A,(HL)
        INC L:OR (HL):RET Z
 .2      DEC L

CYK     LD DE,0
        LD (C_HL),HL

        INC L:LD A,(HL)
        INC L:OR (HL)
 .2      DEC HL
        CALL Z,SWAP:JR Z,CA7

        CALL IINET

        LD B,255
        LD A,(DE)
        CP (HL):JR Z,NXC,NC,TZER,KP9K

CHAK    LD A,(HL),C,A
        CP #5B:JR NC,CKF
        CP #41:JR C,CKF:SET 5,C
CKF     LD A,(DE)
        CP #5B:JR NC,CKS
        CP #41:JR C,CKS:SET 5,A
CKS     CP C:JR Z,NXC,NC,TZER
KP9K
C_HL    EQU $+1:LD HL,0
 .3      INC L
        INC HL
        JP CYK
;-------
NXC     INC HL,DE:DJNZ CHAK
        LD HL,(C_HL)
 .3      INC L
        INC HL
        JP CYK
TZER    LD A,1,(SWAP+1),A
        LD HL,(C_HL)
        LD (CYK+1),HL

 .3      INC L
        INC HL
        JP CYK
;-------
SWAP    LD A,0:OR A:JP Z,NSWA
        XOR A:LD (SWAP+1),A

        LD DE,(C_DE)
        LD HL,(CYK+1)

        LD A,(DE),C,(HL)
        LD (HL),A,A,C,(DE),A:INC L,E
        LD A,(DE),C,(HL)
        LD (HL),A,A,C,(DE),A:INC L,E
        LD A,(DE),C,(HL)
        LD (HL),A,A,C,(DE),A:INC L,E
        LD A,(DE),C,(HL)
        LD (HL),A,A,C,(DE),A

NSWA    LD HL,(C_DE)
 .3      INC L
        INC HL
        EX DE,HL
        XOR A
        RET
;---------------------------------------
DINT    EI:HALT:DI
        LD HL,INTM+2,(INTM),HL
        RET
;-------
RAZ     LD A,(DE):CP (HL):RET NZ
        INC HL,DE
        DJNZ RAZ
        RET
;-------
RAZ0    LD A,(DE):CP (HL):RET NZ
        INC HL,DE
        LD A,(DE):OR A:RET Z
        JR RAZ0
;---------------------------------------
C_DE    DS 2
;---------------------------------------
IMWND   DB 3+16,0
        DB 18,13;    X,Y
        DB 42+2,1+2; W,H
        DB %00011111; цвета фона и текста
        DB 0
        DW #0000; буфер окна
        DB 0,0; число строк
;-------
INIWND  DB 0,0
        DB 0,0;     X,Y
        DB 0,0;      W,H
        DB %00000000; цвета фона и текста
        DB 0
        DW #FFFF; буфер окна
        DB 0,0; число строк
;---------------------------------------
SERR    DB "Device or FAT32 NOT FOUND!"
IFM     DB "INI File ERROR:"
IFM1    EQU SERR
IFM2    DB "WC folder not found!"
IFM3    DB "No settings: press F10 and run WC Setup."
IFM3L   EQU $-IFM3
        ASSERT IFM3L == 40, подсказка должна стоять в окне ровно по центру
IFM4    DB "INI file corrupted!"
TXTIL   DB 4,4,">loading plugins",0
DEFINI  DB "[PLUGINS]",13,"FILEX.WMF",13,"PLM.WMF",13,"SETUP.WMF",13,0
DEFINIL EQU $-DEFINI

STARTU  DB "SETUP",0:DW SUL
        DB "PLUGINS",0:DW SUPL
        DB "LPANEL",0:DW SUPAL
        DB "RPANEL",0:DW SUPAR
        DB #FF
PANN    DB "DRV",0:DW SUPAD
        DB "INFO",0:DW SUPAI
        DB "CSORT",0:DW SUPAS
        DB #FF
SETUP   DB "CPU_FREQ",0:DW SUL1
        DB "SavePaths",0:DW SUL2
        DB "SavePosition",0:DW SUL4
        DB "TextMode",0:DW SUL3
        DB "ScreenSaver",0:DW SUL5
        DB "Logo",0:DW SUL6
        DB #FF

IDNT    DB "SpectrumProg"
IDNT2   DB "WildCommanderMDL"
; Префикс проверки формата, общий для v1.1, v1.10i и v1.11i: строка для
; сохранения берётся из заголовка WC.
IDNT3   DB "Wild Commander v1.1"

IVD     DB "IDE VideoDAC: "
IVDy    DB "detected"
IVDn    DB "none    "
;---------------------------------------
PLresJP PUSH BC:CALL MNG8_PL
        POP BC:JP (HL)
        DS 2
PLresCL LD (REScall+1),HL
        LD HL,(PG8)
        PUSH BC:CALL MNG8_PL
        POP BC
        LD A,L,(REScPG+1),A
REScall CALL 0
REScPG  LD A,0
        PUSH BC:CALL MNG8_PL
        POP BC
        RET

PLresCP LD HL,PLresJP,DE,PLresAD
        LD BC,PLresLN:LDIR
        RET
;---------------------------------------
; Claude - 2026-09-25 - begin
; Конец F8/Delete (DelFl, WCFX): своя панель перечитывается, как прежде, а
; теперь и соседняя. Она могла стоять внутри удалённого дерева: её каталог —
; освобождённый кластер, панель показывала удалённые файлы, а F7/F5 в ней
; писали запись в свободное место (новый объект терялся) или — если кластер
; уже снова занят — поверх чужого файла. Первый кластер каталога соседней
; панели свободен в FAT, не начинается записями «.» (на этот же кластер) и
; «..» либо родитель из «..» на него не ссылается (кластер ушёл под файл) —
; она уходит в корень своего устройства. Если FAT или сектор не прочитать,
; проверить каталог нельзя — тоже в корень: это безопасно всегда. Проверка
; (ID_DIR_ALIVE) ловит кластер, отданный файлу, но не доказывает целостности
; тома: у «..» сверяются два байта имени и бит каталога, сам родитель (FAT,
; путь от корня) не проверяется.
; OTHER_REFRESH (без своей панели) зовёт и обработчик кода возврата плагина 3
; (PLUGIN_REFRESH): плагин мог удалить каталог через API 75 и создать файл.
DEL_REFRESH
        CALL WCFX.SEXY                          ; своя панель — как прежде
OTHER_REFRESH
        CALL WCFX.SWPPAND                       ; соседняя панель и её контекст
        LD DE,BRRR:CALL WCFX.TLSTCAT            ; BRRR — её каталог
        LD HL,(BRRR),DE,(BRRR+2)
        LD A,H:OR L,D,E:JP Z,@DELRF_SHOW        ; корень
        ; Каталог на месте: кластер занят в FAT, начинается своими «.» и «..»,
        ; и родитель на него ссылается — не ушёл под новый файл (плагин мог
        ; удалить каталог и создать файл до возврата). Не читается — в корень.
        ; Границы проверки — в заголовке выше.
        CALL @WDOS.EXTENSION_GATE
        DB @WDOS_EXT.ID_DIR_ALIVE
        JP Z,@DELRF_SHOW
        ; Хвост — «в корень» (WDOS.DELRF_ROOT, ядро) и показ панели
        ; (DELRF_SHOW, MD20): место за WCINI занято сжатым расширением.
        JP @WDOS.DELRF_ROOT

; F5 каталога (DIRCOPY, WCFX) в собственный подкаталог или в него самого уходил
; в бесконечную рекурсию: обход заходил в только что созданную копию, та росла
; дальше — до конца места, а стек индексов DIRCOPY (2 байта на уровень в
; странице TVBPG) через 8192 уровня вышел бы за #FFFF, в страницу ядра.
; Вызывается из DIRCOPY_GUARD в контексте панели назначения того же тома:
; поднимаемся от её каталога (ERRR) по «..» до корня. Встретился исходный
; каталог (BRRR — его первый кластер, записанный GETen) — копировать нельзя.
; Нет «..» — это корень, только если поиск прошёл без ошибки чтения (ABT=0) и
; текущий каталог действительно корневой (0 или BROOTC); иначе — отказ: ошибка
; или испорченный каталог не должны открывать дорогу рекурсии.
; Вход: C=0 — предел 256 шагов на случай зацикленных «..» испорченного тома.
; Выход: CF=1 — назначение внутри копируемого дерева (или сомнение), CF=0 —
; можно. Каталог панели назначения восстанавливается из ERRR.
DIRCOPY_INSIDE
        LD HL,ERRR
DCI_CHECK
        LD DE,BRRR
        LD B,4
DCI_CMP
        LD A,(DE):CP (HL):JR NZ,DCI_UP
        INC HL:INC DE:DJNZ DCI_CMP
DCI_INSIDE
        SCF:JR DCI_HOME
DCI_UP
        DEC C:JR Z,DCI_INSIDE
        PUSH BC
        LD HL,UPDIR:CALL FENTRY                 ; в #7F30 — кластер «..»
        POP BC
        JR Z,DCI_TOP                            ; «..» нет
        PUSH BC
        CALL GDIR                               ; подняться в родителя
        POP BC
        LD HL,#7F30:JR DCI_CHECK
DCI_TOP
        LD A,(@WDOS.ABT):OR A:JR NZ,DCI_INSIDE  ; ошибка чтения — отказ
        LD DE,DCI_HERE:CALL WCFX.TLSTCAT
        LD HL,(DCI_HERE+2),DE,(@WDOS.BROOTC+2)
        LD A,H:OR L:JR NZ,DCI_BROOT
        LD HL,(DCI_HERE):LD A,H:OR L:JR Z,DCI_HOME  ; 0 — корень, CF=0
DCI_BROOT
        LD HL,(DCI_HERE+2):OR A:SBC HL,DE:JR NZ,DCI_INSIDE
        LD HL,(DCI_HERE),DE,(@WDOS.BROOTC):OR A:SBC HL,DE
        JR NZ,DCI_INSIDE                        ; не корень — испорчен
DCI_HOME
        PUSH AF
        CALL WCFX.LOADCD2                       ; каталог назначения — снова ERRR
        POP AF
        RET
DCI_HERE DS 4
; Обёртки LOAD512/SAVE512 цикла F5: COPY_LOAD — в ядре, COPY_SAVE — в WCFX
; (с 2026-09-27), их общий отказ COPY_FAIL — в MD20: место за WCINI занято
; сжатым расширением.
; Claude - 2026-09-25 - end
;---------------------------------------
; Claude - 2026-09-26 - begin
; Окно хода F5 и F8 — одно на всю операцию (PBWND). Прежде после Enter
; диалог (F5WND) оставался с кнопками [OK]/[CANCEL] (при F8 — с «Deleting is
; in Progress!»), пока ищутся файлы и читается FAT (у большого файла —
; секунды без перемен), а при F5 окно полосы открывалось и закрывалось
; поверх диалога на каждом файле, и полоса каждый раз начиналась с нуля —
; мигала. Теперь заголовок «COPY»/«DELETE»; строка 2 — «Copying started...»
; / «Deleting started...», как пошло дело — «Copying имя»/«Deleting имя»;
; строка 3 — «<n of M>»; строка 5 — полоса по всей операции (CP_TOTAL);
; строки 1 и 4 пустые. Полоса только растёт. Окно закрывает CPgo/DLgo;
; отказы его не закрывают, сообщения об ошибках и «Abort operation?»
; открываются поверх.
; Claude - 2026-09-28 - begin
; Окно — CP_W+2 на 7 по центру экрана (прежде 66×5, строки подряд без
; отступов): текст и полоса — CP_W знаков. Счёт полосы — в 64-х долях, как
; прежде; клетки — 64-е доли·CP_W/64 (CP_DRAW).
CP_W     EQU 40
; Claude - 2026-09-28 - end

CP_STARTED
        DB #0D,#0E,"Copying started...",0      ; #0D — строка 2; 18 знаков: в поле 40 отступы по 11
DL_STARTED
        DB #0D,#0E,"Deleting started...",0
; Режим окна: заголовок, строка «... started...», длина и текст префикса
; строки имени — префикс кладётся прямо перед CP_NAME.
CP_KIND_COPY
        DW @TXT8,CP_STARTED
        DB 8,"Copying "
CP_KIND_DEL
        DW @TXTB,DL_STARTED
        DB 9,"Deleting "
CP_OPEN  DB 0                           ; 1 — окно хода открыто (FLOF пишет в него)
CP_STATE DB 0                           ; 0 — в строке 1 ещё «... started...»
CP_BAR   DB 0                           ; нарисованная часть полосы в 64-х долях
CP_NUM   DW 0                           ; сколько файлов операции начато (n)
CP_FILES DW 0                           ; сколько их всего (M, CP_COUNT); 0 — не посчитаны
CT_SP    DW 0                           ; вершина стека индексов обхода CT_TREE
CP_LINE  DW 0                           ; строка 2: префикс и сразу за ним имя
        ASSERT (TXTBU & #FF) + CP_W/2 < #100, в CP_CENTER TXTBU+отступ переносит старший байт
CP_NAME  EQU LOBU+512                   ; имя (до 56 знаков, 0 за ним): FLOF, CP_FILE

; CPGO/DLGO (IX = диалог F5WND): YN(#FF) — NZ, если выбрана [CANCEL]. Иначе
; закрыть диалог и открыть окно хода с пустой полосой; выход Z.
CP_GO
        LD HL,CP_KIND_COPY
        JR CP_WINDOW
DL_GO
        LD HL,CP_KIND_DEL
CP_WINDOW
        PUSH HL
        LD A,#FF:CALL @YN
        POP HL
        RET NZ
        LD DE,@PBWND+12:LDI:LDI           ; заголовок
        LD DE,@PBWND+16:LDI:LDI           ; «... started...»
        LD C,(HL):INC HL:LD B,0           ; префикс имени — прямо перед CP_NAME
        PUSH HL
        LD HL,CP_NAME:OR A:SBC HL,BC:LD (CP_LINE),HL
        EX DE,HL
        POP HL:LDIR
        CALL RRESB                       ; диалог
        XOR A:LD (CP_STATE),A
        INC A:LD (CP_OPEN),A
; Claude - 2026-09-28 - begin
; X/Y 255 — по центру экрана. PRWOW заменяет их вычисленными, и без этого
; окно после смены текстового режима осталось бы на прежнем месте.
        LD HL,#FFFF:LD (@PBWND+2),HL
; Claude - 2026-09-28 - end
        PUSH IX
        LD IX,@PBWND:CALL PRWOW          ; заголовок и «... started...»
        POP IX
        XOR A:LD (CP_BAR),A
        CALL CP_DRAW                     ; пустая полоса
        XOR A
        RET

; CPgo: конец F5 — закрыть окно хода (IX сохраняет вызывающий). Z — все
; объекты пройдены: полоса сначала до конца (у последнего каталога своя доля
; иначе не закрылась бы, Codex R20-03); NZ — отказ или отмена.
CP_CLOSE
        LD A,64:CALL Z,CP_DRAW
; DLgo: конец F8 — без дорисовки: «DIR is not empty!» (NED) удаление не
; прерывает, и Z в конце F8 успеха всех объектов не значит (Codex R21-02).
DL_CLOSE
        XOR A:LD (CP_OPEN),A
        LD IX,@PBWND:JP RRESB

; FLOF (имя — в CP_NAME): строка 2 — «<n of M>» (CP_COUNTER: с 2026-09-27
; — файлы операции, прежде — номер объекта панели, у каталога «1 of 1» на всё
; дерево), полоса — по пройденным файлам; строка 1 — «Copying имя»/«Deleting
; имя» со второго объекта или когда дело уже пошло (у первого, пока ищутся
; файлы и читается FAT, там «... started...»); выход NZ. Окна хода нет: выход
; Z, HL=TXTBU, B=32 — FLOF продолжает прежний вывод в диалог F5WND.
CP_FLOF
        LD A,(CP_OPEN):OR A
        LD HL,TXTBU:LD B,32
        RET Z
        CALL CP_COUNTER
        LD A,64:CALL CP_TOTAL
        LD HL,(@MRRN):DEC HL:LD A,H:OR L
        LD HL,CP_STATE:OR (HL)
        JR Z,CP_FLOF_OUT                 ; первый объект, дело ещё не пошло
        LD (HL),1
        CALL CP_SHOW_NAME
CP_FLOF_OUT
        OR 1
        RET

; Файл начат (COPYFD, DL_INNER, DL_DELFILE): HL=0 — отмеченный файл (имя уже
; в CP_NAME — FLOF); иначе HL — имя файла каталога (COPYFD: TXTBU, DL_INNER:
; запись DIRTREM) — сперва в CP_NAME: строка 2 и полоса собираются в том же
; TXTBU. Затем n+1, строка 2, полоса — на начало доли файла, имя — в строку 1.
CP_FILE
        LD A,H:OR L:JR Z,CP_FILE_COUNT
        LD DE,CP_NAME:LD B,56
CP_FILE_COPY
        LD A,(HL):OR A:JR Z,CP_FILE_PAD
        LD (DE),A:INC HL:INC DE:DJNZ CP_FILE_COPY
        JR CP_FILE_COUNT
CP_FILE_PAD
        EX DE,HL:CALL NOPING             ; остаток имени — нули, как у FLOF
CP_FILE_COUNT
        LD HL,(CP_NUM):INC HL
        LD A,H:OR L:JR Z,CP_FILE_MANY    ; больше 65535 — не считать дальше
        LD (CP_NUM),HL
CP_FILE_MANY
        CALL CP_COUNTER
        XOR A:CALL CP_TOTAL
        LD A,(CP_STATE):OR A:RET Z       ; ещё «... started...»
        JR CP_SHOW_NAME

; DIRTREM (F8 каталога): удалить файл HL → [тип, имя, 0] — как DELFL, Z —
; отказ. До удаления — n+1 и имя, после — доля файла полная; первое
; удалённое переключает строку 1 на имена.
DL_INNER
        PUSH HL
        INC HL:LD A,4:CALL CP_FILE
        POP HL
        CALL WCFX.DELFL:JR Z,DL_INNER_FAIL
        CALL CP_ACTIVE
        LD A,64:CALL CP_TOTAL
        OR 1
        RET
; DELF (F8 отмеченного файла): n+1 и строка 2, удаление (DL_DELETE); удалён —
; строка 1 — имена, доля файла полная. Выход — как у DL_DELETE: Z — удалено.
DL_DELFILE
        PUSH HL
        LD HL,0:CALL CP_FILE
        POP HL
        CALL DL_DELETE
        RET NZ
        CALL CP_ACTIVE
        LD A,64:CALL CP_TOTAL
        XOR A
        RET
; Claude - 2026-09-27 - begin
; DELFL отказал (Z). A=8 при ABT=0 — записи нет: Z, DFILES пишет «File not
; found» (B=8), как прежде. A=8 при ABT≠0 — поиск (SRHDRN в DELEN) не прочитал
; каталог (Codex R30-01); A=0 — отказ записи каталога (DELEN) или
; освобождения цепочки (DLSG: недопустимая ссылка, за томом, первый кластер
; корня, Codex R29-02). Это не «File not found»: «UNKNOWN ERROR!!» здесь же
; (TREE_STOP), возврат — в DTRER0 с B=255, второго сообщения нет. ABT —
; страницы ФС, где работал DELFL (перечисление в копии уже снято CLONOFF).
DL_INNER_FAIL
        CP 8:JR NZ,DL_INNER_ERROR
        LD A,(@WDOS.ABT):OR A:RET Z
DL_INNER_ERROR
        LD HL,WCFX.DTRER0
        JP TREE_STOP
; DDIRS (F8 опустевшего подкаталога дерева): удалить его запись и цепочку
; (@DIRTREM_DELETE → DELFL). Отказ — как у файла (DL_INNER_FAIL): имени нет —
; Z, у DDIRS «DIR not found (dst)» (B=3), как прежде; отказ чтения, записи или
; освобождения цепочки — «UNKNOWN ERROR!!» (Codex R31-01).
DL_DIRDEL
        CALL @DIRTREM_DELETE
        RET NZ
        JR DL_INNER_FAIL
; Claude - 2026-09-27 - end

; COPYF_DATA_DONE: доля файла полная (у пустого файла порций не было);
; сначала строка 1, потом полоса.
CP_DONE
        CALL CP_ACTIVE
        LD A,64:JR CP_ENTRY
; Дело пошло: «... started...» сменяется «Copying имя»/«Deleting имя».
CP_ACTIVE
        LD A,(CP_STATE):OR A:RET NZ
        INC A:LD (CP_STATE),A
; Строка 2: префикс и имя текущего файла — по центру, как весь текст окна.
CP_SHOW_NAME
        LD HL,(CP_LINE):PUSH HL
        LD DE,CP_W:ADD HL,DE:LD (HL),0   ; префикс и имя — не длиннее CP_W знаков
        POP HL:LD D,2
; Строка D окна хода: текст HL (0 в конце, до CP_W знаков) по центру. Строка
; собирается целиком в TXTBU и пишется одной записью: без промежуточной
; очистки, которая мигала бы пустой строкой при смене имени.
CP_CENTER
        PUSH DE
        PUSH HL
        XOR A:LD BC,CP_W+1:CPIR          ; C = CP_W - длина
        LD A,C:SRL A:PUSH AF             ; отступ слева
        LD HL,TXTBU:LD B,CP_W:LD A," ":CALL NOPING+1
        POP AF:LD HL,TXTBU
        ADD A,L:LD E,A:LD D,H            ; TXTBU+отступ: младший байт не переносится
        POP HL
CP_CENTER_COPY
        LD A,(HL):OR A:JR Z,CP_CENTER_OUT
        LDI:JR CP_CENTER_COPY
CP_CENTER_OUT
        POP DE:LD E,1
        LD HL,TXTBU
; CP_W знаков из HL — в строку D, столбец E окна хода.
CP_PRINT
        PUSH IX
        LD IX,@PBWND
        LD BC,CP_W:CALL @PRSRW
        POP IX
        RET

; PBPR: A — доля файла в 64-х по уже переданному. До конца передачи — не
; больше 63: полная доля — только в CP_DONE, по концу файла (Codex R23-02:
; перед последней порцией файла k·16384+1…63 байт выходило ровно 64, и при
; её отказе полоса оставалась полной). Файл короче 64 байт: делитель
; размер/64 — ноль, вычитание нуля доводило долю до 64; до его единственной
; порции — 0.
CP_PART
        CP 64:JR C,CP_ENTRY
        LD HL,(WCFX.PBSTL+1):LD A,H:OR L
        LD HL,(WCFX.PBSTH+1):OR H:OR L
        JR Z,CP_ENTRY                    ; делитель 0: A=0
        LD A,63
; A — доля текущего файла в 64-х (CP_PART, CP_DONE, CP_FILE, CP_FLOF). Файлы
; операции (CP_COUNT) делят полосу поровну: до файла n (CP_NUM) — 64·(n-1)/M,
; его доля — по A. Прежде полосу делили объекты панели, а внутри каталога шли
; ступени 64·j/(j+8): числа файлов дерева WC не знал. n=0 или M=0 (не
; посчитаны) — полоса пустая.
CP_ENTRY
CP_TOTAL
        LD C,A
        LD HL,(CP_NUM)
        LD A,H:OR L
        JR Z,CP_DRAW                     ; A=0
        PUSH BC
        DEC HL
        LD DE,(CP_FILES):CALL WCFX.CP_MUL64DIV  ; начало доли файла (M=0 — 0)
        LD B,A:PUSH BC
        LD HL,(CP_NUM)
        LD DE,(CP_FILES):CALL WCFX.CP_MUL64DIV  ; её конец
        POP BC:SUB B                     ; ширина доли
        POP DE                           ; E — доля файла
        PUSH BC:CALL CP_SCALE:POP BC
        ADD A,B
; Полоса: A — заполненная часть в 64-х долях (CP_BAR хранит её же); клеток
; A·CP_W/64 — #DB, остальные — #B1; строка 5 окна хода. Больше 64 не
; бывает, но и тогда за строку TXTBU (CP_W байт) не писать.
CP_DRAW
        CP 65:JR C,CP_DRAW_UP
        LD A,64
CP_DRAW_UP                               ; полоса только растёт: больше 65535
        LD HL,CP_BAR:CP (HL)             ; файлов начало доли 65535-го (63)
        JR NC,CP_DRAW_NEW                ; шло бы назад от 64 (Codex R37-2)
        LD A,(HL)
CP_DRAW_NEW
        LD (HL),A
CP_DRAW_OK
; Claude - 2026-09-28 - begin
        LD E,CP_W:CALL CP_SCALE          ; клетки: 64 → CP_W, 63 → CP_W-1
; Claude - 2026-09-28 - end
        LD HL,TXTBU:LD C,CP_W
        OR A:JR Z,CP_DRAW_REST
        LD B,A
CP_DRAW_FULL
        LD (HL),#DB:INC HL:DEC C:DJNZ CP_DRAW_FULL
CP_DRAW_REST
        LD A,C:OR A:JR Z,CP_DRAW_OUT
        LD B,A:LD A,#B1:CALL NOPING+1
CP_DRAW_OUT
        LD HL,TXTBU:LD DE,#0501
        JP CP_PRINT                      ; JR не достаёт через CP_PART

; Строка 3 окна хода: «<n of M>» — номер начатого файла и число файлов
; операции (CP_COUNT); больше 9999 — 9999. Не посчитаны (M=0) — «of ????».
CP_COUNTER
        LD HL,(CP_NUM):LD DE,@TXT10+2:CALL CP_DEC4
        LD HL,(CP_FILES):LD DE,@TXT10+10
        LD A,H:OR L:JR NZ,CP_COUNTER_M
        EX DE,HL:LD B,4:LD A,"?":CALL NOPING+1
        JR CP_COUNTER_OUT
CP_COUNTER_M
        CALL CP_DEC4
CP_COUNTER_OUT
        LD HL,@TXT10+1:LD D,3:JP CP_CENTER      ; без #0E — центрует CP_CENTER
CP_DEC4                                  ; HL — число, DE — его 4 знака
        PUSH DE
        LD DE,10000:OR A:SBC HL,DE:ADD HL,DE
        POP DE
        JP C,WCFX.DECZ2
        LD HL,9999
        JP WCFX.DECZ2

; A = A·E/64 (A, E не больше 64).
CP_SCALE
        LD HL,0:LD D,H
        OR A:RET Z
        LD B,A
CP_SCALE_ADD
        ADD HL,DE:DJNZ CP_SCALE_ADD
        ADD HL,HL:ADD HL,HL              ; H = (A·E)/64
        LD A,H
        RET

; DELDIR (F8), проверка пустоты: третьей записи нет — каталог пуст, удалить
; (DL_EMPTY, затем DL_DELETE); есть третья или нет «.»/«..» — «DIR is not
; empty!» (DL_NED), F8 идёт дальше. Z перечисления бывает и при отказе
; чтения, ABT≠0 (Codex R23-01): тогда ни удаления, ни «не пуст» — «UNKNOWN
; ERROR!!» и NZ, F8 останавливается. Каталог панели (LOADCD) — до всего.
DL_NED
        CALL DL_LOADCD
        JR NZ,DL_FAIL
        LD HL,@TER30:CALL WCFX.ERR0
        XOR A
        RET
; LOADCD; выход NZ — перечисление перед ним отказало (ABT взят до LOADCD).
DL_LOADCD
        LD A,(@WDOS.ABT):OR A
        PUSH AF
        CALL WCFX.LOADCD
        POP AF
        RET
DL_EMPTY
        CALL DL_LOADCD
        JR NZ,DL_FAIL
        LD HL,LOBU+4
; DELF и DELDIR (F8): удалить объект HL → [тип, имя, 0] (DELFL ядра); Z —
; удалено. Отказ — «UNKNOWN ERROR!!» и NZ: F8 останавливается. Прежде DELDIR
; результат не проверял — F8 шёл дальше, будто каталог удалён (Codex R21-02),
; а DELF останавливался молча. DL_FAIL — и для отказа поиска в DELDIR.
DL_DELETE
        CALL WCFX.DELFL
        JR Z,DL_FAIL
        XOR A
        RET
DL_FAIL
        LD HL,@TER2X:CALL WCFX.ERR0
        XOR A:INC A
        RET

; Claude - 2026-09-27 - begin
; DL_ALIAS (F8, WCFX.DLGO — до первого удаления; Codex R27-04, частичная
; защита): отмеченный объект панели не делит кластеров с неотмеченной записью
; того же каталога. Испорченная запись на первом кластере соседа (или
; каталог, чья цепочка проходит через первый кластер соседа, через «.» или
; «..» каталога панели) вела F8 по чужим данным: освобождались цепочки и
; удалялись файлы невыбранного объекта. Первые кластеры отмеченных (у
; каталогов — и хвост цепочки) — в таблицу расширения (ID_ALIAS_ADD), затем
; проход по записям каталога на носителе (ID_ALIAS_SCAN, DL_SCAN). Нарушение
; или отказ чтения — «UNKNOWN ERROR!!» (DL_FAIL), F8 ничего не удаляет. Общие
; кластеры с записями других каталогов и слияние цепочек не в первом
; кластере так не ловятся (docs/01, 7.1). IX — панель. Выход: Z — можно
; удалять; NZ — сообщение показано.
DL_ALIAS
        XOR A                            ; начало: прежнее продолжение хвоста забыть
        CALL DL_ALIAS_RESET
        LD HL,0                          ; номер записи панели
DL_ALIAS_NEXT
        PUSH HL
        CALL @GETen                      ; как LENIN2: HL — запись (0 — конец),
        EXA                              ; A — признак (0 — каталог), кластер — BRRR
        LD A,H:OR L:JR Z,DL_ALIAS_LAST
        BIT 0,(HL):JR Z,DL_ALIAS_SKIP    ; не отмечена
        EXA
        LD HL,(@BRRR),DE,(@BRRR+2)       ; DE:HL — первый кластер
        CALL @WDOS.EXTENSION_GATE
        DB @WDOS_EXT.ID_ALIAS_ADD
        JR C,DL_ALIAS_FULL
        JR NZ,DL_ALIAS_END               ; FAT хвоста каталога не читается
DL_ALIAS_SKIP
        POP HL
        INC HL
        JR DL_ALIAS_NEXT
DL_ALIAS_FULL                            ; таблица полна: проверить, опустошить
        CALL DL_SCAN:JR NZ,DL_ALIAS_END  ; и тот же объект — ещё раз (хвост
        LD A,1                           ; каталога продолжится)
        CALL DL_ALIAS_RESET
        POP HL
        JR DL_ALIAS_NEXT
DL_ALIAS_LAST
        CALL DL_SCAN
DL_ALIAS_END
        POP HL
        JR NZ,DL_FAIL
        JP CP_COUNT                      ; можно удалять: сначала счёт файлов (Z)
DL_ALIAS_RESET
        CALL @WDOS.EXTENSION_GATE
        DB @WDOS_EXT.ID_ALIAS_RESET
        RET
; ID_ALIAS_SCAN порциями: между ними EI:HALT — кадр обработчику IM2.
DL_SCAN
        XOR A                            ; начало прохода
DL_SCAN_PART
        CALL @WDOS.EXTENSION_GATE
        DB @WDOS_EXT.ID_ALIAS_SCAN
        RET NC
        EI:HALT
        JR DL_SCAN_PART                  ; A=1 — продолжение

; Счёт файлов операции F5/F8 — до первого действия (WCFX.CPGO, DL_ALIAS): окно
; хода показывает «<n of M>» — номер начатого файла и число файлов всей
; операции. Прежде там был номер объекта панели: у каталога «0001 of 0001» на
; всё дерево. Отмеченный файл — один; каталог — все файлы его дерева
; (CT_TREE, только чтение). Отказ чтения или порча дерева — счёт бросается
; (M=0: «of ????»), саму ошибку покажет операция. IX — панель. Выход: HL=0
; (для LENIN), Z (для DL_ALIAS).
CP_COUNT
        LD HL,0
        LD (CP_NUM),HL
        LD (CP_FILES),HL
CP_COUNT_NEXT
        PUSH HL
        CALL @GETen                      ; HL — запись (0 — конец), A — тип (0 — каталог)
        EXA
        LD A,H:OR L:JR Z,CP_COUNT_END
        BIT 0,(HL):JR Z,CP_COUNT_SKIP    ; не отмечена
        EXA:OR A:JR NZ,CP_COUNT_FILE
        CALL WCFX.NAMEBG                 ; LOBU+4 — [тип, имя] (DE — от GETen)
        CALL CT_TREE
        JR NC,CP_COUNT_SKIP
        LD HL,0:LD (CP_FILES),HL         ; счёт брошен
        JR CP_COUNT_END
CP_COUNT_FILE
        CALL CT_ONE
CP_COUNT_SKIP
        POP HL
        INC HL
        JR CP_COUNT_NEXT
CP_COUNT_END
        POP HL
        LD HL,0
        XOR A
        RET
CT_ONE
        LD HL,(CP_FILES):INC HL
        LD A,H:OR L:RET Z                ; больше 65535 — не считать дальше
        LD (CP_FILES),HL
        RET

; Файлы дерева каталога LOBU+4 — к CP_FILES. Обход — как у копии (IDXLOOP),
; только источник: стек индексов в странице TVBPG (#C000..), у каталога —
; число пройденных записей; после подъёма («..») перечисление каталога идёт
; заново до этого числа. Вход в подкаталог — с той же проверкой, что у обхода
; F5/F8 (ID_TREE_CHILD). Каталог панели — как был (SAVECD/LOADCD). Выход:
; CF=1 — счёт брошен (ABT сброшен: отказ покажет сама операция).
CT_TREE
        CALL WCFX.SAVECD
        LD HL,#C000
        LD (CT_SP),HL
        LD HL,LOBU+4
CT_DOWN                                  ; HL — [тип, имя] каталога
        CALL WCFX.FENTRY:JP Z,CT_FAIL    ; нет или не прочитан
        LD HL,(FOUND_CLUSTER),DE,(FOUND_CLUSTER+2)
        CALL @WDOS.EXTENSION_GATE
        DB @WDOS_EXT.ID_TREE_CHILD
        JP NZ,CT_FAIL                    ; не настоящий подкаталог
        CALL WCFX.GDIR
        CALL WCFX.RECBUF
        LD HL,(CT_SP)
        LD (HL),2:INC HL:LD (HL),0       ; «.» и «..» — пропустить
        CALL WCFX.CLONEZ
        LD DE,LOBU+1024
        PUSH DE:XOR A:CALL WCFX.NXTETY2
        POP DE:XOR A:CALL WCFX.NXTETY2
CT_LOOP
        CALL WCFX.RECBUF
        LD HL,(CT_SP)
        INC (HL):JR NZ,CT_READ
        INC HL:INC (HL)
        JR Z,CT_FAIL                     ; больше 65535 записей: после подъёма
                                         ; счёт пропуска вернулся бы к «.» и «..» —
                                         ; бесконечный обход (Codex R37-1)
CT_READ
        CALL WCFX.CLPG
        LD DE,LOBU+4
        XOR A:CALL CT_NEXT
        JR C,CT_FAIL
        JR Z,CT_UP
        LD HL,LOBU+4
        LD A,(HL):AND #10:LD (HL),A
        JR NZ,CT_SUB
        CALL CT_ONE
        JR CT_LOOP
CT_SUB
        LD HL,(CT_SP)
        INC HL:INC HL
        LD A,H:OR L:JR Z,CT_FAIL         ; стек — до #FFFF
        LD (CT_SP),HL
        LD HL,LOBU+4
        JR CT_DOWN
CT_UP
        LD HL,(CT_SP)
        LD A,L:OR A:JR NZ,CT_POP
        LD A,H:CP #C0:JR Z,CT_DONE       ; вершина — сам каталог
CT_POP
        DEC HL:DEC HL
        LD (CT_SP),HL
        LD HL,@UPDIR
        CALL WCFX.FENTRY:JR Z,CT_FAIL
        CALL WCFX.GDIR
        CALL WCFX.CLONEZ
        CALL WCFX.RECBUF
        LD HL,(CT_SP)
        LD C,(HL):INC HL:LD B,(HL)
CT_SKIP                                  ; до записи, с которой ушли вниз
        LD DE,LOBU+1024
        PUSH BC
        CALL WCFX.CLPG
        XOR A:CALL CT_NEXT
        POP BC
        JR C,CT_FAIL
        JR Z,CT_FAIL                     ; записей меньше — не то дерево
        DEC BC:LD A,B:OR C:JR NZ,CT_SKIP
        JR CT_LOOP
CT_DONE
        CALL WCFX.LOADCD
        OR A
        RET
CT_FAIL
        XOR A:LD (@WDOS.ABT),A
        CALL WCFX.LOADCD
        SCF
        RET
; Следующая запись (NXTETY2 в копии страницы ФС, затем CLONOFF, как CP_NEXT),
; без сообщения: NZ — запись; Z, CF=0 — конец каталога; CF=1 — отказ чтения.
CT_NEXT
        CALL WCFX.NXTETY2
        JR Z,CT_NEXT_END
        OR 1
        JP WCFX.CLONOFF                  ; флаги сохраняет
CT_NEXT_END
        LD A,(@WDOS.ABT):OR A
        JP Z,WCFX.CLONOFF
        SCF
        JP WCFX.CLONOFF
; Claude - 2026-09-27 - end

; Обход дерева F8 (DFILES, NODIRS) и F5 (IDXLOOP): Z перечисления каталога —
; конец, но так же выглядит и отказ чтения: NXTINI/NXMR ядра ставят ноль в
; начало непрочитанного, признак — ABT страницы, где шло перечисление
; (Codex R23-01: F8 принимал отказ за конец и удалял подкаталог с
; непройденными файлами — их цепочки терялись без сообщения; F5 так же
; молча копировал дерево не целиком). Отказ — «UNKNOWN ERROR!!» и переход
; вместо возврата в DTRER0 (F8) или ERMAIN (F5) с B=255: сообщение уже
; показано, каталоги панелей они восстанавливают, операция останавливается.
;
; DL_NEXT (DFILES) и CP_NEXT (IDXLOOP): NXTETY2 (A — маска, DE — буфер) в
; копии страницы ФС (CLPG), затем CLONOFF, как прежде; ABT копии виден только
; до CLONOFF. Выход: Z — конец каталога, NZ — запись.
DL_NEXT
        LD HL,WCFX.DTRER0
        JR TREE_NEXT
CP_NEXT
        LD HL,WCFX.ERMAIN
TREE_NEXT
        PUSH HL
        CALL WCFX.NXTETY2
        POP HL
        JR NZ,TREE_OUT                   ; запись
        LD A,(@WDOS.ABT):OR A
        JR NZ,TREE_FAIL
TREE_OUT
        JP WCFX.CLONOFF                  ; флаги сохраняет
; NODIRS (F8): подкаталогов больше нет — если перечисление (в своей странице)
; не отказало; тогда HL = «..» для FENTRY, как прежде.
DL_UP
        LD HL,WCFX.DTRER0
        LD A,(@WDOS.ABT):OR A
        JR NZ,TREE_STOP
        LD HL,@UPDIR
        RET
; Claude - 2026-09-27 - begin
; ZANOVO (F8) и ZANOVOC (F5): найти каталог дерева (FENTRY; HL — [тип, имя,
; 0]) и проверить его перед входом (GDIR): первый сектор — «.» на этот же
; кластер и «..» на текущий каталог (ID_TREE_CHILD расширения). Испорченная
; запись вела обход не туда: кластер 0 GLSTCAT понимает как корень (так
; задумано для «..»), и F8 одного такого каталога удалял неотмеченные файлы
; корня, F5 копировал корень (проба 2026-09-27); кластер корня — так же;
; кластер чужого каталога — по чужому дереву. Такой каталог (и отказ чтения
; при проверке) — «UNKNOWN ERROR!!» и выход, как у TREE_FAIL (DTRER0 или
; ERMAIN с B=255). Не найден — Z, как прежде (B=1 у вызывающего); найден и
; настоящий — NZ. Поиск не прочитал каталог (ABT≠0) — тоже «UNKNOWN ERROR!!»,
; а не «DIR not found (src)» (TREE_NOT_FOUND, Codex R31-01).
DL_ENTER
        LD DE,WCFX.DTRER0
        JR TREE_ENTER
CP_ENTER
        LD DE,WCFX.ERMAIN
TREE_ENTER
        PUSH DE
        CALL WCFX.FENTRY
        POP DE
        JR Z,TREE_NOT_FOUND
        PUSH DE
        LD HL,(FOUND_CLUSTER),DE,(FOUND_CLUSTER+2)
        CALL @WDOS.EXTENSION_GATE
        DB @WDOS_EXT.ID_TREE_CHILD
        POP HL                           ; обработчик ошибки
        JR NZ,TREE_STOP                  ; не настоящий подкаталог
        OR 1                             ; найден и проверен: NZ
        RET
; Claude - 2026-09-27 - begin
; FENTRY не нашёл (Z): имени нет (ABT=0) — Z, «DIR not found (src)» у
; вызывающего (B=1), как прежде; поиск не прочитал каталог (ABT≠0 страницы, где
; искали) — «UNKNOWN ERROR!!» (TREE_STOP; обработчик — DE).
TREE_NOT_FOUND
        LD A,(@WDOS.ABT):OR A:RET Z
        EX DE,HL
        JR TREE_STOP
; Claude - 2026-09-27 - end
FOUND_CLUSTER EQU #7F30                  ; кластер записи, найденной FENTRY (MD20)
; COPYFD (F5 файла): источник найден (FENTRY: первый кластер — #7F30, размер —
; LOBU+1..4). До создания копии — цепочка файла цела на всю длину данных
; (ID_FILE_CHAIN): кластеры заняты, ссылки допустимы и в томе, цепочка не
; короче размера. Иначе порча — «UNKNOWN ERROR!!», F5 файла не идёт: прежде
; кластер цепочки, помеченный свободным, MKFILE отдавал копии — источник и
; копия делили кластер, часть копии — чужие байты, без сообщения (проба
; 2026-09-27); у короткой цепочки копия добиралась прежним буфером. Цела —
; GFILE, как прежде. Проверка идёт порциями (WCFX.FC_LOOP, между ними — кадр
; IM2); отказ — CP_BAD.
CP_SOURCE
        LD HL,FOUND_CLUSTER
        LD DE,LOBU+1
        XOR A                            ; первый вызов FILE_CHAIN
        JP WCFX.FC_LOOP
CP_BAD  POP HL                           ; возврат в COPYFD
        LD HL,@TER2X
        JP WCFX.CE0                      ; сообщение и NZ из COPYF
; Claude - 2026-09-27 - end
TREE_FAIL                                ; из копии страницы ФС (DL_NEXT, CP_NEXT)
        CALL WCFX.CLONOFF
; Выход с ошибкой: HL — обработчик. На первом входе ZANOVO копии ещё нет, и
; FEP2 может быть чужим: CLONOFF — только после CLPG (TREE_FAIL).
TREE_STOP
        EX (SP),HL                       ; возврат — в обработчик ошибки
        LD HL,@TER2X:CALL WCFX.ERR0
        LD B,255
        RET
; Claude - 2026-09-26 - end
