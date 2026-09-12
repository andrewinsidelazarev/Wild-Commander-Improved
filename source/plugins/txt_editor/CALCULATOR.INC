; AlexKorochinskiy / 2026-09-12: разбор выражений окна Inspector.
; Вход: DE -> строка с нулём на конце, не длиннее CALCBUFL (40) байтов.
; Выход: BC = беззнаковое 16-битное значение, Z/NC = успех;
;        A = код ошибки, NZ/C = ошибка (BC в этом случае не использовать).
; Меняются AF/BC/DE/HL; IX/IY сохраняются. Стек восстанавливается при любой
; ошибке, независимо от глубины скобок и уже сохранённых левых операндов.
;
; Приоритеты: скобки/литералы -> унарные + - [старший ]младший байт ->
; * / \ -> + -. Бинарные операции одного приоритета ассоциативны слева.
; Литералы: десятичные, #шестнадцатеричные, %двоичные, "A" или "AB".
; Литерал >65535 считается ошибкой; арифметический результат берётся по
; модулю 65536. Деление и остаток беззнаковые. Пробелы вне кавычек заранее
; удаляет CALC_BUF_CONV, поэтому пробел внутри " " остаётся частью константы.
DECODER LD (DSP),SP
        CALL CALC_EXPR
        LD A,(DE):OR A:JP NZ,CALC_BAD
        LD BC,HL:XOR A:RET

; Каждый уровень получает DE=позиция разбора и возвращает HL=значение,
; DE=первый ещё не обработанный символ. Отсутствующий операнд не читается
; со стека: CALC_ATOM обязательно проверяет начало следующего литерала.
CALC_EXPR CALL CALC_TERM
CALC_ADD_LOOP LD A,(DE):CP "+":JR Z,CALC_ADD_OP
              CP "-":RET NZ
CALC_ADD_OP INC DE:PUSH HL,AF
            CALL CALC_TERM
            POP AF,BC:CP "+":JR Z,CALC_PLUS
            PUSH DE:EX DE,HL:LD HL,BC
            OR A:SBC HL,DE:POP DE:JR CALC_ADD_LOOP
CALC_PLUS ADD HL,BC:JR CALC_ADD_LOOP

; На стеке храним левое значение и знак, пока рекурсивно разбирается правое.
; Адрес строки DE временно сохраняется перед арифметикой, использующей DE.
CALC_TERM CALL CALC_UNARY
CALC_TERM_LOOP LD A,(DE):CP "*":JR Z,CALC_TERM_OP
               CP "/":JR Z,CALC_TERM_OP
               CP "\\":RET NZ
CALC_TERM_OP INC DE:PUSH HL,AF
             CALL CALC_UNARY
             POP AF,BC:PUSH DE
             CP "*":JR Z,CALC_TERM_MUL
             PUSH AF
             EX DE,HL:LD HL,BC,B,D,C,E
             LD A,B:OR C:JP Z,CALC_DIVZERO
             POP AF:CP "\\":JR Z,CALC_TERM_MOD
             CALL CALC_UDIV:JR CALC_TERM_DONE
CALC_TERM_MOD CALL CALC_UDIV:EX DE,HL:JR CALC_TERM_DONE
CALC_TERM_MUL CALL CALC_MULTIPLY
CALC_TERM_DONE POP DE:JR CALC_TERM_LOOP

; Цепочки унарных знаков допустимы; ограничение строки в 40 байт ограничивает
; и глубину рекурсии. Унарный минус: 0-HL с переносом между младшим и старшим.
CALC_UNARY LD A,(DE):CP "+":JR Z,CALC_UNARY_PLUS
           CP "-":JR Z,CALC_UNARY_MINUS
           CP "[":JR Z,CALC_UNARY_HI
           CP "]":JR Z,CALC_UNARY_LO
           JP CALC_ATOM
CALC_UNARY_PLUS INC DE:JP CALC_UNARY
CALC_UNARY_MINUS INC DE:CALL CALC_UNARY
                 XOR A:SUB L:LD L,A
                 LD A,0:SBC A,H:LD H,A:RET
CALC_UNARY_HI INC DE:CALL CALC_UNARY:LD L,H,H,0:RET
CALC_UNARY_LO INC DE:CALL CALC_UNARY:LD H,0:RET

; Скобки обязаны содержать выражение и иметь закрывающую пару. Символьная
; константа содержит строго один или два байта, первый из двух — старший.
CALC_ATOM LD A,(DE):CP "(":JR Z,CALC_PAREN
          CP #22:JR Z,CALC_QUOTED
          LD C,10
          CP "#":JR Z,CALC_HEX
          CP "%":JR Z,CALC_BINARY
          CP "0":JP C,CALC_BAD
          CP "9"+1:JP NC,CALC_BAD
          JR CALC_NUMBER
CALC_HEX INC DE:LD C,16:JR CALC_NUMBER
CALC_BINARY INC DE:LD C,2:JR CALC_NUMBER
CALC_PAREN INC DE:CALL CALC_EXPR
           LD A,(DE):CP ")":JP NZ,CALC_PAREN_ERROR
           INC DE:RET
CALC_QUOTED INC DE:LD A,(DE):OR A:JP Z,CALC_QUOTE_ERROR
            CP #22:JP Z,CALC_QUOTE_ERROR
            LD L,A,H,0:INC DE
            LD A,(DE):CP #22:JR Z,CALC_QUOTE_END
            OR A:JP Z,CALC_QUOTE_ERROR
            LD H,L,L,A:INC DE
            LD A,(DE):CP #22:JP NZ,CALC_QUOTE_ERROR
CALC_QUOTE_END INC DE:RET

; Число накапливается как старое*основание+цифра. Проверяем перенос каждого
; сдвига/сложения, а не только последнего: иначе #10000 превратится в ноль.
; CALC_DIGITS отличает настоящий ноль от голого префикса '#' или '%'.
CALC_NUMBER LD A,C,(CALC_BASE),A
            XOR A:LD (CALC_DIGITS),A
            LD HL,0
CALC_NUMBER_LOOP LD A,(DE):CALL CALC_DIGIT
                 JR NC,CALC_NUMBER_END
                 LD (CALC_DIGIT_VALUE),A
                 INC DE
                 LD A,(CALC_BASE):CP 10:JR Z,CALC_TIMES10
                 CP 16:JR Z,CALC_TIMES16
                 ADD HL,HL:JP C,CALC_BAD
                 JR CALC_ADD_DIGIT
CALC_TIMES16 LD B,4
CALC_HEX_SHIFT ADD HL,HL:JP C,CALC_BAD
               DJNZ CALC_HEX_SHIFT:JR CALC_ADD_DIGIT
CALC_TIMES10 LD BC,HL
             ADD HL,HL:JP C,CALC_BAD
             ADD HL,HL:JP C,CALC_BAD
             ADD HL,BC:JP C,CALC_BAD
             ADD HL,HL:JP C,CALC_BAD
CALC_ADD_DIGIT LD A,(CALC_DIGIT_VALUE),C,A,B,0
               ADD HL,BC:JP C,CALC_BAD
               LD A,1,(CALC_DIGITS),A:JR CALC_NUMBER_LOOP
CALC_NUMBER_END LD A,(CALC_DIGITS):OR A:JP Z,CALC_BAD
                RET

; A=символ -> A=цифра и C, если она входит в текущее основание; иначе NC.
; Строчные и прописные A..F равнозначны. Меняются AF/B, DE/HL сохраняются.
CALC_DIGIT CP "0":JR C,CALC_NOT_DIGIT
           CP "9"+1:JR C,CALC_DEC_DIGIT
           AND #DF
           CP "A":JR C,CALC_NOT_DIGIT
           CP "F"+1:JR NC,CALC_NOT_DIGIT
           SUB "A"-10:JR CALC_DIGIT_RANGE
CALC_DEC_DIGIT SUB "0"
CALC_DIGIT_RANGE LD B,A,A,(CALC_BASE):CP B
                 JR C,CALC_NOT_DIGIT,Z,CALC_NOT_DIGIT
                 LD A,B:SCF:RET
CALC_NOT_DIGIT OR A:RET

; BC*HL -> младшие 16 бит в HL. Меняются AF/DE/HL, BC сохраняется.
; Переполнение арифметики намеренно отбрасывается (контракт 16-битного слова).
CALC_MULTIPLY EX DE,HL:LD HL,0,A,16
CALC_MUL_LOOP ADD HL,HL:RL E,D:JR NC,CALC_MUL_NEXT
              ADD HL,BC:JR NC,CALC_MUL_NEXT
              INC DE
CALC_MUL_NEXT DEC A:JR NZ,CALC_MUL_LOOP:RET

; HL/BC -> HL=частное, DE=остаток; BC сохраняется, AF меняется, BC<>0.
; Деление по битам за 16 шагов. Перенос после RL D — семнадцатый бит
; остатка. Проверяем его ДО OR/SBC: потеря этого бита ломала большие делители
; в старом алгоритме. При установленном переносе вычитание обязательно;
; после него остаток снова помещается в 16 бит. Бит частного хранится в E
; во время EX DE,HL, затем вместе с остальными битами возвращается в HL.
CALC_UDIV LD DE,0,A,16
CALC_DIV_LOOP ADD HL,HL:RL E,D
              EX DE,HL:JR C,CALC_DIV_CARRY
              OR A:SBC HL,BC:JR C,CALC_DIV_BORROW
              SET 0,E:JR CALC_DIV_NEXT
CALC_DIV_BORROW ADD HL,BC:JR CALC_DIV_NEXT
CALC_DIV_CARRY OR A:SBC HL,BC:SET 0,E
CALC_DIV_NEXT EX DE,HL:DEC A:JR NZ,CALC_DIV_LOOP:RET

; Единый аварийный выход. DSP — SP на входе DECODER, то есть адрес возврата
; вызывающей процедуры. Восстановление SP снимает все рекурсивные кадры,
; включая временно сохранённый адрес строки при обнаружении деления на ноль.
CALC_BAD LD A,24:JR CALC_ABORT
CALC_PAREN_ERROR LD A,23:JR CALC_ABORT
CALC_QUOTE_ERROR LD A,27:JR CALC_ABORT
CALC_DIVZERO LD A,26
CALC_ABORT LD SP,(DSP):OR A:SCF:RET

CALC_BASE DB 0
CALC_DIGITS DB 0
CALC_DIGIT_VALUE DB 0
