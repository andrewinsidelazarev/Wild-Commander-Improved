; Codex - 2026-07-16 - begin
; Дополнительные исправления WildDOSFileCore.
;
; Этот файл физически хранится в свободной области boot.$C перед CORE32.
; INSTALL_WILDDOS копирует его в выделенную физическую страницу #E8. Короткий
; шлюз WildDOS временно подключает эту страницу к окну #C000, поддерживает
; вложенные вызовы и восстанавливает страницу и состояние прерываний.

RUNTIME_START:
; Codex - 2026-07-17 - begin
        INCLUDE "CORE32_EXT_API.ASM"
; Codex - 2026-07-17 - end

; Каждая внешняя точка занимает ровно JP. Номер после CALL шлюза выбирает
; соответствующую строку без изменения входных регистров функции.
ENTRY_TABLE:
        JP STREAM_WITH_HANDLER
        JP READ_SECTORS
        JP STREAM_IO_ERROR
        JP INIT_FREE_SCAN
        JP CHECK_FREE_SCAN_LIMIT
        JP NEXT_FREE_FAT_SECTOR
        JP FAT_SECTOR_IN_RANGE
        JP POSITION_FAT_READ
        JP CLASSIFY_FAT_LINK
        JP FAT_LINK_ERROR
        JP SAVE_FAT_SECTOR
        JP REFINE_NAME_CLASSIFICATION
        JP IS_EOC_BEFORE_HL
        JP RESET_DIR_HISTORY
        JP SAVE_PREVIOUS_DIR_LBA
        JP PRESERVE_OLDER_DIR_SECTOR
        JP BEGIN_LFN_COMPARE
        JP COMPARE_LFN_CHAR
        JP DELETE_ENTRY_WITH_LFN
        JP ALLOCATE_FILE
        JP RFRH_SAFE
        JP RECORD_FAT_LINK_ERROR
        JP LOAD_FAT_CONFIG
; Codex - 2026-07-16 - begin
        JP VALIDATE_NAME
        JP MAP_OLDER_LFN_POINTER
        JP UNPACK_DRIVER
        JP ZC_WAIT_READY
        JP ZC_WAIT_TOKEN
        JP ZC_WAIT_BUSY
        JP ZC_DATA_RESPONSE
        JP ZC_DMA_WAIT
        JP ZC_START_READ
        JP ZC_READ_BLOCK
        JP ZC_WRITE_READY
        JP ZC_START_WRITE
        JP ZC_CHECK_TOKEN
        JP ZERO_CLUSTER_TAIL
; Codex - 2026-07-17 - begin
        JP COPY_ENTRY_AND_CAPTURE
        JP APPEND_BYTES
        JP COPY_TO_ENTRY
; Codex - 2026-07-17 - end
; Codex - 2026-07-16 - end
ENTRY_TABLE_END:
        ASSERT ENTRY_TABLE_END-ENTRY_TABLE == ID_COUNT*3, нарушена таблица шлюза

; Продолжение фиксированного шлюза после подключения страницы #E8.
; IX указывает на сохранённый стековый кадр, L содержит номер функции.
; Кадр: HL'/DE'/BC'/AF', IX, HL/DE/BC/AF, адрес возврата.
GATE_CONTINUE:
        LD H,0
        LD C,L
        LD B,H
        ADD HL,HL
        ADD HL,BC
        LD BC,ENTRY_TABLE
        ADD HL,BC
        LD BC,@WDOS.EXTENSION_GATE_AFTER
        PUSH BC
        PUSH HL

        EXX
        LD L,(IX+0)
        LD H,(IX+1)
        LD E,(IX+2)
        LD D,(IX+3)
        LD C,(IX+4)
        LD B,(IX+5)
        EXX

        LD L,(IX+6)
        LD H,(IX+7)
        PUSH HL
        EX AF,AF'
        POP AF
        EX AF,AF'

        LD C,(IX+14)
        LD B,(IX+15)
        LD E,(IX+12)
        LD D,(IX+13)

        LD L,(IX+16)
        LD H,(IX+17)
        PUSH HL
        POP AF

        LD L,(IX+10)
        LD H,(IX+11)
        PUSH HL
        LD L,(IX+8)
        LD H,(IX+9)
        PUSH HL
        POP IX
        POP HL
        RET

; Вызвать общий потоковый код с временным обработчиком DE и восстановить именно
; прежний адрес NW0, а не безусловно RDDSE. Флаги/A/HL результата LOAD512
; сохраняются.
STREAM_WITH_HANDLER:
        LD BC,(@WDOS.NW0+1)
        PUSH BC
        LD (@WDOS.NW0+1),DE
        CALL @WDOS.LOAD512
        POP DE
        LD (@WDOS.NW0+1),DE
        RET

; Codex - 2026-07-17 - begin
; Скопировать текущую ENTRY вызывающему коду и одновременно сохранить точное
; положение найденной SFN-записи. После XFENTRY указатель записи находится в
; альтернативном BC, а LLHL содержит абсолютный LBA её секторного буфера.
; APPEND дополнительно сверяет все 32 байта на диске перед каждой фиксацией.
COPY_ENTRY_AND_CAPTURE:
; Codex - 2026-07-17 - begin
        ; Исторический TENTRY сохранял Z/S/C входного AF через LDIR. FENTRY
        ; использует этот Z как результат поиска, поэтому служебная проверка
        ; положения записи не должна подменять его собственными флагами.
        PUSH AF
; Codex - 2026-07-17 - end
        PUSH DE
        EXX
        LD (APPEND_FOUND_POINTER),BC
        EXX
        LD HL,(@WDOS.LLHL)
        LD (APPEND_DIRECTORY_LBA),HL
        LD HL,(@WDOS.LLHL+2)
        LD (APPEND_DIRECTORY_LBA+2),HL

        XOR A
        LD (APPEND_VALID),A
        LD (APPEND_READY),A
        LD BC,(APPEND_FOUND_POINTER)
        LD A,C:AND #1F:JR NZ,.copy_saved_entry
        LD A,B:SUB high @WDOS.LOBU:CP 4:JR NC,.copy_saved_entry
        AND 1
        LD H,A,L,C
        LD (APPEND_DIRECTORY_OFFSET),HL
        LD A,1
        LD (APPEND_VALID),A

.copy_saved_entry:
        LD HL,@WDOS.ENTRY,DE,APPEND_ENTRY,BC,32
        LDIR
        POP DE
        LD HL,@WDOS.ENTRY,BC,32
; Codex - 2026-07-17 - begin
        POP AF
; Codex - 2026-07-17 - end
        LDIR
        RET

; Совместимый с прежним GENTRY перенос 32 байт из HL в рабочую ENTRY.
COPY_TO_ENTRY:
        LD DE,@WDOS.ENTRY,BC,32
        LDIR
        RET

APPEND_ERROR_CONTEXT       EQU #20
APPEND_ERROR_BUFFER        EQU #21
APPEND_ERROR_LENGTH        EQU #22
APPEND_ERROR_ENTRY_CHANGED EQU #23
APPEND_ERROR_SIZE_OVERFLOW EQU #24
APPEND_ERROR_BAD_CHAIN     EQU #25
APPEND_ERROR_IS_DIRECTORY  EQU #26
APPEND_ERROR_INTERNAL      EQU #27
APPEND_ERROR_ROLLBACK      EQU #2A

; Дописать в найденный файл от 1 до 512 байт. Нулевой BC является успешной
; пустой операцией. Данные должны полностью лежать в #4000..#BFFF: окно #0000
; занято файловой страницей, а #C000 временно содержит это расширение.
; Контекст создаётся штатным XFENTRY/TENTRY и кэширует положение EOF, поэтому
; последовательные FTP-блоки не обходят FAT-цепочку заново.
APPEND_BYTES:
        PUSH DE
        LD A,B:OR C:JR NZ,.nonempty
        XOR A
        POP DE
        RET

.nonempty:
        LD (APPEND_SOURCE),HL
        LD A,B:CP 2:JR C,.length_ok
        JP NZ,.bad_length
        LD A,C:OR A:JP NZ,.bad_length
.length_ok:
        LD A,H:CP #40:JP C,.bad_buffer
        CP #C0:JP NC,.bad_buffer
        PUSH HL
        ADD HL,BC
        JP C,.bad_buffer_pop
        LD A,H:CP #C0:JR C,.buffer_end_ok
        JP NZ,.bad_buffer_pop
        LD A,L:OR A:JP NZ,.bad_buffer_pop
.buffer_end_ok:
        POP HL

        LD A,(APPEND_VALID):OR A:JP Z,.bad_context
        LD (APPEND_REMAINING),BC
        LD A,(APPEND_READY):OR A:JR NZ,.context_ready
        CALL APPEND_PREPARE
        JP NZ,.failed_without_rollback
.context_ready:

        LD HL,APPEND_CONTEXT,DE,APPEND_WORK_CONTEXT,BC,APPEND_CONTEXT_SIZE
        LDIR
        LD HL,(APPEND_SIZE),DE,(APPEND_SIZE+2)
        LD BC,(APPEND_REMAINING)
        ADD HL,BC:JR NC,.size_ready
        INC DE
        LD A,D:OR E:JP Z,.size_overflow
.size_ready:
        LD (APPEND_WORK_SIZE),HL
        LD (APPEND_WORK_SIZE+2),DE
        XOR A
        LD (APPEND_PENDING_NEW),A
        LD (APPEND_LINKED_NEW),A

.write_loop:
        LD HL,(APPEND_REMAINING)
        LD A,H:OR L:JP Z,.commit
        LD A,(APPEND_WORK_NEEDS_CLUSTER):OR A
        CALL NZ,APPEND_ENSURE_CLUSTER
        JP NZ,.failed_with_rollback

        CALL APPEND_POSITION_SECTOR
        JP NZ,.failed_with_rollback
        LD HL,(APPEND_WORK_OFFSET)
        LD A,H:OR L:JR Z,.clear_sector
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        JP NZ,.failed_with_rollback
        JR .sector_ready
.clear_sector:
        CALL APPEND_CLEAR_SECTOR
.sector_ready:
        LD HL,512
        LD DE,(APPEND_WORK_OFFSET)
        OR A:SBC HL,DE
        EX DE,HL
        LD HL,(APPEND_REMAINING)
        PUSH HL
        OR A:SBC HL,DE
        POP HL
        JR C,.chunk_ready
        LD H,D,L,E
.chunk_ready:
        LD (APPEND_CHUNK),HL

        LD DE,@WDOS.LOBU
        LD HL,(APPEND_WORK_OFFSET)
        ADD HL,DE
        EX DE,HL
        LD HL,(APPEND_SOURCE)
        LD BC,(APPEND_CHUNK)
        LDIR
        LD (APPEND_SOURCE),HL

        CALL APPEND_POSITION_SECTOR
        JR NZ,.failed_with_rollback
        LD HL,@WDOS.LOBU,A,1
        CALL WRITE_SECTORS
        JR NZ,.failed_with_rollback

        LD HL,(APPEND_REMAINING),DE,(APPEND_CHUNK)
        OR A:SBC HL,DE
        LD (APPEND_REMAINING),HL
        LD HL,(APPEND_WORK_OFFSET)
        ADD HL,DE
        LD (APPEND_WORK_OFFSET),HL
        LD DE,512
        OR A:SBC HL,DE
        JP NZ,.write_loop
        LD (APPEND_WORK_OFFSET),HL
        LD A,(APPEND_WORK_SECTOR):INC A
        LD B,A
        LD A,(@WDOS.BSECPC):CP B
        LD A,B
        JR NZ,.store_sector
        XOR A
        LD (APPEND_WORK_SECTOR),A
        INC A
        LD (APPEND_WORK_NEEDS_CLUSTER),A
        JP .write_loop
.store_sector:
        LD (APPEND_WORK_SECTOR),A
        JP .write_loop

.commit:
        CALL APPEND_COMMIT
        JR NZ,.failed_with_rollback
        LD HL,APPEND_WORK_CONTEXT,DE,APPEND_CONTEXT,BC,APPEND_CONTEXT_SIZE
        LDIR
        XOR A
        LD (APPEND_PENDING_NEW),A
        LD (APPEND_LINKED_NEW),A
        LD HL,(APPEND_SOURCE)
        POP DE
        RET

.failed_with_rollback:
        LD (APPEND_LAST_ERROR),A
        CALL APPEND_ROLLBACK
        JR Z,.restore_original_error
        LD A,APPEND_ERROR_ROLLBACK
        JR .return_error
.restore_original_error:
        LD A,(APPEND_LAST_ERROR)
        JR .return_error

.size_overflow:
        LD A,APPEND_ERROR_SIZE_OVERFLOW
.failed_without_rollback:
.return_error:
        OR A
        LD HL,(APPEND_SOURCE)
        POP DE
        RET

.bad_buffer_pop:
        POP HL
.bad_buffer:
        LD A,APPEND_ERROR_BUFFER
        JR .return_error
.bad_length:
        LD A,APPEND_ERROR_LENGTH
        JR .return_error
.bad_context:
        LD A,APPEND_ERROR_CONTEXT
        JR .return_error

; Проверить неизменность каталожной записи и восстановить положение EOF из
; её 32-битного размера. Для первого вызова обходится только существующая
; цепочка; дальнейшие вызовы используют сохранённый текущий кластер.
APPEND_PREPARE:
        CALL APPEND_VERIFY_DIRECTORY
        RET NZ
        LD A,(APPEND_ENTRY+11):BIT 4,A
        LD A,APPEND_ERROR_IS_DIRECTORY
        RET NZ

        LD HL,(APPEND_ENTRY+28),DE,(APPEND_ENTRY+30)
        LD (APPEND_SIZE),HL
        LD (APPEND_SIZE+2),DE
        LD HL,(APPEND_ENTRY+26),DE,(APPEND_ENTRY+20)
        LD A,D:AND #0F:LD D,A
        LD (APPEND_FIRST_CLUSTER),HL
        LD (APPEND_FIRST_CLUSTER+2),DE

        LD BC,(APPEND_SIZE),DE,(APPEND_SIZE+2)
        LD A,B:OR C:OR D:OR E:JR NZ,.nonzero_size
        LD HL,(APPEND_FIRST_CLUSTER),DE,(APPEND_FIRST_CLUSTER+2)
        LD A,D:OR E:OR H:OR L:JR Z,.empty_without_cluster
        CALL CLASSIFY_FAT_LINK
        JP C,.bad_chain
        JP Z,.bad_chain
        LD (APPEND_CURRENT_CLUSTER),HL
        LD (APPEND_CURRENT_CLUSTER+2),DE
        XOR A
        LD (APPEND_SECTOR),A
        LD (APPEND_OFFSET),A
        LD (APPEND_OFFSET+1),A
        LD (APPEND_NEEDS_CLUSTER),A
        JP .ready
.empty_without_cluster:
        XOR A
        LD (APPEND_CURRENT_CLUSTER),A
        LD (APPEND_CURRENT_CLUSTER+1),A
        LD (APPEND_CURRENT_CLUSTER+2),A
        LD (APPEND_CURRENT_CLUSTER+3),A
        LD (APPEND_SECTOR),A
        LD (APPEND_OFFSET),A
        LD (APPEND_OFFSET+1),A
        INC A
        LD (APPEND_NEEDS_CLUSTER),A
        JP .ready

.nonzero_size:
        LD HL,(APPEND_FIRST_CLUSTER),DE,(APPEND_FIRST_CLUSTER+2)
        CALL CLASSIFY_FAT_LINK
        JP C,.bad_chain
        JP Z,.bad_chain
        LD (APPEND_CURRENT_CLUSTER),HL
        LD (APPEND_CURRENT_CLUSTER+2),DE

        LD HL,(APPEND_SIZE)
        LD A,H:AND 1:LD H,A
        LD (APPEND_OFFSET),HL
        LD HL,(APPEND_SIZE),DE,(APPEND_SIZE+2)
        DUP 9
        SRL D:RR E:RR H:RR L
        EDUP
        LD A,(@WDOS.BSECPC):DEC A:AND L
        LD (APPEND_SECTOR),A
        LD A,(@WDOS.BSECPC)
.divide_cluster:
        CP 1:JR Z,.cluster_index_ready
        SRL D:RR E:RR H:RR L
        SRL A
        JR .divide_cluster
.cluster_index_ready:
        XOR A
        LD (APPEND_NEEDS_CLUSTER),A
        LD A,(APPEND_OFFSET):LD B,A
        LD A,(APPEND_OFFSET+1):OR B:JR NZ,.store_skip
        LD A,(APPEND_SECTOR):OR A:JR NZ,.store_skip
        LD A,1
        LD (APPEND_NEEDS_CLUSTER),A
        DEC HL
        LD A,H:CP #FF:JR NZ,.store_skip
        DEC DE
.store_skip:
        LD (APPEND_SKIP_COUNT),HL
        LD (APPEND_SKIP_COUNT+2),DE

.walk_chain:
        LD HL,(APPEND_SKIP_COUNT),DE,(APPEND_SKIP_COUNT+2)
        LD A,D:OR E:OR H:OR L:JR Z,.ready
        LD HL,(APPEND_CURRENT_CLUSTER),DE,(APPEND_CURRENT_CLUSTER+2)
        CALL APPEND_READ_FAT_LINK
        JR C,.bad_chain
        JR Z,.bad_chain
        LD (APPEND_CURRENT_CLUSTER),HL
        LD (APPEND_CURRENT_CLUSTER+2),DE
        LD HL,(APPEND_SKIP_COUNT),DE,(APPEND_SKIP_COUNT+2)
        DEC HL
        LD A,H:CP #FF:JR NZ,.skip_stored
        DEC DE
.skip_stored:
        LD (APPEND_SKIP_COUNT),HL
        LD (APPEND_SKIP_COUNT+2),DE
        JR .walk_chain

.ready:
        LD A,1
        LD (APPEND_READY),A
        XOR A
        RET
.bad_chain:
        LD A,APPEND_ERROR_BAD_CHAIN
        OR A
        RET

; Получить следующую ссылку FAT для DE:HL. Обычный кластер возвращается как
; NZ/CF=0, EOC как Z/CF=0, повреждение как CF=1.
APPEND_READ_FAT_LINK:
        CALL @WDOS.CURIT
        RET C
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A
        EX DE,HL
        JP CLASSIFY_FAT_LINK

; При переходе через границу кластера использовать уже существующее звено,
; либо выделить ровно один новый кластер. При BC<=512 второго выделения за
; один вызов APPEND не требуется.
APPEND_ENSURE_CLUSTER:
        LD HL,(APPEND_WORK_CURRENT),DE,(APPEND_WORK_CURRENT+2)
        LD A,D:OR E:OR H:OR L:JR Z,.allocate
        LD (APPEND_PENDING_OLD_TAIL),HL
        LD (APPEND_PENDING_OLD_TAIL+2),DE
        CALL APPEND_READ_FAT_LINK
        JR C,.bad_chain
        JR Z,.allocate_with_tail
        LD (APPEND_WORK_CURRENT),HL
        LD (APPEND_WORK_CURRENT+2),DE
        XOR A
        LD (APPEND_WORK_NEEDS_CLUSTER),A
        RET
.allocate_with_tail:
        LD HL,(APPEND_PENDING_OLD_TAIL),DE,(APPEND_PENDING_OLD_TAIL+2)
        JR .allocate_common
.allocate:
        LD HL,0,DE,0
        LD (APPEND_PENDING_OLD_TAIL),HL
        LD (APPEND_PENDING_OLD_TAIL+2),DE
.allocate_common:
        LD A,(APPEND_PENDING_NEW):OR A
        LD A,APPEND_ERROR_INTERNAL
        RET NZ
        LD HL,1,DE,0
        CALL @WDOS.MKSG
        RET NZ
        LD HL,(@WDOS.FCTS),DE,(@WDOS.FCTS+2)
        LD (APPEND_NEW_CLUSTER),HL
        LD (APPEND_NEW_CLUSTER+2),DE
        LD (APPEND_WORK_CURRENT),HL
        LD (APPEND_WORK_CURRENT+2),DE
        LD A,1
        LD (APPEND_PENDING_NEW),A
        LD HL,(APPEND_WORK_FIRST),DE,(APPEND_WORK_FIRST+2)
        LD A,D:OR E:OR H:OR L:JR NZ,.first_ready
        LD HL,(APPEND_NEW_CLUSTER),DE,(APPEND_NEW_CLUSTER+2)
        LD (APPEND_WORK_FIRST),HL
        LD (APPEND_WORK_FIRST+2),DE
.first_ready:
        XOR A
        LD (APPEND_WORK_NEEDS_CLUSTER),A
        RET
.bad_chain:
        LD A,APPEND_ERROR_BAD_CHAIN
        OR A
        RET

; Позиционировать драйвер на текущий сектор рабочего EOF.
APPEND_POSITION_SECTOR:
; Codex - 2026-07-17 - begin
        ; GIPAG принимает адрес четырёхбайтового номера кластера, а не сам
        ; номер в DE:HL. Передача значения как указателя давала случайный LBA.
        LD HL,APPEND_WORK_CURRENT
; Codex - 2026-07-17 - end
        CALL @WDOS.GIPAG
        RET NZ
        LD HL,(@WDOS.LTHL),DE,(@WDOS.LTDE)
        LD A,(APPEND_WORK_SECTOR)
        ADD A,L:LD L,A:JR NC,.position
        INC H:JR NZ,.position
        INC DE
.position:
        CALL @WDOS.PROZ
        XOR A
        RET

APPEND_CLEAR_SECTOR:
        LD HL,@WDOS.LOBU,DE,@WDOS.LOBU+1,BC,511
        XOR A
        LD (HL),A
        LDIR
        RET

; Зафиксировать новую цепочку, FSInfo и лишь затем 32-битный размер каталога.
; До последней записи добавленные байты остаются за старым логическим EOF.
APPEND_COMMIT:
        LD A,(APPEND_PENDING_NEW):OR A:JR Z,.directory
        LD HL,(APPEND_PENDING_OLD_TAIL),DE,(APPEND_PENDING_OLD_TAIL+2)
        LD A,D:OR E:OR H:OR L:JR Z,.fsinfo
        CALL APPEND_LINK_NEW_CLUSTER
        RET NZ
.fsinfo:
        CALL RFRH_SAFE
        RET NZ
.directory:
        JP APPEND_UPDATE_DIRECTORY

APPEND_LINK_NEW_CLUSTER:
        LD HL,(APPEND_PENDING_OLD_TAIL),DE,(APPEND_PENDING_OLD_TAIL+2)
        CALL @WDOS.CURIT
        JR C,.bad_chain
        LD (APPEND_FAT_POINTER),HL
        LD DE,APPEND_OLD_LINK,BC,4
        LDIR
        LD HL,(APPEND_OLD_LINK),DE,(APPEND_OLD_LINK+2)
        CALL CLASSIFY_FAT_LINK
        JR C,.bad_chain
        JR NZ,.bad_chain

        LD HL,(APPEND_FAT_POINTER)
        LD DE,APPEND_NEW_CLUSTER
        LD A,(DE):LD (HL),A:INC DE,HL
        LD A,(DE):LD (HL),A:INC DE,HL
        LD A,(DE):LD (HL),A:INC DE,HL
        LD A,(HL):AND #F0:LD B,A
        LD A,(DE):AND #0F:OR B:LD (HL),A
        CALL SAVE_FAT_SECTOR
        RET NZ
        LD A,1
        LD (APPEND_LINKED_NEW),A
        XOR A
        RET
.bad_chain:
        LD A,APPEND_ERROR_BAD_CHAIN
        OR A
        RET

; Прочитать и полностью сверить исходную SFN-запись. Это защищает от записи
; размера не в тот слот после любого постороннего FENTRY или изменения каталога.
APPEND_VERIFY_DIRECTORY:
        LD HL,(APPEND_DIRECTORY_LBA),DE,(APPEND_DIRECTORY_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        RET NZ
        LD HL,@WDOS.LOBU,DE,(APPEND_DIRECTORY_OFFSET)
        ADD HL,DE
        LD (APPEND_SLOT_POINTER),HL
        LD DE,APPEND_ENTRY,BC,32
.compare:
        LD A,(DE):CP (HL):JR NZ,.changed
        INC DE,HL
        DEC BC
        LD A,B:OR C:JR NZ,.compare
        LD HL,(APPEND_SLOT_POINTER)
        XOR A
        RET
.changed:
        LD A,APPEND_ERROR_ENTRY_CHANGED
        OR A
        RET

APPEND_UPDATE_DIRECTORY:
        CALL APPEND_VERIFY_DIRECTORY
        RET NZ
        LD (APPEND_SLOT_POINTER),HL
        LD DE,20:ADD HL,DE
        LD DE,(APPEND_WORK_FIRST+2)
        LD (HL),E:INC HL:LD A,D:AND #0F:LD (HL),A
        LD HL,(APPEND_SLOT_POINTER),DE,26
        ADD HL,DE
        LD DE,(APPEND_WORK_FIRST)
        LD (HL),E:INC HL:LD (HL),D
        LD HL,(APPEND_SLOT_POINTER),DE,28
        ADD HL,DE
        LD DE,(APPEND_WORK_SIZE)
        LD (HL),E:INC HL:LD (HL),D:INC HL
        LD DE,(APPEND_WORK_SIZE+2)
        LD (HL),E:INC HL:LD (HL),D

        LD HL,(APPEND_DIRECTORY_LBA),DE,(APPEND_DIRECTORY_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL WRITE_SECTORS
        RET NZ

        LD HL,(APPEND_SLOT_POINTER),DE,APPEND_ENTRY,BC,32
        LDIR
        LD HL,APPEND_ENTRY,DE,@WDOS.ENTRY,BC,32
        LDIR
        XOR A
        RET

; При ошибке до обновления каталожной записи восстановить EOC старого хвоста
; и освободить отдельно выделенный кластер. Ошибка самого отката имеет
; отдельный код, чтобы FTP-сервер не повторял операцию вслепую.
APPEND_ROLLBACK:
        LD A,(APPEND_PENDING_NEW):OR A:RET Z
        LD A,(APPEND_LINKED_NEW):OR A:JR Z,.release_new
        LD HL,(APPEND_PENDING_OLD_TAIL),DE,(APPEND_PENDING_OLD_TAIL+2)
        CALL @WDOS.CURIT
        RET C
        EX DE,HL
        LD HL,APPEND_OLD_LINK,BC,4
        LDIR
        CALL SAVE_FAT_SECTOR
        RET NZ
.release_new:
        XOR A
        LD (@WDOS.ABT),A
        LD HL,APPEND_NEW_CLUSTER
        CALL @WDOS.DLSG
        LD A,(@WDOS.ABT):OR A:RET NZ
        CALL RFRH_SAFE
        RET NZ
        XOR A
        LD (APPEND_PENDING_NEW),A
        LD (APPEND_LINKED_NEW),A
        RET
; Codex - 2026-07-17 - end

; Вызвать драйвер чтения/записи с единым признаком результата в ABT.
; Старые драйверы ABT не меняют и считаются успешными; исправленные драйверы
; записывают туда ненулевой код ошибки. На выходе ошибка даёт NZ и CF=1.
READ_SECTORS:
        PUSH AF
        XOR A:LD (@WDOS.ABT),A
        POP AF
        CALL @WDOS.RDDSE
        JR IO_RESULT

WRITE_SECTORS:
        PUSH AF
        XOR A:LD (@WDOS.ABT),A
        POP AF
        CALL @WDOS.SDDSE

IO_RESULT:
        LD A,(@WDOS.ABT)
        OR A:RET Z
        SCF
        RET

; Записать нулевым буфером оставшиеся после первого секторы кластера.
; Вход: A — полное число секторов в кластере, HL — 512-байтовый нулевой
; буфер. LTHL:LTDE указывает на первый сектор. Каждый следующий LBA вычисляется
; отдельно; первая ошибка немедленно возвращается как NZ/CF=1.
ZERO_CLUSTER_TAIL:
        LD (ZERO_CLUSTER_BUFFER_LOAD+1),HL
ZERO_CLUSTER_TAIL_NEXT:
        DEC A
        RET Z
        PUSH AF
        LD HL,(@WDOS.LTHL),DE,(@WDOS.LTDE)
        INC HL
        LD A,H:OR L:JR NZ,.lba_ready
        INC DE
.lba_ready:
        CALL @WDOS.XPOZI
ZERO_CLUSTER_BUFFER_LOAD:
        LD HL,0
        LD A,1
        CALL WRITE_SECTORS
        POP BC
        RET NZ
        LD A,B
        JR ZERO_CLUSTER_TAIL_NEXT

; Нормализовать и классифицировать значение FAT32 в DE:HL.
; Старшие четыре служебных бита отбрасываются. Обычный кластер возвращает
; NZ/CF=0, EOC #0FFFFFF8..#0FFFFFFF — Z/CF=0, недопустимые 0, 1,
; #0FFFFFF0..#0FFFFFF7 — NZ/CF=1.
CLASSIFY_FAT_LINK:
        LD A,D:AND #0F:LD D,A
        OR E:OR H
        JR NZ,CLASSIFY_HIGH

CLASSIFY_LOW:
        LD A,L:CP 2:JR C,CLASSIFY_INVALID
        JR CLASSIFY_ORDINARY
CLASSIFY_HIGH:
        LD A,D:CP #0F:JR NZ,CLASSIFY_ORDINARY
        LD A,E:CP #FF:JR NZ,CLASSIFY_ORDINARY
        LD A,H:CP #FF:JR NZ,CLASSIFY_ORDINARY
        LD A,L:CP #F0:JR C,CLASSIFY_ORDINARY
        CP #F8:JR C,CLASSIFY_INVALID
        XOR A
        RET
CLASSIFY_ORDINARY:
; Codex - 2026-07-16 - begin
        ; Тот же A=1, NZ и сброшенный CF одним байтом короче. Освобождённый
        ; байт сохраняет точный физический размер после нормализации EOC.
        XOR A:INC A
; Codex - 2026-07-16 - end
        RET
CLASSIFY_INVALID:
        LD A,1:OR A
        SCF
        RET

; Проверить четыре байта непосредственно перед HL, не меняя указатель.
; Z означает точный маркер EOC, NZ — обычное значение или кластер.
IS_EOC_BEFORE_HL:
        PUSH HL
        DEC HL
        LD A,(HL):AND #0F:CP #0F:JR NZ,.no
        DEC HL
        LD A,(HL):CP #FF:JR NZ,.no
        DEC HL
        LD A,(HL):CP #FF:JR NZ,.no
        DEC HL
        LD A,(HL):CP #F8:JR C,.no
        POP HL
        XOR A
        RET
.no:
        POP HL
        LD A,1:OR A
        RET

; Зафиксировать повреждённую ссылку FAT и остановить текущую цепочку.
RECORD_FAT_LINK_ERROR:
        LD A,#FE
        LD (@WDOS.ABT),A
; Codex - 2026-07-16 - begin
        ; ABT хранит точный код повреждения, а EOC унифицирован с обычным
        ; концом цепочки: компактные исторические проверки ожидают #FF.
        INC A
; Codex - 2026-07-16 - end
        LD (@WDOS.EOC),A
        OR A
        RET

FAT_LINK_ERROR:
        CALL RECORD_FAT_LINK_ERROR
        SCF
        RET

; Уточнить результат штатного анализатора SN/LN. Если исходное имя содержит
; хотя бы один пробел, короткая 8.3-запись недопустима: ENTRY[0]=0 заставляет
; генератор и поисковик использовать длинное имя.
REFINE_NAME_CLASSIFICATION:
        PUSH HL
        LD HL,(@WDOS.CGDE)
        INC HL
.scan:
        LD A,(HL):OR A:JR Z,.done
        CP " ":JR Z,.force_lfn
        INC HL
        JR .scan
.force_lfn:
        XOR A:LD (@WDOS.ENTRY),A
.done:
        POP HL
        LD A,1:OR A
        RET

; Codex - 2026-07-16 - begin
; Проверить имя длиной 1..255 байт. DE запоминает позицию после последнего
; значимого символа, поэтому конечная смесь пробелов и точек удаляется целиком.
; Z означает корректное имя; NZ — пустое, длиннее 255 или содержащее
; запрещённый символ.
VALIDATE_NAME:
        LD B,255
        LD DE,0
.scan:
        LD A,(HL):OR A:JR Z,.terminated
        CALL @WDOS.ENCEN:JR Z,.bad
        CP " ":JR Z,.next
        CP ".":JR Z,.next
        LD DE,HL
        INC DE
.next:
        INC HL
        DJNZ .scan
        LD A,(HL):OR A:JR NZ,.bad
.terminated:
        LD A,D:OR E:JR Z,.bad
        XOR A
        LD (DE),A
        RET
.bad:
        JP CLASSIFY_ORDINARY
; Codex - 2026-07-16 - end

; Начать симметричное сравнение LFN: начальные пробелы пропускаются и в
; поисковом запросе, и в сохранённом UTF-16 имени. Внутренние пробелы остаются
; значимыми.
BEGIN_LFN_COMPARE:
        LD A,1:LD (LFN_LEADING),A
        RET

; Совместимый заменитель ULNP.
; CF=1 — текущий символ совпал и сравнение надо продолжить;
; CF=0,Z=1 — несовпадение; CF=0,NZ — оба имени закончились одновременно.
COMPARE_LFN_CHAR:
        LD A,(LFN_LEADING):OR A:JR Z,.normal
.skip_query_spaces:
        LD A,(DE):CP " ":JR NZ,.leading_stored
        INC DE
        JR .skip_query_spaces
.leading_stored:
        CALL @WDOS.UCS
        OR A:JR Z,.mismatch
        CP " ":JR Z,.continue
        LD C,A
        XOR A:LD (LFN_LEADING),A
        LD A,C:CALL @WDOS.ACS:LD C,A
        LD A,(DE):OR A:JR Z,.decoded_end
        INC DE
        CALL @WDOS.ACS
        CP C:JR Z,.continue
        JR .mismatch
.decoded_end:
        LD A,C:INC A:JR NZ,.mismatch
        JR .matched

.normal:
        LD A,(DE):INC DE:OR A:JR Z,.query_end
        CALL @WDOS.ACS:LD C,A
        CALL @WDOS.UCS:OR A:JR Z,.mismatch
        CALL @WDOS.ACS:CP C:JR Z,.continue
.mismatch:
        XOR A
        RET
.continue:
        SCF
        RET
.query_end:
        CALL @WDOS.UCS:INC A:JR NZ,.mismatch
.matched:
        XOR A:INC A
        RET

; MKFILE(0): корректный пустой файл имеет нулевой первый кластер и не должен
; входить в MKSG, где DEC превращает младшее слово счётчика в #FFFF.
ALLOCATE_FILE:
        LD A,D:OR E,H,L
        JP NZ,@WDOS.MKSG
        LD (@WDOS.FCTS),HL
        LD (@WDOS.FCTS+2),HL
        RET

; Загрузить параметры FAT, включая BPB_ExtFlags. FATFLAGS хранит младший байт:
; бит 7 отключает зеркалирование, младшие четыре бита задают активную FAT.
LOAD_FAT_CONFIG:
        LD A,(@WDOS.LOBU+16)
        LD (@WDOS.BFATS),A
        OR A:JR Z,.bad

        LD A,(@WDOS.LOBU+40)
        LD (@WDOS.FATFLAGS),A
        BIT 7,A:JR Z,.flags_ok
        AND #0F
        LD B,A
        LD A,(@WDOS.BFATS)
        CP B:JR Z,.bad:JR C,.bad
.flags_ok:
        LD HL,(@WDOS.LOBU+36)
        LD (@WDOS.BFTSZ),HL
        LD HL,(@WDOS.LOBU+38)
        LD (@WDOS.BFTSZ+2),HL

        LD HL,(@WDOS.LOBU+44)
        LD (@WDOS.BROOTC),HL
        LD HL,(@WDOS.LOBU+46)
        LD A,H:AND #0F:LD H,A
        LD (@WDOS.BROOTC+2),HL
        XOR A
        RET
.bad:
        LD A,1:OR A
        RET

; Позиционировать устройство на сектор DE:HL относительно начала FAT с индексом
; A. После добавления FAT size, reserved sectors и partition base вызывается
; штатный XPOZI.
POSITION_FAT_INDEX:
        OR A:JR Z,.base
.next:
        LD BC,(@WDOS.BFTSZ)
        ADD HL,BC
        EX DE,HL
        LD BC,(@WDOS.BFTSZ+2)
        ADC HL,BC
        EX DE,HL
        DEC A:JR NZ,.next
.base:
        LD BC,(@WDOS.SFAT)
        CALL @WDOS.ADD4B
        CALL @WDOS.XSPOZ
        JP @WDOS.XPOZI

; Позиционирование чтения: при отключённом зеркалировании использовать только
; активную FAT, иначе FAT0.
POSITION_FAT_READ:
        LD A,(@WDOS.FATFLAGS)
        BIT 7,A:JR Z,.fat0
        AND #0F
        JP POSITION_FAT_INDEX
.fat0:
        XOR A
        JP POSITION_FAT_INDEX

; Проверить полный 32-битный относительный сектор FAT в DE:HL.
; CF=1 означает DE:HL < BFTSZ, CF=0 — сектор находится на границе или за ней.
FAT_SECTOR_IN_RANGE:
        PUSH HL,DE
        LD BC,(@WDOS.BFTSZ)
        OR A:SBC HL,BC
        EX DE,HL
        LD BC,(@WDOS.BFTSZ+2)
        SBC HL,BC
        POP DE,HL
        RET

; Записать текущий SECBU/LSTSE в корректные копии FAT. При обычном режиме —
; во все BFATS, при BPB_ExtFlags.bit7 — только в выбранную активную FAT.
SAVE_FAT_SECTOR:
        LD A,(@WDOS.FATFLAGS)
        BIT 7,A:JR Z,.mirrored
        AND #0F
        LD HL,(@WDOS.LSTSE),DE,(@WDOS.LSTSE+2)
        CALL POSITION_FAT_INDEX
        LD HL,@WDOS.SECBU,A,1
        JP WRITE_SECTORS

.mirrored:
        LD A,(@WDOS.BFATS)
        OR A:JR Z,.failed
        LD B,A
        XOR A
.copy:
        PUSH BC,AF
        LD HL,(@WDOS.LSTSE),DE,(@WDOS.LSTSE+2)
        CALL POSITION_FAT_INDEX
        LD HL,@WDOS.SECBU,A,1
        CALL WRITE_SECTORS
        POP DE,BC
        RET NZ
        LD A,D
        INC A
        DJNZ .copy
        XOR A
        RET
.failed:
        JP CLASSIFY_ORDINARY

; Состояние полного поиска свободного кластера. DABC:DAHL хранит исходную
; подсказку, DUBA=1 означает, что поиск уже обернулся к кластеру 2.
INIT_FREE_SCAN:
        LD HL,(@WDOS.CAHL)
        LD (@WDOS.DABC),HL
        LD HL,(@WDOS.CADE)
        LD (@WDOS.DAHL),HL
        XOR A:LD (@WDOS.DUBA),A
        RET

CHECK_FREE_SCAN_LIMIT:
        LD A,(@WDOS.DUBA):OR A:RET Z
        PUSH HL
        LD HL,(@WDOS.CAHL),DE,(@WDOS.DABC)
        OR A:SBC HL,DE:JR NZ,.more
        LD HL,(@WDOS.CADE),DE,(@WDOS.DAHL)
        OR A:SBC HL,DE:JR NZ,.more
        POP HL
        SCF
        RET
.more:
        POP HL
        OR A
        RET

; Перейти к следующему сектору FAT. На конце FAT один раз продолжить с
; кластера 2; повторный конец означает реальное отсутствие свободных кластеров.
NEXT_FREE_FAT_SECTOR:
        LD HL,(@WDOS.LSTSE),DE,(@WDOS.LSTSE+2)
; Codex - 2026-07-16 - begin
        ; INC HL не меняет флаг Z, поэтому перенос нельзя определять через JR NZ.
        INC HL
        LD A,H:OR L:JR NZ,.next_sector_ready
        INC DE
.next_sector_ready:
; Codex - 2026-07-16 - end

        PUSH HL,DE
        LD BC,(@WDOS.BFTSZ)
        OR A:SBC HL,BC
        EX DE,HL
        LD BC,(@WDOS.BFTSZ+2)
        SBC HL,BC
        POP DE,HL
        JR NC,.wrap

        LD (@WDOS.LSTSE),HL,(@WDOS.LSTSE+2),DE
        CALL POSITION_FAT_READ
        LD HL,@WDOS.SECBU,A,1
        CALL READ_SECTORS
        RET NZ
        LD HL,@WDOS.SECBU
        OR A
        RET

.wrap:
        LD A,(@WDOS.DUBA):OR A:JR NZ,.full
        LD HL,(@WDOS.DAHL)
        LD A,H:OR L:JR NZ,.do_wrap
        LD HL,(@WDOS.DABC)
        LD A,H:OR A:JR NZ,.do_wrap
        LD A,L:CP 3:JR C,.full
.do_wrap:
        LD A,1:LD (@WDOS.DUBA),A
        LD HL,2:LD (@WDOS.CAHL),HL
        LD HL,0:LD (@WDOS.CADE),HL
        LD DE,0:LD HL,2
        JP @WDOS.CURIT
.full:
        SCF
        RET

; Сбросить историю секторного окна перед новым поиском по каталогу.
RESET_DIR_HISTORY:
        XOR A
        LD (DIR_OLDER_VALID),A
        RET

; Сохранить реальный LBA предыдущего секторного буфера каталога. Это позволяет
; удалить LFN даже при переходе через границу кластера, где LBA не обязаны быть
; соседними.
SAVE_PREVIOUS_DIR_LBA:
; Codex - 2026-07-16 - begin
        PUSH HL
; Codex - 2026-07-16 - end
        LD HL,(@WDOS.LLHL)
        LD (DIR_PREVIOUS_LBA),HL
        LD HL,(@WDOS.LLHL+2)
        LD (DIR_PREVIOUS_LBA+2),HL
; Codex - 2026-07-16 - begin
        POP HL
; Codex - 2026-07-16 - end
        RET

; Перед сдвигом LOBU2 -> LOBU сохранить ещё более старый сектор. Максимальное
; FAT32-LFN занимает 20 записей, поэтому SFN и весь его LFN-прогон могут
; пересечь три сектора каталога.
PRESERVE_OLDER_DIR_SECTOR:
        PUSH AF,BC,DE,HL
        LD HL,@WDOS.LOBU,DE,DIR_OLDER_BUFFER,BC,512
        LDIR
        LD HL,(DIR_PREVIOUS_LBA)
        LD (DIR_OLDER_LBA),HL
        LD HL,(DIR_PREVIOUS_LBA+2)
        LD (DIR_OLDER_LBA+2),HL
        LD A,1:LD (DIR_OLDER_VALID),A
        POP HL,DE,BC,AF
        RET

; Codex - 2026-07-16 - begin
; Продолжить обратное сравнение максимального LFN в третьем секторе. Обычные
; указатели #3200..#35FF остаются без изменений; переход ниже #3200 допустим
; только на сохранённый последний слот более старого сектора #2000..#21FF.
MAP_OLDER_LFN_POINTER:
        LD A,H:CP high @WDOS.LOBU:JR NC,.ok
        CP high @WDOS.LOBU-1:JR NZ,.bad
        LD A,(DIR_OLDER_VALID):OR A:JR Z,.bad
        LD A,H:SUB #10:LD H,A
.ok:
        OR A
        RET
.bad:
        SCF
        RET
; Codex - 2026-07-16 - end

; Пометить удалёнными SFN и весь связанный LFN-прогон. Проверяются порядковые
; номера LFN и контрольная сумма SFN; поддерживается максимальное имя в 20
; LFN-записей через текущий, предыдущий и более старый сектор.
DELETE_ENTRY_WITH_LFN:
        LD H,B,L,C
        PUSH HL
        CALL @WDOS.LNCRC
        LD (DIR_LFN_CHECKSUM),A
        POP HL
        LD (HL),#E5
        LD A,B:AND #FE
        LD (@WDOS.COUNT),A
        LD D,A
        LD A,1:LD (DIR_EXPECTED_SEQUENCE),A
        XOR A
        LD (DIR_PREVIOUS_DIRTY),A
        LD (DIR_OLDER_DIRTY),A

.current:
        LD BC,0-32:ADD HL,BC
        LD A,H:CP D:JR C,.previous
        CALL .match_lfn:JR NZ,.write
        LD (HL),#E5
        JR C,.write
        JR .current

.previous:
        LD A,D:CP high @WDOS.LOBU2:JR NZ,.write
        LD HL,@WDOS.LOBE-32
.prev_loop:
        CALL .match_lfn:JR NZ,.write
        LD (HL),#E5
        LD A,1:LD (DIR_PREVIOUS_DIRTY),A
        JR C,.write
        LD BC,0-32:ADD HL,BC
        LD A,H:CP high @WDOS.LOBU:JR NC,.prev_loop

        LD A,(DIR_OLDER_VALID):OR A:JR Z,.write
        LD HL,DIR_OLDER_BUFFER+512-32
.older_loop:
        CALL .match_lfn:JR NZ,.write
        LD (HL),#E5
        LD A,1:LD (DIR_OLDER_DIRTY),A
        JR C,.write
        LD BC,0-32:ADD HL,BC
        LD A,H:CP high DIR_OLDER_BUFFER:JR NC,.older_loop

.write:
        LD A,(DIR_OLDER_DIRTY):OR A:JR Z,.write_previous
        LD HL,(DIR_OLDER_LBA),DE,(DIR_OLDER_LBA+2)
        CALL @WDOS.PROZ
        LD HL,DIR_OLDER_BUFFER,A,1
        CALL WRITE_SECTORS
        RET NZ

.write_previous:
        LD A,(DIR_PREVIOUS_DIRTY):OR A:JR Z,.write_current
        LD HL,(DIR_PREVIOUS_LBA),DE,(DIR_PREVIOUS_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL WRITE_SECTORS
        RET NZ

.write_current:
        LD HL,(@WDOS.LLHL),DE,(@WDOS.LLHL+2)
        CALL @WDOS.PROZ
        LD A,(@WDOS.COUNT)
        LD H,A,L,0
        LD A,1
        JP WRITE_SECTORS

.match_lfn:
        PUSH HL,DE
        LD A,(HL):LD D,A
        AND #1F:LD E,A
        LD A,(DIR_EXPECTED_SEQUENCE):CP E:JR NZ,.not_lfn
        LD BC,11:ADD HL,BC
        LD A,(HL):CP #0F:JR NZ,.not_lfn
        INC HL,HL
        LD A,(DIR_LFN_CHECKSUM):CP (HL):JR NZ,.not_lfn
        LD A,(DIR_EXPECTED_SEQUENCE):INC A
        LD (DIR_EXPECTED_SEQUENCE),A
        BIT 6,D:JR NZ,.last_lfn
        POP DE,HL
        XOR A
        RET
.last_lfn:
        POP DE,HL
        XOR A
        SCF
        RET
.not_lfn:
        POP DE,HL
        LD A,1:OR A
        RET

; Безопасно обновить FSInfo: проверить три сигнатуры, пометить Free_Count как
; неизвестный и записать Next_Free (либо #FFFFFFFF для нулевой подсказки).
RFRH_SAFE:
        LD HL,(@WDOS.FSINF),DE,(@WDOS.FSINF+2)
        CALL @WDOS.XPOZI
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        RET NZ

        LD HL,(@WDOS.LOBU+0),DE,#5252
        OR A:SBC HL,DE:JR NZ,.bad
        LD HL,(@WDOS.LOBU+2),DE,#4161
        OR A:SBC HL,DE:JR NZ,.bad
        LD HL,(@WDOS.LOBU+484),DE,#7272
        OR A:SBC HL,DE:JR NZ,.bad
        LD HL,(@WDOS.LOBU+486),DE,#6141
        OR A:SBC HL,DE:JR NZ,.bad
        LD HL,(@WDOS.LOBU+508),DE,0
        OR A:SBC HL,DE:JR NZ,.bad
        LD HL,(@WDOS.LOBU+510),DE,#AA55
        OR A:SBC HL,DE:JR NZ,.bad

        LD HL,#FFFF
        LD (@WDOS.LOBU+488),HL
        LD (@WDOS.LOBU+490),HL
        LD HL,(@WDOS.FSTFRC),DE,(@WDOS.FSTFRC+2)
        LD A,D:OR E,H,L:JR NZ,.have_hint
        LD HL,#FFFF,DE,HL
.have_hint:
        LD (@WDOS.LOBU+492),HL
        LD (@WDOS.LOBU+494),DE
        LD HL,@WDOS.LOBU,A,1
        JP WRITE_SECTORS
.bad:
        LD A,1:OR A
        RET

; Общий выход потоковой операции при ошибке драйвера. Адрес/сектор потока ещё
; не продвинуты; EOC=#FF заставляет вызывающий код остановиться.
STREAM_IO_ERROR:
        LD A,#FF
        LD (@WDOS.ABT),A
        LD (@WDOS.EOC),A
; Codex - 2026-07-16 - begin
        ; Отличить ошибку I/O от штатного достижения EOC=#FF.
        SCF
; Codex - 2026-07-16 - end
        RET

; Codex - 2026-07-16 - begin
; Codex - 2026-07-17 - begin
; Все четыре блока распаковываются одинаково. SD-ZC уже упакован из конечного
; проверенного runtime, поэтому прежняя большая таблица наложения не нужна.
DSDZC_RUNTIME_READS EQU #393F
DSDZC_RUNTIME_CSH   EQU #3B17
DSDZC_RUNTIME_CMD18 EQU #3BB5
DSDZC_RUNTIME_CMD25 EQU #3BEA
DSDZC_RUNTIME_WAIT  EQU #3C6D

UNPACK_DRIVER:
        PUSH BC
        CALL @WDOS.DEHR
        POP BC
        LD A,B
        RET
; Codex - 2026-07-17 - end

; Общий аварийный выход SD-ZC: зафиксировать ошибку и снять chip-select.
ZC_MARK_ERROR:
        LD A,1
        LD (@WDOS.ABT),A
        CALL DSDZC_RUNTIME_CSH
        LD A,1
        OR A
        RET

; WAIT: дождаться #FF с конечным лимитом. Исходный AF восстанавливается,
; поскольку старые командные процедуры не использовали флаги WAIT.
ZC_WAIT_READY:
        PUSH AF,BC,DE,HL
        LD E,8
.outer:
        LD HL,0
        LD BC,#0057
.poll:
        IN A,(C)
        INC A
        JR Z,.ready
        DEC HL
        LD A,H:OR L
        JR NZ,.poll
        DEC E
        JR NZ,.outer
        CALL ZC_MARK_ERROR
.ready:
        POP HL,DE,BC,AF
        RET

; WTDO: дождаться первого байта, отличного от #FF. При тайм-ауте возвращается
; #FF, ABT устанавливается, а chip-select снимается.
ZC_WAIT_TOKEN:
        PUSH BC,DE,HL
        LD E,8
.outer:
        LD HL,0
        LD BC,#0057
.poll:
        IN A,(C)
        CP #FF
        JR NZ,.received
        DEC HL
        LD A,H:OR L
        JR NZ,.poll
        DEC E
        JR NZ,.outer
        CALL ZC_MARK_ERROR
        POP HL,DE,BC
        LD A,#FF
        OR A
        RET
.received:
        POP HL,DE,BC
        RET

; WTBY: дождаться снятия busy. Z означает успех, NZ — конечный тайм-аут.
ZC_WAIT_BUSY:
        PUSH BC,DE,HL
        LD E,8
.outer:
        LD HL,0
        LD BC,#0057
.poll:
        IN A,(C)
        OR A
        JR NZ,.ready
        DEC HL
        LD A,H:OR L
        JR NZ,.poll
        DEC E
        JR NZ,.outer
        CALL ZC_MARK_ERROR
        POP HL,DE,BC
        LD A,1
        OR A
        RET
.ready:
        POP HL,DE,BC
        XOR A
        RET

; Проверить ответ записи и дождаться снятия busy. При успехе счётчик блоков
; переносится из AF' в AF, как это делал прежний участок SDDSE.
ZC_DATA_RESPONSE:
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        CALL ZC_WAIT_TOKEN
        LD C,A
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        LD A,C:AND #1F:CP 5:JR NZ,.mark
        CALL ZC_WAIT_BUSY
        JR NZ,.failed
        EX AF,AF'
        CP A
        RET
.mark:
        CALL ZC_MARK_ERROR
.failed:
        LD A,1
        OR A
        RET

; Ограничить оба ожидания DMA. A сохраняется, CF=1 означает тайм-аут.
ZC_DMA_WAIT:
; Codex - 2026-07-16 - begin
; BC намеренно не восстанавливается: исходная последовательность оставляла
; BC=#27AF, и следующий OUT меняет только B, сохраняя обязательный C=#AF.
        PUSH AF,DE
        LD BC,#27AF
        LD DE,0
.poll:
        INF
        JP P,.ready
        DEC DE
        LD A,D:OR E
        JR NZ,.poll
        CALL ZC_MARK_ERROR
        POP DE,AF
        SCF
        RET
.ready:
        POP DE,AF
        OR A
        RET
; Codex - 2026-07-16 - end

; Начать многоблочное чтение. Счётчик остаётся в AF'; Z означает готовность.
ZC_START_READ:
        XOR A
        LD (@WDOS.ABT),A
        CALL DSDZC_RUNTIME_CMD18
        LD C,A
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        LD A,C:OR A:JR NZ,.mark
        XOR A
        RET
.mark:
        CALL ZC_MARK_ERROR
.failed:
        LD A,1
        OR A
        RET

; Прочитать блок штатной процедурой с уже ограниченными DMA-ожиданиями.
; При успехе вернуть счётчик из AF' и Z, при ошибке оставить AF' нетронутым.
ZC_READ_BLOCK:
        CALL DSDZC_RUNTIME_READS
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        EX AF,AF'
        CP A
        RET
.failed:
        CALL DSDZC_RUNTIME_CSH
        LD A,1
        OR A
        RET

; Проверить аппаратный запрет записи и одновременно начать новый результат I/O.
ZC_WRITE_READY:
        XOR A
        LD (@WDOS.ABT),A
        IN A,(#77)
        AND 2
        JR NZ,.failed
        XOR A
        RET
.failed:
        JP ZC_MARK_ERROR

; Начать многоблочную запись и дождаться готовности к первому блоку. При успехе
; счётчик переносится из AF' в AF для существующего цикла SDDSE.
ZC_START_WRITE:
        CALL DSDZC_RUNTIME_CMD25
        LD C,A
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        LD A,C:OR A:JR NZ,.mark
        CALL DSDZC_RUNTIME_WAIT
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        EX AF,AF'
        CP A
        RET
.mark:
        CALL ZC_MARK_ERROR
.failed:
        LD A,1
        OR A
        RET

; Токен данных чтения обязан быть #FE. Любой иной ответ завершает операцию.
ZC_CHECK_TOKEN:
        CP #FE
        JR NZ,.failed
        XOR A
        RET
.failed:
        JP ZC_MARK_ERROR
; Codex - 2026-07-16 - end

; Codex - 2026-07-17 - begin
; Постоянный контекст APPEND хранится в выделенной странице расширения и не
; занимает рабочие буферы CORE32. Рабочая копия меняется во время вызова и
; становится постоянной только после успешной записи каталожной ENTRY.
APPEND_VALID:                 DS 1
APPEND_READY:                 DS 1
APPEND_FOUND_POINTER:         DS 2
APPEND_DIRECTORY_LBA:         DS 4
APPEND_DIRECTORY_OFFSET:      DS 2
APPEND_ENTRY:                 DS 32

APPEND_CONTEXT:
APPEND_SIZE:                  DS 4
APPEND_FIRST_CLUSTER:         DS 4
APPEND_CURRENT_CLUSTER:       DS 4
APPEND_SECTOR:                DS 1
APPEND_OFFSET:                DS 2
APPEND_NEEDS_CLUSTER:         DS 1
APPEND_CONTEXT_END:
APPEND_CONTEXT_SIZE           EQU APPEND_CONTEXT_END-APPEND_CONTEXT

APPEND_WORK_CONTEXT:
APPEND_WORK_SIZE:             DS 4
APPEND_WORK_FIRST:            DS 4
APPEND_WORK_CURRENT:          DS 4
APPEND_WORK_SECTOR:           DS 1
APPEND_WORK_OFFSET:           DS 2
APPEND_WORK_NEEDS_CLUSTER:    DS 1
        ASSERT $-APPEND_WORK_CONTEXT == APPEND_CONTEXT_SIZE, различается контекст APPEND

APPEND_SOURCE:                DS 2
APPEND_REMAINING:             DS 2
APPEND_CHUNK:                 DS 2
APPEND_SKIP_COUNT:            DS 4
APPEND_PENDING_NEW:           DS 1
APPEND_LINKED_NEW:            DS 1
APPEND_PENDING_OLD_TAIL:      DS 4
APPEND_NEW_CLUSTER:           DS 4
APPEND_OLD_LINK:              DS 4
APPEND_FAT_POINTER:           DS 2
APPEND_SLOT_POINTER:          DS 2
APPEND_LAST_ERROR:            DS 1
; Codex - 2026-07-17 - end

; Служебное состояние лежит в сохранённом нулевом промежутке CORE32.
; Секторный буфер #2000 остаётся в штатном файловом окне #0000; код расширения
; исполняется независимо в окне #C000.
LFN_LEADING            EQU @WDOS.EXT_LFN_LEADING
DIR_PREVIOUS_LBA       EQU @WDOS.EXT_DIR_PREVIOUS_LBA
DIR_OLDER_LBA          EQU @WDOS.EXT_DIR_OLDER_LBA
DIR_OLDER_VALID        EQU @WDOS.EXT_DIR_OLDER_VALID
DIR_PREVIOUS_DIRTY     EQU @WDOS.EXT_DIR_PREVIOUS_DIRTY
DIR_OLDER_DIRTY        EQU @WDOS.EXT_DIR_OLDER_DIRTY
DIR_EXPECTED_SEQUENCE  EQU @WDOS.EXT_DIR_EXPECTED_SEQUENCE
DIR_LFN_CHECKSUM       EQU @WDOS.EXT_DIR_LFN_CHECKSUM
DIR_OLDER_BUFFER       EQU #2000

RUNTIME_END:
        ASSERT RUNTIME_END <= #10000, расширение вышло за пределы физической страницы
; Codex - 2026-07-16 - end
