; device.inc — устройство: загрузочное, страница драйвера, проверка и
; ёмкость, обмен секторами, перемонтирование панелей.

; Загрузочное устройство WC: ячейка CMOS #B2 (её пишет BIOS Evo; так же GBD
; в MD20) -> номер DOS_SWP (L6011_206): 0 SD1, 1 Nemo, 2 Nemo slave, 3 SD1,
; 4 SMUC, 5 SMUC slave, 6 SD2; иное — #FF.
BootDevice:
        LD BC,#DFF7
        LD A,#B2
        OUT (C),A
        LD B,#BF
        IN A,(C)
        CP 7
        LD B,#FF
        JR NC,.store
        LD HL,BootMap
        LD E,A
        LD D,0
        ADD HL,DE
        LD B,(HL)
.store: LD A,B
        LD (BootDev),A
        RET
BootMap:        DB DEV_SD1,DEV_NEMO,DEV_NEMO2,DEV_SD1,DEV_SMUC,DEV_SMUC2,DEV_SD2

; --- страница драйвера (страница плагина 1 в W0) --------------------------

; Номер физической страницы 1 плагина и её заполнение копией страницы
; активной панели (рабочее состояние WildDOS, как у Chkdsk). Окно #C000
; потом снова — текстовый экран.
ScratchClone:
        LD A,1
        EX AF,AF'
        LD A,0                          ; MNGC_PL: страница 1 плагина в #C000
        CALL WLD
        LD A,(WC_PG3)
        LD (ScratchPg),A
        LD IX,(PanelIX)
        LD A,PNLPG
        ADD A,(IX+PANEL_PAGE)
        DI
        CALL MapW0
        LD HL,#0000
        LD DE,#C000
        LD BC,#4000
        LDIR
        CALL ProtectW0
        LD A,#FE
        EX AF,AF'
        LD A,0                          ; снова основной TXT в #C000
        CALL WLD
        EI
        RET

; Страница A — в W0 для обмена (как MNG0I WC: #21AF = #0E).
MapW0:
        LD (WC_PG0),A
        LD BC,PORT_W0
        OUT (C),A
        LD BC,PORT_MEMCFG
        LD A,%00001110
        OUT (C),A
        RET
MapScratch:
        LD A,(ScratchPg)
        CALL MapW0
; Перед обменом: кэш только у W1 (маска WC), прежний DMA закончен.
BusIdle:
        LD BC,PORT_CACHE
        LD A,CACHE_WC
        OUT (C),A
        LD BC,PORT_DMA
.dma:   IN A,(C)
        RLCA
        JR C,.dma
        RET
; W0 — снова страница, что была при входе в плагин, и ОЗУ в окне (#21AF =
; #0E, как MNG0I): WC работает так всегда, а MNG0 меняет только номер
; страницы. #01 (ПЗУ в W0, MNG0D) WC ставит только перед запуском SPG; с ним
; после возврата WC читал пути и каталоги панелей из ПЗУ.
ProtectW0:
        LD A,(SavedPg0)
        LD (WC_PG0),A
        LD BC,PORT_W0
        OUT (C),A
        LD BC,PORT_MEMCFG
        LD A,%00001110
        OUT (C),A
        RET

; --- проверка выбранного устройства ---------------------------------------

; Dev — номер DOS_SWP. Драйвер в странице плагина, DEVINI, ёмкость. Выход:
; CF=0 — DevKind, DevSize (у CHS — DevHeads, DevSpt, Cylinders), Model;
; CF=1 — сообщение показано.
Probe:
        LD HL,MsgChecking
        CALL ShowBusy
        CALL ScratchClone
        CALL MapScratch
        LD A,(Dev)
        EI                              ; NeoGS ждёт ответа HALT'ами
        CALL CORE_DOS_SWP
        CALL CORE_DEVINI
        JR NZ,.missing
        LD A,(Dev)
        CP DEV_SD1
        JR Z,.sd
        CP DEV_SD2
        JR Z,.sd
        CP DEV_NGS
        JR Z,.ngs
        LD HL,DRV_LOBU                  ; IDENTIFY драйвера IDE
        LD DE,ID_BUF
        LD BC,512
        LDIR
        CALL ProtectW0
        EI
        CALL ParseIdentify
        JR C,.badsize
        OR A
        RET
.sd:    DI
        CALL ReadCsd
        CALL ProtectW0
        EI
        JR C,.nocsd
.sdkind:
        LD A,KIND_SD
        LD (DevKind),A
        OR A
        RET
        ; NeoGS: CSD отдаёт своя программа (NgsCsd), служба WC в NeoGS при
        ; этом замещается — её ставят заново DOS_SWP и DEVINI.
.ngs:   CALL ProtectW0
        CALL NgsCsd
        PUSH AF
        CALL MapScratch
        LD A,DEV_NGS
        EI
        CALL CORE_DOS_SWP
        CALL CORE_DEVINI
        CALL ProtectW0
        EI
        JR NZ,.ngslost
        POP AF
        JR C,.nocsd
        CALL ParseCsd
        JR C,.nocsd
        JR .sdkind
.ngslost:
        POP AF
        JR .missing
.missing:
        CALL ProtectW0
        LD HL,MsgMissing
        JR .error
.nocsd: LD HL,MsgNoCsd
        JR .error
.badsize:
        LD HL,MsgBadSize
.error: EI
        CALL ShowError
        SCF
        RET

; IDENTIFY (ID_BUF): слово 49 бит 9 — LBA28 (слова 60-61), иначе CHS: слова
; 1 (цилиндры), 3 (головки), 6 (секторы). Модель — слова 27-46 (байты в
; словах переставлены). CF=1 — ёмкость нулевая или геометрия не та, что
; принимает драйвер (головок 1..16, секторов 1..127).
ParseIdentify:
        LD HL,ID_BUF+54
        LD DE,Model
        LD B,20
.swap:  INC HL
        LD A,(HL)
        LD (DE),A
        INC DE
        DEC HL
        LD A,(HL)
        LD (DE),A
        INC DE
        INC HL
        INC HL
        DJNZ .swap
        LD B,40                         ; длина без хвостовых пробелов
        LD HL,Model+39
.trim:  LD A,(HL)
        CP 33
        JR NC,.trimmed
        DEC HL
        DJNZ .trim
.trimmed:
        LD A,B
        LD (ModelLen),A
        LD A,(ID_BUF+99)
        AND 2
        JR Z,.chs
        LD A,KIND_LBA
        LD (DevKind),A
        LD HL,ID_BUF+120
        LD DE,DevSize
        CALL Copy32
        JR .check
.chs:   LD A,KIND_CHS
        LD (DevKind),A
        LD A,(ID_BUF+7)
        OR A
        SCF
        RET NZ
        LD A,(ID_BUF+6)
        DEC A
        CP 16
        CCF
        RET C                           ; головок не 1..16
        INC A
        LD (DevHeads),A
        LD A,(ID_BUF+13)
        OR A
        SCF
        RET NZ
        LD A,(ID_BUF+12)
        DEC A
        CP 127
        CCF
        RET C                           ; секторов не 1..127
        INC A
        LD (DevSpt),A
        LD HL,(ID_BUF+2)
        LD (Cylinders),HL
        ; DevSize = цилиндры * головки * секторы (до 65535*16*127 < 2^27).
        LD A,(DevHeads)
        LD C,A
        LD A,(DevSpt)
        CALL Mul8                       ; HL = головки * секторы
        LD B,H
        LD C,L
        LD DE,(Cylinders)
        CALL Mul16                      ; DE:HL = BC * DE
        LD (DevSize),HL
        LD (DevSize+2),DE
.check: LD HL,DevSize
        LD DE,ZeroDword
        CALL Cmp32
        SCF
        RET Z                           ; ёмкость 0
        OR A
        RET
ZeroDword:      DD 0

; HL = A * C.
Mul8:   LD HL,0
        LD B,8
        LD D,0
        LD E,C
.bit:   ADD HL,HL
        RLA
        JR NC,.next
        ADD HL,DE
.next:  DJNZ .bit
        RET

; DE:HL = DE * BC. Множитель уходит из DE сверху, освободившиеся младшие
; биты DE занимает старшее слово произведения.
Mul16:  LD HL,0
        LD A,16
.bit:   ADD HL,HL
        RL E
        RL D
        JR NC,.next
        ADD HL,BC
        JR NC,.next
        INC DE
.next:  DEC A
        JR NZ,.bit
        RET

; Регистр CSD карты Z-Controller (CMD9) — в SECTOR_BUF; ёмкость — в DevSize.
; Карта уже инициализирована DEVINI. Выход: CF=1 — нет ответа или CSD v3.
ReadCsd:
        LD A,(Dev)
        CP DEV_SD2
        LD A,%00000001                  ; выбор карты — как SELDEV DSDZC
        JR NZ,.cs
        LD A,%00001011
.cs:    LD (.on+1),A
        LD BC,SD_CONF
        LD A,%00000011
        OUT (C),A
        LD BC,SD_DATA
        LD A,#FF
        OUT (C),A
        LD BC,SD_CONF
.on:    LD A,0
        OUT (C),A
        LD BC,SD_DATA
        LD A,#FF
        OUT (C),A
        LD HL,Cmd9
        LD B,6
.cmd:   LD A,(HL)
        OUT (SD_DATA),A
        INC HL
        DJNZ .cmd
        LD B,16
.r1:    IN A,(SD_DATA)
        BIT 7,A
        JR Z,.got
        DJNZ .r1
        JP .fail
.got:   OR A
        JP NZ,.fail
        LD DE,8192
.token: IN A,(SD_DATA)
        CP #FE
        JR Z,.data
        DEC DE
        LD A,D
        OR E
        JR NZ,.token
        JP .fail
.data:  LD HL,SECTOR_BUF
        LD B,18                         ; 16 байт и CRC
.byte:  IN A,(SD_DATA)
        LD (HL),A
        INC HL
        DJNZ .byte
        CALL .release
        JR ParseCsd
.fail:  CALL .release
        SCF
        RET
.release:
        LD BC,SD_CONF
        LD A,%00000011
        OUT (C),A
        LD BC,SD_DATA
        LD A,#FF
        OUT (C),A
        RET

; Ёмкость карты по CSD в SECTOR_BUF (16 байт, старший бит первым) — в
; DevSize. CF=1 — CSD v3 (SDUC) или неверный размер блока.
ParseCsd:
        ; Биты 127..126 — версия CSD.
        LD A,(SECTOR_BUF)
        AND #C0
        LD (CsdVersion),A
        JR Z,.v1
        CP #40
        SCF
        RET NZ                          ; v3 (SDUC) — не поддерживается
        ; v2: C_SIZE — биты 69..48, ёмкость (C_SIZE+1)*1024 секторов.
        LD A,(SECTOR_BUF+7)
        AND #3F
        LD E,A
        LD A,(SECTOR_BUF+8)
        LD H,A
        LD A,(SECTOR_BUF+9)
        LD L,A
        LD D,0                          ; DE:HL = C_SIZE
        LD BC,1
        CALL .inc32
        LD B,10
        JR .shift
.v1:    ; C_SIZE (12 бит), C_SIZE_MULT (3), READ_BL_LEN (4):
        ; секторов = (C_SIZE+1) << (C_SIZE_MULT + 2 + READ_BL_LEN - 9).
        LD A,(SECTOR_BUF+6)
        AND 3
        LD H,A
        LD A,(SECTOR_BUF+7)
        LD L,A
        ADD HL,HL
        ADD HL,HL
        LD A,(SECTOR_BUF+8)
        RLCA
        RLCA
        AND 3
        OR L
        LD L,A                          ; HL = C_SIZE
        LD DE,0
        LD BC,1
        CALL .inc32
        LD A,(SECTOR_BUF+9)
        AND 3
        ADD A,A
        LD B,A
        LD A,(SECTOR_BUF+10)
        RLCA
        AND 1
        OR B                            ; C_SIZE_MULT
        ADD A,2
        LD B,A
        LD A,(SECTOR_BUF+5)
        AND #0F                         ; READ_BL_LEN
        ADD A,B
        SUB 9
        LD B,A
        JR C,.fail0
.shift: LD A,B
        OR A
        JR Z,.store
.sl:    ADD HL,HL
        RL E
        RL D
        DJNZ .sl
.store: LD (DevSize),HL
        LD (DevSize+2),DE
        OR A
        RET
.fail0: SCF
        RET
.inc32: ADD HL,BC
        RET NC
        INC DE
        RET
Cmd9:   DB #49,0,0,0,0,#FF

; --- NeoGS: CSD через свою программу ---------------------------------------

; Служба WC в NeoGS умеет только читать и писать секторы (#10, #12) и ждёт
; ответа карты без предела. CSD отдаёт своя программа: как SELDEV DSDNGS —
; NeoGS в ПЗУ (#F3), проверка (#1D -> #8B), загрузка 256 байт в #4000
; (команда ПЗУ GS #14: блоков по 256, адрес), запуск (#13). Программа шлёт
; CMD9 и отдаёт байт состояния (0 — CSD прочитан) и 16 байт CSD, затем JP 0.
; Все ожидания хоста ограничены. Выход: CF=0 — CSD в SECTOR_BUF; CF=1 — нет.
; Служба WC после этого в NeoGS не стоит — её ставит заново вызывающий.
GSCOM           EQU #BB
GSDAT           EQU #B3
NgsCsd:
        LD A,#80
        OUT (#33),A
        EI
        HALT
        HALT
        LD A,#F3
        OUT (GSCOM),A
        CALL GsIdle
        RET C
        XOR A
        OUT (GSDAT),A
        LD A,#1D
        OUT (GSCOM),A
        CALL GsIdle
        RET C
        IN A,(GSDAT)
        CP #8B
        SCF
        RET NZ                          ; не NeoGS
        XOR A
        OUT (GSDAT),A
        LD A,#14
        CALL GsCom
        RET C
        LD A,1                          ; один блок 256 байт
        CALL GsDat
        RET C
        XOR A
        CALL GsDat
        RET C
        LD A,#40                        ; в #4000
        CALL GsDat
        RET C
        LD HL,NgsProgram
        LD B,0
.load:  LD A,(HL)
        CALL GsDat
        RET C
        INC HL
        DJNZ .load
        XOR A
        OUT (GSDAT),A
        LD A,#13                        ; запуск с #4000
        CALL GsCom
        RET C
        LD A,#40
        CALL GsDat
        RET C
        XOR A
        OUT (GSCOM),A
        CALL GsRead
        RET C
        OR A
        SCF
        RET NZ                          ; карта не отдала CSD
        LD HL,SECTOR_BUF
        LD B,16
.csd:   CALL GsRead
        RET C
        LD (HL),A
        INC HL
        DJNZ .csd
        OR A
        RET

; Команда A и ожидание её приёма (бит 0 #BB); CF=1 — нет ответа.
GsCom:  OUT (GSCOM),A
        PUSH BC
        LD BC,0
.wait:  IN A,(GSCOM)
        RRCA
        JR NC,.ok
        DEC BC
        LD A,B
        OR C
        JR NZ,.wait
        POP BC
        SCF
        RET
.ok:    POP BC
        OR A
        RET
; Байт данных A и ожидание его приёма (бит 7 #BB).
GsDat:  OUT (GSDAT),A
        PUSH BC
        LD BC,0
.wait:  IN A,(GSCOM)
        RLCA
        JR NC,.ok
        DEC BC
        LD A,B
        OR C
        JR NZ,.wait
        POP BC
        SCF
        RET
.ok:    POP BC
        OR A
        RET
; Байт от NeoGS (бит 7 #BB — есть данные): до ~1 с. Выход: A, CF=1 — нет.
GsRead: PUSH BC
        LD B,50
.wait:  IN A,(GSCOM)
        RLCA
        JR C,.got
        EI
        HALT
        DJNZ .wait
        POP BC
        SCF
        RET
.got:   POP BC
        IN A,(GSDAT)
        OR A                            ; CF=0
        RET
; Команда принята ПЗУ GS (бит 0 #BB сброшен): до ~2 с, как DIK.
GsIdle: PUSH BC
        LD B,100
.wait:  IN A,(GSCOM)
        RRCA
        JR NC,.ok
        EI
        HALT
        DJNZ .wait
        POP BC
        SCF
        RET
.ok:    POP BC
        OR A
        RET

; Программа для NeoGS (исполняется с #4000 памяти NeoGS). Порты — как у
; службы DSDNGS: #0F=0 — конфигурация, #11 выбор карты (#81 — снять, #01 —
; выбрать), #13 — передать байт, #14 — принять (и начать следующий обмен).
; Хосту — #03, когда бит 7 #04 сброшен. Карту к этому времени уже
; инициализировала служба WC (DEVINI в Probe). Код лежит внутри DISP
; плагина, поэтому абсолютные адреса — NGS_D+метка.
NGS_ORG         EQU #4000
NGS_SCTRL       EQU #11
NGS_SEND        EQU #13
NGS_RSTR        EQU #14
NGS_D           EQU NGS_ORG-NgsProgram
NgsProgram:
        DI
        LD SP,#6000
        XOR A
        OUT (#0F),A
        LD BC,NGS_SCTRL                 ; B=0, как у службы
        LD A,#81
        OUT (C),A
        CALL NGS_D+.ff
        LD C,NGS_SCTRL
        LD A,#01
        OUT (C),A
        CALL NGS_D+.ff
        LD C,NGS_RSTR
        LD D,0                          ; карта готова — отдаёт #FF
.ready: IN A,(C)
        INC A
        JR Z,.cmd
        DEC D
        JR NZ,.ready
.cmd:   LD HL,NGS_D+.cmd9
        LD D,6
        LD C,NGS_SEND
.out:   LD A,(HL)
        OUT (C),A
        CALL NGS_D+.pause
        INC HL
        DEC D
        JR NZ,.out
        LD C,NGS_RSTR
        LD D,16
.r1:    IN A,(C)
        BIT 7,A
        JR Z,.got
        DEC D
        JR NZ,.r1
        JR .fail
.got:   OR A
        JR NZ,.fail
        LD DE,0
.token: IN A,(C)                        ; #FF — ещё ждать, #FE — данные
        CP #FF
        JR NZ,.tok
        DEC DE
        LD A,D
        OR E
        JR NZ,.token
        JR .fail
.tok:   CP #FE
        JR NZ,.fail                     ; маркер ошибки
        LD HL,NGS_D+.buf
        LD D,18                         ; 16 байт и CRC
.byte:  IN A,(C)
        LD (HL),A
        INC HL
        DEC D
        JR NZ,.byte
        CALL NGS_D+.release
        XOR A
        CALL NGS_D+.host
        LD HL,NGS_D+.buf
        LD D,16
.send:  LD A,(HL)
        CALL NGS_D+.host
        INC HL
        DEC D
        JR NZ,.send
        JP 0
.fail:  CALL NGS_D+.release
        LD A,#FF
        CALL NGS_D+.host
        JP 0
.release:
        LD BC,NGS_SCTRL
        LD A,#81
        OUT (C),A
.ff:    LD BC,NGS_SEND
        LD A,#FF
        OUT (C),A
.pause: NOP
        NOP
        NOP
        NOP
        RET
.host:  PUSH AF
.hwait: IN A,(#04)
        RLCA
        JR C,.hwait
        POP AF
        OUT (#03),A
        RET
.cmd9:  DB #49,0,0,0,0,#FF
.buf:   DS 18
NgsProgramEnd:
        ASSERT NgsProgramEnd-NgsProgram <= 256, программа NeoGS длиннее блока

; --- обмен секторами драйвером в странице плагина -------------------------

; Записать IoCount (1..ZERO_SECTORS) секторов из HL с LBA IoLba. CF=1 —
; отказ (ABT драйвера). Прерывания на время обмена закрыты.
WriteSectors:
        LD A,(IoCount)
        LD C,A
        LD B,0                          ; запись
        JR Transfer
; Прочитать IoCount секторов в HL.
ReadSectors:
        LD A,(IoCount)
        LD C,A
        LD B,1
Transfer:
        PUSH HL
        PUSH BC
        ; Обмен не за концом устройства: драйвер IDE на отказ IDNF ждёт DRQ
        ; без предела, и ошибка расчёта повесила бы машину.
        LD HL,IoLba
        LD DE,IoEnd
        CALL Copy32
        LD B,0
        LD HL,IoEnd
        CALL Add32c
        LD HL,DevSize
        LD DE,IoEnd
        CALL Cmp32
        POP BC
        POP HL
        RET C                           ; конец обмена за ёмкостью — отказ
        PUSH HL
        PUSH BC
        DI
        CALL MapScratch
        XOR A
        LD (DRV_ABT),A
        LD HL,(IoLba)
        LD DE,(IoLba+2)
        CALL DRV_XPOZI
        POP BC
        POP HL
        LD A,C
        DEC B
        JR NZ,.write
        PUSH HL
        PUSH BC
        CALL Invalidate                 ; DMA пишет мимо кэша
        POP BC
        POP HL
        LD A,C
        CALL DRV_RDDSE
        JR .done
.write: CALL DRV_SDDSE
.done:  LD A,(DRV_ABT)
        PUSH AF
        CALL ProtectW0
        EI
        POP AF
        OR A
        RET Z
        SCF
        RET

; Перед чтением DMA: самозапись байтов буфера снимает признаки кэша
; (Chkdsk, wc_invalidate_sector_cache). HL — буфер, C — секторов.
Invalidate:
        LD B,C
.sector:
        PUSH BC
        LD B,0
.word:  LD A,(HL)
        LD (HL),A
        INC HL
        INC HL
        DJNZ .word
        POP BC
        DJNZ .sector
        RET

; --- перемонтирование панелей ---------------------------------------------

; Каждая панель на отформатированном устройстве монтирует его заново в своей
; странице (DOS_SWP, DEVINI, HDD — как ORIGA при выборе диска), путь — корень
; (как RPATH). Тома нет (обрыв записи) — панель переходит на загрузочное
; устройство WC. Список перерисует WC по коду возврата 3.
Remount:
        LD IX,WINDOW
        CALL .panel
        LD IX,WINDO2
.panel: LD A,(Dev)
        CP (IX+PANEL_DEV)
        RET NZ
        CALL .mount
        RET Z
        LD A,(BootDev)
        CP #FF
        RET Z
        LD (IX+PANEL_DEV),A
.mount: LD A,PNLPG
        ADD A,(IX+PANEL_PAGE)
        DI
        CALL MapW0
        LD A,(IX+PANEL_DEV)
        EI
        PUSH IX
        CALL CORE_DOS_SWP
        CALL CORE_DEVINI
        CALL Z,CORE_HDD
        POP IX
        PUSH AF
        LD (IX+PANEL_INIT),1
        DI
        LD A,RPPG                       ; путь панели — корень устройства
        CALL MapW0
        LD L,(IX+PANEL_PATH)
        LD H,(IX+PANEL_PATH+1)
        LD A,(IX+PANEL_DEV)
        ADD A,'0'
        LD (HL),A
        INC HL
        LD (HL),":"
        INC HL
        LD (HL),"\\"
        INC HL
        LD (HL),#FF
        LD (IX+PANEL_PATH+2),L
        LD (IX+PANEL_PATH+3),H
        CALL ProtectW0
        EI
        POP AF
        RET
