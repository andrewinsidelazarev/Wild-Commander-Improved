; Детект и ручное переключение из TXTVIEW v0.26.
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
