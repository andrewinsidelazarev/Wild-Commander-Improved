; PS2P — клавиатура PS/2, состояние клавиш и строковый редактор.
; Exact-диапазон: #7143..#7827.
; Основные процедуры и данные:
;   #7143 TAB4E — проверить 20 байтов состояния клавиш; Z означает «нет нажатий»;
;   #7176 ISTR  — автомат строкового ввода и редактирования;
;   #7259 IINIT — инициализировать буфер, размеры и положение курсора;
;   #73BA CLAvA — получить символ с учётом языка, Shift и Caps;
;   #742B CLAVA — упрощённое преобразование scan-кода в символ;
;   #7443 NUSP  — ждать нажатия; #744B USPO — ждать отпускания;
;   #75C9 PSD   — принять PS/2 scan-code set 2;
;   #767A KFF   — зарегистрировать нажатие; #7685 KOF — отпускание;
;   #76B4 TAB   — таблица текущего состояния клавиш;
;   #76CE TAI0  — scan-коды символьных клавиш;
;   #7701..#77F1 — английская и русская раскладки;
;   #77F2 ISINF — строки индикаторов режима ввода.

TAB4E:
L7143:
        LD      HL,(#76B4)
        LD      A,H
        OR      L
        LD      HL,(#76B6)
        OR      H
        OR      L
        LD      HL,(#76B8)
        OR      H
        OR      L
        LD      HL,(#76BA)
        OR      H
        OR      L
        LD      HL,(#76BC)
        OR      H
        OR      L
        LD      HL,(#76BE)
        OR      H
        OR      L
        LD      HL,(#76C0)
        OR      H
        OR      L
        LD      HL,(#76C2)
        OR      H
        OR      L
        LD      HL,(#76C4)
        OR      H
        OR      L
        LD      HL,(#76C6)
        OR      H
        OR      L
        RET

; Автомат строкового редактора.
; Вход A задаёт режим: #FF — первичная инициализация, #FD — ввод в окне,
; #FE — положение строки состояния, #FC — Insert/Caps, 0 — обработка кадра,
; 1 — завершение. Рабочие адреса и курсор хранятся в IWAD..IISP.
ISTR:
L7143_0:
        INC     A
        JP      Z,L7143_11
        INC     A
        JP      Z,L7143_23
        INC     A
        JP      Z,L7143_13
        INC     A
        JP      Z,L7143_30
        CP      #05
        JP      Z,L7143_12
        CP      #06
        JP      Z,L7143_29
        CP      #07
        JP      Z,L7143_25
        CALL    L7143_57
        CALL    NZ,L7143_7
        CALL    L7143_60
        CALL    NZ,L7143_10
        CALL    L7143_52
        CALL    NZ,L7143_3
        CALL    L7143_51
        CALL    NZ,L7143_5
        CALL    L7143_61
        CALL    NZ,L7143_22
        CALL    L7143_20
        CALL    L7143_21
        CALL    L7143_33
        RET     Z
        CALL    L7143_18
        LD      C,A
        LD      A,(INOV)
        OR      A
        JR      NZ,L7143_2
        PUSH    HL
        PUSH    BC
        CALL    L7143_19
        JR      Z,L7143_1
        ADD     HL,BC
        DEC     HL
        LD      D,H
        LD      E,L
        INC     DE
        LDDR

L7143_1:
        POP     BC
        POP     HL

L7143_2:
        LD      (HL),C

L7143_3:
        LD      BC,(#7824)
        LD      A,C
        INC     A
        CP      B
        JR      NC,L7143_4
        CALL    L7143_15
        LD      (#7824),A
        JP      L7143_15

L7143_4:
        LD      HL,(#7820)
        LD      DE,(#7824)
        LD      E,D
        LD      D,#00
        OR      A
        SBC     HL,DE
        RET     Z
        RET     C
        EX      DE,HL
        LD      HL,(#781E)
        SBC     HL,DE
        RET     NC
        ADD     HL,DE
        INC     HL
        LD      (#781E),HL
        XOR     A
        RET

L7143_5:
        LD      BC,(#7824)
        LD      A,C
        DEC     A
        CP      B
        JR      NC,L7143_6
        CALL    L7143_15
        LD      (#7824),A
        JP      L7143_15

L7143_6:
        LD      HL,(#781E)
        LD      A,H
        OR      L
        RET     Z
        DEC     HL
        LD      (#781E),HL
        RET

L7143_7:
        CALL    L7143_5
        RET     Z
        CALL    L7143_18
        LD      A,(INOV)
        OR      A
        JR      Z,L7143_9

L7143_8:
        LD      (HL),#20
        RET

L7143_9:
        EX      DE,HL
        LD      H,D
        LD      L,E
        INC     HL
        CALL    L7143_19
        LDIR
        EX      DE,HL
        JR      L7143_8

L7143_10:
        CALL    L7143_18
        EX      DE,HL
        LD      HL,(#7820)
        LD      BC,(#7822)
        ADD     HL,BC
        EX      DE,HL
        INC     HL
        OR      A
        SBC     HL,DE
        EX      AF,AF'
        ADD     HL,DE
        DEC     HL
        EX      AF,AF'
        JR      NC,L7143_8
        JR      L7143_9

; Инициализировать редактор: сохранить адрес строки, размер буфера,
; положение курсора и сбросить смещение видимой области.
IINIT:
L7143_11:
        LD      (#7822),HL
        LD      (#7824),DE
        LD      HL,#0000
        LD      (#781E),HL
        LD      L,D
        LD      (#7820),HL
        XOR     A
        LD      (#729F),A
        JP      L7143_15

L7143_12:
        CALL    L7143_15
        LD      HL,(#7822)
        RET

L7143_13:
        LD      (#7822),HL
        LD      (#7824),BC
        LD      (#781C),DE
        EXX
        LD      A,H
        OR      A
        JR      NZ,L7143_14
        LD      A,(#7825)
        CP      L
        JR      C,L7143_14
        LD      L,A

L7143_14:
        LD      (#7820),HL
        LD      HL,#0000
        LD      (#781E),HL
        LD      A,#01
        LD      (#729F),A

L7143_15:
        PUSH    AF
        LD      A,#00
        OR      A
        CALL    Z,L7143_17
        CALL    NZ,L7143_16
        SET     7,L
        LD      A,(HL)
        RRD
        POP     AF
        RET

L7143_16:
        CALL    L7828_44
        LD      BC,(#781C)
        LD      A,H
        ADD     A,B
        LD      H,A
        LD      A,L
        ADD     A,C
        LD      L,A
        LD      BC,(#7824)
        LD      B,#00
        ADD     HL,BC
        RET

L7143_17:
        LD      HL,(#7822)
        LD      BC,(#7824)
        LD      B,#00
        ADD     HL,BC
        CP      A
        RET

L7143_18:
        LD      HL,(#7822)
        LD      BC,(#7824)
        LD      B,#00
        ADD     HL,BC
        LD      BC,(#781E)
        ADD     HL,BC
        RET

L7143_19:
        PUSH    HL
        LD      HL,(#7820)
        LD      BC,(#7824)
        LD      B,#00
        INC     C
        OR      A
        SBC     HL,BC
        LD      BC,(#781E)
        OR      A
        SBC     HL,BC
        LD      B,H
        LD      C,L
        POP     HL
        RET

L7143_20:
        CALL    L7143_76
        RET     Z
        CALL    L7143_75
        RET     Z
        LD      A,(#781A)
        XOR     #01
        LD      (#781A),A
        JP      L7143_48

L7143_21:
        CALL    L7143_73
        RET     Z
        LD      BC,#DFF7
        LD      A,#0C
        OUT     (C),A
        LD      B,#BF
        LD      A,(CLST)
        XOR     #01
        LD      (CLST),A
        SLA     A
        OUT     (C),A
        RET

L7143_22:
        LD      A,(INOV)
        XOR     #01
        LD      (INOV),A
        RET

L7143_23:
        XOR     A
        DEC     H
        JR      NZ,L7143_24
        LD      A,(IX+#05)
        DEC     A

L7143_24:
        LD      H,A
        LD      (#7826),HL
        RET

L7143_25:
        LD      A,(#781A)
        OR      A
        LD      HL,#7806
        JR      Z,L7143_26
        LD      HL,#7809

L7143_26:
        LD      DE,#77F4
        LD      BC,#0003
        LDIR
        LD      A,(INOV)
        OR      A
        LD      HL,#780C
        JR      Z,L7143_27
        LD      HL,#780F

L7143_27:
        LD      DE,#77F8
        LD      BC,#0003
        LDIR
        LD      A,(CLST)
        OR      A
        LD      HL,#7812
        JR      Z,L7143_28
        LD      HL,#7815

L7143_28:
        LD      DE,#7802
        LD      BC,#0003
        LDIR
        LD      HL,#77F2
        LD      DE,(#7826)
        JP      L7828_80

L7143_29:
        LD      HL,(#7822)
        LD      BC,(#781E)
        ADD     HL,BC
        LD      DE,(#781C)
        LD      A,(#7825)
        LD      B,#00
        LD      C,A
        JP      L7828_72

L7143_30:
        CALL    L7143_61
        CALL    NZ,L7143_22
        CALL    L7143_20
        CALL    L7143_21
        LD      A,(#781A)
        AND     #03
        LD      C,A
        LD      A,(INOV)
        OR      A
        JR      Z,L7143_31
        SET     7,C

L7143_31:
        LD      A,(CLST)
        OR      A
        JR      Z,L7143_32
        SET     6,C

L7143_32:
        LD      A,C
        RET

; Преобразовать scan-код в печатный символ с учётом LANG, Shift и Caps.
; Выход: Z — символ отсутствует; NZ — A содержит символ кодировки WC.
CLAvA:
L7143_33:
        LD      HL,#76C1

L7143_34:
        LD      A,(HL)
        INC     HL
        OR      A
        JR      Z,L7143_34
        CP      #FF
        RET     Z
        CALL    L7143_88
        RET     Z
        LD      A,(HL)
        LD      HL,#76CE
        LD      B,#33

L7143_35:
        CP      (HL)
        JR      Z,L7143_36
        INC     HL
        DJNZ    L7143_35
        XOR     A
        RET

L7143_36:
        LD      BC,#8932
        ADD     HL,BC
        XOR     A
        LD      (#7818),A
        LD      A,(CLST)
        OR      A
        JR      NZ,L7143_41

L7143_37:
        LD      A,(#781A)
        LD      BC,#7701
        OR      A
        JR      Z,L7143_38
        LD      BC,#778C

L7143_38:
        ADD     HL,BC
        PUSH    HL
        CALL    L7143_75
        POP     HL
        LD      C,#00
        JR      Z,L7143_39
        INC     C

L7143_39:
        LD      A,(#7818)
        XOR     C
        JR      Z,L7143_40
        LD      BC,#0033
        ADD     HL,BC

L7143_40:
        LD      A,(HL)
        OR      A
        RET

L7143_41:
        LD      A,(#781A)
        LD      BC,#7767
        OR      A
        JR      Z,L7143_42
        LD      BC,#777D

L7143_42:
        CALL    L7143_43
        JR      NZ,L7143_37
        LD      A,#01
        LD      (#7818),A
        JR      L7143_37

L7143_43:
        LD      A,(BC)
        INC     BC
        CP      #FF
        RET     Z
        CP      L
        JR      NZ,L7143_43
        INC     A
        RET

; Упрощённое преобразование scan-кода по TAI0 без полного изменения регистра.
CLAVA:
L7143_44:
        CALL    L7143_83
        RET     Z
        LD      HL,#76CE
        LD      B,#33

L7143_45:
        CP      (HL)
        JR      Z,L7143_46
        INC     HL
        DJNZ    L7143_45
        XOR     A
        RET

L7143_46:
        LD      BC,#0033
        ADD     HL,BC
        LD      A,(HL)
        OR      A
        RET

; Ждать появления любой активной клавиши, синхронизируясь через EI/HALT.
NUSP:
L7143_47:
        EI
        HALT
        CALL    L7143_93
        RET     NZ
        JR      L7143_47

; Ждать отпускания всех клавиш, синхронизируясь через EI/HALT.
USPO:
L7143_48:
        EI
        HALT
        CALL    L7143_93
        RET     Z
        JR      L7143_48

UPPP:
L7143_49:
        LD      HL,#76B9
        JP      L7143_89

DWWW:
L7143_50:
        LD      HL,#76BB
        JP      L7143_89

LFFF:
L7143_51:
        LD      HL,#76BA
        JP      L7143_89

RGGG:
L7143_52:
        LD      HL,#76BC
        JP      L7143_89

PGU:
L7143_53:
        LD      HL,#76BE
        JP      L7143_89

PGD:
L7143_54:
        LD      HL,#76C0
        JP      L7143_89

ENKE:
L7143_55:
        LD      A,#5A
        JP      L7143_88

SPKE:
L7143_56:
        LD      A,#29
        JP      L7143_88

BSPC:
L7143_57:
        LD      A,#66
        JP      L7143_88

HOME_KEY:
L7143_58:
        LD      A,#6C
        JP      L7143_88

END_KEY:
L7143_59:
        LD      A,#69
        JP      L7143_88

DELE:
L7143_60:
        LD      A,#71
        JP      L7143_88

INS_KEY:
L7143_61:
        LD      A,#70
        JP      L7143_88

ESC_KEY:
L7143_62:
        LD      A,#76
        JR      L7143_81

F1_KEY:
L7143_63:
        LD      A,#05
        JR      L7143_81

F2_KEY:
L7143_64:
        LD      A,#06
        JR      L7143_81

F3_KEY:
L7143_65:
        LD      A,#04
        JR      L7143_81

F4_KEY:
L7143_66:
        LD      A,#0C
        JR      L7143_81

F5_KEY:
L7143_67:
        LD      A,#03
        JR      L7143_81

F6_KEY:
L7143_68:
        LD      A,#0B
        JR      L7143_81

F7_KEY:
L7143_69:
        LD      A,#83
        JR      L7143_81

F8_KEY:
L7143_70:
        LD      A,#0A
        JR      L7143_81

F9_KEY:
L7143_71:
        LD      A,#01
        JR      L7143_81

F10_KEY:
L7143_72:
        LD      A,#09
        JR      L7143_81

CAPS_KEY:
L7143_73:
        LD      HL,#76B5
        JR      L7143_89

ALT_KEY:
L7143_74:
        LD      HL,#76BD
        JP      L7143_92

SHIFT_KEY:
L7143_75:
        LD      HL,#76B6
        JP      L7143_92

CTRL_KEY:
L7143_76:
        LD      HL,#76B7
        JR      L7143_92

TAB_KEY:
L7143_77:
        LD      HL,#76B4
        JR      L7143_89

L7143_78:
        LD      A,#5A
        LD      HL,#76C1
        JR      L7143_80

L7143_79:
        LD      A,#76
        LD      HL,#76B8

L7143_80:
        CP      (HL)
        JR      NZ,L7143_82
        JR      L7143_90

L7143_81:
        LD      HL,#76B8
        CP      (HL)
        JR      Z,L7143_89

L7143_82:
        XOR     A
        RET

L7143_83:
        LD      HL,#76C1

L7143_84:
        LD      A,(HL)
        INC     HL
        OR      A
        JR      Z,L7143_84
        LD      (#74FB),HL
        DEC     HL
        CP      #FF
        JR      Z,L7143_87
        LD      A,(HL)
        OR      A
        RET     Z
        LD      A,(#76CC)
        CP      (HL)
        JR      NZ,L7143_85
        LD      A,(#76CB)
        OR      A
        JR      Z,L7143_85
        CP      #FF
        JR      NZ,L7143_86
        LD      A,#19
        LD      (#76CB),A

L7143_85:
        LD      A,(HL)
        OR      A
        RET

L7143_86:
        XOR     A
        RET

L7143_87:
        LD      HL,#76C1
        LD      (#74FB),HL
        RET

L7143_88:
        LD      HL,#76C1
        LD      BC,#0007
        CPIR
        JR      NZ,L7143_82
        DEC     HL

L7143_89:
        LD      A,(HL)
        OR      A
        RET     Z
        LD      A,(#76CC)
        CP      (HL)
        JR      NZ,L7143_91
        LD      A,(#76CB)
        OR      A
        JR      Z,L7143_90
        CP      #FF
        JR      NZ,L7143_91
        LD      A,#19
        LD      (#76CB),A

L7143_90:
        XOR     A
        INC     A
        RET

L7143_91:
        XOR     A
        RET

L7143_92:
        LD      A,(HL)
        OR      A
        RET     Z
        JR      L7143_90

; API 45: проверить двадцать отслеживаемых клавиш.
; Выход: Z — все отпущены; NZ — обнаружено нажатие, A=#19 и запущен автоповтор.
ANYK:
L7143_93:
        LD      HL,#76B4
        LD      B,#14
        XOR     A

L7143_94:
        CP      (HL)
        JR      NZ,L7143_95
        INC     HL
        DJNZ    L7143_94
        RET

L7143_95:
        LD      A,#19
        LD      (#76CB),A
        RET

L7143_96:
        LD      HL,#76C1
        LD      BC,#0007
        CPIR
        RET     Z
        LD      E,A
        XOR     A
        LD      HL,#76C1
        LD      BC,#0007
        CPIR
        RET     NZ
        DEC     HL
        LD      (HL),E
        LD      (IX+#18),E
        LD      (IX+#17),#FF
        RET

L7143_97:
        LD      BC,#DFF7
        LD      A,#0C
        OUT     (C),A
        LD      B,#BF
        LD      A,#01
        OUT     (C),A
        LD      B,#DF
        LD      A,#F0
        OUT     (C),A
        XOR     A
        LD      (#76CD),A
        LD      HL,#76B4
        LD      B,#14

L7143_98:
        LD      (HL),A
        INC     HL
        DJNZ    L7143_98
        XOR     A
        INC     A
        RET

L7143_99:
        LD      (#76BD),A
        RET

L7143_100:
        LD      (#76CD),A
        JR      L7143_103

L7143_101:
        LD      IX,#76B4
        LD      A,(IX+#17)
        OR      A
        JR      Z,L7143_102
        CP      #FF
        JR      Z,L7143_102
        DEC     (IX+#17)

; Приём одного события PS/2 scan-code set 2. Префикс #E0 отмечает
; расширенный код, #F0 переключает обработку на отпускание клавиши.
PSD:
L7143_102:
        LD      BC,#DFF7
        LD      A,#F0
        OUT     (C),A
        LD      BC,#BFF7

L7143_103:
        IN      A,(C)
        OR      A
        RET     Z
        CP      #E0
        JR      Z,L7143_100
        CP      #F0
        JP      Z,L7143_118
        CP      #FF
        JR      Z,L7143_97
        JP      Z,L7143_119
        LD      C,A
        LD      A,(#76CD)
        OR      A
        LD      (IX+#19),#00
        LD      A,C
        JR      Z,L7143_104
        CP      #12
        RET     Z
        CP      #59
        RET     Z

L7143_104:
        CP      #12
        JR      Z,L7143_107
        CP      #59
        JR      Z,L7143_107
        CP      #11
        JR      Z,L7143_99
        CP      #0D
        JR      Z,L7143_105
        CP      #58
        JR      Z,L7143_106
        CP      #14
        JR      Z,L7143_108
        CP      #0D
        JR      C,L7143_109
        CP      #76
        JR      Z,L7143_109
        CP      #78
        JR      Z,L7143_109
        CP      #83
        JR      Z,L7143_109
        CP      #75
        JR      Z,L7143_110
        CP      #6B
        JR      Z,L7143_111
        CP      #72
        JR      Z,L7143_112
        CP      #74
        JR      Z,L7143_113
        CP      #7D
        JR      Z,L7143_114
        CP      #7A
        JR      Z,L7143_116
        CP      #77
        JR      Z,L7143_115
        JP      L7143_96

L7143_105:
        LD      HL,#76B4
        JR      L7143_117

L7143_106:
        LD      HL,#76B5
        JR      L7143_117

L7143_107:
        LD      HL,#76B6
        JR      L7143_117

L7143_108:
        LD      HL,#76B7
        JR      L7143_117

L7143_109:
        LD      HL,#76B8
        JR      L7143_117

L7143_110:
        LD      HL,#76B9
        JR      L7143_117

L7143_111:
        LD      HL,#76BA
        JR      L7143_117

L7143_112:
        LD      HL,#76BB
        JR      L7143_117

L7143_113:
        LD      HL,#76BC
        JR      L7143_117

L7143_114:
        LD      HL,#76BE
        JR      L7143_117

L7143_115:
        LD      HL,#76BF
        JR      L7143_117

L7143_116:
        LD      HL,#76C0

; Зарегистрировать make-код: записать его в выбранную ячейку TAB,
; сохранить как последний код ARK и запустить задержку автоповтора.
KFF:
L7143_117:
        CP      (HL)
        RET     Z
        LD      (HL),A
        LD      (#76CC),A
        LD      (IX+#17),#FF
        RET

; Обработать break-код после #F0: найти его среди 20 ячеек TAB и очистить.
KOF:
L7143_118:
        IN      A,(C)
        OR      A
        JR      Z,L7143_121

L7143_119:
        LD      C,A
        LD      A,#CA
        LD      (#75E4),A
        LD      A,(#76CD)
        OR      A
        LD      (IX+#19),#00
        LD      A,C
        JR      Z,L7143_120
        CP      #12
        RET     Z
        CP      #59
        RET     Z

L7143_120:
        LD      HL,#76B4
        LD      BC,#0014
        CPIR
        RET     NZ
        DEC     HL
        LD      (HL),#00
        RET

L7143_121:
        LD      A,#C3
        LD      (#75E4),A
        RET

; Данные клавиатуры и строкового редактора, #76B4..#7827.
; Ранее этот диапазон был ошибочно разобран как команды Z80.
; TAB+0..+19 — текущие make-коды групп клавиш. KFF записывает код,
; KOF очищает соответствующую ячейку после break-префикса #F0.
TAB:
        DS      20,0
        DB      #FF                     ; Начальное служебное значение повтора.

NXF:
        DB      0                       ; Служебное состояние повтора клавиши.

WIN:
        DB      0                       ; Состояние оконного режима ввода.

ARR:
        DB      0                       ; Счётчик автоповтора.

ARK:
        DB      0                       ; Последний принятый scan-код.

E0F:
        DB      0                       ; Ненулевое значение означает префикс #E0.
        ASSERT  $ == #76CE, нарушена граница состояния клавиатуры

; 51 scan-код символьных клавиш PS/2 scan-code set 2.
TAI0:
        DB      #0E,#16,#1E,#26,#25,#2E,#36,#3D,#3E,#46,#45,#4E,#55
        DB      #15,#1D,#24,#2D,#2C,#35,#3C,#43,#44,#4D,#54,#5B,#5D
        DB      #1C,#1B,#23,#2B,#34,#33,#3B,#42,#4B,#4C,#52
        DB      #1A,#22,#21,#2A,#32,#31,#3A,#41,#49,#4A,#29
        DB      #79,#7B,#7C
        ASSERT  $ == #7701, нарушена граница TAI0

; Английская раскладка: без Shift и с Shift.
TAIE1:
        DB #27,"1234567890-="
        DB "qwertyuiop[]",#5C
        DB "asdfghjkl;",#27
        DB "zxcvbnm,./ +-*"

TAIE2:
        DB #7E,"!@#$%^&*()_+"
        DB "QWERTYUIOP{}",#7C
        DB "ASDFGHJKL:",#22
        DB "ZXCVBNM<>? +-*"
        ASSERT  $ == #7767, нарушена граница английской раскладки

; Индексы клавиш, для которых применяется дополнительная смена регистра.
TAIE0:
        DB      0,1,2,3,4,5,6,7,8,9,10,11,12
        DB      23,24,25,35,36,44,45,46,#FF

TAIR0:
        DB      1,2,3,4,5,6,7,8,9,10,11,12,25,46,#FF
        ASSERT  $ == #778C, нарушена граница индексных таблиц

; Русская раскладка в однобайтовой кодировке, используемой WC.
TAIR1:
        DB #F1,"1234567890-="
        DB      #A9,#E6,#E3,#AA,#A5,#AD,#A3,#E8,#E9,#A7,#E5,#EA,#5C
        DB      #E4,#EB,#A2,#A0,#AF,#E0,#AE,#AB,#A4,#A6,#ED
        DB #EF,#E7,#E1,#AC,#A8,#E2,#EC,#A1,#EE,#2E," +-*"

TAIR2:
        DB      #F0,#21,#22,#FB,#3B,#25,#3A,#3F,#2A,#28,#29,#5F,#2B
        DB      #89,#96,#93,#8A,#85,#8D,#83,#98,#99,#87,#95,#9A,#2F
        DB      #94,#9B,#82,#80,#8F,#90,#8E,#8B,#84,#86,#9D
        DB #9F,#97,#91,#8C,#88,#92,#9C,#81,#9E,#2C," +-*"
        ASSERT  $ == #77F2, нарушена граница русской раскладки

; Строка состояния редактора и варианты её трёхбуквенных индикаторов.
ISINF:
        DB      #09,#0E

ISIL:
        DB "ENG",#2F

ISII:
        DB "INS",#0B,1,"CAPS:"

ISIC:
        DB "OFF",0

ISI1:
        DB "ENG"

ISI2:
        DB "RUS"

ISI3:
        DB "INS"

ISI4:
        DB "OVR"

ISI5:
        DB "OFF"

ISI6:
        DB "ON "
        ASSERT  $ == #7818, нарушена граница строк индикаторов

; Рабочее состояние строкового редактора.
CLTT:
        DB      0                       ; Временный символ.

CLST:
        DB      0                       ; 0 — нижний регистр, 1 — верхний.

LANG:
        DB      0                       ; 0 — английская, 1 — русская раскладка.

INOV:
        DB      0                       ; 0 — вставка, 1 — замена.

IWAD:
        DW      0                       ; Адрес описателя окна.

IWOF:
        DW      0                       ; Смещение видимой части строки.

IBSZ:
        DW      0                       ; Размер редактируемого буфера.

ISAD:
        DW      0                       ; Адрес строки.

ICUP:
        DW      0                       ; Положение курсора.

IISP:
        DW      0                       ; Сохранённая экранная позиция.
        ASSERT  $ == #7828, нарушена конечная граница PS2P

; Имена отдельных групп в 20-байтовой таблице TAB.
BCA     EQU     TAB+1
BCS     EQU     TAB+2
BSS     EQU     TAB+3
BFS     EQU     TAB+4
BUP     EQU     TAB+5
BLF     EQU     TAB+6
BDN     EQU     TAB+7
BRG     EQU     TAB+8
BHM     EQU     TAB+9
BPU     EQU     TAB+10
BED     EQU     TAB+11
BPD     EQU     TAB+12
BAL     EQU     TAB+13
