; IDE_CHS.INC — адресация CHS для дисков без LBA (драйверы IDE Nemo и SMUC).
; Включается только сборкой с ключом IDE_CHS (build.ps1, -DIDE_CHS): штатные
; образы DIDENEMO/DIDESMUC остаются побайтно прежними и сверяются по SHA-256,
; а вариант с CHS упаковывается отдельно и едет в FILEX.WMF (docs/03, раздел 2).
;
; Включающий драйвер даёт порты DRV, SECR, CYLL, CYLH, BLKS, буфер LOBU с
; ответом IDENTIFY (его читает xxxINI), DRVRE (#E0/#F0 от SELDEV), BLKNUM
; (позиция PROZ, байты LBA в порядке 0, 3, 1, 2), COMM и YDET.
;
; Диск сообщает LBA словом 49 IDENTIFY (бит 9). Без него драйвер берёт
; штатную геометрию (слово 3 — головок, слово 6 — секторов на дорожке),
; задаёт её диску командой INITIALIZE DEVICE PARAMETERS (#91) и пишет в
; drive/head номер головки без бита LBA. REREG тогда переводит LBA в
; цилиндр, головку и сектор; многосекторный обмен диск ведёт сам, через
; границы дорожек и цилиндров. Путь LBA не меняется.

; Режим — по CHS_SPT: 0 — LBA, иначе секторов на дорожке.
CHS_SPT         DB 0
CHS_HEADS       DB 0

; Снова LBA: DEVINI повторяет проверку адресных регистров (REREG позиции 2)
; и при CHS прочитал бы назад номер сектора 3, а не 2.
CHS_RESET:
        XOR A
        LD (CHS_SPT),A
        LD A,(DRVRE)
        OR #40
        LD (DRVRE),A
        RET

; После IDENTIFY (ответ в LOBU). Выход: Z — диск готов (LBA или CHS),
; NZ — диск без LBA с неверной геометрией или не ответил на #91.
CHS_SETUP:
        LD A,(LOBU+99)
        AND 2
        XOR 2
        RET Z                                   ; слово 49, бит 9: есть LBA
        LD A,(LOBU+7)
        OR A
        RET NZ                                  ; головок больше 255
        LD A,(LOBU+6)
        DEC A
        CP 16
        JR NC,.bad                              ; головок не 1..16
        LD E,A                                  ; номер последней головки
        LD A,(LOBU+13)
        OR A
        RET NZ
        LD A,(LOBU+12)
        OR A
        JR Z,.bad
        CP 128
        JR NC,.bad                              ; секторов на дорожке не 1..127
        LD D,A
        LD BC,BLKS:OUT (C),A
        LD A,(DRVRE)
        AND #BF                                 ; без бита LBA
        LD (DRVRE),A
        OR E
        LD BC,DRV:OUT (C),A
        LD A,#91:CALL COMM
        LD HL,256:CALL YDET
        RET NZ                                  ; диск не освободился
        LD A,D
        LD (CHS_SPT),A
        LD A,E
        INC A
        LD (CHS_HEADS),A
        XOR A
        RET
.bad:
        LD A,1
        OR A
        RET

; REREG в режиме CHS: на стеке уже HL и DE вызывающего.
CHS_REREG:
        LD HL,(BLKNUM)                          ; L — байт 0, H — байт 3
        LD DE,(BLKNUM+2)                        ; E — байт 1, D — байт 2
        LD A,H
        LD H,E
        LD E,D
        LD D,A                                  ; DE:HL — LBA
        LD A,(CHS_SPT)
        LD C,A
        CALL CHS_DIV
        INC A
        PUSH AF                                 ; сектор 1..SPT
        LD A,(CHS_HEADS)
        LD C,A
        CALL CHS_DIV                            ; HL — цилиндр, A — головка
        LD C,A
        LD A,(DRVRE)
        OR C
        LD BC,DRV:OUT (C),A
        POP AF
        LD BC,SECR:OUT (C),A
        LD BC,CYLH:OUT (C),H
        LD BC,CYLL:OUT (C),L
        POP DE,HL
        RET

; DE:HL — делимое, C — делитель 1..127. Выход: DE:HL — частное, A — остаток.
CHS_DIV:
        XOR A
        LD B,32
.bit:
        ADD HL,HL
        RL E
        RL D
        RLA
        CP C
        JR C,.next
        SUB C
        INC L
.next:
        DJNZ .bit
        RET
