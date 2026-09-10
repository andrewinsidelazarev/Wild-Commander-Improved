;========================================================================
; inflate.asm — распаковщик потока Deflate (RFC 1951) для процессора Z80
;========================================================================
;
; ЗАЧЕМ ЭТОТ ФАЙЛ
; ---------------
; Почти все файлы внутри ZIP-архивов сжаты методом Deflate. Этот файл
; «разжимает» такой поток. Он подключается (INCLUDE) в плагин UNZIP.WMF и
; в тестовую программу для эмулятора (tests/inflate_harness.asm).
;
; КАК УСТРОЕН DEFLATE (в двух словах)
; ----------------------------------
; Сжатые данные — это последовательность «символов» трёх видов:
;   * литерал    — просто байт 0..255, его надо вывести как есть;
;   * повтор     — «скопируй N байт, которые были выведены D байт назад»
;                  (N — длина 3..258, D — расстояние 1..32768);
;   * конец блока — символ 256.
; Чтобы символы занимали меньше места, их записывают кодами Хаффмана:
; частые символы — короткими кодами (2–4 бита), редкие — длинными (до 15).
; Поток делится на блоки; у блока есть тип:
;   0 — без сжатия (просто байты), 1 — стандартные («фиксированные») коды,
;   2 — свои («динамические») коды, их описание лежит в начале блока.
;
; ПОЧЕМУ ЭТО БЫСТРО
; -----------------
; Прежний плагин на C читал поток по одному биту и для каждого символа
; перебирал до 15 длин кода. Здесь:
;   * коды длиной до 8 бит (а это ~94 % символов в реальных архивах)
;     узнаются ОДНИМ чтением из таблицы по восьми следующим битам потока;
;   * повторы копируются командой LDIR, а не по байту;
;   * результат пишется прямо в «кольцо истории» 32 КиБ, откуда хозяин
;     (плагин) забирает готовые куски по 4 КиБ.
;
; ЧТО ТАКОЕ «РЕЗЕРВУАР БИТОВ»
; --------------------------
; Биты читаются из пары регистров HL. Самый старший бит H — это следующий
; непрочитанный бит потока, дальше идут остальные уже загруженные биты, а
; внизу — нули. Счётчик загруженных бит хранится в младшей половине
; регистра IY (IYl). «Потребить n бит» = сдвинуть HL влево на n разрядов
; (команда ADD HL,HL сдвигает на один разряд) и уменьшить счётчик.
; Когда бит становится меньше восьми, в резервуар подкладывается ещё один
; байт из входа.
;
; Хитрость с порядком битов: Deflate хранит биты «младшим вперёд», а коды
; Хаффмана читаются «от старшего бита кода». Поэтому каждый входной байт
; сначала переворачивается задом наперёд таблицей REV (бит 0 ↔ бит 7 и
; т. д.). После этого старший байт резервуара H — это ровно следующие
; восемь бит кода, и его можно сразу использовать как номер ячейки таблицы.
;
; РЕГИСТРЫ ВО ВРЕМЯ РАСПАКОВКИ
; ----------------------------
;   HL  — резервуар битов (см. выше);
;   IYl — сколько бит сейчас в резервуаре (после пополнения 8..15);
;   DE  — куда писать следующий выходной байт (физический адрес в кольце);
;   IX  — откуда читать следующий входной байт; in_end — конец входа.
;
; КОЛЬЦО ИСТОРИИ
; --------------
; Повтор может ссылаться на данные до 32768 байт назад, поэтому последние
; 32 КиБ вывода хранятся в памяти. Под кольцо отданы две страницы по 16 КиБ:
;   логические байты #0000..#3FFF лежат по адресам #0000..#3FFF,
;   логические байты #4000..#7FFF лежат по адресам #C000..#FFFF.
; Когда запись доходит до #4000, она перепрыгивает на #C000, а после #FFFF
; сама возвращается на #0000 (16-битный адрес «переполняется» в ноль).
;
; ЧТО ДОЛЖЕН ПРЕДОСТАВИТЬ ХОЗЯИН (плагин или тест)
; -----------------------------------------------
;   in_more        — вход кончился: переставить IX и in_end на новую порцию
;                    и вернуть флаг C=0; C=1 — данных больше нет (для
;                    Deflate это ещё не ошибка: ядро могло прочитать байт
;                    «про запас», нехватка обнаружится позже). Портит A, BC;
;                    регистры HL, DE и IY сохраняет вызывающий код.
;   out_flush_hook — готов кусок кольца: HL — начало, BC — длина. Хозяин
;                    считает контрольную сумму, пишет на диск, двигает
;                    индикатор. C=0 — продолжать, C=1 — прервать.
;   core_fail      — распаковка невозможна (испорченный поток и т. п.).
;
; ЧТО ДАЁТ ЯДРО
; -------------
;   out_reset   — начать новый выходной файл (кольцо с нуля);
;   inflate_raw — распаковать поток Deflate: C=0 — успех, C=1 — ошибка;
;   store_bytes — скопировать (inf_store_count) байт входа как есть
;                 (для файлов в ZIP без сжатия, метод «Stored»);
;   out_finish  — отдать хозяину последний, неполный кусок кольца.
; Вход и выход задаются переменными in_ptr/in_end и out_ptr.
;
; Алгоритм построения и чтения канонических кодов Хаффмана повторяет
; puff.c Марка Адлера (zlib/contrib/puff, лицензия zlib).

OUT_SEG         EQU #1000               ; размер куска, отдаваемого хозяину (4 КиБ)
RING_LO_END     EQU #40                 ; старший байт адреса сразу за младшей половиной кольца
RING_HI_START   EQU #C0                 ; старший байт адреса начала старшей половины

; Страница MISC — восемь маленьких таблиц по 32 байта в одной странице
; 256 байт. Смещения таблиц внутри страницы:
M_BITMASK       EQU 0                   ; маска «n младших бит» для n = 0..8
M_LEN_EXTRA     EQU 32                  ; сколько доп. бит у кода длины (29 кодов)
M_DIST_EXTRA    EQU 64                  ; сколько доп. бит у кода расстояния (30)
M_CODE_ORDER    EQU 96                  ; порядок записи длин «кодов длин» (19)
M_LEN_BASE_LO   EQU 128                 ; начальная длина для кода, младший байт
M_LEN_BASE_HI   EQU 160                 ; то же, старший байт
M_DIST_BASE_LO  EQU 192                 ; начальное расстояние, младший байт
M_DIST_BASE_HI  EQU 224                 ; то же, старший байт

;========================================================================
; ВЫХОДНОЕ КОЛЬЦО
;========================================================================

; Начать новый выходной поток: писать с логического нуля, ничего ещё не
; отдано хозяину, ранней истории нет.
out_reset:
                ld hl,0
                ld (out_ptr),hl         ; писать с адреса #0000
                ld (out_seg_base),hl    ; текущий кусок начинается там же
                ld (out_flushed),hl     ; отдано хозяину 0 байт
                ld (out_flushed+2),hl   ; (четырёхбайтовое число: две половины)
                xor a
                ld (out_hist_full),a    ; истории 32 КиБ ещё нет
                ret

; Указатель записи DE перешагнул границу 256 байт (младший байт E стал 0).
; Вызывается двумя способами:
;   out_cross   — после «INC E»: старший байт D ещё надо увеличить;
;   out_cross_d — после LDIR: D уже увеличен самой командой.
; Здесь проверяются две вещи: не пора ли перепрыгнуть на старшую половину
; кольца и не заполнен ли очередной кусок (4 КиБ) для хозяина.
; Сохраняет HL, BC, IX, IY; на выходе DE — новый указатель записи.
out_cross:
                inc d
out_cross_d:
                ld a,d
                cp RING_LO_END          ; дошли до #4000?
                jr z,.wrap
                and #0F                 ; адрес кратен #1000 — кусок готов
                ret nz                  ; нет — просто продолжаем
                jr .flush
.wrap:          ld d,RING_HI_START      ; #4000 → #C000: старшая половина
.flush:         push hl                 ; хозяин вправе портить все регистры,
                push bc                 ; поэтому сохраняем всё, что нужно
                push ix                 ; ядру
                push iy
                push de
                ld hl,(out_seg_base)    ; HL — начало готового куска
                ld bc,OUT_SEG           ; BC — его длина, ровно 4 КиБ
                call out_flush_hook     ; отдать хозяину
                jp c,inf_fail           ; хозяин попросил остановиться
                pop de
                ld (out_seg_base),de    ; следующий кусок начинается здесь
                ld hl,(out_flushed)     ; out_flushed += 4096
                ld bc,OUT_SEG
                add hl,bc
                ld (out_flushed),hl
                jr nc,.nocarry          ; перенос в старшее слово?
                ld hl,(out_flushed+2)
                inc hl
                ld (out_flushed+2),hl
                jr .full                ; > 64 КиБ — история точно полная
.nocarry:       ld a,h
                cp #80                  ; отдано ≥ 32768 байт?
                jr c,.done
.full:          ld a,1                  ; после 32 КиБ любое расстояние
                ld (out_hist_full),a    ; допустимо — проверка не нужна
.done:          pop iy
                pop ix
                pop bc
                pop hl
                ret

; Отдать хозяину «хвост» — всё, что записано с начала текущего куска до
; указателя записи. Вызывается в конце файла. C=0/C=1 — как у хука.
out_finish:
                ld hl,(out_ptr)
                ld de,(out_seg_base)
                or a                    ; сбросить C перед вычитанием
                sbc hl,de               ; HL = длина хвоста
                ld b,h
                ld c,l
                ld a,b
                or c
                ret z                   ; хвоста нет (C=0 после OR)
                ex de,hl                ; HL = начало хвоста
                push bc
                call out_flush_hook
                pop bc
                ret c                   ; хозяин сообщил об ошибке
                ld hl,(out_ptr)         ; хвост отдан: следующий кусок —
                ld (out_seg_base),hl    ; с текущей позиции
                ld hl,(out_flushed)     ; out_flushed += длина хвоста
                add hl,bc
                ld (out_flushed),hl
                ret nc
                ld hl,(out_flushed+2)
                inc hl
                ld (out_flushed+2),hl
                or a                    ; вернуть C=0
                ret

;========================================================================
; РЕЗЕРВУАР БИТОВ
;========================================================================

; Подложить в резервуар ещё один байт входа. Вход: IYl — сколько бит уже
; есть (0..7). Байт переворачивается таблицей REV и ставится сразу под
; имеющиеся биты. Если вход кончился, резервуар не меняется: нехватка
; обнаружится, когда кто-то попросит больше бит, чем есть.
; Сохраняет C, DE; портит A, B.
inf_refill:
                push bc
                ld a,(in_end)           ; IX == in_end? (сравниваем обе
                cp ixl                  ; половины 16-битного адреса)
                jr nz,.have
                ld a,(in_end+1)
                cp ixh
                jr nz,.have
                push hl                 ; вход кончился — просим у хозяина
                push de                 ; следующую порцию
                call in_more
                pop de
                pop hl
                jr c,.none              ; данных больше нет
.have:          ld b,high REV           ; BC = REV + входной байт:
                ld c,(ix+0)             ; таблица лежит с начала страницы,
                inc ix                  ; поэтому номер ячейки — сам байт
                ld a,(bc)               ; перевёрнутый байт
                ld b,a                  ; BC = байт в старшей половине
                ld c,0
                ld a,iyl                ; сдвинуть вправо на число уже
                or a                    ; имеющихся бит, чтобы новый байт
                jr z,.merge             ; встал сразу за ними
.shift:         srl b                   ; SRL B / RR C — сдвиг пары BC вправо
                rr c
                dec a
                jr nz,.shift
.merge:         ld a,h                  ; HL = HL OR BC
                or b
                ld h,a
                ld a,l
                or c
                ld l,a
                ld a,iyl                ; бит стало на 8 больше
                add a,8
                ld iyl,a
.none:          pop bc
                ret

; Потребить A бит (0..8): сдвинуть резервуар влево и при нехватке
; пополнить. Сохраняет C, DE; портит A, B.
inf_consume:
                or a
                ret z                   ; ноль бит — ничего не делать
                ld b,a
                ld a,iyl
                sub b
                jp c,inf_fail           ; просят больше, чем есть: поток кончился
                ld iyl,a
1               add hl,hl               ; сдвиг резервуара на один бит
                djnz 1B
                cp 8                    ; осталось меньше восьми — пополнить
                ret nc
                jp inf_refill

; Прочитать число из A бит (0..8). Для «дополнительных бит» Deflate младший
; бит потока — младший бит числа, поэтому следующие 8 бит резервуара
; переворачиваются обратно той же таблицей REV и берутся нужные младшие.
; Выход: A — число. Портит BC.
inf_getbits:
                or a
                ret z                   ; 0 бит — число 0 (A уже 0)
                ld (inf_gb_n),a
                ld c,a                  ; маска n младших бит — из MISC
                ld b,high MISC          ; (таблица M_BITMASK с нулевого смещения)
                ld a,(bc)
                ld (inf_gb_mask),a
                ld b,high REV           ; следующие 8 бит в естественном
                ld c,h                  ; порядке («младшим вперёд»)
                ld a,(bc)
                ld c,a
                ld a,(inf_gb_mask)
                and c                   ; оставить n младших бит
                ld (inf_gb_val),a
                ld a,(inf_gb_n)
                call inf_consume        ; и убрать их из резервуара
                ld a,(inf_gb_val)
                ret

; Следующий целый байт входа (для блоков без сжатия, когда резервуар пуст).
inf_inbyte:
                ld a,(in_end)
                cp ixl
                jr nz,.have
                ld a,(in_end+1)
                cp ixh
                jr nz,.have
                push hl
                push de
                call in_more
                pop de
                pop hl
                jp c,inf_fail           ; здесь нехватка — уже ошибка
.have:          ld a,(ix+0)
                inc ix
                ret

; Распаковка невозможна. Сообщить хозяину и вернуться из inflate_raw (или
; store_bytes) с C=1. Стек возвращается к состоянию на входе в ядро —
; так можно выйти сразу из любой глубины вложенных вызовов.
inf_fail:
                call core_fail
                ld sp,(inf_sp)          ; стек как при входе в ядро
                scf                     ; C=1 — ошибка
                ret                     ; возврат к тому, кто вызвал ядро

;========================================================================
; ПОТОК DEFLATE: БЛОКИ
;========================================================================

; Распаковать весь поток. Вход: in_ptr/in_end — входные данные, out_ptr —
; куда писать. Выход: C=0 — успех; in_ptr — первый байт после потока.
inflate_raw:
                ld (inf_sp),sp          ; запомнить стек для inf_fail
                ld ix,(in_ptr)
                ld de,(out_ptr)
                ld hl,0                 ; резервуар пуст
                ld iy,0                 ; бит в нём 0
                xor a
                call inf_refill         ; первый байт потока — в резервуар
.block:         ld a,1                  ; заголовок блока: 1 бит «последний»
                call inf_getbits
                ld (inf_last),a
                ld a,2                  ; и 2 бита — тип блока
                call inf_getbits
                or a
                jr z,.stored            ; 0 — без сжатия
                dec a
                jr z,.fixed             ; 1 — фиксированные коды
                dec a
                jp nz,inf_fail          ; 3 — такого типа нет, поток испорчен
                call inf_dynamic        ; 2 — динамические коды
                jr .next
.fixed:         call inf_fixed
                jr .next
.stored:        call inf_stored
.next:          ld a,(inf_last)         ; был последний блок?
                or a
                jr z,.block
                ; Поток кончился. Резервуар мог «на всякий случай» взять из
                ; входа один байт, который потоку не принадлежит (там уже
                ; следующая запись ZIP). Если в резервуаре целый байт или
                ; больше — вернуть этот байт во вход. Больше одного байта
                ; вперёд ядро никогда не читает: пополнение идёт по байту
                ; и только при нехватке.
                ld a,iyl
                cp 8
                jr c,1F
                dec ix
1               ld (in_ptr),ix          ; сообщить хозяину позиции входа
                ld (out_ptr),de         ; и выхода
                or a                    ; C=0 — успех
                ret

; Скопировать (inf_store_count) байт входа в кольцо без распаковки
; (метод ZIP «Stored» — файл лежит в архиве несжатым).
store_bytes:
                ld (inf_sp),sp
                ld ix,(in_ptr)
                ld de,(out_ptr)
                call inf_store_loop
                ld (in_ptr),ix
                ld (out_ptr),de
                or a
                ret

; Блок типа 0 (без сжатия): после заголовка идёт выравнивание на границу
; байта, затем LEN (2 байта), NLEN (2 байта, LEN с инвертированными битами)
; и LEN байт данных как есть.
inf_stored:
                ld a,iyl                ; выбросить биты до границы байта:
                and 7                   ; их число = IYl mod 8
                jr z,1F
                ld b,a
                ld a,iyl
                sub b
                ld iyl,a
2               add hl,hl
                djnz 2B
1               ld a,iyl                ; если в резервуаре остался целый байт,
                cp 8                    ; вернуть его во вход — дальше читаем
                jr c,3F                 ; входные байты напрямую
                dec ix
3               ld hl,0                 ; резервуар теперь пуст
                ld iy,0
                call inf_inbyte         ; LEN, младший байт
                ld (inf_len),a
                call inf_inbyte         ; LEN, старший байт
                ld (inf_len+1),a
                call inf_inbyte
                ld c,a
                call inf_inbyte
                ld b,a                  ; BC = NLEN
                ld a,(inf_len)          ; проверка: NLEN должен быть
                cpl                     ; побитовым отрицанием LEN
                cp c
                jp nz,inf_fail
                ld a,(inf_len+1)
                cpl
                cp b
                jp nz,inf_fail
                ld hl,(inf_len)         ; сколько байт копировать —
                ld (inf_store_count),hl ; в четырёхбайтовый счётчик
                ld hl,0
                ld (inf_store_count+2),hl
                call inf_store_loop
                ld hl,0                 ; дальше снова читаем биты:
                ld iy,0                 ; резервуар заново
                xor a
                jp inf_refill

; Скопировать (inf_store_count) байт из входа в кольцо начиная с DE.
; Копирование идёт кусками, которые не пересекают границу 256 байт в
; кольце: так проверки «конец половины кольца» и «кусок готов» нужны один
; раз на кусок, а не на каждый байт. Каждый кусок копируется LDIR.
inf_store_loop:
.loop:          ld a,(inf_store_count+2) ; счётчик ≥ 65536? тогда точно
                ld c,a                  ; не ноль
                ld a,(inf_store_count+3)
                or c
                jr nz,.have_count
                ld bc,(inf_store_count)
                ld a,b
                or c
                ret z                   ; всё скопировано (C=0)
.have_count:    ld a,(in_end)           ; BC = сколько байт осталось во входе
                sub ixl                 ; (in_end − IX)
                ld c,a
                ld a,(in_end+1)
                sbc a,ixh
                ld b,a
                or c
                jr nz,.avail
                push hl                 ; вход пуст — следующая порция
                push de
                call in_more
                pop de
                pop hl
                jp c,inf_fail           ; данных нет, а копировать ещё надо
                jr .loop
.avail:         ld a,e                  ; HL = сколько байт до границы 256
                neg                     ; в кольце (256 − E; при E=0 это 256)
                ld l,a
                ld h,0
                or a
                jr nz,1F
                inc h
1               push hl                 ; кусок = min(до границы, есть во входе)
                or a
                sbc hl,bc
                pop hl
                jr c,2F
                ld h,b
                ld l,c
2               ld a,(inf_store_count+2) ; и не больше, чем осталось копировать
                ld c,a
                ld a,(inf_store_count+3)
                or c
                jr nz,3F
                ld bc,(inf_store_count)
                push hl
                or a
                sbc hl,bc
                pop hl
                jr c,3F
                ld h,b
                ld l,c
3               ld b,h                  ; BC = размер куска
                ld c,l
                ld a,(inf_store_count)  ; счётчик −= кусок (4 байта)
                sub c
                ld (inf_store_count),a
                ld a,(inf_store_count+1)
                sbc a,b
                ld (inf_store_count+1),a
                ld a,(inf_store_count+2)
                sbc a,0
                ld (inf_store_count+2),a
                ld a,(inf_store_count+3)
                sbc a,0
                ld (inf_store_count+3),a
                push ix                 ; HL = откуда (IX), DE = куда
                pop hl
                ldir                    ; скопировать кусок
                push hl                 ; новое положение во входе — в IX
                pop ix
                ld a,e                  ; дошли до границы 256 в кольце?
                or a
                call z,out_cross_d
                jp .loop

; Заполнить BC байт значением A начиная с адреса HL. Портит D.
inf_fill:
                ld d,a
1               ld (hl),d
                inc hl
                dec bc
                ld a,b
                or c
                jr nz,1B
                ret

; Блок типа 1: коды заданы стандартом. Длины кодов литералов/длин:
; символы 0–143 — 8 бит, 144–255 — 9 бит, 256–279 — 7 бит, 280–287 — 8 бит;
; все 30 кодов расстояний — по 5 бит. Строим по этим длинам таблицы и
; распаковываем блок.
inf_fixed:
                ld (out_ptr),de
                push hl                 ; HL (резервуар) нужен inf_fill
                ld hl,inf_lengths
                ld a,8
                ld bc,144
                call inf_fill
                ld a,9
                ld bc,112
                call inf_fill
                ld a,7
                ld bc,24
                call inf_fill
                ld a,8
                ld bc,8
                call inf_fill
                ld a,5                  ; 30 кодов расстояния по 5 бит
                ld bc,30
                call inf_fill
                pop hl
                ld bc,lt_desc           ; таблица литералов/длин
                ld (inf_bd_desc),bc
                ld de,inf_lengths
                ld bc,288
                call inf_build
                jp c,inf_fail
                ld bc,dt_desc           ; таблица расстояний
                ld (inf_bd_desc),bc
                ld de,inf_lengths+288
                ld bc,30
                call inf_build          ; неполный набор здесь допустим
                jp c,inf_fail
                jp inf_codes

; Блок типа 2: свои коды. В начале блока записано:
;   HLIT  (5 бит) — число кодов литералов/длин минус 257;
;   HDIST (5 бит) — число кодов расстояний минус 1;
;   HCLEN (4 бита) — число «кодов длин» минус 4;
;   HCLEN+4 длины «кодов длин» по 3 бита в особом порядке (M_CODE_ORDER);
;   затем длины всех кодов, записанные «кодами длин» (символы 0..15 — сама
;   длина; 16 — повторить предыдущую 3..6 раз; 17 — 3..10 нулей;
;   18 — 11..138 нулей).
inf_dynamic:
                ld (out_ptr),de
                ld a,5
                call inf_getbits
                cp 30                   ; nlen = 257 + A, не больше 286
                jp nc,inf_fail
                ld c,a
                ld b,1
                inc bc                  ; BC = 256 + A + 1 = 257 + A
                ld (inf_nlen),bc
                ld a,5
                call inf_getbits
                cp 30                   ; ndist = 1 + A, не больше 30
                jp nc,inf_fail
                inc a
                ld (inf_ndist),a
                ld a,4
                call inf_getbits
                add a,4
                ld (inf_ncode),a        ; число «кодов длин»: 4..19
                push hl
                ld hl,inf_lengths       ; длины «кодов длин»: 19 нулей
                xor a
                ld bc,19
                call inf_fill
                pop hl
                xor a
                ld (inf_index),a
.clen:          ld a,3                  ; очередная длина — 3 бита
                call inf_getbits
                ld (inf_tmp),a
                ld a,(inf_index)        ; куда её класть — по таблице порядка
                add a,M_CODE_ORDER
                ld c,a
                ld b,high MISC
                ld a,(bc)               ; номер элемента в массиве длин
                push hl
                ld hl,inf_lengths
                add a,l
                ld l,a
                jr nc,1F
                inc h
1               ld a,(inf_tmp)
                ld (hl),a
                pop hl
                ld a,(inf_index)
                inc a
                ld (inf_index),a
                ld c,a
                ld a,(inf_ncode)
                cp c
                jr nz,.clen
                ld bc,lt_desc           ; построить таблицу «кодов длин»
                ld (inf_bd_desc),bc     ; (временно — в таблицу литералов)
                ld de,inf_lengths
                ld bc,19
                call inf_build
                jp c,inf_fail
                or a                    ; этот набор обязан быть полным
                jp nz,inf_fail
                ; Длины литералов/длин и расстояний идут одной строкой:
                ; всего nlen + ndist чисел. inf_lend — конец этой строки.
                ld bc,(inf_nlen)
                ld a,(inf_ndist)
                add a,c
                ld c,a
                jr nc,1F
                inc b
1               push hl
                ld hl,inf_lengths
                add hl,bc
                ld (inf_lend),hl
                pop hl
                ld de,inf_lengths       ; DE — куда писать очередную длину
                xor a
                ld (inf_prev),a
.lens:          ld a,e                  ; все длины прочитаны? (DE ≥ конец)
                ld bc,(inf_lend)
                sub c
                ld a,d
                sbc a,b
                jr nc,.lens_done
                call inf_decode_lt      ; BC = символ «кода длин» 0..18
                ld a,c
                cp 16
                jr nc,.repeat
                ld (de),a               ; 0..15 — это и есть длина
                inc de
                ld (inf_prev),a
                jr .lens
.repeat:        jr nz,.zeros
                ld a,d                  ; 16: повторить предыдущую длину
                cp high inf_lengths     ; 3..6 раз; но если это самая первая
                jr nz,1F                ; длина — повторять нечего, ошибка
                ld a,e
                cp low inf_lengths
                jp z,inf_fail
1               ld a,2
                call inf_getbits
                add a,3
                ld c,a                  ; C — сколько раз
                ld a,(inf_prev)         ; A — что повторять
                jr .run
.zeros:         cp 17
                jr nz,.zeros18
                ld a,3                  ; 17: 3..10 нулей
                call inf_getbits
                add a,3
                jr .zrun
.zeros18:       ld a,7                  ; 18: 11..138 нулей
                call inf_getbits
                add a,11
.zrun:          ld c,a
                xor a
                ld (inf_prev),a
.run:           ld (inf_gb_val),a       ; значение повтора
                ld b,0
                push hl                 ; повтор не должен выйти за конец
                ld hl,(inf_lend)        ; строки длин: DE + C ≤ конец
                or a
                sbc hl,de
                sbc hl,bc
                pop hl
                jp c,inf_fail
                ld a,(inf_gb_val)
2               ld (de),a
                inc de
                dec c
                jr nz,2B
                jr .lens
.lens_done:     ld a,(inf_lengths+256)  ; у символа «конец блока» обязан
                or a                    ; быть код
                jp z,inf_fail
                ld bc,lt_desc           ; таблица литералов/длин
                ld (inf_bd_desc),bc
                ld de,inf_lengths
                ld bc,(inf_nlen)
                call inf_build
                jp c,inf_fail
                or a
                jr z,.lt_ok
                ; Неполный набор допустим только в одном случае: весь набор —
                ; единственный код длины 1 (count[0] + count[1] == nlen).
                ld bc,(lt_count)        ; count[0]
                ld a,(lt_count+2)       ; count[1]
                add a,c
                ld c,a
                jr nc,1F
                inc b
1               ld a,(inf_nlen)
                cp c
                jp nz,inf_fail
                ld a,(inf_nlen+1)
                cp b
                jp nz,inf_fail
.lt_ok:         ld bc,dt_desc           ; таблица расстояний — из хвоста
                ld (inf_bd_desc),bc     ; той же строки длин
                push hl
                ld hl,inf_lengths
                ld bc,(inf_nlen)
                add hl,bc
                ex de,hl                ; DE = длины расстояний
                pop hl
                ld a,(inf_ndist)
                ld c,a
                ld b,0
                call inf_build
                jp c,inf_fail
                or a
                jr z,.dt_ok
                ld a,(dt_count)         ; то же правило для расстояний
                ld c,a
                ld a,(dt_count+2)
                add a,c
                ld c,a
                ld a,(inf_ndist)
                cp c
                jp nz,inf_fail
.dt_ok:         jp inf_codes

; Прочитать один символ по таблице литералов (и длинные коды тоже).
; Выход: BC — символ.
inf_decode_lt:
                ld b,high LT_LEN        ; ячейка = следующие 8 бит (H)
                ld c,h
                ld a,(bc)               ; длина кода; 0 — код длиннее 8 бит
                or a
                jr z,.long
                ld (inf_gb_n),a
                and 15
                call inf_consume        ; убрать биты кода; C сохраняется
                ld b,high LT_SYM
                ld a,(bc)               ; младший байт символа
                ld c,a
                ld b,0
                ld a,(inf_gb_n)         ; бит 7 длины — символ ≥ 256
                rlca
                ret nc
                inc b
                ret
.long:          ld bc,lt_desc
                ld (inf_dl_desc),bc
                jp inf_decode_long

; Разобрать код длиннее 8 бит «по-честному», как в puff.c: для каждой
; длины от 9 до 15 взять ещё один бит и проверить, попал ли код в
; диапазон кодов этой длины. Такие коды редки (около 6 %), поэтому
; медленный путь почти не влияет на скорость.
; Вход: (inf_dl_desc) — какая таблица; H — первые 8 бит кода.
; Выход: BC — символ. Сохраняет DE.
inf_decode_long:
                push de
                ld a,h                  ; code = первые 8 бит
                ld (inf_dl_code),a
                xor a
                ld (inf_dl_code+1),a
                ld a,8
                call inf_consume
                ld bc,(inf_dl_desc)     ; достать из дескриптора таблицы:
                inc bc
                ld a,(bc)               ; адрес count[9] = count + 9*2
                add a,18
                ld e,a
                inc bc
                ld a,(bc)
                adc a,0
                ld d,a
                ld (inf_dl_cnt),de
                inc bc
                ld a,(bc)               ; адрес массива symbol[]
                ld e,a
                inc bc
                ld a,(bc)
                ld d,a
                ld (inf_dl_sym),de
                inc bc
                ld a,(bc)               ; first — первый код длины 9
                ld e,a
                inc bc
                ld a,(bc)
                ld d,a
                ld (inf_dl_first),de
                inc bc
                ld a,(bc)               ; index — номер первого символа длины 9
                ld e,a
                inc bc
                ld a,(bc)
                ld d,a
                ld (inf_dl_index),de
                ld a,7                  ; длины 9..15 — семь попыток
                ld (inf_dl_left),a
.iter:          ld bc,(inf_dl_code)     ; code = code*2 + следующий бит
                sla c
                rl b
                bit 7,h
                jr z,1F
                inc c
1               ld (inf_dl_code),bc
                ld a,1
                call inf_consume
                ld bc,(inf_dl_cnt)      ; DE = count[len] (кодов этой длины)
                ld a,(bc)
                ld e,a
                inc bc
                ld a,(bc)
                ld d,a
                inc bc
                ld (inf_dl_cnt),bc
                ld bc,(inf_dl_first)    ; BC = first + count
                ld a,c
                add a,e
                ld c,a
                ld a,b
                adc a,d
                ld b,a
                ld a,(inf_dl_code)      ; code < first + count → код найден
                sub c
                ld a,(inf_dl_code+1)
                sbc a,b
                jr c,.found
                sla c                   ; нет: first = (first + count) * 2
                rl b
                ld (inf_dl_first),bc
                ld bc,(inf_dl_index)    ; index += count
                ld a,c
                add a,e
                ld c,a
                ld a,b
                adc a,d
                ld b,a
                ld (inf_dl_index),bc
                ld a,(inf_dl_left)
                dec a
                ld (inf_dl_left),a
                jr nz,.iter
                jp inf_fail             ; кода длиннее 15 бит не бывает
.found:         ld bc,(inf_dl_first)    ; символ = symbol[index + code − first]
                ld de,(inf_dl_code)
                ex de,hl                ; HL = code, резервуар пока в DE
                or a
                sbc hl,bc
                ld bc,(inf_dl_index)
                add hl,bc
                add hl,hl               ; ×2: элементы по 2 байта
                ld bc,(inf_dl_sym)
                add hl,bc
                ld c,(hl)
                inc hl
                ld b,(hl)
                ex de,hl                ; резервуар обратно в HL
                pop de
                or a
                ret

;========================================================================
; ПОСТРОЕНИЕ ТАБЛИЦ ХАФФМАНА
;========================================================================
; Коды Хаффмана в Deflate «канонические»: по одним лишь длинам кодов можно
; восстановить сами коды. Коды одной длины идут подряд по возрастанию
; символа, а первый код каждой следующей длины = (первый код предыдущей
; длины + их количество) * 2.
;
; Вход: DE — массив длин (по байту на символ), BC — число символов,
;       (inf_bd_desc) — дескриптор таблицы.
; Выход: C=1 — набор длин избыточен (кодов «больше, чем помещается»),
;        иначе A = 0 — набор полный, A = 1 — неполный.
; Сохраняет HL, IX, IY.
;
; Дескриптор таблицы (5 полей):
;   +0 — старший байт адреса страницы SYM (страница LEN — следующая);
;   +1 — адрес массива count[16]: сколько кодов каждой длины;
;   +3 — адрес массива symbol[]: символы, упорядоченные по кодам;
;   +5 — first9: первый код длины 9 (для медленного пути);
;   +7 — index9: номер первого символа длины 9 в symbol[].
;
; Быстрые таблицы: для кода длины L (1..8) заполняются все ячейки, номер
; которых начинается с этого кода: 2^(8−L) ячеек. В странице SYM — младший
; байт символа, в странице LEN — длина кода и бит 7, если символ ≥ 256.
inf_build:
                push hl
                push ix
                ld ix,(inf_bd_desc)
                ld (inf_bd_len),de
                ld (inf_bd_n),bc
                ; Страница LEN — нулями: нулевая длина в ячейке означает
                ; «код длиннее 8 бит» (или что такого кода нет).
                ld h,(ix+0)
                inc h
                ld l,0
                xor a
1               ld (hl),a
                inc l
                jr nz,1B
                ld l,(ix+1)             ; count[0..15] = 0
                ld h,(ix+2)
                ld b,32
2               ld (hl),a
                inc hl
                djnz 2B
                ; Посчитать, сколько символов каждой длины.
                ld hl,(inf_bd_len)
                ld bc,(inf_bd_n)        ; B испорчен обнулением счётчиков
.hist:          ld a,(hl)               ; длина кода символа
                inc hl
                push hl
                add a,a                 ; count[длина]++ (элементы по 2 байта)
                add a,(ix+1)
                ld l,a
                ld a,0
                adc a,(ix+2)
                ld h,a
                inc (hl)
                jr nz,3F
                inc hl
                inc (hl)
3               pop hl
                dec bc
                ld a,b
                or c
                jr nz,.hist
                ld l,(ix+1)             ; все длины нулевые — пустой набор:
                ld h,(ix+2)             ; таблицы остаются пустыми
                ld c,(hl)
                inc hl
                ld b,(hl)
                ld hl,(inf_bd_n)
                or a
                sbc hl,bc
                jr nz,.check
                xor a
                jp .exit
.check:         ; Проверить, что коды помещаются: left — сколько кодов ещё
                ; свободно на текущей длине. left = 1; для len = 1..15:
                ; left = left*2 − count[len]. Ушли в минус — набор избыточен.
                ld hl,1
                ld a,1
.left:          ld (inf_bd_curlen),a
                add hl,hl
                call inf_bd_count       ; DE = count[len]
                or a
                sbc hl,de
                jp c,.over
                ld a,(inf_bd_curlen)
                inc a
                cp 16
                jr c,.left
                ld a,h                  ; остались свободные коды —
                or l                    ; набор неполный
                jr z,4F
                ld a,1
4               ld (inf_bd_incomplete),a
                ; Для каждой длины: offs — где в symbol[] начинаются символы
                ; этой длины; next — первый код этой длины.
                ;   offs[1] = 0; offs[len+1] = offs[len] + count[len];
                ;   next[1] = 0; next[len+1] = (next[len] + count[len]) * 2.
                ld hl,0
                ld (inf_bd_offs+2),hl
                ld (inf_bd_next+2),hl
                ld a,1
.offs:          ld (inf_bd_curlen),a
                call inf_bd_count       ; DE = count[len]
                push de
                add a,a
                ld c,a
                ld b,0                  ; BC = len * 2 (смещение в массивах)
                ld hl,inf_bd_offs
                add hl,bc
                ld a,(hl)
                inc hl
                ld h,(hl)
                ld l,a                  ; HL = offs[len]
                add hl,de
                ex de,hl                ; DE = offs[len+1]
                ld hl,inf_bd_offs+2
                add hl,bc
                ld (hl),e
                inc hl
                ld (hl),d
                pop de                  ; DE = count[len]
                ld hl,inf_bd_next
                add hl,bc
                ld a,(hl)
                inc hl
                ld h,(hl)
                ld l,a                  ; HL = next[len]
                add hl,de
                add hl,hl
                ex de,hl
                ld hl,inf_bd_next+2
                add hl,bc
                ld (hl),e
                inc hl
                ld (hl),d
                ld a,(inf_bd_curlen)
                inc a
                cp 15
                jr c,.offs
                ld hl,(inf_bd_next+18)  ; first9 = next[9]
                ld (ix+5),l
                ld (ix+6),h
                ld hl,(inf_bd_offs+18)  ; index9 = offs[9]
                ld (ix+7),l
                ld (ix+8),h
                ld hl,inf_bd_offs       ; запомнить начала групп: offs ниже
                ld de,inf_bd_start      ; будет «съеден» раздачей символов
                ld bc,32
                ldir
                ; Разложить символы по группам длин: symbol[offs[len]++] = sym
                ld hl,(inf_bd_len)
                ld bc,0                 ; BC = номер символа
.place:         ld a,(hl)
                inc hl
                or a
                jr z,.next_sym          ; нулевая длина — символа нет
                push hl
                push bc
                add a,a
                ld c,a
                ld b,0
                ld hl,inf_bd_offs
                add hl,bc
                ld e,(hl)
                inc hl
                ld d,(hl)               ; DE = offs[len], HL → его старший байт
                push hl
                ld h,d
                ld l,e
                inc hl
                ex de,hl                ; DE = offs[len] + 1, HL = прежнее
                ex (sp),hl              ; HL → старший байт offs[len]
                ld (hl),d
                dec hl
                ld (hl),e               ; offs[len]++
                pop hl                  ; HL = прежнее offs[len]
                add hl,hl
                ld c,(ix+3)
                ld b,(ix+4)
                add hl,bc               ; адрес symbol[offs]
                pop bc
                ld (hl),c               ; записать номер символа
                inc hl
                ld (hl),b
                pop hl
.next_sym:      inc bc
                push hl
                ld hl,(inf_bd_n)
                or a
                sbc hl,bc
                pop hl
                jr nz,.place
                ; Заполнить быстрые страницы SYM/LEN кодами длиной 1..8.
                ld a,1
.len_loop:      ld (inf_bd_curlen),a
                add a,a
                ld c,a
                ld b,0
                ld hl,inf_bd_start
                add hl,bc
                ld e,(hl)
                inc hl
                ld d,(hl)
                ld (inf_bd_grp),de      ; номер первого символа этой длины
                call inf_bd_count       ; DE = count[len]
                ld (inf_bd_grp_left),de
                ld hl,inf_bd_next
                add hl,bc
                ld e,(hl)
                inc hl
                ld d,(hl)
                ld (inf_bd_code),de     ; первый код этой длины
.sym_loop:      ld hl,(inf_bd_grp_left)
                ld a,h
                or l
                jr z,.len_next
                dec hl
                ld (inf_bd_grp_left),hl
                ld hl,(inf_bd_grp)
                inc hl
                ld (inf_bd_grp),hl
                dec hl
                add hl,hl
                ld c,(ix+3)
                ld b,(ix+4)
                add hl,bc
                ld c,(hl)               ; BC = символ
                inc hl
                ld b,(hl)
                ld a,(inf_bd_curlen)    ; значение для LEN: длина кода и
                bit 0,b                 ; бит 7, если символ ≥ 256
                jr z,1F
                or #80
1               ld (inf_bd_flag),a
                ld a,(inf_bd_curlen)    ; первая ячейка = code << (8 − len),
                ld b,a                  ; ячеек = 1 << (8 − len)
                ld a,8
                sub b
                ld hl,(inf_bd_code)
                ld d,1
                or a
                jr z,2F
3               add hl,hl
                sla d
                dec a
                jr nz,3B
2               ld a,l
                ld e,c                  ; E = младший байт символа
                ld b,d                  ; B = сколько ячеек заполнить
                ld h,(ix+0)             ; страница SYM
                ld l,a
                ld a,(inf_bd_flag)
                ld d,a
4               ld (hl),e               ; SYM[ячейка] = символ
                inc h
                ld (hl),d               ; LEN[ячейка] = длина (+ бит 7)
                dec h
                inc l
                djnz 4B
                ld hl,(inf_bd_code)     ; следующий код той же длины
                inc hl
                ld (inf_bd_code),hl
                jr .sym_loop
.len_next:      ld a,(inf_bd_curlen)
                inc a
                cp 9
                jp c,.len_loop
                ld a,(inf_bd_incomplete)
                or a                    ; C=0
.exit:          pop ix
                pop hl
                ret
.over:          pop ix
                pop hl
                scf
                ret

; DE = count[(inf_bd_curlen)] таблицы, на которую указывает IX.
; Сохраняет AF, HL, BC.
inf_bd_count:
                push af
                push hl
                push bc
                ld a,(inf_bd_curlen)
                add a,a
                ld c,a
                ld b,0
                ld l,(ix+1)
                ld h,(ix+2)
                add hl,bc
                ld e,(hl)
                inc hl
                ld d,(hl)
                pop bc
                pop hl
                pop af
                ret

;========================================================================
; ОСНОВНОЙ ЦИКЛ БЛОКА: символ за символом до «конца блока»
;========================================================================
inf_codes:
                ld de,(out_ptr)
.loop:          ld b,high LT_LEN        ; ячейка таблицы = следующие 8 бит
                ld c,h
                ld a,(bc)               ; A = длина кода (+ бит 7)
                or a
                jp z,.long              ; 0 — код длиннее 8 бит
                jp m,.length            ; бит 7 — символ ≥ 256 (длина/конец)
                ; САМЫЙ ЧАСТЫЙ СЛУЧАЙ — литерал. Код занимает A бит.
                ld b,a
                ld a,iyl
                sub b
                jp c,inf_fail
                ld iyl,a
1               add hl,hl               ; убрать биты кода из резервуара
                djnz 1B
                cp 8
                call c,inf_refill
                ld b,high LT_SYM        ; C всё ещё номер ячейки
                ld a,(bc)               ; A = байт-литерал
                ld (de),a               ; записать в кольцо
                inc e
                jp nz,.loop             ; не граница 256 — следующий символ
                call out_cross
                jp .loop
.long:          ld bc,lt_desc           ; длинный код — медленный путь
                ld (inf_dl_desc),bc
                call inf_decode_long    ; BC = символ
                ld a,b
                or a
                jr nz,.long_ctl
                ld a,c                  ; литерал
                ld (de),a
                inc e
                jp nz,.loop
                call out_cross
                jp .loop
.long_ctl:      ld a,c                  ; символ ≥ 256
                or a
                jp z,.eob               ; 256 — конец блока
                dec a
                cp 29
                jp nc,inf_fail
                jr .have_len_idx
.length:        ld b,high LT_SYM
                ld a,(bc)               ; символ − 256: 0 — конец блока
                ld (inf_sym),a
                ld b,high LT_LEN
                ld a,(bc)
                and 15
                call inf_consume        ; биты кода убираем и для «конца блока»
                ld a,(inf_sym)
                or a
                jp z,.eob
                dec a
                cp 29
                jp nc,inf_fail          ; символы 286 и 287 не используются
.have_len_idx:  ld (inf_sym),a          ; A = номер кода длины 0..28
                add a,M_LEN_BASE_LO     ; длина = база + дополнительные биты
                ld c,a
                ld b,high MISC
                ld a,(bc)
                ld (inf_len),a
                ld a,c
                add a,M_LEN_BASE_HI-M_LEN_BASE_LO
                ld c,a
                ld a,(bc)
                ld (inf_len+1),a
                ld a,(inf_sym)
                add a,M_LEN_EXTRA
                ld c,a
                ld a,(bc)               ; сколько дополнительных бит
                call inf_getbits
                ld c,a
                ld a,(inf_len)
                add a,c
                ld (inf_len),a
                jr nc,.dist
                ld a,(inf_len+1)
                inc a
                ld (inf_len+1),a
.dist:          ld b,high DT_LEN        ; теперь код расстояния
                ld c,h
                ld a,(bc)
                or a
                jr z,.dist_long
                and 15
                call inf_consume
                ld b,high DT_SYM
                ld a,(bc)
.have_dist_sym: ld (inf_sym),a          ; A = номер кода расстояния 0..29
                add a,M_DIST_BASE_LO    ; расстояние = база + доп. биты
                ld c,a
                ld b,high MISC
                ld a,(bc)
                ld (inf_dist),a
                ld a,c
                add a,M_DIST_BASE_HI-M_DIST_BASE_LO
                ld c,a
                ld a,(bc)
                ld (inf_dist+1),a
                ld a,(inf_sym)
                add a,M_DIST_EXTRA
                ld c,a
                ld a,(bc)               ; дополнительных бит 0..13
                cp 9
                jr c,.dist_short
                sub 8                   ; больше 8 — читаем в два приёма:
                ld (inf_gb_n2),a        ; сначала 8 младших бит, потом остаток
                ld a,8
                call inf_getbits
                ld (inf_gb_lo),a
                ld a,(inf_gb_n2)
                call inf_getbits
                ld b,a
                ld a,(inf_gb_lo)
                ld c,a
                jr .dist_add
.dist_short:    call inf_getbits
                ld c,a
                ld b,0
.dist_add:      ld a,(inf_dist)         ; расстояние += доп. биты
                add a,c
                ld (inf_dist),a
                ld a,(inf_dist+1)
                adc a,b
                ld (inf_dist+1),a
                call inf_copy           ; скопировать повтор
                jp .loop
.dist_long:     ld bc,dt_desc           ; длинный код расстояния
                ld (inf_dl_desc),bc
                call inf_decode_long
                ld a,b
                or a
                jp nz,inf_fail
                ld a,c
                cp 30
                jp nc,inf_fail
                jr .have_dist_sym
.eob:           ld (out_ptr),de         ; конец блока
                or a
                ret

; Скопировать повтор: (inf_len) байт с расстояния (inf_dist) назад от DE.
; Копирование идёт кусками, которые не пересекают границу 256 байт ни у
; источника, ни у приёмника: так переходы между половинами кольца и
; готовность кусков для хозяина проверяются один раз на кусок. Если
; расстояние меньше длины (например «повтори последний байт 100 раз»),
; LDIR копирует байты по одному вперёд и сам размножает их — это ровно то,
; чего требует Deflate.
inf_copy:
                ld a,(out_hist_full)    ; пока выведено меньше 32 КиБ,
                or a                    ; проверить, что повтор не ссылается
                jr nz,.ok               ; раньше начала файла
                push hl                 ; выведено = flushed + (DE − база куска)
                ld h,d
                ld l,e
                ld bc,(out_seg_base)
                or a
                sbc hl,bc
                ld bc,(out_flushed)
                add hl,bc
                ld bc,(inf_dist)        ; расстояние ≤ выведено
                or a
                sbc hl,bc
                pop hl
                jp c,inf_fail
.ok:            push hl                 ; резервуар — в стек, HL нужен LDIR
                ld h,d                  ; HL = DE − расстояние: откуда копировать
                ld l,e
                ld bc,(inf_dist)
                or a
                sbc hl,bc
                res 7,h                 ; перевести в логический адрес кольца
                bit 6,h                 ; (#0000..#7FFF) и обратно в физический:
                jr z,.chunk             ; #4000..#7FFF → #C000..#FFFF
                set 7,h
.chunk:         ld a,e                  ; BC = сколько до границы 256 у приёмника
                neg
                ld c,a
                ld b,0
                or a
                jr nz,1F
                inc b                   ; E=0 — ровно 256
1               ld a,l                  ; и у источника
                neg
                jr z,3F                 ; у источника 256 — не меньше, чем BC
                ld (inf_tmp),a
                ld a,b
                or a
                jr nz,2F
                ld a,(inf_tmp)
                cp c
                jr nc,3F
2               ld a,(inf_tmp)
                ld c,a
                ld b,0
3               ld a,(inf_len)          ; и не больше остатка повтора
                sub c
                ld a,(inf_len+1)
                sbc a,b
                jr nc,4F
                ld bc,(inf_len)
4               ld a,(inf_len)          ; остаток −= кусок
                sub c
                ld (inf_len),a
                ld a,(inf_len+1)
                sbc a,b
                ld (inf_len+1),a
                ldir                    ; скопировать кусок
                ld a,e                  ; приёмник дошёл до границы 256?
                or a
                call z,out_cross_d      ; (сохраняет HL и BC)
                ld a,l                  ; источник дошёл до конца младшей
                or a                    ; половины кольца (#4000)?
                jr nz,5F
                ld a,h
                cp RING_LO_END
                jr nz,5F
                ld h,RING_HI_START      ; тогда продолжить с #C000
5               ld a,(inf_len)          ; ещё осталось копировать?
                ld b,a
                ld a,(inf_len+1)
                or b
                jr nz,.chunk
                pop hl                  ; резервуар обратно
                ret

;========================================================================
; ПЕРЕМЕННЫЕ ЯДРА (размещаются хозяином через INFLATE_VARS)
;========================================================================
                MACRO INFLATE_VARS
in_ptr          DW 0                    ; вход: текущий адрес
in_end          DW 0                    ; вход: адрес сразу за последним байтом
out_ptr         DW 0                    ; выход: физический адрес записи в кольце
out_seg_base    DW 0                    ; начало ещё не отданного куска
out_flushed     DD 0                    ; сколько байт уже отдано хозяину
out_hist_full   DB 0                    ; 1 — отдано ≥ 32 КиБ, расстояния не проверять
inf_sp          DW 0                    ; стек на входе в ядро (для inf_fail)
inf_last        DB 0                    ; 1 — текущий блок последний
inf_sym         DB 0                    ; временно: номер символа
inf_len         DW 0                    ; длина повтора / LEN блока без сжатия
inf_dist        DW 0                    ; расстояние повтора
inf_tmp         DB 0                    ; временная ячейка
inf_store_count DD 0                    ; сколько байт копировать без сжатия
inf_gb_n        DB 0                    ; inf_getbits: число бит
inf_gb_mask     DB 0                    ; inf_getbits: маска
inf_gb_val      DB 0                    ; inf_getbits: результат
inf_gb_n2       DB 0                    ; расстояние: старшая часть доп. бит
inf_gb_lo       DB 0                    ; расстояние: младшие 8 доп. бит
inf_nlen        DW 0                    ; число кодов литералов/длин
inf_ndist       DB 0                    ; число кодов расстояний
inf_ncode       DB 0                    ; число «кодов длин»
inf_index       DB 0                    ; счётчик при чтении длин
inf_prev        DB 0                    ; предыдущая длина (для символа 16)
inf_lend        DW 0                    ; конец строки длин
inf_dl_desc     DW 0                    ; медленный путь: дескриптор таблицы
inf_dl_code     DW 0                    ; медленный путь: набранный код
inf_dl_cnt      DW 0                    ; медленный путь: адрес count[len]
inf_dl_sym      DW 0                    ; медленный путь: адрес symbol[]
inf_dl_first    DW 0                    ; медленный путь: первый код длины
inf_dl_index    DW 0                    ; медленный путь: номер первого символа
inf_dl_left     DB 0                    ; медленный путь: осталось длин
inf_bd_desc     DW 0                    ; построение: дескриптор таблицы
inf_bd_len      DW 0                    ; построение: адрес массива длин
inf_bd_n        DW 0                    ; построение: число символов
inf_bd_curlen   DB 0                    ; построение: текущая длина кода
inf_bd_incomplete DB 0                  ; построение: 1 — набор неполный
inf_bd_flag     DB 0                    ; построение: значение ячейки LEN
inf_bd_grp      DW 0                    ; построение: текущий символ группы
inf_bd_grp_left DW 0                    ; построение: осталось символов группы
inf_bd_code     DW 0                    ; построение: текущий код
inf_bd_offs     DS 32                   ; offs[0..15]
inf_bd_next     DS 32                   ; next[0..15]
inf_bd_start    DS 32                   ; копия offs до раздачи символов
lt_desc         DB high LT_SYM          ; дескриптор таблицы литералов/длин
                DW lt_count, lt_symbol, 0, 0
dt_desc         DB high DT_SYM          ; дескриптор таблицы расстояний
                DW dt_count, dt_symbol, 0, 0
lt_count        DS 32                   ; count[16] литералов/длин
dt_count        DS 32                   ; count[16] расстояний
lt_symbol       DS 288*2                ; symbol[] литералов/длин
dt_symbol       DS 30*2                 ; symbol[] расстояний
inf_lengths     DS 320                  ; длины кодов (до 286 + 30 штук)
                ENDM

;========================================================================
; ТАБЛИЦЫ, ВЫРОВНЕННЫЕ НА 256 БАЙТ (размещаются через INFLATE_PAGES)
;========================================================================
; Выравнивание нужно, чтобы адрес ячейки собирался из двух байтов без
; сложения: старший байт — номер страницы таблицы, младший — номер ячейки
; (ld b,high ТАБЛИЦА / ld c,номер / ld a,(bc)).
                MACRO INFLATE_PAGES
                ALIGN 256
MISC:           DB 0,1,3,7,15,31,63,127,255     ; M_BITMASK: маски n бит
                DS 32-9
                DB 0,0,0,0,0,0,0,0,1,1,1,1      ; M_LEN_EXTRA
                DB 2,2,2,2,3,3,3,3,4,4,4,4
                DB 5,5,5,5,0
                DS 32-29
                DB 0,0,0,0,1,1,2,2,3,3,4,4      ; M_DIST_EXTRA
                DB 5,5,6,6,7,7,8,8,9,9,10,10
                DB 11,11,12,12,13,13
                DS 32-30
                DB 16,17,18,0,8,7,9,6,10,5      ; M_CODE_ORDER
                DB 11,4,12,3,13,2,14,1,15
                DS 32-19
                DB 3,4,5,6,7,8,9,10             ; M_LEN_BASE_LO
                DB 11,13,15,17,19,23,27,31
                DB 35,43,51,59,67,83,99,115
                DB 131,163,195,227,low 258
                DS 32-29
                DS 28                           ; M_LEN_BASE_HI (все 0, кроме 258)
                DB high 258
                DS 32-29
                DB 1,2,3,4,5,7,9,13             ; M_DIST_BASE_LO
                DB 17,25,33,49,65,97,129,193
                DB low 257,low 385,low 513,low 769
                DB low 1025,low 1537,low 2049,low 3073
                DB low 4097,low 6145,low 8193,low 12289
                DB low 16385,low 24577
                DS 32-30
                DS 16                           ; M_DIST_BASE_HI (первые 16 — нули)
                DB high 257,high 385,high 513,high 769
                DB high 1025,high 1537,high 2049,high 3073
                DB high 4097,high 6145,high 8193,high 12289
                DB high 16385,high 24577
                DS 32-30
                ASSERT $-MISC == 256
REV:            ; REV[x] — байт x, записанный задом наперёд (бит 0 ↔ бит 7 ...)
_rev_i = 0
                DUP 256
                DB ((_rev_i>>7)&1)|((_rev_i>>5)&2)|((_rev_i>>3)&4)|((_rev_i>>1)&8)|((_rev_i<<1)&16)|((_rev_i<<3)&32)|((_rev_i<<5)&64)|((_rev_i<<7)&128)
_rev_i = _rev_i+1
                EDUP
LT_SYM:         DS 256                          ; литералы/длины: младший байт символа
LT_LEN:         DS 256                          ; длина кода, бит 7 — символ ≥ 256
DT_SYM:         DS 256                          ; расстояния: символ
DT_LEN:         DS 256                          ; длина кода расстояния
                ENDM
