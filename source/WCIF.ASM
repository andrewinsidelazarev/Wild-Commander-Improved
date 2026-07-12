; WCIF — оконный интерфейс, курсор, печать и индикатор прогресса.
; Exact-диапазон: #7828..#7E9F.
; Основные процедуры:
;   #7828 PBINIT  — инициализировать индикатор; IX=окно, DE=полный объём;
;   #785C PBPRINT — вывести положение индикатора для значения HL;
;   #792C PRWOW   — нарисовать окно по 36-байтовому описателю IX;
;   #7BE6 SCRLWOW — прокрутить прямоугольную область окна;
;   #7CAF CURSORF — принудительно погасить или восстановить курсор;
;   #7CD5 CURSOR  — кадровое мигание курсора активной панели;
;   #7D25 PRSRW   — скопировать строку в окно;
;   #7D39 PRIAT   — записать атрибуты строки;
;   #7D45 GADRW   — преобразовать координаты окна в экранный адрес;
;   #7D81 TXTPR   — печатать строку с управляющими кодами оформления.
; Инициализировать индикатор прогресса.
; Вход: IX — описатель окна; DE — полное количество элементов.
; При DE=0 процедура немедленно возвращает управление.
PBINIT:
L7828:
        LD      (#786D),DE
        LD      A,D
        OR      E
        RET     Z
        LD      A,(IX+#0A)
        OR      A
        LD      A,#F6
        JR      NZ,L7828_0
        LD      A,#DF

L7828_0:
        LD      (#789C),A
        LD      A,(IX+#05)
        SUB     (IX+#0A)
        SUB     #03
        LD      (#787D),A
        LD      B,#00
        LD      H,#00
        LD      L,A

L7828_1:
        INC     B
        OR      A
        SBC     HL,DE
        JR      Z,L7828_2
        JR      NC,L7828_1

L7828_2:
        LD      (#7864),A
        LD      A,B
        LD      (#789F),A
        RET
; Пересчитать заполненную часть индикатора.
; Вход: IX — окно прогресса; HL — текущая абсолютная позиция.
PBPRINT:
L7828_3:
        LD      E,(IX+#0C)
        LD      D,#00
        DEC     E
        ADD     HL,DE
        LD      B,#00
        EX      DE,HL
        LD      HL,#0000

L7828_4:
        ADD     HL,DE
        DJNZ    L7828_4
        LD      DE,#0000
        LD      A,D
        OR      E
        RET     Z
        XOR     A

L7828_5:
        INC     A
        SBC     HL,DE
        JR      Z,L7828_6
        JR      NC,L7828_5
        DEC     A

L7828_6:
        LD      C,A
        LD      B,#00
        LD      A,B
        SUB     C
        LD      C,A
        LD      D,#01
        LD      E,(IX+#04)
        DEC     E
        CALL    L7828_75
        LD      (HL),#DC
        INC     H
        LD      DE,#B0DB
        LD      A,C

L7828_7:
        CP      B
        CALL    Z,L7828_9
        JR      Z,L7828_8
        LD      (HL),D
        INC     H
        DJNZ    L7828_7

L7828_8:
        LD      (HL),#F6
        RET

L7828_9:
        LD      A,#00

L7828_10:
        LD      (HL),E
        INC     H
        DEC     B
        RET     Z
        DEC     A
        JR      NZ,L7828_10
        LD      A,B
        OR      A
        LD      A,#FF
        RET

L7828_11:
        BIT     7,(IX+#00)
        RET     Z
        CALL    L7828_44
        LD      A,(#7F1D)
        LD      B,A
        LD      A,(IX+#04)
        CP      #02
        RET     C
        ADD     A,L
        LD      L,A
        CP      B
        RET     NC
        SET     7,L
        LD      A,(IX+#05)
        CP      #02
        RET     C
        LD      B,A

L7828_12:
        INC     H
        LD      A,(HL)
        AND     #00
        LD      (HL),A
        DJNZ    L7828_12
        LD      B,(IX+#04)
        DEC     B

L7828_13:
        DEC     L
        LD      A,(HL)
        AND     #00
        LD      (HL),A
        DJNZ    L7828_13
        RET

L7828_14:
        BIT     4,(IX+#00)
        JR      Z,L7828_15
        PUSH    AF
        RLCA
        RLCA
        RLCA
        RLCA
        LD      (#7A2E),A
        LD      (#7A36),A
        LD      DE,#2020
        LD      C,#20
        CALL    L7828_28
        POP     AF
        LD      (#7A2E),A
        LD      (#7A36),A
        RET

L7828_15:
        LD      (#7A2E),A
        LD      (#7A36),A
        LD      DE,#DABF
        LD      C,#C4
        CALL    L7828_28
        RET
; Три десятибайтовых описания оформления окна. Линейный дизассемблер
; ошибочно принимал эти данные и первые два байта PRWOW за последовательность команд.
WINDOW_STYLE_TABLE:
        DB      #BB,#C9,#CD,#BA,#BA,#B6,#C7,#BC,#C8,#CD
        DB      #F9,#F8,#F7,#FF,#FE,#FB,#FA,#FD,#FC,#5F
        DB      #BF,#DA,#C4,#B3,#B3,#B4,#C3,#D9,#C0,#C4
; API 1: нарисовать окно по 36-байтовому описателю IX.
; Младшие четыре бита (IX+0) выбирают вариант оформления; поля описателя
; задают размеры, координаты, цвета, заголовки и дополнительные строки.
PRWOW:
        LD      B,#03
        LD      A,(IX+#00)
        AND     #0F
        LD      HL,#790E
        LD      DE,#000A

L7828_16:
        JR      Z,L7828_23
        DEC     A
        JR      Z,L7828_20
        DEC     A
        JR      Z,L7828_17
        ADD     HL,DE
        DEC     A
        DJNZ    L7828_16
        RET

L7828_17:
        CALL    L7828_23
        LD      A,(IX+#11)
        OR      A
        JR      Z,L7828_18
        LD      L,(IX+#10)
        LD      H,A
        LD      DE,#0000
        CALL    L7828_80

L7828_18:
        LD      A,(IX+#13)
        OR      A
        JR      Z,L7828_19
        LD      L,(IX+#12)
        LD      H,A
        LD      D,(IX+#05)
        DEC     D
        LD      E,#00
        CALL    L7828_80

L7828_19:
        LD      A,(IX+#15)
        OR      A
        RET     Z
        LD      L,(IX+#14)
        LD      H,A
        LD      DE,#0101
        JP      L7828_80

L7828_20:
        CALL    L7828_23
        LD      A,(IX+#0D)
        OR      A
        JR      Z,L7828_21
        LD      L,(IX+#0C)
        LD      H,A
        LD      DE,#0000
        CALL    L7828_80

L7828_21:
        LD      A,(IX+#0F)
        OR      A
        JR      Z,L7828_22
        LD      L,(IX+#0E)
        LD      H,A
        LD      D,(IX+#05)
        DEC     D
        LD      E,#00
        CALL    L7828_80

L7828_22:
        LD      A,(IX+#11)
        OR      A
        RET     Z
        LD      L,(IX+#10)
        LD      H,A
        LD      DE,#0101
        JP      L7828_80

L7828_23:
        LD      A,(HL)
        INC     HL
        LD      (#7906),A
        LD      A,(HL)
        INC     HL
        LD      (#7907),A
        LD      A,(HL)
        INC     HL
        LD      (#7909),A
        LD      A,(HL)
        INC     HL
        LD      (#79FA),A
        LD      A,(HL)
        INC     HL
        LD      (#79FB),A
        LD      A,(HL)
        INC     HL
        LD      (#7A1C),A
        LD      A,(HL)
        INC     HL
        LD      (#7A1D),A
        LD      A,(HL)
        INC     HL
        LD      (#7A0F),A
        LD      A,(HL)
        INC     HL
        LD      (#7A10),A
        LD      A,(HL)
        INC     HL
        LD      (#7A12),A
        CALL    L7828_30
        LD      A,(IX+#04)
        DEC     A
        LD      (#7A28),A
        LD      A,(IX+#06)
        CALL    L7828_14
        LD      A,(IX+#05)
        SUB     #02
        JR      Z,L7828_26
        LD      DE,#B3B3
        LD      C,#20

L7828_24:
        CP      (IX+#0A)
        JR      Z,L7828_27
        CP      (IX+#0B)
        JR      Z,L7828_27
        CALL    L7828_28

L7828_25:
        DEC     A
        JR      NZ,L7828_24

L7828_26:
        LD      DE,DIR_FILTER_PATCH
        LD      C,#C4
        CALL    L7828_28
        JP      L7828_11

L7828_27:
        PUSH    DE
        PUSH    BC
        LD      DE,#C3B4
        LD      C,#C4
        CALL    L7828_28
        POP     BC
        POP     DE
        JR      L7828_25

L7828_28:
        LD      B,#00
        PUSH    HL
        LD      (HL),D
        SET     7,L
        LD      (HL),#00
        RES     7,L

L7828_29:
        INC     HL
        LD      (HL),C
        SET     7,L
        LD      (HL),#00
        RES     7,L
        DJNZ    L7828_29
        LD      (HL),E
        POP     HL
        INC     H
        RET

L7828_30:
        LD      A,(IX+#04)
        OR      A
        JR      NZ,L7828_31
        LD      A,(#7F1D)
        LD      (IX+#04),A

L7828_31:
        LD      A,(IX+#05)
        OR      A
        JR      NZ,L7828_32
        LD      A,(#600E)
        LD      (IX+#05),A

L7828_32:
        LD      A,(IX+#02)
        CP      #FF
        JR      NZ,L7828_33
        LD      A,(#7F1D)
        SUB     (IX+#04)
        SRL     A
        LD      (IX+#02),A

L7828_33:
        LD      A,(IX+#03)
        CP      #FF
        JR      NZ,L7828_34
        LD      A,(#600E)
        SUB     (IX+#05)
        SRL     A
        LD      (IX+#03),A

L7828_34:
        CALL    L7828_44
        LD      A,(IX+#08)
        OR      (IX+#09)
        RET     NZ
        PUSH    HL
        LD      DE,(L6011)
        LD      (IX+#08),E
        LD      (IX+#09),D
        LD      A,(IX+#04)
        BIT     7,(IX+#00)
        JR      Z,L7828_35
        INC     A

L7828_35:
        LD      (#7AB6),A
        LD      (#7ABD),A
        LD      A,(IX+#05)
        BIT     7,(IX+#00)
        JR      Z,L7828_36
        INC     A

L7828_36:
        EX      AF,AF'
        LD      A,#1D
        CALL    L6011_111
        LD      A,L
        EX      AF,AF'
        LD      B,#00

L7828_37:
        EX      AF,AF'
        LD      C,#00
        LDIR
        LD      L,A
        SET     7,L
        LD      C,#00
        LDIR
        LD      L,A
        INC     H
        EX      AF,AF'
        DEC     A
        JR      NZ,L7828_37
        LD      (L6011),DE
        POP     HL
        JP      L6011_109
; API 2: восстановить ранее сохранённую прямоугольную область окна IX.
; Адрес сохранения берётся из (IX+8..9); после копирования поле обнуляется.
RRESB:
L7828_38:
        CALL    L7828_44
        EX      DE,HL
        LD      L,(IX+#08)
        LD      H,(IX+#09)
        LD      A,H
        CP      #BF
        RET     NC
        OR      L
        RET     Z
        PUSH    HL
        LD      A,(IX+#04)
        BIT     7,(IX+#00)
        JR      Z,L7828_39
        INC     A

L7828_39:
        LD      (#7B05),A
        LD      (#7B0C),A
        LD      A,(IX+#05)
        BIT     7,(IX+#00)
        JR      Z,L7828_40
        INC     A

L7828_40:
        EX      AF,AF'
        LD      A,#1D
        CALL    L6011_111
        LD      A,E
        EX      AF,AF'
        LD      B,#00

L7828_41:
        EX      AF,AF'
        LD      C,#00
        LDIR
        LD      E,A
        SET     7,E
        LD      C,#00
        LDIR
        LD      E,A
        INC     D
        EX      AF,AF'
        DEC     A
        JR      NZ,L7828_41
        POP     BC
        EX      DE,HL
        LD      HL,(L6011)
        OR      A
        SBC     HL,DE
        JR      Z,L7828_42
        JR      L7828_43

L7828_42:
        LD      (L6011),BC

L7828_43:
        CALL    L6011_109
        XOR     A
        LD      (IX+#08),A
        LD      (IX+#09),A
        RET

L7828_44:
        XOR     A
        CALL    L6011_114
        LD      HL,RAM_PAGE_C000
        LD      A,(IX+#02)
        ADD     A,L
        LD      L,A
        LD      A,(IX+#03)
        ADD     A,H
        LD      H,A
        RET

L7828_45:
        LD      A,H
        OR      A
        JR      Z,L7828_48
        DEC     A
        JR      Z,L7828_46
        RET

L7828_46:
        CALL    L7828_64
        JP      C,L7828_51
        LD      HL,#0000
        LD      A,(IX+#02)
        ADD     A,L
        ADD     A,E
        LD      L,A
        LD      A,(IX+#03)
        ADD     A,H
        ADD     A,D
        LD      H,A
        LD      D,B
        LD      E,C
        DEC     D
        DEC     D
        DEC     E
        XOR     A
        LD      BC,#1DAF
        OUT     (C),L
        LD      B,#1E
        OUT     (C),H
        LD      B,#1F
        OUT     (C),A
        LD      B,#1C
        OUT     (C),A
        INC     H
        LD      B,#1A
        OUT     (C),L
        LD      B,#1B
        OUT     (C),H
        LD      B,#26
        OUT     (C),E
        LD      B,#28
        OUT     (C),D
        LD      B,#27
        LD      A,#31
        OUT     (C),A

L7828_47:
        DB      #ED,#70
        JP      M,L7828_47
        RET

L7828_48:
        CALL    L7828_64
        JR      C,L7828_51
        LD      HL,#0000
        LD      A,(IX+#02)
        ADD     A,L
        ADD     A,E
        LD      E,A
        LD      A,(IX+#03)
        ADD     A,H
        ADD     A,D
        ADD     A,B
        LD      D,A
        DEC     D
        LD      H,D
        LD      L,E
        DEC     H
        LD      A,B
        DEC     A
        EX      AF,AF'
        LD      A,C
        LD      BC,#26AF
        OUT     (C),A
        XOR     A
        LD      B,#1F
        OUT     (C),A
        LD      B,#1C
        OUT     (C),A
        LD      B,#28
        OUT     (C),A
        EX      AF,AF'

L7828_49:
        EX      AF,AF'
        LD      B,#1D
        OUT     (C),E
        LD      B,#1E
        OUT     (C),D
        DEC     D
        LD      B,#1A
        OUT     (C),L
        LD      B,#1B
        OUT     (C),H
        DEC     H
        LD      B,#27
        LD      A,#01
        OUT     (C),A

L7828_50:
        DB      #ED,#70
        JP      M,L7828_50
        EX      AF,AF'
        DEC     A
        JR      NZ,L7828_49
        RET
; API 84: прокрутить прямоугольник окна IX.
; Вход: D/E — Y/X, B/C — высота/ширина; A: биты 1..0 задают направление,
; биты 5..2 — величину шага, бит 6 — очистку источника, бит 7 — перенос атрибутов.
SCRLWOW:
        LD      H,A
        AND     #FC
        JP      Z,L7828_45

L7828_51:
        LD      A,H
        LD      HL,#7C39
        LD      (HL),#00
        BIT     7,A
        JR      Z,L7828_52
        LD      (HL),#01

L7828_52:
        LD      HL,#7C50
        LD      (HL),#00
        BIT     6,A
        JR      Z,L7828_53
        LD      (HL),#01

L7828_53:
        LD      L,A
        AND     #3C
        RRA
        RRA
        INC     A
        LD      (#7C2C),A
        LD      A,L
        AND     #03
        OR      A
        JR      Z,L7828_61
        DEC     A
        JR      Z,L7828_55
        DEC     A
        JR      Z,L7828_54
        RET

L7828_54:
        RET

L7828_55:
        CALL    L7828_44
        LD      A,D
        ADD     A,H
        LD      H,A
        LD      A,E
        ADD     A,L
        LD      L,A
        LD      D,H
        LD      E,L
        LD      A,(#7C2C)
        ADD     A,H
        LD      H,A
        LD      A,B
        SUB     #00
        RET     C
        LD      B,A

L7828_56:
        PUSH    BC
        PUSH    HL
        PUSH    DE
        LD      A,C
        EX      AF,AF'
        LD      B,#00
        LDIR
        LD      A,#00
        OR      A
        JR      Z,L7828_57
        SET     7,L
        SET     7,E
        DEC     L
        DEC     E
        EX      AF,AF'
        LD      C,A
        LDDR

L7828_57:
        POP     DE
        POP     HL
        INC     H
        INC     D
        POP     BC
        DJNZ    L7828_56
        DEC     H

L7828_58:
        LD      A,#00
        OR      A
        RET     Z
        XOR     A
        LD      B,C

L7828_59:
        LD      (HL),A
        INC     L
        DJNZ    L7828_59
        LD      A,(#7C39)
        OR      A
        RET     Z
        SET     7,L
        LD      A,(IX+#06)
        LD      B,C

L7828_60:
        DEC     L
        LD      (HL),A
        DJNZ    L7828_60
        RET

L7828_61:
        CALL    L7828_44
        LD      A,D
        ADD     A,H
        ADD     A,B
        LD      H,A
        DEC     H
        LD      A,E
        ADD     A,L
        LD      L,A
        LD      D,H
        LD      E,L
        PUSH    BC
        LD      A,(#7C2C)
        LD      C,A
        LD      A,H
        SUB     C
        LD      H,A
        LD      A,B
        SUB     C
        POP     BC
        RET     C
        LD      B,A

L7828_62:
        PUSH    BC
        PUSH    HL
        PUSH    DE
        LD      A,C
        EX      AF,AF'
        LD      B,#00
        LDIR
        LD      A,(#7C39)
        OR      A
        JR      Z,L7828_63
        SET     7,L
        SET     7,E
        DEC     L
        DEC     E
        EX      AF,AF'
        LD      C,A
        LDDR

L7828_63:
        POP     DE
        POP     HL
        DEC     H
        DEC     D
        POP     BC
        DJNZ    L7828_62
        INC     H
        JR      L7828_58

L7828_64:
        LD      A,(IX+#02)
        ADD     A,E
        RRA
        RET     C
        LD      A,C
        RRA
        RET
; Принудительно погасить либо восстановить курсор панели.
CURSORF:
L7828_65:
        DEC     B
        DEC     B
        DEC     L
        LD      A,#0F
        AND     A
        AND     (HL)
        LD      C,A
        LD      A,#F0
        AND     (IX+#0E)
        OR      C
        LD      (HL),A
        INC     L
        PUSH    AF
        LD      A,(IX+#01)
        AND     A
        AND     (HL)
        OR      (IX+#0E)
        CP      (HL)
        JR      Z,L7828_66
        LD      C,(HL)
        LD      (IX+#0F),C

L7828_66:
        CALL    L7828_68
        POP     AF
        LD      (HL),A
        RET
; Кадровое мигание курсора активной панели. Главный цикл вызывает процедуру
; сразу после EI/HALT; координаты и цвета берутся из полей описателя IX.
CURSOR:
L7828_67:
        CALL    L7828_71
        JR      NZ,L7828_65
        DEC     B
        RET     Z
        DEC     B
        RET     Z
        LD      A,(IX+#01)
        AND     A
        AND     (HL)
        OR      (IX+#0E)
        CP      (HL)
        JR      Z,L7828_68
        LD      C,(HL)
        LD      (IX+#0F),C

L7828_68:
        LD      (HL),A
        INC     L
        DJNZ    L7828_68
        RET
; API 7: погасить курсор и восстановить сохранённые символы/атрибуты фона.
CURSER:
L7828_69:
        CALL    L7828_71
        JR      NZ,L7828_70
        DEC     B
        RET     Z
        DEC     B
        RET     Z
        LD      A,(IX+#0F)
        JR      L7828_68

L7828_70:
        DEC     L
        LD      A,(IX+#06)
        LD      (HL),A
        INC     L
        DEC     B
        DEC     B
        PUSH    AF
        LD      A,(IX+#0F)
        CALL    L7828_68
        POP     AF
        LD      (HL),A
        RET

L7828_71:
        CALL    L7828_44
        LD      B,(IX+#04)
        SET     7,L
        INC     L
        LD      A,(IX+#0C)
        ADD     A,H
        LD      H,A
        BIT     6,(IX+#00)
        RET
; Скопировать строку в окно.
; Вход: IX — окно, HL — текст, BC — длина, D/E — координаты Y/X.
; Выход: HL — вычисленный экранный адрес.
PRSRW:
L7828_72:
        PUSH    DE
        PUSH    HL
        CALL    L7828_44
        LD      A,D
        ADD     A,H
        LD      H,A
        LD      A,E
        ADD     A,L
        LD      L,A
        EX      DE,HL
        POP     HL
        LD      A,C
        LDIR
        LD      B,A
        EX      DE,HL
        POP     DE
        RET
; Записать атрибуты строки. Вход: HL — экранный адрес, A — цвет, B — длина.
PRIAT:
L7828_73:
        CALL    L7828_76
        RET     C
        SET     7,L
        DEC     L

L7828_74:
        LD      (HL),A
        DEC     L
        DJNZ    L7828_74
        RET
; Преобразовать координаты D/E внутри окна IX в экранный адрес HL.
GADRW:
L7828_75:
        PUSH    DE
        CALL    L7828_44
        LD      A,D
        ADD     A,H
        LD      H,A
        LD      A,E
        ADD     A,L
        LD      L,A
        POP     DE
        RET

L7828_76:
        PUSH    AF
        LD      A,B
        CP      #5B
        JR      NC,L7828_77
        LD      A,H
        CP      #C0
        JR      C,L7828_77
        BIT     7,L
        JR      NZ,L7828_77
        LD      A,(#6003)
        CP      #00
        JR      NZ,L7828_77
        POP     AF
        OR      A
        RET

L7828_77:
        POP     AF
        SCF
        RET
; API 12: выбрать сообщение с индексом A из последовательности строк,
; разделённых нулевыми байтами, затем напечатать его через TXTPR.
; При A=0 HL уже указывает на печатаемую строку.
MEZZ:
        OR      A
        JR      Z,L7828_80
        PUSH    DE
        LD      E,A
        LD      BC,#2000

L7828_78:
        XOR     A

L7828_79:
        CPIR
        LD      A,(HL)
        INC     HL
        OR      A
        JR      NZ,L7828_78
        DEC     E
        JR      NZ,L7828_79
        POP     DE
; Печатать управляющую строку из HL с началом в D/E.
; Коды 11/12/13/14 задают табуляцию, смещение, новую строку и центрирование;
; значения меньше 10 переключают оформление.
TXTPR:
L7828_80:
        XOR     A
        CALL    L6011_114
        LD      (#7F54),DE
        LD      A,(IX+#06)
        LD      (#7F53),A

L7828_81:
        LD      A,(HL)
        OR      A
        JR      Z,L7828_82
        CP      #0B
        JR      Z,L7828_83
        CP      #0C
        JR      Z,L7828_84
        CP      #0D
        JP      Z,L7828_93
        CP      #0E
        JR      Z,L7828_85
        CP      #FE
        CALL    Z,L7828_94
        JR      Z,L7828_81
        CP      #0A
        CALL    C,L7828_96
        JR      C,L7828_81
        CALL    L7828_92
        JP      L7828_81

L7828_82:
        LD      DE,(#7F54)
        INC     D
        RET

L7828_83:
        INC     HL
        LD      A,E
        ADD     A,(HL)
        LD      E,A
        INC     HL
        JR      L7828_81

L7828_84:
        INC     HL
        LD      A,D
        ADD     A,(HL)
        LD      D,A
        INC     HL
        JR      L7828_81

L7828_85:
        PUSH    HL
        LD      BC,#5000
        CALL    L7828_87
        JR      NZ,L7828_86
        LD      A,C
        OR      A
        JR      Z,L7828_86
        LD      A,(IX+#04)
        SUB     C
        JR      C,L7828_86
        JR      Z,L7828_86
        SRL     A
        LD      E,A

L7828_86:
        POP     HL
        INC     HL
        JR      L7828_81

L7828_87:
        INC     HL
        LD      A,(HL)
        OR      A
        RET     Z
        CP      #0D
        RET     Z
        CP      #0E
        JR      Z,L7828_91
        CP      #FE
        JR      NC,L7828_91
        CP      #10
        JR      C,L7828_88
        INC     C

L7828_88:
        CP      #0B
        JR      NZ,L7828_89
        INC     HL

L7828_89:
        CP      #0C
        JR      NZ,L7828_90
        INC     HL

L7828_90:
        DJNZ    L7828_87

L7828_91:
        LD      A,#FE
        OR      A
        RET

L7828_92:
        PUSH    HL
        LD      A,(HL)
        EX      AF,AF'
        LD      HL,RAM_PAGE_C000
        LD      A,(IX+#02)
        ADD     A,L
        LD      L,A
        LD      A,(IX+#03)
        ADD     A,H
        LD      H,A
        LD      A,D
        ADD     A,H
        LD      H,A
        LD      A,E
        ADD     A,L
        LD      L,A
        EX      AF,AF'
        LD      (HL),A
        SET     7,L
        LD      A,(#7F53)
        LD      (HL),A
        POP     HL
        INC     E
        INC     HL
        RET

L7828_93:
        LD      DE,(#7F54)
        INC     D
        INC     HL
        JP      L7828_80

L7828_94:
        INC     HL
        LD      A,(HL)
        INC     HL
        EX      AF,AF'
        LD      A,(HL)
        INC     HL
        PUSH    HL
        LD      H,A
        EX      AF,AF'
        LD      L,A
        CALL    L7828_95
        POP     HL
        XOR     A
        RET

L7828_95:
        LD      A,(HL)
        OR      A
        RET     Z
        CP      #0D
        RET     Z
        CP      #0A
        CALL    C,L7828_96
        JR      C,L7828_95
        CALL    L7828_92
        JP      L7828_95

L7828_96:
        CP      #09
        JR      NZ,L7828_97
        LD      A,(#7F53)
        RRCA
        RRCA
        RRCA
        RRCA
        LD      (#7F53),A
        INC     HL
        SCF
        RET

L7828_97:
        EX      AF,AF'
        INC     HL
        LD      A,(HL)
        CP      #09
        JR      C,L7828_98
        EX      AF,AF'
        AND     #07
        LD      C,A
        LD      A,(IX+#06)
        AND     #F0
        OR      C
        LD      (#7F53),A
        SCF
        RET

L7828_98:
        EXX
        LD      C,A
        EX      AF,AF'
        CP      C
        JR      Z,L7828_100
        DEC     A
        DEC     C
        ADD     A,A
        ADD     A,A
        ADD     A,A
        ADD     A,A
        OR      C

L7828_99:
        LD      (#7F53),A
        SCF
        EXX
        INC     HL
        RET

L7828_100:
        OR      #08
        LD      C,A
        LD      A,(IX+#06)
        AND     #F0
        OR      C
        JR      L7828_99
