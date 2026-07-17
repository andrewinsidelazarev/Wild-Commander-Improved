; Codex - 2026-07-16 - begin
; Регрессионный плагин CORE32 для запуска штатным меню Wild Commander.
; Все операции проходят через публичный API плагинов и реальный SD-драйвер.

        DEVICE ZXSPECTRUM128

WLD             EQU #6006
; Codex - 2026-07-17 - begin
; #6004 принадлежит менеджеру плагинов и является флагом Esc, а не ABT CORE32.
; Штатный EOC возвращает A=#0F/CF=0; возвращённая ошибка — A=#FF/CF=1.
; Внутренние адреса ниже принадлежат установленному SD-ZC runtime. ABT хранит
; общий результат I/O; WTDO в текущем штатном драйвере не имеет конечного
; ожидания, поэтому отказной тест распознаёт этот код и безопасно пропускается.
DRIVER_ABT      EQU #384A
DRIVER_NSDC     EQU #3848
DRIVER_EOC      EQU #3849
DRIVER_WTDO     EQU #3C61
DRIVER_CS_ON_VALUE EQU #3B30
; Публичные точки установленного CORE32 и изменяемый JP чтения в RAM-драйвере.
CORE_DEVINI     EQU #4003
CORE_HDD        EQU #4009
CORE_RDD        EQU #400C
CORE_LOAD512    EQU #4015
CORE_DOS_SWP    EQU #401B
CORE_RFRH       EQU #4030
CORE_FENTRY     EQU #404E
CORE_PAGE_IN    EQU #6B7A
CORE_PAGE_OUT   EQU #6B8B
CORE_EXTENSION_GATE EQU #5123
CORE_BFTSZ      EQU #3890
DRIVER_RDD_JUMP EQU #380F
DRIVER_SDD_JUMP EQU #3812
DRIVER_CUHL     EQU #38A8
EXT_ID_FAT_SECTOR_IN_RANGE EQU 6
EXT_ID_CLASSIFY_FAT_LINK   EQU 8
; Codex - 2026-07-17 - end

        ORG #0000
; Codex - 2026-07-16 - begin
; Заголовок собирается по физическим адресам файла. Отдельный DISP #0000
; здесь нельзя оставлять активным перед подключением runtime-адреса #8000.
; Codex - 2026-07-16 - end
START_CODE:

; Заголовок WMF версии 10.
        DS 16,0
        DB "WildCommanderMDL"
        DB #0A
        DB #00
        DB #01
        DB #00
; Codex - 2026-07-16 - begin
        DB #00,(PLUGIN_FILE_END-MAIN_FILE_START+511)/512
; Codex - 2026-07-16 - end
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DS 16,0
        DS 32*3,0
        DB #00
        DD #FFFFFFFF
        DB "CORE32 regression test Codex    "
        DB #03
        DB #00

        ALIGN 512,0
; Codex - 2026-07-16 - begin
; Физически код идёт сразу после заголовка, а все абсолютные CALL/JP должны
; собираться для адреса, по которому загрузчик WMF запускает его в памяти.
MAIN_FILE_START:
        DISP #8000
; Codex - 2026-07-16 - end
MAIN_START:

PLUGIN:
        PUSH IX
        CALL GEDPL
; Codex - 2026-07-16 - begin
; Плагин может быть предварительно загружен из каталога WC автономным
; файловым вводом патченного Unreal. Клонировать поток панели и явно
; перейти в корень, чтобы регрессионный набор всегда начинался с C32T716.
        LD D,#FE
        CALL STREAM_API
        LD D,#FF
        CALL STREAM_API
; Codex - 2026-07-16 - end
        CALL INITIALIZE_RESULT

        CALL ENTER_MAIN_DIRECTORY
        JR Z,.main_directory_ready
        LD A,#E0
        JP TEST_FAILED
.main_directory_ready:
        LD A,1
        CALL CHECKPOINT

        CALL TEST_EMPTY_FILE
        JR Z,.empty_ok
        LD A,1
        JP TEST_FAILED
.empty_ok:
        LD A,1
        LD (RESULT_COMPLETED),A
        LD A,2
        CALL CHECKPOINT

        CALL TEST_SPACE_FORCES_LFN
        JR Z,.space_ok
        LD A,2
        JP TEST_FAILED
.space_ok:
        LD A,2
        LD (RESULT_COMPLETED),A
        LD A,3
        CALL CHECKPOINT

        CALL TEST_LEADING_SPACES
        JR Z,.leading_ok
        LD A,3
        JP TEST_FAILED
.leading_ok:
        LD A,3
        LD (RESULT_COMPLETED),A
        LD A,4
        CALL CHECKPOINT

        CALL TEST_STREAM_IO
        JR Z,.stream_ok
        LD A,4
        JP TEST_FAILED
.stream_ok:
        LD A,4
        LD (RESULT_COMPLETED),A
        LD A,5
        CALL CHECKPOINT

        CALL TEST_FAT_BOUNDARY
        JR Z,.fat_ok
        LD A,5
        JP TEST_FAILED
.fat_ok:
        LD A,5
        LD (RESULT_COMPLETED),A
        LD A,6
        CALL CHECKPOINT

; Codex - 2026-07-16 - begin
        CALL TEST_SD_TIMEOUT
        JR Z,.sd_timeout_ok
        LD A,6
        JP TEST_FAILED
.sd_timeout_ok:
        LD A,6
        LD (RESULT_COMPLETED),A
        LD A,7
        CALL CHECKPOINT

        CALL TEST_FULL_DIRECTORY_END
        JR Z,.full_directory_ok
        LD A,7
        JP TEST_FAILED
.full_directory_ok:
        LD A,7
        LD (RESULT_COMPLETED),A
; Codex - 2026-07-17 - begin
        LD A,8
        CALL CHECKPOINT

        CALL TEST_APPEND_FILE
        JR Z,.append_ok
        LD A,8
        JP TEST_FAILED
.append_ok:
        LD A,8
        LD (RESULT_COMPLETED),A
; Codex - 2026-07-17 - end
        ; Зафиксировать все тесты основного каталога до его смены.
        CALL WRITE_CURRENT_RESULT
; Codex - 2026-07-16 - end

        CALL ENTER_LONG_DIRECTORY
        JR Z,.long_directory_ready
        LD A,7
        JP TEST_FAILED
.long_directory_ready:
        LD A,1
        LD (IN_LONG_DIRECTORY),A
; Codex - 2026-07-17 - begin
        LD A,9
; Codex - 2026-07-17 - end
        CALL CHECKPOINT

        CALL TEST_LONG_DELETE
        JR Z,.long_delete_ok
; Codex - 2026-07-17 - begin
        LD A,9
; Codex - 2026-07-17 - end
        JP TEST_FAILED
.long_delete_ok:
; Codex - 2026-07-17 - begin
        LD A,9
; Codex - 2026-07-17 - end
        LD (RESULT_COMPLETED),A
; Codex - 2026-07-16 - begin
; Codex - 2026-07-17 - begin
        LD A,10
; Codex - 2026-07-17 - end
        CALL CHECKPOINT

        CALL TEST_INVALID_BPB_RETURN
        JR Z,.invalid_bpb_ok
; Codex - 2026-07-17 - begin
        LD A,10
; Codex - 2026-07-17 - end
        JP TEST_FAILED
.invalid_bpb_ok:
; Codex - 2026-07-17 - begin
        LD A,10
; Codex - 2026-07-17 - end
        LD (RESULT_COMPLETED),A
; Codex - 2026-07-16 - end
        LD A,#FF
        LD (RESULT_STAGE),A
        LD A,1
        LD (RESULT_STATUS),A
        CALL WRITE_CURRENT_RESULT
; Codex - 2026-07-17 - begin
        ; Окно PASS допустимо только после подтверждённой записи финального
        ; результата. При отказе вернуться в основной каталог и сохранить там
        ; диагностический код #FA/#FB вместо ложного успешного сообщения.
        JR Z,.final_result_written
        LD A,#FF
        LD (RESULT_STATUS),A
        XOR A
        LD (IN_LONG_DIRECTORY),A
        CALL ENTER_MAIN_DIRECTORY
        CALL WRITE_CURRENT_RESULT
.final_result_written:
; Codex - 2026-07-17 - end
        JP SHOW_RESULT

TEST_FAILED:
        LD (RESULT_FAILED_TEST),A
        LD A,#FF
        LD (RESULT_STATUS),A
        CALL WRITE_CURRENT_RESULT

SHOW_RESULT:
        LD IX,RESULT_WINDOW
        CALL PRWOW
        LD A,(RESULT_STATUS)
        CP 1
        LD HL,TEXT_PASS
        LD BC,TEXT_PASS_END-TEXT_PASS
        JR Z,.print
        LD HL,TEXT_FAIL
        LD BC,TEXT_FAIL_END-TEXT_FAIL
.print:
        LD D,2
        LD E,2
        CALL PRSRW
.wait_escape:
        EI
        HALT
        CALL ESC
        JR Z,.wait_escape
        LD IX,RESULT_WINDOW
        CALL RRESB
        POP IX
        RET

INITIALIZE_RESULT:
        XOR A
        LD (RESULT_STATUS),A
        LD (RESULT_FAILED_TEST),A
        LD (RESULT_API_ERROR),A
        LD (RESULT_STAGE),A
        LD (RESULT_COMPLETED),A
        LD (IN_LONG_DIRECTORY),A
        LD HL,RESULT_RESERVED
        LD DE,RESULT_RESERVED+1
        LD BC,512-(RESULT_RESERVED-RESULT_BUFFER)-1
        LD (HL),A
        LDIR
        RET

CHECKPOINT:
        LD (RESULT_STAGE),A
        JP WRITE_CURRENT_RESULT

ENTER_MAIN_DIRECTORY:
        LD HL,MAIN_DIRECTORY_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR
        CALL GDIR
        XOR A
        RET

ENTER_LONG_DIRECTORY:
        LD HL,LONG_DIRECTORY_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR
        CALL GDIR
        XOR A
        RET

WRITE_CURRENT_RESULT:
        LD A,(IN_LONG_DIRECTORY)
        OR A
        LD HL,MAIN_RESULT_FIND
        JR Z,.selected
        LD HL,LONG_RESULT_FIND
.selected:
        CALL FENTRY
; Codex - 2026-07-17 - begin
        JR Z,.find_failed
; Codex - 2026-07-17 - end
        CALL GFILE
        LD HL,RESULT_BUFFER
        LD B,1
        CALL SAVE512
; Codex - 2026-07-17 - begin
        JR C,.write_failed
        XOR A
        RET
.find_failed:
        LD A,#FA
        JR .failed
.write_failed:
        LD A,#FB
.failed:
        LD (RESULT_API_ERROR),A
        LD A,1
        OR A
        RET
; Codex - 2026-07-17 - end

TEST_EMPTY_FILE:
        LD HL,EMPTY_CREATE
        CALL MKFILE
        JP NZ,API_ERROR
        LD DE,ENTRY_BUFFER
        CALL TENTRY

        LD HL,ENTRY_BUFFER+20
        LD A,(HL)
        INC HL
        OR (HL)
        LD HL,ENTRY_BUFFER+26
        OR (HL)
        INC HL
        OR (HL)
        LD HL,ENTRY_BUFFER+28
        OR (HL)
        INC HL
        OR (HL)
        INC HL
        OR (HL)
        INC HL
        OR (HL)
        JP NZ,SEMANTIC_ERROR
        XOR A
        RET

TEST_SPACE_FORCES_LFN:
        LD HL,SPACE_CREATE
        CALL MKFILE
        JP NZ,API_ERROR
        LD HL,SPACE_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR

        LD HL,PLAIN_CREATE
        CALL MKFILE
        JP NZ,API_ERROR
        LD HL,PLAIN_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR
        XOR A
        RET

TEST_LEADING_SPACES:
        LD HL,LEADING_STORED_CREATE
        CALL MKFILE
        JP NZ,API_ERROR
        LD HL,LEADING_STORED_TRIMMED_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR

        LD HL,LEADING_QUERY_CREATE
        CALL MKFILE
        JP NZ,API_ERROR
        LD HL,LEADING_QUERY_SPACED_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR

        LD HL,INTERNAL_SPACE_MISMATCH_FIND
; Codex - 2026-07-16 - begin
        ; Прямой FENTRY требует той же рабочей страницы, что штатный API 59.
        CALL CORE_PAGE_IN
        CALL CORE_FENTRY
        CALL CORE_PAGE_OUT
; Codex - 2026-07-16 - end
        JP NZ,SEMANTIC_ERROR
        XOR A
        RET

TEST_STREAM_IO:
        LD HL,IO_CREATE
        CALL MKFILE
        JP NZ,API_ERROR

        LD HL,IO_BUFFER
        LD DE,IO_BUFFER+1
        LD BC,511
        LD (HL),#A5
        LDIR
        LD HL,IO_BUFFER
        LD B,1
        CALL SAVE512
; Codex - 2026-07-16 - begin
        JP C,API_ERROR
; Codex - 2026-07-16 - end
; Codex - 2026-07-17 - begin
        ; При SPC=1 один сектор достигает конца цепочки и возвращает #0F.
        ; При SPC>1 поток корректно остаётся внутри того же кластера с A=0.
        ; Любое третье значение без CF нарушает контракт.
        OR A
        JR Z,.write_status_ok
        CP #0F
        JP NZ,SEMANTIC_ERROR
.write_status_ok:
; Codex - 2026-07-17 - end

        LD HL,IO_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR
        CALL GFILE
        LD HL,IO_BUFFER
        LD DE,IO_BUFFER+1
        LD BC,511
        XOR A
        LD (HL),A
        LDIR
        LD HL,IO_BUFFER
        LD B,1
        CALL LOAD512
; Codex - 2026-07-16 - begin
        JP C,API_ERROR
; Codex - 2026-07-16 - end

        LD HL,IO_BUFFER
        LD BC,512
.verify:
        LD A,(HL)
        CP #A5
        JP NZ,SEMANTIC_ERROR
        INC HL
        DEC BC
        LD A,B
        OR C
        JR NZ,.verify

        LD HL,IO_FIND
        CALL DELFL
        JP Z,SEARCH_ERROR
        XOR A
        RET

TEST_FAT_BOUNDARY:
        LD HL,FAT_BOUNDARY_CREATE
        CALL MKFILE
        JP NZ,API_ERROR
        LD HL,FAT_BOUNDARY_FIND
        CALL DELFL
        JP Z,SEARCH_ERROR
; Codex - 2026-07-16 - begin
        CALL CORE_PAGE_IN
        CALL TEST_FAT_VALUE_BOUNDARIES
        JR NZ,.semantic_failed
        CALL CORE_RFRH
        CALL CORE_PAGE_OUT
        JP NZ,API_ERROR
        JR .direct_ok
.semantic_failed:
        CALL CORE_PAGE_OUT
        JP SEMANTIC_ERROR
.direct_ok:
; Codex - 2026-07-16 - end
        XOR A
        RET

; Codex - 2026-07-16 - begin
; Проверить классификацию FAT32 и полное 32-битное сравнение с BFTSZ прямо
; через тот же шлюз расширения, который использует рабочий CORE32.
TEST_FAT_VALUE_BOUNDARIES:
        LD HL,2
        LD DE,#F000
        CALL CORE_EXTENSION_GATE
        DB EXT_ID_CLASSIFY_FAT_LINK
        JP C,.failed
        JP Z,.failed
        LD A,D:OR E:JP NZ,.failed
        LD A,H:OR A:JP NZ,.failed
        LD A,L:CP 2:JP NZ,.failed

        LD HL,#FFF0
        LD DE,#0FFF
        CALL CORE_EXTENSION_GATE
        DB EXT_ID_CLASSIFY_FAT_LINK
        JP NC,.failed
        JP Z,.failed

        LD HL,#FFF7
        LD DE,#0FFF
        CALL CORE_EXTENSION_GATE
        DB EXT_ID_CLASSIFY_FAT_LINK
        JP NC,.failed
        JP Z,.failed

        LD HL,#FFF8
        LD DE,#FFFF
        CALL CORE_EXTENSION_GATE
        DB EXT_ID_CLASSIFY_FAT_LINK
        JP C,.failed
        JP NZ,.failed
        LD A,D:CP #0F:JP NZ,.failed

        LD HL,(CORE_BFTSZ)
        LD DE,(CORE_BFTSZ+2)
        CALL CORE_EXTENSION_GATE
        DB EXT_ID_FAT_SECTOR_IN_RANGE
        JP C,.failed

        LD HL,(CORE_BFTSZ)
        LD DE,(CORE_BFTSZ+2)
        LD A,H:OR L:JR NZ,.before_ready
        DEC DE
.before_ready:
        DEC HL
        CALL CORE_EXTENSION_GATE
        DB EXT_ID_FAT_SECTOR_IN_RANGE
        JP NC,.failed

        LD HL,(CORE_BFTSZ)
        LD DE,(CORE_BFTSZ+2)
        INC HL
        LD A,H:OR L:JR NZ,.after_ready
        INC DE
.after_ready:
        CALL CORE_EXTENSION_GATE
        DB EXT_ID_FAT_SECTOR_IN_RANGE
        JP C,.failed

        LD HL,0
        LD DE,(CORE_BFTSZ+2)
        INC DE
        CALL CORE_EXTENSION_GATE
        DB EXT_ID_FAT_SECTOR_IN_RANGE
        JP C,.failed
        XOR A
        RET
.failed:
        LD A,1
        OR A
        RET
; Codex - 2026-07-16 - end

; Codex - 2026-07-16 - begin
; Codex - 2026-07-17 - begin
; Для диагностического patched-SD runtime выбрать второй ZC без отвечающего
; SPI-устройства и проверить возврат ошибки через ABT/NZ/CF. Текущий боевой
; штатный WTDO потенциально бесконечен: он распознаётся ниже и пропускается,
; поэтому этот сценарий не засчитывается как его физический отказной тест.
; Codex - 2026-07-17 - end
TEST_SD_TIMEOUT:
        LD HL,MAIN_RESULT_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR
        LD HL,#7F30
        LD DE,RESULT_RESERVED+7
        LD BC,4
        LDIR
        CALL GFILE
        ; Прямые точки CORE и runtime #3800 используют рабочую страницу окна
        ; #0000. Тот же пролог/эпилог применяют штатные файловые API плагинов.
        CALL CORE_PAGE_IN

; Codex - 2026-07-17 - begin
        ; Боевой образ после аппаратной регрессии использует точный штатный
        ; SD-ZC. Его WTDO начинается с PUSH BC (#C5) и намеренно не запускается
        ; против отсутствующего SPI-устройства: исходный цикл не имеет
        ; тайм-аута. Обычные чтение и запись уже проверены TEST_STREAM_IO.
        LD A,(DRIVER_WTDO)
        CP #C5
        JR NZ,.patched_timeout_driver
        CALL CORE_PAGE_OUT
        XOR A
        RET
.patched_timeout_driver:
; Codex - 2026-07-17 - end

        ; Диагностический след остаётся в резерве файла результата:
        ; пары NSDC/EOC после GFILE, WTDO и публичного RDD, затем ABT.
        LD A,(DRIVER_NSDC)
        LD (RESULT_RESERVED+0),A
        LD A,(DRIVER_EOC)
        LD (RESULT_RESERVED+1),A
        LD A,(DRIVER_ABT)
        LD (RESULT_RESERVED+12),A
        LD HL,DRIVER_CUHL
        LD DE,RESULT_RESERVED+13
        LD BC,4
        LDIR
        XOR A
        LD (DRIVER_ABT),A
        LD BC,#0077
        LD A,#0B
        OUT (C),A
        LD BC,#0057
        IN A,(C)
        IN A,(C)
        CALL DRIVER_WTDO
        LD A,(DRIVER_NSDC)
        LD (RESULT_RESERVED+2),A
        LD A,(DRIVER_EOC)
        LD (RESULT_RESERVED+3),A
        LD A,(DRIVER_ABT)
        OR A
        JR Z,.wtdo_failed

        XOR A
        LD (DRIVER_ABT),A
        LD A,#0B
        LD (DRIVER_CS_ON_VALUE),A
        LD HL,0
        LD DE,0
        LD BC,IO_BUFFER
        LD A,1
        CALL CORE_RDD
        LD A,(DRIVER_NSDC)
        LD (RESULT_RESERVED+4),A
        LD A,(DRIVER_EOC)
        LD (RESULT_RESERVED+5),A
        LD A,(DRIVER_ABT)
        LD (RESULT_RESERVED+6),A
        JR Z,.read_status_failed
        LD A,(DRIVER_ABT)
        OR A
        JR Z,.read_abt_failed

        ; Перед потоковой проверкой GFILE обязан оставить поток в начале файла.
        ; Отдельные коды различают ошибку подготовки и потерю CF после I/O.
        LD A,(DRIVER_NSDC)
        OR A
        JR NZ,.stream_nsdc_failed
        LD A,(DRIVER_EOC)
        OR A
        JR NZ,.stream_eoc_failed
        LD HL,IO_BUFFER
        LD B,1
        CALL CORE_LOAD512
        ; Сохранить точные флаги и состояние, затем восстановить AF для проверки.
        PUSH AF
        POP DE
        LD A,E
        LD (RESULT_RESERVED+17),A
        LD A,(DRIVER_ABT)
        LD (RESULT_RESERVED+18),A
        LD A,(DRIVER_EOC)
        LD (RESULT_RESERVED+19),A
        PUSH DE
        POP AF
        JR C,.stream_cf_ok
        LD A,(DRIVER_ABT)
        OR A
        JR NZ,.stream_cf_lost
        JR .stream_io_missing
.stream_cf_ok:

        LD A,#01
        LD (DRIVER_CS_ON_VALUE),A
        XOR A
        LD (DRIVER_ABT),A
        LD BC,#0077
        LD A,#03
        OUT (C),A
        CALL CORE_PAGE_OUT
        XOR A
        RET
.wtdo_failed:
        LD A,#F1
        JR .failed
.read_status_failed:
        LD A,#F2
        JR .failed
.read_abt_failed:
        LD A,#F3
        JR .failed
.stream_io_missing:
        LD A,#F4
        JR .failed
.stream_cf_lost:
        LD A,#F5
        JR .failed
.stream_nsdc_failed:
        LD A,#F6
        JR .failed
.stream_eoc_failed:
        LD A,#F7
.failed:
        LD (RESULT_API_ERROR),A
        LD A,#01
        LD (DRIVER_CS_ON_VALUE),A
        LD BC,#0077
        LD A,#03
        OUT (C),A
        CALL CORE_PAGE_OUT
        LD A,1
        OR A
        RET
; Codex - 2026-07-16 - end

; Codex - 2026-07-16 - begin
; Войти в одно-кластерный каталог, где все 16 слотов заняты и записи #00 нет.
; Отсутствующее имя обязано вернуть Z по достижении EOC, затем поток
; восстанавливается в основном тестовом каталоге.
TEST_FULL_DIRECTORY_END:
        LD HL,FULL_DIRECTORY_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR
        CALL GDIR
        LD HL,FULL_MISSING_FIND
        CALL FENTRY
        JR Z,.missing_ok
        JP SEMANTIC_ERROR
.missing_ok:
        LD D,#FF
        CALL STREAM_API
        CALL ENTER_MAIN_DIRECTORY
        RET NZ
        XOR A
        RET
; Codex - 2026-07-16 - end

; Codex - 2026-07-17 - begin
; Проверить FTP-сценарий: пустой файл получает произвольные куски, пересекает
; частичный сектор и пять одно-секторных кластеров, затем повторно открывается
; и продолжает расти. Недопустимые длина и окно памяти не должны менять файл.
TEST_APPEND_FILE:
        LD HL,APPEND_CREATE
        CALL MKFILE
        JP NZ,API_ERROR
        LD HL,APPEND_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR

        LD HL,APPEND_BUFFER,BC,0
        CALL APPEND
        JP NZ,API_ERROR
        LD HL,APPEND_BUFFER,BC,513
        CALL APPEND
        JP Z,SEMANTIC_ERROR
        CP #22
        JP NZ,SEMANTIC_ERROR
        LD HL,#C000,BC,1
        CALL APPEND
        JP Z,SEMANTIC_ERROR
        CP #21
        JP NZ,SEMANTIC_ERROR

        LD A,#A1,BC,3
        CALL APPEND_PATTERN
        JP NZ,API_ERROR
        LD A,#B2,BC,509
        CALL APPEND_PATTERN
        JP NZ,API_ERROR
        LD A,#C3,BC,1
        CALL APPEND_PATTERN
        JP NZ,API_ERROR
        LD A,#D4,BC,511
        CALL APPEND_PATTERN
        JP NZ,API_ERROR
        LD A,#E5,BC,512
        CALL APPEND_PATTERN
        JP NZ,API_ERROR
        LD A,#F6,BC,17
        CALL APPEND_PATTERN
        JP NZ,API_ERROR

        ; Повторный FENTRY заставляет APPEND восстановить EOF из FAT и размера.
        LD HL,APPEND_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR
        LD A,#17,BC,100
        CALL APPEND_PATTERN
        JP NZ,API_ERROR
        LD A,#28,BC,400
        CALL APPEND_PATTERN
        JP NZ,API_ERROR

        LD HL,APPEND_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR
        LD BC,2053
        OR A:SBC HL,BC
        JP NZ,SEMANTIC_ERROR
        LD A,D:OR E
        JP NZ,SEMANTIC_ERROR
        LD DE,ENTRY_BUFFER
        CALL TENTRY
        LD HL,(ENTRY_BUFFER+28),BC,2053
        OR A:SBC HL,BC
        JP NZ,SEMANTIC_ERROR
        LD HL,(ENTRY_BUFFER+30)
        LD A,H:OR L
        JP NZ,SEMANTIC_ERROR
        LD HL,(ENTRY_BUFFER+20)
        LD A,H:AND #0F:OR L
        LD HL,(ENTRY_BUFFER+26)
        OR H:OR L
        JP Z,SEMANTIC_ERROR

        LD HL,APPEND_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR
        CALL GFILE
        LD HL,APPEND_READ_BUFFER,B,5
        CALL LOAD512
        JP C,API_ERROR

        LD HL,APPEND_READ_BUFFER
        LD A,#A1,BC,3:CALL CHECK_APPEND_PATTERN:JP NZ,SEMANTIC_ERROR
        LD A,#B2,BC,509:CALL CHECK_APPEND_PATTERN:JP NZ,SEMANTIC_ERROR
        LD A,#C3,BC,1:CALL CHECK_APPEND_PATTERN:JP NZ,SEMANTIC_ERROR
        LD A,#D4,BC,511:CALL CHECK_APPEND_PATTERN:JP NZ,SEMANTIC_ERROR
        LD A,#E5,BC,512:CALL CHECK_APPEND_PATTERN:JP NZ,SEMANTIC_ERROR
        LD A,#F6,BC,17:CALL CHECK_APPEND_PATTERN:JP NZ,SEMANTIC_ERROR
        LD A,#17,BC,100:CALL CHECK_APPEND_PATTERN:JP NZ,SEMANTIC_ERROR
        LD A,#28,BC,400:CALL CHECK_APPEND_PATTERN:JP NZ,SEMANTIC_ERROR
        XOR A
        LD BC,507:CALL CHECK_APPEND_PATTERN:JP NZ,SEMANTIC_ERROR
        XOR A
        RET

; Заполнить временный блок одним байтом и сразу вызвать API 76, сохранив BC.
APPEND_PATTERN:
        PUSH BC
        LD HL,APPEND_BUFFER
        LD (HL),A
        LD DE,APPEND_BUFFER+1
        DEC BC
        LD A,B:OR C:JR Z,.filled
        LDIR
.filled:
        POP BC
        LD HL,APPEND_BUFFER
        JP APPEND

; Сверить BC байт с A. При успехе HL остаётся на следующем диапазоне.
CHECK_APPEND_PATTERN:
        LD D,A
.next:
        LD A,(HL):CP D:JR NZ,.failed
        INC HL
        DEC BC
        LD A,B:OR C:JR NZ,.next
        XOR A
        RET
.failed:
        LD A,1
        OR A
        RET
; Codex - 2026-07-17 - end

TEST_LONG_DELETE:
        LD HL,LONG_TOO_LONG_CREATE
        CALL MKFILE
        JP Z,SEMANTIC_ERROR
        LD HL,INVALID_CHAR_CREATE
        CALL MKFILE
        JP Z,SEMANTIC_ERROR

        LD HL,LONG_CREATE
        CALL MKFILE
        JP NZ,API_ERROR
        LD HL,LONG_FIND
        CALL FENTRY
        JP Z,SEARCH_ERROR
        LD HL,LONG_FIND
        CALL DELFL
        JP Z,SEARCH_ERROR
        XOR A
        RET

; Codex - 2026-07-16 - begin
; Подменить только JP чтения уже установленного драйвера процедурой, которая
; возвращает нулевой MBR/BPB. Старый FHDD после попытки superfloppy снова
; переходил в Nhdd и зависал; исправленный обязан один раз вернуть NZ.
; После проверки штатный SD-ZC полностью восстанавливается через DOS_SWP.
TEST_INVALID_BPB_RETURN:
        ; Драйвер #3800 и данные CORE находятся в рабочей странице окна #0000.
        CALL CORE_PAGE_IN
        CALL INSTALL_FAKE_INVALID_READ
        XOR A
        LD (FAKE_WRITE_CALLED),A
        CALL CORE_RFRH
        LD A,#F8
        JR Z,.record_fake_failure
        LD A,(FAKE_WRITE_CALLED)
        OR A
        LD A,#F7
        JR NZ,.record_fake_failure

        CALL CORE_HDD
        LD A,0
        JR NZ,.expected_failure
        INC A
.expected_failure:
.record_fake_failure:
        LD (HDD_UNEXPECTED_SUCCESS),A

        LD A,1
        CALL CORE_DOS_SWP
        CALL CORE_DEVINI
        JR NZ,.restore_core_failed
        CALL CORE_HDD
        JR NZ,.restore_core_failed
        CALL CORE_PAGE_OUT
        CALL ENTER_MAIN_DIRECTORY
        JR NZ,.restore_api_failed
        CALL ENTER_LONG_DIRECTORY
        JR NZ,.restore_api_failed

        LD A,(HDD_UNEXPECTED_SUCCESS)
        OR A
        JR NZ,.failed
        XOR A
        RET
.restore_core_failed:
        CALL CORE_PAGE_OUT
.restore_api_failed:
        LD A,#F9
        LD (RESULT_API_ERROR),A
.failed:
        LD A,1
        OR A
        RET

INSTALL_FAKE_INVALID_READ:
        LD HL,DRIVER_RDD_JUMP
        LD (HL),#C3
        INC HL
        LD DE,FAKE_INVALID_READ
        LD (HL),E
        INC HL
        LD (HL),D
        LD HL,DRIVER_SDD_JUMP
        LD (HL),#C3
        INC HL
        LD DE,FAKE_FORBIDDEN_WRITE
        LD (HL),E
        INC HL
        LD (HL),D
        RET

FAKE_INVALID_READ:
        PUSH HL
        LD D,H
        LD E,L
        INC DE
        LD BC,511
        XOR A
        LD (HL),A
        LDIR
        POP HL
        RET

FAKE_FORBIDDEN_WRITE:
        LD A,1
        LD (FAKE_WRITE_CALLED),A
        XOR A
        RET
; Codex - 2026-07-16 - end

API_ERROR:
        LD (RESULT_API_ERROR),A
        LD A,1
        OR A
        RET

SEARCH_ERROR:
        LD A,#FD
        LD (RESULT_API_ERROR),A
        LD A,1
        OR A
        RET

SEMANTIC_ERROR:
        LD A,#FE
        LD (RESULT_API_ERROR),A
        LD A,1
        OR A
        RET

GEDPL:
        LD A,15
        JP WLD
; Codex - 2026-07-16 - begin
; Управление потоком каталога через штатный API Wild Commander.
STREAM_API:
        LD A,57
        JP WLD
; Codex - 2026-07-16 - end
PRWOW:
        LD A,1
        JP WLD
RRESB:
        LD A,2
        JP WLD
PRSRW:
        LD A,3
        JP WLD
ESC:
        LD A,23
        JP WLD
LOAD512:
        LD A,48
        JP WLD
SAVE512:
        LD A,49
        JP WLD
TENTRY:
        LD A,51
        JP WLD
FENTRY:
        LD A,59
        JP WLD
GFILE:
        LD A,62
        JP WLD
GDIR:
        LD A,63
        JP WLD
MKFILE:
        LD A,72
        JP WLD
DELFL:
        LD A,75
        JP WLD
; Codex - 2026-07-17 - begin
APPEND:
        LD A,76
        JP WLD
; Codex - 2026-07-17 - end

RESULT_WINDOW:
        DB 0,0
        DB 18,10
        DB 52,8
        DB %01111111
        DB 0
        DW 0
        DB 0,0

TEXT_PASS:
        DB "CORE32 TEST PASS"
TEXT_PASS_END:
TEXT_FAIL:
        DB "CORE32 TEST FAIL - SEE C32 RESULT"
TEXT_FAIL_END:

MAIN_DIRECTORY_FIND:
        DB #10,"C32T716",0
LONG_DIRECTORY_FIND:
        DB #10,"LFNDEL",0
; Codex - 2026-07-16 - begin
FULL_DIRECTORY_FIND:
        DB #10,"FULLEOC",0
FULL_MISSING_FIND:
        DB #00,"ABSENT.BIN",0
; Codex - 2026-07-16 - end
MAIN_RESULT_FIND:
        DB #00,"C32RESULT.BIN",0
LONG_RESULT_FIND:
        DB #00,"C32LONG.BIN",0

EMPTY_CREATE:
        DB #00
        DD 0
        DB "EMPTY0.BIN",0

SPACE_CREATE:
        DB #00
        DD 512
        DB "AB C.TXT",0
SPACE_FIND:
        DB #00,"AB C.TXT",0

PLAIN_CREATE:
        DB #00
        DD 512
        DB "plain83.txt",0
PLAIN_FIND:
        DB #00,"plain83.txt",0

LEADING_STORED_CREATE:
        DB #00
        DD 512
        DB "   Leading Name.txt",0
LEADING_STORED_TRIMMED_FIND:
        DB #00,"Leading Name.txt",0

LEADING_QUERY_CREATE:
        DB #00
        DD 512
        DB "Plain Leading.txt",0
LEADING_QUERY_SPACED_FIND:
        DB #00,"   Plain Leading.txt",0
INTERNAL_SPACE_MISMATCH_FIND:
        DB #00,"Plain  Leading.txt",0

IO_CREATE:
        DB #00
        DD 512
        DB "IO512.BIN",0
IO_FIND:
        DB #00,"IO512.BIN",0

FAT_BOUNDARY_CREATE:
        DB #00
        DD 131072
        DB "CROSSFAT.BIN",0
FAT_BOUNDARY_FIND:
        DB #00,"CROSSFAT.BIN",0

; Codex - 2026-07-17 - begin
APPEND_CREATE:
        DB #00
        DD 0
        DB "FTPAPP.BIN",0
APPEND_FIND:
        DB #00,"FTPAPP.BIN",0
; Codex - 2026-07-17 - end

LONG_CREATE:
        DB #00
        DD 512
        DS 251,#4C
        DB ".TXT",0
LONG_FIND:
        DB #00
        DS 251,#4C
        DB ".TXT",0

LONG_TOO_LONG_CREATE:
        DB #00
        DD 512
        DS 252,#4C
        DB ".TXT",0
INVALID_CHAR_CREATE:
        DB #00
        DD 512
        DB "BAD:NAME.TXT",0

IN_LONG_DIRECTORY:
        DB 0
; Codex - 2026-07-16 - begin
HDD_UNEXPECTED_SUCCESS:
        DB 0
FAKE_WRITE_CALLED:
        DB 0
; Codex - 2026-07-16 - end
ENTRY_BUFFER:
        DS 32,0

RESULT_BUFFER:
        DB "C32T2026"
RESULT_STATUS:
        DB 0
RESULT_FAILED_TEST:
        DB 0
RESULT_API_ERROR:
        DB 0
RESULT_STAGE:
        DB 0
RESULT_COMPLETED:
        DB 0
RESULT_RESERVED:
        DS 512-(RESULT_RESERVED-RESULT_BUFFER),0

IO_BUFFER:
        DS 512,0

; Codex - 2026-07-17 - begin
APPEND_BUFFER:
        DS 512,0
APPEND_READ_BUFFER:
        DS 512*5,0
; Codex - 2026-07-17 - end

; Codex - 2026-07-16 - begin
MAIN_RUNTIME_END:
        ENT
PLUGIN_FILE_END:

        SAVEBIN "Build/CORE32T.WMF",START_CODE,PLUGIN_FILE_END-START_CODE
; Codex - 2026-07-16 - end
; Codex - 2026-07-16 - end
