; Основная реализация FILEX исполняется в окне #C000. Блок параметров и
; пользовательские буферы находятся в #8000..#BFFF, поэтому временное
; подключение приватной страницы CORE32 к #C000 их не затрагивает.

        MACRO FILEX_CALL_EXTENSION extension_id
        CALL @WDOS.EXTENSION_GATE
        DB extension_id
        ENDM

FILEX_CONTEXT_LBA       EQU 0
FILEX_CONTEXT_OFFSET    EQU 4
FILEX_CONTEXT_ENTRY     EQU 6
FILEX_CONTEXT_SIZE      EQU 38

FILEX_ENTRY:
        PUSH IY
        PUSH HL
        POP IY

        ; Сам блок обязан целиком находиться в постоянном окне #8000..#BFFF.
        LD A,H:CP #80:JP C,FILEX_BAD_POINTER
        CP #C0:JP NC,FILEX_BAD_POINTER
        LD DE,FILEX_BLOCK_SIZE
        ADD HL,DE:JP C,FILEX_BAD_POINTER
        LD A,H:CP #C0:JR C,.block_range_ok
        JP NZ,FILEX_BAD_POINTER
        LD A,L:OR A:JP NZ,FILEX_BAD_POINTER
.block_range_ok:
        XOR A
        LD (FILEX_RESULT+0),A
        LD (FILEX_RESULT+1),A
        LD (FILEX_RESULT+2),A
        LD (FILEX_RESULT+3),A
        LD (FILEX_RESULT_FLAGS),A

        LD A,(IY+FILEX_P_SIZE):CP FILEX_BLOCK_SIZE:JR NZ,FILEX_BAD_BLOCK
        LD A,(IY+FILEX_P_VERSION):CP FILEX_API_VERSION:JR NZ,FILEX_BAD_VERSION
        LD A,(IY+FILEX_P_RESERVED):OR (IY+FILEX_P_RESERVED+1):JR NZ,FILEX_BAD_BLOCK
        LD A,(IY+FILEX_P_OPERATION):CP FILEX_OP_COUNT:JR NC,FILEX_BAD_OPERATION
        OR A:JP Z,FILEX_QUERY_CAPS
        DEC A:JP Z,FILEX_READ_AT
        DEC A:JP Z,FILEX_WRITE_AT
        DEC A:JP Z,FILEX_SET_EOF32
        DEC A:JP Z,FILEX_GET_FS_INFO
        DEC A:JP Z,FILEX_MOVE_RENAME
        DEC A:JP Z,FILEX_SET_METADATA
; Claude - 2026-09-26 - begin
        DEC A:JP Z,FILEX_READ_FAT
        JP FILEX_GET_METADATA
; Claude - 2026-09-26 - end

FILEX_QUERY_CAPS:
        LD A,(IY+FILEX_P_FLAGS):OR A:JP NZ,FILEX_BAD_BLOCK
        LD A,FILEX_CAP_READ_AT|FILEX_CAP_WRITE_AT|FILEX_CAP_SET_EOF32|FILEX_CAP_GET_FS_INFO|FILEX_CAP_MOVE_RENAME|FILEX_CAP_SET_METADATA|FILEX_CAP_MOVE_CURRENT_DIR|FILEX_CAP_READ_FAT
        LD (FILEX_RESULT),A
; Claude - 2026-09-26 - begin
        LD A,FILEX_CAP2_GET_METADATA            ; второй байт возможностей
        LD (FILEX_RESULT+1),A
; Claude - 2026-09-26 - end
        LD A,FILEX_API_VERSION
        LD (FILEX_RESULT_FLAGS),A
        XOR A
        JP FILEX_FINISH

FILEX_NOT_IMPLEMENTED:
FILEX_BAD_OPERATION:
        LD A,FILEX_STATUS_BAD_OPERATION
        JP FILEX_FINISH
FILEX_BAD_VERSION:
        LD A,FILEX_STATUS_BAD_VERSION
        JP FILEX_FINISH
FILEX_BAD_BLOCK:
        LD A,FILEX_STATUS_BAD_BLOCK
        JP FILEX_FINISH

; Неверный адрес блока нельзя безопасно использовать даже для выдачи статуса.
FILEX_BAD_POINTER:
        LD A,FILEX_STATUS_BAD_BLOCK
        OR A
        POP IY
        RET

FILEX_FINISH:
        LD (IY+FILEX_P_STATUS),A
        PUSH AF
        LD A,(FILEX_RESULT+0):LD (IY+FILEX_P_RESULT_COUNT+0),A
        LD A,(FILEX_RESULT+1):LD (IY+FILEX_P_RESULT_COUNT+1),A
        LD A,(FILEX_RESULT+2):LD (IY+FILEX_P_RESULT_COUNT+2),A
        LD A,(FILEX_RESULT+3):LD (IY+FILEX_P_RESULT_COUNT+3),A
        LD A,(FILEX_RESULT_FLAGS):LD (IY+FILEX_P_RESULT_FLAGS),A
        POP AF
        OR A
        POP IY
        RET

; Проверить произвольный непустой пользовательский буфер. Конец ровно #C000
; допустим; переполнение адреса или длина свыше окна дают BAD_BUFFER.
; Вход: HL — начало, BC — длина. Выход: Z — допустимо, NZ/A — код ошибки.
FILEX_VALIDATE_BUFFER:
        LD A,B:OR C:RET Z
        LD A,H:CP #80:JR C,.bad
        CP #C0:JR NC,.bad
        LD (FILEX_VALIDATE_START),HL
        ADD HL,BC:JR C,.bad_pop
        LD A,H:CP #C0:JR C,.ok_pop
        JR NZ,.bad_pop
        LD A,L:OR A:JR Z,.ok_pop
.bad_pop:
        LD HL,(FILEX_VALIDATE_START)
.bad:
        LD A,FILEX_STATUS_BAD_BUFFER
        OR A
        RET
.ok_pop:
        ; Пользовательский диапазон не должен накрывать сам блок параметров:
        ; иначе операция способна затереть ещё не прочитанные входные поля.
        LD (FILEX_VALIDATE_END),HL
        PUSH IY
        POP DE
        OR A:SBC HL,DE:JR C,.ok_reload:JR Z,.ok_reload
        PUSH IY
        POP HL
        LD DE,FILEX_BLOCK_SIZE
        ADD HL,DE
        EX DE,HL
        LD HL,(FILEX_VALIDATE_START)
        OR A:SBC HL,DE:JR NC,.ok_reload
        JR .bad_pop
.ok_reload:
        LD HL,(FILEX_VALIDATE_START)
        XOR A
        RET

; Получить сохранённый FENTRY-контекст из приватной страницы и заново сверить
; все 32 байта SFN с диском. Это отсекает устаревший либо подменённый объект.
; При успехе LOBU содержит сектор каталога, а FILEX_DIRECTORY_SLOT — его слот.
FILEX_LOAD_CONTEXT:
        LD DE,@WDOS.LOBU
        XOR A
        FILEX_CALL_EXTENSION ID_FILEX_CONTEXT_BRIDGE
        JR Z,.no_context
        LD HL,@WDOS.LOBU,DE,FILEX_CONTEXT,BC,FILEX_CONTEXT_SIZE
        LDIR
; Claude - 2026-10-10 - begin
        CALL FILEX_VERIFY_CONTEXT
        RET NZ
        ; Цепочка файла (FILEX_FILE_CHAIN_GUARD): цикл уводил WRITE_AT в
        ; начало файла, а усечение освобождало оставляемые кластеры (драйвер).
        JP FILEX_FILE_CHAIN_GUARD
; Claude - 2026-10-10 - end
.no_context:
        LD A,FILEX_STATUS_NO_CONTEXT
        OR A
        RET

; Проверить уже помещённый в FILEX_CONTEXT снимок каталожной записи.
FILEX_VERIFY_CONTEXT:
        LD HL,(FILEX_CONTEXT+FILEX_CONTEXT_LBA)
        LD DE,(FILEX_CONTEXT+FILEX_CONTEXT_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        RET NZ

        LD HL,(FILEX_CONTEXT+FILEX_CONTEXT_OFFSET)
        LD A,H:CP 2:JR NC,.changed
        LD A,L:AND #1F:JR NZ,.changed
        LD DE,@WDOS.LOBU
        ADD HL,DE
        LD (FILEX_DIRECTORY_SLOT),HL
        LD DE,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY
        LD B,32
.compare:
        LD A,(DE)
        CP (HL):JR NZ,.changed
        INC DE
        INC HL
        DJNZ .compare
        XOR A
        RET
.changed:
        LD A,FILEX_STATUS_ENTRY_CHANGED
        OR A
        RET

; После изменения каталожной записи синхронизировать сохранённый контекст
; APPEND/FENTRY. Обмен идёт через низкий буфер, потому что на время шлюза
; страница FILEX по #C000 отключается.
FILEX_IMPORT_CONTEXT:
        LD HL,FILEX_CONTEXT,DE,@WDOS.LOBU,BC,FILEX_CONTEXT_SIZE
        LDIR
        LD HL,@WDOS.LOBU
        LD A,2
        FILEX_CALL_EXTENSION ID_FILEX_CONTEXT_BRIDGE
        XOR A
        RET

; Низкоуровневый секторный обмен с единым преобразованием ABT в MEDIA.
FILEX_READ_ONE:
        XOR A
        LD (@WDOS.ABT),A
        LD A,1
        CALL @WDOS.RDDSE
        JR FILEX_IO_RESULT

FILEX_WRITE_ONE:
        XOR A
        LD (@WDOS.ABT),A
        LD A,1
        CALL @WDOS.SDDSE

FILEX_IO_RESULT:
        LD A,(@WDOS.ABT)
        OR A:JR Z,.ok
        LD A,FILEX_STATUS_MEDIA
        OR A
        RET
.ok:
        XOR A
        RET

; Классифицировать FAT32-ссылку DE:HL. Обычный кластер: NZ/CF=0;
; EOC: Z/CF=0; повреждённая ссылка: NZ/CF=1.
FILEX_CLASSIFY_LINK:
        LD A,D:AND #0F:LD D,A
        OR E:OR H:JR NZ,.high
        LD A,L:CP 2:JR C,.invalid
        JR .ordinary
.high:
        LD A,D:CP #0F:JR NZ,.ordinary
        LD A,E:CP #FF:JR NZ,.ordinary
        LD A,H:CP #FF:JR NZ,.ordinary
        LD A,L:CP #F0:JR C,.ordinary
        CP #F8:JR C,.invalid
        XOR A
        RET
.ordinary:
        LD A,1:OR A
        RET
.invalid:
        LD A,1:OR A
        SCF
        RET

; Claude - 2026-10-10 - begin
; ---- Цепочки FAT (из драйвера FAT32: FILE_CHAIN_GUARD, FILE_CHAIN_CHECK,
; CHAINS_DISJOINT). Прежде FILEX проверял только каждую ссылку по отдельности.

; Ссылка цепочки файла или подкаталога: обычный кластер в области данных тома
; и не кластер корня (ID_CLASSIFY_DATA; таблицу корня строит
; FILEX_ROOT_REFRESH). Выход как у FILEX_CLASSIFY_LINK; HL, DE сохраняются.
FILEX_CLASSIFY_DATA:
        LD A,D:AND #0F:LD D,A
        FILEX_CALL_EXTENSION ID_CLASSIFY_DATA
        RET

; Освежить таблицу корня расширения (ROOT_BUILD; она одна на все тома и
; панели) — через FILE_CHAIN с длиной 1: он строит её и проверяет первый
; кластер DE:HL и его ссылку. Аргументы — на стеке: на время шлюза по #C000
; подключена страница расширения, и указатели в страницу FILEX ей не годятся.
; Выход: Z — первый кластер годен. Разрушает AF, BC, DE, HL и SECBU.
FILEX_ROOT_REFRESH:
        LD BC,0:PUSH BC                         ; длина 1
        INC C:PUSH BC
        PUSH DE:PUSH HL                         ; первый кластер
        LD HL,0:ADD HL,SP
        LD D,H:LD E,L
        INC DE:INC DE:INC DE:INC DE
        XOR A
        FILEX_CALL_EXTENSION ID_FILE_CHAIN
        POP BC:POP BC:POP BC:POP BC
        RET

; Цепочка файла контекста — один раз на запись: проверенная запись (все 38
; байт контекста) хранится в FILEX_CHAIN_CACHE, её цепочку повторно не обходят.
; Каталог и пустой файл без кластера не проверяются: FILEX не пишет и не
; читает каталоги как файлы. Таблицу корня освежает каждый вызов (для
; FILEX_NEXT_CLUSTER). Выход: Z — можно; NZ, A=FAT — цепочка испорчена.
FILEX_FILE_CHAIN_GUARD:
        LD A,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+11):AND #10
        JR NZ,.ok
        LD HL,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+26)
        LD DE,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+20)
        LD A,D:AND #0F:LD D,A
        LD A,H:OR L:OR D:OR E:RET Z             ; пустой без кластера
        PUSH HL
        PUSH DE
        CALL FILEX_ROOT_REFRESH
        POP DE
        POP HL
        JR NZ,.bad
        CALL FILEX_CHAIN_CACHED
        RET Z                                   ; уже проверена
        CALL FILEX_CHAIN_WALK
        JR NZ,.bad
        LD HL,FILEX_CONTEXT,DE,FILEX_CHAIN_CACHE,BC,FILEX_CONTEXT_SIZE
        LDIR
        LD A,1:LD (FILEX_CHAIN_CACHE_VALID),A
.ok:
        XOR A
        RET
.bad:
        LD A,FILEX_STATUS_FAT:OR A
        RET

; Z — FILEX_CONTEXT совпадает с проверенной записью FILEX_CHAIN_CACHE.
; Поля времени и дат записи (+13..+19, +22..+25) не сравниваются (с
; 2026-10-11): WRITE_AT ставит время изменения, и прежде каждая новая отметка
; (раз в 2 с) заставляла обходить всю цепочку заново. HL, DE сохраняются.
FILEX_CHAIN_CACHED:
        LD A,(FILEX_CHAIN_CACHE_VALID):OR A
        JR Z,.miss
        PUSH HL
        PUSH DE
        LD HL,FILEX_CONTEXT,DE,FILEX_CHAIN_CACHE
        LD B,FILEX_CONTEXT_ENTRY+13             ; место записи, имя, атрибут, +12
        CALL .compare
        JR NZ,.done
        LD BC,7:ADD HL,BC
        EX DE,HL:ADD HL,BC:EX DE,HL
        LD B,2                                  ; старшее слово кластера
        CALL .compare
        JR NZ,.done
        LD BC,4:ADD HL,BC
        EX DE,HL:ADD HL,BC:EX DE,HL
        LD B,6                                  ; младшее слово и размер
        CALL .compare
.done:
        POP DE
        POP HL
        RET
.compare:
        LD A,(DE):CP (HL):RET NZ
        INC HL:INC DE
        DJNZ .compare
        RET
.miss:
        OR 1
        RET

; Цепочка DE:HL (не 0) до конца: FILEX_ROOT_REFRESH и FILEX_CHAIN_WALK.
FILEX_CHAIN_CHECK:
        PUSH HL
        PUSH DE
        CALL FILEX_ROOT_REFRESH
        POP DE
        POP HL
        RET NZ
; Цепочка DE:HL до конца: каждый кластер — обычный, в томе, не корень
; (FILEX_CLASSIFY_DATA), без повторов — алгоритм Брента: «черепаха» встаёт на
; кластер с номером шага — степенью двойки, «заяц» идёт по цепочке; совпадение
; — цикл. Z — цела, FILEX_CHAIN_LAST — последний кластер; NZ — нет, в том числе
; при отказе чтения FAT. Разрушает AF, BC, DE, HL и SECBU.
FILEX_CHAIN_WALK:
        LD (FILEX_CHAIN_TORTOISE),HL
        LD (FILEX_CHAIN_TORTOISE+2),DE
        PUSH HL
        LD HL,FILEX_CHAIN_POWER
        LD B,8
.zero:
        LD (HL),0:INC HL                        ; FILEX_CHAIN_POWER и _LAM
        DJNZ .zero
        POP HL
        LD A,1:LD (FILEX_CHAIN_POWER),A
        XOR A:LD (FILEX_CHAIN_READ),A
        CALL FILEX_CLASSIFY_DATA
        JR C,.bad
        JR Z,.bad                               ; EOC вместо первого кластера
.cluster:                                       ; DE:HL — кластер цепочки
        LD (FILEX_CHAIN_LAST),HL
        LD (FILEX_CHAIN_LAST+2),DE
        CALL FILEX_CHAIN_VALUE
        JR C,.bad
        CALL FILEX_CLASSIFY_DATA
        JR C,.bad                               ; 0, недопустимая, за томом, корень
        RET Z                                   ; конец цепочки: Z — цела
        PUSH HL
        LD HL,FILEX_CHAIN_LAM:CALL @WDOS.INC4b
        POP HL
        LD BC,(FILEX_CHAIN_TORTOISE)
        LD A,L:CP C:JR NZ,.differ
        LD A,H:CP B:JR NZ,.differ
        LD BC,(FILEX_CHAIN_TORTOISE+2)
        LD A,E:CP C:JR NZ,.differ
        LD A,D:CP B:JR NZ,.differ
.bad:                                           ; цикл или порча
        OR 1
        RET
.differ:
        PUSH HL
        PUSH DE
        LD HL,FILEX_CHAIN_LAM,DE,FILEX_CHAIN_POWER,B,4
.same:
        LD A,(DE):CP (HL):JR NZ,.keep
        INC HL:INC DE
        DJNZ .same
        POP DE
        POP HL
        LD (FILEX_CHAIN_TORTOISE),HL            ; шаг — степень двойки
        LD (FILEX_CHAIN_TORTOISE+2),DE
        PUSH HL
        LD HL,FILEX_CHAIN_POWER
        SLA (HL):INC HL:RL (HL):INC HL:RL (HL):INC HL:RL (HL)
        INC HL                                  ; FILEX_CHAIN_LAM
        XOR A
        LD (HL),A:INC HL:LD (HL),A:INC HL:LD (HL),A:INC HL:LD (HL),A
        POP HL
        JR .cluster
.keep:
        POP DE
        POP HL
        JR .cluster

; Значение записи FAT кластера DE:HL. Сектор FAT читается CURIT в первый раз
; за обход и затем, только когда сменился (FILEX_CHAIN_READ). Выход: DE:HL —
; значение, CF=0; CF=1 — отказ чтения. Разрушает AF, AF', BC.
FILEX_CHAIN_VALUE:
        LD A,(FILEX_CHAIN_READ):OR A
        JR Z,.read
        PUSH DE
        PUSH HL
        CALL @WDOS.STREAM_CACHE_SECTOR          ; Z — тот же сектор FAT, A — запись
        POP HL
        POP DE
        JR NZ,.read
        LD L,A:LD H,@WDOS.SECBU/1024
        ADD HL,HL:ADD HL,HL                     ; адрес записи в SECBU
        JR .value
.read:
        XOR A:LD (@WDOS.ABT),A
        CALL @WDOS.CURIT                        ; HL — запись FAT кластера
        RET C
        LD A,1:LD (FILEX_CHAIN_READ),A
.value:
        LD E,(HL):INC HL:LD D,(HL):INC HL
        LD A,(HL):INC HL:LD H,(HL):LD L,A
        EX DE,HL
        OR A                                    ; CF=0
        RET

; Цепочки записей источника и заменяемого назначения не пересекаются. Две
; конечные цепочки FAT с общим кластером дальше идут вместе, поэтому
; пересекаются ровно тогда, когда у них общий последний кластер. Z — не
; пересекаются; NZ — пересекаются или цепочка испорчена.
FILEX_CHAINS_DISJOINT:
        LD HL,FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY
        CALL FILEX_CHAIN_TAIL
        RET NZ
        LD A,H:OR L:OR D:OR E:RET Z             ; у источника цепочки нет
        LD (FILEX_CHAIN_OTHER),HL
        LD (FILEX_CHAIN_OTHER+2),DE
        LD HL,FILEX_DEST_CONTEXT+FILEX_CONTEXT_ENTRY
        CALL FILEX_CHAIN_TAIL
        RET NZ
        LD A,H:OR L:OR D:OR E:RET Z             ; у назначения цепочки нет
        LD BC,(FILEX_CHAIN_OTHER)
        OR A:SBC HL,BC:JR NZ,.differ
        EX DE,HL
        LD BC,(FILEX_CHAIN_OTHER+2)
        SBC HL,BC                               ; CF=0 после равенства выше
        JR NZ,.differ
        OR 1                                    ; общий хвост
        RET
.differ:
        XOR A
        RET

; Последний кластер цепочки записи каталога HL (32 байта). Выход: Z, DE:HL —
; последний кластер (0 — цепочки нет); NZ — цепочка испорчена.
FILEX_CHAIN_TAIL:
        PUSH HL
        LD BC,20:ADD HL,BC
        LD E,(HL):INC HL:LD D,(HL)              ; старшее слово кластера
        POP HL
        LD BC,26:ADD HL,BC
        LD A,(HL):INC HL:LD H,(HL):LD L,A       ; младшее слово
        LD A,D:AND #0F:LD D,A
        LD A,H:OR L:OR D:OR E:RET Z
        CALL FILEX_CHAIN_CHECK
        RET NZ
        LD HL,(FILEX_CHAIN_LAST),DE,(FILEX_CHAIN_LAST+2)
        XOR A
        RET
; Claude - 2026-10-10 - end

; Прочитать следующую FAT-ссылку текущего кластера и сделать её текущей.
FILEX_NEXT_CLUSTER:
        XOR A
        LD (@WDOS.ABT),A
        LD HL,(FILEX_CURRENT_CLUSTER)
        LD DE,(FILEX_CURRENT_CLUSTER+2)
        CALL @WDOS.CURIT
        JR C,.fat_read_failed
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A
        EX DE,HL
; Claude - 2026-10-10 - begin
        ; В томе и не кластер корня (таблицу корня освежил LOAD_CONTEXT): FAT
        ; могли изменить после проверки цепочки, и WRITE_AT писал бы в корень.
        CALL FILEX_CLASSIFY_DATA
; Claude - 2026-10-10 - end
        JP C,.fat_error
        JP Z,.fat_error
        LD (FILEX_CURRENT_CLUSTER),HL
        LD (FILEX_CURRENT_CLUSTER+2),DE
        XOR A
        RET
.fat_read_failed:
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:RET NZ
.fat_error:
        LD A,FILEX_STATUS_FAT
        OR A
        RET

; Вычислить кластер, сектор и смещение для FILEX_ABSOLUTE_OFFSET. Обходятся
; только FAT-ссылки; данные предшествующих секторов файла не читаются.
FILEX_LOCATE_OFFSET:
        LD A,(@WDOS.BSECPC):OR A:JP Z,.fat_error
        LD B,A
        DEC A
        LD C,A
        LD A,B:AND C:JP NZ,.fat_error   ; секторов на кластер должно быть 2^n

        LD HL,(FILEX_ABSOLUTE_OFFSET)
        LD A,H:AND 1:LD H,A
        LD (FILEX_BYTE_OFFSET),HL

        LD HL,(FILEX_ABSOLUTE_OFFSET)
        LD DE,(FILEX_ABSOLUTE_OFFSET+2)
        DUP 9
        SRL D:RR E:RR H:RR L
        EDUP
        LD A,C:AND L
        LD (FILEX_CURRENT_SECTOR),A

        LD A,B
.divide_cluster:
        CP 1:JR Z,.cluster_index_ready
        SRL D:RR E:RR H:RR L
        SRL A
        JR .divide_cluster
.cluster_index_ready:
        LD (FILEX_CLUSTER_SKIP),HL
        LD (FILEX_CLUSTER_SKIP+2),DE
; Claude - 2026-10-11 - begin
        ; Номер кластера в файле — для кэша позиции. Прежде каждый READ_AT/
        ; WRITE_AT шёл от первого кластера и читал сектор FAT на каждую ссылку:
        ; на глубине 100 МБ (кластер 32 КиБ) — около 3200 чтений на окно SMB.
        LD (FILEX_POS_TARGET),HL
        LD (FILEX_POS_TARGET+2),DE
        CALL FILEX_LOCATE_CACHED                ; Z — от запомненного кластера
        JR Z,.walk_start
; Claude - 2026-10-11 - end

        LD HL,(FILEX_FIRST_CLUSTER)
        LD DE,(FILEX_FIRST_CLUSTER+2)
        CALL FILEX_CLASSIFY_LINK
        JR C,.fat_error
        JR Z,.fat_error
        LD (FILEX_CURRENT_CLUSTER),HL
        LD (FILEX_CURRENT_CLUSTER+2),DE

; Claude - 2026-10-11 - begin
.walk_start:
        XOR A:LD (FILEX_CHAIN_READ),A           ; первый шаг читает сектор FAT
; Claude - 2026-10-11 - end
.walk:
        LD HL,(FILEX_CLUSTER_SKIP)
        LD DE,(FILEX_CLUSTER_SKIP+2)
        LD A,D:OR E:OR H:OR L:JR Z,.ready
        CALL FILEX_LOCATE_STEP                  ; Claude - 2026-10-11
        RET NZ
        LD HL,(FILEX_CLUSTER_SKIP)
        DEC HL
        LD (FILEX_CLUSTER_SKIP),HL
        ; Старшее слово уменьшается только при займе из ровно #0000. Проверка
        ; одного H ошибочно считала займом любой результат #FFxx.
        LD A,H:AND L:CP #FF:JR NZ,.walk
        LD HL,(FILEX_CLUSTER_SKIP+2)
        DEC HL
        LD (FILEX_CLUSTER_SKIP+2),HL
        JR .walk
.ready:
; Claude - 2026-10-11 - begin
        LD HL,FILEX_POS_NOW,DE,FILEX_POS_KEY,BC,FILEX_POS_KEY_SIZE
        LDIR
        LD HL,FILEX_POS_TARGET,DE,FILEX_POS_INDEX,BC,4
        LDIR
        LD HL,FILEX_CURRENT_CLUSTER,DE,FILEX_POS_CLUSTER,BC,4
        LDIR
        LD A,1:LD (FILEX_POS_VALID),A
; Claude - 2026-10-11 - end
        XOR A
        RET
.fat_error:
        LD A,FILEX_STATUS_FAT
        OR A
        RET

; Claude - 2026-10-11 - begin
; Кэш позиции FILEX_LOCATE_OFFSET: последний найденный кластер файла и его
; номер. Годен, пока совпадает ключ: поколение FAT ядра (FAT_CACHE_GENERATION
; меняют любая запись FAT, монтирование, смена драйвера, начало чтения
; каталога, возврат карты), место записи каталога (LBA и смещение контекста) и
; первый кластер. Ключ текущего вызова — в FILEX_POS_NOW. Z — нужный кластер
; не раньше запомненного: FILEX_CURRENT_CLUSTER — запомненный, а
; FILEX_CLUSTER_SKIP — остаток пути от него; NZ — идти от первого кластера.
FILEX_LOCATE_CACHED:
        LD HL,@WDOS.FAT_CACHE_GENERATION,DE,FILEX_POS_NOW,BC,4
        LDIR
        LD HL,FILEX_CONTEXT+FILEX_CONTEXT_LBA,BC,6
        LDIR
        LD HL,FILEX_FIRST_CLUSTER,BC,4
        LDIR
        LD A,(FILEX_POS_VALID):OR A:JR Z,.miss
        LD HL,FILEX_POS_NOW,DE,FILEX_POS_KEY,B,FILEX_POS_KEY_SIZE
.compare:
        LD A,(DE):CP (HL):JR NZ,.miss
        INC HL:INC DE
        DJNZ .compare
        LD HL,(FILEX_CLUSTER_SKIP)
        LD BC,(FILEX_POS_INDEX)
        OR A:SBC HL,BC
        EX DE,HL
        LD HL,(FILEX_CLUSTER_SKIP+2)
        LD BC,(FILEX_POS_INDEX+2)
        SBC HL,BC
        JR C,.miss                              ; нужный раньше запомненного
        LD (FILEX_CLUSTER_SKIP),DE
        LD (FILEX_CLUSTER_SKIP+2),HL
        LD HL,(FILEX_POS_CLUSTER),DE,(FILEX_POS_CLUSTER+2)
        LD (FILEX_CURRENT_CLUSTER),HL
        LD (FILEX_CURRENT_CLUSTER+2),DE
        XOR A
        RET
.miss:
        OR 1
        RET

; Шаг обхода FILEX_LOCATE_OFFSET: как FILEX_NEXT_CLUSTER, но сектор FAT
; читается один раз на 128 ссылок (FILEX_CHAIN_VALUE, первый шаг обхода —
; заново); прежде CURIT читал его на каждую ссылку.
FILEX_LOCATE_STEP:
        LD HL,(FILEX_CURRENT_CLUSTER)
        LD DE,(FILEX_CURRENT_CLUSTER+2)
        CALL FILEX_CHAIN_VALUE
        JR C,.read_failed
        CALL FILEX_CLASSIFY_DATA
        JR C,.fat_error
        JR Z,.fat_error
        LD (FILEX_CURRENT_CLUSTER),HL
        LD (FILEX_CURRENT_CLUSTER+2),DE
        XOR A
        RET
.read_failed:
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:RET NZ
.fat_error:
        LD A,FILEX_STATUS_FAT
        OR A
        RET
; Claude - 2026-10-11 - end

; Подвести драйвер к текущему сектору и сохранить его абсолютный LBA.
FILEX_POSITION_CURRENT:
        LD HL,FILEX_CURRENT_CLUSTER
        CALL @WDOS.GIPAG
        JR NZ,.position_failed
        LD HL,(@WDOS.CLHL)
        LD DE,(@WDOS.CLDE)
        LD A,(FILEX_CURRENT_SECTOR)
        LD C,A
        LD B,0
        ADD HL,BC:JR NC,.lba_ready
        INC DE
.lba_ready:
        LD (FILEX_CURRENT_LBA),HL
        LD (FILEX_CURRENT_LBA+2),DE
        CALL @WDOS.PROZ
        XOR A
        RET
.position_failed:
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:RET NZ
        LD A,FILEX_STATUS_FAT
        OR A
        RET

FILEX_REPOSITION_CURRENT:
        LD HL,(FILEX_CURRENT_LBA)
        LD DE,(FILEX_CURRENT_LBA+2)
        JP @WDOS.PROZ

; Claude - 2026-09-25 - begin
; Содержимое изменилось в обход APPEND (запись внутри файла, усечение): время
; и дата изменения и дата доступа локальной ENTRY — из часов ядра, с той же
; проверкой, что при создании. Время создания не трогается.
FILEX_STAMP_MODIFIED:
        FILEX_CALL_EXTENSION ID_CLOCK_NOW       ; HL — время, DE — дата
        LD (FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+22),HL
        LD (FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+24),DE
        LD (FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+18),DE
        RET
; Claude - 2026-09-25 - end

; Записать изменённую локальную ENTRY в уже проверенный сектор каталога и
; только после успешной записи обновить глобальный контекст FENTRY/APPEND.
FILEX_COMMIT_CONTEXT_ENTRY:
        LD HL,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY
        LD DE,(FILEX_DIRECTORY_SLOT)
        LD BC,32
        LDIR
        LD HL,(FILEX_CONTEXT+FILEX_CONTEXT_LBA)
        LD DE,(FILEX_CONTEXT+FILEX_CONTEXT_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU
        CALL FILEX_WRITE_ONE
; Claude - 2026-10-10 - begin
        ; Отказ записи ENTRY неоднозначен (сектор мог лечь, например с новым
        ; атрибутом «только чтение»): контекст FENTRY/APPEND снят, AF прежний
        ; (драйвер, R3-4). Легшая запись берёт его заново (COMMIT_CONTEXT_DONE).
        JP NZ,FILEX_CONTEXT_FORGET
; Claude - 2026-10-10 - end
; Claude - 2026-09-26 - begin
; Запись легла: ENTRY ядра и контекст APPEND — по новой записи. Отдельный вход
; — для случая, когда отказ записи оказался легшей записью (SET_EOF32).
FILEX_COMMIT_CONTEXT_DONE:
; Claude - 2026-09-26 - end
        LD HL,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY
        LD DE,@WDOS.ENTRY
        LD BC,32
        LDIR
        JP FILEX_IMPORT_CONTEXT

; Перейти к следующему сектору, при необходимости — через FAT-ссылку.
FILEX_ADVANCE_SECTOR:
        LD A,(FILEX_CURRENT_SECTOR):INC A
        LD B,A
        LD A,(@WDOS.BSECPC):CP B
        LD A,B:JR NZ,.same_cluster
        XOR A
        LD (FILEX_CURRENT_SECTOR),A
        JP FILEX_NEXT_CLUSTER
.same_cluster:
        LD (FILEX_CURRENT_SECTOR),A
        XOR A
        RET

; Позиционное чтение до 16 КиБ из последнего объекта FENTRY.
FILEX_READ_AT:
        LD A,(IY+FILEX_P_FLAGS):OR A:JP NZ,FILEX_BAD_BLOCK
        CALL FILEX_LOAD_CONTEXT
        JP NZ,FILEX_FINISH
        LD A,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+11):BIT 4,A
        LD A,FILEX_STATUS_IS_DIRECTORY:JP NZ,FILEX_FINISH

        LD L,(IY+FILEX_P_LENGTH+0)
        LD H,(IY+FILEX_P_LENGTH+1)
        LD A,H:CP #40:JR C,.length_ok
        JP NZ,.bad_length
        LD A,L:OR A:JP NZ,.bad_length
.length_ok:
        LD (FILEX_REQUESTED),HL
        LD A,H:OR L:JP Z,.empty
        LD C,L
        LD B,H
        LD L,(IY+FILEX_P_BUFFER+0)
        LD H,(IY+FILEX_P_BUFFER+1)
        CALL FILEX_VALIDATE_BUFFER
        JP NZ,FILEX_FINISH
        LD (FILEX_BUFFER_POINTER),HL

        LD L,(IY+FILEX_P_OFFSET+0)
        LD H,(IY+FILEX_P_OFFSET+1)
        LD (FILEX_ABSOLUTE_OFFSET),HL
        LD L,(IY+FILEX_P_OFFSET+2)
        LD H,(IY+FILEX_P_OFFSET+3)
        LD (FILEX_ABSOLUTE_OFFSET+2),HL
        LD HL,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+28)
        LD DE,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+30)
        LD (FILEX_FILE_SIZE),HL
        LD (FILEX_FILE_SIZE+2),DE

        ; offset >= size означает чистый EOF без обращения к FAT.
        LD HL,(FILEX_ABSOLUTE_OFFSET+2)
        OR A
        SBC HL,DE:JR C,.inside
        JP NZ,.eof
        LD HL,(FILEX_ABSOLUTE_OFFSET)
        LD DE,(FILEX_FILE_SIZE)
        OR A:SBC HL,DE:JP NC,.eof
.inside:
        ; available = size - offset. Запрос ограничен 16 битами.
        LD HL,(FILEX_FILE_SIZE)
        LD BC,(FILEX_ABSOLUTE_OFFSET)
        OR A:SBC HL,BC
        LD (FILEX_AVAILABLE),HL
        LD HL,(FILEX_FILE_SIZE+2)
        LD BC,(FILEX_ABSOLUTE_OFFSET+2)
        SBC HL,BC
        LD (FILEX_AVAILABLE+2),HL
        XOR A
        LD (FILEX_PARTIAL_EOF),A
        LD A,H:OR L:JR NZ,.full_request
        LD HL,(FILEX_AVAILABLE)
        LD BC,(FILEX_REQUESTED)
        OR A:SBC HL,BC:JR NC,.full_request
        LD HL,(FILEX_AVAILABLE)
        LD (FILEX_REMAINING),HL
        LD A,1:LD (FILEX_PARTIAL_EOF),A
        JR .prepare_position
.full_request:
        LD HL,(FILEX_REQUESTED)
        LD (FILEX_REMAINING),HL
.prepare_position:
        LD HL,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+26)
        LD DE,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+20)
        LD A,D:AND #0F:LD D,A
        LD (FILEX_FIRST_CLUSTER),HL
        LD (FILEX_FIRST_CLUSTER+2),DE
        CALL FILEX_LOCATE_OFFSET
        JP NZ,FILEX_FINISH

.loop:
        CALL FILEX_POSITION_CURRENT
        JP NZ,FILEX_FINISH
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        JP NZ,FILEX_FINISH

        LD HL,512
        LD DE,(FILEX_BYTE_OFFSET)
        OR A:SBC HL,DE
        LD DE,(FILEX_REMAINING)
        PUSH HL
        OR A:SBC HL,DE
        POP HL
        JR C,.chunk_ready
        LD H,D,L,E
.chunk_ready:
        LD (FILEX_CHUNK),HL
        LD BC,(FILEX_BYTE_OFFSET)
        LD HL,@WDOS.LOBU
        ADD HL,BC
        LD DE,(FILEX_BUFFER_POINTER)
        LD BC,(FILEX_CHUNK)
        LDIR
        LD (FILEX_BUFFER_POINTER),DE

        LD HL,(FILEX_RESULT)
        LD DE,(FILEX_CHUNK)
        ADD HL,DE
        LD (FILEX_RESULT),HL
        LD HL,(FILEX_REMAINING)
        OR A:SBC HL,DE
        LD (FILEX_REMAINING),HL
        LD A,H:OR L:JR Z,.done

        XOR A
        LD (FILEX_BYTE_OFFSET),A
        LD (FILEX_BYTE_OFFSET+1),A
        CALL FILEX_ADVANCE_SECTOR
        JP NZ,FILEX_FINISH
        JR .loop

.done:
        LD A,(FILEX_PARTIAL_EOF):OR A
        LD A,FILEX_STATUS_EOF:JP NZ,FILEX_FINISH
.empty:
        XOR A
        JP FILEX_FINISH
.eof:
        LD A,FILEX_STATUS_EOF
        JP FILEX_FINISH
.bad_length:
        LD A,FILEX_STATUS_BAD_LENGTH
        JP FILEX_FINISH

; Установить произвольный 32-битный EOF последнего файла FENTRY. Рост идёт
; нулевыми APPEND-транзакциями, а при любой ошибке уже опубликованные куски
; компенсируются усечением к исходному размеру.
FILEX_SET_EOF32:
        LD A,(IY+FILEX_P_FLAGS):OR A:JP NZ,FILEX_BAD_BLOCK
        CALL FILEX_LOAD_CONTEXT
        JP NZ,FILEX_FINISH
        CALL FILEX_CHECK_MUTABLE_FILE
        JP NZ,FILEX_FINISH
        LD HL,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+28)
        LD DE,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+30)
        LD (FILEX_FILE_SIZE),HL
        LD (FILEX_FILE_SIZE+2),DE
        LD (FILEX_ORIGINAL_SIZE),HL
        LD (FILEX_ORIGINAL_SIZE+2),DE
        LD L,(IY+FILEX_P_OFFSET+0)
        LD H,(IY+FILEX_P_OFFSET+1)
        LD (FILEX_TARGET_SIZE),HL
        LD L,(IY+FILEX_P_OFFSET+2)
        LD H,(IY+FILEX_P_OFFSET+3)
        LD (FILEX_TARGET_SIZE+2),HL

        LD HL,(FILEX_TARGET_SIZE+2)
        OR A:SBC HL,DE:JR C,.shrink
        JR NZ,.grow
        LD HL,(FILEX_TARGET_SIZE)
        LD DE,(FILEX_FILE_SIZE)
        OR A:SBC HL,DE:JR C,.shrink
        JR NZ,.grow
        CALL FILEX_TARGET_TO_RESULT
        XOR A
        JP FILEX_FINISH
.grow:
        CALL FILEX_PREFLIGHT_GROWTH
        JP NZ,FILEX_FINISH
        CALL FILEX_GROW_TO_TARGET
        PUSH AF
        CALL Z,FILEX_TARGET_TO_RESULT
        POP AF
        JP FILEX_FINISH
.shrink:
        CALL FILEX_SHRINK_TO_TARGET
        JP FILEX_FINISH

FILEX_CHECK_MUTABLE_FILE:
        LD A,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+11)
        BIT 4,A:JR NZ,.directory
        BIT 0,A:JR NZ,.read_only
        XOR A
        RET
.directory:
        LD A,FILEX_STATUS_IS_DIRECTORY
        OR A
        RET
.read_only:
        LD A,FILEX_STATUS_READ_ONLY
        OR A
        RET

FILEX_TARGET_TO_RESULT:
        LD HL,(FILEX_TARGET_SIZE)
        LD DE,(FILEX_TARGET_SIZE+2)
        LD (FILEX_RESULT),HL
        LD (FILEX_RESULT+2),DE
        RET

; До первой изменяющей записи доказать, что для всего роста хватает именно
; реальных data-кластеров. Штатный SRHFCL умеет оборачивать поиск, но размер
; последнего сектора FAT обычно больше области данных; без этой проверки его
; нулевой хвост выглядел бы как свободные кластеры за концом тома.
FILEX_PREFLIGHT_GROWTH:
        ; Для неизменного или меньшего EOF проверка свободного места не нужна.
        LD HL,(FILEX_TARGET_SIZE+2),DE,(FILEX_FILE_SIZE+2)
        OR A:SBC HL,DE:JP C,.no_growth
        JR NZ,.growth
        LD HL,(FILEX_TARGET_SIZE),DE,(FILEX_FILE_SIZE)
        OR A:SBC HL,DE:JP C,.no_growth
        JP Z,.no_growth
.growth:
        LD HL,(FILEX_TARGET_SIZE),DE,(FILEX_TARGET_SIZE+2)
        CALL FILEX_SIZE_TO_CLUSTERS
        LD (FILEX_REQUIRED_CLUSTERS),HL
        LD (FILEX_REQUIRED_CLUSTERS+2),DE
        LD HL,(FILEX_FILE_SIZE),DE,(FILEX_FILE_SIZE+2)
        CALL FILEX_SIZE_TO_CLUSTERS
        LD (FILEX_SCAN_CLUSTER),HL
        LD (FILEX_SCAN_CLUSTER+2),DE
        LD HL,(FILEX_REQUIRED_CLUSTERS),BC,(FILEX_SCAN_CLUSTER)
        OR A:SBC HL,BC
        LD (FILEX_REQUIRED_CLUSTERS),HL
        LD HL,(FILEX_REQUIRED_CLUSTERS+2),BC,(FILEX_SCAN_CLUSTER+2)
        SBC HL,BC
        LD (FILEX_REQUIRED_CLUSTERS+2),HL
        LD A,H:OR L
        LD HL,(FILEX_REQUIRED_CLUSTERS)
        OR H:OR L:JP Z,.no_growth

        ; CORE32 вычисляет реальную границу data-кластеров один раз при
        ; монтировании. Сохраняем текущую подсказку: preflight должен доказать
        ; наличие места, но фактический MKSG обязан затем повторить тот же путь.
        LD HL,(@WDOS.FSTFRC),DE,(@WDOS.FSTFRC+2)
        LD (FILEX_SCAN_START),HL
        LD (FILEX_SCAN_START+2),DE
        XOR A:LD (FILEX_SCAN_WRAPPED),A
        FILEX_CALL_EXTENSION ID_GET_DATA_CLUSTER_LIMIT
        JP NZ,.fat_error
        LD (FILEX_SCAN_LIMIT),HL
        LD (FILEX_SCAN_LIMIT+2),DE

        ; Продвигаться от постоянной подсказки. Поскольку preflight не помечает
        ; найденные записи занятыми, отдельно отслеживается единственный wrap:
        ; после возврата к исходной позиции повторно считать кластеры нельзя.
.scan:
        LD HL,(@WDOS.FSTFRC),DE,(@WDOS.FSTFRC+2)
        LD (FILEX_SCAN_CURSOR),HL
        LD (FILEX_SCAN_CURSOR+2),DE
        CALL @WDOS.SRHFCL
        JP C,.scan_failed
        LD (FILEX_SCAN_CLUSTER),HL
        LD (FILEX_SCAN_CLUSTER+2),DE
        LD HL,(FILEX_SCAN_CLUSTER+2),DE,(FILEX_SCAN_LIMIT+2)
        OR A:SBC HL,DE:JR C,.valid_cluster
        JR NZ,.wrap_data
        LD HL,(FILEX_SCAN_CLUSTER),DE,(FILEX_SCAN_LIMIT)
        OR A:SBC HL,DE:JR NC,.wrap_data
.valid_cluster:
        CALL FILEX_SCAN_CLUSTER_UNIQUE
        JR NZ,.no_space
        LD HL,(FILEX_REQUIRED_CLUSTERS)
        DEC HL
        LD (FILEX_REQUIRED_CLUSTERS),HL
        ; Уменьшать старшее слово только при полном переходе 0000 -> FFFF.
        LD A,H:AND L:CP #FF:JR NZ,.count_ready
        LD HL,(FILEX_REQUIRED_CLUSTERS+2)
        DEC HL
        LD (FILEX_REQUIRED_CLUSTERS+2),HL
.count_ready:
        LD HL,(FILEX_REQUIRED_CLUSTERS),DE,(FILEX_REQUIRED_CLUSTERS+2)
        LD A,D:OR E:OR H:OR L:JR Z,.ready
        FILEX_CALL_EXTENSION ID_SAVE_NEXT_FREE_HINT
        ; SAVE_NEXT_FREE_HINT сам оборачивает подсказку последнего кластера к 2.
        ; Следующий SRHFCL уже начнёт с 2, поэтому сравнение найденного кластера
        ; с его новым курсором не обнаружит wrap. Зафиксировать его здесь, иначе
        ; preflight повторно зачтёт свободные кластеры и разрешит лишний рост.
        LD HL,(@WDOS.FSTFRC+2),DE,(FILEX_SCAN_CLUSTER+2)
        OR A:SBC HL,DE:JR C,.hint_wrapped
        JR NZ,.scan
        LD HL,(@WDOS.FSTFRC),DE,(FILEX_SCAN_CLUSTER)
        OR A:SBC HL,DE:JR NC,.scan
.hint_wrapped:
        LD A,1:LD (FILEX_SCAN_WRAPPED),A
        JR .scan
.wrap_data:
        LD A,(FILEX_SCAN_WRAPPED):OR A:JR NZ,.no_space
        INC A:LD (FILEX_SCAN_WRAPPED),A
        LD HL,2:LD (@WDOS.FSTFRC),HL
        LD HL,0:LD (@WDOS.FSTFRC+2),HL
        JP .scan
.ready:
        CALL FILEX_RESTORE_SCAN_HINT
.no_growth:
        XOR A
        RET
.scan_failed:
        CALL FILEX_RESTORE_SCAN_HINT
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:RET NZ
.no_space:
        CALL FILEX_RESTORE_SCAN_HINT
        LD A,FILEX_STATUS_NO_SPACE:OR A:RET
.fat_error:
        CALL FILEX_RESTORE_SCAN_HINT
        LD A,FILEX_STATUS_FAT:OR A:RET

; Z — найденный кластер ещё не учитывался этим preflight. Возврат ниже
; текущего курсора означает wrap; после него исходная позиция является границей
; уже просмотренного диапазона.
FILEX_SCAN_CLUSTER_UNIQUE:
        LD HL,(FILEX_SCAN_CLUSTER),DE,(FILEX_SCAN_CLUSTER+2)
        LD BC,(FILEX_SCAN_CURSOR)
        OR A:SBC HL,BC
        EX DE,HL
        LD BC,(FILEX_SCAN_CURSOR+2)
        SBC HL,BC
        JR NC,.wrap_known
        LD A,1:LD (FILEX_SCAN_WRAPPED),A
.wrap_known:
        LD A,(FILEX_SCAN_WRAPPED):OR A:JR Z,.unique
        LD HL,(FILEX_SCAN_CLUSTER),DE,(FILEX_SCAN_CLUSTER+2)
        LD BC,(FILEX_SCAN_START)
        OR A:SBC HL,BC
        EX DE,HL
        LD BC,(FILEX_SCAN_START+2)
        SBC HL,BC
        JR NC,.duplicate
.unique:
        XOR A
        RET
.duplicate:
        LD A,1:OR A
        RET

FILEX_RESTORE_SCAN_HINT:
        LD HL,(FILEX_SCAN_START),DE,(FILEX_SCAN_START+2)
        LD (@WDOS.FSTFRC),HL
        LD (@WDOS.FSTFRC+2),DE
        RET

FILEX_SIZE_TO_CLUSTERS:
        CALL @WDOS.DEL512
        LD A,(@WDOS.BSECPC)
        JP @WDOS.DELITX2

; В #2000..#2FFF находится приватный сериализованный нулевой scratch. Он не
; пересекает SECBU/LOBU и позволяет APPEND писать по 4 КиБ за транзакцию.
FILEX_PREPARE_ZERO_SCRATCH:
        LD HL,#2000
        LD DE,#2001
        LD BC,#0FFF
        XOR A:LD (HL),A:LDIR
        RET

FILEX_GROW_TO_TARGET:
        CALL FILEX_PREPARE_ZERO_SCRATCH
        LD HL,(FILEX_TARGET_SIZE)
        LD BC,(FILEX_FILE_SIZE)
        OR A:SBC HL,BC
        LD (FILEX_GROW_REMAINING),HL
        LD HL,(FILEX_TARGET_SIZE+2)
        LD BC,(FILEX_FILE_SIZE+2)
        SBC HL,BC
        LD (FILEX_GROW_REMAINING+2),HL
.loop:
        LD HL,(FILEX_GROW_REMAINING)
        LD DE,(FILEX_GROW_REMAINING+2)
        LD A,D:OR E:JR NZ,.full_chunk
        LD BC,#1000
        OR A:SBC HL,BC:JR NC,.full_chunk
        ; SBC использовался только для сравнения. Восстановить остаток, иначе
        ; короткий последний кусок превращался в #Fxxx и APPEND давал LENGTH.
        ADD HL,BC
        LD B,H:LD C,L
        JR .chunk_ready
.full_chunk:
        LD BC,#1000
.chunk_ready:
        LD (FILEX_CHUNK),BC
        LD HL,#2000
        CALL #4027                       ; внутренний APPEND, контекст тот же
        JR NZ,.append_failed
        LD HL,(FILEX_GROW_REMAINING)
        LD BC,(FILEX_CHUNK)
        OR A:SBC HL,BC
        LD (FILEX_GROW_REMAINING),HL
        LD HL,(FILEX_GROW_REMAINING+2)
        LD BC,0
        SBC HL,BC
        LD (FILEX_GROW_REMAINING+2),HL
        LD A,H:OR L
        LD HL,(FILEX_GROW_REMAINING)
        OR H:OR L:JR NZ,.loop
        LD HL,(FILEX_TARGET_SIZE)
        LD DE,(FILEX_TARGET_SIZE+2)
        LD (FILEX_FILE_SIZE),HL
        LD (FILEX_FILE_SIZE+2),DE
        XOR A
        RET

.append_failed:
        CALL FILEX_MAP_APPEND_ERROR
        LD (FILEX_SAVED_STATUS),A
        ; APPEND мог уже зафиксировать предыдущие куски: перечитать контекст.
        CALL FILEX_LOAD_CONTEXT
        JR NZ,.rollback_failed
        LD HL,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+28)
        LD DE,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+30)
        LD (FILEX_FILE_SIZE),HL
        LD (FILEX_FILE_SIZE+2),DE
        LD HL,(FILEX_ORIGINAL_SIZE)
        LD DE,(FILEX_ORIGINAL_SIZE+2)
        LD (FILEX_TARGET_SIZE),HL
        LD (FILEX_TARGET_SIZE+2),DE
        CALL FILEX_SHRINK_TO_TARGET
        JR NZ,.rollback_failed
        LD A,(FILEX_SAVED_STATUS)
        OR A
        RET
.rollback_failed:
        LD A,FILEX_STATUS_ROLLBACK
        OR A
        RET

FILEX_MAP_APPEND_ERROR:
        LD B,A
        LD A,(@WDOS.ABT):OR A
        JR NZ,.media
        LD A,B
        CP #10:JR Z,.no_space
        CP #20:JR Z,.context
        CP #21:JR Z,.buffer
        CP #22:JR Z,.length
        CP #23:JR Z,.changed
        CP #24:JR Z,.overflow
        CP #25:JR Z,.fat
        CP #26:JR Z,.directory
        CP #27:JR Z,.internal
        CP #28:JR Z,.read_only                  ; Claude - 2026-10-10: APPEND
        CP #2A:JR Z,.rollback
        ; Определённые ошибки APPEND перечислены выше. Любой иной ненулевой
        ; код приходит непосредственно из ABT драйвера и означает I/O-сбой.
        LD A,FILEX_STATUS_MEDIA:OR A:RET
.media:     LD A,FILEX_STATUS_MEDIA:OR A:RET
.no_space:  LD A,FILEX_STATUS_NO_SPACE:OR A:RET
.context:   LD A,FILEX_STATUS_NO_CONTEXT:OR A:RET
.buffer:    LD A,FILEX_STATUS_BAD_BUFFER:OR A:RET
.length:    LD A,FILEX_STATUS_BAD_LENGTH:OR A:RET
.changed:   LD A,FILEX_STATUS_ENTRY_CHANGED:OR A:RET
.overflow:  LD A,FILEX_STATUS_SIZE_OVERFLOW:OR A:RET
.fat:       LD A,FILEX_STATUS_FAT:OR A:RET
.directory: LD A,FILEX_STATUS_IS_DIRECTORY:OR A:RET
.internal:  LD A,FILEX_STATUS_INTERNAL:OR A:RET
.rollback:  LD A,FILEX_STATUS_ROLLBACK:OR A:RET
.read_only: LD A,FILEX_STATUS_READ_ONLY:OR A:RET  ; Claude - 2026-10-10

; Усечение публикует меньший размер до отсоединения хвоста. Поэтому сбой FAT
; после commit не оставляет запись, указывающую за короткую цепочку: максимум
; остаётся лишняя, но уже недоступная цепочка и код COMMITTED_CLEANUP.
; Claude - 2026-10-10 - begin
; Хвост последнего сохраняемого сектора обнуляется после публикации нового
; размера, когда за концом файла уже мёртвые данные. Прежде — до публикации,
; с копией FILEX_SECTOR_BACKUP: там ещё живые данные файла, и отказ записи при
; неудачном возврате копии терял их (драйвер, R8-3). Отказ до публикации —
; на диске ничего не менялось; отказ обнуления — COMMITTED_CLEANUP.
; Claude - 2026-10-10 - end
FILEX_SHRINK_TO_TARGET:
        ; Компенсация не должна трогать уже исходный размер (особенно size=0).
        LD HL,(FILEX_TARGET_SIZE+2)
        LD DE,(FILEX_FILE_SIZE+2)
        OR A:SBC HL,DE:JR NZ,.different_size
        LD HL,(FILEX_TARGET_SIZE)
        LD DE,(FILEX_FILE_SIZE)
        OR A:SBC HL,DE:JR NZ,.different_size
        XOR A
        RET
.different_size:
        XOR A
        LD (FILEX_TAIL_PRESENT),A
; Claude - 2026-10-10 - begin
        LD HL,512:LD (FILEX_TAIL_START),HL      ; 512 — хвоста сектора нет
; Claude - 2026-10-10 - end
        LD HL,(FILEX_TARGET_SIZE)
        LD DE,(FILEX_TARGET_SIZE+2)
        LD A,D:OR E:OR H:OR L:JP Z,.prepare_zero_size

        LD HL,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+26)
        LD DE,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+20)
        LD A,D:AND #0F:LD D,A
        LD (FILEX_FIRST_CLUSTER),HL
        LD (FILEX_FIRST_CLUSTER+2),DE
        ; Последний сохраняемый байт определяет последний сохраняемый кластер.
        LD HL,(FILEX_TARGET_SIZE)
        LD DE,(FILEX_TARGET_SIZE+2)
        DEC HL
        ; Проверка одного H теряла 64 КиБ при размерах low16=FF01..FFFF.
        LD A,H:AND L:CP #FF:JR NZ,.last_offset_ready
        DEC DE
.last_offset_ready:
        LD (FILEX_ABSOLUTE_OFFSET),HL
        LD (FILEX_ABSOLUTE_OFFSET+2),DE
        CALL FILEX_LOCATE_OFFSET
        RET NZ
        LD HL,(FILEX_CURRENT_CLUSTER)
        LD DE,(FILEX_CURRENT_CLUSTER+2)
        LD (FILEX_KEEP_CLUSTER),HL
        LD (FILEX_KEEP_CLUSTER+2),DE

        CALL FILEX_POSITION_CURRENT
        RET NZ
        LD HL,(FILEX_CURRENT_LBA)
        LD DE,(FILEX_CURRENT_LBA+2)
        LD (FILEX_TAIL_LBA),HL
        LD (FILEX_TAIL_LBA+2),DE
; Claude - 2026-10-10 - begin
        LD HL,(FILEX_BYTE_OFFSET)
        INC HL
        LD (FILEX_TAIL_START),HL                ; первый байт за новым концом
; Claude - 2026-10-10 - end
        ; Сохранить прежнюю ссылку хвоста до публикации нового размера.
        XOR A:LD (@WDOS.ABT),A
        LD HL,(FILEX_KEEP_CLUSTER)
        LD DE,(FILEX_KEEP_CLUSTER+2)
        CALL @WDOS.CURIT
        JP C,.fat_lookup_failed
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A
        EX DE,HL
        CALL FILEX_CLASSIFY_LINK
        JP C,.fat_error
        JR Z,.entry_commit
        LD (FILEX_TAIL_HEAD),HL
        LD (FILEX_TAIL_HEAD+2),DE
        LD A,1:LD (FILEX_TAIL_PRESENT),A
        JR .entry_commit

.prepare_zero_size:
        LD HL,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+26)
        LD DE,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+20)
        LD A,D:AND #0F:LD D,A
        CALL FILEX_CLASSIFY_LINK
        JP C,.fat_error
        JP Z,.fat_error
        LD (FILEX_TAIL_HEAD),HL
        LD (FILEX_TAIL_HEAD+2),DE
        LD A,1:LD (FILEX_TAIL_PRESENT),A

.entry_commit:
        ; Дисковые чтения затёрли LOBU: перечитать и повторно сверить ENTRY.
        CALL FILEX_LOAD_CONTEXT
        RET NZ
        LD HL,(FILEX_TARGET_SIZE)
        LD DE,(FILEX_TARGET_SIZE+2)
        LD (FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+28),HL
        LD (FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+30),DE
        LD A,D:OR E:OR H:OR L:JR NZ,.write_entry
        XOR A
        LD (FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+20),A
        LD (FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+21),A
        LD (FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+26),A
        LD (FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+27),A
.write_entry:
; Claude - 2026-09-25 - begin
        CALL FILEX_STAMP_MODIFIED               ; усечение — изменение содержимого
; Claude - 2026-09-25 - end
        CALL FILEX_COMMIT_CONTEXT_ENTRY
; Claude - 2026-09-26 - begin
        ; Отказ записи ENTRY неоднозначен: сектор мог лечь. Прежде — сразу
        ; возврат хвоста и MEDIA, хотя на диске мог быть уже новый размер при
        ; неотсоединённом хвосте цепочки, а при размере 0 — цепочка без
        ; ссылок (аудит, А.5). Теперь сектор перечитывается: на диске новая
        ; ENTRY — усечение доводится как обычно; прежняя или сектор не
        ; читается — MEDIA (Claude, 2026-10-10: контекст FENTRY/APPEND снят
        ; уже отказом записи, а легшая ENTRY берёт его заново — импорт).
        JR Z,.entry_committed
        LD (FILEX_SAVED_STATUS),A
        CALL FILEX_VERIFY_CONTEXT
        LD A,(FILEX_SAVED_STATUS)
        JR NZ,.failed
        CALL FILEX_COMMIT_CONTEXT_DONE
.entry_committed:
; Claude - 2026-09-26 - end
        CALL FILEX_TARGET_TO_RESULT

        LD HL,(FILEX_TARGET_SIZE)
        LD DE,(FILEX_TARGET_SIZE+2)
        LD A,D:OR E:OR H:OR L:JR Z,.release_tail
        LD A,(FILEX_TAIL_PRESENT):OR A:JR Z,.success

        ; Отсоединить хвост точным EOC, сохранив служебный старший полубайт.
        XOR A:LD (@WDOS.ABT),A
        LD HL,(FILEX_KEEP_CLUSTER)
        LD DE,(FILEX_KEEP_CLUSTER+2)
        CALL @WDOS.CURIT
        JR C,.committed_cleanup
        LD (HL),#FF:INC HL
        LD (HL),#FF:INC HL
        LD (HL),#FF:INC HL
        LD A,(HL):AND #F0:OR #0F:LD (HL),A
        FILEX_CALL_EXTENSION ID_SAVE_FAT_SECTOR
        JR NZ,.committed_cleanup

.release_tail:
        LD A,(FILEX_TAIL_PRESENT):OR A:JR Z,.success
        LD HL,(FILEX_TAIL_HEAD)
        LD DE,(FILEX_TAIL_HEAD+2)
        LD (@WDOS.LOBU),HL
        LD (@WDOS.LOBU+2),DE
        XOR A:LD (@WDOS.ABT),A
        LD HL,@WDOS.LOBU
        CALL @WDOS.DLSG
        LD A,(@WDOS.ABT):OR A:JR NZ,.committed_cleanup
        CALL #4030
        JR NZ,.committed_cleanup
; Claude - 2026-10-10 - begin
.success:
        CALL .zero_tail
        RET Z
        JR .cleanup_status
; Claude - 2026-10-10 - end
; Claude - 2026-09-26 - begin
; Отказ чтения FAT или испорченная ссылка хвоста — до публикации: на диске
; ничего не менялось (Claude, 2026-10-10: обнуления до публикации больше нет).
.fat_lookup_failed:
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:RET NZ
.fat_error:
        LD A,FILEX_STATUS_FAT
; Claude - 2026-09-26 - end
.failed:
        OR A
        RET
.committed_cleanup:
; Claude - 2026-10-10 - begin
        CALL .zero_tail                         ; хвост сектора — и здесь
.cleanup_status:
; Claude - 2026-10-10 - end
        LD A,FILEX_STATUS_COMMITTED_CLEANUP
        OR A
        RET
; Claude - 2026-10-10 - begin
; Обнулить хвост последнего сохраняемого сектора с FILEX_TAIL_START (512 и
; больше — хвоста нет): прочитать сектор FILEX_TAIL_LBA, обнулить, записать.
; Выход: Z — обнулён или нечего; NZ — отказ чтения или записи.
.zero_tail:
        LD HL,(FILEX_TAIL_START)
        LD A,H:CP 2:JR NC,.no_tail
        PUSH HL
        CALL .tail_position
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        POP DE                                  ; начало хвоста
        RET NZ
        LD HL,512:OR A:SBC HL,DE
        LD B,H:LD C,L                           ; длина хвоста, не 0
        LD HL,@WDOS.LOBU:ADD HL,DE
.zero_loop:
        LD (HL),0
        INC HL
        DEC BC
        LD A,B:OR C:JR NZ,.zero_loop
        CALL .tail_position
        LD HL,@WDOS.LOBU
        JP FILEX_WRITE_ONE
.no_tail:
        XOR A
        RET
.tail_position:
        LD HL,(FILEX_TAIL_LBA)
        LD DE,(FILEX_TAIL_LBA+2)
        JP @WDOS.PROZ
; Claude - 2026-10-10 - end

; Перезаписать существующие байты и при необходимости продолжить файл. Вся
; часть за старым EOF проходит через APPEND, поэтому новый размер появляется
; только после данных и FAT. Для разреженного offset сначала создаётся нулевой
; промежуток; ошибка последующего APPEND откатывает его к исходному EOF.
FILEX_WRITE_AT:
        LD A,(IY+FILEX_P_FLAGS):OR A:JP NZ,FILEX_BAD_BLOCK
        CALL FILEX_LOAD_CONTEXT
        JP NZ,FILEX_FINISH
        CALL FILEX_CHECK_MUTABLE_FILE
        JP NZ,FILEX_FINISH
        LD L,(IY+FILEX_P_LENGTH+0)
        LD H,(IY+FILEX_P_LENGTH+1)
        LD A,H:CP #40:JR C,.length_ok
        JP NZ,.bad_length
        LD A,L:OR A:JP NZ,.bad_length
.length_ok:
        LD (FILEX_REQUESTED),HL
        LD A,H:OR L:JP Z,.success
        LD C,L:LD B,H
        LD L,(IY+FILEX_P_BUFFER+0)
        LD H,(IY+FILEX_P_BUFFER+1)
        CALL FILEX_VALIDATE_BUFFER
        JP NZ,FILEX_FINISH
        LD (FILEX_BUFFER_POINTER),HL
        LD L,(IY+FILEX_P_OFFSET+0)
        LD H,(IY+FILEX_P_OFFSET+1)
        LD (FILEX_ABSOLUTE_OFFSET),HL
        LD L,(IY+FILEX_P_OFFSET+2)
        LD H,(IY+FILEX_P_OFFSET+3)
        LD (FILEX_ABSOLUTE_OFFSET+2),HL
        LD HL,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+28)
        LD DE,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+30)
        LD (FILEX_FILE_SIZE),HL
        LD (FILEX_FILE_SIZE+2),DE
        LD (FILEX_ORIGINAL_SIZE),HL
        LD (FILEX_ORIGINAL_SIZE+2),DE

        ; Проверить offset+length на 32-битное переполнение.
        LD HL,(FILEX_ABSOLUTE_OFFSET)
        LD DE,(FILEX_REQUESTED)
        ADD HL,DE
        LD (FILEX_WRITE_END),HL
        LD HL,(FILEX_ABSOLUTE_OFFSET+2)
        LD DE,0
        ADC HL,DE:JP C,.overflow
        LD (FILEX_WRITE_END+2),HL

        ; Проверить весь возможный рост до перезаписи существующих данных.
        LD HL,(FILEX_WRITE_END),DE,(FILEX_WRITE_END+2)
        LD (FILEX_TARGET_SIZE),HL
        LD (FILEX_TARGET_SIZE+2),DE
        CALL FILEX_PREFLIGHT_GROWTH
        JP NZ,FILEX_FINISH

        ; Сравнить offset со старым EOF.
        LD HL,(FILEX_ABSOLUTE_OFFSET+2)
        LD DE,(FILEX_FILE_SIZE+2)
        OR A:SBC HL,DE:JR C,.inside_file
        JR NZ,.after_eof
        LD HL,(FILEX_ABSOLUTE_OFFSET)
        LD DE,(FILEX_FILE_SIZE)
        OR A:SBC HL,DE:JR C,.inside_file
        JR Z,.append_at_eof

.after_eof:
        ; Сначала безопасно заполнить нулями gap [old_size, offset).
        LD HL,(FILEX_ABSOLUTE_OFFSET)
        LD DE,(FILEX_ABSOLUTE_OFFSET+2)
        LD (FILEX_TARGET_SIZE),HL
        LD (FILEX_TARGET_SIZE+2),DE
        CALL FILEX_GROW_TO_TARGET
        JR Z,.append_after_gap
        CALL FILEX_CLEAR_RESULT
        JP FILEX_FINISH
.append_after_gap:
        LD HL,(FILEX_REQUESTED)
        LD (FILEX_REMAINING),HL
        CALL FILEX_APPEND_REMAINING
        JP Z,.success
        LD (FILEX_SAVED_STATUS),A
        CALL FILEX_ROLLBACK_WRITE_GAP
        JR NZ,.rollback_failed
        LD A,(FILEX_SAVED_STATUS)
        CALL FILEX_CLEAR_RESULT
        JP FILEX_FINISH
.rollback_failed:
        CALL FILEX_CLEAR_RESULT
        LD A,FILEX_STATUS_ROLLBACK
        JP FILEX_FINISH

.append_at_eof:
        LD HL,(FILEX_REQUESTED)
        LD (FILEX_REMAINING),HL
        CALL FILEX_APPEND_REMAINING
        JP NZ,FILEX_FINISH
        JR .success

.inside_file:
        ; in_place = min(length, old_size-offset), tail = length-in_place.
        LD HL,(FILEX_FILE_SIZE)
        LD BC,(FILEX_ABSOLUTE_OFFSET)
        OR A:SBC HL,BC
        LD (FILEX_AVAILABLE),HL
        LD HL,(FILEX_FILE_SIZE+2)
        LD BC,(FILEX_ABSOLUTE_OFFSET+2)
        SBC HL,BC
        LD (FILEX_AVAILABLE+2),HL
        LD A,H:OR L:JR NZ,.all_in_place
        LD HL,(FILEX_AVAILABLE)
        LD BC,(FILEX_REQUESTED)
        OR A:SBC HL,BC:JR NC,.all_in_place
        LD HL,(FILEX_AVAILABLE)
        LD (FILEX_REMAINING),HL
        LD DE,(FILEX_REQUESTED)
        EX DE,HL
        OR A:SBC HL,DE
        LD (FILEX_WRITE_TAIL_COUNT),HL
        JR .write_existing
.all_in_place:
        LD HL,(FILEX_REQUESTED)
        LD (FILEX_REMAINING),HL
        XOR A
        LD (FILEX_WRITE_TAIL_COUNT),A
        LD (FILEX_WRITE_TAIL_COUNT+1),A
.write_existing:
        LD HL,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+26)
        LD DE,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+20)
        LD A,D:AND #0F:LD D,A
        LD (FILEX_FIRST_CLUSTER),HL
        LD (FILEX_FIRST_CLUSTER+2),DE
        CALL FILEX_LOCATE_OFFSET
        JP NZ,FILEX_FINISH
        CALL FILEX_WRITE_EXISTING
        JP NZ,FILEX_FINISH
        LD HL,(FILEX_WRITE_TAIL_COUNT)
        LD A,H:OR L:JR Z,.stamp_in_place
        LD (FILEX_REMAINING),HL
        CALL FILEX_APPEND_REMAINING             ; хвост за концом: время ставит APPEND
        JP NZ,FILEX_FINISH

.success:
        XOR A
        JP FILEX_FINISH

; Claude - 2026-09-25 - begin
; Запись целиком внутри файла через APPEND не проходила, и время изменения
; оставалось прежним. ENTRY перечитывается (дисковые чтения затёрли сектор
; каталога), получает время и публикуется.
.stamp_in_place:
        CALL FILEX_LOAD_CONTEXT
        JP NZ,FILEX_FINISH
        CALL FILEX_STAMP_MODIFIED
        CALL FILEX_COMMIT_CONTEXT_ENTRY
        JP NZ,FILEX_FINISH
        JR .success
; Claude - 2026-09-25 - end
.overflow:
        LD A,FILEX_STATUS_SIZE_OVERFLOW
        JP FILEX_FINISH
.bad_length:
        LD A,FILEX_STATUS_BAD_LENGTH
        JP FILEX_FINISH

; Claude - 2026-10-10 - begin
; AF сохраняется: прежде XOR A затирал код отказа, и WRITE_AT за концом файла
; при отказе роста (MEDIA, ROLLBACK) отвечал OK (из драйвера FAT32, R5-1).
FILEX_CLEAR_RESULT:
        LD HL,0
        LD (FILEX_RESULT),HL
        LD (FILEX_RESULT+2),HL
        RET
; Claude - 2026-10-10 - end

FILEX_APPEND_REMAINING:
        LD HL,(FILEX_BUFFER_POINTER)
        LD BC,(FILEX_REMAINING)
        CALL #4027
        JR NZ,.failed
        LD (FILEX_BUFFER_POINTER),HL
        LD HL,(FILEX_RESULT)
        LD DE,(FILEX_REMAINING)
        ADD HL,DE
        LD (FILEX_RESULT),HL
        XOR A
        RET
.failed:
        JP FILEX_MAP_APPEND_ERROR

FILEX_ROLLBACK_WRITE_GAP:
        CALL FILEX_LOAD_CONTEXT
        RET NZ
        LD HL,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+28)
        LD DE,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+30)
        LD (FILEX_FILE_SIZE),HL
        LD (FILEX_FILE_SIZE+2),DE
        LD HL,(FILEX_ORIGINAL_SIZE)
        LD DE,(FILEX_ORIGINAL_SIZE+2)
        LD (FILEX_TARGET_SIZE),HL
        LD (FILEX_TARGET_SIZE+2),DE
        JP FILEX_SHRINK_TO_TARGET

; Записать FILEX_REMAINING байт внутри существующего размера. Невыровненные
; участки проходят через RMW; полный сектор пишется прямо из буфера клиента.
FILEX_WRITE_EXISTING:
.loop:
        CALL FILEX_POSITION_CURRENT
        RET NZ
        LD HL,512
        LD DE,(FILEX_BYTE_OFFSET)
        OR A:SBC HL,DE
        LD DE,(FILEX_REMAINING)
        PUSH HL
        OR A:SBC HL,DE
        POP HL
        JR C,.chunk_ready
        LD H,D:LD L,E
.chunk_ready:
        LD (FILEX_CHUNK),HL
        LD DE,512
        OR A:SBC HL,DE:JR NZ,.partial
        LD HL,(FILEX_BYTE_OFFSET)
        LD A,H:OR L:JR NZ,.partial
        LD HL,(FILEX_BUFFER_POINTER)
        CALL FILEX_WRITE_ONE
        RET NZ
        LD HL,(FILEX_BUFFER_POINTER)
        LD DE,512
        ADD HL,DE
        LD (FILEX_BUFFER_POINTER),HL
        JR .sector_written

.partial:
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        RET NZ
        LD HL,@WDOS.LOBU
        LD DE,(FILEX_BYTE_OFFSET)
        ADD HL,DE
        EX DE,HL
        LD HL,(FILEX_BUFFER_POINTER)
        LD BC,(FILEX_CHUNK)
        LDIR
        LD (FILEX_BUFFER_POINTER),HL
        CALL FILEX_REPOSITION_CURRENT
        LD HL,@WDOS.LOBU
        CALL FILEX_WRITE_ONE
        RET NZ

.sector_written:
        LD HL,(FILEX_RESULT)
        LD DE,(FILEX_CHUNK)
        ADD HL,DE
        LD (FILEX_RESULT),HL
        LD HL,(FILEX_REMAINING)
        OR A:SBC HL,DE
        LD (FILEX_REMAINING),HL
        LD A,H:OR L:RET Z
        XOR A
        LD (FILEX_BYTE_OFFSET),A
        LD (FILEX_BYTE_OFFSET+1),A
        CALL FILEX_ADVANCE_SECTOR
        RET NZ
        JP .loop

; MOVE_RENAME принимает два запроса формата FENTRY [тип, имя, 0] и два
; cluster32 родительских каталогов. В одном томе сначала создаётся новая
; ссылка, затем удаляется старая. При replace существующая SFN назначения
; перенаправляется на исходную цепочку одной секторной записью; её старая
; цепочка освобождается только после успешного удаления исходной ссылки.
; Имя с пробелом или точкой в конце (в том числе «.» и «..») в любом из двух
; запросов — INVALID_NAME до каких-либо изменений (FILEX_VALIDATE_QUERY).
FILEX_MOVE_RENAME:
        LD A,(IY+FILEX_P_FLAGS)
        AND ~(FILEX_FLAG_REPLACE|FILEX_FLAG_CURRENT_DIR):JP NZ,.bad_block
        LD L,(IY+FILEX_P_BUFFER+0)
        LD H,(IY+FILEX_P_BUFFER+1)
        LD C,(IY+FILEX_P_LENGTH+0)
        LD B,(IY+FILEX_P_LENGTH+1)
        LD (FILEX_SOURCE_QUERY),HL
        CALL FILEX_VALIDATE_QUERY
        JP NZ,FILEX_FINISH
        LD L,(IY+FILEX_P_AUX+0)
        LD H,(IY+FILEX_P_AUX+1)
        LD C,(IY+FILEX_P_AUX_LENGTH+0)
        LD B,(IY+FILEX_P_AUX_LENGTH+1)
        LD (FILEX_DEST_QUERY),HL
        CALL FILEX_VALIDATE_QUERY
        JP NZ,FILEX_FINISH
        LD HL,(FILEX_SOURCE_QUERY)
        LD A,(HL):LD B,A
        LD HL,(FILEX_DEST_QUERY)
        LD A,(HL):CP B:JR NZ,.bad_block

        LD L,(IY+FILEX_P_SOURCE_DIR+0)
        LD H,(IY+FILEX_P_SOURCE_DIR+1)
        LD (FILEX_SOURCE_DIR),HL
        LD L,(IY+FILEX_P_SOURCE_DIR+2)
        LD H,(IY+FILEX_P_SOURCE_DIR+3)
        LD (FILEX_SOURCE_DIR+2),HL
        LD L,(IY+FILEX_P_DEST_DIR+0)
        LD H,(IY+FILEX_P_DEST_DIR+1)
        LD (FILEX_DEST_DIR),HL
        LD L,(IY+FILEX_P_DEST_DIR+2)
        LD H,(IY+FILEX_P_DEST_DIR+3)
        LD (FILEX_DEST_DIR+2),HL
        CALL FILEX_SAVE_ACTIVE_DIRECTORY
        ; Обычный плагин не должен читать приватный LSTCAT из переключаемой
        ; страницы WildDOS. CURRENT_DIR безопасно подставляет один сохранённый
        ; активный каталог для обеих сторон операции.
        LD A,(IY+FILEX_P_FLAGS):BIT 1,A:JR Z,.directories_ready
        LD HL,FILEX_SAVED_ACTIVE_DIR,DE,FILEX_SOURCE_DIR,BC,4:LDIR
        LD HL,FILEX_SAVED_ACTIVE_DIR,DE,FILEX_DEST_DIR,BC,4:LDIR
.directories_ready:
        CALL FILEX_MOVE_WORKER
        PUSH AF
        CALL FILEX_RESTORE_ACTIVE_DIRECTORY
        POP AF
        JP FILEX_FINISH
.bad_block:
        LD A,FILEX_STATUS_BAD_BLOCK
        JP FILEX_FINISH

; Проверить границы и нулевой терминатор запроса [#00/#10, имя, 0] и что имя
; не кончается пробелом или точкой. Выход: Z — годен, NZ и A=INVALID_NAME —
; нет (либо код FILEX_VALIDATE_BUFFER). Зовёт только MOVE_RENAME.
FILEX_VALIDATE_QUERY:
        PUSH HL,BC
        CALL FILEX_VALIDATE_BUFFER
        POP BC,HL
        RET NZ
        LD A,B:OR A:JR Z,.short_length
        CP 1:JR NZ,.bad
        LD A,C:CP 2:JR NC,.bad           ; максимум 257 байт
        JR .length_ready
.short_length:
        LD A,C:CP 3:JR C,.bad
.length_ready:
        LD A,(HL):AND #EF:JR NZ,.bad
        INC HL
        DEC BC
        LD A,(HL):OR A:JR Z,.bad
.scan:
        LD A,(HL):OR A:JR Z,.ok
        INC HL
        DEC BC
        LD A,B:OR C:JR NZ,.scan
.bad:
        LD A,FILEX_STATUS_INVALID_NAME
        OR A
        RET
.ok:
; Claude - 2026-09-25 - begin
; Имя с пробелом или точкой в конце: SVHDFL записывает его усечённым («NEW »
; → NEW), а поиск и откат MOVE шли по исходному тексту и записи не находили:
; на каталог оставались две ссылки даже без сбоя носителя, и удаление
; источника освобождало живую цепочку (аудит Codex). Такое имя FAT не
; допускает — отказ INVALID_NAME.
        DEC HL                                  ; последний знак имени
        LD A,(HL)
        CP " ":JR Z,.bad
        CP ".":JR Z,.bad
; Claude - 2026-09-25 - end
        XOR A
        RET

FILEX_SAVE_ACTIVE_DIRECTORY:
        LD HL,@WDOS.LSTCAT,DE,FILEX_SAVED_ACTIVE_DIR,BC,4
        LDIR
        RET

FILEX_RESTORE_ACTIVE_DIRECTORY:
        LD HL,FILEX_SAVED_ACTIVE_DIR
        JR FILEX_SET_ACTIVE_DIRECTORY

FILEX_SET_SOURCE_DIRECTORY:
        LD HL,FILEX_SOURCE_DIR
        JR FILEX_SET_ACTIVE_DIRECTORY

FILEX_SET_DEST_DIRECTORY:
        LD HL,FILEX_DEST_DIR
FILEX_SET_ACTIVE_DIRECTORY:
        LD DE,@WDOS.LSTCAT,BC,4
        LDIR
        XOR A
        LD (@WDOS.CGFL),A
        RET

; Сохранить LLHL, смещение найденного SFN и ENTRY в контекст по DE.
FILEX_CAPTURE_FOUND:
        PUSH IX
        PUSH DE
        POP IX
        LD HL,(@WDOS.LLHL)
        LD (IX+0),L:LD (IX+1),H
        LD HL,(@WDOS.LLHL+2)
        LD (IX+2),L:LD (IX+3),H
        LD A,C:AND #1F:JR NZ,.bad
        LD (IX+4),C
        LD A,B:SUB high @WDOS.LOBU:CP 4:JR NC,.bad
        AND 1
        LD (IX+5),A
        LD HL,@WDOS.ENTRY
        PUSH IX
        POP DE
        LD BC,FILEX_CONTEXT_ENTRY
        EX DE,HL
        ADD HL,BC
        EX DE,HL
        LD HL,@WDOS.ENTRY
        LD BC,32
        LDIR
        POP IX
        XOR A
        RET
.bad:
        POP IX
        LD A,FILEX_STATUS_INTERNAL
        OR A
        RET

FILEX_CONTEXTS_EQUAL:
        LD HL,FILEX_SOURCE_CONTEXT
        LD DE,FILEX_DEST_CONTEXT
        LD B,FILEX_CONTEXT_ENTRY
.loop:
        LD A,(DE):CP (HL):RET NZ
        INC DE:INC HL
        DJNZ .loop
        RET

FILEX_MOVE_WORKER:
        XOR A
        LD (FILEX_DOTDOT_CHANGED),A
        CALL FILEX_SET_SOURCE_DIRECTORY
        LD HL,(FILEX_SOURCE_QUERY)
        XOR A:LD (@WDOS.ABT),A
        CALL @WDOS.SRHDRN
        JR NZ,.source_found
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:RET NZ
        LD A,FILEX_STATUS_NOT_FOUND:OR A:RET
.source_found:
        LD DE,FILEX_SOURCE_CONTEXT
        CALL FILEX_CAPTURE_FOUND
        RET NZ
        CALL FILEX_VALIDATE_MOVE_ANCESTRY
        RET NZ

        CALL FILEX_SET_DEST_DIRECTORY
        LD HL,(FILEX_DEST_QUERY)
        XOR A:LD (@WDOS.ABT),A
        CALL @WDOS.SRHDRN
        JR Z,.destination_not_found
        LD DE,FILEX_DEST_CONTEXT
        CALL FILEX_CAPTURE_FOUND
        RET NZ
        CALL FILEX_CONTEXTS_EQUAL
        JR Z,FILEX_MOVE_SUCCESS
        LD A,(IY+FILEX_P_FLAGS):BIT 0,A
        LD A,FILEX_STATUS_EXISTS:RET Z
        JP FILEX_MOVE_REPLACE

.destination_not_found:
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:RET NZ
        ; Проверить collision с объектом противоположного типа в том же FAT namespace.
        LD HL,(FILEX_DEST_QUERY)
        LD A,(HL):XOR #10:LD (HL),A
        PUSH HL
        XOR A:LD (@WDOS.ABT),A
        CALL @WDOS.SRHDRN
        POP HL
        PUSH AF
        LD A,(HL):XOR #10:LD (HL),A
        POP AF
        JR Z,.create_new
        LD A,FILEX_STATUS_EXISTS:OR A:RET
.create_new:
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:RET NZ
        JP FILEX_MOVE_CREATE

FILEX_MOVE_SUCCESS:
        LD HL,1:LD (FILEX_RESULT),HL
        LD A,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+11)
        LD (FILEX_RESULT_FLAGS),A
        XOR A
        RET

; Каталог нельзя переносить внутрь самого себя либо собственного потомка.
; Идём от каталога назначения по «..» до корня; конечный лимит защищает от
; зацикленной или повреждённой родительской цепочки.
FILEX_VALIDATE_MOVE_ANCESTRY:
        LD A,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+11):BIT 4,A:RET Z
        LD HL,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+26)
        LD DE,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+20)
        LD A,D:AND #0F:LD D,A
        CALL FILEX_CLASSIFY_LINK
        JP C,.fat_error
        JP Z,.fat_error
        LD (FILEX_FIRST_CLUSTER),HL
        LD (FILEX_FIRST_CLUSTER+2),DE

        LD HL,(FILEX_DEST_DIR)
        LD DE,(FILEX_DEST_DIR+2)
        LD A,D:AND #0F:LD D,A
        LD (FILEX_ANCESTRY_CURRENT),HL
        LD (FILEX_ANCESTRY_CURRENT+2),DE
        LD HL,#4000:LD (FILEX_ANCESTRY_LIMIT),HL
.next_parent:
        LD HL,(FILEX_ANCESTRY_CURRENT)
        LD DE,(FILEX_FIRST_CLUSTER)
        OR A:SBC HL,DE:JR NZ,.compare_root
        LD HL,(FILEX_ANCESTRY_CURRENT+2)
        LD DE,(FILEX_FIRST_CLUSTER+2)
        OR A:SBC HL,DE:JP Z,.invalid_move
.compare_root:
        LD HL,(FILEX_ANCESTRY_CURRENT)
        LD DE,(@WDOS.BROOTC)
        OR A:SBC HL,DE:JR NZ,.check_zero
        LD HL,(FILEX_ANCESTRY_CURRENT+2)
        LD DE,(@WDOS.BROOTC+2)
        OR A:SBC HL,DE:RET Z
.check_zero:
        LD HL,(FILEX_ANCESTRY_CURRENT)
        LD DE,(FILEX_ANCESTRY_CURRENT+2)
        LD A,D:OR E:OR H:OR L:RET Z
        CALL FILEX_CLASSIFY_LINK
        JR C,.fat_error
        JR Z,.fat_error
        LD (FILEX_ANCESTRY_CURRENT),HL
        LD (FILEX_ANCESTRY_CURRENT+2),DE
        LD HL,FILEX_ANCESTRY_CURRENT
        CALL @WDOS.GIPAG
        JR NZ,.position_failed
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        RET NZ
        LD A,(@WDOS.LOBU):CP ".":JR NZ,.fat_error
        LD A,(@WDOS.LOBU+11):BIT 4,A:JR Z,.fat_error
        LD A,(@WDOS.LOBU+32):CP ".":JR NZ,.fat_error
        LD A,(@WDOS.LOBU+33):CP ".":JR NZ,.fat_error
        LD A,(@WDOS.LOBU+43):BIT 4,A:JR Z,.fat_error
        LD HL,(@WDOS.LOBU+58)
        LD DE,(@WDOS.LOBU+52)
        LD A,D:AND #0F:LD D,A
        LD (FILEX_ANCESTRY_PARENT),HL
        LD (FILEX_ANCESTRY_PARENT+2),DE
        LD BC,(FILEX_ANCESTRY_CURRENT)
        OR A:SBC HL,BC:JR NZ,.parent_ready
        LD H,D:LD L,E
        LD BC,(FILEX_ANCESTRY_CURRENT+2)
        OR A:SBC HL,BC:JR Z,.fat_error
.parent_ready:
        LD HL,(FILEX_ANCESTRY_PARENT)
        LD DE,(FILEX_ANCESTRY_PARENT+2)
        LD (FILEX_ANCESTRY_CURRENT),HL
        LD (FILEX_ANCESTRY_CURRENT+2),DE
        LD HL,(FILEX_ANCESTRY_LIMIT):DEC HL
        LD (FILEX_ANCESTRY_LIMIT),HL
        LD A,H:OR L:JP NZ,.next_parent
.fat_error:
        LD A,FILEX_STATUS_FAT:OR A:RET
.position_failed:
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:RET NZ
        JR .fat_error
.invalid_move:
        LD A,FILEX_STATUS_INVALID_MOVE:OR A:RET

; Создать ссылку назначения, точно перенести метаданные, поправить «..» и
; лишь затем удалить старую ссылку. Любая ранняя ошибка — откат
; (.rollback_new): вернуть «..» и удалить новую ссылку; не удался сам откат —
; FILEX_STATUS_ROLLBACK, и на объект могут остаться обе ссылки.
FILEX_MOVE_CREATE:
        CALL FILEX_CREATE_DESTINATION_LINK
; Claude - 2026-09-25 - begin
        ; Прежде RET NZ: запись ссылки назначения легла, а драйвер вернул
        ; отказ — на цепочке оставались обе ссылки (аудит Codex). Откат
        ; попытается удалить её по имени: до MOVE назначения с этим именем не
        ; было (MOVE_WORKER).
; Claude - 2026-09-25 - end
; Claude - 2026-10-10 - begin
        ; Откат — только после отказа носителя: отказ без него (нет места,
        ; имя, занято) — до любой записи, откатывать нечего (драйвер, R10-3).
        JR Z,.created
        CP FILEX_STATUS_MEDIA
        JR Z,.rollback_new
        OR A
        RET
.created:
; Claude - 2026-10-10 - end
        CALL FILEX_FIND_AND_CAPTURE_DESTINATION
        JR NZ,.rollback_new
        CALL FILEX_COPY_DEST_TO_CURRENT
        CALL FILEX_VERIFY_CONTEXT
        JR NZ,.rollback_new
        CALL FILEX_PATCH_CURRENT_FROM_SOURCE
        CALL FILEX_COMMIT_CONTEXT_ENTRY
        JR NZ,.rollback_new
        CALL FILEX_UPDATE_DOTDOT_IF_NEEDED
        JR NZ,.rollback_new
        CALL FILEX_DELETE_SOURCE_ENTRY
        JR Z,.committed
        CP FILEX_STATUS_COMMITTED_CLEANUP:JR Z,.committed_cleanup
; Claude - 2026-10-10 - begin
        ; Удаление источника не прошло или не подтвердилось — довести перенос
        ; по месту (ENTRY_KILL_AT); прежде сразу откат, и отказ уже в откате
        ; оставлял на цепочке две живые ссылки (драйвер, R8).
        LD (FILEX_SAVED_STATUS),A
        CALL FILEX_KILL_SOURCE
        JR Z,.committed_cleanup
        LD A,(FILEX_SAVED_STATUS)
; Claude - 2026-10-10 - end
; Claude - 2026-09-25 - begin
; Откат: сначала вернуть «..» (без изменения — ничего не пишет), и только
; если это удалось — удалить новую ссылку. Прежде результат возврата «..»
; отбрасывался, и после удаления ссылки назначения каталог оставался с «..»
; на новый родитель. Возврат «..» отказал — ссылка назначения не удаляется;
; не удалось удалить саму ссылку назначения — тоже. Выход
; FILEX_STATUS_ROLLBACK значит одно: откат не подтверждён. Сколько живых
; ссылок осталось (обычно две — из прежнего родителя и из нового; но если
; удаление источника легло, а его сектор не перечитался, — одна или ни
; одной) и куда смотрит «..», по статусу не узнать.
; Claude - 2026-10-10: каждый шаг отката — до трёх попыток (FILEX_RETRY3), а
; выход отката — без контекста FENTRY/APPEND: он мог быть уже взят по новой
; ссылке, и следующий FILEX без FENTRY освобождал или переписывал цепочку
; живого назначения (драйвер, R8, R9-1).
.rollback_new:
        LD (FILEX_SAVED_STATUS),A
        LD HL,FILEX_RESTORE_DOTDOT
        CALL FILEX_RETRY3
        JR NZ,.rollback_error
        CALL FILEX_DELETE_DESTINATION_LINK
        JR NZ,.rollback_error
        LD A,(FILEX_SAVED_STATUS):OR A
        JP FILEX_CONTEXT_FORGET
; Claude - 2026-09-25 - end
.rollback_error:
        LD A,FILEX_STATUS_ROLLBACK:OR A
        JP FILEX_CONTEXT_FORGET
.committed:
        CALL FILEX_IMPORT_CONTEXT
        JP FILEX_MOVE_SUCCESS
.committed_cleanup:
        CALL FILEX_IMPORT_CONTEXT
        CALL FILEX_MOVE_SUCCESS
        LD A,FILEX_STATUS_COMMITTED_CLEANUP
        OR A
        RET

FILEX_CREATE_DESTINATION_LINK:
        CALL FILEX_SET_DEST_DIRECTORY
        LD A,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+11)
        LD (@WDOS.EFLG),A
        LD HL,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+26)
        LD DE,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+20)
        LD (@WDOS.FCTS),HL
        LD (@WDOS.FCTS+2),DE
        LD HL,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+28)
        LD DE,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+30)
        LD (@WDOS.SIZIK),HL
        LD (@WDOS.SIZIK+2),DE
        LD HL,(FILEX_DEST_QUERY)
        INC HL
        XOR A:LD (@WDOS.ABT),A
        CALL @WDOS.SVHDFL
        JR NZ,.failed
        XOR A
        RET
.failed:
        LD B,A
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:RET NZ
; Claude - 2026-10-10 - begin
        ; Прежде NO_SPACE уходил с Z: MOVE_CREATE шёл дальше и отвечал
        ; NOT_FOUND; код 1 (имя не годится) давал INTERNAL (драйвер, R10-3).
        LD A,B
        LD C,FILEX_STATUS_NO_SPACE
        CP 16:JR Z,.status
        LD C,FILEX_STATUS_INVALID_NAME
        CP 1:JR Z,.status
        LD C,FILEX_STATUS_INTERNAL
.status:
        LD A,C
        OR A
        RET
; Claude - 2026-10-10 - end

FILEX_FIND_AND_CAPTURE_DESTINATION:
        CALL FILEX_SET_DEST_DIRECTORY
        LD HL,(FILEX_DEST_QUERY)
        XOR A:LD (@WDOS.ABT),A
        CALL @WDOS.SRHDRN
        JR Z,.not_found
        LD DE,FILEX_DEST_CONTEXT
        JP FILEX_CAPTURE_FOUND
.not_found:
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:RET NZ
        LD A,FILEX_STATUS_NOT_FOUND:OR A:RET

FILEX_COPY_DEST_TO_CURRENT:
        LD HL,FILEX_DEST_CONTEXT,DE,FILEX_CONTEXT,BC,FILEX_CONTEXT_SIZE
        LDIR
        RET

FILEX_PATCH_CURRENT_FROM_SOURCE:
        LD A,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+11)
        LD (FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+11),A
        LD HL,FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+13
        LD DE,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+13
        LD BC,19
        LDIR
        RET

; Удалить только каталоговую ссылку источника, не вызывая DLSG. Если запись
; после неоднозначной ошибки уже исчезла, новая ссылка сохраняется и операция
; считается зафиксированной с предупреждением cleanup.
; Claude - 2026-09-25 - begin
; «Исчезла» прежде проверялось поиском по имени, а он тут не довод:
; DELETE_ENTRY_WITH_LFN пишет секторы LFN раньше сектора SFN — при отказе
; последнего длинное имя уже стёрто, а короткая запись жива, и поиск её не
; находит; ошибка чтения при поиске тоже давала «не найдено». Тогда MOVE
; фиксировался (COMMITTED_CLEANUP) с двумя живыми ссылками на одну цепочку.
; Теперь, как у RENAME ядра, сектор SFN источника перечитывается по месту из
; FILEX_SOURCE_CONTEXT (до трёх попыток): #E5 — удаление легло; жива или не
; читается — MEDIA и откат (потерянная цепочка лучше общей).
; Claude - 2026-09-25 - end
FILEX_DELETE_SOURCE_ENTRY:
        CALL FILEX_SET_SOURCE_DIRECTORY
        LD HL,(FILEX_SOURCE_QUERY)
        XOR A:LD (@WDOS.ABT),A
        CALL @WDOS.SRHDRN
        JR Z,.not_found
        FILEX_CALL_EXTENSION ID_DELETE_ENTRY_WITH_LFN
        RET Z
; Claude - 2026-09-25 - begin
        LD C,3                                  ; попытки чтения
.reread:
        PUSH BC
        LD HL,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_LBA)
        LD DE,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        POP BC
        JR Z,.reread_done
        DEC C
        JR NZ,.reread
        OR A                                    ; A=MEDIA; DEC C оставил Z
        RET                                     ; не читается: NZ
.reread_done:
        LD HL,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_OFFSET)
        LD DE,@WDOS.LOBU
        ADD HL,DE
        LD A,(HL):CP #E5
        JR Z,.ambiguous_commit                  ; удаление легло
        LD A,FILEX_STATUS_MEDIA:OR A:RET        ; жива — откат
; Claude - 2026-09-25 - end
.not_found:
        LD A,FILEX_STATUS_ENTRY_CHANGED:OR A:RET
.ambiguous_commit:
        LD A,FILEX_STATUS_COMMITTED_CLEANUP:OR A:RET

; Claude - 2026-10-10 - begin
; Удалить новую ссылку назначения (откат MOVE с созданием): найти её (поиск,
; не прочитавший каталог, — до трёх попыток; место — в FILEX_DEST_CONTEXT),
; удалить по имени с длинным именем и убедиться по месту (ENTRY_KILL_AT).
; Прежде — одна попытка по имени: стерев длинное имя и не записав короткую,
; она оставляла живую вторую ссылку. Не нашлась без отказа чтения — ссылки
; нет: Z (драйвер, R8).
FILEX_DELETE_DESTINATION_LINK:
        LD A,3
.find:
        LD (FILEX_RETRY_LEFT),A
        CALL FILEX_FIND_AND_CAPTURE_DESTINATION
        JR Z,.found
        CP FILEX_STATUS_NOT_FOUND
        JR NZ,.again
        XOR A
        RET
.again:
        LD A,(FILEX_RETRY_LEFT):DEC A
        JR NZ,.find
        LD A,FILEX_STATUS_MEDIA:OR A
        RET
.found:
        CALL FILEX_SET_DEST_DIRECTORY
        LD HL,(FILEX_DEST_QUERY)
        XOR A:LD (@WDOS.ABT),A
        CALL @WDOS.SRHDRN
        JR Z,.verify
        FILEX_CALL_EXTENSION ID_DELETE_ENTRY_WITH_LFN
.verify:
        LD HL,(FILEX_DEST_CONTEXT+FILEX_CONTEXT_LBA)
        LD DE,(FILEX_DEST_CONTEXT+FILEX_CONTEXT_LBA+2)
        LD BC,(FILEX_DEST_CONTEXT+FILEX_CONTEXT_OFFSET)
        CALL FILEX_ENTRY_KILL_AT
        RET Z
        LD A,FILEX_STATUS_MEDIA:OR A
        RET

; Довести перенос, когда удаление источника по имени не прошло или не
; подтвердилось: его короткая запись — #E5 по месту (ENTRY_KILL_AT).
FILEX_KILL_SOURCE:
        LD HL,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_LBA)
        LD DE,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_LBA+2)
        LD BC,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_OFFSET)
        JP FILEX_ENTRY_KILL_AT

; Шаг отката HL — до трёх попыток, пока не вернёт Z (шаги перечитывают
; носитель и повторяемы). Прежде шаг делался один раз, и второй отказ подряд
; оставлял на цепочке две живые записи или «..» на нового родителя. Выход —
; флаги и A последней попытки.
FILEX_RETRY3:
        LD (FILEX_RETRY_STEP),HL
        LD A,3
.try:
        LD (FILEX_RETRY_LEFT),A
        LD HL,.back
        PUSH HL
        LD HL,(FILEX_RETRY_STEP)
        JP (HL)
.back:
        RET Z
        LD B,A
        LD A,(FILEX_RETRY_LEFT):DEC A
        JR NZ,.try
        LD A,B:OR A
        RET

; Короткую запись в секторе DE:HL по смещению BC (0..511, кратно 32) —
; удалённой (#E5) вместе с записями её длинного имени в том же секторе (они
; идут подряд перед ней) — и убедиться: до трёх попыток «прочитать — пометить
; — записать», затем перечитать. Удаление по имени для повтора не годится:
; стерев длинное имя и не записав короткую, при повторе оно её уже не находит.
; Выход: Z — на носителе #E5; NZ — не удалось. Разрушает AF, BC, DE, HL и LOBU.
FILEX_ENTRY_KILL_AT:
        LD A,B:CP 2:JR NC,.fail
        LD A,C:AND #1F:JR NZ,.fail
        LD (FILEX_KILL_LBA),HL
        LD (FILEX_KILL_LBA+2),DE
        LD (FILEX_KILL_OFFSET),BC
        LD A,4                                  ; три записи и проверка
.try:
        LD (FILEX_KILL_LEFT),A
        CALL .position
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        JR NZ,.next                             ; не прочитан — ещё раз
        LD HL,@WDOS.LOBU,DE,(FILEX_KILL_OFFSET)
        ADD HL,DE
        LD A,(HL):CP #E5:RET Z                  ; на носителе удалена
        LD A,(FILEX_KILL_LEFT):DEC A:JR Z,.fail ; записей больше не будет
        LD (HL),#E5
        LD BC,(FILEX_KILL_OFFSET)
.lfn:                                           ; её длинное имя в этом секторе
        LD A,B:OR C:JR Z,.write
        LD A,C:SUB 32:LD C,A
        LD A,B:SBC A,0:LD B,A
        LD HL,@WDOS.LOBU:ADD HL,BC
        LD A,(HL):CP #E5:JR Z,.write
        PUSH HL
        LD DE,11:ADD HL,DE
        LD A,(HL)
        POP HL
        CP #0F:JR NZ,.write
        LD (HL),#E5
        JR .lfn
.write:
        CALL .position
        LD HL,@WDOS.LOBU
        CALL FILEX_WRITE_ONE
        RET Z                                   ; легла
.next:
        LD A,(FILEX_KILL_LEFT):DEC A
        JR NZ,.try
.fail:
        OR 1
        RET
.position:
        LD HL,(FILEX_KILL_LBA),DE,(FILEX_KILL_LBA+2)
        JP @WDOS.PROZ

; Снять контекст FENTRY/APPEND (мост, A=1): после отката или неизвестного
; исхода записи он не описывает носитель, и следующий FILEX или APPEND без
; FENTRY писал бы по чужой цепочке (драйвер, R4-7, R9-1). AF сохраняется.
FILEX_CONTEXT_FORGET:
        PUSH AF
        LD A,1
        FILEX_CALL_EXTENSION ID_FILEX_CONTEXT_BRIDGE
        XOR A:LD (FILEX_CHAIN_CACHE_VALID),A
        POP AF
        RET
; Claude - 2026-10-10 - end

; Replace меняет найденную SFN назначения на месте. Источник остаётся целым
; до подтверждённой записи назначения и обновления «..» каталога.
FILEX_MOVE_REPLACE:
        LD A,(FILEX_DEST_CONTEXT+FILEX_CONTEXT_ENTRY+11)
        BIT 0,A:LD A,FILEX_STATUS_READ_ONLY:RET NZ
        LD A,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+11):AND #10:LD B,A
        LD A,(FILEX_DEST_CONTEXT+FILEX_CONTEXT_ENTRY+11):AND #10:CP B
        LD A,FILEX_STATUS_EXISTS:RET NZ
        LD A,B:OR A:JR Z,.replace_ready
        CALL FILEX_DIRECTORY_EMPTY_DESTINATION
        RET NZ
; Claude - 2026-10-10 - begin
        ; Заменяемый каталог — текущий (LSTCAT до MOVE): замена освободила бы
        ; его цепочку, а текущим остался бы освобождённый кластер, и создание
        ; писало бы записи в файл, которому он потом достанется (драйвер, R10-1).
        LD HL,(FILEX_DEST_CONTEXT+FILEX_CONTEXT_ENTRY+26)
        LD DE,(FILEX_SAVED_ACTIVE_DIR)
        OR A:SBC HL,DE:JR NZ,.replace_ready
        LD HL,(FILEX_DEST_CONTEXT+FILEX_CONTEXT_ENTRY+20)
        LD A,H:AND #0F:LD H,A
        LD DE,(FILEX_SAVED_ACTIVE_DIR+2)
        LD A,D:AND #0F:LD D,A
        OR A:SBC HL,DE
        LD A,FILEX_STATUS_INVALID_MOVE
        JR NZ,.replace_ready
        OR A
        RET
; Claude - 2026-10-10 - end
.replace_ready:
; Claude - 2026-10-10 - begin
        ; Цепочки источника и заменяемого назначения не пересекаются: прежде
        ; сравнивался только первый кластер, и при общем хвосте замена
        ; освобождала его вместе со старым назначением — из-под живого
        ; источника (драйвер, R2-7).
        CALL FILEX_CHAINS_DISJOINT
        LD A,FILEX_STATUS_FAT
        RET NZ
; Claude - 2026-10-10 - end
        CALL FILEX_SAVE_OLD_DEST_CLUSTER
        CALL FILEX_COPY_DEST_TO_CURRENT
        CALL FILEX_VERIFY_CONTEXT
        RET NZ
        CALL FILEX_PATCH_CURRENT_FROM_SOURCE
        CALL FILEX_COMMIT_CONTEXT_ENTRY
; Claude - 2026-09-26 - begin
        ; Прежде RET NZ: запись назначения, перенаправленная на цепочку
        ; источника, легла, а драйвер вернул отказ, — MEDIA, на цепочку
        ; смотрели обе записи, а старая цепочка назначения терялась (аудит,
        ; А.3). Теперь откат: прежняя запись назначения возвращается, если на
        ; диске новая; если запись не легла — возвращать нечего.
        JR NZ,.restore_destination
; Claude - 2026-09-26 - end
        CALL FILEX_UPDATE_DOTDOT_IF_NEEDED
        JR NZ,.restore_destination
        CALL FILEX_DELETE_SOURCE_ENTRY
        JR Z,.committed
        CP FILEX_STATUS_COMMITTED_CLEANUP:JR Z,.committed_cleanup
; Claude - 2026-10-10 - begin
        LD (FILEX_SAVED_STATUS),A
        CALL FILEX_KILL_SOURCE                  ; довести перенос (как у CREATE)
        JR Z,.committed_cleanup
        LD A,(FILEX_SAVED_STATUS)
; Claude - 2026-10-10 - end
; Claude - 2026-09-25 - begin
; Как у MOVE_CREATE: «..» возвращается и после отказа его собственной записи
; (признак ставится до неё), а не вернулся — запись назначения не трогаем.
; Claude - 2026-10-10: каждый шаг — до трёх попыток; выход отката — без
; контекста FENTRY/APPEND: запись отката взяла бы в него прежнее назначение,
; которого никто не выбирал, и следующий FILEX без FENTRY переписывал или
; усекал его (драйвер, R4-7).
.restore_destination:
        LD (FILEX_SAVED_STATUS),A
        LD HL,FILEX_RESTORE_DOTDOT
        CALL FILEX_RETRY3
        JR NZ,.rollback_error
        LD HL,FILEX_RESTORE_DESTINATION_ENTRY
        CALL FILEX_RETRY3
        JR NZ,.rollback_error
        LD A,(FILEX_SAVED_STATUS):OR A
        JP FILEX_CONTEXT_FORGET
; Claude - 2026-09-25 - end
.rollback_error:
        LD A,FILEX_STATUS_ROLLBACK:OR A
        JP FILEX_CONTEXT_FORGET
.committed:
        CALL FILEX_IMPORT_CONTEXT
        CALL FILEX_MOVE_SUCCESS
        CALL FILEX_RELEASE_OLD_DESTINATION
        RET Z
        LD A,FILEX_STATUS_COMMITTED_CLEANUP:OR A:RET
.committed_cleanup:
        CALL FILEX_IMPORT_CONTEXT
        CALL FILEX_MOVE_SUCCESS
        CALL FILEX_RELEASE_OLD_DESTINATION
        LD A,FILEX_STATUS_COMMITTED_CLEANUP:OR A:RET

FILEX_SAVE_OLD_DEST_CLUSTER:
        LD HL,(FILEX_DEST_CONTEXT+FILEX_CONTEXT_ENTRY+26)
        LD DE,(FILEX_DEST_CONTEXT+FILEX_CONTEXT_ENTRY+20)
        LD A,D:AND #0F:LD D,A
        LD (FILEX_OLD_DEST_CLUSTER),HL
        LD (FILEX_OLD_DEST_CLUSTER+2),DE
        RET

; Claude - 2026-10-10 - begin
; Вернуть прежнюю запись назначения. На месте прежняя (новая не легла или
; возврат уже лёг) — Z; новая — пишется прежняя; не читается или там что-то
; третье — NZ. Повторяема (FILEX_RETRY3): обе ожидаемые записи каждый раз
; строятся заново — прежде вторая попытка сравнивала уже с прежней и не
; узнавала новую (драйвер, R8).
FILEX_RESTORE_DESTINATION_ENTRY:
        CALL .old_to_context
        CALL FILEX_VERIFY_CONTEXT
        RET Z                                   ; на месте прежняя
        CP FILEX_STATUS_ENTRY_CHANGED:RET NZ    ; не читается
        CALL FILEX_COPY_DEST_TO_CURRENT
        CALL FILEX_PATCH_CURRENT_FROM_SOURCE
        CALL FILEX_VERIFY_CONTEXT
        RET NZ                                  ; на месте не новая
        CALL .old_to_context
        JP FILEX_COMMIT_CONTEXT_ENTRY
.old_to_context:
; Claude - 2026-10-10 - end
        LD HL,FILEX_DEST_CONTEXT+FILEX_CONTEXT_ENTRY
        LD DE,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY
        LD BC,32
        LDIR
        RET

FILEX_RELEASE_OLD_DESTINATION:
        LD HL,(FILEX_OLD_DEST_CLUSTER)
        LD DE,(FILEX_OLD_DEST_CLUSTER+2)
        LD A,D:OR E:OR H:OR L:RET Z
        LD BC,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+26)
        OR A:SBC HL,BC:JR NZ,.reload_release
        LD H,D:LD L,E
        LD BC,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+20)
        OR A:SBC HL,BC:RET Z
.reload_release:
        LD HL,(FILEX_OLD_DEST_CLUSTER)
        LD DE,(FILEX_OLD_DEST_CLUSTER+2)
        CALL FILEX_CLASSIFY_LINK
        JR C,.failed
        JR Z,.failed
        LD (@WDOS.LOBU),HL
        LD (@WDOS.LOBU+2),DE
        XOR A:LD (@WDOS.ABT),A
        LD HL,@WDOS.LOBU
        CALL @WDOS.DLSG
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        CALL #4030
        RET
.failed:
        LD A,FILEX_STATUS_COMMITTED_CLEANUP:OR A:RET

; Проверить, что заменяемый каталог не содержит записей, кроме «.»/«..»/LFN.
FILEX_DIRECTORY_EMPTY_DESTINATION:
        LD HL,(FILEX_DEST_CONTEXT+FILEX_CONTEXT_ENTRY+26)
        LD DE,(FILEX_DEST_CONTEXT+FILEX_CONTEXT_ENTRY+20)
        LD A,D:AND #0F:LD D,A
; Claude - 2026-10-10 - begin
        ; Цепочка каталога назначения конечна, в томе и без кластеров корня
        ; (FILEX_CHAIN_CHECK): обход ниже прежде вис на замкнутой цепочке без
        ; нулевой записи (драйвер, R7).
        PUSH HL
        PUSH DE
        CALL FILEX_CHAIN_CHECK
        POP DE
        POP HL
        JR NZ,.fat_error
; Claude - 2026-10-10 - end
        CALL FILEX_CLASSIFY_LINK
        JR C,.fat_error
        JR Z,.fat_error
        LD (FILEX_CURRENT_CLUSTER),HL
        LD (FILEX_CURRENT_CLUSTER+2),DE
        XOR A:LD (FILEX_CURRENT_SECTOR),A
.sector_loop:
        CALL FILEX_POSITION_CURRENT
        RET NZ
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        RET NZ
        LD HL,@WDOS.LOBU
        LD B,16
.entry_loop:
        LD A,(HL):OR A:JR Z,.empty
        CP #E5:JR Z,.next_entry
        PUSH HL
        LD DE,11:ADD HL,DE
        LD A,(HL):CP #0F
        POP HL
        JR Z,.next_entry
        CALL FILEX_IS_DOT_ENTRY:JR NZ,.not_empty
.next_entry:
        LD DE,32:ADD HL,DE
        DJNZ .entry_loop
        LD A,(FILEX_CURRENT_SECTOR):INC A
        LD C,A
        LD A,(@WDOS.BSECPC):CP C
        LD A,C:JR NZ,.same_cluster
        XOR A:LD (FILEX_CURRENT_SECTOR),A
        CALL FILEX_NEXT_CLUSTER_FOR_DIRECTORY
        JR Z,.empty
        RET C
        JR .sector_loop
.same_cluster:
        LD (FILEX_CURRENT_SECTOR),A
        JR .sector_loop
.empty:
        XOR A
        RET
.not_empty:
        LD A,FILEX_STATUS_NOT_EMPTY:OR A:RET
.fat_error:
        LD A,FILEX_STATUS_FAT:OR A:RET

; Выход Z только для точных коротких имён «.» и «..», дополненных пробелами.
FILEX_IS_DOT_ENTRY:
        PUSH BC,HL
        LD A,(HL):CP ".":JR NZ,.not_dot
        INC HL
        LD A,(HL):CP ".":JR Z,.dotdot
        CP " ":JR NZ,.not_dot
        LD B,10
        JR .spaces
.dotdot:
        INC HL
        LD B,9
.spaces:
        LD A,(HL):CP " ":JR NZ,.not_dot
        INC HL:DJNZ .spaces
        POP HL,BC
        XOR A
        RET
.not_dot:
        POP HL,BC
        LD A,1:OR A:RET

; Выход: Z — EOC; CF=1/NZ — ошибка с A=status; NZ/CF=0 — следующий кластер.
FILEX_NEXT_CLUSTER_FOR_DIRECTORY:
        XOR A:LD (@WDOS.ABT),A
        LD HL,(FILEX_CURRENT_CLUSTER)
        LD DE,(FILEX_CURRENT_CLUSTER+2)
        CALL @WDOS.CURIT
        JR C,.lookup_failed
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A
        EX DE,HL
        CALL FILEX_CLASSIFY_LINK
        JR C,.fat_error
        RET Z
        LD (FILEX_CURRENT_CLUSTER),HL
        LD (FILEX_CURRENT_CLUSTER+2),DE
        LD A,1:OR A
        RET
.fat_error:
        LD A,FILEX_STATUS_FAT
        OR A
        SCF
        RET
.lookup_failed:
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:JR NZ,.error
        LD A,FILEX_STATUS_FAT
.error:
        OR A
        SCF
        RET

; При переносе каталога между родителями обновить его запись «..».
FILEX_UPDATE_DOTDOT_IF_NEEDED:
        LD A,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+11):BIT 4,A:RET Z
        LD HL,(FILEX_SOURCE_DIR),DE,(FILEX_DEST_DIR)
        OR A:SBC HL,DE:JR NZ,.different
        LD HL,(FILEX_SOURCE_DIR+2),DE,(FILEX_DEST_DIR+2)
        OR A:SBC HL,DE:RET Z
.different:
        LD HL,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+26)
        LD DE,(FILEX_SOURCE_CONTEXT+FILEX_CONTEXT_ENTRY+20)
        LD A,D:AND #0F:LD D,A
        LD (FILEX_DOTDOT_CLUSTER),HL
        LD (FILEX_DOTDOT_CLUSTER+2),DE
        LD HL,FILEX_DOTDOT_CLUSTER
        CALL @WDOS.GIPAG
        JR NZ,.fat_error
        LD HL,(@WDOS.CLHL),DE,(@WDOS.CLDE)
        LD (FILEX_DOTDOT_LBA),HL
        LD (FILEX_DOTDOT_LBA+2),DE
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        RET NZ
        LD A,(@WDOS.LOBU+32):CP ".":JR NZ,.fat_error
        LD A,(@WDOS.LOBU+33):CP ".":JR NZ,.fat_error
        LD A,(@WDOS.LOBU+43):BIT 4,A:JR Z,.fat_error
        LD HL,(@WDOS.LOBU+58),DE,(@WDOS.LOBU+52)
        LD (FILEX_DOTDOT_OLD_PARENT),HL
        LD (FILEX_DOTDOT_OLD_PARENT+2),DE
        LD HL,(FILEX_DEST_DIR),DE,(FILEX_DEST_DIR+2)
        LD A,D:AND #0F:LD D,A
        LD (@WDOS.LOBU+58),HL
        LD (@WDOS.LOBU+52),DE
        LD HL,(FILEX_DOTDOT_LBA),DE,(FILEX_DOTDOT_LBA+2)
        CALL @WDOS.PROZ
; Claude - 2026-09-25 - begin
        ; Признак — до записи: сектор мог лечь, хоть драйвер и вернул отказ.
        ; Прежде откат тогда удалял новую ссылку, не вернув «..»: каталог
        ; оставался в прежнем родителе с «..» на новый — обход вверх (F8)
        ; искал бы имя в чужом каталоге. Вернуть неизменённый «..» безвредно.
        LD A,1:LD (FILEX_DOTDOT_CHANGED),A
; Claude - 2026-09-25 - end
        LD HL,@WDOS.LOBU
        CALL FILEX_WRITE_ONE
        RET NZ
        XOR A
        RET
.fat_error:
        LD A,FILEX_STATUS_FAT:OR A:RET

FILEX_RESTORE_DOTDOT:
        LD A,(FILEX_DOTDOT_CHANGED):OR A:RET Z
        LD HL,(FILEX_DOTDOT_LBA),DE,(FILEX_DOTDOT_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        RET NZ
        LD HL,(FILEX_DOTDOT_OLD_PARENT)
        LD DE,(FILEX_DOTDOT_OLD_PARENT+2)
        LD (@WDOS.LOBU+58),HL
        LD (@WDOS.LOBU+52),DE
        LD HL,(FILEX_DOTDOT_LBA),DE,(FILEX_DOTDOT_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU
        CALL FILEX_WRITE_ONE
        RET NZ
        XOR A:LD (FILEX_DOTDOT_CHANGED),A
        RET

; Прочитать секторно выровненное окно выбранной активной FAT. При включённом
; зеркалировании читается FAT0; при BPB_ExtFlags.bit7=1 — указанная активная
; копия. offset задаётся в байтах от начала FAT, length=512..16384.
FILEX_READ_FAT:
        LD A,(IY+FILEX_P_FLAGS):OR A:JP NZ,FILEX_BAD_BLOCK
        LD L,(IY+FILEX_P_LENGTH+0)
        LD H,(IY+FILEX_P_LENGTH+1)
        LD A,H:OR L:JP Z,.bad_length
        LD A,L:OR A:JP NZ,.bad_length
        LD A,H:AND 1:JP NZ,.bad_length
        LD DE,#4001
        OR A:SBC HL,DE:JP NC,.bad_length

        LD C,(IY+FILEX_P_LENGTH+0)
        LD B,(IY+FILEX_P_LENGTH+1)
        LD L,(IY+FILEX_P_BUFFER+0)
        LD H,(IY+FILEX_P_BUFFER+1)
        CALL FILEX_VALIDATE_BUFFER
        JP NZ,FILEX_FINISH
        LD (FILEX_FAT_BUFFER),HL

        ; И offset, и длина обязаны быть кратны сектору 512 байт.
        LD A,(IY+FILEX_P_OFFSET+0):OR A:JP NZ,.bad_length
        LD A,(IY+FILEX_P_OFFSET+1):AND 1:JP NZ,.bad_length
        LD L,(IY+FILEX_P_OFFSET+0)
        LD H,(IY+FILEX_P_OFFSET+1)
        LD E,(IY+FILEX_P_OFFSET+2)
        LD D,(IY+FILEX_P_OFFSET+3)
        LD B,9
.shift_sector:
        SRL D:RR E:RR H:RR L
        DJNZ .shift_sector
        LD (FILEX_FAT_SECTOR),HL
        LD (FILEX_FAT_SECTOR+2),DE

        LD A,(IY+FILEX_P_LENGTH+1)
        SRL A
        LD (FILEX_FAT_COUNT),A
        LD C,A:LD B,0
        ADD HL,BC
        EX DE,HL
        LD BC,0
        ADC HL,BC
        EX DE,HL
        LD (FILEX_FAT_END),HL
        LD (FILEX_FAT_END+2),DE

        ; Конец окна может совпадать с BFTSZ, но не переходить за него.
        LD HL,(FILEX_FAT_END+2)
        LD BC,(@WDOS.BFTSZ+2)
        OR A:SBC HL,BC:JR C,.range_ok
        JP NZ,.bad_length
        LD HL,(FILEX_FAT_END)
        LD BC,(@WDOS.BFTSZ)
        OR A:SBC HL,BC:JR C,.range_ok
        JP NZ,.bad_length
.range_ok:
        LD HL,(FILEX_FAT_SECTOR)
        LD DE,(FILEX_FAT_SECTOR+2)
        FILEX_CALL_EXTENSION ID_POSITION_FAT_READ
        LD HL,(FILEX_FAT_BUFFER)
        LD A,(FILEX_FAT_COUNT)
        FILEX_CALL_EXTENSION ID_READ_SECTORS
        JR NZ,.media_error
        LD L,(IY+FILEX_P_LENGTH+0)
        LD H,(IY+FILEX_P_LENGTH+1)
        LD (FILEX_RESULT),HL
        XOR A
        JP FILEX_FINISH
.media_error:
        LD A,FILEX_STATUS_MEDIA
        JP FILEX_FINISH
.bad_length:
        LD A,FILEX_STATUS_BAD_LENGTH
        JP FILEX_FINISH

; Вернуть геометрию FAT32 и проверенные подсказки FSInfo. Неизвестное число
; свободных кластеров обозначается #FFFFFFFF и отсутствием FREE_KNOWN.
FILEX_GET_FS_INFO:
        LD A,(IY+FILEX_P_FLAGS)
        AND ~FILEX_FLAG_REFRESH_FREE:JP NZ,FILEX_BAD_BLOCK
        LD L,(IY+FILEX_P_LENGTH+0)
        LD H,(IY+FILEX_P_LENGTH+1)
        LD DE,FILEX_FS_SIZE
        OR A:SBC HL,DE:JP C,.bad_length
        LD C,(IY+FILEX_P_LENGTH+0)
        LD B,(IY+FILEX_P_LENGTH+1)
        LD L,(IY+FILEX_P_BUFFER+0)
        LD H,(IY+FILEX_P_BUFFER+1)
        CALL FILEX_VALIDATE_BUFFER
        JP NZ,FILEX_FINISH
        LD (FILEX_FS_DESTINATION),HL

        LD HL,FILEX_FS_OUTPUT
        LD DE,FILEX_FS_OUTPUT+1
        LD BC,FILEX_FS_SIZE-1
        XOR A:LD (HL),A:LDIR
        LD A,FILEX_FS_SIZE:LD (FILEX_FS_OUTPUT+FILEX_FS_O_SIZE),A
        LD A,FILEX_FS_VERSION:LD (FILEX_FS_OUTPUT+FILEX_FS_O_VERSION),A
        LD A,FILEX_FS_FLAG_MEDIA_PRESENT
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FLAGS),A
        LD HL,512:LD (FILEX_FS_OUTPUT+FILEX_FS_O_BYTES_PER_SECTOR),HL
        LD HL,#FFFF
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FREE_CLUSTERS),HL
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FREE_CLUSTERS+2),HL
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_NEXT_FREE),HL
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_NEXT_FREE+2),HL

        ; Загрузочный сектор раздела содержит serial, label и точный размер.
        LD HL,(@WDOS.ADDTOP)
        LD DE,(@WDOS.ADDTOP+2)
        CALL @WDOS.XPOZI
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        JP NZ,FILEX_FINISH
        LD HL,(@WDOS.LOBU+11)
        LD DE,512
        OR A:SBC HL,DE:JP NZ,.fat_error
        LD A,(@WDOS.LOBU+13):OR A:JP Z,.fat_error
        LD B,A:DEC A:AND B:JP NZ,.fat_error
        LD A,(@WDOS.BSECPC):CP B:JP NZ,.fat_error
        LD A,B:LD (FILEX_FS_OUTPUT+FILEX_FS_O_SECTORS_PER_CLUSTER),A
        LD A,(@WDOS.LOBU+16):OR A:JP Z,.fat_error
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FAT_COUNT),A
        LD (FILEX_FS_FAT_COUNT),A
        LD A,(@WDOS.LOBU+40)
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FAT_FLAGS),A
        BIT 7,A:JR NZ,.active_fat_selected
        XOR A
        JR .active_fat_ready
.active_fat_selected:
        AND #0F
.active_fat_ready:
        LD C,A
        LD A,(FILEX_FS_FAT_COUNT):CP C:JP Z,.fat_error:JP C,.fat_error
        LD A,C
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_ACTIVE_FAT),A

        LD HL,(@WDOS.LOBU+36)
        LD DE,(@WDOS.LOBU+38)
        LD (FILEX_FS_FAT_SECTORS),HL
        LD (FILEX_FS_FAT_SECTORS+2),DE
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FAT_SECTORS),HL
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FAT_SECTORS+2),DE
        LD A,D:OR E:OR H:OR L:JP Z,.fat_error
        LD HL,(@WDOS.LOBU+19)
        LD A,H:OR L:JR NZ,.total16
        LD HL,(@WDOS.LOBU+32)
        LD DE,(@WDOS.LOBU+34)
        JR .total_ready
.total16:
        LD DE,0
.total_ready:
        LD A,D:OR E:OR H:OR L:JP Z,.fat_error
        LD (FILEX_FS_TOTAL_SECTORS),HL
        LD (FILEX_FS_TOTAL_SECTORS+2),DE
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_TOTAL_SECTORS),HL
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_TOTAL_SECTORS+2),DE
        LD HL,(@WDOS.LOBU+67)
        LD DE,(@WDOS.LOBU+69)
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_SERIAL),HL
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_SERIAL+2),DE
        LD HL,@WDOS.LOBU+71
        LD DE,FILEX_FS_OUTPUT+FILEX_FS_O_LABEL
        LD BC,11
        LDIR
        XOR A:LD (DE),A
        LD HL,FILEX_FS_OUTPUT+FILEX_FS_O_LABEL
        LD B,11
.label_scan:
        LD A,(HL):CP " ":JR NZ,.label_valid
        INC HL:DJNZ .label_scan
        JR .label_done
.label_valid:
        LD A,(FILEX_FS_OUTPUT+FILEX_FS_O_FLAGS)
        OR FILEX_FS_FLAG_LABEL_VALID
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FLAGS),A
.label_done:

        ; data_sectors = total - reserved - fat_count*fat_sectors.
        LD HL,0
        LD (FILEX_FS_FAT_AREA),HL
        LD (FILEX_FS_FAT_AREA+2),HL
        LD A,(FILEX_FS_FAT_COUNT)
        LD B,A
.fat_area_loop:
        LD HL,(FILEX_FS_FAT_AREA)
        LD DE,(FILEX_FS_FAT_SECTORS)
        ADD HL,DE
        LD (FILEX_FS_FAT_AREA),HL
        LD HL,(FILEX_FS_FAT_AREA+2)
        LD DE,(FILEX_FS_FAT_SECTORS+2)
        ADC HL,DE
        LD (FILEX_FS_FAT_AREA+2),HL
        DJNZ .fat_area_loop
        LD HL,(FILEX_FS_TOTAL_SECTORS)
        LD BC,(FILEX_FS_FAT_AREA)
        OR A:SBC HL,BC
        LD (FILEX_FS_DATA_SECTORS),HL
        LD HL,(FILEX_FS_TOTAL_SECTORS+2)
        LD BC,(FILEX_FS_FAT_AREA+2)
        SBC HL,BC:JP C,.fat_error
        LD (FILEX_FS_DATA_SECTORS+2),HL
        LD HL,(FILEX_FS_DATA_SECTORS)
        LD BC,(@WDOS.LOBU+14)
        OR A:SBC HL,BC
        LD (FILEX_FS_DATA_SECTORS),HL
        LD HL,(FILEX_FS_DATA_SECTORS+2)
        LD BC,0
        SBC HL,BC:JP C,.fat_error
        LD DE,HL
        LD HL,(FILEX_FS_DATA_SECTORS)
        LD A,(@WDOS.BSECPC)
.cluster_divide:
        CP 1:JR Z,.cluster_count_ready
        SRL D:RR E:RR H:RR L
        SRL A
        JR .cluster_divide
.cluster_count_ready:
        LD (FILEX_FS_TOTAL_CLUSTERS),HL
        LD (FILEX_FS_TOTAL_CLUSTERS+2),DE
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_TOTAL_CLUSTERS),HL
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_TOTAL_CLUSTERS+2),DE

        ; FSInfo с плохими сигнатурами не ломает остальную информацию о томе.
; Claude - 2026-10-10 - begin
        ; Сектор FSInfo — только внутри резервной области (не 0, меньше
        ; BREZS): прежде испорченный BPB_FSInfo вёл чтение в чужой сектор, и
        ; его байты с подписями выдавались за подсказки (драйвер, R6-4).
        CALL FILEX_FSINFO_POSITION
        JR C,.refresh
; Claude - 2026-10-10 - end
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        JP NZ,FILEX_FINISH
        CALL FILEX_VALIDATE_FSINFO
        JR NZ,.refresh
        LD HL,(@WDOS.LOBU+488)
        LD DE,(@WDOS.LOBU+490)
        LD A,D:AND E:AND H:AND L:CP #FF:JR Z,.next_free
        LD (FILEX_FS_FREE_TEMP),HL
        LD (FILEX_FS_FREE_TEMP+2),DE
        LD H,D:LD L,E
        LD BC,(FILEX_FS_TOTAL_CLUSTERS+2)
        OR A:SBC HL,BC:JR C,.free_valid
        JR NZ,.next_free
        LD HL,(FILEX_FS_FREE_TEMP)
        LD BC,(FILEX_FS_TOTAL_CLUSTERS)
        OR A:SBC HL,BC
        JR C,.free_valid
        JR NZ,.next_free
.free_valid:
        LD HL,(FILEX_FS_FREE_TEMP)
        LD DE,(FILEX_FS_FREE_TEMP+2)
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FREE_CLUSTERS),HL
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FREE_CLUSTERS+2),DE
        LD A,(FILEX_FS_OUTPUT+FILEX_FS_O_FLAGS)
        OR FILEX_FS_FLAG_FREE_KNOWN
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FLAGS),A
.next_free:
        LD HL,(@WDOS.LOBU+492)
        LD DE,(@WDOS.LOBU+494)
; Claude - 2026-10-10 - begin
        ; Подсказка — только кластер данных этого тома (прежде отдавалась
        ; как есть, драйвер, R6-4); иначе — #FFFFFFFF.
        CALL FILEX_VALIDATE_FREE_HINT
        JR NZ,.refresh
; Claude - 2026-10-10 - end
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_NEXT_FREE),HL
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_NEXT_FREE+2),DE
; Claude - 2026-10-10 - begin
; FILEX_FLAG_REFRESH_FREE прежде принимался и ничего не менял (драйвер, R6-3),
; а RFRH_SAFE пишет в FSInfo #FFFFFFFF, и после любой записи WC число
; свободных кластеров было неизвестно. Теперь — пересчёт по FAT.
.refresh:
        LD A,(IY+FILEX_P_FLAGS):OR A:JR Z,.copy_output
        CALL FILEX_COUNT_FREE
        JP NZ,FILEX_FINISH
        LD HL,(FILEX_FS_FREE_TEMP)
        LD DE,(FILEX_FS_FREE_TEMP+2)
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FREE_CLUSTERS),HL
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FREE_CLUSTERS+2),DE
        LD A,(FILEX_FS_OUTPUT+FILEX_FS_O_FLAGS)
        OR FILEX_FS_FLAG_FREE_KNOWN
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_FLAGS),A
; Claude - 2026-10-10 - end

.copy_output:
        LD HL,FILEX_FS_OUTPUT
        LD DE,(FILEX_FS_DESTINATION)
        LD BC,FILEX_FS_SIZE
        LDIR
        LD HL,FILEX_FS_SIZE
        LD (FILEX_RESULT),HL
        XOR A
        JP FILEX_FINISH
.bad_length:
        LD A,FILEX_STATUS_BAD_LENGTH
        JP FILEX_FINISH
.fat_error:
        LD A,FILEX_STATUS_FAT
        JP FILEX_FINISH

FILEX_VALIDATE_FSINFO:
        LD HL,(@WDOS.LOBU+0),DE,#5252
        OR A:SBC HL,DE:JR NZ,.bad
        LD HL,(@WDOS.LOBU+2),DE,#4161
        OR A:SBC HL,DE:JR NZ,.bad
        LD HL,(@WDOS.LOBU+484),DE,#7272
        OR A:SBC HL,DE:JR NZ,.bad
        LD HL,(@WDOS.LOBU+486),DE,#6141
        OR A:SBC HL,DE:JR NZ,.bad
; Claude - 2026-10-10 - begin
        LD HL,(@WDOS.LOBU+508)                  ; нули перед #55AA (драйвер, R6-4)
        LD A,H:OR L:JR NZ,.bad
; Claude - 2026-10-10 - end
        LD HL,(@WDOS.LOBU+510),DE,#AA55
        OR A:SBC HL,DE:JR NZ,.bad
        XOR A
        RET
.bad:
        LD A,1:OR A
        RET

; Claude - 2026-10-10 - begin
; Позиционировать на сектор FSInfo, если он внутри резервной области: не 0 и
; меньше BREZS (номер — относительно начала тома). Выход: CF=0 —
; позиционировано; CF=1 — сектор вне резерва.
FILEX_FSINFO_POSITION:
        LD HL,(@WDOS.FSINF),DE,(@WDOS.FSINF+2)
        PUSH DE,HL
        LD BC,(@WDOS.ADDTOP):OR A:SBC HL,BC
        EX DE,HL
        LD BC,(@WDOS.ADDTOP+2):SBC HL,BC
        LD A,H:OR L:JR NZ,.invalid              ; DE — номер в томе
        LD A,D:OR E:JR Z,.invalid
        LD HL,(@WDOS.BREZS):OR A:SBC HL,DE
        JR C,.invalid
        JR Z,.invalid
        POP HL,DE
        CALL @WDOS.XPOZI
        OR A                                    ; CF=0
        RET
.invalid:
        POP HL,DE
        SCF
        RET

; Z — DE:HL годится подсказкой следующего свободного: кластер данных тома
; (2 ≤ n < граница) и его сектор FAT в пределах FAT. HL, DE сохраняются.
FILEX_VALIDATE_FREE_HINT:
        LD (FILEX_FS_HINT),HL
        LD (FILEX_FS_HINT+2),DE
        LD A,D:OR E:OR H:JR NZ,.minimum_ok
        LD A,L:CP 2:JR C,.bad
.minimum_ok:
        FILEX_CALL_EXTENSION ID_GET_DATA_CLUSTER_LIMIT   ; DE:HL — граница
        LD B,H:LD C,L
        LD HL,(FILEX_FS_HINT):OR A:SBC HL,BC
        LD HL,(FILEX_FS_HINT+2):SBC HL,DE      ; CF — подсказка ниже границы
        JR NC,.bad
        LD HL,(FILEX_FS_HINT)
        LD DE,(FILEX_FS_HINT+2)
        CALL @WDOS.DEL128                       ; DE:HL — сектор FAT
        FILEX_CALL_EXTENSION ID_FAT_SECTOR_IN_RANGE      ; CF — внутри FAT
        JR NC,.bad
        LD HL,(FILEX_FS_HINT)
        LD DE,(FILEX_FS_HINT+2)
        XOR A
        RET
.bad:
        LD HL,(FILEX_FS_HINT)
        LD DE,(FILEX_FS_HINT+2)
        LD A,1:OR A
        RET

; Число свободных кластеров по FAT (FILEX_FLAG_REFRESH_FREE): нули среди
; записей 2..граница−1 (старшая тетрада не считается). Выход: Z —
; FILEX_FS_FREE_TEMP; NZ, A — MEDIA или FAT (граница тома не задана).
FILEX_COUNT_FREE:
        LD HL,0
        LD (FILEX_FS_FREE_TEMP),HL
        LD (FILEX_FS_FREE_TEMP+2),HL
        LD (FILEX_FAT_SECTOR),HL
        LD (FILEX_FAT_SECTOR+2),HL
        FILEX_CALL_EXTENSION ID_GET_DATA_CLUSTER_LIMIT
        LD (FILEX_FAT_END),HL
        LD (FILEX_FAT_END+2),DE
        LD A,D:OR E:OR H:JR NZ,.sector
        LD A,L:CP 3:JR NC,.sector
        LD A,FILEX_STATUS_FAT:OR A              ; кластеров данных нет
        RET
.sector:
        LD HL,(FILEX_FAT_END)
        LD DE,(FILEX_FAT_END+2)
        LD A,D:OR E:OR H:OR L:RET Z             ; все записи пройдены
        LD HL,(FILEX_FAT_SECTOR)
        LD DE,(FILEX_FAT_SECTOR+2)
        FILEX_CALL_EXTENSION ID_POSITION_FAT_READ
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        RET NZ
        LD HL,(FILEX_FAT_END):LD BC,128:OR A:SBC HL,BC
        EX DE,HL
        LD HL,(FILEX_FAT_END+2):LD BC,0:SBC HL,BC
        LD B,128
        JR NC,.left_ready
        LD A,(FILEX_FAT_END):LD B,A             ; последний сектор — неполный
        LD HL,0:LD D,H:LD E,L
.left_ready:
        LD (FILEX_FAT_END),DE
        LD (FILEX_FAT_END+2),HL
        LD HL,@WDOS.LOBU
        LD A,(FILEX_FAT_SECTOR+1):LD C,A
        LD A,(FILEX_FAT_SECTOR):OR C
        LD C,A
        LD A,(FILEX_FAT_SECTOR+2):OR C
        LD C,A
        LD A,(FILEX_FAT_SECTOR+3):OR C
        JR NZ,.scan
        LD L,8:DEC B:DEC B                      ; записи 0 и 1 — не кластеры
.scan:
        LD A,(HL):INC HL
        OR (HL):INC HL
        OR (HL):INC HL
        LD C,A
        LD A,(HL):INC HL
        AND #0F:OR C
        JR NZ,.used
        PUSH HL
        LD HL,(FILEX_FS_FREE_TEMP):INC HL:LD (FILEX_FS_FREE_TEMP),HL
        LD A,H:OR L
        JR NZ,.counted
        LD HL,(FILEX_FS_FREE_TEMP+2):INC HL:LD (FILEX_FS_FREE_TEMP+2),HL
.counted:
        POP HL
.used:
        DJNZ .scan
        LD HL,FILEX_FAT_SECTOR
        CALL @WDOS.INC4b
        JP .sector
; Claude - 2026-10-10 - end

; Установить поддерживаемые FAT timestamps и атрибуты последнего FENTRY.
FILEX_SET_METADATA:
        LD A,(IY+FILEX_P_FLAGS):OR A:JP NZ,FILEX_BAD_BLOCK
        CALL FILEX_LOAD_CONTEXT
        JP NZ,FILEX_FINISH
        LD L,(IY+FILEX_P_LENGTH+0)
        LD H,(IY+FILEX_P_LENGTH+1)
        LD DE,FILEX_META_SIZE
        OR A:SBC HL,DE:JP C,.bad_length
        LD BC,FILEX_META_SIZE
        LD L,(IY+FILEX_P_BUFFER+0)
        LD H,(IY+FILEX_P_BUFFER+1)
        CALL FILEX_VALIDATE_BUFFER
        JP NZ,FILEX_FINISH
        LD (FILEX_META_POINTER),HL
        LD A,(HL):CP FILEX_META_SIZE:JP NZ,.bad_block
        INC HL
        LD A,(HL)
        LD (FILEX_META_ATTR_MASK),A
        AND ~FILEX_META_ALLOWED_ATTRS:JP NZ,.bad_block
        INC HL
        LD A,(HL):LD (FILEX_META_ATTR_VALUE),A
        INC HL
        LD A,(HL):LD (FILEX_META_TIME_MASK),A
        AND ~%00000111:JP NZ,.bad_block

        LD A,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+11)
        BIT 0,A:JR Z,.read_only_ok
        LD A,(FILEX_META_ATTR_MASK):BIT 0,A:JP Z,.read_only
        LD A,(FILEX_META_ATTR_VALUE):BIT 0,A:JP NZ,.read_only
.read_only_ok:
        LD A,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+11)
        LD B,A
        LD A,(FILEX_META_ATTR_MASK)
        CPL
        AND B
        LD B,A
        LD A,(FILEX_META_ATTR_VALUE)
        LD C,A
        LD A,(FILEX_META_ATTR_MASK)
        AND C
        OR B
        LD (FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+11),A
        LD (FILEX_META_APPLIED),A

        LD HL,(FILEX_META_POINTER)
        LD DE,4
        ADD HL,DE
        LD A,(FILEX_META_TIME_MASK):BIT 0,A:JR Z,.access_time
        LD DE,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+13
        LD BC,5
        LDIR
        JR .access_mask
.access_time:
        LD DE,5:ADD HL,DE
.access_mask:
        LD A,(FILEX_META_TIME_MASK):BIT 1,A:JR Z,.write_time
        LD DE,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+18
        LD BC,2
        LDIR
        JR .write_mask
.write_time:
        INC HL:INC HL
.write_mask:
        LD A,(FILEX_META_TIME_MASK):BIT 2,A:JR Z,.stamps
        LD DE,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+22
        LD BC,4
        LDIR
; Claude - 2026-09-26 - begin
; Штамп программы, которого нет в календаре (месяц, день месяца, часы,
; минуты, секунды), на диск не пишется: вместо него — текущий по часам ядра
; (как у копии с неверной датой источника); доли секунды создания при этом —
; 0, их больше 199 — тоже 0. Структура программы не меняется.
.stamps:
        LD A,(FILEX_META_TIME_MASK):BIT 0,A:JR Z,.access_stamp
        LD HL,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+14
        LD A,1
        CALL FILEX_FIX_STAMP
        CALL FILEX_FIX_TENTH
.access_stamp:
        LD A,(FILEX_META_TIME_MASK):BIT 1,A:JR Z,.write_stamp
        LD HL,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+18
        LD A,1
        CALL FILEX_FIX_DATE
.write_stamp:
        LD A,(FILEX_META_TIME_MASK):BIT 2,A:JR Z,.commit
        LD HL,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+22
        LD A,1
        CALL FILEX_FIX_STAMP
; Claude - 2026-09-26 - end
.commit:
        CALL FILEX_COMMIT_CONTEXT_ENTRY
        JP NZ,FILEX_FINISH
        LD HL,(FILEX_META_POINTER)
        LD DE,FILEX_META_O_APPLIED_ATTR
        ADD HL,DE
        LD A,(FILEX_META_APPLIED):LD (HL),A
        LD (FILEX_RESULT_FLAGS),A
        LD HL,FILEX_META_SIZE:LD (FILEX_RESULT),HL
        XOR A
        JP FILEX_FINISH
.read_only:
        LD A,FILEX_STATUS_READ_ONLY
        JP FILEX_FINISH
.bad_length:
        LD A,FILEX_STATUS_BAD_LENGTH
        JP FILEX_FINISH
.bad_block:
        LD A,FILEX_STATUS_BAD_BLOCK
        JP FILEX_FINISH

; Claude - 2026-09-26 - begin
; GET_METADATA (операция 8): атрибут и времена последнего FENTRY — та же
; 16-байтовая структура, что у SET_METADATA, но ничего не пишется ни в запись,
; ни на диск. Контекст сверяется с диском, как у прочих операций (FENTRY
; другого объекта или изменение записи — ENTRY_CHANGED). Выход в buffer (не
; короче FILEX_META_SIZE): SIZE=16; ATTR_MASK=FILEX_META_ALLOWED_ATTRS и
; TIME_MASK=%111 — чтобы структуру можно было без правки отдать в
; SET_METADATA; ATTR_VALUE и APPLIED_ATTR — атрибут записи (+11); времена —
; поля записи: создание +13/+14/+16, доступ +18, изменение +22/+24. Штамп,
; которого нет в календаре (месяц, день месяца, часы, минуты, секунды),
; программа получает как 2026-01-01 00:00 (доли секунды создания тогда — 0,
; их больше 199 — тоже 0); сама запись не меняется.
; result_count=16, result_flags — атрибут.
FILEX_GET_METADATA:
        LD A,(IY+FILEX_P_FLAGS):OR A:JP NZ,FILEX_BAD_BLOCK
        CALL FILEX_LOAD_CONTEXT
        JP NZ,FILEX_FINISH
        LD L,(IY+FILEX_P_LENGTH+0)
        LD H,(IY+FILEX_P_LENGTH+1)
        LD DE,FILEX_META_SIZE
        OR A:SBC HL,DE:JR C,.bad_length
        LD BC,FILEX_META_SIZE
        LD L,(IY+FILEX_P_BUFFER+0)
        LD H,(IY+FILEX_P_BUFFER+1)
        CALL FILEX_VALIDATE_BUFFER
        JP NZ,FILEX_FINISH
        LD (FILEX_META_POINTER),HL
        EX DE,HL                                ; DE — структура
        LD A,FILEX_META_SIZE:LD (DE),A:INC DE   ; +0 SIZE
        LD A,FILEX_META_ALLOWED_ATTRS
        LD (DE),A:INC DE                        ; +1 ATTR_MASK
        LD A,(FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+11)
        LD (FILEX_RESULT_FLAGS),A
        LD (DE),A:INC DE                        ; +2 ATTR_VALUE
        LD A,%00000111:LD (DE),A:INC DE         ; +3 TIME_MASK
        LD HL,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+13
        LD BC,5:LDIR                            ; +4..+8 создание: доли, время, дата
        LD HL,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+18
        LD C,2:LDIR                             ; +9..+10 дата доступа
        LD HL,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+22
        LD C,4:LDIR                             ; +11..+14 изменение: время, дата
        LD A,(FILEX_RESULT_FLAGS):LD (DE),A     ; +15 APPLIED_ATTR
        LD HL,(FILEX_META_POINTER)
        LD BC,5:ADD HL,BC                       ; +5 время создания
        XOR A
        CALL FILEX_FIX_STAMP
        CALL FILEX_FIX_TENTH                    ; +4
        LD BC,4:ADD HL,BC                       ; +9 дата доступа
        XOR A
        CALL FILEX_FIX_DATE
        INC HL:INC HL                           ; +11 изменение
        XOR A
        CALL FILEX_FIX_STAMP
        LD HL,FILEX_META_SIZE:LD (FILEX_RESULT),HL
        XOR A
        JP FILEX_FINISH
.bad_length:
        LD A,FILEX_STATUS_BAD_LENGTH
        JP FILEX_FINISH

; Штамп FAT на месте: HL — время, за ним дата. Штампа нет в календаре
; (CHECK_STAMP расширения: месяц, день месяца, часы, минуты, секунды) — вместо
; него при A=0 2026-01-01 00:00 (так штамп с носителя отдаётся программе), при
; A≠0 — текущий штамп часов ядра (так штамп программы пишется на диск).
; Выход: HL сохраняется; Z — штамп прежний, NZ — заменён. Портит A, BC, DE.
FILEX_FIX_STAMP:
        LD (FILEX_STAMP_MODE),A
        PUSH HL
        LD C,(HL):INC HL:LD B,(HL):INC HL
        LD E,(HL):INC HL:LD D,(HL)
        LD H,B:LD L,C                           ; HL — время, DE — дата
        FILEX_CALL_EXTENSION ID_CHECK_STAMP     ; нет: CF, HL=0, DE — 2026-01-01
        JR NC,.kept
        LD A,(FILEX_STAMP_MODE):OR A
        JR Z,.store
        FILEX_CALL_EXTENSION ID_CLOCK_NOW
.store:
        LD B,H:LD C,L
        POP HL
        LD (HL),C:INC HL:LD (HL),B:INC HL
        LD (HL),E:INC HL:LD (HL),D
        DEC HL:DEC HL:DEC HL
        OR 1                                    ; NZ — заменён
        RET
.kept:
        POP HL
        XOR A                                   ; Z — прежний
        RET

; Дата FAT на месте (дата доступа): HL — дата; A и выход — как у
; FILEX_FIX_STAMP. Время для проверки — 00:00:00, оно в календаре есть.
FILEX_FIX_DATE:
        LD (FILEX_STAMP_MODE),A
        PUSH HL
        LD E,(HL):INC HL:LD D,(HL)
        LD HL,0
        FILEX_CALL_EXTENSION ID_CHECK_STAMP
        JR NC,FILEX_FIX_STAMP.kept
        LD A,(FILEX_STAMP_MODE):OR A
        JR Z,.store
        FILEX_CALL_EXTENSION ID_CLOCK_NOW
.store:
        POP HL
        LD (HL),E:INC HL:LD (HL),D:DEC HL
        OR 1
        RET

; Доли секунды создания — байт перед временем создания (HL): после замены
; штампа (NZ от FILEX_FIX_STAMP) или если их больше 199 (больше 1,99 с не
; бывает) — 0. HL сохраняется.
FILEX_FIX_TENTH:
        DEC HL
        JR NZ,.zero
        LD A,(HL):CP 200:JR C,.done
.zero:
        LD (HL),0
.done:
        INC HL
        RET
; Claude - 2026-09-26 - end

; Рабочее состояние одной сериализованной операции.
FILEX_RESULT:               DS 4
FILEX_RESULT_FLAGS:         DS 1
FILEX_VALIDATE_START:       DS 2
FILEX_VALIDATE_END:         DS 2
FILEX_CONTEXT:              DS FILEX_CONTEXT_SIZE
FILEX_DIRECTORY_SLOT:       DS 2
FILEX_FILE_SIZE:            DS 4
FILEX_ORIGINAL_SIZE:        DS 4
FILEX_TARGET_SIZE:          DS 4
FILEX_GROW_REMAINING:       DS 4
FILEX_WRITE_END:            DS 4
FILEX_REQUIRED_CLUSTERS:    DS 4
FILEX_SCAN_CLUSTER:         DS 4
FILEX_SCAN_LIMIT:           DS 4
FILEX_SCAN_START:           DS 4
FILEX_SCAN_CURSOR:          DS 4
FILEX_SCAN_WRAPPED:         DS 1
FILEX_WRITE_TAIL_COUNT:     DS 2
FILEX_ABSOLUTE_OFFSET:      DS 4
FILEX_AVAILABLE:            DS 4
FILEX_FIRST_CLUSTER:        DS 4
FILEX_CURRENT_CLUSTER:      DS 4
FILEX_CLUSTER_SKIP:         DS 4
FILEX_CURRENT_LBA:          DS 4
FILEX_CURRENT_SECTOR:       DS 1
FILEX_BYTE_OFFSET:          DS 2
FILEX_BUFFER_POINTER:       DS 2
FILEX_REQUESTED:            DS 2
FILEX_REMAINING:            DS 2
FILEX_CHUNK:                DS 2
FILEX_PARTIAL_EOF:          DS 1
FILEX_KEEP_CLUSTER:         DS 4
FILEX_TAIL_HEAD:            DS 4
FILEX_TAIL_LBA:             DS 4
FILEX_TAIL_PRESENT:         DS 1
FILEX_SAVED_STATUS:         DS 1
; Claude - 2026-10-10 - begin
FILEX_TAIL_START:           DS 2                ; первый байт хвоста сектора; 512 — нет
FILEX_RETRY_LEFT:           DS 1
FILEX_RETRY_STEP:           DS 2
FILEX_KILL_LBA:             DS 4
FILEX_KILL_OFFSET:          DS 2
FILEX_KILL_LEFT:            DS 1
FILEX_CHAIN_READ:           DS 1
FILEX_CHAIN_LAST:           DS 4
FILEX_CHAIN_OTHER:          DS 4
FILEX_CHAIN_TORTOISE:       DS 4
FILEX_CHAIN_POWER:          DS 4                ; FILEX_CHAIN_LAM — сразу за ним
FILEX_CHAIN_LAM:            DS 4
FILEX_CHAIN_CACHE_VALID:    DS 1
FILEX_CHAIN_CACHE:          DS FILEX_CONTEXT_SIZE
; Claude - 2026-10-10 - end
; Claude - 2026-10-11 - begin
FILEX_POS_KEY_SIZE          EQU 14              ; поколение FAT, LBA и смещение записи, первый кластер
FILEX_POS_VALID:            DS 1
FILEX_POS_NOW:              DS FILEX_POS_KEY_SIZE
FILEX_POS_KEY:              DS FILEX_POS_KEY_SIZE
FILEX_POS_TARGET:           DS 4
FILEX_POS_INDEX:            DS 4
FILEX_POS_CLUSTER:          DS 4
; Claude - 2026-10-11 - end
FILEX_FS_DESTINATION:       DS 2
FILEX_FS_FAT_COUNT:         DS 1
FILEX_FS_FAT_SECTORS:       DS 4
FILEX_FS_TOTAL_SECTORS:     DS 4
FILEX_FS_FAT_AREA:          DS 4
FILEX_FS_DATA_SECTORS:      DS 4
FILEX_FS_TOTAL_CLUSTERS:    DS 4
FILEX_FS_FREE_TEMP:         DS 4
FILEX_FS_HINT:              DS 4                ; Claude - 2026-10-10
FILEX_FS_OUTPUT:            DS FILEX_FS_SIZE
FILEX_FAT_BUFFER:           DS 2
FILEX_FAT_SECTOR:           DS 4
FILEX_FAT_END:              DS 4
FILEX_FAT_COUNT:            DS 1
FILEX_META_POINTER:         DS 2
FILEX_META_ATTR_MASK:       DS 1
FILEX_META_ATTR_VALUE:      DS 1
FILEX_META_TIME_MASK:       DS 1
FILEX_META_APPLIED:         DS 1
FILEX_STAMP_MODE:           DS 1
FILEX_SOURCE_QUERY:         DS 2
FILEX_DEST_QUERY:           DS 2
FILEX_SOURCE_DIR:           DS 4
FILEX_DEST_DIR:             DS 4
FILEX_SAVED_ACTIVE_DIR:     DS 4
FILEX_SOURCE_CONTEXT:       DS FILEX_CONTEXT_SIZE
FILEX_DEST_CONTEXT:         DS FILEX_CONTEXT_SIZE
FILEX_OLD_DEST_CLUSTER:     DS 4
FILEX_DOTDOT_CLUSTER:       DS 4
FILEX_DOTDOT_LBA:           DS 4
FILEX_DOTDOT_OLD_PARENT:    DS 4
FILEX_DOTDOT_CHANGED:       DS 1
FILEX_ANCESTRY_CURRENT:     DS 4
FILEX_ANCESTRY_PARENT:      DS 4
FILEX_ANCESTRY_LIMIT:       DS 2
