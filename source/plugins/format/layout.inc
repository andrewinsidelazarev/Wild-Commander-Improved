; layout.inc — расчёт разметки: раздел MBR и параметры тома FAT32.
; Эталон и правила — tests/fat32_layout.py (тест сверяет их на Z80).
;
; Вход (переменные): DevKind (KIND_SD/KIND_LBA/KIND_CHS), DevSize (секторов
; на устройстве; у CHS — C*H*S), DevHeads/DevSpt (у CHS), SpcReq (0 — авто,
; иначе 1..64, степень двойки). Выход: CF=0 и PartStart, PartLength, Spc,
; Reserved, FatSize, DataStart, Clusters, GeoHeads/GeoSpt; CF=1 и A — код
; отказа (LAY_*).

KIND_SD         EQU 0
KIND_LBA        EQU 1
KIND_CHS        EQU 2

LAY_SMALL       EQU 1                   ; устройство меньше нужного FAT32
LAY_FEW         EQU 2                   ; кластеров меньше 65525 — кластер крупный
LAY_MANY        EQU 3                   ; кластеров больше предела FAT32 — кластер мелкий
LAY_RESERVED    EQU 4                   ; резерв длиннее 65535 секторов

LBA28_MAX       EQU #0FFFFFFF
MIN_CLUSTERS    EQU 65525
MAX_CLUSTERS    EQU #0FFFFFF5-2

Layout:
        LD A,(DevKind)
        CP KIND_CHS
        JR NZ,.lba
        LD A,(DevSpt)                   ; CHS: со второй головки цилиндра 0
        LD L,A
        LD H,0
        LD DE,0
        LD (PartStart),HL
        LD (PartStart+2),DE
        LD A,(DevHeads)
        LD (GeoHeads),A
        LD A,(DevSpt)
        LD (GeoSpt),A
        LD HL,0                         ; выравнивание — по кластеру (ниже)
        JR .bounds
.lba:   CP KIND_LBA
        LD HL,8192
        JR NZ,.start                    ; SD — 4 МиБ
        LD HL,DevSize                   ; IDE: не дальше LBA28 драйвера
        LD DE,Lba28Max
        CALL Cmp32
        JR C,.ide
        LD HL,Lba28Max
        LD DE,DevSize
        CALL Copy32
.ide:   LD HL,2048                      ; IDE с LBA — 1 МиБ
.start: LD (PartStart),HL
        LD DE,0
        LD (PartStart+2),DE
        LD A,255
        LD (GeoHeads),A
        LD A,63
        LD (GeoSpt),A
.bounds:
        LD (Align),HL
        ; Длина раздела = конец устройства - начало.
        LD HL,PartStart
        LD DE,DevSize
        CALL Cmp32
        LD A,LAY_SMALL
        JP NC,.fail                     ; начало не раньше конца устройства
        LD HL,DevSize
        LD DE,PartLength
        CALL Copy32
        LD HL,PartLength
        LD DE,PartStart
        CALL Sub32                      ; (HL) -= (DE)
        ; Кластер: заданный или по таблице fatgen103.
        LD A,(SpcReq)
        OR A
        JR NZ,.spc
        CALL AutoSpc
        JR NZ,.spc
        LD A,LAY_SMALL
        JP .fail
.spc:   LD (Spc),A
        LD HL,(Align)
        LD A,H
        OR L
        JR NZ,.aligned
        LD A,(Spc)
        LD L,A                          ; CHS: выравнивание по кластеру
.aligned:
        LD (Align),HL
        ; FAT = ceil((длина - 32) / (128*Spc + 1)).
        LD A,(Spc)
        LD L,A
        LD H,0
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        INC HL
        LD (Tmp2),HL
        LD HL,PartLength
        LD DE,Work
        CALL Copy32
        LD HL,Work
        LD BC,32
        CALL Sub32c                     ; (HL) -= BC
        LD HL,Work
        LD BC,(Tmp2)
        CALL Div32                      ; (HL) /= BC, остаток — в HL
        LD A,H
        OR L
        JR Z,.exact
        LD HL,Work
        LD BC,1
        CALL Add32c
.exact: LD HL,Work
        LD DE,FatSize
        CALL Copy32
        ; Начало данных без выравнивания: старт + 32 + 2*FAT.
        LD HL,PartStart
        LD DE,DataStart
        CALL Copy32
        LD HL,DataStart
        LD BC,32
        CALL Add32c
        LD HL,DataStart
        LD DE,FatSize
        CALL Add32
        LD HL,DataStart
        LD DE,FatSize
        CALL Add32
        ; Резерв: 32 + дополнение до кратного Align (степень двойки).
        LD HL,(Align)
        DEC HL
        LD A,(DataStart)
        AND L
        LD E,A
        LD A,(DataStart+1)
        AND H
        LD D,A                          ; DE = DataStart mod Align
        LD A,D
        OR E
        LD HL,0
        JR Z,.nopad
        LD HL,(Align)
        OR A
        SBC HL,DE                       ; дополнение
.nopad: PUSH HL
        LD B,H
        LD C,L
        LD HL,DataStart
        CALL Add32c
        POP HL
        LD BC,32
        ADD HL,BC                       ; не больше 32+8191
        LD (Reserved),HL
        ; Кластеры = (длина - резерв - 2*FAT) / Spc; служебная область не
        ; должна занять весь раздел.
        LD HL,FatSize
        LD DE,Work
        CALL Copy32
        LD HL,Work
        LD DE,FatSize
        CALL Add32
        LD HL,Work
        LD BC,(Reserved)
        CALL Add32c                     ; Work = резерв + 2*FAT
        LD HL,Work
        LD DE,PartLength
        CALL Cmp32
        JR NC,.few                      ; служебная область не меньше раздела
        LD HL,PartLength
        LD DE,Work2
        CALL Copy32
        LD HL,Work2
        LD DE,Work
        CALL Sub32
        LD HL,Work2
        LD DE,Work
        CALL Copy32
        LD A,(Spc)
.shift: RRCA
        JR C,.counted                   ; Spc — степень двойки
        PUSH AF
        LD HL,Work+3
        SRL (HL)
        DEC HL
        RR (HL)
        DEC HL
        RR (HL)
        DEC HL
        RR (HL)
        POP AF
        JR .shift
.counted:
        LD HL,Work
        LD DE,Clusters
        CALL Copy32
        LD HL,Clusters
        LD DE,MinClusters
        CALL Cmp32
        JR C,.few
        LD HL,Clusters
        LD DE,MaxClusters               ; предел + 1
        CALL Cmp32
        LD A,LAY_MANY
        JR NC,.fail
        OR A
        RET
.few:   LD A,LAY_FEW
.fail:  SCF
        RET

; Кластер по таблице fatgen103 для длины раздела. Выход: A — секторов на
; кластер, Z — раздел меньше 32,5 МБ (FAT32 нельзя).
AutoSpc:
        LD IX,AutoTable
.next:  LD HL,PartLength
        PUSH IX
        POP DE
        CALL Cmp32                      ; CF — длина < порога
        JR C,.found
        LD DE,5
        ADD IX,DE
        LD A,(IX+4)
        CP 64
        JR NZ,.next
        OR A
        RET
.found: LD A,(IX+4)
        OR A
        RET
; Пороги «меньше» (fatgen103 — «не больше»: +1), секторов на кластер.
AutoTable:
        DD 66601
        DB 0
        DD 532481
        DB 1
        DD 16777217
        DB 8
        DD 33554433
        DB 16
        DD 67108865
        DB 32
        DD #FFFFFFFF
        DB 64

Lba28Max:       DD LBA28_MAX
MinClusters:    DD MIN_CLUSTERS
MaxClusters:    DD MAX_CLUSTERS+1

; --- 32-битные операции над числами в памяти (младший байт первым) -------

; (HL) -> (DE), 4 байта. Сохраняет HL, DE.
Copy32:
        PUSH HL
        PUSH DE
        PUSH BC
        LD BC,4
        LDIR
        POP BC
        POP DE
        POP HL
        RET

; Сравнить (HL) и (DE): CF — (HL) < (DE), Z — равны. Сохраняет HL, DE.
Cmp32:
        PUSH HL
        PUSH DE
        PUSH BC
        INC HL
        INC HL
        INC HL
        INC DE
        INC DE
        INC DE
        LD B,4
.byte:  LD A,(DE)
        LD C,A
        LD A,(HL)
        CP C
        JR NZ,.done
        DEC HL
        DEC DE
        DJNZ .byte
.done:  POP BC
        POP DE
        POP HL
        RET

; (HL) += (DE). CF — перенос. Сохраняет DE.
Add32:
        PUSH DE
        PUSH BC
        LD B,4
        OR A
.byte:  LD A,(DE)
        ADC A,(HL)
        LD (HL),A
        INC HL
        INC DE
        DJNZ .byte
        POP BC
        POP DE
        RET

; (HL) -= (DE). CF — заём. Сохраняет DE.
Sub32:
        PUSH DE
        PUSH BC
        LD B,4
        OR A
.byte:  LD A,(DE)
        LD C,A
        LD A,(HL)
        SBC A,C
        LD (HL),A
        INC HL
        INC DE
        DJNZ .byte
        POP BC
        POP DE
        RET

; (HL) += BC; (HL) -= BC. CF — перенос/заём.
Add32c:
        LD A,(HL)
        ADD A,C
        LD (HL),A
        INC HL
        LD A,(HL)
        ADC A,B
        LD (HL),A
        INC HL
        LD A,(HL)
        ADC A,0
        LD (HL),A
        INC HL
        LD A,(HL)
        ADC A,0
        LD (HL),A
        RET
Sub32c:
        LD A,(HL)
        SUB C
        LD (HL),A
        INC HL
        LD A,(HL)
        SBC A,B
        LD (HL),A
        INC HL
        LD A,(HL)
        SBC A,0
        LD (HL),A
        INC HL
        LD A,(HL)
        SBC A,0
        LD (HL),A
        RET

; (HL) /= BC (1..32767). Выход: HL — остаток. Сохраняет IX.
Div32:
        PUSH IX
        PUSH HL
        POP IX
        LD HL,0
        LD A,32
.bit:   SLA (IX+0)
        RL (IX+1)
        RL (IX+2)
        RL (IX+3)
        ADC HL,HL
        OR A
        SBC HL,BC
        JR NC,.one
        ADD HL,BC
        JR .next
.one:   INC (IX+0)
.next:  DEC A
        JR NZ,.bit
        POP IX
        RET
