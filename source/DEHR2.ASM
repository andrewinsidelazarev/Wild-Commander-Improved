; DEHR2 — распаковщик драйверов WildDOS из Hrust-подобного контейнера.
; Физический адрес в boot.$C: #DAB6; рабочий адрес после копирования: #5AAA.
;
; Основные этапы:
;   DEHR_UNPACK_DRIVER          — прочитать размеры и подготовить размещение;
;   DEHR_MOVE_OVERLAPPED_STREAM — безопасно перенести перекрывающийся поток;
;   DEHR_SAVE_LAST_6_BYTES      — сохранить хвост результата из заголовка;
;   DEHR_TOKEN_LOOP             — основной цикл литералов и LZ-совпадений;
;   DEHR_DECODE_MATCH_LENGTH    — декодировать длину совпадения;
;   DEHR_DECODE_MATCH_OFFSET    — декодировать отрицательное смещение;
;   DEHR_COPY_MATCH             — скопировать ранее распакованные байты;
;   DEHR_EXTENDED_COMMAND       — длинные команды и терминатор;
;   DEHR_APPEND_LAST_6_BYTES    — дописать сохранённый хвост;
;   DEHR_REFILL_16_BITS         — пополнить 16-битный битовый резервуар.
;
; Вход:
;   HL — начало упакованного блока с сигнатурой "HR";
;   DE — начало области результата (DOS_SWP передаёт #3800).
; Выход:
;   распакованный драйвер записан начиная с исходного DE;
;   отдельного кода состояния нет.
; Разрушаются:
;   AF, BC, DE, HL, альтернативный набор регистров и IX.
;
; Формат блока, доказанный кодом ниже и четырьмя встроенными драйверами:
;   +0..+1  48 52, сигнатура "HR";
;   +2..+3  размер результата, little-endian;
;   +4..+5  полный размер упакованного блока, little-endian;
;   +6..+11 последние шесть байт результата;
;   +12..   поток команд и литералов.
; Сигнатура "HR" самой процедурой не проверяется: первые два байта просто
; пропускаются. Контрольной суммы, проверки границ и кода ошибки нет;
; вызывающая сторона обязана передать корректные размеры и поток с терминатором.
;
; Физически процедура лежит в boot.$C по #DAB6, но после установки WildDOS
; исполняется по #5AAA. Поэтому BOOT.ASM включает этот исходник внутри
; DISP #5AAA: абсолютные CALL должны вычисляться относительно рабочего адреса.
DEHR_UNPACK_DRIVER:
DEHRUST PUSH DE            ; Сохранить адрес начала результата.
        PUSH HL
        INC HL
        INC HL
        LD C,(HL)          ; BC = размер распакованного результата (+2).
        INC HL
        LD B,(HL)
        INC HL
        DEC BC
        EX DE,HL
        ADD HL,BC          ; DE = адрес последнего байта результата.
        EX DE,HL
        LD C,(HL)          ; BC = полный размер упакованного блока (+4).
        INC HL
        LD B,(HL)
        DEC BC
        POP HL
        ADD HL,BC          ; HL = последний байт упакованного блока.
        SBC HL,DE
        ADD HL,DE
        JR C,LL4019
        LD D,H
        LD E,L
; Если вход пересекается с будущим результатом, поток переносится с конца.
; Направление LDDR не позволяет ещё не прочитанным байтам быть затёртыми.
DEHR_MOVE_OVERLAPPED_STREAM:
LL4019  LDDR
        EX DE,HL
        POP DE
        LD C,#0C           ; Пропустить 12-байтовую служебную часть.
        ADD HL,BC
        PUSH HL
        POP IX             ; IX указывает на первый байт потока.
        LD A,#03
; Три слова из +6..+11 временно сохраняются на стеке. При завершении они
; дописываются как последние шесть байт результата.
DEHR_SAVE_LAST_6_BYTES:
LL4025  DEC HL
        LD B,(HL)
        DEC HL
        LD C,(HL)
        PUSH BC
        DEC A
        JR NZ,LL4025
        LD B,A
        EXX
        LD D,#BF           ; Адаптивное состояние кодирования смещения.
        LD C,#10           ; Пополнение битового резервуара идёт по 16 бит.
        CALL LL4115
; Литеральный токен: один байт копируется из потока непосредственно в DE.
DEHR_OUTPUT_LITERAL:
LL4036  LD A,(IX+#00)
        INC IX
        EXX
LL403C  LD (DE),A
        INC DE
; Основной цикл токенов. HL' — битовый резервуар, B' — число доступных битов.
DEHR_TOKEN_LOOP:
LL403E  EXX
DEHR_READ_TOKEN_BIT:
LL403F  ADD HL,HL
        DJNZ LL4045
        CALL LL4115
LL4045  JR C,LL4036
        LD E,#01
; Декодирование длины совпадения переменным префиксным кодом.
DEHR_DECODE_MATCH_LENGTH:
LL4049  LD A,#80
LL404B  ADD HL,HL
        DJNZ LL4051
        CALL LL4115
LL4051  RLA
        JR C,LL404B
        CP #03
        JR C,LL405D
        ADD A,E
        LD E,A
        XOR C
        JR NZ,LL4049
LL405D  ADD A,E
        CP #04
        JR Z,LL40C4
        ADC A,#FF
        CP #02
        EXX
DEHR_STORE_MATCH_LENGTH:
LL4067  LD C,A
LL4068  EXX
        LD A,#BF
        JR C,LL4082
; Декодирование отрицательного смещения до уже выведенных данных.
DEHR_DECODE_MATCH_OFFSET:
LL406D  ADD HL,HL
        DJNZ LL4073
        CALL LL4115
LL4073  RLA
        JR C,LL406D
        JR Z,LL407D
        INC A
        ADD A,D
        JR NC,LL4084
        SUB D
LL407D  INC A
        JR NZ,LL408D
        LD A,#EF
LL4082  RRCA
        CP A
LL4084  ADD HL,HL
        DJNZ LL408A
        CALL LL4115
LL408A  RLA
        JR C,LL4084
DEHR_BUILD_MATCH_OFFSET:
LL408D  EXX
        LD H,#FF
        JR Z,LL409B
        LD H,A
        INC A
        LD A,(IX+#00)
        INC IX
        JR Z,LL40A6
; HL = DE + отрицательное смещение; BC содержит длину совпадения.
DEHR_COPY_MATCH:
LL409B  LD L,A
        ADD HL,DE
        LDIR
LL409F  JR LL403E
DEHR_CHANGE_OFFSET_CONTEXT:
LL40A1  EXX
        RRC D
        JR LL403F
; Специальные коды коротких и контекстных смещений.
DEHR_SPECIAL_OFFSET_CODE:
LL40A6  CP #E0
        JR C,LL409B
        RLCA
        XOR C
        INC A
        JR Z,LL40A1
        SUB #10
; Короткое совпадение с последующим литералом.
DEHR_SHORT_MATCH_WITH_LITERAL:
LL40B1  LD L,A
        LD C,A
        LD H,#FF
        ADD HL,DE
        LDI
        LD A,(IX+#00)
        INC IX
        LD (DE),A
        INC HL
        INC DE
        LD A,(HL)
        JP LL403C
; Расширенная команда: длинное совпадение, блок литералов либо конец потока.
DEHR_EXTENDED_COMMAND:
LL40C4  LD A,#80
LL40C6  ADD HL,HL
        DJNZ LL40CC
        CALL LL4115
LL40CC  ADC A,A
        JR NZ,LL40F3
        JR C,LL40C6
        LD A,#FC
        JR LL40F6
DEHR_LENGTH_FROM_STREAM_BYTE:
LL40D5  LD B,A
        LD C,(IX+#00)
        INC IX
        CCF
        JR LL4068
DEHR_CHECK_END_MARKER:
LL40DE  CP #0F
        JR C,LL40D5
        JR NZ,LL4067
        LD B,#03
        EX DE,HL
; Терминатор #0F: восстановить три сохранённых слова и дописать хвост.
DEHR_APPEND_LAST_6_BYTES:
LL40E7  POP DE
        LD (HL),E
        INC HL
        LD (HL),D
        INC HL
        DJNZ LL40E7
        RET
;-------
DEHR_EXTENDED_PREFIX:
LL40F3  SBC A,A
        LD A,#EF
LL40F6  ADD HL,HL
        DJNZ LL40FC
        CALL LL4115
LL40FC  RLA
        JR C,LL40F6
        EXX
        JR NZ,LL40B1
        BIT 7,A
        JR Z,LL40DE
        SUB #EA
        ADD A,A
        LD B,A
; Блок несжатых литералов; B задаёт число копируемых байтов.
DEHR_COPY_LITERAL_RUN:
LL410A  LD A,(IX+#00)
        INC IX
        LD (DE),A
        INC DE
        DJNZ LL410A
        JR LL409F
; Пополнить битовый резервуар следующим 16-битным словом потока.
DEHR_REFILL_16_BITS:
LL4115  LD B,C
        LD L,(IX+#00)
        INC IX
        LD H,(IX+#00)
        INC IX
        RET
LCODE   EQU $-DEHRUST      ; Размер процедуры: #011D (285 байт).
