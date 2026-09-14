; Потоковый ввод и арифметика LE32. Содержимое файла никогда не изменяется.
; PeekByte/ReadByte сохраняют BC, DE, HL, IX. AF — результат:
; CF=0, A=байт; CF=1 — EOF, ошибка или отмена. IoError и Cancelled позволяют
; отличить последние два случая от нормального конца, включая пустой файл.

PeekByte:
        PUSH HL
        ; Внутри загруженного окна достаточно проверить его адрес и длину.
        ; CacheLength уже ограничена логическим EOF в FillCache, поэтому
        ; повторное Compare32 для каждого байта не требуется. На быстром пути
        ; меняются только AF/HL; BC, DE и IX сохраняем лишь перед файловым API.
        LD HL,Cancelled
        LD A,(IoError)
        OR (HL)
        JR NZ,.end
        LD A,(CacheValid)
        OR A
        JR Z,.refill
        LD HL,(Position+2)
        LD A,(CacheBase+2)
        CP L
        JR NZ,.refill
        LD A,(CacheBase+3)
        CP H
        JR NZ,.refill
        LD A,(Position+1)
        AND #F0
        LD HL,CacheBase+1
        CP (HL)
        JR NZ,.refill
.offset:
        LD HL,(Position)
        LD A,H
        AND #0F
        LD H,A                         ; HL — смещение 0..4095 внутри окна
        LD A,(CacheLength+1)
        CP H
        JR C,.end
        JR NZ,.cached
        LD A,(CacheLength)
        CP L
        JR C,.end
        JR Z,.end                      ; последний неполный блок не читаем за EOF
.cached:
        LD A,H
        OR HIGH CACHE
        LD H,A
        LD A,(HL)
        OR A                           ; CF=0 даже для байта #00
.return:
        POP HL
        RET
.refill:
        PUSH BC
        PUSH DE
        PUSH IX
        ; При промахе обязательно проверяем все 32 бита до вычитания в FillCache.
        ; Это сохраняет границы 64 КиБ/16 МиБ/2 ГиБ и EOF на FFFFFFFF.
        LD HL,Position
        LD DE,FileSize
        CALL Compare32
        JR NC,.miss_end
        CALL FillCache
        JR .miss_done
.miss_end:
        SCF
.miss_done:
        POP IX
        POP DE
        POP BC
        JR NC,.offset
.end:
        SCF
        JR .return

ReadByte:
        CALL PeekByte
        RET C
        PUSH AF
        PUSH HL
        LD HL,Position
        CALL Increment32
        POP HL
        POP AF
        RET

; При последовательном чтении используем LOAD512: не обходим FAT-цепочку
; заново на каждом окне. Промах назад/End обслуживает FILEX.READ_AT, который
; сохраняет последовательный поток. Поэтому обычная прокрутка вперёд линейна.
; Без FILEX доступен совместимый путь: FENTRY/GFILE и повторное чтение до
; требуемого окна; он медленнее, но не ограничивает размер одним мегабайтом.
FillCache:
        XOR A
        LD (CacheValid),A
        CALL CheckCancel
        RET C
        LD HL,Position
        LD DE,CacheBase
        CALL Copy32
        XOR A
        LD (CacheBase),A
        LD A,(CacheBase+1)
        AND #F0
        LD (CacheBase+1),A
        ; length = min(4096, FileSize - CacheBase), строго до логического EOF.
        LD HL,(FileSize)
        LD DE,(CacheBase)
        OR A
        SBC HL,DE
        PUSH HL
        LD HL,(FileSize+2)
        LD DE,(CacheBase+2)
        SBC HL,DE
        LD A,H
        OR L
        POP HL
        JR NZ,.full
        LD A,H
        CP HIGH CACHE_SIZE
        JR C,.length
.full:
        LD HL,CACHE_SIZE
.length:
        LD (CacheLength),HL
        LD HL,CacheBase
        LD DE,StreamNext
        CALL Compare32
        JP Z,.sequential
        LD A,(HaveFilex)
        OR A
        JR Z,.fallback
        CALL ClearFilex
        LD A,1
        LD (FilexBlock+2),A
        LD HL,CacheBase
        LD DE,FilexBlock+4
        CALL Copy32
        LD HL,CACHE
        LD (FilexBlock+8),HL
        LD HL,(CacheLength)
        LD (FilexBlock+10),HL
        CALL CallFilex
        ; EOF со всеми запрошенными байтами допустим; короткое чтение при
        ; заявленном большем размере означает повреждённую цепочку/носитель.
        CP 2
        JP NC,ReadFailure
        LD HL,(FilexBlock+26)
        LD A,H
        OR L
        JP NZ,ReadFailure
        LD HL,(FilexBlock+24)
        LD DE,(CacheLength)
        OR A
        SBC HL,DE
        JP NZ,ReadFailure
        JR .ready
.fallback:
        LD HL,StreamNext
        LD DE,CacheBase
        CALL Compare32
        JR C,.skip
        ; Повторный FENTRY обязателен: не полагаемся на старую глобальную ENTRY.
        LD HL,FileName
        LD A,59
        CALL WLD
        JP Z,ReadFailure
        LD BC,(FileSize)
        OR A
        SBC HL,BC
        JP NZ,ReadFailure
        EX DE,HL
        LD BC,(FileSize+2)
        OR A
        SBC HL,BC
        JP NZ,ReadFailure
        LD A,62
        CALL WLD
        LD HL,StreamNext
        CALL Zero32
.skip:
        CALL CheckCancel
        RET C
        LD HL,StreamNext
        LD DE,CacheBase
        CALL Compare32
        JR Z,.sequential
        LD HL,CACHE_SIZE
        CALL LoadChunk
        RET C
        JR .skip
.sequential:
        LD HL,(CacheLength)
        CALL LoadChunk
        RET C
.ready:
        CALL CheckCancel                ; учитываем Esc, нажатый внутри чтения
        RET C
        LD A,1
        LD (CacheValid),A
        OR A
        RET

; HL=число полезных байт 1..4096. LOAD512 читает ceil(HL/512) секторов.
; Проверяем одновременно CF, статус и конечный HL. Хвост последнего сектора
; остаётся в кэше, но PeekByte никогда не выдаёт его за пределом FileSize.
; StreamNext увеличивается на полезные байты, без переполнения у #FFFFFFFF.
LoadChunk:
        PUSH HL
        LD DE,511
        ADD HL,DE
        LD A,H
        SRL A
        LD B,A
        ADD A,A
        ADD A,HIGH CACHE
        LD H,A
        LD L,0
        LD (TransferEnd),HL
        LD HL,CACHE
        LD A,48
        CALL WLD
        JR C,.fail
        PUSH AF
        LD DE,(TransferEnd)
        OR A
        SBC HL,DE
        POP BC
        JR NZ,.fail
        LD A,B
        OR A
        JR Z,.good
        CP #0F
        JR NZ,.fail
.good:
        POP BC
        PUSH AF
        LD HL,StreamNext
        CALL Add32BC
        POP AF
        OR A
        RET Z
        ; Ранний EOC при ещё не прочитанном логическом остатке — ошибка.
        LD HL,StreamNext
        LD DE,FileSize
        CALL Compare32
        JP C,ReadFailure
        OR A
        RET
.fail:
        POP HL
        JP ReadFailure

ReadFailure:
        LD A,1
        LD (IoError),A
        XOR A
        LD (CacheValid),A
        SCF
        RET

; Во время первоначального определения формата Esc не опрашивается:
; менеджер ещё может передавать скан запуска. В долгих командах флаг включён.
CheckCancel:
        LD A,(AllowCancel)
        OR A
        RET Z
        ; INT WC защёлкивает короткое нажатие в #6004, даже когда READ_AT
        ; обходит FAT. Опрос только текущей клавиши терял Esc, уже отпущенный
        ; к возврату API. Флаг не равен ABT ядра и не прерывает его посередине.
        LD A,(WC_ABORT)
        OR A
        JR NZ,.cancel
        LD A,23
        CALL WLD
        JR NZ,.cancel
        XOR A                          ; API клавиши гарантирует Z, но не CF
        RET
.cancel:
        XOR A
        LD (WC_ABORT),A
        LD A,1
        LD (Cancelled),A
        SCF
        RET

QueryFilex:
        CALL ClearFilex
        CALL CallFilex
        OR A
        RET NZ
        LD A,(FilexBlock+29)
        CP 1
        RET NZ
        LD A,(FilexBlock+24)
        AND 1
        LD (HaveFilex),A
        RET

; Полностью очищаем запрос: поля результата прошлого вызова не являются
; допустимыми входами следующего. FILEX имеет право разрушить IX и все
; основные пары, кроме IY; IX окна сохраняется этой общей обёрткой.
ClearFilex:
        LD HL,FilexBlock
        LD DE,FilexBlock+1
        LD BC,31
        LD (HL),0
        LDIR
        LD HL,#0120
        LD (FilexBlock),HL
        RET
CallFilex:
        PUSH IX
        LD HL,FilexBlock
        LD A,77
        CALL WLD
        POP IX
        RET
MapVideoZero:
        EX AF,AF'
        LD A,80
        JP WLD

; Compare32: беззнаковое сравнение *(LE32*)HL и *(LE32*)DE.
; CF=первое меньше, Z=равно. Все основные регистры разрушаются.
; Сравнение старшими байтами исключает ложные границы 64 КиБ/16 МиБ/2 ГиБ.
Compare32:
        LD BC,3
        ADD HL,BC
        EX DE,HL
        ADD HL,BC
        EX DE,HL
        LD B,4
.loop:
        LD A,(DE)
        LD C,A
        LD A,(HL)
        CP C
        RET NZ
        DEC HL
        DEC DE
        DJNZ .loop
        RET

; Copy32: четыре байта HL -> DE; AF сохраняется, BC/DE/HL разрушаются.
Copy32:
        LD BC,4
        LDIR
        RET
Zero32:
        XOR A
        LD (HL),A
        INC HL
        LD (HL),A
        INC HL
        LD (HL),A
        INC HL
        LD (HL),A
        RET
Increment32:
        INC (HL)
        RET NZ
        INC HL
        INC (HL)
        RET NZ
        INC HL
        INC (HL)
        RET NZ
        INC HL
        INC (HL)
        RET
Decrement32:
        LD A,(HL)
        SUB 1
        LD (HL),A
        RET NC
        INC HL
        LD A,(HL)
        SUB 1
        LD (HL),A
        RET NC
        INC HL
        LD A,(HL)
        SUB 1
        LD (HL),A
        RET NC
        INC HL
        DEC (HL)
        RET
; *(LE32*)HL += BC. AF/HL разрушаются, BC сохраняется.
Add32BC:
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
