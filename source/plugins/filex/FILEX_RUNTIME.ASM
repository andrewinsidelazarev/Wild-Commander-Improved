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
        JP FILEX_READ_FAT

FILEX_QUERY_CAPS:
        LD A,(IY+FILEX_P_FLAGS):OR A:JP NZ,FILEX_BAD_BLOCK
        LD A,FILEX_CAP_READ_AT|FILEX_CAP_WRITE_AT|FILEX_CAP_SET_EOF32|FILEX_CAP_GET_FS_INFO|FILEX_CAP_MOVE_RENAME|FILEX_CAP_SET_METADATA|FILEX_CAP_MOVE_CURRENT_DIR|FILEX_CAP_READ_FAT
        LD (FILEX_RESULT),A
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
        JR FILEX_VERIFY_CONTEXT
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
        CALL FILEX_CLASSIFY_LINK
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

        LD HL,(FILEX_FIRST_CLUSTER)
        LD DE,(FILEX_FIRST_CLUSTER+2)
        CALL FILEX_CLASSIFY_LINK
        JR C,.fat_error
        JR Z,.fat_error
        LD (FILEX_CURRENT_CLUSTER),HL
        LD (FILEX_CURRENT_CLUSTER+2),DE

.walk:
        LD HL,(FILEX_CLUSTER_SKIP)
        LD DE,(FILEX_CLUSTER_SKIP+2)
        LD A,D:OR E:OR H:OR L:JR Z,.ready
        CALL FILEX_NEXT_CLUSTER
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
        XOR A
        RET
.fat_error:
        LD A,FILEX_STATUS_FAT
        OR A
        RET

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
        RET NZ
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
        JR C,.scan_failed
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
        LD A,H:CP #FF:JR NZ,.count_ready
        LD HL,(FILEX_REQUIRED_CLUSTERS+2)
        DEC HL
        LD (FILEX_REQUIRED_CLUSTERS+2),HL
.count_ready:
        LD HL,(FILEX_REQUIRED_CLUSTERS),DE,(FILEX_REQUIRED_CLUSTERS+2)
        LD A,D:OR E:OR H:OR L:JR Z,.ready
        FILEX_CALL_EXTENSION ID_SAVE_NEXT_FREE_HINT
        JR .scan
.wrap_data:
        LD A,(FILEX_SCAN_WRAPPED):OR A:JR NZ,.no_space
        INC A:LD (FILEX_SCAN_WRAPPED),A
        LD HL,2:LD (@WDOS.FSTFRC),HL
        LD HL,0:LD (@WDOS.FSTFRC+2),HL
        JR .scan
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

; Усечение публикует меньший размер до отсоединения хвоста. Поэтому сбой FAT
; после commit не оставляет запись, указывающую за короткую цепочку: максимум
; остаётся лишняя, но уже недоступная цепочка и код COMMITTED_CLEANUP.
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
        LD (FILEX_TAIL_ZEROED),A
        LD (FILEX_TAIL_PRESENT),A
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
        LD A,H:CP #FF:JR NZ,.last_offset_ready
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
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        RET NZ
        LD HL,@WDOS.LOBU
        LD DE,FILEX_SECTOR_BACKUP
        LD BC,512
        LDIR

        LD HL,(FILEX_BYTE_OFFSET)
        INC HL
        LD DE,512
        OR A:SBC HL,DE:JR Z,.tail_zero_ready
        ADD HL,DE                       ; восстановить start=byte_offset+1
        EX DE,HL
        LD HL,512
        OR A:SBC HL,DE
        LD B,H:LD C,L
        LD HL,@WDOS.LOBU
        ADD HL,DE
.zero_tail_loop:
        LD (HL),0
        INC HL
        DEC BC
        LD A,B:OR C:JR NZ,.zero_tail_loop
        CALL FILEX_REPOSITION_CURRENT
        LD HL,@WDOS.LOBU
        CALL FILEX_WRITE_ONE
        RET NZ
        LD A,1:LD (FILEX_TAIL_ZEROED),A
.tail_zero_ready:
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
        JP NZ,.restore_tail_before_return
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
        CALL FILEX_COMMIT_CONTEXT_ENTRY
        JR NZ,.restore_tail_before_return
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
.success:
        XOR A
        RET

.restore_tail_before_return:
        LD (FILEX_SAVED_STATUS),A
        LD A,(FILEX_TAIL_ZEROED):OR A:JR Z,.return_saved
        LD HL,FILEX_SECTOR_BACKUP
        LD DE,@WDOS.LOBU
        LD BC,512
        LDIR
        LD HL,(FILEX_TAIL_LBA)
        LD DE,(FILEX_TAIL_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU
        CALL FILEX_WRITE_ONE
        JR NZ,.rollback_error
.return_saved:
        LD A,(FILEX_SAVED_STATUS)
        OR A
        RET
.rollback_error:
        LD A,FILEX_STATUS_ROLLBACK
        OR A
        RET
.fat_lookup_failed:
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:RET NZ
.fat_error:
        LD A,FILEX_STATUS_FAT
        OR A
        RET
.committed_cleanup:
        LD A,FILEX_STATUS_COMMITTED_CLEANUP
        OR A
        RET

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
        PUSH AF
        CALL FILEX_CLEAR_RESULT
        POP AF
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
        LD A,H:OR L:JR Z,.success
        LD (FILEX_REMAINING),HL
        CALL FILEX_APPEND_REMAINING
        JP NZ,FILEX_FINISH

.success:
        XOR A
        JP FILEX_FINISH
.overflow:
        LD A,FILEX_STATUS_SIZE_OVERFLOW
        JP FILEX_FINISH
.bad_length:
        LD A,FILEX_STATUS_BAD_LENGTH
        JP FILEX_FINISH

FILEX_CLEAR_RESULT:
        XOR A
        LD (FILEX_RESULT+0),A
        LD (FILEX_RESULT+1),A
        LD (FILEX_RESULT+2),A
        LD (FILEX_RESULT+3),A
        RET

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

; Проверить границы и нулевой терминатор запроса [#00/#10, имя, 0].
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
; лишь затем удалить старую ссылку. Любая ранняя ошибка удаляет новую ссылку.
FILEX_MOVE_CREATE:
        CALL FILEX_CREATE_DESTINATION_LINK
        RET NZ
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
        LD (FILEX_SAVED_STATUS),A
        CALL FILEX_RESTORE_DOTDOT
        CALL FILEX_DELETE_DESTINATION_LINK
        JR NZ,.rollback_error
        LD A,(FILEX_SAVED_STATUS):OR A:RET
.rollback_new:
        LD (FILEX_SAVED_STATUS),A
        CALL FILEX_DELETE_DESTINATION_LINK
        JR NZ,.rollback_error
        LD A,(FILEX_SAVED_STATUS):OR A:RET
.rollback_error:
        LD A,FILEX_STATUS_ROLLBACK:OR A:RET
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
        LD A,B:CP 16
        LD A,FILEX_STATUS_NO_SPACE:RET Z
        LD A,FILEX_STATUS_INTERNAL:OR A:RET

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
FILEX_DELETE_SOURCE_ENTRY:
        CALL FILEX_SET_SOURCE_DIRECTORY
        LD HL,(FILEX_SOURCE_QUERY)
        XOR A:LD (@WDOS.ABT),A
        CALL @WDOS.SRHDRN
        JR Z,.not_found
        FILEX_CALL_EXTENSION ID_DELETE_ENTRY_WITH_LFN
        RET Z
        CALL FILEX_SET_SOURCE_DIRECTORY
        LD HL,(FILEX_SOURCE_QUERY)
        XOR A:LD (@WDOS.ABT),A
        CALL @WDOS.SRHDRN
        JR Z,.ambiguous_commit
        LD A,FILEX_STATUS_MEDIA:OR A:RET
.not_found:
        LD A,FILEX_STATUS_ENTRY_CHANGED:OR A:RET
.ambiguous_commit:
        LD A,FILEX_STATUS_COMMITTED_CLEANUP:OR A:RET

FILEX_DELETE_DESTINATION_LINK:
        CALL FILEX_SET_DEST_DIRECTORY
        LD HL,(FILEX_DEST_QUERY)
        XOR A:LD (@WDOS.ABT),A
        CALL @WDOS.SRHDRN
        JR Z,.gone
        FILEX_CALL_EXTENSION ID_DELETE_ENTRY_WITH_LFN
        RET
.gone:
        LD A,(@WDOS.ABT):OR A
        LD A,FILEX_STATUS_MEDIA:RET NZ
        XOR A
        RET

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
.replace_ready:
        CALL FILEX_SAVE_OLD_DEST_CLUSTER
        CALL FILEX_COPY_DEST_TO_CURRENT
        CALL FILEX_VERIFY_CONTEXT
        RET NZ
        CALL FILEX_PATCH_CURRENT_FROM_SOURCE
        CALL FILEX_COMMIT_CONTEXT_ENTRY
        RET NZ
        CALL FILEX_UPDATE_DOTDOT_IF_NEEDED
        JR NZ,.restore_destination
        CALL FILEX_DELETE_SOURCE_ENTRY
        JR Z,.committed
        CP FILEX_STATUS_COMMITTED_CLEANUP:JR Z,.committed_cleanup
        LD (FILEX_SAVED_STATUS),A
        CALL FILEX_RESTORE_DOTDOT
        CALL FILEX_RESTORE_DESTINATION_ENTRY
        JR NZ,.rollback_error
        LD A,(FILEX_SAVED_STATUS):OR A:RET
.restore_destination:
        LD (FILEX_SAVED_STATUS),A
        CALL FILEX_RESTORE_DESTINATION_ENTRY
        JR NZ,.rollback_error
        LD A,(FILEX_SAVED_STATUS):OR A:RET
.rollback_error:
        LD A,FILEX_STATUS_ROLLBACK:OR A:RET
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

FILEX_RESTORE_DESTINATION_ENTRY:
        ; FILEX_CONTEXT описывает ожидаемую новую запись на диске.
        CALL FILEX_VERIFY_CONTEXT
        RET NZ
        LD HL,FILEX_DEST_CONTEXT+FILEX_CONTEXT_ENTRY
        LD DE,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY
        LD BC,32
        LDIR
        JP FILEX_COMMIT_CONTEXT_ENTRY

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
        LD HL,@WDOS.LOBU
        CALL FILEX_WRITE_ONE
        RET NZ
        LD A,1:LD (FILEX_DOTDOT_CHANGED),A
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
        LD HL,(@WDOS.FSINF)
        LD DE,(@WDOS.FSINF+2)
        CALL @WDOS.XPOZI
        LD HL,@WDOS.LOBU
        CALL FILEX_READ_ONE
        JP NZ,FILEX_FINISH
        CALL FILEX_VALIDATE_FSINFO
        JR NZ,.copy_output
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
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_NEXT_FREE),HL
        LD (FILEX_FS_OUTPUT+FILEX_FS_O_NEXT_FREE+2),DE

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
        LD HL,(@WDOS.LOBU+510),DE,#AA55
        OR A:SBC HL,DE:JR NZ,.bad
        XOR A
        RET
.bad:
        LD A,1:OR A
        RET

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
        LD A,(FILEX_META_ATTR_MASK):BIT 0,A:JR Z,.read_only
        LD A,(FILEX_META_ATTR_VALUE):BIT 0,A:JR NZ,.read_only
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
        LD A,(FILEX_META_TIME_MASK):BIT 2,A:JR Z,.commit
        LD DE,FILEX_CONTEXT+FILEX_CONTEXT_ENTRY+22
        LD BC,4
        LDIR
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
FILEX_TAIL_ZEROED:          DS 1
FILEX_SAVED_STATUS:         DS 1
FILEX_SECTOR_BACKUP:        DS 512
FILEX_FS_DESTINATION:       DS 2
FILEX_FS_FAT_COUNT:         DS 1
FILEX_FS_FAT_SECTORS:       DS 4
FILEX_FS_TOTAL_SECTORS:     DS 4
FILEX_FS_FAT_AREA:          DS 4
FILEX_FS_DATA_SECTORS:      DS 4
FILEX_FS_TOTAL_CLUSTERS:    DS 4
FILEX_FS_FREE_TEMP:         DS 4
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
