; write.inc — запись разметки: секторы MBR, загрузочный, FSInfo, начало FAT,
; метка тома (эталон — tests/fat32_layout.py), порядок записи и сверка.

FMT_OK          EQU 0
FMT_WRITE       EQU 1                   ; отказ записи
FMT_ESC         EQU 2                   ; остановлено Esc
FMT_VERIFY      EQU 3                   ; прочитано не то, что записано

; Записать разметку по Layout. Итог — FormatResult (FMT_*).
Format:
        CALL MakeSerial
        LD HL,DataStart                 ; всего: нули до конца корня и 8 секторов
        LD DE,Total
        CALL Copy32
        LD A,(Spc)
        LD C,A
        LD B,0
        LD HL,Total
        CALL Add32c
        LD HL,Total
        LD BC,8
        CALL Add32c
        LD HL,0
        LD (Done),HL
        LD (Done+2),HL
        LD A,#FF
        LD (BarPct),A
        CALL ShowProgress
        ; 1. Нули с LBA 0 до начала раздела: прежних MBR и тома больше нет.
        LD HL,0
        LD (IoLba),HL
        LD (IoLba+2),HL
        LD HL,PartStart
        LD DE,ZeroLeft
        CALL Copy32
        CALL ZeroRange
        RET C
        ; 2. Нули: резерв, обе FAT и корень — [PartStart, DataStart+Spc).
        LD HL,PartStart
        LD DE,IoLba
        CALL Copy32
        LD HL,DataStart
        LD DE,ZeroLeft
        CALL Copy32
        LD A,(Spc)
        LD C,A
        LD B,0
        LD HL,ZeroLeft
        CALL Add32c
        LD HL,ZeroLeft
        LD DE,PartStart
        CALL Sub32
        CALL ZeroRange
        RET C
        ; 3. FSInfo и копия, начало обеих FAT, метка в корне.
        CALL BuildFsinfo
        LD BC,1
        CALL WritePart
        RET C
        LD BC,7
        CALL WritePart
        RET C
        CALL BuildFatHead
        LD BC,(Reserved)
        CALL WritePart
        RET C
        LD HL,PartStart
        LD DE,IoLba
        CALL Copy32
        LD HL,IoLba
        LD BC,(Reserved)
        CALL Add32c
        LD HL,IoLba
        LD DE,FatSize
        CALL Add32
        CALL WriteOne
        RET C
        CALL BuildRootLabel
        JR Z,.boot                      ; метки нет — корень уже нулевой
        LD HL,DataStart
        LD DE,IoLba
        CALL Copy32
        CALL WriteOne
        RET C
        ; 4. Копия загрузочного сектора, затем сам он.
.boot:  CALL BuildBoot
        LD BC,6
        CALL WritePart
        RET C
        LD BC,0
        CALL WritePart
        RET C
        ; 5. MBR — последним.
        CALL BuildMbr
        LD HL,0
        LD (IoLba),HL
        LD (IoLba+2),HL
        CALL WriteOne
        RET C
        ; 6. Сверка: MBR и загрузочный сектор чтением.
        CALL BuildMbr
        LD HL,0
        LD (IoLba),HL
        LD (IoLba+2),HL
        CALL VerifyOne
        RET C
        CALL BuildBoot
        LD HL,PartStart
        LD DE,IoLba
        CALL Copy32
        CALL VerifyOne
        RET C
        LD HL,Total                     ; полоса до конца: Total — оценка
        LD DE,Done
        CALL Copy32
        CALL DrawBar
        XOR A
        LD (FormatResult),A
        RET

; Сектор SECTOR_BUF — по LBA PartStart + BC.
WritePart:
        PUSH BC
        LD HL,PartStart
        LD DE,IoLba
        CALL Copy32
        POP BC
        LD HL,IoLba
        CALL Add32c
; Сектор SECTOR_BUF — по LBA IoLba. CF=1 — отказ (FormatResult).
WriteOne:
        LD A,1
        LD (IoCount),A
        LD HL,SECTOR_BUF
        CALL WriteSectors
        LD A,FMT_WRITE
        JR C,.fail
        LD HL,Done
        LD BC,1
        CALL Add32c
        CALL DrawBar
        OR A
        RET
.fail:  LD (FormatResult),A
        RET

; Прочитать IoLba в VERIFY_BUF и сравнить с SECTOR_BUF. CF=1 — отказ.
VerifyOne:
        LD A,1
        LD (IoCount),A
        LD HL,VERIFY_BUF
        CALL ReadSectors
        LD A,FMT_WRITE
        JR C,.fail
        LD HL,SECTOR_BUF
        LD DE,VERIFY_BUF
        LD BC,512
.cmp:   LD A,(DE)
        CPI
        JR NZ,.diff
        INC DE
        JP PE,.cmp
        OR A
        RET
.diff:  LD A,FMT_VERIFY
.fail:  LD (FormatResult),A
        SCF
        RET

; Нули: ZeroLeft секторов с LBA IoLba (IoLba продвигается). Ход записи — Done
; и полоса; Esc — остановка. CF=1 — остановлено (FormatResult).
ZeroRange:
.chunk: LD HL,ZeroLeft
        LD DE,ZeroDword
        CALL Cmp32
        RET Z                           ; CF=0 — всё записано
        LD A,(ZeroLeft+1)                  ; кусок — до ZERO_SECTORS секторов
        LD HL,(ZeroLeft+2)
        OR H
        OR L
        LD A,ZERO_SECTORS
        JR NZ,.full
        LD A,(ZeroLeft)
        CP ZERO_SECTORS
        JR C,.part
.full:  LD A,ZERO_SECTORS
.part:  LD (IoCount),A
        LD HL,ZERO_BUF
        CALL WriteSectors
        LD A,FMT_WRITE
        JR C,.fail
        LD A,(IoCount)
        LD C,A
        LD B,0
        PUSH BC
        LD HL,IoLba
        CALL Add32c
        POP BC
        PUSH BC
        LD HL,Done
        CALL Add32c
        POP BC
        LD HL,ZeroLeft
        CALL Sub32c
        CALL DrawBar
        LD A,23                         ; Esc — остановить
        CALL WLD
        JR Z,.chunk
        LD A,FMT_ESC
.fail:  LD (FormatResult),A
        SCF
        RET

; --- секторы ---------------------------------------------------------------

ClearSector:
        LD HL,SECTOR_BUF
        LD DE,SECTOR_BUF+1
        LD BC,511
        LD (HL),0
        LDIR
        RET
Signature:
        LD HL,#AA55
        LD (SECTOR_BUF+510),HL
        RET

BuildMbr:
        CALL ClearSector
        LD HL,Serial                    ; подпись диска — как серийный номер
        LD DE,SECTOR_BUF+440
        CALL Copy32
        LD HL,PartStart
        LD DE,SECTOR_BUF+446+1
        CALL ChsField
        LD A,(DevKind)
        CP KIND_CHS
        LD A,#0C                        ; FAT32 LBA
        JR NZ,.type
        LD A,#0B                        ; FAT32 CHS
.type:  LD (SECTOR_BUF+446+4),A
        LD HL,PartStart                 ; последний сектор раздела
        LD DE,Work
        CALL Copy32
        LD HL,Work
        LD DE,PartLength
        CALL Add32
        LD HL,Work
        LD BC,1
        CALL Sub32c
        LD HL,Work
        LD DE,SECTOR_BUF+446+5
        CALL ChsField
        LD HL,PartStart
        LD DE,SECTOR_BUF+446+8
        CALL Copy32
        LD HL,PartLength
        LD DE,SECTOR_BUF+446+12
        CALL Copy32
        JR Signature

; Поле CHS записи MBR: (HL) — LBA, DE — три байта. Геометрия GeoHeads/GeoSpt;
; цилиндр больше 1023 — 1023, последняя головка, последний сектор.
ChsField:
        PUSH DE
        LD DE,Work2
        CALL Copy32
        LD A,(GeoHeads)
        LD C,A
        LD A,(GeoSpt)
        CALL Mul8                       ; HL = головки * секторы
        LD B,H
        LD C,L
        LD HL,Work2
        CALL Div32                      ; Work2 — цилиндр, HL — остаток
        LD A,(GeoSpt)
        LD C,A
        CALL Div16                      ; HL — головка, A — сектор - 1
        INC A
        LD (ChsSector),A
        LD A,(Work2+2)
        LD B,A
        LD A,(Work2+3)
        OR B
        JR NZ,.cap
        LD BC,(Work2)
        LD A,B
        CP 4
        JR NC,.cap                      ; цилиндр > 1023
        POP DE
        LD A,L
        LD (DE),A                       ; головка
        INC DE
        LD A,B
        RRCA
        RRCA
        AND #C0
        LD L,A
        LD A,(ChsSector)
        OR L
        LD (DE),A                       ; старшие биты цилиндра и сектор
        INC DE
        LD A,C
        LD (DE),A
        RET
.cap:   POP DE
        LD A,(GeoHeads)
        DEC A
        LD (DE),A
        INC DE
        LD A,(GeoSpt)
        OR #C0
        LD (DE),A
        INC DE
        LD A,#FF
        LD (DE),A
        RET

; HL /= C (1..127). Выход: HL — частное, A — остаток.
Div16:  XOR A
        LD B,16
.bit:   ADD HL,HL
        RLA
        CP C
        JR C,.next
        SUB C
        INC L
.next:  DJNZ .bit
        RET

BuildBoot:
        CALL ClearSector
        LD HL,BootHead
        LD DE,SECTOR_BUF
        LD BC,BootHeadEnd-BootHead
        LDIR
        LD A,(Spc)
        LD (SECTOR_BUF+13),A
        LD HL,(Reserved)
        LD (SECTOR_BUF+14),HL
        LD A,2
        LD (SECTOR_BUF+16),A
        LD A,#F8
        LD (SECTOR_BUF+21),A
        LD A,(GeoSpt)
        LD (SECTOR_BUF+24),A
        LD A,(GeoHeads)
        LD (SECTOR_BUF+26),A
        LD HL,PartStart
        LD DE,SECTOR_BUF+28
        CALL Copy32
        LD HL,PartLength
        LD DE,SECTOR_BUF+32
        CALL Copy32
        LD HL,FatSize
        LD DE,SECTOR_BUF+36
        CALL Copy32
        LD A,2
        LD (SECTOR_BUF+44),A            ; корень — кластер 2
        LD A,1
        LD (SECTOR_BUF+48),A            ; FSInfo — сектор 1
        LD A,6
        LD (SECTOR_BUF+50),A            ; копия загрузочного — сектор 6
        LD A,#80
        LD (SECTOR_BUF+64),A
        LD A,#29
        LD (SECTOR_BUF+66),A
        LD HL,Serial
        LD DE,SECTOR_BUF+67
        CALL Copy32
        CALL LabelText
        LD DE,SECTOR_BUF+71
        LD BC,11
        LDIR
        LD HL,FsType
        LD DE,SECTOR_BUF+82
        LD BC,8+4
        LDIR
        JP Signature
BootHead:
        DB #EB,#58,#90
        DB "MSWIN4.1"
        DW 512
BootHeadEnd:
FsType: DB "FAT32   "
        DB #FA,#F4,#EB,#FD               ; CLI; HLT; JMP $-1 — не загрузочный

BuildFsinfo:
        CALL ClearSector
        LD HL,#5252
        LD (SECTOR_BUF),HL
        LD HL,#4161
        LD (SECTOR_BUF+2),HL
        LD HL,#7272
        LD (SECTOR_BUF+484),HL
        LD HL,#6141
        LD (SECTOR_BUF+486),HL
        LD HL,Clusters                  ; свободных — все, кроме корня
        LD DE,SECTOR_BUF+488
        CALL Copy32
        LD HL,SECTOR_BUF+488
        LD BC,1
        CALL Sub32c
        LD A,3
        LD (SECTOR_BUF+492),A           ; поиск свободного — с кластера 3
        LD HL,#AA55
        LD (SECTOR_BUF+510),HL
        RET

BuildFatHead:
        CALL ClearSector
        LD HL,FatHead
        LD DE,SECTOR_BUF
        LD BC,12
        LDIR
        RET
FatHead:
        DB #F8,#FF,#FF,#0F, #FF,#FF,#FF,#FF, #FF,#FF,#FF,#0F

; Первый сектор корня с записью метки. Z — метки нет (сектор не нужен).
BuildRootLabel:
        LD A,(LabelLen)
        OR A
        RET Z
        CALL ClearSector
        CALL LabelText
        LD DE,SECTOR_BUF
        LD BC,11
        LDIR
        LD A,#08
        LD (SECTOR_BUF+11),A
        OR A
        RET

; HL — 11 знаков метки: введённая (с пробелами до 11) или NO NAME.
LabelText:
        LD A,(LabelLen)
        OR A
        LD HL,NoName
        RET Z
        LD HL,Label
        LD E,A
        LD D,0
        ADD HL,DE
        SUB 11
        JR Z,.done
        NEG
        LD B,A
.pad:   LD (HL),' '
        INC HL
        DJNZ .pad
.done:  LD HL,Label
        RET
NoName: DB "NO NAME    "

; Серийный номер тома из часов CMOS (секунды, минуты, часы, день, месяц, год)
; и счётчика кадров — как у DOS, по времени форматирования.
MakeSerial:
        LD HL,CmosRegs
        LD DE,Serial
        LD B,4
.reg:   PUSH BC
        LD A,(HL)
        INC HL
        CALL ReadCmos
        LD C,A
        LD A,(HL)
        INC HL
        CALL ReadCmos
        ADD A,C
        LD (DE),A
        INC DE
        POP BC
        DJNZ .reg
        LD HL,(#6009)
        LD A,(Serial)
        XOR L
        LD (Serial),A
        LD A,(Serial+1)
        XOR H
        LD (Serial+1),A
        RET
CmosRegs:       DB 0,9, 2,8, 4,7, 7,0
ReadCmos:
        PUSH BC
        LD BC,#DFF7
        OUT (C),A
        LD B,#BF
        IN A,(C)
        POP BC
        RET
