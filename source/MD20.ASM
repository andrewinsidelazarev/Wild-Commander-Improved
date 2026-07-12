; MD20 — запуск, главный диспетчер и общие процедуры Wild Commander.
; Exact-диапазон: #6011..#7142.
; Основные процедуры:
;   #6011 WC_ENTRY — одноразовая точка входа и последовательность инициализации;
;   #6049 MAIN     — кадровый цикл и диспетчер клавиш;
;   #6107 ENTR     — открыть текущий файл либо войти в каталог;
;   #611C BENT     — перейти по записи «..» в родительский каталог;
;   #6149 Xpan     — служебно выбрать противоположную панель;
;   #6160 XPAN     — пользовательское переключение панелей по Tab;
;   #62EB PANELI   — сброс вычисляемого состояния панели;
;   #62FE GETEN    — получить запись под курсором;
;   #63FE FOLDER   — перестроить содержимое текущей панели;
;   #6407 NEWDIR   — перечислить каталог через WildDOS и построить индекс;
;   #65BB WLIT     — перерисовать видимую часть панели;
;   #6715 I_N_T    — обработчик IM2: таймер, видео, PS/2 и часы;
;   #6868 DRACT    — активировать драйвер выбранной панели;
;   #6A44 INIT     — начальная настройка TS-Conf, CMOS/PS2 и частоты;
;   #6BED DEF      — применить параметры CPU/AY и кэша.
; Точка входа полезной нагрузки. Два NOP присутствуют в эталонном образе;
; их назначение пока не доказано, поэтому они сохранены без интерпретации.
WC_ENTRY:
L6011:
        DI
        NOP
        LD      SP,#5FFE                ; Стек расположен непосредственно перед кодом по #6011.
        NOP
        CALL    INIT                    ; Начальная настройка видео, CMOS/PS2 и частоты CPU.
        CALL    WDOS.INSTALL_WILDDOS    ; Установить WildDOS: скопировать рабочую часть к #4000.

; Таблица IM2 занимает четыре байта #5BFF..#5C02. При векторе #FF процессор
; получает адрес #6715 — обработчик I_N_T. Байты FB C9 образуют EI/RET.
        DI
        LD      HL,#6715                ; Точный адрес обработчика I_N_T этой версии.
        LD      (#5BFF),HL
        LD      HL,#C9FB                ; Машинный код EI, RET.
        LD      (#5C01),HL
        DI
        LD      A,#5B
        LD      I,A
        IM      2

; Последовательность установлена сопоставлением с оригинальными метками.
        CALL    WCINI.FINI              ; Загрузить и разобрать wc.ini, подготовить буферы.
        CALL    WCINI.GEDZ              ; Выполнить первичное построение интерфейса.
        CALL    DEF                     ; Применить параметры CPU/AY и кэша.
        CALL    WCINI.PATH              ; Восстановить каталоги и позиции обеих панелей.
        CALL    Xpan                    ; Временно переключить IX на противоположную панель.
        CALL    WCFX.STATUS             ; Обслужить вторую панель.
        CALL    Xpan                    ; Вернуть IX к исходной панели.
        CALL    WCINI.PLresCP           ; Скопировать шлюз вызова резидентных плагинов.

; Главный цикл синхронизирован с кадровым прерыванием. Процедуры клавиатуры
; возвращают NZ при срабатывании; следующая команда выполняется условно.
WC_MAIN_LOOP:
MAIN:
L6011_0:
        EI
        HALT
        CALL    CURSOR                  ; Обновить курсор активной панели.
        CALL    ALT_KEY
        CALL    NZ,WCFX.F12             ; Действие комбинации с Alt.
        JR      NZ,L6011_0
        CALL    CTRL_KEY
        CALL    NZ,WCFX.F36             ; Действие комбинации с Ctrl.
        JR      NZ,L6011_0
        CALL    UPPP                    ; Клавиша вверх.
        CALL    NZ,CRUP                 ; Переместить курсор вверх.
        CALL    DWWW                    ; Клавиша вниз.
        CALL    NZ,CRDN                 ; Переместить курсор вниз.
        CALL    PGU
        CALL    NZ,PGSUP                ; Предыдущая страница списка.
        CALL    PGD
        CALL    NZ,PGSDN                ; Следующая страница списка.
        CALL    HOME_KEY
        CALL    NZ,PGSHM                ; Перейти к началу списка.
        CALL    END_KEY
        CALL    NZ,PGSED                ; Перейти к концу списка.
        CALL    LFFF                    ; Влево: эквивалент Home для панели.
        CALL    NZ,PGSHM
        CALL    RGGG                    ; Вправо: эквивалент End для панели.
        CALL    NZ,PGSED
        CALL    DELE
        CALL    NZ,WCFX.DelFl           ; Удалить отмеченные объекты.
        CALL    INS_KEY
        CALL    NZ,WCFX.Mark            ; Изменить отметку текущего объекта.
        CALL    BSPC
        CALL    NZ,BENT                 ; Перейти в родительский каталог «..».
        CALL    WCFX.STATUS             ; Обновить строку, только если STUS помечен.
        CALL    SHIFT_KEY
        CALL    NZ,WCFX.R2B2            ; Обработать комбинацию с Shift.
        JR      NZ,L6011_0
        CALL    F1_KEY
        CALL    NZ,WCFX.HELP
        CALL    F3_KEY
        CALL    NZ,WCVW.VIEW
        CALL    F10_KEY
        CALL    NZ,WCVW.F11MENU         ; Меню загруженных плагинов.
        CALL    TAB_KEY
        CALL    NZ,XPAN                 ; Переключить активную панель.
        CALL    F2_KEY
        CALL    NZ,WCFX.F2MENU
        CALL    F4_KEY
        CALL    NZ,WCFX.EDIT
        CALL    F5_KEY
        CALL    NZ,WCFX.COPY
        CALL    F6_KEY
        CALL    NZ,WCFX.Move
        CALL    F7_KEY
        CALL    NZ,WCFX.MkDir
        CALL    F8_KEY
        CALL    NZ,WCFX.DelFl
        CALL    F9_KEY
        CALL    NZ,WCINI.F9STP
        CALL    SPKE
        CALL    NZ,WCFX.Mark
        CALL    WCVW.TMAFK              ; Таймер бездействия и запуск плагина-заставки.
        CALL    ENKE
        CALL    NZ,ENTR                 ; Открыть выбранный объект.
        CALL    CLAVA                   ; Получить введённый символ.
        CP      #2A                     ; Символ «*» включает групповую отметку.
        CALL    Z,WCFX.MarkMUL
        JP      L6011_0

ENTR:
L6011_1:
        CALL    L6011_33
        EX      AF,AF'
        LD      A,H
        OR      L
        RET     Z
        EX      AF,AF'
        JP      NZ,WCVW.VIE
        INC     DE
        CALL    WCINI.MPATH
        CALL    L7828_69
        JP      L6011_48

BENT:
L6011_2:
        LD      HL,#0000
        CALL    L6011_34
        RET     NZ
        LD      A,H
        OR      L
        RET     Z
        LD      B,#02

L6011_3:
        INC     DE
        LD      A,(DE)
        CP      #2E
        RET     NZ
        DJNZ    L6011_3
        INC     DE
        LD      A,(DE)
        OR      A
        RET     NZ
        DEC     DE
        DEC     DE
        CALL    WCINI.MPATH
        CALL    L7828_69
        XOR     A
        LD      (IX+#0C),#01
        LD      (IX+#10),A
        LD      (IX+#11),A
        JP      L6011_48

Xpan:
L6011_4:
        LD      A,#01
        LD      (#7F43),A
        PUSH    IX
        POP     HL
        LD      DE,#7EC4
        OR      A
        SBC     HL,DE
        LD      IX,WINDOW
        RET     Z
        PUSH    DE
        POP     IX
        RET

XPAN:
L6011_5:
        PUSH    IX
        POP     HL
        LD      DE,#7EC4
        OR      A
        SBC     HL,DE
        JR      Z,L6011_6
        CALL    L7828_69
        CALL    L6011_116
        LD      A,#42
        LD      (#DFFC),A
        LD      IX,#7EC4
        CALL    L6011_104
        JP      L6011_23

L6011_6:
        CALL    L7828_69
        CALL    L6011_116
        LD      A,#41
        LD      (#DFFC),A
        LD      IX,WINDOW
        CALL    L6011_104
        JP      L6011_23

PGSED:
L6011_7:
        CALL    L7828_69
        LD      A,(IX+#14)
        OR      A
        JR      NZ,L6011_10
        LD      L,(IX+#10)
        LD      H,(IX+#11)

L6011_8:
        PUSH    HL
        CALL    L6011_36
        POP     HL
        INC     HL
        JR      NZ,L6011_8
        LD      A,(IX+#05)
        SUB     #01
        SUB     (IX+#0A)
        LD      B,#00
        LD      C,A
        OR      A
        SBC     HL,BC
        LD      A,H
        CP      #FF
        RET     NC
        LD      (IX+#10),L
        LD      (IX+#11),H
        CALL    L6011_78
        JR      L6011_10

PGSDN:
L6011_9:
        CALL    L7828_69
        LD      A,(IX+#14)
        OR      A
        JR      NZ,L6011_10
        LD      A,(IX+#05)
        SUB     #02
        SUB     (IX+#0A)
        LD      C,A
        LD      B,#00
        LD      L,(IX+#10)
        LD      H,(IX+#11)
        ADD     HL,BC
        LD      (IX+#10),L
        LD      (IX+#11),H
        CALL    L6011_78

L6011_10:
        CALL    L6011_18
        JP      L6011_23

L6011_11:
        PUSH    HL
        CALL    L7828_69
        POP     HL
        JR      L6011_17

PGSUP:
L6011_12:
        LD      A,(IX+#05)
        SUB     #02
        SUB     (IX+#0A)
        LD      C,A
        LD      B,#00
        LD      L,(IX+#10)
        LD      H,(IX+#11)
        OR      A
        SBC     HL,BC
        JR      NC,L6011_11

PGSHM:
L6011_13:
        CALL    L7828_69
        LD      HL,#0000
        LD      (IX+#0C),#01
        JR      L6011_17

CRDN:
L6011_14:
        LD      A,(IX+#0C)
        CP      (IX+#0D)
        JR      NC,L6011_16

L6011_15:
        CALL    L7828_69
        INC     (IX+#0C)
        JR      L6011_23

L6011_16:
        LD      A,(IX+#14)
        OR      A
        RET     NZ
        LD      L,(IX+#10)
        LD      H,(IX+#11)
        INC     HL

L6011_17:
        LD      (IX+#10),L
        LD      (IX+#11),H
        CALL    L6011_78
        JP      L7828_67

L6011_18:
        LD      A,(IX+#14)
        OR      A
        RET     Z
        LD      A,(IX+#0D)
        OR      A
        RET     Z
        LD      (IX+#0C),A
        RET

L6011_19:
        LD      A,(IX+#0D)
        OR      A
        JR      NZ,L6011_20
        INC     A

L6011_20:
        CP      (IX+#0C)
        RET     NC
        LD      (IX+#0C),A
        RET

CRUP:
L6011_21:
        LD      A,(IX+#0C)
        CP      #01
        JR      Z,L6011_24

L6011_22:
        CALL    L7828_69
        DEC     (IX+#0C)

L6011_23:
        CALL    L7828_67
        LD      A,#01
        LD      (#7F43),A
        RET

L6011_24:
        LD      A,(IX+#15)
        OR      A
        RET     NZ
        LD      L,(IX+#10)
        LD      H,(IX+#11)
        DEC     HL
        JR      L6011_17

L6011_25:
        LD      A,(IX+#0C)
        CP      (IX+#0D)
        RET     NC
        JR      L6011_15

L6011_26:
        LD      A,(IX+#0C)
        CP      #01
        RET     Z
        JR      L6011_22

L6011_27:
        CALL    L7828_69
        LD      (IX+#0C),#01
        JR      L6011_23

L6011_28:
        CALL    L7828_69
        LD      A,(IX+#0D)
        LD      (IX+#0C),A
        JR      L6011_23

L6011_29:
        LD      L,(IX+#12)
        LD      H,(IX+#13)
        LD      A,(IX+#11)
        CP      H
        RET     C
        LD      A,(IX+#10)
        CP      L
        RET     C
        LD      A,(IX+#05)
        SUB     #02
        SUB     (IX+#0A)
        LD      B,#00
        LD      C,A
        OR      A
        SBC     HL,BC
        JR      NC,L6011_30
        LD      HL,#0000

L6011_30:
        LD      (IX+#10),L
        LD      (IX+#11),H
        RET

L6011_31:
        CALL    L6011_32
        LD      (IX+#17),A
        LD      (IX+#18),A
        LD      (IX+#0C),#01
        LD      (IX+#10),A
        LD      (IX+#11),A
        LD      (IX+#1A),A
        RET

PANELI:
L6011_32:
        LD      A,#01
        LD      (#7F43),A
        XOR     A
        LD      (IX+#0D),A
        LD      (IX+#0F),A
        LD      (IX+#14),A
        LD      (IX+#15),A
        RET

GETEN:
L6011_33:
        LD      B,#00
        LD      C,(IX+#0C)
        DEC     C
        LD      L,(IX+#10)
        LD      H,(IX+#11)
        ADD     HL,BC

GETen:
L6011_34:
        CALL    L6011_35
        PUSH    HL
        INC     HL
        INC     HL
        INC     HL
        INC     HL
        LD      DE,#7F28
        LD      BC,#0008
        LDIR
        LD      C,#04
        ADD     HL,BC
        LD      DE,#7F6B
        CALL    L6011_60
        XOR     A
        LD      (DE),A
        POP     HL
        PUSH    HL
        LD      C,#10
        ADD     HL,BC
        EX      DE,HL
        POP     HL
        LD      A,(DE)
        OR      A
        RET
        LD      L,(IX+#10)
        LD      H,(IX+#11)

L6011_35:
        ADD     HL,HL
        ADD     HL,HL
        LD      BC,RAM_PAGE_C000
        ADD     HL,BC
        CALL    L6011_118
        LD      A,(HL)
        INC     L
        LD      (IX+#1A),A
        LD      C,(HL)
        INC     L
        LD      B,(HL)
        INC     L
        LD      A,(HL)
        LD      H,B
        LD      L,C
        LD      C,A
        JP      L6011_119

L6011_36:
        CALL    L6011_35
        LD      A,H
        OR      L
        RET

L6011_37:
        LD      A,(IX+#16)
        OR      A
        RET     Z
        CALL    L6011_114
        LD      DE,RAM_PAGE_C000
        LD      C,(IX+#10)
        LD      B,(IX+#11)
        LD      L,(IX+#17)
        LD      H,(IX+#18)
        LD      A,(IX+#0C)
        DEC     A
        JR      Z,L6011_40

L6011_38:
        LD      A,(IX+#0C)
        ADD     HL,DE
        LD      (HL),C
        INC     HL
        LD      (HL),B
        INC     HL
        LD      (HL),A
        INC     HL
        LD      (HL),#00
        INC     HL
        LD      (IX+#0C),#01
        LD      (IX+#10),#00
        LD      (IX+#11),#00

L6011_39:
        OR      A
        SBC     HL,DE
        LD      (IX+#17),L
        LD      (IX+#18),H
        RET

L6011_40:
        LD      A,B
        OR      C
        JR      NZ,L6011_38
        LD      A,L
        OR      H
        JR      Z,L6011_38
        ADD     HL,DE
        DEC     HL
        DEC     HL
        LD      A,(HL)
        LD      (IX+#0C),A
        DEC     HL
        LD      A,(HL)
        LD      (IX+#11),A
        DEC     HL
        LD      A,(HL)
        LD      (IX+#10),A
        JR      L6011_39

L6011_41:
        LD      HL,#81D3

L6011_42:
        CALL    WCFX.ERR0
        PUSH    IX
        POP     HL
        CALL    WCFX.SXM
        LD      (IX+#1D),A
        LD      (IX+#1C),#00
        CALL    L6011_104
        JR      L6011_45

L6011_43:
        LD      HL,#81E6
        JR      L6011_42

L6011_44:
        LD      A,(#600E)
        SUB     #01
        LD      (IX+#05),A
        CALL    #792C

L6011_45:
        CALL    #4003
        JR      NZ,L6011_41
        CALL    #4009
        JR      NZ,L6011_43
        LD      HL,#7F28
        LD      B,#04
        CALL    L6011_129
        JP      L6011_31

L6011_46:
        CALL    L6011_44

FOLD:
L6011_47:
        CALL    L6011_49
        CALL    L6011_29
        CALL    L6011_78
        CALL    L6011_19
        XOR     A
        RET

FOLDER:
L6011_48:
        CALL    L6011_32
        CALL    L6011_37
        JP      L6011_47

NEWDIR:
L6011_49:
        CALL    WCINI.PPATH
        LD      HL,#7F28
        CALL    #401E
        XOR     A
        LD      (IX+#12),A
        LD      (IX+#13),A
        INC     A
        LD      (IX+#1A),A
        CALL    L6011_119
        CALL    L6011_120
        XOR     A
        LD      (#C011),A
        LD      DE,RAM_PAGE_C000
        PUSH    DE
        CALL    L6011_71
        CALL    #4057
        CALL    L6011_72
        LD      B,D
        LD      C,E
        LD      HL,#7FFF
        POP     DE
        JP      Z,L6011_57
        LD      HL,#0010
        ADD     HL,DE
        LD      A,(HL)
        OR      A
        JR      NZ,L6011_50
        INC     HL
        LD      A,(HL)
        CP      #2E
        JR      NZ,L6011_50
        INC     HL
        LD      A,(HL)
        OR      A

L6011_50:
        LD      HL,F5WND
        LD      DE,RAM_PAGE_C000
        JR      Z,L6011_51
        LD      A,(IX+#1A)
        LD      (HL),A
        INC     L
        LD      (HL),E
        INC     L
        LD      (HL),D
        INC     L
        LD      A,(#7F4F)
        LD      (HL),A
        INC     HL
        LD      D,B
        LD      E,C
        INC     (IX+#12)

L6011_51:
        DEC     HL

L6011_52:
        LD      A,D
        CP      #FE
        JR      C,L6011_53
        INC     (IX+#1A)
        CALL    L6011_119
        LD      DE,RAM_PAGE_C000

L6011_53:
        LD      A,(IX+#1A)
        CP      #09
        JR      NC,L6011_57
        LD      C,A
        LD      A,H
        CP      #80
        JR      C,L6011_54
        LD      A,(#7F4F)
        LD      (HL),A

L6011_54:
        INC     HL
        LD      A,H
        CP      #BF
        JP      NZ,L6011_55
        LD      A,L
        CP      #FC
        JR      Z,L6011_57

L6011_55:
        LD      (HL),C
        INC     L
        LD      (HL),E
        INC     L
        LD      (HL),D
        INC     L
        INC     (IX+#12)
        JP      NZ,L6011_56
        INC     (IX+#13)

L6011_56:
        PUSH    HL
        CALL    L6011_71
        CALL    #4057
        CALL    L6011_72
        POP     HL
        JR      NZ,L6011_52
        DEC     HL
        DEC     HL
        DEC     HL
        DEC     HL
        DEC     (IX+#12)
        LD      A,(IX+#12)
        INC     A
        JR      NZ,L6011_57
        DEC     (IX+#13)

L6011_57:
        XOR     A
        INC     HL
        LD      (HL),A
        INC     L
        LD      (HL),A
        INC     L
        LD      (HL),A
        LD      A,#02
        CALL    L6011_110
        LD      A,(IX+#1A)
        CP      #01
        RET     NZ
        LD      A,(IX+#13)
        OR      A
        JR      NZ,L6011_58
        LD      A,(IX+#12)
        CP      #C8
        JR      C,L6011_59

L6011_58:
        PUSH    IX
        LD      IX,#8070
        CALL    #792C
        POP     IX
        CALL    L6011_59
        PUSH    IX
        LD      IX,#8070
        CALL    L7828_38
        POP     IX
        RET

L6011_59:
        LD      A,#06
        CALL    L6011_143
        CALL    WCINI.SORT
        CALL    L6011_105
        JP      L6011_142

L6011_60:
        LD      C,(HL)
        INC     HL
        LD      B,#08

L6011_61:
        LD      A,(HL)
        OR      A
        JR      Z,L6011_64
        CP      #2E
        JR      Z,L6011_70
        LD      (DE),A
        INC     HL
        INC     DE
        DJNZ    L6011_61
        LD      A,(HL)
        OR      A
        JR      Z,L6011_64
        LD      A,C
        OR      A
        JR      Z,L6011_64

L6011_62:
        XOR     A
        LD      BC,#0100
        CPIR
        DEC     HL
        LD      A,#FF
        SUB     C
        JR      Z,L6011_64
        CP      #04
        LD      B,A
        JR      C,L6011_63
        LD      B,#04

L6011_63:
        DEC     HL
        LD      A,(HL)
        CP      #2E
        JR      Z,L6011_67
        DJNZ    L6011_63

L6011_64:
        INC     B
        INC     B
        INC     B

L6011_65:
        LD      A,#20

L6011_66:
        LD      (DE),A
        INC     DE
        DJNZ    L6011_66
        RET

L6011_67:
        LD      B,#03

L6011_68:
        INC     HL
        LD      A,(HL)
        OR      A
        JR      Z,L6011_65
        CP      #40
        JR      C,L6011_69
        CP      #80
        JR      NC,L6011_69
        RES     5,A

L6011_69:
        LD      (DE),A
        INC     DE
        DJNZ    L6011_68
        RET

L6011_70:
        CALL    L6011_65
        JR      L6011_62

L6011_71:
        LD      (#7F51),DE
        XOR     A
        LD      (DE),A
        INC     DE
        LD      (DE),A
        INC     DE
        LD      (DE),A
        INC     DE
        LD      (DE),A
        INC     DE
        RET

L6011_72:
        EX      AF,AF'
        PUSH    DE
        LD      HL,(#7F51)
        LD      BC,#0010
        ADD     HL,BC
        LD      A,(HL)
        OR      A
        JR      Z,L6011_77
        LD      H,D
        LD      L,E
        LD      DE,(#7F51)
        INC     DE
        DEC     HL
        DEC     HL
        CP      #2E
        JR      Z,L6011_77
        LD      B,#04
        LD      A,#2E

L6011_73:
        DEC     HL
        CP      (HL)
        JR      Z,L6011_74
        DJNZ    L6011_73

L6011_74:
        INC     HL
        LD      B,#03

L6011_75:
        LD      A,(HL)
        OR      A
        JR      Z,L6011_77
        CP      #5B
        JR      NC,L6011_76
        CP      #41
        JR      C,L6011_76
        SET     5,A

L6011_76:
        LD      (DE),A
        INC     HL
        INC     DE
        DJNZ    L6011_75

L6011_77:
        POP     DE
        LD      H,D
        LD      L,E
        LD      BC,(#7F51)
        OR      A
        SBC     HL,BC
        LD      BC,#0013
        SBC     HL,BC
        LD      (#7F4F),HL
        EX      AF,AF'
        RET

WLIT:
L6011_78:
        XOR     A
        LD      (IX+#0D),A
        LD      (IX+#14),A
        LD      (IX+#15),A
        INC     A
        LD      (#7F43),A
        LD      H,(IX+#11)
        LD      L,(IX+#10)
        LD      DE,#0101
        LD      A,H
        OR      L
        JR      NZ,L6011_79
        LD      (IX+#15),#01

L6011_79:
        PUSH    HL
        PUSH    DE
        CALL    L6011_35
        LD      A,H
        OR      L
        JR      Z,L6011_85
        LD      A,(HL)
        BIT     0,A
        LD      C,#13
        JR      NZ,L6011_80
        LD      C,#17

L6011_80:
        LD      DE,#0010
        ADD     HL,DE
        LD      A,(HL)
        OR      A
        LD      A,C
        JR      NZ,L6011_81
        OR      #08

L6011_81:
        LD      (#7F42),A
        INC     HL
        LD      DE,#5EA0
        LD      A,(IX+#04)
        SUB     #02
        LD      B,A
        LD      C,A
        XOR     A

L6011_82:
        CP      (HL)
        JR      Z,L6011_83
        LDI
        DJNZ    L6011_82
        JR      L6011_84

L6011_83:
        LD      (DE),A
        INC     DE
        DJNZ    L6011_83

L6011_84:
        POP     DE
        POP     HL
        INC     HL
        INC     (IX+#0D)
        PUSH    HL
        LD      HL,#5EA0
        LD      A,(IX+#04)
        SUB     #02
        LD      B,#00
        LD      C,A
        CALL    L7828_72
        INC     D
        LD      A,(#7F42)
        CALL    L7828_73
        LD      A,(IX+#05)
        SUB     #02
        SUB     (IX+#0A)
        POP     HL
        CP      D
        JR      NC,L6011_79
        CALL    L6011_35
        LD      A,H
        OR      L
        RET     NZ
        LD      (IX+#14),#01
        RET

L6011_85:
        POP     DE
        POP     HL
        LD      (IX+#14),#01

L6011_86:
        LD      HL,#5EA0
        PUSH    HL
        LD      B,#2B
        CALL    L6011_129
        POP     HL
        LD      A,(IX+#04)
        SUB     #02
        LD      B,#00
        LD      C,A
        CALL    L7828_72
        INC     D
        LD      A,#17
        CALL    L7828_73
        LD      A,(IX+#05)
        SUB     #02
        SUB     (IX+#0A)
        CP      D
        JR      NC,L6011_86
        RET

; API 8: обслужить и перерисовать диалог выбора «да/нет».
; A=#FF возвращает текущее состояние, A=1/2 принудительно выбирает вариант.
YN:
L6011_87:
        CP      #01
        JR      Z,L6011_89
        CP      #02
        JR      Z,L6011_90
        CP      #FF
        JR      Z,L6011_88
        CALL    L7143_51
        CALL    NZ,L6011_92
        CALL    L7143_52
        CALL    NZ,L6011_93
        LD      DE,(#7F48)
        LD      HL,#7F8B
        LD      BC,#0008
        CALL    L7828_72
        LD      A,#F7
        CALL    L7828_73
        LD      DE,(#7F4A)
        LD      HL,#7F93
        LD      BC,#0008
        CALL    L7828_72
        LD      A,#07
        JP      L7828_73

L6011_88:
        LD      A,(#6699)
        LD      HL,#7F12
        CP      (HL)
        RET

L6011_89:
        LD      HL,#7F8B
        LD      DE,#7F93
        JR      L6011_91

L6011_90:
        LD      HL,#7F9B
        LD      DE,#7FA3

L6011_91:
        LD      (#6690),HL
        LD      (#66A2),DE
        LD      A,(IX+#06)
        RLCA
        RLCA
        RLCA
        RLCA
        LD      (#7F12),A
        LD      A,(IX+#06)
        AND     #F0
        RLCA
        RLCA
        RLCA
        RLCA
        LD      (#7F13),A
        LD      A,(IX+#05)
        SUB     #02
        LD      D,A
        LD      H,A
        LD      A,(IX+#04)
        SRL     A
        SUB     #09
        LD      L,A
        ADD     A,#0A
        LD      E,A
        LD      (#7F48),HL
        LD      (#7F4A),DE

L6011_92:
        LD      A,(#7F12)
        LD      (#6699),A
        LD      A,(#7F13)
        LD      (#66AB),A
        RET

L6011_93:
        LD      A,(#7F13)
        LD      (#6699),A
        LD      A,(#7F12)
        LD      (#66AB),A
        RET

; Обработчик IM2. Сохраняет оба набора регистров, обслуживает таймер,
; видеорегистры, PS/2 и часы, затем формирует флаги Escape/Enter.
I_N_T:
        PUSH    AF
        PUSH    BC
        PUSH    DE
        PUSH    HL
        PUSH    IX
        EXX
        EX      AF,AF'
        PUSH    AF
        PUSH    BC
        PUSH    DE
        PUSH    HL
        LD      HL,(#6009)
        INC     HL
        LD      (#6009),HL
        LD      A,(#7F4C)
        OR      A
        CALL    NZ,L6011_233
        CALL    L6011_94
        LD      A,(#7F4E)
        OR      A
        CALL    NZ,L7143_101
        LD      A,(#7F4D)
        OR      A
        CALL    NZ,L6011_97
        CALL    L7143_79
        CALL    NZ,L6011_96
        CALL    L7143_78
        CALL    NZ,L6011_95
        POP     HL
        POP     DE
        POP     BC
        POP     AF
        EXX
        EX      AF,AF'
        POP     IX
        POP     HL
        POP     DE
        POP     BC
        POP     AF
        EI
        RET

VPRT:
L6011_94:
        LD      HL,#7F56
        LD      BC,#02AF
        OUTI
        LD      B,#01
        OUTI
        LD      B,#05
        OUTI
        LD      B,#06
        OUTI
        LD      B,#03
        OUTI
        LD      B,#04
        OUTI
        RET

ENTF:
L6011_95:
        LD      A,#01
        LD      (#6005),A
        RET

ABTF:
L6011_96:
        LD      A,#01
        LD      (#6004),A
        RET

TIME:
L6011_97:
        LD      HL,#7F60
        LD      A,(HL)
        OR      A
        JR      Z,L6011_98
        DEC     (HL)
        LD      A,(HL)
        ADD     A,(HL)
        ADD     A,(HL)
        LD      B,#00
        LD      C,A
        SUB     (HL)
        LD      HL,#7F69
        OR      A
        SBC     HL,BC
        LD      BC,#DFF7
        OUT     (C),A
        LD      B,#BF
        IN      A,(C)
        CALL    L6011_135
        JR      L6011_99

L6011_98:
        INC     HL
        LD      A,(HL)
        DEC     A
        LD      (HL),A
        RET     NZ
        INC     HL
        LD      A,(HL)
        DEC     HL
        LD      (HL),A
        DEC     HL
        LD      (HL),#03
        RET

L6011_99:
        XOR     A
        CALL    L6011_115
        LD      DE,#7F63
        LD      HL,#BFF8
        LD      BC,(#7F1D)
        ADD     HL,BC
        EX      DE,HL
        LD      BC,#0008
        LDIR
        JP      L6011_113

L6011_100:
        LD      D,#00
        LD      A,#02
        CALL    L6011_101
        LD      E,A
        SLA     E
        RL      D
        SLA     E
        RL      D
        SLA     E
        RL      D
        SLA     E
        RL      D
        SLA     E
        RL      D
        XOR     A
        CALL    L6011_101
        SRL     A
        OR      E
        LD      E,A
        LD      A,#04
        CALL    L6011_101
        SLA     A
        SLA     A
        SLA     A
        OR      D
        LD      D,A
        LD      (#7F79),DE
        LD      (#7F81),DE
        LD      A,#09
        CALL    L6011_101
        ADD     A,#14
        LD      D,A
        LD      A,#08
        CALL    L6011_101
        SLA     A
        SLA     A
        SLA     A
        SLA     A
        SLA     A
        RL      D
        LD      E,A
        LD      A,#07
        CALL    L6011_101
        OR      E
        LD      E,A
        LD      (#7F7B),DE
        LD      (#7F7D),DE
        LD      (#7F83),DE
        RET

L6011_101:
        LD      BC,#DFF7
        OUT     (C),A
        LD      B,#BF
        IN      A,(C)
        LD      C,A
        AND     #0F
        LD      B,A
        SRL     C
        SRL     C
        SRL     C
        SRL     C
        LD      A,C
        ADD     A,C
        ADD     A,C
        ADD     A,C
        ADD     A,C
        ADD     A,C
        ADD     A,C
        ADD     A,C
        ADD     A,C
        ADD     A,C
        ADD     A,B
        RET

L6011_102:
        PUSH    IX
        POP     HL
        LD      DE,WINDOW
        OR      A
        SBC     HL,DE
        JR      NZ,L6011_103
        LD      IX,#7EC4
        RET

L6011_103:
        LD      IX,WINDOW
        RET

DRACT:
L6011_104:
        CALL    L6011_105
        LD      A,(IX+#1C)
        OR      A
        RET     NZ
        CALL    WCINI.RPATH
        LD      (IX+#1C),#01
        LD      A,(IX+#1D)
        JP      #401B

FRST:
L6011_105:
        LD      A,#F0
        ADD     A,(IX+#1B)
        JP      L6011_108

MNG0D:
L6011_106:
        LD      BC,#21AF
        LD      A,#01
        OUT     (C),A
        LD      BC,#10AF
        LD      A,#00
        OUT     (C),A
        RET

MNG0I:
L6011_107:
        LD      BC,#21AF
        LD      A,#0E
        OUT     (C),A
        RET

MNG0:
L6011_108:
        LD      (#6000),A
        LD      BC,#10AF
        OUT     (C),A
        RET
        LD      (#6001),A
        LD      BC,#11AF
        OUT     (C),A
        RET

L6011_109:
        LD      A,(#6002)

L6011_110:
        LD      (#6002),A

L6011_111:
        LD      BC,#12AF
        OUT     (C),A
        RET

L6011_112:
        XOR     A
        JP      L6011_114

L6011_113:
        LD      A,(#6003)

L6011_114:
        PUSH    BC
        LD      (#6003),A
        LD      BC,#13AF
        OUT     (C),A
        POP     BC
        RET

L6011_115:
        LD      BC,#13AF
        OUT     (C),A
        RET

MNGP:
L6011_116:
        LD      A,#F7
        JR      L6011_114

L6011_117:
        LD      A,#0B
        ADD     A,(IX+#19)
        JP      L6011_108

L6011_118:
        LD      A,#0B
        ADD     A,(IX+#19)
        JP      L6011_114

L6011_119:
        LD      A,#0B
        ADD     A,(IX+#1A)
        ADD     A,(IX+#19)
        JP      L6011_114

L6011_120:
        LD      A,#0B
        ADD     A,(IX+#19)
        JP      L6011_110

; API 0: подключить страницу плагина к окну #C000.
; A<64 задаёт номер страницы, #FE выбирает нулевую, #FF — первую страницу.
MNGC_PL:
L6011_121:
        CP      #FE
        JR      Z,L6011_112
        CP      #FF
        JR      Z,L6011_122
        CP      #40
        RET     NC
        ADD     A,#61
        PUSH    HL
        LD      HL,#7F15
        ADD     A,(HL)
        POP     HL
        JP      L6011_114

L6011_122:
        LD      A,#01
        JP      L6011_114

; API 78: подключить страницу плагина A<64 к окну #0000.
MNG0_PL:
        CP      #40
        RET     NC
        ADD     A,#61
        PUSH    HL
        LD      HL,#7F15
        ADD     A,(HL)
        POP     HL
        JP      L6011_108

; API 79: подключить страницу плагина A<64 к окну #8000.
MNG8_PL:
L6011_123:
        CP      #40
        RET     NC
        ADD     A,#61
        PUSH    HL
        LD      HL,#7F15
        ADD     A,(HL)
        POP     HL
        JP      L6011_110

; API 65: подключить видеостраницу A<64 к окну #C000.
MNGCVPL:
        CP      #40
        RET     NC
        ADD     A,#20
        JP      L6011_114

; API 80: подключить видеостраницу A<64 к окну #0000.
MNG0VPL:
        CP      #40
        RET     NC
        ADD     A,#20
        JP      L6011_108

; API 81: подключить видеостраницу A<64 к окну #8000.
MNG8VPL:
        CP      #40
        RET     NC
        ADD     A,#20
        JP      L6011_110

; API 64: выбрать один из четырёх банков видеостраниц.
; A=1..4 записывает базу #20/#30/#40/#50; иное значение запускает GEDPL.
MNGV_PL:
        CP      #01
        JR      Z,L6011_126
        CP      #02
        JR      Z,L6011_125
        CP      #03
        JR      Z,L6011_124
        CP      #04
        JP      NZ,L6011_131
        LD      A,#50
        JR      L6011_127

L6011_124:
        LD      A,#40
        JR      L6011_127

L6011_125:
        LD      A,#30
        JR      L6011_127

L6011_126:
        LD      A,#20

L6011_127:
        LD      (#7F56),A
        RET

; API 69: подключить видеостраницу C<64 к регистру Vtm (#16AF).
GVtm:
        LD      A,C
        CP      #40
        RET     NC
        ADD     A,#20
        LD      BC,#16AF
        OUT     (C),A
        RET

; API 70: подключить видеостраницу C<64 к Vtl0 либо Vtl1.
; Младший бит B выбирает порт #17AF или #18AF.
GVtl:
        LD      A,C
        CP      #40
        RET     NC
        ADD     A,#20
        BIT     0,B
        JR      NZ,L6011_128
        LD      BC,#17AF
        OUT     (C),A
        RET

L6011_128:
        LD      BC,#18AF
        OUT     (C),A
        RET

; API 71: подключить видеостраницу C<64 к регистру Vsgp (#19AF).
GVsgp:
        LD      A,C
        CP      #40
        RET     NC
        ADD     A,#20
        LD      BC,#19AF
        OUT     (C),A
        RET

L6011_129:
        XOR     A

L6011_130:
        LD      (HL),A
        INC     HL
        DJNZ    L6011_130
        RET

; API 15: инициализировать графическое окружение плагина:
; видеорежим, смещения, рабочую видеостраницу и аппаратную палитру.
GEDPL:
L6011_131:
        DI
        XOR     A
        LD      (#7F56),A
        LD      (#6010),A
        LD      A,(#600F)
        LD      (#7F57),A
        XOR     A
        LD      B,A
        LD      C,A
        LD      (#7F58),BC
        LD      (#7F5A),BC
        EI
        HALT
        LD      BC,#0FAF
        OUT     (C),A
        LD      A,#20
        CALL    L6011_114
        CALL    L6011_134
        LD      HL,#7EE8
        LD      DE,#1000
        LD      BC,#0020
        LDIR
        LD      HL,#7EE8
        LD      DE,#11E0
        LD      C,#20
        LDIR
        EX      DE,HL
        CALL    L6011_132
        LD      L,#40
        LD      B,#04
        CALL    L6011_132
        CALL    L6011_133
        LD      BC,#07AF
        OUT     (C),A
        RET

L6011_132:
        LD      (HL),C
        INC     L
        LD      (HL),C
        INC     HL
        DJNZ    L6011_132
        RET

L6011_133:
        XOR     A
        LD      BC,#15AF
        OUT     (C),A
        RET

L6011_134:
        LD      A,#11
        LD      BC,#15AF
        OUT     (C),A
        RET
        XOR     A
        LD      B,A
        LD      C,A
        LD      (#7F58),BC
        LD      (#7F5A),BC
        LD      (#7F56),A
        LD      BC,#0FAF
        OUT     (C),A
        RET

; API 66: сохранить A как текущий видеорежим плагина.
GVmod:
        LD      (#7F57),A
        RET

; API 67: сохранить HL как вертикальное смещение изображения.
GYoff:
        LD      (#7F58),HL
        RET

; API 68: сохранить HL как горизонтальное смещение изображения.
GXoff:
        LD      (#7F5A),HL
        RET

; API 10: записать байт A в (HL), а его две шестнадцатеричные цифры —
; в соседние позиции; выходной HL указывает за сформированную тройку.
NORK:
L6011_135:
        INC     HL
        LD      C,A
        AND     #0F
        CP      #0A
        JR      C,L6011_136
        ADD     A,#07

L6011_136:
        ADD     A,#30
        LD      (HL),A
        DEC     HL
        LD      (HL),C
        XOR     A
        RLD
        CP      #0A
        JR      C,L6011_137
        ADD     A,#07

L6011_137:
        ADD     A,#30
        LD      (HL),A
        INC     HL
        INC     HL
        RET

INIT:
L6011_138:
        LD      BC,#00AF
        LD      A,#30
        OUT     (C),A
        LD      BC,#EFF7
        LD      A,#80
        OUT     (C),A
        LD      B,#DF
        LD      A,#0B
        OUT     (C),A
        LD      B,#BF
        XOR     A
        OUT     (C),A
        LD      B,#DF
        LD      A,#0C
        OUT     (C),A
        LD      B,#BF
        LD      A,#01
        OUT     (C),A
        LD      B,#DF
        LD      A,#F0
        OUT     (C),A
        LD      B,#BF
        LD      A,#02
        OUT     (C),A
        LD      A,#01
        CALL    L6011_141

L6011_139:
        LD      A,#00
        LD      (#7F4D),A
        XOR     A
        LD      (#7F4C),A
        INC     A
        LD      (#7F4E),A
        RET

TURBOof:
L6011_140:
        LD      BC,#EFF7
        XOR     A
        OUT     (C),A
        LD      A,#00

TURBO:
L6011_141:
        AND     #03
        LD      BC,#20AF
        OUT     (C),A

L6011_142:
        LD      A,#02

L6011_143:
        LD      BC,#2BAF
        OUT     (C),A
        RET

GBD:
L6011_144:
        LD      BC,#DFF7
        LD      A,#B2
        OUT     (C),A
        LD      B,#BF
        IN      A,(C)
        RET

; Шлюзы X* образуют группу внешнего ABI плагина к файловым функциям WC/WildDOS.
; Общий пролог XPO сохраняет текущую страницу окна #0000 в #600C и подключает
; рабочую страницу плагина из #600B; эпилог XPC восстанавливает прежнюю страницу.
; Пролог и эпилог сохраняют AF/BC, поэтому результат и флаги задаёт целевая функция.
; XLD512/XSV512 дополнительно переводят указатель HL из окна #0000 в #C000,
; временно переключая это окно, а после операции возвращают адрес и страницу.
; API 48: прочитать блоки по 512 байт через LOAD512 (#4015).
XLD512:
        CALL    L6011_145
        CALL    L6011_147
        PUSH    DE
        CALL    L6011_113
        CALL    #4015
        POP     DE
        CALL    L6011_149
        JP      L6011_146

; API 49: записать блоки по 512 байт через SAVE512 (#4018).
XSV512:
        CALL    L6011_145
        CALL    L6011_147
        PUSH    DE
        CALL    #4018
        POP     DE
        CALL    L6011_149
        JP      L6011_146

; API 50: выбрать каталог по сохранённому кластеру #7F28 через GIPAG.
XGIPGPL:
        CALL    L6011_145
        CALL    L6011_155
        JP      L6011_146

; API 51: скопировать 32-байтовую ENTRY из #7F6B в буфер DE.
XTNTRY2:
        CALL    L6011_145
        CALL    L6011_156
        JP      L6011_146

; API 52: преобразовать сохранённую цепочку кластеров через CHTOSE.
XCHTS:
        CALL    L6011_145
        CALL    L6011_157
        JP      L6011_146

; API 53: зарезервированный шлюз TENTRYN; точная реализация ничего не делает.
XTNTRYN:
        CALL    L6011_145
        CALL    L6011_187
        JP      L6011_146

; API 54: найти и отметить файл; HL несёт номер либо маску поиска.
XTMRKFL:
        CALL    L6011_145
        CALL    L6011_188
        JP      L6011_146

; API 55: зарезервированный шлюз TMRKNXT; точная реализация ничего не делает.
XTMRKNX:
        CALL    L6011_145
        CALL    L6011_202
        JP      L6011_146

; API 56: открыть каталог, описанный сохранённым путём/кластером.
XADIR:
        CALL    L6011_145
        CALL    L6011_227
        JP      L6011_146

; API 57: выполнить команду потокового файлового интерфейса из D/E/BC.
; После вызова обновлённая рабочая страница #0000 сохраняется обратно в #600B.
XSTREAM:
        CALL    L6011_145
        CALL    L6011_205
        EX      AF,AF'
        LD      A,(#6000)
        LD      (#600B),A
        EX      AF,AF'
        JP      L6011_146

; API 58: получить следующую запись каталога через NXTETY2 (#405A).
XXTETY2:
        CALL    L6011_145
        CALL    #405A
        JP      L6011_146

; API 59: найти файловую запись и вернуть её метаданные.
XFENTRY:
        CALL    L6011_145
        CALL    L6011_217
        JP      L6011_146

; API 60: прочитать поток порциями по 256 байт через LOAD256 (#4051).
XLD256:
        CALL    L6011_145
        CALL    #4051
        JP      L6011_146

; API 61: пропустить данные потока через LOADNON (#4054).
XLDNON:
        CALL    L6011_145
        CALL    #4054
        JP      L6011_146

; API 62: выбрать файл по сохранённому кластеру.
XGFILE:
        CALL    L6011_145
        CALL    L6011_228
        JP      L6011_146

; API 63: загрузить сохранённый каталог через GLSTCAT.
XGDIR:
        CALL    L6011_145
        CALL    L6011_229
        JP      L6011_146

; API 72: создать файл и обновить сохранённые метаданные.
XMKfile:
        CALL    L6011_145
        CALL    L6011_230
        JP      L6011_146

; API 73: создать каталог через MKDIR.
XMKdir:
        CALL    L6011_145
        CALL    L6011_231
        JP      L6011_146

; API 74: переименовать объект через RENAME (#4042).
XREname:
        CALL    L6011_145
        CALL    #4042
        JP      L6011_146

; API 75: удалить файл через DELFL; Z означает, что объект не найден.
XDelFl:
        CALL    L6011_145
        CALL    L6011_232
        JP      L6011_146

L6011_145:
        PUSH    AF
        PUSH    BC
        LD      A,(#6000)
        LD      (#600C),A
        LD      A,(#600B)
        CALL    L6011_108
        POP     BC
        POP     AF
        RET

L6011_146:
        PUSH    AF
        PUSH    BC
        LD      A,(#600C)
        CALL    L6011_108
        POP     BC
        POP     AF
        RET

L6011_147:
        PUSH    AF
        PUSH    BC
        LD      D,#01
        LD      A,H
        CP      #40
        JR      NC,L6011_148
        DEC     D
        LD      A,(#6003)
        LD      E,A
        LD      A,(#600C)
        CALL    L6011_114
        LD      BC,RAM_PAGE_C000
        ADD     HL,BC

L6011_148:
        POP     BC
        POP     AF
        RET

L6011_149:
        PUSH    AF
        PUSH    BC
        DEC     D
        JR      Z,L6011_150
        LD      A,E
        CALL    L6011_114
        LD      BC,#4000
        ADD     HL,BC

L6011_150:
        POP     BC
        POP     AF
        RET

; API 14: настроить частоту Z80 и кэш по B/C.
; B=#FF восстанавливает сохранённые настройки, остальные значения выбирают поля C.
TURBOPL:
        INC     B
        JR      Z,L6011_154
        DEC     B
        JR      NZ,L6011_153
        LD      A,C
        AND     #03
        LD      C,A
        LD      B,#38

L6011_151:
        LD      A,(#7F1F)
        AND     B
        OR      C

L6011_152:
        LD      BC,#20AF
        OUT     (C),A
        LD      A,#02
        LD      BC,#2BAF
        OUT     (C),A
        RET

L6011_153:
        LD      A,C
        AND     #07
        SLA     A
        SLA     A
        SLA     A
        LD      C,A
        LD      B,#03
        JR      L6011_151

DEF:
L6011_154:
        LD      A,(#7F20)
        AND     #3B
        JR      L6011_152

GIPAGPL:
L6011_155:
        LD      HL,#7F28
        JP      #4012

TENTRY2:
L6011_156:
        LD      HL,#7F6B
        LD      BC,#0020
        LDIR
        RET

CHTOSEP:
L6011_157:
        LD      HL,#7F28
        JP      #4048

L6011_158:
        LD      A,#01
        JR      L6011_163

L6011_159:
        LD      A,#81
        JR      L6011_163

L6011_160:
        LD      A,#04
        JR      L6011_163

L6011_161:
        LD      A,#84
        JR      L6011_163

L6011_162:
        LD      A,#85

L6011_163:
        LD      HL,#7F21
        OR      (HL)
        INC     HL
        OR      (HL)
        INC     HL
        OR      (HL)
        EX      AF,AF'
        CALL    L6011_166
        RET     NZ
        EX      AF,AF'
        LD      BC,#27AF
        OUT     (C),A
        JR      L6011_164

; API 13: диспетчер DMA плагина.
; A выбирает запуск, ожидание, режим передачи либо настройку адресов и длины;
; параметры операций хранятся в трёх байтах #7F21..#7F23 и регистрах BC/DE/HL.
DMAPL:
        CP      #FC
        JR      Z,L6011_158
        CP      #FB
        JR      Z,L6011_159
        CP      #FA
        JR      Z,L6011_160
        CP      #F9
        JR      Z,L6011_161
        CP      #F8
        JR      Z,L6011_162
        CP      #FF
        JR      Z,L6011_164
        CP      #FE
        JR      Z,L6011_168
        CP      #FD
        JR      Z,L6011_169
        OR      A
        JR      Z,L6011_170
        DEC     A
        JR      Z,L6011_171
        DEC     A
        JR      Z,L6011_173
        DEC     A
        JR      Z,L6011_175
        DEC     A
        JR      Z,L6011_176
        DEC     A
        JR      Z,L6011_177
        DEC     A
        JR      Z,L6011_178
        DEC     A
        JP      Z,L6011_179
        DEC     A
        JP      Z,L6011_181
        DEC     A
        JP      Z,L6011_182
        DEC     A
        JP      Z,L6011_183
        DEC     A
        JP      Z,L6011_180
        RET

L6011_164:
        LD      BC,#27AF

L6011_165:
        DB      #ED,#70
        JP      M,L6011_165
        XOR     A
        RET

L6011_166:
        LD      BC,#27AF
        DB      #ED,#70
        JP      M,L6011_167
        XOR     A
        RET

L6011_167:
        XOR     A
        INC     A
        RET

L6011_168:
        CALL    L6011_169
        RET     NZ
        JR      L6011_164

L6011_169:
        CALL    L6011_166
        RET     NZ
        LD      BC,#27AF
        LD      A,#01
        OUT     (C),A
        XOR     A
        RET

L6011_170:
        PUSH    BC
        CALL    L6011_171
        POP     BC
        JR      L6011_173

L6011_171:
        LD      A,B
        CALL    L6011_184

L6011_172:
        LD      BC,#1AAF
        OUT     (C),L
        LD      B,#1B
        OUT     (C),H
        LD      B,#1C
        OUT     (C),A
        RET

L6011_173:
        LD      A,C
        CALL    L6011_184

L6011_174:
        LD      BC,#1DAF
        OUT     (C),E
        LD      B,#1E
        OUT     (C),D
        LD      B,#1F
        OUT     (C),A
        RET

L6011_175:
        CALL    L6011_186
        JR      L6011_172

L6011_176:
        CALL    L6011_186
        JR      L6011_174

L6011_177:
        LD      A,B
        LD      BC,#28AF
        OUT     (C),A
        RET

L6011_178:
        LD      A,B
        LD      BC,#26AF
        OUT     (C),A
        RET

L6011_179:
        PUSH    BC
        CALL    L6011_177
        POP     BC
        LD      B,C
        JR      L6011_178

L6011_180:
        LD      C,E
        CALL    L6011_183
        LD      C,H
        CALL    L6011_181
        LD      C,L
        JR      L6011_182

L6011_181:
        LD      A,C
        RRC     A
        RRC     A
        RRC     A
        AND     #20
        LD      (#7F21),A
        RET

L6011_182:
        LD      A,C
        RRC     A
        RRC     A
        RRC     A
        RRC     A
        AND     #10
        LD      (#7F22),A
        RET

L6011_183:
        LD      A,C
        SLA     A
        SLA     A
        SLA     A
        AND     #08
        LD      (#7F23),A
        RET

L6011_184:
        BIT     7,A
        JR      NZ,L6011_185
        AND     #3F
        ADD     A,#20
        RET

L6011_185:
        AND     #0F
        ADD     A,#61
        EXX
        LD      HL,#7F15
        ADD     A,(HL)
        EXX
        RET

L6011_186:
        LD      A,B
        AND     #03
        EXX
        LD      H,#60
        LD      L,A
        LD      A,(HL)
        EXX
        RET

; API 42: преобразовать состояние клавиатуры в символ.
; A=0 использует полный учёт языка/Shift/Caps, A=1 — упрощённую таблицу;
; выход: Z — символа нет, NZ — символ в A.
KBSCN:
        OR      A
        JP      Z,L7143_33
        DEC     A
        JP      Z,L7143_44
        RET

L6011_187:
        RET

L6011_188:
        LD      A,H
        OR      L
        JP      Z,L6011_197
        BIT     7,H
        PUSH    AF
        RES     7,H
        PUSH    DE
        PUSH    HL
        LD      HL,#0000
        EXX
        POP     DE
        LD      HL,#0000

L6011_189:
        EXX

L6011_190:
        LD      (#7F46),HL
        CALL    L6011_36
        JR      Z,L6011_196
        LD      BC,#0010
        ADD     HL,BC
        LD      A,(HL)
        OR      A
        JR      Z,L6011_191
        SBC     HL,BC
        LD      A,(HL)
        BIT     0,A

L6011_191:
        LD      HL,(#7F46)
        INC     HL
        JR      Z,L6011_190
        EXX
        INC     HL
        OR      A
        SBC     HL,DE
        JR      Z,L6011_192
        ADD     HL,DE
        JP      L6011_189

L6011_192:
        EXX
        DEC     HL
        CALL    L6011_34
        EX      DE,HL
        INC     HL
        POP     DE
        LD      BC,#FFFF

L6011_193:
        LD      A,(HL)
        OR      A
        JR      Z,L6011_194
        LD      A,D
        CP      #C0
        JR      NC,L6011_195
        LDI
        DJNZ    L6011_193

L6011_194:
        XOR     A
        LD      (DE),A

L6011_195:
        POP     AF
        CALL    Z,L6011_155
        XOR     A
        RET

L6011_196:
        POP     DE
        POP     AF
        XOR     A
        INC     A
        RET

L6011_197:
        LD      HL,#0000
        EXX
        LD      BC,#0000

L6011_198:
        EXX

L6011_199:
        LD      (#7F46),HL
        CALL    L6011_36
        JR      Z,L6011_201
        LD      BC,#0010
        ADD     HL,BC
        LD      A,(HL)
        OR      A
        JR      Z,L6011_200
        SBC     HL,BC
        LD      A,(HL)
        BIT     0,A

L6011_200:
        LD      HL,(#7F46)
        INC     HL
        JR      Z,L6011_199
        EXX
        INC     BC
        JP      L6011_198

L6011_201:
        EXX
        LD      HL,#0000
        LD      (#7F46),HL
        LD      (#7F44),BC
        LD      A,B
        OR      C
        RET

L6011_202:
        RET

L6011_203:
        LD      A,#F2
        CALL    L6011_108
        CALL    L6011_144
        CALL    L6011_206
        LD      A,#01
        RET     NZ
        LD      HL,#7FAB
        CALL    #404E
        LD      A,#02
        JR      Z,L6011_204
        LD      (#7F30),HL
        LD      (#7F32),DE
        CALL    L6011_229
        XOR     A
        RET

L6011_204:
        OR      A
        RET

L6011_205:
        LD      A,D
        CP      #FF
        JR      Z,L6011_209
        CP      #FE
        JR      Z,L6011_210
        CP      #FD
        JR      Z,L6011_203
        PUSH    BC
        AND     #01
        ADD     A,#F3
        CALL    L6011_108
        POP     BC
        LD      E,B
        INC     BC
        LD      A,B
        OR      C
        RET     Z
        LD      A,E

L6011_206:
        OR      A
        JR      Z,L6011_207
        DEC     A
        LD      C,#00
        JR      Z,L6011_208
        DEC     A
        LD      C,#05
        JR      Z,L6011_208
        DEC     A
        JR      Z,L6011_207
        DEC     A
        LD      C,#03
        JR      Z,L6011_208
        DEC     A
        LD      C,#04
        JR      Z,L6011_208
        DEC     A
        LD      C,#06
        JR      Z,L6011_208

L6011_207:
        LD      C,#01

L6011_208:
        LD      A,C
        CALL    #401B
        CALL    #4003
        RET     NZ
        CALL    #4009
        RET     NZ
        XOR     A
        RET

L6011_209:
        LD      HL,#0000
        LD      (#7F30),HL
        LD      (#7F32),HL
        JP      L6011_229

L6011_210:
        LD      HL,#0000
        LD      D,H
        LD      E,L
        LD      A,(#6018)
        CALL    L6011_172
        LD      A,#F4
        CALL    L6011_174
        LD      B,#1F
        CALL    L6011_177
        LD      B,#FF
        CALL    L6011_178
        LD      BC,#27AF
        LD      A,#01
        OUT     (C),A
        CALL    L6011_164

L6011_211:
        LD      A,(#6018)
        CALL    L6011_172
        LD      A,#F3
        CALL    L6011_174
        LD      BC,#27AF
        LD      A,#01
        OUT     (C),A
        CALL    L6011_164

L6011_212:
        LD      A,#F3
        JP      L6011_108

L6011_213:
        LD      B,#FF
        INC     HL

L6011_214:
        LD      A,(HL)
        OR      A
        RET     Z
        CP      #5C
        SCF
        RET     Z
        CP      #2F
        SCF
        RET     Z
        INC     HL
        DJNZ    L6011_214
        XOR     A
        DEC     A
        RET

L6011_215:
        LD      DE,#5E00
        LD      (DE),A
        INC     DE
        INC     HL
        EX      AF,AF'
        LD      A,#FF
        SUB     B
        RET     Z
        LD      C,#FF
        LD      B,A

L6011_216:
        LDI
        DJNZ    L6011_216
        LD      (#7F4F),HL
        XOR     A
        LD      (DE),A
        EX      AF,AF'
        INC     A
        RET

L6011_217:
        PUSH    HL
        CALL    L6011_213
        POP     HL
        JR      C,L6011_218
        JR      Z,L6011_226

L6011_218:
        INC     A
        RET     Z
        LD      A,#10
        CALL    L6011_215
        RET     Z
        CALL    L6011_224

L6011_219:
        LD      HL,#5E00
        CALL    #404E
        JR      Z,L6011_220
        LD      (#7F30),HL
        LD      (#7F32),DE
        CALL    L6011_229
        LD      HL,(#7F4F)
        CALL    L6011_213
        JR      C,L6011_221
        JR      Z,L6011_222

L6011_220:
        CALL    L6011_223
        XOR     A
        RET

L6011_221:
        LD      A,#10

L6011_222:
        LD      HL,(#7F4F)
        CALL    L6011_215
        JR      Z,L6011_220
        CP      #11
        JR      Z,L6011_219
        LD      HL,#5E00
        CALL    L6011_226
        JR      Z,L6011_220

L6011_223:
        PUSH    HL
        PUSH    DE
        CALL    L6011_225
        POP     DE
        POP     HL
        XOR     A
        INC     A
        RET

L6011_224:
        LD      DE,#7F34
        JP      #4021

L6011_225:
        LD      HL,#7F34
        JP      #401E

L6011_226:
        CALL    #404E
        RET     Z
        LD      (#7F30),HL
        LD      (#7F32),DE
        EXX
        LD      DE,#7F6B
        CALL    #4036
        LD      HL,(#7F87)
        LD      DE,(#7F89)
        RET

L6011_227:
        LD      DE,#7F30
        CALL    #4021
        CP      #01
        JR      Z,L6011_229
        OR      A
        RET     NZ

L6011_228:
        LD      HL,#7F30
        JP      #4012

L6011_229:
        LD      HL,#7F30
        JP      #401E

L6011_230:
        CALL    L6011_238
        CALL    #4039
        RET     NZ
        LD      (#7F28),HL
        LD      (#7F2A),DE
        PUSH    HL
        PUSH    DE
        LD      DE,#7F6B
        CALL    #4036
        CALL    L6011_155
        POP     DE
        POP     HL
        XOR     A
        RET

L6011_231:
        CALL    L6011_238
        JP      #403C

L6011_232:
        CALL    #403F
        RET     Z
        RET

L6011_233:
        LD      BC,#12AF
        IN      A,(C)
        LD      BC,(#6002)
        CP      C
        RET     NZ
        JP      #0000

L6011_234:
        LD      (#6F92),HL
        LD      (#7F4C),A
        RET

; API 86: управлять прерываниями плагина.
; A=#FF устанавливает адрес HL и флаг обработчика; A=0/1/2 меняет сразу все,
; таймерный либо PS/2-флаг в #7F4C..#7F4E.
INT_PL:
        CP      #FF
        JR      Z,L6011_234
        OR      A
        JR      Z,L6011_235
        DEC     A
        JR      Z,L6011_236
        DEC     A
        JR      Z,L6011_237
        RET

L6011_235:
        CALL    L6011_237
        LD      (#7F4C),A

L6011_236:
        LD      (#7F4D),A
        RET

L6011_237:
        LD      (#7F4E),A
        RET

L6011_238:
        PUSH    HL
        CALL    L6011_100
        LD      HL,#7F6B
        CALL    #4033
        POP     HL
        RET

; API 83: прочитать байт параметров плагина.
; Вход: A=1..8 — индекс; выход: A=значение, Z если значение равно нулю.
; A=0 и A>=9 завершаются без доступа к таблице.
PRM_PL:
        OR      A
        RET     Z
        CP      #09
        RET     NC
        DI
        LD      E,A
        LD      D,#00
        LD      A,#60
        CALL    L6011_115
        LD      HL,(#7F1A)
        ADD     HL,DE
        LD      C,(HL)
        CALL    L6011_113
        LD      A,C
        OR      A
        EI
        RET

; ABI плагинов Wild Commander. Номер функции приходит в A. Диспетчер читает
; соответствующее слово FUX, кладёт адрес на стек и выполняет RET, то есть
; передаёт управление выбранной процедуре без дополнительного уровня CALL.
; Это внешний API плагинов; его нельзя смешивать с внутренним API WildDOS #4000.
PLUGIN_API_DISPATCH:
FUN:
        EXX
        PUSH    HL
        LD      HL,PLUGIN_API_TABLE
        LD      B,#00
        LD      C,A
        ADD     HL,BC
        ADD     HL,BC
        LD      C,(HL)
        INC     HL
        LD      B,(HL)
        POP     HL
        PUSH    BC                      ; Адрес выбранной процедуры становится адресом возврата.
        EXX
        EX      AF,AF'

FEX:
        RET                             ; Пункты 76, 77 и 82 используют этот пустой обработчик.

; 87 двухбайтовых адресов API. Диапазон #6FEF..#709C является данными,
; а не исполняемыми командами.
PLUGIN_API_TABLE:
FUX:
        DW      MNGC_PL                 ;  0 MNGC_PL   — подключить страницу плагина к #C000.
        DW      PRWOW                   ;  1 PRWOW     — нарисовать окно по описателю IX.
        DW      RRESB                   ;  2 RRESB     — восстановить сохранённую область окна.
        DW      PRSRW                   ;  3 PRSRW     — скопировать строку в окно.
        DW      PRIAT                   ;  4 PRIAT     — записать атрибуты строки.
        DW      GADRW                   ;  5 GADRW     — вычислить экранный адрес в окне.
        DW      CURSOR                  ;  6 CURSOR    — выполнить фазу мигания курсора.
        DW      CURSER                  ;  7 CURSER    — погасить курсор с восстановлением фона.
        DW      YN                      ;  8 YN        — обслужить диалог «да/нет».
        DW      ISTR                    ;  9 ISTR      — выполнить команду строкового редактора.
        DW      NORK                    ; 10 NORK      — сформировать две шестнадцатеричные цифры.
        DW      TXTPR                   ; 11 TXTPR     — напечатать управляющую строку.
        DW      MEZZ                    ; 12 MEZZ      — выбрать сообщение и передать его TXTPR.
        DW      DMAPL                   ; 13 DMAPL     — выполнить команду DMA плагина.
        DW      TURBOPL                 ; 14 TURBOPL   — настроить частоту Z80 и кэш.
        DW      GEDPL                   ; 15 GEDPL     — инициализировать графическое окружение.
        DW      SPKE                    ; 16 SPKE      — проверить клавишу пробела.
        DW      UPPP                    ; 17 UPPP      — проверить стрелку вверх.
        DW      DWWW                    ; 18 DWWW      — проверить стрелку вниз.
        DW      LFFF                    ; 19 LFFF      — проверить стрелку влево.
        DW      RGGG                    ; 20 RGGG      — проверить стрелку вправо.
        DW      TAB_KEY                 ; 21 TAB_KEY   — проверить Tab.
        DW      ENKE                    ; 22 ENKE      — проверить Enter.
        DW      ESC_KEY                 ; 23 ESC_KEY   — проверить Esc.
        DW      BSPC                    ; 24 BSPC      — проверить Backspace.
        DW      PGU                     ; 25 PGU       — проверить Page Up.
        DW      PGD                     ; 26 PGD       — проверить Page Down.
        DW      HOME_KEY                ; 27 HOME_KEY  — проверить Home.
        DW      END_KEY                 ; 28 END_KEY   — проверить End.
        DW      F1_KEY                  ; 29 F1_KEY    — проверить F1.
        DW      F2_KEY                  ; 30 F2_KEY    — проверить F2.
        DW      F3_KEY                  ; 31 F3_KEY    — проверить F3.
        DW      F4_KEY                  ; 32 F4_KEY    — проверить F4.
        DW      F5_KEY                  ; 33 F5_KEY    — проверить F5.
        DW      F6_KEY                  ; 34 F6_KEY    — проверить F6.
        DW      F7_KEY                  ; 35 F7_KEY    — проверить F7.
        DW      F8_KEY                  ; 36 F8_KEY    — проверить F8.
        DW      F9_KEY                  ; 37 F9_KEY    — проверить F9.
        DW      F10_KEY                 ; 38 F10_KEY   — проверить F10.
        DW      ALT_KEY                 ; 39 ALT_KEY   — проверить Alt.
        DW      SHIFT_KEY               ; 40 SHIFT_KEY — проверить Shift.
        DW      CTRL_KEY                ; 41 CTRL_KEY  — проверить Ctrl.
        DW      KBSCN                   ; 42 KBSCN     — преобразовать scan-код в символ.
        DW      DELE                    ; 43 DELE      — проверить Delete.
        DW      CAPS_KEY                ; 44 CAPS_KEY  — проверить Caps Lock.
        DW      ANYK                    ; 45 ANYK      — проверить наличие любой клавиши.
        DW      USPO                    ; 46 USPO      — дождаться отпускания всех клавиш.
        DW      NUSP                    ; 47 NUSP      — дождаться нажатия клавиши.
        DW      XLD512                  ; 48 XLD512    — прочитать блоки LOAD512 через шлюз.
        DW      XSV512                  ; 49 XSV512    — записать блоки SAVE512 через шлюз.
        DW      XGIPGPL                 ; 50 XGIPGPL   — выбрать сохранённый каталог через GIPAG.
        DW      XTNTRY2                 ; 51 XTNTRY2   — скопировать 32-байтовую ENTRY.
        DW      XCHTS                   ; 52 XCHTS     — преобразовать цепочку через CHTOSE.
        DW      XTNTRYN                 ; 53 XTNTRYN   — зарезервированный пустой шлюз.
        DW      XTMRKFL                 ; 54 XTMRKFL   — найти и отметить файл.
        DW      XTMRKNX                 ; 55 XTMRKNX   — зарезервированный пустой шлюз.
        DW      XADIR                   ; 56 XADIR     — открыть сохранённый каталог.
        DW      XSTREAM                 ; 57 XSTREAM   — выполнить потоковую файловую команду.
        DW      XXTETY2                 ; 58 XXTETY2   — получить запись через NXTETY2.
        DW      XFENTRY                 ; 59 XFENTRY   — найти файловую запись.
        DW      XLD256                  ; 60 XLD256    — прочитать поток через LOAD256.
        DW      XLDNON                  ; 61 XLDNON    — пропустить данные через LOADNON.
        DW      XGFILE                  ; 62 XGFILE    — выбрать файл по сохранённому кластеру.
        DW      XGDIR                   ; 63 XGDIR     — загрузить сохранённый каталог.
        DW      MNGV_PL                 ; 64 MNGV_PL   — выбрать банк видеостраниц.
        DW      MNGCVPL                 ; 65 MNGCVPL   — подключить видеостраницу к #C000.
        DW      GVmod                   ; 66 GVmod     — задать видеорежим плагина.
        DW      GYoff                   ; 67 GYoff     — задать вертикальное смещение.
        DW      GXoff                   ; 68 GXoff     — задать горизонтальное смещение.
        DW      GVtm                    ; 69 GVtm      — назначить страницу регистру Vtm.
        DW      GVtl                    ; 70 GVtl      — назначить страницу регистру Vtl0/Vtl1.
        DW      GVsgp                   ; 71 GVsgp     — назначить страницу регистру Vsgp.
        DW      XMKfile                 ; 72 XMKfile   — создать файл через шлюз.
        DW      XMKdir                  ; 73 XMKdir    — создать каталог через шлюз.
        DW      XREname                 ; 74 XREname   — переименовать объект через шлюз.
        DW      XDelFl                  ; 75 XDelFl    — удалить файл через шлюз.
        DW      FEX                     ; 76 FEX       — пустой обработчик.
        DW      FEX                     ; 77 FEX       — пустой обработчик.
        DW      MNG0_PL                 ; 78 MNG0_PL   — подключить страницу плагина к #0000.
        DW      MNG8_PL                 ; 79 MNG8_PL   — подключить страницу плагина к #8000.
        DW      MNG0VPL                 ; 80 MNG0VPL   — подключить видеостраницу к #0000.
        DW      MNG8VPL                 ; 81 MNG8VPL   — подключить видеостраницу к #8000.
        DW      FEX                     ; 82 FEX       — пустой обработчик.
        DW      PRM_PL                  ; 83 PRM_PL    — прочитать параметр плагина.
        DW      SCRLWOW                 ; 84 SCRLWOW   — прокрутить прямоугольник окна.
        DW      INS_KEY                 ; 85 INS_KEY   — проверить Insert.
        DW      INT_PL                  ; 86 INT_PL    — настроить прерывания плагина.
        ASSERT  $ == #709D, нарушена конечная граница FUX

L6011_240:
        PUSH    BC
        CALL    L6011_241
        POP     HL
        LD      A,#00
        CALL    L6011_244
        PUSH    AF
        LD      A,#02
        CALL    L6011_110
        CALL    L6011_155
        POP     AF
        RET

L6011_241:
        LD      A,(#B000)
        LD      (#7F15),A
        LD      HL,#B023
        ADD     A,(HL)
        ADD     A,#61
        JP      L6011_110

L6011_242:
        LD      A,#01

L6011_243:
        PUSH    AF
        CALL    L6011_241
        POP     AF
        CALL    L6011_244
        PUSH    AF
        LD      A,#02
        CALL    L6011_110
        POP     AF
        RET

L6011_244:
        PUSH    AF
        XOR     A
        LD      (#7F21),A
        LD      (#7F22),A
        LD      (#7F23),A
        CALL    L6011_114
        POP     AF
        LD      BC,(#6000)
        LD      (#600B),BC
        LD      (#6018),BC
        PUSH    BC
        LD      BC,(#7F2A)
        PUSH    BC
        LD      BC,(#7F28)
        PUSH    BC
        LD      BC,(L6011)
        LD      (#6013),BC
        LD      (#7F24),IX
        EX      AF,AF'
        LD      A,#00
        EX      AF,AF'
        EXX
        LD      L,(IX+#10)
        LD      H,(IX+#11)
        LD      E,(IX+#0C)
        LD      D,#00
        ADD     HL,DE
        LD      E,(IX+#12)
        LD      D,(IX+#13)
        EXX
        LD      BC,#5E00
        CALL    F5WND
        LD      IX,(#7F24)
        LD      HL,(#6013)
        LD      (L6011),HL
        POP     HL
        LD      (#7F28),HL
        POP     HL
        LD      (#7F2A),HL
        POP     HL
        PUSH    AF
        LD      A,L
        CALL    L6011_108
        CALL    L6011_154
        CALL    L6011_139
        POP     AF
        RET
