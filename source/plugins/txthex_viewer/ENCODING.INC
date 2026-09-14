; Декодирование в однобайтовый шрифт WC. UTF-8 проверяется строго:
; C0/C1, одиночные продолжения, overlong, суррогаты и значения > U+10FFFF
; не принимаются. Неотображаемая Unicode-буква занимает одну клетку '?'.
; Ошибочный префикс не поглощает следующий ASCII/CR/LF. Разрыв последовательности
; между двумя 4-КиБ окнами обрабатывается тем же ReadByte, что обычный текст.

ReadChar:
        PUSH BC
        PUSH DE
        PUSH HL
        CALL DecodeChar
        POP HL
        POP DE
        POP BC
        RET
DecodeChar:
        CALL ReadByte
        RET C
        CP #80
        JR NC,.high
        OR A                            ; ASCII #00 — данные, CF не является EOF
        RET
.high:
        LD B,A
        LD A,(Encoding)
        OR A
        LD A,B
        RET Z
        PUSH AF
        LD A,(Encoding)
        CP 1
        JR NZ,.utf
        POP AF
        SUB #80
        LD L,A
        LD H,0
        LD DE,WindowsTo866
        ADD HL,DE
        LD A,(HL)
        OR A
        RET
.utf:
        POP AF
        LD (UtfFirst),A
        LD B,A
        LD A,1
        LD (UtfSeen),A
        LD A,B
        CP #C2
        JP C,InvalidUtf
        CP #F5
        JP NC,InvalidUtf
        LD C,1
        CP #E0
        JR C,.two
        INC C
        CP #F0
        JR C,.three
        INC C
        AND 7
        JR .start
.three:
        AND 15
        JR .start
.two:
        AND 31
.start:
        LD E,A
        LD D,0
        LD A,C
        LD (UtfRemaining),A
        ; Дополнительные границы второго байта нужны до его потребления.
        CALL PeekByte
        JP C,InvalidUtf
        LD B,A
        LD A,(UtfFirst)
        CP #E0
        JR NZ,.surrogate
        LD A,B
        CP #A0
        JP C,InvalidUtf
.surrogate:
        LD A,(UtfFirst)
        CP #ED
        JR NZ,.overlong4
        LD A,B
        CP #A0
        JP NC,InvalidUtf
.overlong4:
        LD A,(UtfFirst)
        CP #F0
        JR NZ,.max
        LD A,B
        CP #90
        JP C,InvalidUtf
.max:
        LD A,(UtfFirst)
        CP #F4
        JR NZ,.continuation
        LD A,B
        CP #90
        JP NC,InvalidUtf
.continuation:
        CALL PeekByte
        JP C,InvalidUtf
        CP #80
        JP C,InvalidUtf
        CP #C0
        JP NC,InvalidUtf
        CALL ReadByte
        AND #3F
        LD B,A
        DUP 6
          SLA E
          RL D
        EDUP
        LD A,E
        OR B
        LD E,A
        LD HL,UtfRemaining
        DEC (HL)
        JR NZ,.continuation
        LD A,(UtfFirst)
        CP #F0
        LD A,"?"
        JR NC,.ok                      ; шрифт CP866 не имеет символов вне BMP
        CALL UnicodeTo866
.ok:
        OR A
        RET

InvalidUtf:
        LD A,1
        LD (UtfBad),A
        LD A,"?"
        OR A
        RET

; DE=Unicode BMP -> A=CP866 или '?'. ASCII и русские буквы — быстрые ветви;
; прочие 128 символов штатного шрифта находятся по полной Unicode-таблице.
; Кодировка файлов не меняется: преобразование применяется только к экрану.
UnicodeTo866:
        LD A,D
        OR A
        JR NZ,.russian
        LD A,E
        CP #80
        JR C,.return
.russian:
        LD A,D
        CP 4
        JR NZ,.table
        LD A,E
        CP #10
        JR C,.yo
        CP #40
        JR NC,.lower
        ADD A,#70
        JR .return
.lower:
        CP #50
        JR NC,.yo
        ADD A,#A0
        JR .return
.yo:
        CP 1
        LD A,#F0
        JR Z,.return
        LD A,E
        CP #51
        LD A,#F1
        JR Z,.return
.table:
        LD HL,Unicode866
        LD B,128
        LD C,#80
.find:
        LD A,(HL)
        INC HL
        CP E
        JR NZ,.next
        LD A,(HL)
        CP D
        JR Z,.found
.next:
        INC HL
        INC C
        DJNZ .find
        LD A,"?"
        JR .return
.found:
        LD A,C
.return:
        OR A
        RET

; DetectEncoding исследует до 4096 исходных байт, а не весь большой файл.
; UTF-8 с BOM имеет приоритет. Без BOM нужен строгий UTF-8 и хотя бы один
; многобайтовый символ: чистый ASCII совместим со всеми тремя кодировками.
; CP866/1251 сравниваются по русским буквам и частым биграммам; это эвристика,
; поэтому F8 всегда позволяет явный выбор. При равных оценках выбираем CP866.
DetectEncoding:
        LD HL,Position
        CALL Zero32
        LD A,#FF
        LD (Prev866),A
        LD (Prev1251),A
        LD BC,4096
.raw:
        CALL ReadByte
        JR C,.raw_done
        CP 9
        JR Z,.ascii
        CP 10
        JR Z,.ascii
        CP 13
        JR Z,.ascii
        CP 32
        JR C,.binary
        CP #7F
        JR NZ,.score
.binary:
        PUSH AF
        LD A,1
        LD (BinarySample),A
        POP AF
.score:
        CP #80
        JR C,.ascii
        PUSH BC
        PUSH AF
        LD HL,Letters866
        CALL NormalizedLetter
        LD HL,Score866
        LD DE,Prev866
        CALL ScoreLetter
        POP AF
        LD HL,Letters1251
        CALL NormalizedLetter
        LD HL,Score1251
        LD DE,Prev1251
        CALL ScoreLetter
        POP BC
        JR .next
.ascii:
        LD A,#FF
        LD (Prev866),A
        LD (Prev1251),A
.next:
        DEC BC
        LD A,B
        OR C
        JR NZ,.raw
.raw_done:
        LD A,(Score1251+1)
        XOR #80
        LD B,A
        LD A,(Score866+1)
        XOR #80
        CP B
        JR C,.windows
        JR NZ,.utf_probe
        LD A,(Score1251)
        LD B,A
        LD A,(Score866)
        CP B
        JR NC,.utf_probe
.windows:
        LD A,1
        LD (Detected),A
.utf_probe:
        LD HL,Position
        CALL Zero32
        LD A,2
        LD (Encoding),A
.utf_loop:
        CALL ReadChar
        JR C,.utf_done
        LD A,(UtfBad)
        OR A
        JR NZ,.utf_done
        LD HL,(Position)
        LD A,H
        CP #10
        JR C,.utf_loop
.utf_done:
        LD A,(UtfBad)
        OR A
        JR NZ,.bom
        LD A,(UtfSeen)
        OR A
        JR Z,.bom
        LD A,2
        LD (Detected),A
.bom:
        ; Проверяем исходные три байта отдельно: UTF-8 BOM не является текстом.
        LD HL,Position
        CALL Zero32
        CALL ReadByte
        JR C,.apply
        CP #EF
        JR NZ,.apply
        CALL ReadByte
        JR C,.apply
        CP #BB
        JR NZ,.apply
        CALL ReadByte
        JR C,.apply
        CP #BF
        JR NZ,.apply
        LD A,1
        LD (HasBom),A
        LD A,2
        LD (Detected),A
.apply:
        LD A,(Detected)
        LD (Encoding),A
        JP SetTextStart

; Вход A=#80..#FF, HL=таблица нормализации. Выход A=0..31 либо #FF.
NormalizedLetter:
        SUB #80
        LD E,A
        LD D,0
        ADD HL,DE
        LD A,(HL)
        RET

; A=номер русской буквы, HL=знаковая оценка, DE=предыдущая буква.
; Буква даёт +2; частая биграмма ещё +6; редкая биграмма уменьшает добавку
; до +1. Не-буква среди верхних байт даёт -2. При 4096 байтах нет переполнения
; знакового 16-битного аккумулятора (максимум 32762).
ScoreLetter:
        LD B,A
        LD A,(DE)
        LD C,A
        LD A,B
        LD (DE),A
        PUSH HL
        LD DE,-2
        CP 32
        JR NC,.add
        LD DE,2
        LD A,C
        CP 32
        JR NC,.add
        LD L,C
        LD H,0
        ADD HL,HL
        ADD HL,HL
        LD A,B
        SRL A
        SRL A
        SRL A
        LD E,A
        LD D,0
        ADD HL,DE
        LD DE,CommonBigrams
        ADD HL,DE
        LD C,(HL)
        LD A,B
        AND 7
        JR Z,.bit
        LD B,A
.shift:
        SRL C
        DJNZ .shift
.bit:
        LD DE,1
        BIT 0,C
        JR Z,.add
        LD DE,8
.add:
        POP HL
        LD C,(HL)
        INC HL
        LD B,(HL)
        EX DE,HL
        ADD HL,BC
        EX DE,HL
        LD (HL),D
        DEC HL
        LD (HL),E
        RET

; BOM скрывается только в UTF-8. При ручном CP866/1251 доступны все байты.
SetTextStart:
        LD HL,TextStart
        CALL Zero32
        LD A,(Encoding)
        CP 2
        RET NZ
        LD A,(HasBom)
        OR A
        RET Z
        LD A,3
        LD (TextStart),A
        RET

NextEncoding:
        LD A,(Choice)
        INC A
        AND 3
        LD (Choice),A
        JR NZ,.manual
        LD A,(Detected)
        JR .set
.manual:
        DEC A
.set:
        LD (Encoding),A
        CALL SetTextStart
        CALL BuildSearch                ; Ctrl+G должен искать в новой кодировке
        XOR A
        LD (SearchAgain),A
        CALL GoHome                     ; новая кодировка меняет границы строк
        JP DrawPage
