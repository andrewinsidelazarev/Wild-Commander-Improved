; На основе транспорта предоставленного Weather screensaver VDAC2.
; FT812 платы VDAC2: обмен по SPI, запуск в 1024x768@59, поток команд
; сопроцессору и загрузка ресурсов.
;
; FT812 — не «экран в памяти», а видеочип со своей памятью: RAM_G (1 МиБ)
; хранит шрифты и иконки, а картинку он собирает каждый кадр по дисплей-листу —
; программе из 32-битных команд. Писать её удобнее через сопроцессор чипа: ему
; отдают поток команд в очередь (FIFO) на 4 КиБ, а он строит из них
; дисплей-лист, рисует градиент, распаковывает сжатые данные.
;
; Z80 говорит с чипом через Z-контроллер — тот же, что обслуживает SD-карту.
; Порт #77 выбирает, с кем обмен по SPI: бит 2 — FT812 (значение #07), #03 —
; никто (так шину оставляет драйвер SD). Порт #57 — сам обмен: запись
; отправляет байт; чтение возвращает байт, пришедший при ПРЕДЫДУЩЕМ обмене, и
; сразу запускает следующий. Поэтому после адреса при чтении идёт пустой байт,
; а первый прочитанный байт выбрасывается.
;
; Посылки FT812 (FT81X Series Programmer Guide):
;   команда хоста — три байта: код, параметр, 0;
;   запись памяти — три байта адреса (старшие биты 10), затем данные;
;   чтение памяти — три байта адреса (старшие биты 00), пустой байт, данные.
; Порядок запуска и тайминги 1024x768@59 — как VM_1024_768_59Hz в TSLib
; (так работают Zuma и HMM2 на VDAC2): частота точек 64 МГц, строка 1344
; такта, кадр 806 строк, 64 000 000 / (1344 * 806) = 59,08 Гц.

SPI_CTRL        equ #77                 ; Z-контроллер: кто выбран на шине SPI
SPI_DATA        equ #57                 ; Z-контроллер: байт обмена
SPI_FT812       equ #07                 ; выбран FT812, SD-карта — нет
SPI_IDLE        equ #03                 ; никто не выбран (покой SD)

; адреса памяти и регистров FT812
FT_RAM_REG      equ #302000
REG_ID          equ #302000             ; #7C — чип запущен
REG_HCYCLE      equ #30202C
REG_HOFFSET     equ #302030
REG_HSIZE       equ #302034
REG_HSYNC0      equ #302038
REG_HSYNC1      equ #30203C
REG_VCYCLE      equ #302040
REG_VOFFSET     equ #302044
REG_VSIZE       equ #302048
REG_VSYNC0      equ #30204C
REG_VSYNC1      equ #302050
REG_DLSWAP      equ #302054             ; 0 — отложенная смена списка выполнена
REG_CSPREAD     equ #302068
REG_PCLK_POL    equ #30206C
REG_PCLK        equ #302070             ; делитель частоты точек, 0 — вывод стоит
REG_CMD_READ    equ #3020F8             ; докуда сопроцессор выполнил очередь
REG_CMD_WRITE   equ #3020FC             ; докуда очередь записана
REG_CMDB_SPACE  equ #302574             ; сколько байтов свободно в очереди
REG_CMDB_WRITE  equ #302578             ; запись сюда дописывает очередь

; команды хоста
HOST_ACTIVE     equ #00
HOST_SLEEP      equ #42
HOST_CLKEXT     equ #44
HOST_CLKSEL     equ #61
HOST_RST_PULSE  equ #68
FT_CLK_MUL      equ 8                   ; частота FT812: x8 = 64 МГц

; команды сопроцессора
CMD_INFLATE     equ #FFFFFF22

FT_BOOT_FRAMES  equ 50                  ; до 1 с ждать ответа чипа
FT_IDLE_FRAMES  equ 250                 ; до 5 с на работу сопроцессора
FT_IDLE_POLLS   equ 32                  ; опросов за кадр при ожидании

; --- SPI ------------------------------------------------------------------------------
FT_Select:
        ld a,SPI_FT812
        out (SPI_CTRL),a
        ret

FT_Deselect:
        ld a,SPI_IDLE
        out (SPI_CTRL),a
        ret

; Команда хоста A с параметром C.
FT_Host:
        push af
        call FT_Select
        pop af
        out (SPI_DATA),a                ; код команды
        ld a,c
        out (SPI_DATA),a                ; параметр
        xor a
        out (SPI_DATA),a                ; третий байт всегда 0
        jp FT_Deselect

; Начать запись в регистр: HL — младшие 16 бит адреса #30xxxx. Чип остаётся
; выбранным: дальше идут байты данных и FT_Deselect.
FT_WriteReg:
        call FT_Select
        ld a,#80 | ((FT_RAM_REG >> 16) & #3F)   ; #B0: биты адреса 21..16 и «запись»
        out (SPI_DATA),a
        ld a,h
        out (SPI_DATA),a
        ld a,l
        out (SPI_DATA),a
        ret

; Записать байт E в регистр HL.
FT_Wr8:
        call FT_WriteReg
        ld a,e
        out (SPI_DATA),a
        jp FT_Deselect

; Записать 16 бит DE в регистр HL (младшим байтом вперёд).
FT_Wr16:
        call FT_WriteReg
        ld a,e
        out (SPI_DATA),a
        ld a,d
        out (SPI_DATA),a
        jp FT_Deselect

; Прочитать 16 бит регистра HL. Выход: HL.
FT_Rd16:
        call FT_Select
        ld a,#3F & (FT_RAM_REG >> 16)   ; #30: старшие биты 00 — чтение
        out (SPI_DATA),a
        ld a,h
        out (SPI_DATA),a
        ld a,l
        out (SPI_DATA),a
        out (SPI_DATA),a                ; пустой байт: чип готовит данные
        in a,(SPI_DATA)                 ; ответ на пустой байт — не нужен
        in a,(SPI_DATA)
        ld l,a                          ; младший байт
        in a,(SPI_DATA)
        ld h,a                          ; старший байт
        jp FT_Deselect

; Подождать B кадров.
FT_Frames:
        push bc
        call Saver_Frame
        pop bc
        djnz FT_Frames
        ret

; --- запуск -----------------------------------------------------------------------------
; Запустить FT812 в режиме 1024x768@59. Выход: CF=1 — чипа нет (платы VDAC2
; нет или она не ответила): REG_ID так и не стал #7C.
FT_Boot:
        ld a,HOST_RST_PULSE             ; сброс ядра чипа
        ld c,0
        call FT_Host
        ld b,18
        call FT_Frames
        ld a,HOST_CLKEXT                ; тактирование от внешнего генератора
        ld c,0
        call FT_Host
        ld b,6
        call FT_Frames
        ld a,HOST_SLEEP
        ld c,0
        call FT_Host
        ld b,6
        call FT_Frames
        ld a,HOST_CLKSEL                ; множитель частоты; #C0 — диапазон PLL
        ld c,FT_CLK_MUL | #C0
        call FT_Host
        ld a,HOST_ACTIVE
        ld c,0
        call FT_Host
        ld a,HOST_ACTIVE
        call FT_Host
        ld b,6
        call FT_Frames
        ld b,FT_BOOT_FRAMES
.wait_id:
        push bc
        ld hl,REG_ID & #FFFF
        call FT_Rd16
        pop bc
        ld a,l
        cp #7C
        jr z,.ready
        push bc
        call Saver_Frame
        pop bc
        djnz .wait_id
        scf                             ; не ответил — платы нет
        ret
.ready:
        ld hl,REG_PCLK & #FFFF          ; вывод стоит, пока задаются тайминги
        ld e,0
        call FT_Wr8
        ld hl,FtModeTable
.mode:
        ld e,(hl)
        inc hl
        ld d,(hl)                       ; DE — регистр (младшие 16 бит)
        inc hl
        ld a,d
        or e
        jr z,.mode_done                 ; ноль — конец таблицы
        ld c,(hl)
        inc hl
        ld b,(hl)                       ; BC — значение
        inc hl
        push hl
        ex de,hl                        ; HL — регистр
        ld d,b
        ld e,c                          ; DE — значение
        call FT_Wr16
        pop hl
        jr .mode
.mode_done:
        ld hl,REG_PCLK_POL & #FFFF
        ld e,0
        call FT_Wr8
        ld hl,REG_CSPREAD & #FFFF       ; без «размазывания» тактов по цветам
        ld e,0
        call FT_Wr8
        ld hl,REG_PCLK & #FFFF          ; делитель 1: 64 МГц, вывод пошёл
        ld e,1
        call FT_Wr8
        or a                            ; CF=0 — чип готов
        ret

; Тайминги 1024x768@59: пары «регистр, значение», в конце ноль.
; Строка: 24 точки до синхроимпульса, импульс 136, 160 после, 1024 видимых.
; Кадр: 3 строки до синхроимпульса, импульс 6, 29 после, 768 видимых.
FtModeTable:
        dw REG_HSYNC0 & #FFFF, 24
        dw REG_HSYNC1 & #FFFF, 24+136
        dw REG_HOFFSET & #FFFF, 24+136+160
        dw REG_HSIZE & #FFFF, 1024
        dw REG_HCYCLE & #FFFF, 24+136+160+1024
        dw REG_VSYNC0 & #FFFF, 3-1
        dw REG_VSYNC1 & #FFFF, 3+6-1
        dw REG_VOFFSET & #FFFF, 3+6+29-1
        dw REG_VSIZE & #FFFF, 768
        dw REG_VCYCLE & #FFFF, 3+6+29+768
        dw 0

; --- очередь сопроцессора ----------------------------------------------------------------
; Команды пишутся одной длинной посылкой в REG_CMDB_WRITE: чип сам дописывает
; их в свою очередь. Больше, чем в очереди свободно, писать нельзя, поэтому
; CmdSpace считает остаток; когда он кончается, посылка закрывается, чип
; спрашивается о свободном месте (REG_CMDB_SPACE) и посылка открывается снова.
; Каждая посылка — целое число 4-байтовых слов: свободное место чип сообщает
; кратным четырём.

; Начать поток команд. Посылка откроется при первой записи.
Cmd_Begin:
        ld hl,0
        ld (CmdSpace),hl
        ret

; Закрыть посылку (всё записанное уже в очереди чипа).
Cmd_End:
        jp FT_Deselect

; Дождаться места в очереди и открыть посылку. Выход: CmdSpace > 0.
; Сохраняет DE. Ошибка сопроцессора или ограниченный таймаут устанавливают
; FtFault; последующие слова и блоки не передаются. SPI остаётся свободной.
Cmd_Wait:
        push de
        call FT_Deselect
        ld bc,16384                     ; ограниченное ожидание, без вечного цикла
.poll:
        push bc
        ld hl,REG_CMDB_SPACE & #FFFF
        call FT_Rd16
        pop bc
        bit 0,l                         ; некратный четырём SPACE — ошибка FIFO
        jr nz,.fault
        ld a,h
        and #0F                         ; место — 12-битное число
        ld h,a
        ld a,l
        and #FC                         ; кратно 4 байтам
        ld l,a
        or h
        jr nz,.got
        dec bc
        ld a,b
        or c
        jr nz,.poll
.fault:
        ld a,1
        ld (FtFault),a                  ; очередь стоит — чип не работает
        pop de
        ret
.got:
        ld (CmdSpace),hl
        ld hl,REG_CMDB_WRITE & #FFFF
        call FT_WriteReg
        pop de
        ret

; Дописать 32-битное слово DE:HL (D — старший байт) в очередь.
Cmd_Word:
        ld a,(FtFault)
        or a
        ret nz
        push hl
        ld hl,(CmdSpace)
        ld a,h
        or a
        jr nz,.room                     ; мест больше 255
        ld a,l
        cp 4
        jr nc,.room
        call Cmd_Wait
        ld a,(FtFault)
        or a
        jr z,.available
        pop hl
        ret
.available:
        ld hl,(CmdSpace)
.room:
        ld bc,-4
        add hl,bc
        ld (CmdSpace),hl
        pop hl
        ld a,l
        out (SPI_DATA),a                ; младшим байтом вперёд
        ld a,h
        out (SPI_DATA),a
        ld a,e
        out (SPI_DATA),a
        ld a,d
        out (SPI_DATA),a
        ret

; Дописать в очередь BC байтов с адреса HL. Байты уходят кусками не больше
; свободного места и не больше 256 (столько за раз передаёт OTIR).
Cmd_Block:
        ld a,(FtFault)
        or a
        ret nz
        ld (BlkLeft),bc
.chunk:
        ld a,(FtFault)
        or a
        ret nz
        ld bc,(BlkLeft)
        ld a,b
        or c
        ret z                           ; всё передано
        ld de,(CmdSpace)
        ld a,d
        or e
        jr nz,.room
        push hl
        call Cmd_Wait
        pop hl
        jr .chunk
.room:
        ; кусок = меньшее из «осталось», «свободно» и 256
        ex de,hl                        ; HL — свободно, DE — адрес данных
        or a
        sbc hl,bc
        add hl,bc                       ; флаги от «свободно - осталось»
        jr c,.by_space                  ; свободно меньше, чем осталось
        ld h,b
        ld l,c                          ; кусок = осталось
.by_space:
        ld a,h
        or a
        jr z,.small
        ld hl,256                       ; не больше 256 за раз
.small:
        ; HL — длина куска (1..256): вычесть из «осталось» и «свободно»
        push hl
        ld b,h
        ld c,l
        ld hl,(BlkLeft)
        or a
        sbc hl,bc
        ld (BlkLeft),hl
        ld hl,(CmdSpace)
        or a
        sbc hl,bc
        ld (CmdSpace),hl
        pop bc                          ; BC — длина куска
        ex de,hl                        ; HL — адрес данных
        ld b,c                          ; OTIR: B — счётчик (0 = 256)
        ld c,SPI_DATA
        otir                            ; байт (HL) -> порт, HL+1, B-1, пока B не 0
        jr .chunk

; Ждать, пока сопроцессор выполнит всё записанное (READ = WRITE).
; Выход: CF=1 — сопроцессор сообщил об ошибке (READ = #FFF) или не успел.
FT_WaitIdle:
        call FT_Deselect
        ld b,FT_IDLE_FRAMES
.frame:
        push bc
        ld b,FT_IDLE_POLLS
.poll:
        push bc
        ld hl,REG_CMD_READ & #FFFF
        call FT_Rd16
        ld a,h
        and #0F
        ld h,a
        push hl
        ld hl,REG_CMD_WRITE & #FFFF
        call FT_Rd16
        ld a,h
        and #0F
        ld h,a
        pop de                          ; DE — READ, HL — WRITE
        pop bc
        ld a,d
        cp #0F
        jr nz,.no_fault
        ld a,e
        cp #FF
        jr z,.fault                     ; #FFF — ошибка сопроцессора
.no_fault:
        or a
        sbc hl,de
        jr z,.idle
        djnz .poll
        call Saver_Frame
        pop bc
        djnz .frame
        scf                             ; не успел
        ret
.fault:
        pop bc
        scf
        ret
.idle:
        pop bc
        or a
        ret

; --- ресурсы ------------------------------------------------------------------------------
; Загрузить шрифты и иконки в RAM_G: команда CMD_INFLATE с адресом 0 и следом
; сжатый zlib поток из страниц плагина (отрезки AssetSegments, assets.inc) —
; распаковывает сам сопроцессор. Выход: CF=1 — не получилось.
FT_LoadAssets:
        xor a
        ld (FtFault),a
        call Cmd_Begin
        ld hl,CMD_INFLATE & #FFFF
        ld de,#FFFF & (CMD_INFLATE >> 16)
        call Cmd_Word
        ld hl,0                         ; распаковать с адреса 0 RAM_G
        ld d,h
        ld e,l
        call Cmd_Word
        ld hl,AssetSegments
.segment:
        ld a,(hl)
        cp #FF
        jr z,.segments_done
        inc hl
        call Data_Page                  ; страница отрезка -> #0000
        ld e,(hl)
        inc hl
        ld d,(hl)                       ; DE — адрес в окне
        inc hl
        ld c,(hl)
        inc hl
        ld b,(hl)                       ; BC — длина
        inc hl
        push hl
        ex de,hl
        call Cmd_Block
        pop hl
        jr .segment
.segments_done:
        IF ASSET_PAD
        ld hl,AssetPad                  ; добить поток до целых слов
        ld bc,ASSET_PAD
        call Cmd_Block
        ENDIF
        call Cmd_End
        ld a,(FtFault)
        or a
        scf
        ret nz
        jp FT_WaitIdle

AssetPad:       db 0,0,0
CmdSpace:       dw 0                    ; сколько байтов ещё влезет в очередь
BlkLeft:        dw 0                    ; сколько байтов блока осталось передать
FtFault:        db 0                    ; 1 — очередь FT812 так и не освободилась
