;========================================================================
; UNZIP.WMF — распаковщик ZIP-архивов для Wild Commander Improved
;========================================================================
;
; ЧТО ДЕЛАЕТ ПЛАГИН
; -----------------
; Пользователь нажимает Enter на файле .ZIP — Wild Commander (дальше WC)
; загружает плагин и вызывает его. Плагин извлекает все файлы архива в
; текущий каталог активной панели, создавая вложенные каталоги. Если файл
; с таким именем уже есть, задаётся вопрос Yes/No/All/Cancel. Каждый файл
; сначала пишется во временный файл WCUZnn0.$$$ и только после проверки
; размера и контрольной суммы CRC32 получает настоящее имя — так
; оборванная распаковка не портит уже существующие файлы.
;
; КАК УСТРОЕН ZIP (то, что нужно здесь)
; ------------------------------------
; Архив — это подряд записанные файлы. Перед данными каждого файла стоит
; «локальный заголовок» (сигнатура PK 03 04, метод сжатия, CRC32, размеры,
; имя). После данных может идти «data descriptor» (PK 07 08, CRC, размеры) —
; так делают упаковщики, которые пишут архив потоком и узнают размеры
; только в конце. В самом конце архива лежит «центральный каталог»
; (PK 01 02) и запись «конец центрального каталога» EOCD (PK 05 06), где
; указано общее число файлов. Плагин читает архив от начала к концу и
; останавливается на центральном каталоге.
; Поддерживаются методы 0 (Stored — без сжатия) и 8 (Deflate).
;
; ПАМЯТЬ
; ------
; Процессор Z80 видит 64 КиБ адресов, поделённых на четыре «окна» по
; 16 КиБ. В каждое окно WC может подставить любую страницу памяти:
;   #0000..#3FFF — страница плагина 1: младшие 16 КиБ истории Deflate;
;   #4000..#7FFF — рабочая область самого WC (сюда не пишем);
;   #8000..#BFFF — страница плагина 0: этот код, переменные и буферы;
;   #C000..#FFFF — страница плагина 2: старшие 16 КиБ истории Deflate.
; Файловые функции WC принимают буферы только из #4000..#BFFF, поэтому
; все буферы для чтения и записи лежат в нашей странице #8000..#BFFF.
;
; ПОТОКИ WC
; ---------
; У WC есть два «потока» — как два независимых открытых файла со своими
; текущими каталогами. Поток 0 читает архив, поток 1 указывает на каталог,
; куда извлекаются файлы. Переключение: функция STREAM (57).
;
; ЧИСЛА В ПАМЯТИ
; --------------
; Размеры в ZIP 32-битные, а регистры Z80 16-битные, поэтому 32-битные
; числа лежат в памяти по 4 байта, младший байт первым (так же, как в
; самом ZIP). Для них есть процедуры add32, sub32, cmp32 и т. д.
;
; ФЛАГИ
; -----
; Процедуры сообщают результат флагами процессора:
;   C (перенос) = 1 — ошибка (код ошибки уже записан в error_code);
;   Z (ноль)       — «равно»/«найдено»/«нет» — смотрите описание процедуры.
; Функции WC возвращают флаги по своему описанию (READ_ME.TXT плагинов).

                DEVICE ZXSPECTRUM128
                ORG #8000               ; WC вызывает плагин по адресу #8000

WCAPI           EQU #6006               ; единая точка вызова функций WC:
                                        ; номер функции — в A, CALL #6006
INPUT_SIZE      EQU 1024                ; окно чтения архива: два сектора
STAGING_SIZE    EQU 2048                ; буфер записи на карту: четыре сектора
PATH_SIZE       EQU 384                 ; полный путь файла внутри архива
NAME_SIZE       EQU 256                 ; одно имя (компонент пути)
UI_WIDTH        EQU 58                  ; ширина строки в окне плагина
BAR_WIDTH       EQU 54                  ; ширина полосы индикатора
BAR_FILLED      EQU #DB                 ; символ заполненной клетки полосы
BAR_EMPTY       EQU #B1                 ; символ пустой клетки полосы
FILEX_BLOCK_SIZE EQU 32                 ; размер блока запроса к FILEX
EOCD_SIZE       EQU 22                  ; размер записи EOCD без комментария
EOCD_SEARCH_SIZE EQU 65557              ; EOCD ищется в последних 22+65535 байтах
METHOD_STORED   EQU 0                   ; метод ZIP «без сжатия»
METHOD_DEFLATE  EQU 8                   ; метод ZIP «Deflate»

; Коды ошибок (порядок и тексты — как в прежней версии на C)
ERR_NONE        EQU 0
ERR_IO          EQU 1                   ; не читается архив
ERR_TRUNCATED   EQU 2                   ; архив обрезан
ERR_NOT_ZIP     EQU 3                   ; это не ZIP
ERR_ENCRYPTED   EQU 4                   ; архив зашифрован
ERR_METHOD      EQU 5                   ; неизвестный метод сжатия
ERR_ZIP64       EQU 6                   ; ZIP64 (файлы > 4 ГиБ) не поддержан
ERR_NAME        EQU 7                   ; плохое или слишком длинное имя
ERR_PATH        EQU 8                   ; опасный путь («..» и т. п.)
ERR_STREAMED_STORED EQU 9               ; Stored без известного размера
ERR_DEFLATE     EQU 10                  ; испорченный поток Deflate
ERR_CRC         EQU 11                  ; не сошлась контрольная сумма
ERR_SIZE        EQU 12                  ; не сошёлся размер
ERR_DIRECTORY   EQU 13                  ; не создаётся каталог
ERR_CREATE      EQU 14                  ; не создаётся файл
ERR_WRITE       EQU 15                  ; не пишется файл
ERR_RENAME      EQU 16                  ; не удалось переименовать
ERR_SELF        EQU 17                  ; архив затёр бы сам себя
ERR_CANCELLED   EQU 18                  ; пользователь нажал Esc

; Ответы на вопрос «заменить файл?»
REPLACE_CANCEL  EQU 0
REPLACE_YES     EQU 1
REPLACE_NO      EQU 2
REPLACE_ALL     EQU 3

;========================================================================
; ВХОД В ПЛАГИН
;========================================================================
; WC передаёт: [DE,HL] — длина файла архива (DE — старшие 16 бит),
; BC — адрес имени файла, IX — адрес структуры активной панели (IX надо
; вернуть неизменным). На выходе A — код для WC: 0 — ничего не менялось,
; 3 — перечитать панели (мы создали файлы).
plugin_entry:
                push ix                 ; сохранить IX до самого выхода
                ld (saved_panel_ix),ix
                ld (archive_size),hl    ; длина архива — 4 байта в памяти
                ld (archive_size+2),de
                ld (archive_name_ptr),bc
                call plugin_main
                pop ix
                ret

plugin_main:
                call copy_archive_name  ; имя архива — в свой буфер
                call reset_state        ; все переменные — в исходное состояние
                call initialise_window  ; описание окна «ZIP unpacker»
                call crc32_init         ; таблица для контрольной суммы
                ld a,15                 ; GEDPL: включить основной текстовый экран
                call WCAPI
                call wc_show_window     ; нарисовать окно
                call ui_draw_percent    ; «000%» и пустая полоса
                ld hl,archive_name
                call ui_draw_name       ; «unziping: имя архива»
                call prepare_streams    ; открыть архив в потоке 0
                jr c,.finish
                ld a,1                  ; подставить страницы истории Deflate:
                call wc_map_page_0000   ; страница 1 — в окно #0000,
                ld a,2
                call wc_map_page_c000   ; страница 2 — в окно #C000
                call extract_archive    ; главная работа
.finish:        call cleanup_temp       ; удалить недописанный временный файл
                call return_to_base     ; поток 1 — в исходный каталог
                ld a,(error_code)
                or a
                jr nz,.failed
                ld a,(changed_directory)
                or a
                call nz,ui_finish       ; «100% done»
                jr .close
.failed:        call ui_error           ; сообщение об ошибке и ожидание клавиши
.close:         call wc_close_window
                ld a,15                 ; GEDPL ещё раз — вернуть экран WC
                call WCAPI
                ; Код 3 просит WC перечитать панели уже после того, как он
                ; сам восстановит свои страницы и стек.
                ld a,(changed_directory)
                or a
                ret z
                ld a,3
                ret

; Скопировать имя архива (строка с нулём в конце) в archive_name.
copy_archive_name:
                ld hl,(archive_name_ptr)
                ld de,archive_name
                ld bc,NAME_SIZE-1       ; не больше 255 символов
1               ld a,(hl)
                or a
                jr z,2F                 ; ноль — конец строки
                ld (de),a
                inc hl
                inc de
                dec bc
                ld a,b
                or c
                jr nz,1B
2               xor a
                ld (de),a               ; завершающий ноль
                ret

; Привести все переменные распаковки в исходное состояние.
reset_state:
                ld hl,state_begin       ; обнулить область state_begin..state_end:
                ld de,state_begin+1     ; первый байт = 0, затем LDIR
                ld bc,state_end-state_begin-1 ; «размножает» его на всю область
                ld (hl),0
                ldir
                ld hl,INPUT_SIZE        ; окно входа пусто: первая же попытка
                ld (input_index),hl     ; чтения загрузит сектора
                ld a,#FF
                ld (progress_drawn),a   ; процент ещё ни разу не рисовался
                ; Для индикатора: progress_quotient = размер архива / 100,
                ; progress_remainder = остаток. Порог для k процентов потом
                ; считается как quotient*k + округлённое вверх remainder*k/100.
                ld hl,archive_size
                ld de,progress_quotient
                call copy32
                ld hl,progress_quotient
                ld a,100
                call div32_8
                ld (progress_remainder),a
                ret

; Заполнить описание окна (18 байт) для функций WC PRWOW/PRSRW/RRESB:
; тень и двойная рамка как у ChkDsk, 64×9 знакомест, синий фон, белый текст.
initialise_window:
                ld hl,unzip_window      ; сначала всё нулями
                ld de,unzip_window+1
                ld bc,17
                ld (hl),0
                ldir
                ld hl,unzip_window
                ld (hl),#81             ; +0: тень и двойная рамка
                inc hl
                inc hl
                ld (hl),#FF             ; +2, +3: окно по центру экрана
                inc hl
                ld (hl),#FF
                inc hl
                ld (hl),64              ; +4: ширина
                inc hl
                ld (hl),9               ; +5: высота
                inc hl
                ld (hl),#1F             ; +6: цвет — синий фон, ярко-белый текст
                ld hl,window_title      ; +12: адрес заголовка окна
                ld (unzip_window+12),hl
                ret

;========================================================================
; ОБЁРТКИ ФУНКЦИЙ WC
;========================================================================
; Каждая функция WC вызывается так: номер в A, остальные параметры — по её
; описанию, затем CALL #6006. Обёртки дают функциям понятные имена.

wc_select_stream:                       ; STREAM: сделать активным поток A (0 или 1)
                ld d,a
                ld bc,#FFFF             ; BC=#FFFF — «включить существующий поток»
                ld a,57
                jp WCAPI

wc_clone_streams:                       ; STREAM: скопировать поток панели в потоки 0 и 1
                ld d,#FE
                ld a,57
                jp WCAPI

wc_load_sectors:                        ; LOAD512: прочитать B секторов в HL; C=1 — ошибка
                ld a,48
                jp WCAPI

wc_save_sectors:                        ; SAVE512: записать B секторов из HL; C=1 — ошибка
                ld a,49
                jp WCAPI

wc_fentry:                              ; FENTRY: найти файл/каталог; NZ — найден
                ld a,59                 ; (HL — тип #00/#10 и имя, см. make_query)
                jp WCAPI

wc_gfile:       ld a,62                 ; GFILE: встать на начало найденного файла
                jp WCAPI

wc_gdir:        ld a,63                 ; GDIR: войти в найденный каталог
                jp WCAPI

wc_mkfile:                              ; MKfile: создать файл; Z — создан, A — код ошибки
                ld a,72
                jp WCAPI

wc_mkdir:                               ; MKdir: создать каталог; Z — создан
                ld a,73
                jp WCAPI

wc_delete:                              ; DelFl: удалить; NZ — удалён
                ld a,75
                jp WCAPI

wc_rename:                              ; REName: HL — старое имя с типом,
                ld a,74                 ; DE — новое имя; NZ — успех
                jp WCAPI

wc_append:                              ; APPEND: дописать BC байт из HL в конец
                ld a,76                 ; последнего найденного файла; Z — успех
                jp WCAPI

wc_filex:                               ; FILEX: чтение по смещению; A=0 — успех
                ld a,77
                jp WCAPI

; Номер страницы для этих двух функций WC ждёт в «теневом» A' — команда
; EX AF,AF' меняет A с A' местами.
wc_map_page_0000:                       ; MNG0_PL: страница плагина A — в окно #0000
                ex af,af'
                ld a,78
                jp WCAPI

wc_map_page_c000:                       ; MNGC_PL: страница плагина A — в окно #C000
                ex af,af'
                xor a
                jp WCAPI

; Функции вывода текста подставляют в #C000 текстовый экран WC. После них
; надо вернуть туда страницу истории Deflate.
restore_history_mapping:
                ld a,2
                jr wc_map_page_c000

wc_show_window:                         ; PRWOW: нарисовать окно
                ld ix,unzip_window
                ld a,1
                jp WCAPI

wc_close_window:                        ; RRESB: убрать окно, вернуть фон
                ld ix,unzip_window
                ld a,2
                jp WCAPI

wc_print:                               ; PRSRW: HL — текст, BC — длина,
                ld ix,unzip_window      ; D — строка, E — столбец в окне
                ld a,3
                jp WCAPI

wc_enter:       ld a,22                 ; нажат Enter? NZ — да
                jp WCAPI

wc_escape:      ld a,23                 ; нажат Esc? NZ — да
                jp WCAPI

wc_scan_key:                            ; KBSCN: A — код нажатой клавиши (0 — нет)
                ld a,1                  ; A'=1: код из основной таблицы
                ex af,af'
                ld a,42
                jp WCAPI

wc_any_key:     ld a,45                 ; нажата любая клавиша? NZ — да
                jp WCAPI

wc_wait_key_release:                    ; ждать, пока все клавиши отпустят
                ld a,46
                jp WCAPI

; Подождать один кадр (1/50 с). Тест плагина в эмуляторе подменяет эту
; процедуру одной командой RET: там нет прерываний.
wc_wait_frame:
                ei
                halt
                ret

;========================================================================
; ОШИБКИ
;========================================================================
; Запомнить код ошибки A. Сохраняется только ПЕРВАЯ ошибка — она и есть
; причина, остальные обычно её следствия.
set_error:
                ld c,a
                ld a,(error_code)
                or a
                jr nz,1F                ; ошибка уже есть — не перезаписывать
                ld a,c
                ld (error_code),a
1               ld a,1
                ld (zip_error),a
                ret

; То же, но с выходом C=1: «jp fail_with» — короткий способ сообщить
; об ошибке и вернуться из процедуры.
fail_with:
                call set_error
                scf
                ret

; Вызывается ядром Deflate, если распаковка невозможна. Если ядро упёрлось
; в ошибку чтения карты, которую мы отложили (pending_error), причина —
; она; иначе испорчен сам поток Deflate.
core_fail:
                ld a,(pending_error)
                or a
                jr nz,set_error
                ld a,ERR_DEFLATE
                jr set_error

;========================================================================
; 32-БИТНАЯ АРИФМЕТИКА НАД ПАМЯТЬЮ
;========================================================================
; Числа по 4 байта, младший байт первым. Сложение и вычитание идут байт за
; байтом от младшего к старшему с учётом переноса (ADC/SBC).

add32:                                  ; (HL) += (DE)
                ld b,4
                or a                    ; перенос = 0 перед первым байтом
1               ld a,(de)
                adc a,(hl)
                ld (hl),a
                inc hl
                inc de
                djnz 1B
                ret

sub32:                                  ; (HL) -= (DE); C=1 — результат < 0
                ld b,4                  ; портит BC
                or a
1               ld a,(de)
                ld c,a
                ld a,(hl)
                sbc a,c
                ld (hl),a
                inc hl
                inc de
                djnz 1B
                ret

; Сравнить (HL) и (DE) как беззнаковые 32-битные числа.
; Выход: C=1 — (HL) меньше; иначе Z=1 — равны, Z=0 — (HL) больше.
; Сохраняет HL и DE; портит A, BC.
cmp32:
                push hl
                push de
                ld b,4
                xor a
                ld (cmp_flag),a         ; 1 — какой-то байт разности не ноль
1               ld a,(de)               ; вычитаем без записи результата
                ld c,a
                ld a,(hl)
                sbc a,c
                jr z,2F
                ld a,1
                ld (cmp_flag),a
2               inc hl
                inc de
                djnz 1B
                jr c,.less              ; последний заём — (HL) меньше
                ld a,(cmp_flag)
                or a                    ; Z — все байты разности нули
                pop de
                pop hl
                ret
.less:          ld a,1
                or a                    ; Z=0
                scf                     ; C=1
                pop de
                pop hl
                ret

add32_bc:                               ; (HL) += BC (16-битное)
                ld a,(hl)
                add a,c
                ld (hl),a
                inc hl
                ld a,(hl)
                adc a,b
                ld (hl),a
                inc hl
                ld a,(hl)
                adc a,0                 ; перенос в старшие байты
                ld (hl),a
                inc hl
                ld a,(hl)
                adc a,0
                ld (hl),a
                ret

copy32:                                 ; (DE) = (HL); портит BC
                ld bc,4
                ldir
                ret

zero32:                                 ; (HL) = 0; портит A
                xor a
                ld (hl),a
                inc hl
                ld (hl),a
                inc hl
                ld (hl),a
                inc hl
                ld (hl),a
                ret

is_zero32:                              ; Z=1 — (HL) равно нулю
                ld a,(hl)
                inc hl
                or (hl)
                inc hl
                or (hl)
                inc hl
                or (hl)
                ret

inc32:                                  ; (HL) += 1
                inc (hl)
                ret nz                  ; не переполнился — готово
                inc hl
                inc (hl)
                ret nz
                inc hl
                inc (hl)
                ret nz
                inc hl
                inc (hl)
                ret

; (HL) = (HL) / A, остаток — в A. Деление «в столбик» по одному биту:
; число сдвигается влево, выдвинутый бит попадает в остаток; если остаток
; стал не меньше делителя — вычитаем делитель и пишем 1 в частное.
div32_8:
                ld e,a                  ; E — делитель
                ld d,0                  ; D — остаток
                ld b,32                 ; 32 бита числа
.bit:           or a                    ; число << 1, старший бит — во флаг C
                rl (hl)
                inc hl
                rl (hl)
                inc hl
                rl (hl)
                inc hl
                rl (hl)
                dec hl
                dec hl
                dec hl
                ld a,d                  ; остаток = остаток*2 + бит
                rla
                ld d,a
                cp e
                jr c,.next
                sub e
                ld d,a
                inc (hl)                ; в освободившийся младший бит — 1
.next:          djnz .bit
                ld a,d
                ret

; (DE) = (HL) * A; число (HL) не меняется. Умножение «в столбик»: для
; каждого единичного бита множителя прибавляем множимое, сдвинутое на
; номер бита.
mul32_8:
                ld (mul_factor),a       ; множитель — в память: zero32 ниже портит A
                push de
                ld de,mul_tmp           ; mul_tmp — копия множимого, её
                call copy32             ; будем сдвигать
                pop hl                  ; HL = адрес результата
                push hl
                call zero32             ; результат = 0
                pop hl
                ld a,(mul_factor)
                ld b,8                  ; 8 бит множителя
.bit:           rra                     ; младший бит множителя — во флаг C
                jr nc,.skip
                push af
                push hl
                push bc
                ld de,mul_tmp
                call add32              ; результат += сдвинутое множимое
                pop bc
                pop hl
                pop af
.skip:          push af
                push hl
                ld hl,mul_tmp           ; множимое *= 2
                or a
                rl (hl)
                inc hl
                rl (hl)
                inc hl
                rl (hl)
                inc hl
                rl (hl)
                pop hl
                pop af
                djnz .bit
                ret

mul8:                                   ; HL = A * C (оба 8-битные)
                ld hl,0
                ld d,0
                ld e,c
                ld b,8
1               add hl,hl               ; результат *= 2
                rla                     ; старший бит A — во флаг C
                jr nc,2F
                add hl,de               ; бит был 1 — прибавить C
2               djnz 1B
                ret

;========================================================================
; СТРОКИ
;========================================================================
string_length:                          ; BC = длина строки HL (до нуля);
                push hl                 ; HL сохраняется
                ld bc,0
1               ld a,(hl)
                or a
                jr z,2F
                inc hl
                inc bc
                jr 1B
2               pop hl
                ret

copy_string:                            ; скопировать строку (HL) в (DE)
1               ld a,(hl)               ; вместе с завершающим нулём
                ld (de),a
                inc hl
                inc de
                or a
                jr nz,1B
                ret

upper_ascii:                            ; A: латинская буква — в заглавную
                cp "a"
                ret c
                cp "z"+1
                ret nc
                sub "a"-"A"
                ret

strings_equal_ci:                       ; сравнить строки HL и DE без учёта
1               ld a,(de)               ; регистра латиницы; Z=1 — равны
                call upper_ascii
                ld c,a
                ld a,(hl)
                call upper_ascii
                cp c
                ret nz
                or a                    ; обе строки кончились — равны
                ret z
                inc hl
                inc de
                jr 1B

; Скопировать строку HL в DE, но не больше A знакомест. Длинная строка
; показывается как «...» и её конец — конец пути важнее начала.
copy_tail:
                ld (ct_limit),a
                call string_length      ; BC = длина
                ld a,b
                or a
                jr nz,.long             ; ≥ 256 символов — точно длинная
                ld a,(ct_limit)
                cp c
                jr c,.long
                ld a,c
                or a
                ret z                   ; пустая строка
                ldir                    ; помещается целиком
                ret
.long:          ld a,"."                ; «...»
                ld (de),a
                inc de
                ld (de),a
                inc de
                ld (de),a
                inc de
                add hl,bc               ; HL — конец строки
                ld a,(ct_limit)
                sub 3                   ; сколько символов конца поместится
                ld c,a
                ld b,0
                or a
                sbc hl,bc               ; начало видимого конца
                ldir
                ret

;========================================================================
; ЧТЕНИЕ АРХИВА
;========================================================================
; Архив читается кусками по два сектора (1 КиБ) в input_buffer.
; input_index — сколько байт этого окна уже разобрано, input_valid — сколько
; байт в окне настоящих. archive_position — сколько байт архива разобрано
; всего (по нему же движется индикатор).

; Загрузить следующее окно из потока 0: до двух секторов, но не дальше
; конца файла (сектора за концом файла читать нельзя — цепочка кластеров
; файла там кончается). C=1 — ошибка.
refill_input:
                ld hl,archive_position  ; архив уже весь прочитан?
                ld de,archive_size
                call cmp32
                jr c,1F
                ld a,ERR_TRUNCATED      ; данных больше нет, а они нужны
                jr refill_failed
1               ld hl,archive_size      ; refill_tmp = сколько осталось
                ld de,refill_tmp
                call copy32
                ld hl,refill_tmp
                ld de,archive_position
                call sub32
                ld a,(refill_tmp+2)
                ld b,a
                ld a,(refill_tmp+3)
                or b
                jr nz,.two_full         ; осталось ≥ 64 КиБ
                ld hl,(refill_tmp)
                ld de,INPUT_SIZE
                or a
                sbc hl,de
                jr nc,.two_full         ; осталось ≥ 1 КиБ
                ld hl,(refill_tmp)      ; меньше 1 КиБ: окно = остаток
                ld (input_valid),hl
                ld de,512
                or a
                sbc hl,de
                jr c,.one               ; 1..511 байт — один сектор
                jr z,.one               ; ровно 512 — тоже один
                ld b,2
                jr .load
.one:           ld b,1
                jr .load
.two_full:      ld hl,INPUT_SIZE
                ld (input_valid),hl
                ld b,2
.load:          push bc
                xor a
                call wc_select_stream   ; архив читается в потоке 0
                pop bc
                ld hl,input_buffer
                call wc_load_sectors
                jr nc,2F
                ld a,ERR_IO
                jr refill_failed
2               ld hl,0
                ld (input_index),hl     ; окно начинается заново
                or a
                ret

; Ошибка при чтении архива. Если читали для разбора заголовков
; (refill_soft=0) — это сразу ошибка. Если читало ядро Deflate «про запас»
; (refill_soft=1) — ошибку откладываем: возможно, эти байты и не нужны.
refill_failed:
                ld c,a
                ld a,(refill_soft)
                or a
                ld a,c
                jr nz,1F
                jp fail_with
1               ld (pending_error),a
                scf
                ret

; Прочитать один байт архива в A. C=1 — ошибка (уже записана).
; HL, DE, BC сохраняются.
read_archive_byte:
                push hl
                push de
                push bc
                ld hl,(input_index)     ; окно кончилось?
                ld de,(input_valid)
                or a
                sbc hl,de
                jr c,1F
                xor a
                ld (refill_soft),a      ; разбор заголовка: ошибка — сразу
                call refill_input
                jr c,2F
1               ld hl,(input_index)     ; байт = input_buffer[input_index]
                ld de,input_buffer
                add hl,de
                ld a,(hl)
                ld hl,(input_index)
                inc hl
                ld (input_index),hl
                ld hl,archive_position
                call inc32
                or a
2               pop bc
                pop de
                pop hl
                ret

read_u16:                               ; BC = 16-битное число из архива
                call read_archive_byte  ; (младший байт первым); C=1 — ошибка
                ret c
                ld c,a
                call read_archive_byte
                ret c
                ld b,a
                or a
                ret

read_u32:                               ; (HL) = 32-битное число из архива
                push hl
                call read_u16
                jr c,1F
                ld (hl),c
                inc hl
                ld (hl),b
                inc hl
                call read_u16
                jr c,1F
                ld (hl),c
                inc hl
                ld (hl),b
                or a
1               pop hl
                ret

skip_bytes:                             ; пропустить BC байт архива
                ld a,b
                or c
                ret z
1               call read_archive_byte
                ret c
                dec bc
                ld a,b
                or c
                jr nz,1B
                ret

;------------------------------------------------------------------------
; Окно входа для ядра Deflate
;------------------------------------------------------------------------
; Ядро читает вход само, через in_ptr/in_end. Здесь окно — непрочитанная
; часть input_buffer, но не дальше конца сжатых данных текущего файла
; (data_limit_end), чтобы ядро не залезло в следующую запись архива.
set_input_window:
                ld hl,input_buffer      ; in_ptr = начало непрочитанного
                ld bc,(input_index)
                add hl,bc
                ld (in_ptr),hl
                ld hl,(input_valid)     ; HL = сколько байт есть в окне
                or a
                sbc hl,bc
                ld a,(data_limit_active)
                or a
                jr z,.window            ; предела нет — всё окно
                push hl
                ld hl,data_limit_end    ; refill_tmp = сколько до предела
                ld de,refill_tmp
                call copy32
                ld hl,refill_tmp
                ld de,archive_position
                call sub32
                pop hl
                jr c,.zero              ; позиция уже за пределом
                ld a,(refill_tmp+2)
                ld b,a
                ld a,(refill_tmp+3)
                or b
                jr nz,.window           ; предел дальше 64 КиБ — всё окно
                ld de,(refill_tmp)
                push hl
                or a
                sbc hl,de
                pop hl
                jr c,.window            ; в окне меньше, чем до предела
                ex de,hl                ; HL = столько, сколько до предела
                jr .window
.zero:          ld hl,0
.window:        ld de,(in_ptr)          ; in_end = in_ptr + длина
                add hl,de
                ld (in_end),hl
                ret

; Вызывается ядром, когда окно входа кончилось (IX = in_end).
; Учитываем прочитанное ядром, загружаем новое окно. C=1 — данных нет.
; Сохраняет IY (в нём счётчик бит ядра).
in_more:
                push iy
                push ix                 ; HL = новый input_index = IX − буфер
                pop hl
                ld de,input_buffer
                or a
                sbc hl,de
                ld de,(input_index)
                ld (input_index),hl
                or a
                sbc hl,de               ; сколько байт ядро взяло с прошлого раза
                ld b,h
                ld c,l
                ld hl,archive_position
                call add32_bc
                ld a,(data_limit_active) ; конец сжатых данных файла?
                or a                    ; тогда данных нет, но это не ошибка:
                jr z,1F                 ; ядро могло читать «про запас»
                ld hl,archive_position
                ld de,data_limit_end
                call cmp32
                jr c,1F
                pop iy
                scf
                ret
1               ld hl,(input_index)     ; буфер весь разобран? — загрузить
                ld de,(input_valid)
                or a
                sbc hl,de
                jr c,2F
                ld a,1
                ld (refill_soft),a      ; чтение для ядра: ошибку отложить
                call refill_input
                jr nc,2F
                pop iy
                scf
                ret
2               call set_input_window
                ld ix,(in_ptr)
                pop iy
                or a
                ret

; После работы ядра перенести его позицию (in_ptr) в наши input_index и
; archive_position.
sync_input_position:
                ld hl,(in_ptr)
                ld de,input_buffer
                or a
                sbc hl,de
                ld de,(input_index)
                ld (input_index),hl
                or a
                sbc hl,de
                ld b,h
                ld c,l
                ld hl,archive_position
                jp add32_bc

;========================================================================
; ВЫХОД: ГОТОВЫЙ КУСОК КОЛЬЦА — CRC32, ЗАПИСЬ НА КАРТУ, ИНДИКАТОР
;========================================================================
; Ядро вызывает эту процедуру для каждого готового куска (до 4 КиБ).
; Вход: HL — начало куска в кольце, BC — длина. C=1 на выходе — прервать.
;
; Запись на карту идёт одним из двух способов (write_mode):
;   0 — SAVE512: размер файла известен заранее, файл создан сразу нужной
;       длины, данные пишутся потоково целыми секторами. Это самый быстрый
;       путь: ни каталог, ни FAT на каждом куске не трогаются.
;   1 — APPEND: размер неизвестен (запись с data descriptor). Файл один раз
;       найден FENTRY, дальше куски дописываются в его конец. Прежняя
;       версия перед каждым куском снова вызывала FENTRY — и ядро WC
;       каждый раз проходило всю цепочку кластеров файла до конца; на
;       больших файлах это и было главным тормозом.
out_flush_hook:
                ld (flush_ptr),hl
                ld (flush_len),bc
                call crc32_update       ; контрольная сумма по всему куску
                ld a,(expected_size_known) ; размер известен — не дать
                or a                    ; данным его превысить (иначе запись
                jr z,.write             ; вышла бы за выделенные кластеры)
                ld hl,out_flushed
                ld de,flush_total
                call copy32
                ld hl,flush_total
                ld bc,(flush_len)
                call add32_bc           ; flush_total = отдано + этот кусок
                ld hl,expected_size
                ld de,flush_total
                call cmp32
                jr nc,.write
                ld a,ERR_SIZE
                jp fail_with
.write:         ld a,(discard_output)   ; файл пропускается (ответ No) —
                or a                    ; ничего не пишем
                jr nz,.progress
.piece:         ld bc,(flush_len)       ; сколько ещё осталось записать
                ld a,b
                or c
                jr z,.progress
                ld hl,STAGING_SIZE      ; кусок не больше буфера записи
                or a
                sbc hl,bc
                jr nc,1F
                ld bc,STAGING_SIZE
1               ld (flush_piece),bc
                ld hl,(flush_ptr)       ; из кольца — в буфер записи: файловые
                ld de,staging_buffer    ; функции WC берут данные только
                ldir                    ; из #4000..#BFFF
                ld (flush_ptr),hl
                ld hl,(flush_len)
                ld bc,(flush_piece)
                or a
                sbc hl,bc
                ld (flush_len),hl
                ld a,1                  ; файлы пишутся в потоке 1
                call wc_select_stream
                ld a,(write_mode)
                or a
                jr nz,.append
                ld hl,(flush_piece)     ; SAVE512 пишет целыми секторами:
                ld de,511               ; секторов = (кусок + 511) / 512.
                add hl,de               ; Хвост последнего сектора файла —
                ld a,h                  ; мусор, но он за концом файла и
                srl a                   ; не виден: размер уже записан
                ld b,a
                ld hl,staging_buffer
                call wc_save_sectors
                jr c,.write_failed
                jr .piece
.append:        ld hl,staging_buffer
                ld bc,(flush_piece)
                call wc_append
                jr nz,.write_failed
                jr .piece
.write_failed:  ld a,ERR_WRITE
                jp fail_with
.progress:      ld a,(discard_output)
                or a
                jr z,2F
                ; При ответе No распаковка идёт только в кольцо (нужно, чтобы
                ; найти конец записи): индикатор её не показывает, но Esc
                ; по-прежнему работает.
                call wc_escape
                jr nz,3F
                or a
                ret
3               ld a,ERR_CANCELLED
                jp fail_with
2               xor a
                jp ui_update            ; C=1 — нажат Esc

;========================================================================
; CRC32
;========================================================================
; Контрольная сумма ZIP — CRC32 (многочлен #EDB88320). Побитовый расчёт —
; 8 шагов на байт; табличный — один шаг: crc = T[(crc xor байт) and #FF]
; xor (crc >> 8). Таблица из 256 четырёхбайтовых чисел хранится как четыре
; «плоскости» по 256 байт (CRC_T0 — младшие байты чисел, ... CRC_T3 —
; старшие): так номер ячейки — это просто младший байт адреса.

; Построить таблицу: T[i] = CRC от одного байта i.
crc32_init:
                ld l,0                  ; L — номер ячейки i
.entry:         ld h,high CRC_T0
                ld e,l                  ; crc = i (E — младший байт,
                ld d,0                  ; затем D, C, B — старший)
                ld c,0
                ld b,0
                ld a,8                  ; 8 шагов по одному биту
.round:         srl b                   ; crc >>= 1, выпавший бит — во флаг C
                rr c
                rr d
                rr e
                jr nc,1F
                push af
                ld a,e                  ; бит был 1: crc ^= #EDB88320
                xor #20
                ld e,a
                ld a,d
                xor #83
                ld d,a
                ld a,c
                xor #B8
                ld c,a
                ld a,b
                xor #ED
                ld b,a
                pop af
1               dec a
                jr nz,.round
                ld (hl),e               ; разложить число по четырём плоскостям
                inc h
                ld (hl),d
                inc h
                ld (hl),c
                inc h
                ld (hl),b
                inc l
                jr nz,.entry            ; все 256 ячеек
                ret

; Один байт CRC. Текущая сумма: E — младший байт, D, IYl, IYh — старший.
; HL — адрес байта данных, B и C портятся.
                MACRO CRC_BYTE
                ld a,(hl)               ; номер ячейки = (crc xor байт) and #FF
                xor e
                ld c,a
                ld b,high CRC_T0
                ld a,(bc)               ; новый байт 0 = T0[n] xor старый байт 1
                xor d
                ld e,a
                inc b
                ld a,(bc)               ; новый байт 1 = T1[n] xor старый байт 2
                xor iyl
                ld d,a
                inc b
                ld a,(bc)               ; новый байт 2 = T2[n] xor старый байт 3
                xor iyh
                ld iyl,a
                inc b
                ld a,(bc)               ; новый байт 3 = T3[n]
                ld iyh,a
                inc hl
                ENDM

; Добавить к running_crc BC байт с адреса HL. Портит все регистры.
; Основной цикл обрабатывает по 8 байт за проход (меньше команд перехода).
crc32_update:
                ld a,b
                or c
                ret z
                ld a,c                  ; остаток от деления длины на 8
                and 7
                ld (crc_tail),a
                srl b                   ; BC = число полных восьмёрок
                rr c
                srl b
                rr c
                srl b
                rr c
                push bc
                pop ix                  ; счётчик восьмёрок — в IX
                ld de,(running_crc)     ; сумма — в регистры
                ld iy,(running_crc+2)
                ld a,b
                or c
                jp z,.tail
.block:         CRC_BYTE
                CRC_BYTE
                CRC_BYTE
                CRC_BYTE
                CRC_BYTE
                CRC_BYTE
                CRC_BYTE
                CRC_BYTE
                dec ix
                ld a,ixh
                or ixl
                jp nz,.block
.tail:          ld a,(crc_tail)         ; оставшиеся 0..7 байт
                or a
                jr z,.done
                ld ixl,a
.tloop:         CRC_BYTE
                dec ixl
                jr nz,.tloop
.done:          ld (running_crc),de     ; сумма — обратно в память
                ld (running_crc+2),iy
                ret

;========================================================================
; ОКНО ПЛАГИНА И ИНДИКАТОР
;========================================================================
; Строки собираются в буфере ui_line и выводятся функцией PRSRW.

fill_spaces:                            ; ui_line = одни пробелы
                ld hl,ui_line
                ld de,ui_line+1
                ld bc,UI_WIDTH-1
                ld (hl)," "
                ldir
                ret

put_dec3:                               ; A (0..255) — три цифры по адресу HL
                ld c,"0"-1              ; сотни: вычитаем 100, пока можно
1               inc c
                sub 100
                jr nc,1B
                add a,100
                ld (hl),c
                inc hl
                ld c,"0"-1              ; десятки
2               inc c
                sub 10
                jr nc,2B
                add a,10
                ld (hl),c
                inc hl
                add a,"0"               ; единицы
                ld (hl),a
                ret

; Нарисовать строку «NNN%» (строка 2 окна) и полосу (строка 4).
ui_draw_percent:
                call fill_spaces
                ld a,(progress_percent)
                ld hl,ui_line+27
                call put_dec3
                ld a,"%"
                ld (ui_line+30),a
                ld hl,ui_line
                ld bc,UI_WIDTH
                ld d,2
                ld e,3
                call wc_print
                call fill_spaces
                ld a,(progress_percent) ; заполнено клеток = процент * 54 / 100
                ld c,BAR_WIDTH
                call mul8
                ld c,0                  ; деление на 100 вычитанием
1               ld de,100
                or a
                sbc hl,de
                jr c,2F
                inc c
                jr 1B
2               ld hl,ui_line+2         ; C — сколько клеток закрасить
                ld b,BAR_WIDTH
3               ld a,BAR_EMPTY
                inc c                   ; C ещё не ноль? (INC/DEC — проверка
                dec c                   ; на ноль без порчи A)
                jr z,4F
                dec c
                ld a,BAR_FILLED
4               ld (hl),a
                inc hl
                djnz 3B
                ld hl,ui_line
                ld bc,UI_WIDTH
                ld d,4
                ld e,3
                jp wc_print

; Строка 6: «unziping: путь» (или «skipping: путь» для пропускаемого файла).
ui_draw_name:
                push hl
                call fill_spaces
                ld hl,prefix_unzip
                ld a,(skip_display)
                or a
                jr z,1F
                ld hl,prefix_skip
1               ld de,ui_line
                ld bc,10
                ldir
                pop hl
                ld de,ui_line+10
                ld a,UI_WIDTH-10
                call copy_tail
                ld hl,ui_line
                ld bc,UI_WIDTH
                ld d,6
                ld e,3
                jp wc_print

ui_draw_centered:                       ; HL — текст, D — строка окна:
                push de                 ; вывести по центру
                push hl
                call fill_spaces
                pop hl
                call string_length
                ld a,b
                or a
                jr z,1F
                ld bc,UI_WIDTH          ; длиннее строки — обрезать
                jr 2F
1               ld a,c
                cp UI_WIDTH+1
                jr c,2F
                ld c,UI_WIDTH
2               ld a,UI_WIDTH           ; отступ = (ширина − длина) / 2
                sub c
                srl a
                ld de,ui_line
                add a,e
                ld e,a
                jr nc,3F
                inc d
3               ld a,b
                or c
                jr z,4F
                ldir
4               pop de
                ld hl,ui_line
                ld bc,UI_WIDTH
                ld e,3
                jp wc_print

ui_draw_prompt_path:                    ; путь HL — в строку 4 (для вопроса)
                push hl
                call fill_spaces
                pop hl
                ld de,ui_line
                ld a,UI_WIDTH
                call copy_tail
                ld hl,ui_line
                ld bc,UI_WIDTH
                ld d,4
                ld e,3
                jp wc_print

; Вопрос «заменить существующий файл?». Выход: A — REPLACE_*.
ui_confirm_replace:
                ld hl,replace_question
                ld d,2
                call ui_draw_centered
                ld hl,path_buffer
                call ui_draw_prompt_path
                ld hl,replace_options
                ld d,6
                call ui_draw_centered
                call restore_history_mapping
                ; Enter, которым запустили ZIP, может ещё быть нажат —
                ; дождаться отпускания, чтобы не принять его за «Yes».
                call wc_wait_key_release
.loop:          call wc_wait_frame
                call wc_escape
                ld a,REPLACE_CANCEL
                jr nz,.done
                call wc_enter
                ld a,REPLACE_YES
                jr nz,.done
                call wc_scan_key
                call upper_ascii
                ld c,a
                cp "Y"
                ld a,REPLACE_YES
                jr z,.done
                ld a,c
                cp "N"
                ld a,REPLACE_NO
                jr z,.done
                ld a,c
                cp "A"
                ld a,REPLACE_ALL
                jr z,.done
                ld a,c
                cp 27                   ; код Esc
                ld a,REPLACE_CANCEL
                jr z,.done
                jr .loop
.done:          push af
                call wc_wait_key_release
                call ui_draw_percent    ; вернуть обычные строки индикатора
                ld hl,path_buffer
                call ui_draw_name
                call restore_history_mapping
                pop af
                ret

; Сколько байт архива соответствует A процентам:
;   threshold = quotient*A + (remainder*A + 99) / 100,
; где quotient и remainder — частное и остаток от размер/100. Так порог
; считается точно, без 32-битного деления на каждом шаге.
progress_threshold:
                push af
                ld hl,progress_quotient
                ld de,threshold
                call mul32_8            ; threshold = quotient * A
                pop af
                ld c,a
                ld a,(progress_remainder)
                call mul8               ; HL = remainder * A (не больше 9900)
                ld bc,99                ; + 99 — округление вверх
                add hl,bc
                ld c,0                  ; C = HL / 100
1               ld de,100
                or a
                sbc hl,de
                jr c,2F
                inc c
                jr 1B
2               ld b,0
                ld hl,threshold
                jp add32_bc

; Обновить индикатор по archive_position. A≠0 — перерисовать в любом
; случае. Выход: C=1 — нажат Esc (отмена уже записана).
ui_update:
                ld (ui_force),a
                ld a,(progress_percent)
                ld (ui_old),a
.advance:       ld a,(progress_percent) ; пока позиция достигла порога
                cp 99                   ; следующего процента — прибавлять
                jr nc,.check            ; (100 % рисует только ui_finish)
                inc a
                call progress_threshold
                ld hl,archive_position
                ld de,threshold
                call cmp32
                jr c,.check
                ld a,(progress_percent)
                inc a
                ld (progress_percent),a
                jr .advance
.check:         ld a,(ui_force)         ; перерисовка нужна, если просили,
                or a                    ; если процент изменился или ещё
                jr nz,.draw             ; ни разу не рисовался
                ld a,(ui_old)
                ld b,a
                ld a,(progress_percent)
                cp b
                jr nz,.draw
                ld a,(progress_drawn)
                cp b
                jr z,.esc
.draw:          call ui_draw_percent
                ld hl,path_buffer
                call ui_draw_name
                ld a,(progress_percent)
                ld (progress_drawn),a
                call restore_history_mapping
.esc:           call wc_escape
                jr nz,1F
                or a
                ret
1               ld a,ERR_CANCELLED
                jp fail_with

; Успешное окончание: «100%», «unziping: done» и полсекунды паузы.
ui_finish:
                ld a,100
                ld (progress_percent),a
                call ui_draw_percent
                ld hl,done_text
                call ui_draw_name
                ld b,25                 ; 25 кадров = 0,5 с
1               push bc
                call wc_wait_frame
                pop bc
                djnz 1B
                ret

; Сообщение «ERROR: текст» и ожидание любой клавиши.
ui_error:
                ld a,(error_code)
                cp ERR_CANCELLED        ; отмену пользователь видел сам
                ret z
                cp ERR_SELF+1
                jr c,1F
                xor a                   ; неизвестный код — общий текст
1               add a,a                 ; адрес текста — из таблицы error_texts
                ld c,a
                ld b,0
                ld hl,error_texts
                add hl,bc
                ld a,(hl)
                inc hl
                ld h,(hl)
                ld l,a
                push hl
                call fill_spaces
                ld hl,error_prefix
                ld de,ui_line
                ld bc,7
                ldir
                pop hl
                ld b,UI_WIDTH-7
2               ld a,(hl)
                or a
                jr z,3F
                ld (de),a
                inc hl
                inc de
                djnz 2B
3               ld hl,ui_line
                ld bc,UI_WIDTH
                ld d,4
                ld e,3
                call wc_print
                ld hl,press_key_text
                ld d,6
                call ui_draw_centered
                call restore_history_mapping
                ; Enter, которым запустили архив, не должен закрыть сообщение
                call wc_wait_key_release
4               call wc_any_key
                ret nz
                call wc_wait_frame
                jr 4B

;========================================================================
; ИМЕНА ФАЙЛОВ И ПУТИ
;========================================================================
; Символы, запрещённые в именах FAT, заменяются на «_».
sanitise_character:
                cp 32                   ; управляющие символы
                jr c,1F
                cp '"'
                jr z,1F
                cp "*"
                jr z,1F
                cp ":"
                jr z,1F
                cp "<"
                jr z,1F
                cp ">"
                jr z,1F
                cp "?"
                jr z,1F
                cp "|"
                ret nz
1               ld a,"_"
                ret

; Русская буква в UTF-8 — это два байта: #D0 или #D1 и второй байт.
; Перевести её в один байт кодировки CP866, которой пользуется WC.
; Вход: A — первый байт, C — второй. Выход: A — буква CP866 (или «_»).
convert_utf8_pair:
                cp #D0
                jr nz,.d1
                ld a,c
                cp #81
                jr nz,1F
                ld a,#F0                ; Ё
                ret
1               cp #90
                jr c,.under
                cp #A0
                jr c,2F
                cp #B0
                jr c,3F
                cp #C0
                jr c,4F
                jr .under
2               sub #90-#80             ; А..П: #D0 #90..#9F → #80..#8F
                ret
3               sub #A0-#90             ; Р..Я: #D0 #A0..#AF → #90..#9F
                ret
4               sub #B0-#A0             ; а..п: #D0 #B0..#BF → #A0..#AF
                ret
.d1:            ld a,c
                cp #91
                jr nz,5F
                ld a,#F1                ; ё
                ret
5               cp #80
                jr c,.under
                cp #90
                jr nc,.under
                add a,#E0-#80           ; р..я: #D1 #80..#8F → #E0..#EF
                ret
.under:         ld a,"_"                ; прочие символы не переводятся
                ret

; Прочитать имя файла из локального заголовка в path_buffer.
; Вход: BC — длина имени в архиве, A≠0 — имя в UTF-8 (иначе CP866).
; Разделители «/» и «\» приводятся к «/»; имя, кончающееся на «/», —
; каталог (is_directory=1). C=1 — ошибка.
read_entry_name:
                ld (utf8_flag),a
                ld (name_remaining),bc
                xor a
                ld (is_directory),a
                ld hl,0
                ld (name_output),hl     ; сколько символов уже записано
                ld a,b
                or c
                jr nz,.loop
                jp .bad_name            ; пустое имя
.loop:          ld hl,(name_remaining)
                ld a,h
                or l
                jp z,.done
                call read_archive_byte
                ret c
                ld hl,(name_remaining)
                dec hl
                ld (name_remaining),hl
                ld c,a                  ; C — очередной байт имени
                ld a,(utf8_flag)
                or a
                jr z,.plain
                ld a,c
                cp #80
                jr c,.plain             ; обычный латинский символ
                cp #D0
                jr z,.cyr               ; русская буква
                cp #D1
                jr z,.cyr
                and #F0                 ; прочие многобайтовые символы UTF-8
                cp #E0                  ; (3 или 4 байта) — пропустить и
                jr nz,1F                ; заменить на «_»
                ld b,2
                jr 2F
1               ld a,c
                and #F8
                cp #F0
                jp nz,.bad_name
                ld b,3
2               ld hl,(name_remaining)
                ld a,h
                or a
                jr nz,3F
                ld a,l
                cp b
                jp c,.bad_name          ; имя кончилось посреди символа
3               push bc
                call read_archive_byte
                pop bc
                ret c
                and #C0                 ; байт-продолжение UTF-8: 10xxxxxx
                cp #80
                jp nz,.bad_name
                ld hl,(name_remaining)
                dec hl
                ld (name_remaining),hl
                djnz 3B
                ld c,"_"
                jr .plain
.cyr:           ld hl,(name_remaining)
                ld a,h
                or l
                jp z,.bad_name
                push bc
                call read_archive_byte  ; второй байт буквы
                pop bc
                ret c
                ld hl,(name_remaining)
                dec hl
                ld (name_remaining),hl
                ld b,a
                and #C0
                cp #80
                jr nz,.bad_name
                ld a,c
                ld c,b
                call convert_utf8_pair
                ld c,a
.plain:         ld a,c
                or a
                jr z,.bad_name          ; нулевой байт в имени недопустим
                cp "/"
                jr z,.slash
                cp 92                   ; обратная косая черта «\»
                jr z,.slash
                call .room
                jr c,.bad_name
                ld a,c
                call sanitise_character
                call .put
                jp .loop
.slash:         ld hl,(name_output)
                ld a,h
                or l
                jr z,.bad_path          ; путь не может начинаться с «/»
                ld de,path_buffer
                add hl,de
                dec hl
                ld a,(hl)
                cp "/"
                jr z,4F                 ; «//» — оставить один разделитель
                call .room
                jr c,.bad_name
                ld a,"/"
                call .put
4               ld hl,(name_remaining)
                ld a,h
                or l
                jp nz,.loop
                ld a,1                  ; «/» в самом конце — это каталог
                ld (is_directory),a
                jp .loop
.done:          ld bc,(name_output)
                jp canonicalise_path
.room:          ld hl,(name_output)     ; C=1 — в буфере пути нет места
                ld de,PATH_SIZE-1
                or a
                sbc hl,de
                ccf
                ret
.put:           ld hl,(name_output)     ; добавить символ A в буфер пути
                ld de,path_buffer
                add hl,de
                ld (hl),a
                ld hl,(name_output)
                inc hl
                ld (name_output),hl
                ret
.bad_name:      ld a,ERR_NAME
                jp fail_with
.bad_path:      ld a,ERR_PATH
                jp fail_with

; Нормализовать путь длиной BC в path_buffer: у каждого компонента убрать
; хвостовые пробелы и точки (FAT их не хранит), запретить пустые
; компоненты, «.» и «..» (иначе архив мог бы писать выше текущего каталога)
; и компоненты длиннее 255. В конце пути ставится ноль.
canonicalise_path:
                ld (cp_length),bc
                ld hl,0
                ld (cp_read),hl         ; откуда читаем
                ld (cp_write),hl        ; куда пишем (путь сжимается на месте)
.component:     ld hl,(cp_read)
                ld de,(cp_length)
                or a
                sbc hl,de
                jp nc,.end
                ld hl,(cp_read)
                ld (cp_start),hl        ; начало компонента
1               ld hl,(cp_read)         ; найти «/» или конец
                ld de,(cp_length)
                or a
                sbc hl,de
                jr nc,2F
                ld hl,(cp_read)
                ld de,path_buffer
                add hl,de
                ld a,(hl)
                cp "/"
                jr z,2F
                ld hl,(cp_read)
                inc hl
                ld (cp_read),hl
                jr 1B
2               ld hl,(cp_read)         ; длина компонента
                ld de,(cp_start)
                or a
                sbc hl,de
                ld (cp_complen),hl
3               ld hl,(cp_complen)      ; снять хвостовые пробелы и точки
                ld a,h
                or l
                jr z,4F
                ld de,(cp_start)
                add hl,de
                dec hl
                ld de,path_buffer
                add hl,de
                ld a,(hl)
                cp " "
                jr z,5F
                cp "."
                jr nz,4F
5               ld hl,(cp_complen)
                dec hl
                ld (cp_complen),hl
                jr 3B
4               ld hl,(cp_complen)
                ld a,h
                or l
                jp z,.bad               ; пустой компонент
                ld a,h
                or a
                jp nz,.bad              ; длиннее 255
                ld hl,(cp_start)
                ld de,path_buffer
                add hl,de
                ld a,(hl)
                cp "."
                jr nz,6F
                ld a,(cp_complen)
                cp 1
                jp z,.bad               ; «.»
                cp 2
                jr nz,6F
                inc hl
                ld a,(hl)
                cp "."
                jr z,.bad               ; «..»
6               ld hl,(cp_start)        ; перенести компонент на место записи
                ld de,path_buffer
                add hl,de
                ld de,(cp_write)
                push hl
                ld hl,path_buffer
                add hl,de
                ex de,hl
                pop hl
                ld bc,(cp_complen)
                ldir
                ld hl,(cp_write)
                ld bc,(cp_complen)
                add hl,bc
                ld (cp_write),hl
                ld hl,(cp_read)         ; дальше был «/» — записать разделитель
                ld de,(cp_length)
                or a
                sbc hl,de
                jp nc,.component
                ld hl,(cp_write)
                ld de,path_buffer
                add hl,de
                ld (hl),"/"
                ld hl,(cp_write)
                inc hl
                ld (cp_write),hl
                ld hl,(cp_read)
                inc hl
                ld (cp_read),hl
                jp .component
.end:           ld hl,(cp_write)
                ld a,h
                or l
                jr z,7F
                ld de,path_buffer
                add hl,de
                dec hl
                ld a,(hl)
                cp "/"
                jr nz,7F
                ld hl,(cp_write)        ; «/» в конце — это каталог
                dec hl
                ld (cp_write),hl
                ld a,1
                ld (is_directory),a
7               ld hl,(cp_write)
                ld a,h
                or l
                jr z,.bad               ; от пути ничего не осталось
                ld de,path_buffer
                add hl,de
                ld (hl),0
                or a
                ret
.bad:           ld a,ERR_PATH
                jp fail_with

; Пропустить «дополнительное поле» заголовка длиной BC. Поле состоит из
; блоков [тег 2 байта][размер 2 байта][данные]. Тег 1 — это ZIP64, его
; не поддерживаем. C=1 — ошибка.
read_extra:
                ld (extra_remaining),bc
.loop:          ld hl,(extra_remaining)
                ld a,h
                or l
                ret z                   ; всё прочитано (C=0)
                ld a,h
                or a
                jr nz,1F
                ld a,l
                cp 4
                jr c,.truncated         ; на заголовок блока не хватает
1               call read_u16           ; тег
                ret c
                ld (extra_tag),bc
                call read_u16           ; размер
                ret c
                ld (extra_size),bc
                ld hl,(extra_remaining)
                ld de,4
                or a
                sbc hl,de
                ld (extra_remaining),hl
                ld de,(extra_size)
                or a
                sbc hl,de
                jr c,.truncated         ; блок длиннее поля
                ld (extra_remaining),hl
                ld hl,(extra_tag)
                ld a,h
                or a
                jr nz,2F
                ld a,l
                cp 1
                jr nz,2F
                ld a,ERR_ZIP64
                jp fail_with
2               ld bc,(extra_size)
                call skip_bytes
                ret c
                jr .loop
.truncated:     ld a,ERR_TRUNCATED
                jp fail_with

;========================================================================
; КАТАЛОГИ И ФАЙЛЫ НА КАРТЕ
;========================================================================
; Запрос для FENTRY и других функций: байт типа (#00 — файл, #10 —
; каталог), затем имя с нулём. Вход: A — тип, HL — имя.
; Выход: HL = query_buffer.
make_query:
                ld de,query_buffer
                ld (de),a
                inc de
                call copy_string
                ld hl,query_buffer
                ret

; Подготовить потоки: оба — копии потока активной панели. Поток 0
; открывает архив для чтения, поток 1 остаётся в каталоге панели — туда
; идёт распаковка.
prepare_streams:
                call wc_clone_streams
                xor a
                call wc_select_stream
                ld hl,archive_name
                xor a
                call make_query
                call wc_fentry          ; найти архив
                jr nz,1F
                ld a,ERR_IO
                jp fail_with
1               ; FILEX читает конец архива по смещению, не сбивая будущее
                ; последовательное чтение. Нет провайдера FILEX — число
                ; записей останется неизвестным, это не ошибка.
                call detect_entry_count
                call wc_gfile           ; встать на начало архива
                ld a,1
                call wc_select_stream
                or a
                ret

; Вернуть поток 1 в каталог, из которого начали: подниматься «..»
; столько раз, сколько вошли.
return_to_base:
                ld a,1
                call wc_select_stream
1               ld a,(output_depth)
                or a
                ret z                   ; C=0
                ld hl,dotdot
                ld a,#10
                call make_query
                call wc_fentry
                jr nz,2F
                ld a,ERR_DIRECTORY
                jp fail_with
2               call wc_gdir
                ld a,(output_depth)
                dec a
                ld (output_depth),a
                jr 1B

; Войти в каталог HL (в потоке 1), при необходимости создав его.
enter_directory:
                push hl
                ld a,#10
                call make_query
                call wc_fentry
                pop hl
                jr nz,.found            ; каталог уже есть
                push hl
                ld hl,query_buffer+1
                call wc_mkdir
                pop hl
                jr z,1F
                ld a,ERR_DIRECTORY
                jp fail_with
1               ld a,1
                ld (changed_directory),a
                ld a,#10
                call make_query
                call wc_fentry
                jr nz,.found
                ld a,ERR_DIRECTORY
                jp fail_with
.found:         ld a,(output_depth)
                cp 63                   ; глубже 63 уровней не идём
                jr c,2F
                ld a,ERR_PATH
                jp fail_with
2               call wc_gdir
                ld a,(output_depth)
                inc a
                ld (output_depth),a
                or a
                ret

; Пройти путь из path_buffer: для каждого каталога пути — войти в него
; (создав при необходимости). Последний компонент (имя файла) остаётся в
; target_name. Вход: A≠0 — вся запись является каталогом.
navigate_entry:
                ld (nav_is_dir),a
                call return_to_base     ; начать от исходного каталога
                ret c
                ld hl,path_buffer
.component:     ld a,(hl)
                or a
                ret z                   ; путь кончился (C=0)
                ld (nav_start),hl
1               ld a,(hl)               ; найти «/» или конец
                or a
                jr z,2F
                cp "/"
                jr z,2F
                inc hl
                jr 1B
2               ld (nav_pos),hl
                ld de,(nav_start)
                or a
                sbc hl,de               ; длина компонента
                ld a,h
                or a
                jr z,3F
                ld a,ERR_NAME
                jp fail_with
3               ld b,h
                ld c,l
                ex de,hl                ; HL = начало компонента
                ld de,target_name       ; скопировать его в target_name
                ld a,b
                or c
                jr z,4F
                ldir
4               xor a
                ld (de),a
                ld hl,(nav_pos)
                ld a,(hl)
                or a
                jr nz,5F                ; не последний — это каталог
                ld a,(nav_is_dir)
                or a
                jr z,.next              ; последний и запись — файл
5               ld hl,target_name
                call enter_directory
                ret c
.next:          ld hl,(nav_pos)
                ld a,(hl)
                or a
                ret z
                inc hl                  ; перешагнуть «/»
                jr .component

; Решить, что делать с файлом target_name. Выход: A=1 — пропустить файл,
; A=0 — распаковывать; C=1 — ошибка или отмена.
choose_file_action:
                ld hl,target_name       ; каталог с таким именем — файл
                ld a,#10                ; не запишешь
                call make_query
                call wc_fentry
                jr z,1F
                ld a,ERR_RENAME
                jp fail_with
1               ld hl,target_name
                xor a
                call make_query
                call wc_fentry
                jr nz,2F
                xor a                   ; файла нет — писать
                ret
2               ld a,(replace_all)      ; раньше ответили «All» — не спрашивать
                or a
                jr nz,.self
                ; Решение принимается ДО создания временного файла и записи
                call ui_confirm_replace
                cp REPLACE_CANCEL
                jr nz,3F
                ld a,ERR_CANCELLED
                jp fail_with
3               cp REPLACE_NO
                jr nz,4F
                ld a,1                  ; пропустить этот файл
                ret
4               cp REPLACE_ALL
                jr nz,.self
                ld a,1
                ld (replace_all),a
.self:          ld a,(output_depth)     ; сам архив в том же каталоге
                or a                    ; заменять нельзя: мы же его читаем
                jr nz,5F
                ld hl,target_name
                ld de,archive_name
                call strings_equal_ci
                jr nz,5F
                ld a,ERR_SELF
                jp fail_with
5               xor a
                ret

; Имя временного файла WCUZnn0.$$$, где nn — номер A (0..99).
make_temp_candidate:
                ld hl,temp_template
                ld de,temp_name
                ld bc,13
                ldir
                ld c,"0"-1              ; десятки
1               inc c
                sub 10
                jr nc,1B
                add a,10
                add a,"0"               ; единицы
                ld (temp_name+6),a
                ld a,c
                ld (temp_name+5),a
                ret

; Создать временный файл в текущем каталоге потока 1. Перебираются имена
; WCUZ000.$$$ ... WCUZ990.$$$, пока не найдётся свободное.
;
; Если размер файла известен из заголовка, файл сразу создаётся нужной
; длины: WC выделяет всю цепочку кластеров и ставит поток на начало
; файла — дальше данные идут потоком через SAVE512 (write_mode = 0).
; Если размер неизвестен (data descriptor), файл создаётся пустым и один
; раз находится FENTRY: так APPEND будет дописывать его, помня конец
; файла, без повторного поиска (write_mode = 1). C=1 — ошибка.
begin_temp_file:
                xor a
.candidate:     ld (temp_candidate),a
                call make_temp_candidate
                ld hl,temp_name         ; имя не должно быть занято ни файлом,
                xor a                   ; ни каталогом
                call make_query
                call wc_fentry
                jp nz,.next
                ld hl,temp_name
                ld a,#10
                call make_query
                call wc_fentry
                jp nz,.next
                ; Блок для MKfile: атрибуты (1 байт), размер (4 байта), имя, 0.
                xor a
                ld (query_buffer),a     ; атрибуты: обычный файл
                ld hl,hdr_uncompressed  ; размер из заголовка...
                ld a,(has_descriptor)
                or a
                jr z,1F
                ld hl,zero_dword        ; ...или 0, если он неизвестен
1               ld de,query_buffer+1
                call copy32
                ld hl,temp_name
                ld de,query_buffer+5
                call copy_string
                ld hl,query_buffer
                call wc_mkfile
                jr z,.created
                cp 16                   ; «нет места на карте» — другие имена
                jr z,.no_space          ; не помогут
                jr .next                ; имя занято — попробовать следующее
.created:       ld a,1
                ld (temp_active),a      ; при ошибке файл надо будет удалить
                ld (changed_directory),a
                ld a,(has_descriptor)
                ld (write_mode),a       ; 0 — SAVE512, 1 — APPEND
                or a
                ret z                   ; SAVE512: поток уже в начале файла
                ld hl,temp_name         ; APPEND: найти файл один раз
                xor a
                call make_query
                call wc_fentry
                jr z,.no_space
                or a
                ret
.no_space:      ld a,ERR_CREATE
                jp fail_with
.next:          ld a,(temp_candidate)
                inc a
                cp 100
                jp c,.candidate
                ld a,ERR_CREATE
                jp fail_with

; Файл распакован и проверен: удалить прежний файл с таким именем (если
; был) и переименовать временный. C=1 — ошибка.
commit_temp_file:
                ld hl,target_name       ; появился каталог с этим именем?
                ld a,#10
                call make_query
                call wc_fentry
                jr nz,.rename_failed
                ld hl,target_name       ; есть старый файл — удалить
                xor a
                call make_query
                call wc_fentry
                jr z,1F
                ld hl,target_name
                xor a
                call make_query
                call wc_fentry
                jr z,.rename_failed
                ld hl,query_buffer
                call wc_delete
                jr z,.rename_failed
1               ld hl,temp_name         ; WCUZnn0.$$$ → настоящее имя
                xor a
                call make_query
                ld de,target_name
                call wc_rename
                jr z,.rename_failed
                xor a
                ld (temp_active),a      ; временного файла больше нет
                ret
.rename_failed: ld a,ERR_RENAME
                jp fail_with

; При ошибке удалить недописанный временный файл. Код первой ошибки
; сохраняется, даже если удаление само добавит ошибок.
cleanup_temp:
                ld a,(temp_active)
                or a
                ret z
                ld a,(error_code)
                push af
                ld a,1
                call wc_select_stream
                ld hl,temp_name
                xor a
                call make_query
                call wc_fentry
                jr z,1F
                ld hl,query_buffer
                call wc_delete
1               xor a
                ld (temp_active),a
                pop af
                ld (error_code),a
                or a
                jr z,2F
                ld a,1
2               ld (zip_error),a
                ret

;========================================================================
; FILEX: ЧИСЛО ЗАПИСЕЙ ИЗ КОНЦА АРХИВА
;========================================================================
; Зачем: если пользователь ответил «No» на ПОСЛЕДНИЙ файл архива, его
; данные можно вообще не читать. Для этого надо знать, сколько в архиве
; файлов, — это число записано в EOCD в самом конце архива. FILEX — плагин-
; провайдер WC, который читает файл с любого смещения.

; Прочитать BC байт с 32-битного смещения (fx_offset) в буфер HL.
; C=0 — прочитано ровно столько.
filex_read_at:
                ld (filex_block+8),hl   ; блок запроса: +4 смещение,
                ld (filex_block+10),bc  ; +8 адрес буфера, +10 длина
                ld hl,fx_offset
                ld de,filex_block+4
                call copy32
                ld hl,filex_block
                call wc_filex
                or a
                jr nz,.fail
                ld hl,(filex_block+24)  ; +24 — сколько прочитано
                ld de,(filex_block+10)
                or a
                sbc hl,de
                jr nz,.fail
                ld hl,(filex_block+26)
                ld a,h
                or l
                jr nz,.fail
                or a
                ret
.fail:          scf
                ret

; Проверить кандидата в EOCD по смещению (fx_offset): сигнатура, номера
; дисков 0, число записей не 0 и не #FFFF, и EOCD вместе с комментарием
; кончается ровно в конце архива. C=0 — подходит, число записей сохранено.
valid_eocd:
                ld hl,staging_buffer
                ld bc,EOCD_SIZE
                call filex_read_at
                ret c
                ld hl,staging_buffer
                ld a,(hl)
                cp "P"
                jr nz,.bad
                inc hl
                ld a,(hl)
                cp "K"
                jr nz,.bad
                inc hl
                ld a,(hl)
                cp 5
                jr nz,.bad
                inc hl
                ld a,(hl)
                cp 6
                jr nz,.bad
                ld hl,(staging_buffer+4) ; номера дисков — нули
                ld a,h
                or l
                jr nz,.bad
                ld hl,(staging_buffer+6)
                ld a,h
                or l
                jr nz,.bad
                ld hl,(staging_buffer+10) ; записей всего: не 0 и не #FFFF
                ld a,h
                or l
                jr z,.bad
                ld a,h
                and l
                cp #FF
                jr z,.bad
                ld de,(staging_buffer+8) ; и столько же на этом диске
                or a
                sbc hl,de
                jr nz,.bad
                ld hl,fx_offset         ; смещение + 22 + комментарий == размер
                ld de,fx_tmp
                call copy32
                ld bc,(staging_buffer+20)
                ld hl,fx_tmp
                call add32_bc
                ld bc,EOCD_SIZE
                ld hl,fx_tmp
                call add32_bc
                ld hl,fx_tmp
                ld de,archive_size
                call cmp32
                jr nz,.bad
                ld hl,(staging_buffer+10)
                ld (archive_entry_count),hl
                or a
                ret
.bad:           scf
                ret

; Найти EOCD, просматривая конец архива окнами по 512 байт от конца к
; началу (комментарий архива может содержать ложную сигнатуру — поэтому
; каждый кандидат проверяется целиком). Не нашли или нет FILEX — число
; записей остаётся нулём («неизвестно»).
detect_entry_count:
                ld hl,0
                ld (archive_entry_count),hl
                ld hl,archive_size
                ld de,eocd_min_size
                call cmp32
                ret c                   ; архив короче EOCD
                ld hl,filex_block       ; блок запроса FILEX: нули,
                ld de,filex_block+1
                ld bc,FILEX_BLOCK_SIZE-1
                ld (hl),0
                ldir
                ld a,FILEX_BLOCK_SIZE   ; +0 размер блока, +1 версия,
                ld (filex_block),a      ; +2 операция READ_AT
                ld a,1
                ld (filex_block+1),a
                ld (filex_block+2),a
                ; minimum = размер > 65557 ? размер − 65557 : 0
                ld hl,fx_minimum
                call zero32
                ld hl,archive_size
                ld de,eocd_search_size
                call cmp32
                jr c,1F
                jr z,1F
                ld hl,archive_size
                ld de,fx_minimum
                call copy32
                ld hl,fx_minimum
                ld de,eocd_search_size
                call sub32
1               ld hl,archive_size      ; end = размер
                ld de,fx_end
                call copy32
.window:        ; start = end − minimum > 512 ? end − 512 : minimum
                ld hl,fx_end
                ld de,fx_tmp
                call copy32
                ld hl,fx_tmp
                ld de,fx_minimum
                call sub32              ; tmp = end − minimum
                ld hl,fx_tmp
                ld de,window_size
                call cmp32
                jr c,2F
                jr z,2F
                ld hl,fx_end
                ld de,fx_start
                call copy32
                ld hl,fx_start
                ld de,window_size
                call sub32
                jr 3F
2               ld hl,fx_minimum
                ld de,fx_start
                call copy32
3               ld hl,fx_end            ; length = end − start
                ld de,fx_tmp
                call copy32
                ld hl,fx_tmp
                ld de,fx_start
                call sub32
                ld bc,(fx_tmp)
                ld (fx_length),bc
                ld hl,fx_start
                ld de,fx_offset
                call copy32             ; портит BC — длину загрузить заново
                ld bc,(fx_length)
                ld hl,input_buffer
                call filex_read_at
                ret c
                ld hl,(fx_length)       ; index = length − 4: сигнатура — 4 байта
                ld de,4
                or a
                sbc hl,de
                ret c
                ld (fx_index),hl
.scan:          ld hl,(fx_index)        ; искать «PK 05 06» от конца окна
                ld de,input_buffer
                add hl,de
                ld a,(hl)
                cp "P"
                jr nz,4F
                inc hl
                ld a,(hl)
                cp "K"
                jr nz,4F
                inc hl
                ld a,(hl)
                cp 5
                jr nz,4F
                inc hl
                ld a,(hl)
                cp 6
                jr nz,4F
                ld hl,fx_start          ; кандидат = start + index
                ld de,fx_offset
                call copy32
                ld bc,(fx_index)
                ld hl,fx_offset
                call add32_bc
                call valid_eocd
                ret nc                  ; нашли
4               ld hl,(fx_index)
                ld a,h
                or l
                jr z,5F
                dec hl
                ld (fx_index),hl
                jr .scan
5               ld hl,fx_start          ; start == minimum — искать больше негде
                ld de,fx_minimum
                call cmp32
                ret z
                ld hl,fx_start          ; следующее окно: end = start + 3 —
                ld de,fx_end            ; сигнатура могла попасть на
                call copy32             ; границу окон
                ld bc,3
                ld hl,fx_end
                call add32_bc
                jp .window

;========================================================================
; ОБРАБОТКА ЗАПИСЕЙ АРХИВА
;========================================================================
; Пропустить (skip_count) сжатых байт целыми окнами, ничего не распаковывая
; (ответ No при известном размере).
skip_data_bytes:
                ld a,1
                ld (skip_display),a     ; показать «skipping: …»
                ld a,1
                call ui_update
                jr c,.abort
.loop:          ld hl,skip_count
                call is_zero32
                jr z,.done
                ld hl,(input_valid)     ; HL = сколько непрочитанного в окне
                ld de,(input_index)
                or a
                sbc hl,de
                jr nz,1F
                xor a
                ld (refill_soft),a
                call refill_input       ; окно пусто — загрузить
                jr c,.abort
                call wc_escape
                jr z,2F
                ld a,ERR_CANCELLED
                call set_error
                jr .abort
2               ld hl,(input_valid)
1               ; пропустить = min(осталось пропустить, есть в окне)
                ld a,(skip_count+2)
                ld b,a
                ld a,(skip_count+3)
                or b
                jr nz,3F
                ld bc,(skip_count)
                push hl
                or a
                sbc hl,bc
                pop hl
                jr c,3F
                ld h,b
                ld l,c
3               ld b,h
                ld c,l
                ld hl,(input_index)
                add hl,bc
                ld (input_index),hl
                ld hl,archive_position
                call add32_bc
                ld hl,skip_count        ; skip_count −= пропущено
                ld a,(hl)
                sub c
                ld (hl),a
                inc hl
                ld a,(hl)
                sbc a,b
                ld (hl),a
                inc hl
                ld a,(hl)
                sbc a,0
                ld (hl),a
                inc hl
                ld a,(hl)
                sbc a,0
                ld (hl),a
                jr .loop
.done:          xor a
                ld (skip_display),a
                ret                     ; C=0
.abort:         xor a
                ld (skip_display),a
                scf
                ret

; Подготовить выход для очередной записи: ожидаемый размер
; (hdr_uncompressed), A≠0 — размер известен; CRC32 начинается с #FFFFFFFF.
reset_output:
                ld (expected_size_known),a
                ld hl,hdr_uncompressed
                ld de,expected_size
                call copy32
                ld hl,running_crc
                ld a,#FF
                ld (hl),a
                inc hl
                ld (hl),a
                inc hl
                ld (hl),a
                inc hl
                ld (hl),a
                xor a
                ld (zip_error),a
                ld (pending_error),a
                jp out_reset

; Прочитать data descriptor: CRC и оба размера. Сигнатура PK 07 08 перед
; ними необязательна — если первое число не сигнатура, это уже CRC.
read_descriptor:
                ld hl,desc_crc
                call read_u32
                ret c
                ld hl,desc_crc
                ld de,sig_desc
                call cmp32
                jr nz,1F
                ld hl,desc_crc          ; была сигнатура — CRC дальше
                call read_u32
                ret c
1               ld hl,desc_compressed
                call read_u32
                ret c
                ld hl,desc_uncompressed
                jp read_u32

; Пропущенный файл известного размера: если за ним есть data descriptor,
; прочитать его и сверить с заголовком.
finish_skipped_known:
                ld a,(has_descriptor)
                or a
                ret z                   ; C=0
                xor a
                ld (data_limit_active),a
                call read_descriptor
                ret c
                ld hl,desc_compressed
                ld de,hdr_compressed
                call cmp32
                jr nz,.size
                ld hl,hdr_uncompressed
                call is_zero32
                jr z,1F
                ld hl,desc_uncompressed
                ld de,hdr_uncompressed
                call cmp32
                jr nz,.size
1               ld hl,hdr_crc
                call is_zero32
                jr z,2F
                ld hl,desc_crc
                ld de,hdr_crc
                call cmp32
                jr nz,.crc
2               or a
                ret
.size:          ld a,ERR_SIZE
                jp fail_with
.crc:           ld a,ERR_CRC
                jp fail_with

; Проверить распакованный файл: размеры и CRC32 — из data descriptor, если
; он есть, иначе из заголовка. C=1 — не сошлось.
validate_entry:
                ld hl,running_crc       ; итог CRC32 — это инверсия суммы
                ld de,actual_crc
                ld b,4
1               ld a,(hl)
                cpl
                ld (de),a
                inc hl
                inc de
                djnz 1B
                ld a,(has_descriptor)
                or a
                jr z,.header
                xor a
                ld (data_limit_active),a
                call read_descriptor
                ret c
                ld hl,desc_compressed
                ld de,actual_compressed
                call cmp32
                jr nz,.size
                ld hl,desc_uncompressed
                ld de,out_flushed
                call cmp32
                jr nz,.size
                ld hl,desc_crc
                ld de,actual_crc
                call cmp32
                jr nz,.crc
                or a
                ret
.header:        ld hl,hdr_compressed
                ld de,actual_compressed
                call cmp32
                jr nz,.size
                ld hl,hdr_uncompressed
                ld de,out_flushed
                call cmp32
                jr nz,.size
                ld hl,hdr_crc
                ld de,actual_crc
                call cmp32
                jr nz,.crc
                or a
                ret
.size:          ld a,ERR_SIZE
                jp fail_with
.crc:           ld a,ERR_CRC
                jp fail_with

; Распаковать данные записи методом A. C=1 — ошибка.
extract_data:
                cp METHOD_STORED
                jr z,.stored
                cp METHOD_DEFLATE
                jr z,.deflate
                ld a,ERR_METHOD
                jp fail_with
.stored:        ld a,(has_descriptor)   ; без сжатия и без известной длины
                or a                    ; конец данных найти невозможно
                jr z,1F
                ld a,(compressed_known)
                or a
                jr nz,1F
                ld a,ERR_STREAMED_STORED
                jp fail_with
1               ld hl,hdr_compressed    ; скопировать как есть
                ld de,inf_store_count
                call copy32
                call set_input_window
                call store_bytes
                jr .after
.deflate:       call set_input_window
                call inflate_raw
.after:         push af                 ; сохранить флаг C результата
                call sync_input_position
                pop af
                ret nc
                ld a,(error_code)       ; ошибка: причина уже записана?
                or a
                scf
                ret nz
                ld a,ERR_DEFLATE
                jp fail_with

; Обработать одну запись архива (заголовок, имя и доп. поле уже прочитаны).
process_entry:
                ld a,1
                call ui_update          ; показать новое имя
                ret c
                ld a,(is_directory)
                call navigate_entry     ; создать и пройти каталоги пути
                ret c
                xor a
                ld (skip_entry),a
                ld a,(is_directory)
                or a
                jr z,.file
                ld hl,hdr_uncompressed  ; у записи-каталога данных нет
                call is_zero32
                jr nz,.bad_dir
                ld hl,hdr_compressed
                call is_zero32
                jr z,.data
.bad_dir:       ld a,ERR_DIRECTORY
                jp fail_with
.file:          call choose_file_action ; писать, пропустить или отменить?
                ret c
                ld (skip_entry),a
                or a
                jr z,1F
                ; Пропускаемый файл — последний в архиве? Тогда дальше только
                ; центральный каталог: читать его данные незачем.
                ld hl,(archive_entry_count)
                ld a,h
                or l
                jr z,.data              ; число записей неизвестно
                ld de,(archive_entry_index)
                or a
                sbc hl,de
                jr nz,.data
                ld a,1
                ld (finish_after_skip),a
                or a
                ret
1               call begin_temp_file
                ret c
.data:          ld hl,archive_position  ; где начинаются данные
                ld de,data_start_position
                call copy32
                ld a,(compressed_known) ; предел чтения — конец сжатых данных,
                ld (data_limit_active),a ; если их размер известен
                or a
                jr z,.limit_done
                ld hl,archive_position
                ld de,data_limit_end
                call copy32
                ld hl,data_limit_end
                ld de,hdr_compressed
                call add32              ; data_limit_end = начало + размер
                jr c,.truncated         ; переполнение 32 бит
                ld hl,data_limit_end
                ld de,archive_position
                call cmp32
                jr c,.truncated
                ld hl,archive_size      ; конец данных не дальше конца архива
                ld de,data_limit_end
                call cmp32
                jr nc,.limit_done
.truncated:     ld a,ERR_TRUNCATED
                jp fail_with
.limit_done:    ld a,(skip_entry)
                or a
                jr z,.unpack
                ld a,(compressed_known)
                or a
                jr z,.unpack
                ; Ответ No и размер известен: перешагнуть сжатые байты,
                ; ничего не распаковывая и не записывая.
                ld hl,hdr_compressed
                ld de,skip_count
                call copy32
                call skip_data_bytes
                ret c
                call actual_size
                xor a
                ld (data_limit_active),a
                ld hl,actual_compressed
                ld de,hdr_compressed
                call cmp32
                jr z,2F
                ld a,ERR_SIZE
                jp fail_with
2               jp finish_skipped_known
.unpack:        ld a,(has_descriptor)   ; размер известен, если нет descriptor
                xor 1
                call reset_output
                ld a,(skip_entry)       ; ответ No при неизвестном размере:
                ld (discard_output),a   ; распаковать «вхолостую», чтобы
                ld (skip_display),a     ; найти конец записи
                or a
                jr z,3F
                ld a,1
                call ui_update
                jr c,.clear_fail
3               ld a,(is_directory)
                or a
                jr nz,4F                ; у каталога нет данных
                ld a,(hdr_method)
                call extract_data
                jr c,.clear_fail
4               call out_finish         ; последний кусок: CRC и запись
                jr c,.clear_fail
                call actual_size
                xor a
                ld (data_limit_active),a
                ld (discard_output),a
                ld (skip_display),a
                ld a,(compressed_known) ; сжатых байт ровно столько,
                or a                    ; сколько объявлено?
                jr z,5F
                ld hl,actual_compressed
                ld de,hdr_compressed
                call cmp32
                jr z,5F
                ld a,ERR_SIZE
                jp fail_with
5               call validate_entry     ; размеры и CRC32
                ret c
                ld a,(is_directory)
                or a
                ret nz
                ld a,(skip_entry)
                or a
                ret nz
                jp commit_temp_file     ; дать файлу настоящее имя
.clear_fail:    xor a
                ld (discard_output),a
                ld (skip_display),a
                scf
                ret

actual_size:                            ; actual_compressed = позиция − начало данных
                ld hl,archive_position
                ld de,actual_compressed
                call copy32
                ld hl,actual_compressed
                ld de,data_start_position
                jp sub32

; Главный цикл: читать локальные заголовки один за другим до центрального
; каталога. C=0 — архив разобран до конца.
extract_archive:
.entry:         ld hl,signature         ; сигнатура очередной записи
                call read_u32
                ret c
                ld hl,signature
                ld de,sig_central       ; центральный каталог или EOCD —
                call cmp32              ; файлы кончились
                jp z,.finished
                ld hl,signature
                ld de,sig_eocd
                call cmp32
                jp z,.finished
                ld hl,signature
                ld de,sig_zip64
                call cmp32
                jr nz,1F
                ld a,ERR_ZIP64
                jp fail_with
1               ld hl,signature
                ld de,sig_local
                call cmp32
                jr z,2F
                ld a,ERR_NOT_ZIP
                jp fail_with
2               ld hl,(archive_entry_index) ; номер записи — для правила
                inc hl                  ; «последний пропущенный файл»
                ld (archive_entry_index),hl
                ; Локальный заголовок: версия (2), флаги (2), метод (2),
                ; время (2), дата (2), CRC32 (4), сжатый размер (4),
                ; исходный размер (4), длина имени (2), длина доп. поля (2).
                call read_u16           ; версия
                ret c
                call read_u16           ; флаги
                ret c
                ld (hdr_flags),bc
                call read_u16           ; метод
                ret c
                ld (hdr_method),bc
                call read_u16           ; время
                ret c
                call read_u16           ; дата
                ret c
                ld hl,hdr_crc
                call read_u32
                ret c
                ld hl,hdr_compressed
                call read_u32
                ret c
                ld hl,hdr_uncompressed
                call read_u32
                ret c
                call read_u16
                ret c
                ld (hdr_name_len),bc
                call read_u16
                ret c
                ld (hdr_extra_len),bc
                ld a,(hdr_flags)        ; биты 0 и 6 — шифрование:
                and #41                 ; не поддерживается
                jr z,3F
                ld a,ERR_ENCRYPTED
                jp fail_with
3               ld a,(hdr_method+1)
                or a
                jr nz,.method
                ld a,(hdr_method)
                cp METHOD_STORED
                jr z,4F
                cp METHOD_DEFLATE
                jr z,4F
.method:        ld a,ERR_METHOD
                jp fail_with
4               ld hl,hdr_compressed    ; размер #FFFFFFFF — признак ZIP64
                ld de,all_ones
                call cmp32
                jr z,.zip64
                ld hl,hdr_uncompressed
                ld de,all_ones
                call cmp32
                jr nz,5F
.zip64:         ld a,ERR_ZIP64
                jp fail_with
5               ld a,(hdr_flags)        ; бит 3 — после данных будет descriptor
                and #08
                jr z,7F
                ld a,1
7               ld (has_descriptor),a
                ld a,1                  ; сжатый размер известен, если нет
                ld (compressed_known),a ; descriptor или в заголовке не 0
                ld a,(has_descriptor)
                or a
                jr z,6F
                ld hl,hdr_compressed
                call is_zero32
                jr nz,6F
                xor a
                ld (compressed_known),a
6               ld a,(hdr_flags+1)      ; бит 11 — имя в UTF-8
                and #08
                ld bc,(hdr_name_len)
                call read_entry_name
                ret c
                ld bc,(hdr_extra_len)
                call read_extra
                ret c
                call process_entry
                ret c
                ld a,(finish_after_skip)
                or a
                jp z,.entry
.finished:      or a
                ret

;========================================================================
; ЯДРО DEFLATE
;========================================================================
                INCLUDE "inflate.asm"

;========================================================================
; КОНСТАНТЫ И ТЕКСТЫ
;========================================================================
window_title:   DB #0E,9," ZIP unpacker ",0 ; #0E,9 — цвет заголовка (как у ChkDsk)
prefix_unzip:   DB "unziping: "
prefix_skip:    DB "skipping: "
done_text:      DB "done",0
press_key_text: DB "Press any key",0
replace_question: DB "Replace existing file?",0
replace_options: DB "[Y] Yes  [N] No  [A] All  [Esc] Cancel",0
error_prefix:   DB "ERROR: "
dotdot:         DB "..",0
temp_template:  DB "WCUZ0000.$$$",0
sig_local:      DD #04034B50            ; «PK 03 04» — локальный заголовок
sig_central:    DD #02014B50            ; «PK 01 02» — центральный каталог
sig_eocd:       DD #06054B50            ; «PK 05 06» — конец каталога
sig_zip64:      DD #06064B50            ; «PK 06 06» — ZIP64
sig_desc:       DD #08074B50            ; «PK 07 08» — data descriptor
all_ones:       DD #FFFFFFFF
zero_dword:     DD 0
eocd_min_size:  DD EOCD_SIZE
eocd_search_size: DD EOCD_SEARCH_SIZE
window_size:    DD 512

error_texts:    DW err_unknown,err_io,err_truncated,err_not_zip
                DW err_encrypted,err_method,err_zip64,err_name,err_path
                DW err_streamed,err_deflate,err_crc,err_size,err_directory
                DW err_create,err_write,err_rename,err_self
err_unknown:    DB "unknown error",0
err_io:         DB "device read error",0
err_truncated:  DB "truncated ZIP archive",0
err_not_zip:    DB "invalid ZIP structure",0
err_encrypted:  DB "encrypted ZIP is unsupported",0
err_method:     DB "unsupported compression method",0
err_zip64:      DB "ZIP64 is unsupported",0
err_name:       DB "invalid or too long name",0
err_path:       DB "unsafe archive path",0
err_streamed:   DB "streamed Stored entry unsupported",0
err_deflate:    DB "invalid Deflate stream",0
err_crc:        DB "CRC32 mismatch",0
err_size:       DB "entry size mismatch",0
err_directory:  DB "cannot create directory",0
err_create:     DB "cannot create output file",0
err_write:      DB "cannot write output file",0
err_rename:     DB "cannot publish output file",0
err_self:       DB "archive cannot overwrite itself",0

;========================================================================
; ПЕРЕМЕННЫЕ
;========================================================================
archive_size:   DD 0                    ; длина архива
archive_name_ptr: DW 0                  ; адрес имени архива от WC
saved_panel_ix: DW 0                    ; IX панели от WC
unzip_window:   DS 18                   ; описание окна для WC
mul_tmp:        DD 0                    ; mul32_8: сдвигаемое множимое
mul_factor:     DB 0                    ; mul32_8: множитель
threshold:      DD 0                    ; порог следующего процента
refill_tmp:     DD 0                    ; временное 32-битное число
flush_total:    DD 0                    ; выход: отдано вместе с куском
flush_ptr:      DW 0                    ; выход: откуда брать данные
flush_len:      DW 0                    ; выход: сколько ещё записать
flush_piece:    DW 0                    ; выход: текущий кусок
crc_tail:       DB 0                    ; CRC: остаток байт после восьмёрок
cmp_flag:       DB 0                    ; cmp32: разность не ноль
ct_limit:       DB 0                    ; copy_tail: лимит знакомест
ui_force:       DB 0                    ; ui_update: перерисовать обязательно
ui_old:         DB 0                    ; ui_update: процент до обновления
fx_offset:      DD 0                    ; FILEX: смещение чтения
fx_tmp:         DD 0
fx_minimum:     DD 0                    ; FILEX: нижняя граница поиска EOCD
fx_end:         DD 0                    ; FILEX: конец окна поиска
fx_start:       DD 0                    ; FILEX: начало окна поиска
fx_length:      DW 0
fx_index:       DW 0
nav_is_dir:     DB 0                    ; navigate_entry: запись — каталог
nav_start:      DW 0
nav_pos:        DW 0
temp_candidate: DB 0                    ; номер пробуемого временного имени
extra_remaining: DW 0
extra_tag:      DW 0
extra_size:     DW 0
name_remaining: DW 0
name_output:    DW 0
utf8_flag:      DB 0
cp_length:      DW 0
cp_read:        DW 0
cp_write:       DW 0
cp_start:       DW 0
cp_complen:     DW 0
signature:      DD 0                    ; сигнатура текущей записи

; Состояние распаковки: обнуляется целиком в reset_state
state_begin:
archive_position: DD 0                  ; сколько байт архива разобрано
data_limit_end: DD 0                    ; где кончаются сжатые данные записи
data_start_position: DD 0               ; где они начались
expected_size:  DD 0                    ; ожидаемый размер распакованного
running_crc:    DD 0                    ; текущая сумма CRC32
progress_quotient: DD 0                 ; размер архива / 100
actual_compressed: DD 0                 ; сколько сжатых байт прочитано
skip_count:     DD 0                    ; сколько байт осталось пропустить
desc_crc:       DD 0                    ; data descriptor: CRC
desc_compressed: DD 0                   ; data descriptor: сжатый размер
desc_uncompressed: DD 0                 ; data descriptor: исходный размер
actual_crc:     DD 0                    ; итоговая CRC32 файла
hdr_crc:        DD 0                    ; заголовок: CRC
hdr_compressed: DD 0                    ; заголовок: сжатый размер
hdr_uncompressed: DD 0                  ; заголовок: исходный размер
hdr_flags:      DW 0                    ; заголовок: флаги
hdr_method:     DW 0                    ; заголовок: метод сжатия
hdr_name_len:   DW 0
hdr_extra_len:  DW 0
archive_entry_count: DW 0               ; записей в архиве (0 — неизвестно)
archive_entry_index: DW 0               ; номер текущей записи
input_index:    DW 0                    ; разобрано байт в окне входа
input_valid:    DW 0                    ; настоящих байт в окне входа
progress_remainder: DB 0                ; размер архива mod 100
progress_percent: DB 0                  ; текущий процент
progress_drawn: DB 0                    ; нарисованный процент
data_limit_active: DB 0                 ; 1 — предел сжатых данных известен
expected_size_known: DB 0               ; 1 — размер файла известен
discard_output: DB 0                    ; 1 — распаковка «вхолостую» (No)
skip_display:   DB 0                    ; 1 — показывать «skipping:»
output_depth:   DB 0                    ; глубина вложенных каталогов
temp_active:    DB 0                    ; 1 — временный файл существует
error_code:     DB 0                    ; код первой ошибки
changed_directory: DB 0                 ; 1 — на карте что-то изменилось
replace_all:    DB 0                    ; 1 — ответили All
finish_after_skip: DB 0                 ; 1 — последний файл пропущен
zip_error:      DB 0                    ; 1 — была ошибка
pending_error:  DB 0                    ; отложенная ошибка чтения
refill_soft:    DB 0                    ; 1 — чтение «про запас» для ядра
is_directory:   DB 0                    ; 1 — запись является каталогом
has_descriptor: DB 0                    ; 1 — после данных есть descriptor
compressed_known: DB 0                  ; 1 — сжатый размер известен
skip_entry:     DB 0                    ; 1 — файл пропускается
write_mode:     DB 0                    ; 0 — SAVE512, 1 — APPEND
state_end:

                INFLATE_VARS            ; переменные ядра Deflate

path_buffer:    DS PATH_SIZE            ; путь текущего файла
query_buffer:   DS NAME_SIZE+6          ; запрос к WC: тип/размер + имя
target_name:    DS NAME_SIZE            ; имя файла без каталогов
archive_name:   DS NAME_SIZE            ; имя архива
temp_name:      DS 13                   ; имя временного файла
ui_line:        DS UI_WIDTH             ; строка для вывода в окно
filex_block:    DS FILEX_BLOCK_SIZE     ; блок запроса к FILEX
data_end_vars:

                INFLATE_PAGES           ; таблицы ядра (выровнены на 256)
                ALIGN 256
CRC_T0:         DS 256                  ; таблица CRC32: младшие байты
CRC_T1:         DS 256
CRC_T2:         DS 256
CRC_T3:         DS 256                  ; старшие байты
input_buffer:   DS INPUT_SIZE           ; окно чтения архива
staging_buffer: DS STAGING_SIZE         ; буфер записи на карту
data_end:
                ASSERT data_end <= #C000, code and data exceed the 16 KiB page
                SAVEBIN "build/code.bin",#8000,data_end-#8000
