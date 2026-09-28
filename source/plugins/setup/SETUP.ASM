; SETUP.WMF — настройки Wild Commander отдельным плагином.
;
; Диалога настроек в ядре больше нет: он занимал место рядом со сжатым
; расширением WildDOS, где счёт идёт на байты. Здесь обычный плагин, который
; читает и пишет wc.ini сам, поэтому ядру остаётся только чтение конфигурации
; при старте.
;
; Тип #03: пункт «WC Setup» в меню плагинов F10, как у любого плагина. Если
; wc.ini нет, ядро при старте говорит «No settings: press F10 and run WC
; Setup.» и грузит встроенный минимум FILEX/PLM/SETUP; здесь тогда открывается
; шаблон с заводскими значениями, и F2 создаёт файл.
;
; Высота окна берётся из текущего текстового режима (#600E — 25, 30 или 36
; строк), список прокручивается, поэтому плагин одинаково работает во всех
; режимах WC.

        DEVICE ZXSPECTRUM128
        INCLUDE "../../VERSION.ASM"             ; WC_VERSION — первая строка wc.ini

; --- публичный интерфейс WC -------------------------------------------------
WLD     EQU #6006       ; диспетчер API: номер в A
HEI     EQU #600E       ; высота текстового экрана: 25, 30 или 36

API_PRWOW   EQU 1       ; нарисовать окно по описателю IX
API_RRESB   EQU 2       ; восстановить фон под окном
API_PRSRW   EQU 3       ; строка в окно: HL текст, BC длина, D/E координаты
API_PRIAT   EQU 4       ; сразу за PRSRW: цвет A' только что выведенного
API_YN      EQU 8       ; кнопки [ YES ]/[ NO ] в окне IX, подкоманда в A'
API_CURSOR  EQU 6       ; зажечь полосу курсора в строке IX+12, её цвет — в IX+15
API_CURSER  EQU 7       ; погасить полосу, вернув строке цвет из IX+15
API_TXTPR   EQU 11      ; размеченный текст
API_SAVE512 EQU 49      ; записать поток поверх прежней цепочки
API_SPACE   EQU 16      ; клавиши: пробел, стрелки, Enter, Esc
API_F2      EQU 30      ; F2 — сохранить wc.ini
API_TAB     EQU 21      ; Tab — переключить экран настроек и плагинов
API_ISTR    EQU 9       ; строковый редактор WC, подкоманда в A'
API_WAITUP  EQU 46      ; ждать, пока отпустят все клавиши
API_WAITKEY EQU 47      ; ждать нажатия любой клавиши
API_MKFILE  EQU 72      ; создать файл: HL -> [атрибут][размер 4][имя,0]
API_RENAME  EQU 74      ; переименовать: HL -> [тип,старое,0], DE -> [новое,0]
API_DELFL   EQU 75      ; удалить: HL -> [тип,имя,0]
API_UP      EQU 17
API_DOWN    EQU 18
API_ENTER   EQU 22
API_ESC     EQU 23
API_PGUP    EQU 25
API_PGDN    EQU 26
API_HOME    EQU 27
API_END     EQU 28
API_LOAD512 EQU 48      ; чтение потока: HL буфер, B блоков
API_ADIR    EQU 56      ; A'=1 — сбросить перебор каталога
API_STREAM  EQU 57      ; потоки: D=#FD — служебный INI-поток в каталоге WC
API_NXTETY2 EQU 58      ; следующая запись каталога в DE
API_FENTRY  EQU 59      ; найти запись: HL -> [тип,имя,0]
API_GFILE   EQU 62      ; выбрать найденный файл и встать на его начало
API_TENTRY  EQU 51      ; за FENTRY: 32 байта записи в DE (кластер +20/+26)

; --- раскладка страницы плагина ---------------------------------------------
; Страница видна в окне #8000. Верхняя четверть #B000..#BFFF принадлежит WC и
; CORE32: любой файловый вызов затирает её, поэтому своих данных там нет.
;
; Всё состояние плагина — текст wc.ini в INIBUF. Настройки правятся в нём на
; месте, отметки и флаги плагинов вписываются в него сразу, а список после
; каждой правки заново читает текст. На экране всегда то, что запишет F2.
; Буферы идут подряд от INIBUF и кончаются ровно на #B000 (последний — поле
; правки флагов EDITBUF). Код растёт до INIBUF: INIBUF поднят с #9000 на
; #9140 — 192 байта над буферами прежде пустовали, — а затем на #91C0
; (2026-09-26, проверка хвостов перед DELFL в SAVE_INI). Оба буфера текста
; укорочены с #C00 до #AC0: 384 байта ушли на восемь лишних записей списка —
; .WMF в каталоге WC бывает больше 32 (на карте пользователя их 33). С
; 2026-09-27 (признак правки, вопрос при выходе, отказ править флаги длиннее
; поля) — ещё на 192 байта каждый, #A00: wc.ini до 2559 байт (поставляемый —
; ~1,7 КиБ).
CODE        EQU #8000   ; код плагина — до INIBUF
INIBUF      EQU #9340   ; текст wc.ini: до #9FF байт и ноль за ним
INISECT     EQU 6       ; столько секторов читаем: хвост шестого ляжет в
                        ; начало NEWBUF, при чтении это черновик
NEWBUF      EQU INIBUF+#A00 ; новый текст при правке, в остальное время черновик:
NEWEND      EQU NEWBUF+#A00
ENTRYBUF    EQU NEWBUF  ;   выход NXTETY2 при переборе каталога
SECTOR      EQU NEWBUF  ;   первый сектор .WMF при чтении заголовков
PLIST       EQU NEWEND  ; найденные .WMF: по PITEM байт на файл
VALUES      EQU PLIST+PMAX*PITEM ; значения настроек: по байту на параметр
PLACES      EQU VALUES+#10 ; адреса их цифр в тексте wc.ini, по два байта
ROWBUF      EQU PLACES+#20 ; строка, которую сейчас печатаем
VARS        EQU ROWBUF+#50 ; переменные плагина, за ними EDITBUF
                        ; #B000..#BFFF принадлежит WC и CORE32

PMAX        EQU 40      ; все .WMF каталога WC; включить можно не больше 32 —
                        ; столько записей в таблице заголовков WC
PITEM       EQU 48      ; запись списка:
                        ;   +0  бит 0 — плагин включён: строка без «;»
PNAME       EQU 1       ;   +1  имя файла 8.3 с нулём (13 байт)
PLINE       EQU 14      ;   +14 адрес строки плагина в тексте или 0
PFLAGS      EQU 16      ;   +16 адрес её флагов (сразу за именем) или 0
PTYPE       EQU 18      ;   +18 тип из заголовка .WMF
PTITLE      EQU 19      ;   +19 название из заголовка, 28 символов с нулём
PGROUP      EQU 47      ;   +47 группа, она же порядок в списке:
GROUP_CORE  EQU 0       ;       обязательные (по имени файла)
GROUP_AUTO  EQU 1       ;       autoexec (#06)
GROUP_MENU  EQU 2       ;       только меню F10: #03 и #11 без расширений
GROUP_SAVER EQU 3       ;       заставка (#02): включена не больше одной
GROUP_FILE  EQU 4       ;       работает с файлами: свои расширения, меню
                        ;       просмотрщиков, F2, F4
NAMEW       EQU 12      ; длиннее 8.3 имя файла в [PLUGINS] не бывает
TITLEW      EQU 28

LINEW       EQU 66      ; ширина строки: название плагина и его флаги
FIELDX      EQU 11+TITLEW       ; колонка флагов в окне, 0 — рамка
FIELDW      EQU LINEW-10-TITLEW ; сколько флагов видно в строке
FLAGW       EQU 64      ; сколько флагов вмещает поле правки
BAR_TRACK   EQU #B0     ; полоса прокрутки: дорожка
BAR_KNOB    EQU #DB     ; и ползунок — как в меню F10

; Заголовок — первые 512 байт файла, в страницу он не грузится. Код собирается
; для окна #8000 через DISP, как того ждёт загрузчик плагинов.
START_CODE:
        DS 16,0
        DB "WildCommanderMDL"
        DB #0A                                  ; версия формата
        DB #00
        DB #01                                  ; одна страница
        DB #00                                  ; страница входа
        DB #00,(FILE_END-MAIN_START+511)/512
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DS 16,0
        DS 32*3,0                               ; расширения не перехватываем
        DB #00
        DD #FFFFFFFF
SETUP_NAME:
        DB "WC Setup v0.1"
        DS 32-($-SETUP_NAME)," "
        DB #03                                  ; тип: меню плагинов F10
        DB #00

        ALIGN 512,0
MAIN_START:
        DISP CODE

; --- вход -------------------------------------------------------------------
; Из меню F10: A=#03. IX — панель, её WC ждёт обратно.
ENTRY:
        PUSH IX
        CALL SCREEN
        POP IX
        LD A,3                                  ; WC перечитает обе панели: после F2
        RET                                     ; у wc.ini новые кластер, размер и дата

; --- чтение wc.ini ----------------------------------------------------------
; Выход: CF=0 — файл прочитан в INIBUF и закрыт нулём; CF=1 — файла нет
; (в INIBUF шаблон нового wc.ini) или он длиннее буфера (текст пуст).
READ_INI:
        CALL ENTER_WC
        JR NZ,.missing
        LD HL,INI_QUERY
        LD A,API_FENTRY
        CALL WLD
        JR NZ,.found
        JR NC,.missing                          ; Z, CF=0 — файла нет
        LD A,3                                  ; Z, CF=1 — каталог не прочитался: файл,
        JR .refuse                              ; может быть, есть — шаблон поверх нельзя
.found:
        LD A,D                                  ; размер в DE:HL: не меньше буфера —
        OR E                                    ; не примет, нулю за текстом не встать
        JR NZ,.too_long
        LD DE,NEWBUF-INIBUF                     ; CF=0 после OR
        SBC HL,DE
        ADD HL,DE
        JR NC,.too_long
        LD (FILE_LEN),HL
        LD A,API_GFILE
        CALL WLD
        LD HL,INIBUF
        LD B,INISECT                            ; 3 КиБ: wc.ini заметно меньше
        LD A,API_LOAD512
        CALL WLD
        LD A,3                                  ; 3 — не прочитался: текст недостоверен,
        JR C,.refuse                            ; поверх исправного файла его не пишем
        LD HL,(FILE_LEN)                        ; конец текста — по размеру файла,
        LD DE,INIBUF                            ; а не по прочитанным секторам:
        ADD HL,DE                               ; хвост сектора — не текст
        LD (INI_SIZE),HL
        LD (HL),0
        XOR A
        LD (INI_STATE),A                        ; 0 — файл прочитан
        RET
.too_long:
        LD A,2                                  ; 2 — не помещается, не пишем
.refuse:
        LD BC,0
        JR .fill
.missing:
        LD A,1                                  ; 1 — файла нет: начнём с шаблона
        LD BC,DEFAULT_SIZE
.fill:
        LD (INI_STATE),A
        LD HL,DEFAULT_INI
        LD DE,INIBUF
        LD A,B
        OR C
        JR Z,.empty
        LDIR
.empty:
        EX DE,HL
        LD (INI_SIZE),HL
        LD (HL),0
        SCF
        RET

; Шаблон нового wc.ini: значения — как в поставке WC, из плагинов включены
; только обязательные и сам SETUP.WMF, остальные отмечаются на втором экране.
DEFAULT_INI:
        DB WC_VERSION,13,13
        DB "[SETUP]",13
        DB "CPU_FREQ=2",13
        DB "SavePaths=1",13
        DB "SavePosition=1",13
        DB "TextMode=2",13
        DB "Logo=1",13
        DB "ScreenSaver=9",13,13
        DB "[PLUGINS]",13
        DB "FILEX.WMF",13
        DB "PLM.WMF",13
        DB "SETUP.WMF",13,13
        DB "[LPANEL]",13
        DB "DRV=1",13
        DB "INFO=1",13
        DB "CSORT=2",13,13
        DB "[RPANEL]",13
        DB "DRV=1",13
        DB "INFO=1",13
        DB "CSORT=2",13
DEFAULT_SIZE EQU $-DEFAULT_INI

; Каталог WC в служебном INI-потоке ядра — оттуда WC читает wc.ini при
; старте. Потоки панелей не трогаем, и неважно, где панели стоят.
; Выход: Z — каталог выбран; NZ — нет устройства или каталога WC.
ENTER_WC:
        LD D,#FD
        LD A,API_STREAM
        JP WLD

INI_QUERY:
        DB #00                                  ; файл
        DB "wc.ini",0

; --- экраны -----------------------------------------------------------------
; Первый экран — настройки WC, второй — плагины. Tab переключает их, потому
; что в одном окне удобнее держать всё, что относится к конфигурации.
SCREEN:
        XOR A
        LD (PCOUNT),A                           ; список прочтём на экране плагинов
        LD (SCREEN_NO),A
        LD (QUIET),A
        LD (MODIFIED),A                         ; правок нет; шаблон вместо ненайденного
        CALL READ_INI                           ; файла — тоже не правка
        CALL TEXT_CHANGED
        CALL OPEN_SCREEN
        LD A,(INI_STATE)
        DEC A
        LD HL,MSG_NEW
        JR Z,.tell                              ; файла нет — F2 создаст его
        DEC A
        LD HL,MSG_LONG
        JR Z,.tell                              ; файл не лёг в буфер
        DEC A
        JR NZ,.loop
        LD HL,MSG_UNREAD                        ; файл не прочитался
.tell:
        CALL SHOW_MESSAGE
.loop:
        EI
        HALT
        LD IX,WND
        LD A,API_CURSOR
        CALL WLD
        LD A,API_UP
        CALL WLD
        LD B,1
        CALL NZ,UP_BY
        LD A,API_DOWN
        CALL WLD
        LD B,1
        CALL NZ,DOWN_BY
        LD A,API_PGUP
        CALL WLD
        CALL NZ,PAGE_UP
        LD A,API_PGDN
        CALL WLD
        CALL NZ,PAGE_DOWN
        LD A,API_HOME
        CALL WLD
        CALL NZ,GO_HOME
        LD A,API_END
        CALL WLD
        CALL NZ,GO_END
        LD A,API_SPACE
        CALL WLD
        CALL NZ,CHANGE
        LD A,API_ENTER
        CALL WLD
        CALL NZ,ENTER_KEY
        LD A,API_TAB
        CALL WLD
        CALL NZ,SWITCH_SCREEN
        LD A,API_F2
        CALL WLD
        CALL NZ,SAVE_INI
        LD A,API_ESC
        CALL WLD
        JP Z,.loop
        CALL LEAVE_ASK                          ; изменения не сохранены — вопрос
        JP NZ,.loop
        JP CLOSE_SCREEN

; Esc (2026-09-27). Текст не правили с чтения или записи — выход. Правили —
; вопрос в том же окне: «Save changed settings?» и кнопки WC [ YES ]/[ NO ]
; (API 8) в нижней строке списка. Yes — то же, что F2: записан — выход, не
; записан — сообщение и назад к списку; No — выход без записи; Esc — назад к
; списку. Выход: Z — закрывать окно.
LEAVE_ASK:
        LD A,(MODIFIED)
        OR A
        RET Z
        LD HL,MSG_ASK
        CALL SHOW_TEXT
        LD A,API_WAITUP                         ; Esc отпущен — он не ответит за нас
        CALL WLD
        LD A,2                                  ; кнопки Yes/No, выбрана Yes
        CALL .yn
.frame:
        EI
        HALT
        XOR A                                   ; кадр: стрелки выбирают кнопку
        CALL .yn
        LD A,API_ENTER
        CALL WLD
        JR NZ,.chosen
        LD A,API_ESC
        CALL WLD
        JR Z,.frame
        LD A,API_WAITUP
        CALL WLD
        CALL PAINT                              ; назад к списку
        OR 1                                    ; NZ — остаться
        RET
.chosen:
        LD A,API_WAITUP
        CALL WLD
        LD A,#FF                                ; Z — выбрана Yes
        CALL .yn
        JR Z,.save
        XOR A                                   ; No: выход без записи
        RET
.save:
        LD A,1
        LD (QUIET),A                            ; «wc.ini saved» не показывать: выходим
        CALL SAVE_INI
        XOR A
        LD (QUIET),A
        LD A,(MODIFIED)                         ; Z — записан; NZ — нет, сообщение было
        OR A
        RET
.yn:
        EX AF,AF'
        LD IX,WND
        LD A,API_YN
        JP WLD

; Текст правили: он уже не тот, что на носителе, — «*» и красный заголовок.
; Признак ставится только там, где текст на самом деле стал другим (цифра
; параметра, вписанный ключ, COPY_NEW с отличием), и снимается только удачной
; записью. Контрольная сумма вместо него не годится: у 16-битной суммы
; совпадали реальные пары правок, и Esc выходил без вопроса. Разрушает A.
MARK_MODIFIED:
        LD A,1
        LD (MODIFIED),A
        RET

; Заголовок окна поверх того, что нарисовал PRWOW, на том же месте: название
; по центру строки 0, а перед ним — пробел, если текст не правили, и «*», если
; правили (MODIFIED); тогда всё название красное на том же белом фоне (как
; «ERROR:» окна ошибки WC).
DRAW_TITLE:
        LD A,(MODIFIED)
        OR A
        LD A," "
        JR Z,.mark
        LD A,"*"
.mark:
        LD (ROWBUF),A
        LD A,(SCREEN_NO)
        OR A
        LD HL,TITLE_SETUP+2                     ; за #0E,#09
        JR Z,.copy_start
        LD HL,TITLE_PLUGS+2
.copy_start:
        LD DE,ROWBUF+1
        LD C,1
.copy:
        LD A,(HL)
        OR A
        JR Z,.copied
        LD (DE),A
        INC HL
        INC DE
        INC C
        JR .copy
.copied:
        LD A,LINEW+1                            ; PRWOW: название с колонки
        SUB C                                   ; (ширина-длина)/2, ширина — LINEW+2;
        SRL A                                   ; «*» — на колонку левее, C — с ней
        LD E,A
        LD D,0
        LD B,D
        LD HL,ROWBUF
        CALL PRSRW_WND
        LD A,(ROWBUF)
        CP "*"
        LD A,(WND+6)
        RRCA                                    ; бумага и чернила окна местами —
        RRCA                                    ; цвет заголовка
        RRCA
        RRCA
        JR NZ,.paint
        AND #F0
        OR 2                                    ; чернила красные
.paint:
        EX AF,AF'
        LD A,API_PRIAT
        JP WLD

; Собрать строки текущего экрана и открыть под них окно нужной высоты.
OPEN_SCREEN:
        CALL REFRESH
        LD IX,WND
        LD A,(SCREEN_NO)
        OR A
        LD HL,TITLE_SETUP
        LD DE,FOOT_SETUP
        JR Z,.title
        LD HL,TITLE_PLUGS
        LD DE,FOOT_PLUGS
.title:
        LD (IX+16),L
        LD (IX+17),H
        LD (IX+18),E
        LD (IX+19),D
        LD (IX+2),255                           ; PRWOW пишет сюда вычисленный
        LD (IX+3),255                           ; центр, а высота у экранов разная
        LD A,(HEI)
        SUB 5                                   ; рамка окна и строка клавиш
        LD B,A
        LD A,(COUNT)
        CP B
        JR C,.fits
        LD A,B
.fits:
        LD (SHOWN),A
        LD (IX+13),A
        ADD A,2
        LD (IX+5),A
        LD (IX+12),1
        XOR A
        LD (TOP),A
        LD A,API_PRWOW
        CALL WLD
        JP PAINT

CLOSE_SCREEN:
        LD IX,WND
        LD A,API_RRESB
        JP WLD

SWITCH_SCREEN:
        CALL CLOSE_SCREEN
        LD A,(SCREEN_NO)
        XOR 1
        LD (SCREEN_NO),A
        JP OPEN_SCREEN

; Строки и их число для текущего экрана.
REFRESH:
        LD A,(SCREEN_NO)
        OR A
        JR NZ,.plugins
        LD A,PARAM_COUNT
        LD (COUNT),A
        RET
.plugins:
        CALL SCAN_PLUGINS
        CALL READ_TITLES
        CALL SORT_PLUGINS
        LD A,(PCOUNT)
        LD (COUNT),A
        RET

; Пробел и Enter меняют значение строки под курсором по кругу и правят цифру
; прямо в тексте wc.ini: размер файла не меняется, комментарии не страдают.
CHANGE:
        LD A,(SCREEN_NO)
        OR A
        JP NZ,TOGGLE_PLUGIN
        CALL CURRENT                            ; A — номер параметра
        LD (CURRENT_NO),A
        LD L,A
        LD H,0
        LD DE,VALUES
        ADD HL,DE
        PUSH HL                                 ; адрес значения
        LD A,(CURRENT_NO)
        CALL PARAM_AT                           ; IX — описание параметра
        POP HL
        LD A,(HL)
        INC A
        CP (IX+8)
        JR C,.store
        XOR A
.store:
        LD (HL),A
        ADD A,"0"
        LD (DIGIT),A
        LD A,(CURRENT_NO)
        ADD A,A
        LD L,A
        LD H,0
        LD DE,PLACES
        ADD HL,DE
        LD E,(HL)
        INC HL
        LD D,(HL)
        LD A,D
        OR E
        JR Z,.insert                            ; ключа в тексте нет — вписать строку
        LD A,(DIGIT)
        LD (DE),A
.redraw:
        CALL MARK_MODIFIED                      ; цифра — следующее значение или ключ вписан
        JP PAINT
.insert:
        CALL INSERT_KEY
        JR NC,.redraw
        CALL TEXT_CHANGED                       ; не влезла: значение — снова из текста
        LD HL,MSG_FULL
        JP SHOW_MESSAGE

; Ключа параметра IX в тексте нет: вписать строку «КЛЮЧ=цифра» (цифра — DIGIT)
; сразу за заголовком своей секции, а если нет и секции — дописать её в конец
; текста. Текст затем разбирается заново, и адрес цифры появляется в PLACES.
; Раньше такой параметр менялся только на экране и в файл не попадал.
; Выход: CF=1 — текст не поместился бы в буфер, он не тронут.
INSERT_KEY:
        LD HL,NEWBUF                            ; вставку собираем в черновике
        LD (NEWPTR),HL
        LD L,(IX+0)
        LD H,(IX+1)                             ; «[СЕКЦИЯ]»
        LD DE,INIBUF
        PUSH HL
        CALL FIND_KEY
        POP HL
        JR C,.no_section
.eol:
        LD A,(DE)                               ; DE — за заголовком: до конца строки
        CALL IS_EOL
        JR Z,.eol_found
        INC DE
        JR .eol
.eol_found:
        OR A
        JR Z,.last_line                         ; заголовок — последняя строка без перевода
        INC DE
        CP 13
        JR NZ,.key
        LD A,(DE)
        CP 10
        JR NZ,.key
        INC DE                                  ; CR LF
        JR .key
.no_section:
        LD A,13
        CALL EMIT                               ; пустая строка перед новой секцией
        CALL EMIT_TEXT                          ; «[СЕКЦИЯ]»
        LD DE,(INI_SIZE)                        ; место — конец текста
.last_line:
        LD A,13
        CALL EMIT
.key:
        PUSH DE
        LD L,(IX+2)
        LD H,(IX+3)
        CALL EMIT_TEXT                          ; «КЛЮЧ=»
        LD A,(DIGIT)
        CALL EMIT
        LD A,13
        CALL EMIT
        POP DE
        LD (INSPOS),DE
        LD HL,(NEWPTR)
        LD DE,NEWBUF
        OR A
        SBC HL,DE
        LD (INSLEN),HL                          ; длина вставки
        LD DE,(INI_SIZE)                        ; прежний конец текста, там ноль
        ADD HL,DE
        LD BC,NEWBUF
        OR A
        SBC HL,BC
        CCF
        RET C                                   ; новый конец не ниже NEWBUF — не влезет
        ADD HL,BC
        LD (INI_SIZE),HL
        EX DE,HL                                ; DE — новый конец, HL — прежний
        PUSH HL
        LD BC,(INSPOS)
        OR A
        SBC HL,BC
        LD B,H
        LD C,L
        INC BC                                  ; хвост вместе с нулём
        POP HL
        LDDR                                    ; хвост — выше на длину вставки
        LD HL,NEWBUF
        LD DE,(INSPOS)
        LD BC,(INSLEN)
        LDIR                                    ; вставка — на её место
        CALL TEXT_CHANGED
        OR A
        RET

; Enter: на экране настроек — то же, что пробел; на экране плагинов —
; правка флагов строки.
ENTER_KEY:
        LD A,(SCREEN_NO)
        OR A
        JP Z,CHANGE
        JP EDIT_FLAGS

; Пробел на экране плагинов ставит и снимает отметку «использовать» и сразу
; переносит её в текст wc.ini. Обязательный плагин можно отметить, но не снять.
; Заставку WC держит одну: включённая заставка выключает остальные.
TOGGLE_PLUGIN:
        LD A,(PCOUNT)
        OR A
        RET Z                                   ; список пуст: курсор не на записи
        CALL CURRENT
        CALL PLUGIN_AT                          ; HL — запись
        PUSH HL
        LD DE,PGROUP
        ADD HL,DE
        LD A,(HL)
        POP HL
        LD C,A                                  ; группа
        OR A
        JR NZ,.flip
        BIT 0,(HL)
        RET NZ                                  ; обязательный уже включён
.flip:
        LD A,(HL)
        XOR 1
        LD (HL),A
        RRA
        JR NC,.apply                            ; выключили — других не трогаем
        LD A,C
        CP GROUP_SAVER
        JR NZ,.apply
        EX DE,HL                                ; DE — включённая заставка
        LD HL,PLIST
        LD A,(PCOUNT)
        LD B,A
.saver:
        PUSH BC
        LD BC,PGROUP
        ADD HL,BC
        LD A,(HL)
        OR A
        SBC HL,BC                               ; снова начало записи
        CP GROUP_SAVER
        JR NZ,.next
        OR A
        SBC HL,DE
        ADD HL,DE
        JR Z,.next                              ; сама включённая
        RES 0,(HL)
.next:
        LD BC,PITEM
        ADD HL,BC
        POP BC
        DJNZ .saver
.apply:
        JP APPLY

; Номер параметра под курсором: верх списка плюс строка окна.
CURRENT:
        LD IX,WND
        LD A,(IX+12)
        DEC A
        LD B,A
        LD A,(TOP)
        ADD A,B
        RET

; IX — описание параметра номер A.
PARAM_AT:
        LD IX,PARAMS
        OR A
        RET Z
        LD B,A
        LD DE,PARAM_SIZE
.step:
        ADD IX,DE
        DJNZ .step
        RET

; --- сохранение wc.ini -------------------------------------------------------
; Текст в INIBUF уже готов, пишем его как есть. Файл пишется через временный
; wc.new: если его создать не удалось (например, в каталоге нет свободных
; записей), старый wc.ini остаётся нетронутым.
SAVE_INI:
        LD A,(INI_STATE)
        CP 2
        JP NC,.failed                           ; файл больше буфера или не прочитался —
                                                ; не трогаем
        CALL STAMP_VERSION
        JP C,.failed                            ; с новой версией не поместился
        LD HL,(INI_SIZE)
        LD DE,INIBUF
        OR A
        SBC HL,DE
        JP Z,.failed                            ; пустой текст не пишем
        LD (NEW_SIZE),HL
        CALL ENTER_WC
        JP NZ,.failed
; Claude - 2026-09-26 - begin
        ; Хвосты прошлой неудачной попытки удаляются DELFL — но после двойного
        ; сбоя RENAME (ядро: Z, A=#FF) хвост мог остаться второй записью на
        ; цепочке wc.ini, и DELFL освободил бы данные wc.ini, а их кластеры
        ; потом ушли бы другому файлу (аудит Codex, R12-1). Хвост, который
        ; начинается с того же кластера, что wc.ini, не удаляется, как и хвост,
        ; чью цепочку не удалось сверить (ошибка чтения каталога): сохранение
        ; отказывает с просьбой проверить диск (TAIL_ON_INI_CHAIN).
        LD HL,NEW_QUERY
        CALL TAIL_ON_INI_CHAIN
        JP Z,.check_disk
; Claude - 2026-09-26 - end
        LD HL,NEW_QUERY
        LD A,API_DELFL
        CALL WLD                                ; хвост прошлой неудачной записи
        LD HL,NEW_MAKE
        LD A,API_MKFILE
        CALL WLD
        JP NZ,.failed                           ; создать не вышло — старый цел
        LD HL,NEW_QUERY
        LD A,API_FENTRY
        CALL WLD
        JP Z,.failed
        LD A,API_GFILE
        CALL WLD
        LD HL,(NEW_SIZE)
        DEC HL
        LD A,H
        SRL A
        INC A
        LD B,A                                  ; секторов с округлением вверх
        LD HL,INIBUF
        LD A,API_SAVE512
        CALL WLD
        JR C,.failed
; Замена с запасной копией: прежний wc.ini сначала откладывается в wc.old, новый
; встаёт на его имя, и только потом wc.old удаляется. Если новый встать не
; смог, делается попытка вернуть wc.old на место, и выводится «wc.ini was NOT
; saved» («check the disk», если это переименование или возврат вернули A=#FF
; — см. ниже). Полной гарантии нет при
; сбоях носителя внутри RENAME: любое из переименований может оставить файл
; без имени (цепочка — потерянными кластерами) или две записи на одной
; цепочке (A=#FF). Удалять такие хвосты следующему сохранению нельзя: DELFL
; освободил бы цепочку, общую с wc.ini, — поэтому хвост с первым кластером
; wc.ini не удаляется (TAIL_ON_INI_CHAIN, с 2026-09-26). A=#FF от любого из
; переименований сразу даёт «wc.ini: check the disk»: вторая запись на
; цепочке может потом получить другое имя, и её SETUP уже не найдёт, — том
; надо проверить до работы с этими файлами. Такие исходы возможны только с
; драйвером, сообщающим ошибки носителя (штатные их не сообщают). Результаты
; RENAME при сохранении проверяются: иначе прежний файл той же длины сходил
; за сохранённый.
; Claude - 2026-09-26 - begin
        LD HL,OLD_QUERY
        CALL TAIL_ON_INI_CHAIN
        JP Z,.check_disk
; Claude - 2026-09-26 - end
        LD HL,OLD_QUERY
        LD A,API_DELFL
        CALL WLD                                ; хвост прошлой неудачной замены
        LD HL,INI_QUERY
        LD DE,OLD_QUERY+1
        LD A,API_RENAME
        CALL WLD                                ; wc.ini -> wc.old
        JR NZ,.aside
; Claude - 2026-09-26 - begin
        ; A=#FF от RENAME — исход неизвестен: на цепочке могут остаться обе
        ; записи. Такой том нужно проверить до любой работы с этими файлами:
        ; переименованную потом копию SETUP уже не увидит, а удаление любой из
        ; двух записей освободит данные другой (аудит Codex, R14-1).
        CP #FF:JR Z,.check_disk
; Claude - 2026-09-26 - end
        LD A,(INI_STATE)
        OR A
        JR Z,.failed                            ; прежний был, но не отложился (обычно
                                                ; цел; сбои носителя в RENAME — см. выше)
.aside:
        LD HL,NEW_QUERY
        LD DE,INI_QUERY+1
        LD A,API_RENAME
        CALL WLD                                ; wc.new -> wc.ini
        JR NZ,.placed
; Claude - 2026-09-26 - begin
        PUSH AF                                 ; код отказа wc.new -> wc.ini
; Claude - 2026-09-26 - end
        LD HL,OLD_QUERY                         ; не встал — вернуть прежний
        LD DE,INI_QUERY+1
        LD A,API_RENAME
        CALL WLD
; Claude - 2026-09-26 - begin
        POP BC
        JR NZ,.back                             ; прежний вернулся на имя
        CP #FF:JR Z,.check_disk                 ; возврат: исход неизвестен
.back:
        LD A,B
        CP #FF:JR Z,.check_disk                 ; wc.new -> wc.ini: исход неизвестен
; Claude - 2026-09-26 - end
        JR .failed
.placed:
        LD HL,OLD_QUERY
        LD A,API_DELFL
        CALL WLD                                ; прежний больше не нужен
        LD HL,INI_QUERY                         ; wc.ini на месте и нужной длины?
        LD A,API_FENTRY
        CALL WLD
        JR Z,.failed
        LD DE,(NEW_SIZE)
        OR A
        SBC HL,DE
        JR NZ,.failed
        XOR A
        LD (INI_STATE),A                        ; теперь файл есть
        LD (MODIFIED),A                         ; текст на носителе: заголовок обычный
        LD A,(QUIET)
        OR A
        RET NZ                                  ; записан по вопросу при выходе
        CALL DRAW_TITLE                         ; обычный — уже под «wc.ini saved»
        LD HL,MSG_SAVED
        JP SHOW_MESSAGE
.failed:
        LD HL,MSG_FAILED
        JP SHOW_MESSAGE
; Claude - 2026-09-26 - begin
.check_disk:
        LD HL,MSG_CHECK
        JP SHOW_MESSAGE

; Z — хвост по HL (wc.new или wc.old) удалять нельзя: он есть, wc.ini тоже
; есть и начинается с того же первого кластера (хвост — вторая запись на
; цепочке wc.ini после сбоя RENAME), либо каталог не прочитался (FENTRY: Z и
; CF=1) — тогда общую цепочку не исключить (аудит Codex, R13-1). NZ — удалять
; можно: хвоста или wc.ini нет, либо цепочки разные. Кластер — из записи,
; которую отдаёт TENTRY (API 51) сразу за FENTRY: +20 — старшее слово, +26 —
; младшее. Размер для этого не годится (так было до R13-2): после сбоя RENAME
; обычный APPEND к wc.ini меняет размер только в его записи, а цепочка
; остаётся общей. Записи кладутся в черновик NEWBUF: текст для записи — в
; INIBUF. У двух пустых файлов первый кластер 0 у обоих — это тоже Z: ложный,
; но безопасный отказ (SETUP пустых wc.* не создаёт; на исключение для нуля
; места в плагине нет).
TAIL_ON_INI_CHAIN:
        LD DE,ENTRYBUF                          ; запись хвоста
        CALL .entry
        RET NC                                  ; не прочитан (Z) или хвоста нет (NZ)
        LD HL,INI_QUERY
        LD DE,ENTRYBUF+32                       ; запись wc.ini
        CALL .entry
        RET NC
        LD HL,ENTRYBUF+20
        LD DE,ENTRYBUF+32+20
        CALL .word                              ; старшее слово кластера
        RET NZ
        LD L,low (ENTRYBUF+26)
        LD E,low (ENTRYBUF+32+26)
.word:
        LD A,(DE):CP (HL):RET NZ
        INC HL:INC DE
        LD A,(DE):CP (HL)
        RET                                     ; Z — слово совпало
; FENTRY по HL и TENTRY в DE. Выход: CF=1 — запись найдена и скопирована;
; иначе Z — каталог не прочитался, NZ — записи нет.
.entry:
        PUSH DE
        LD A,API_FENTRY
        CALL WLD
        POP DE
        JR NZ,.found
        CCF                                     ; Z остаётся: CF=1 ошибки -> CF=0
        RET NC                                  ; каталог не прочитан: Z, CF=0
        OR 1                                    ; записи нет: NZ, CF=0
        RET
.found:
        LD A,API_TENTRY
        CALL WLD
        SCF
        RET
        ASSERT high (ENTRYBUF+26) == high (ENTRYBUF+20), кластер записи пересёк страницу
        ASSERT high (ENTRYBUF+32+26) == high (ENTRYBUF+32+20), кластер записи пересёк страницу
; Claude - 2026-09-26 - end

NEW_MAKE:
        DB #00                                  ; атрибут
NEW_SIZE:
        DW 0,0                                  ; размер, 32 бита
        DB "wc.new",0
NEW_QUERY:
        DB #00
        DB "wc.new",0
OLD_QUERY:
        DB #00                                  ; прежний wc.ini на время замены
        DB "wc.old",0

; Первая строка wc.ini — версия WC: по её префиксу ядро узнаёт свой файл.
; Прежнюю строку версии заменяем текущей, а если её не было — вставляем
; перед текстом. Выход: CF=1 — текст с новой строкой не поместился.
STAMP_VERSION:
        LD HL,NEWBUF
        LD (NEWPTR),HL
        LD HL,VERSION_TEXT
        CALL EMIT_TEXT
        RET C
        LD HL,INIBUF
        LD DE,VERSION_TEXT
        LD B,VERSION_PREFIX
.same:
        LD A,(DE)
        CP (HL)
        JR NZ,.insert                           ; первая строка — не версия
        INC HL
        INC DE
        DJNZ .same
.skip:
        LD A,(HL)                               ; прежнюю версию до конца строки
        CALL IS_EOL
        JR Z,.rest
        INC HL
        JR .skip
.insert:
        LD A,13
        CALL EMIT
        RET C
        LD A,13
        CALL EMIT                               ; пустая строка перед секциями
        RET C
        LD HL,INIBUF
.rest:
        LD DE,(INI_SIZE)
        CALL EMIT_RANGE
        RET C
        JR COPY_NEW

VERSION_TEXT    DB WC_VERSION,0
VERSION_PREFIX  EQU 14                          ; «Wild Commander»

; --- правка текста ----------------------------------------------------------
; Перенести отметки и правку флагов в текст: он собирается заново в NEWBUF и
; копируется на место. Не поместился — текст прежний, отметки — как в нём.
APPLY:
        CALL BUILD_NEW_INI
        JR C,.full
        CALL COPY_NEW
        JP PAINT
.full:
        CALL TEXT_CHANGED
        LD HL,MSG_FULL
        JP SHOW_MESSAGE

; Новый текст из NEWBUF — на место прежнего. Другой длины или хоть с одним
; другим байтом — текст правили (MARK_MODIFIED). Строка версии, которая уже та
; же, собирает его точно таким же; флаги, подтверждённые без правки, — тоже,
; если в строке не было лишних пробелов: поле их убирает (ведущие, хвостовые,
; второй пробел после имени), и такой текст уже другой (аудит Codex R36-2).
COPY_NEW:
        LD HL,(NEWPTR)
        LD DE,NEWBUF
        OR A
        SBC HL,DE
        LD B,H
        LD C,L                                  ; длина нового текста
        LD HL,INIBUF
        ADD HL,BC                               ; новый конец, CF=0
        LD DE,(INI_SIZE)
        EX DE,HL
        SBC HL,DE
        CALL NZ,MARK_MODIFIED                   ; длина другая
        EX DE,HL
        LD (INI_SIZE),HL
        LD (HL),0
        LD HL,NEWBUF
        LD DE,INIBUF
.copy:
        LD A,B
        OR C
        JR Z,TEXT_CHANGED
        LD A,(DE)
        CP (HL)
        CALL NZ,MARK_MODIFIED                   ; байт другой
        LDI
        JR .copy

; Текст сменился: заново найти секцию, параметры и строки плагинов.
TEXT_CHANGED:
        LD HL,0
        LD (EDITREC),HL                         ; правка флагов уже в тексте
        CALL FIND_PLUGINS
        CALL PARSE_SETUP
        JP RELINK

; Собрать новый текст в NEWBUF. Выход: CF=1 — не поместился.
BUILD_NEW_INI:
        LD HL,NEWBUF
        LD (NEWPTR),HL
        LD DE,(PLUGSEC)
        LD A,D
        OR E
        JR Z,.no_section
        LD HL,INIBUF
        CALL EMIT_RANGE                         ; всё до секции и её заголовок
        RET C
        CALL EMIT_SECTION                       ; HL — конец секции
        RET C
        CALL TRIM_BREAKS
        PUSH HL
        CALL EMIT_NEW_PLUGINS
        POP HL
        RET C
        LD DE,(INI_SIZE)
        JR EMIT_RANGE                           ; пустые строки и остаток файла
.no_section:
        LD HL,INIBUF                            ; секции нет — дописать её
        LD DE,(INI_SIZE)
        CALL EMIT_RANGE
        RET C
        LD HL,PLUGHEAD
        CALL EMIT_TEXT
        RET C
        CALL EMIT_NEW_PLUGINS
        RET C
        LD A,13
        JR EMIT

; Отступить от конца секции за пустые строки: новые плагины встанут сразу за
; последней строкой, пустые останутся перед следующей секцией. Переводы строк
; в NEWBUF — точная копия текста, поэтому отступаем в обоих поровну.
; Вход: HL — конец секции в тексте.
TRIM_BREAKS:
        LD DE,(PLUGSEC)
.back:
        OR A
        SBC HL,DE
        ADD HL,DE
        RET Z                                   ; дошли до заголовка секции
        DEC HL
        LD A,(HL)
        CP 13
        JR Z,.cut
        CP 10
        JR Z,.cut
        INC HL
        RET
.cut:
        PUSH HL
        LD HL,(NEWPTR)
        DEC HL
        LD (NEWPTR),HL
        POP HL
        JR .back

; Вывести байты от HL до DE, не включая DE. CF=1 — буфер кончился.
EMIT_RANGE:
        LD A,H
        CP D
        JR NZ,.byte
        LD A,L
        CP E
        RET Z                                   ; CF=0
.byte:
        LD A,(HL)
        CALL EMIT
        RET C
        INC HL
        JR EMIT_RANGE

; Вывести текст HL до нуля. CF=1 — буфер кончился.
EMIT_TEXT:
        LD A,(HL)
        OR A
        RET Z
        CALL EMIT
        RET C
        INC HL
        JR EMIT_TEXT

; Записать байт A в новый текст. CF=1 — места нет: текст должен лечь в
; INIBUF вместе с завершающим нулём.
EMIT:
        PUSH HL
        LD HL,(NEWPTR)
        PUSH AF
        LD A,H
        CP high (NEWEND-1)
        JR C,.room
        LD A,L
        CP low (NEWEND-1)
        JR NC,.full
.room:
        POP AF
        LD (HL),A
        INC HL
        LD (NEWPTR),HL
        POP HL
        OR A
        RET
.full:
        POP AF
        POP HL
        SCF
        RET

; Пройти секцию [PLUGINS] построчно. Вход: HL — начало секции. Выход: HL —
; начало следующей секции или конец текста.
EMIT_SECTION:
        LD A,(HL)
        OR A
        RET Z
        CP "["
        RET Z                                   ; дальше другая секция
        CALL IS_EOL
        JR Z,.eol
        CALL EMIT_PLUGIN_LINE                   ; HL — за строкой
        RET C
        JR EMIT_SECTION
.eol:
        CALL EMIT
        RET C
        INC HL
        JR EMIT_SECTION

; Строка секции. Строку, которой владеет запись списка, выводим по её
; состоянию: снятая отметка — «;» в начале, у правленой записи — новые флаги.
; Прочие строки — комментарии, чужие имена, повторы — переходят как есть.
EMIT_PLUGIN_LINE:
        CALL LINE_OWNER                         ; DE — запись или CF
        LD HL,(LINEHEAD)
        JR C,EMIT_REST
        LD A,(HL)
        CP ";"
        JR NZ,.named
        INC HL                                  ; прежнюю «;» решает отметка
.named:
        LD A,(DE)
        RRCA
        JR C,.on
        LD A,";"                                ; отметку сняли — строка выключена
        CALL EMIT
        RET C
.on:
        PUSH HL
        CALL IS_EDITED
        POP HL
        JR NZ,EMIT_REST                         ; флаги не правили — как было
.name:
        LD A,(HL)
        CALL WORD_END
        JR Z,.flags
        CALL EMIT
        RET C
        INC HL
        JR .name
.flags:
        CALL EMIT_FLAGS
        RET C
.skip:
        LD A,(HL)                               ; прежние флаги пропустить,
        CP ";"                                  ; подсказку за ними оставить
        JR Z,EMIT_REST
        CALL IS_EOL
        RET Z
        INC HL
        JR .skip

; Остаток строки как есть.
EMIT_REST:
        LD A,(HL)
        CALL IS_EOL
        RET Z
        CALL EMIT
        RET C
        INC HL
        JR EMIT_REST

; Поле правки как флаги: пробел и текст; пустое поле не выводит ничего.
EMIT_FLAGS:
        LD A,(EDITLEN)
        OR A
        RET Z
        LD B,A
        LD A," "
        CALL EMIT
        RET C
        LD DE,EDITBUF
.copy:
        LD A,(DE)
        CALL EMIT
        RET C
        INC DE
        DJNZ .copy
        RET

; Запись, которой принадлежит строка HL. Выход: DE — запись, CF=0; CF=1 —
; строка ничья. LINEHEAD — начало строки.
LINE_OWNER:
        LD (LINEHEAD),HL
        LD HL,PLIST
        LD A,(PCOUNT)
        OR A
        SCF
        RET Z
        LD B,A
.item:
        PUSH HL
        LD DE,PLINE
        ADD HL,DE
        LD E,(HL)
        INC HL
        LD D,(HL)                               ; DE — строка записи
        LD HL,(LINEHEAD)
        OR A
        SBC HL,DE
        POP DE                                  ; DE — запись
        RET Z
        LD HL,PITEM
        ADD HL,DE
        DJNZ .item
        SCF
        RET

; Z — запись DE та, чьи флаги сейчас правили. Портит HL, CF=0.
IS_EDITED:
        LD HL,(EDITREC)
        OR A
        SBC HL,DE
        LD A,H
        OR L
        RET

; Дописать строки плагинов, которых в секции нет: отмеченных и того, чьи
; флаги правили. Каждая строка начинается с перевода строки.
EMIT_NEW_PLUGINS:
        LD HL,PLIST
        LD A,(PCOUNT)
        OR A
        RET Z
        LD B,A
.item:
        PUSH BC
        PUSH HL
        CALL NEW_LINE
        POP HL
        POP BC
        RET C
        LD DE,PITEM
        ADD HL,DE
        DJNZ .item
        OR A
        RET

; Строка для записи HL, если её нужно дописать. CF=1 — буфер кончился.
NEW_LINE:
        EX DE,HL                                ; DE — запись
        LD HL,PLINE
        ADD HL,DE
        LD A,(HL)
        INC HL
        OR (HL)
        RET NZ                                  ; строка уже есть
        CALL IS_EDITED
        JR Z,.write
        LD A,(DE)
        AND 1
        RET Z                                   ; не отмечена — строка не нужна
.write:
        LD A,13
        CALL EMIT
        RET C
        LD A,(DE)
        RRCA
        JR C,.name
        LD A,";"                                ; правили флаги выключенного
        CALL EMIT
        RET C
.name:
        LD H,D
        LD L,E
        INC HL
        CALL EMIT_TEXT                          ; имя файла
        RET C
        CALL IS_EDITED
        RET NZ
        JP EMIT_FLAGS

; --- сообщения ----------------------------------------------------------------
; Сообщение показывается в том же окне: строки списка на время уступают место
; тексту по центру и подсказке под ним. После любой клавиши список на месте.
SHOW_MESSAGE:
        CALL SHOW_TEXT
        INC D
        LD HL,MSG_KEY
        CALL CENTER_ROW
        LD A,API_WAITUP
        CALL WLD
        LD A,API_WAITKEY
        CALL WLD
        LD A,API_WAITUP
        CALL WLD                                ; клавиша не дойдёт до списка
        JP PAINT

; Строки списка убрать, текст HL — по центру средней строки. Выход: D — она.
; Под текстом нужна ещё строка — подсказке или кнопкам. На экране плагинов строк
; бывает меньше двух (в каталоге WC нашёлся один .WMF или ни одного: каталог не
; читается), а при нуле строк счёт пошёл бы с 256 — за окно и за экран. Тогда
; текст — на экране настроек: там строк всегда PARAM_COUNT.
SHOW_TEXT:
        LD A,(SHOWN)
        CP 2
        JR NC,.room
        PUSH HL
        CALL SWITCH_SCREEN
        POP HL
.room:
        PUSH HL
        LD IX,WND
        LD A,API_CURSER
        CALL WLD                                ; полосу курсора убрать
        LD A,(SHOWN)
        LD B,A
        LD D,1
.clear:
        PUSH BC
        PUSH DE
        CALL BLANK_ROW
        POP DE
        PUSH DE
        CALL PAINT_ROW                          ; и цвет окна: след кнопок WC
        POP DE
        INC D
        POP BC
        DJNZ .clear
        LD A,(SHOWN)
        INC A
        SRL A
        LD D,A                                  ; середина окна
        POP HL
        PUSH DE
        CALL CENTER_ROW
        POP DE
        RET

; Перерисовать видимые строки: каждая собирается перед печатью, поэтому для
; длинных строк плагинов с флагами не нужен отдельный буфер на весь список.
PAINT:
        CALL DRAW_TITLE                         ; «*» и красный — текст правили
        LD A,(SHOWN)
        OR A
        RET Z
        LD B,A
        LD A,(TOP)
        LD (ROWNO),A
        LD D,1                                  ; первая строка окна
.row:
        PUSH BC
        PUSH DE
        LD A,(ROWNO)
        CALL BUILD_ROW
        POP DE
        PUSH DE
        CALL PAINT_ROW
        POP DE
        INC D
        LD HL,ROWNO
        INC (HL)
        POP BC
        DJNZ .row                               ; дальше — полоса прокрутки

; Полоса прокрутки на правой рамке окна, как в меню F10: дорожка и ползунок.
; Строка ползунка — TOP*(SHOWN-1)/(COUNT-SHOWN), считая с нуля: в начале
; списка он вверху, в конце — внизу. Список влез в окно — полосы нет.
BAR:
        LD HL,COUNT
        LD A,(SHOWN)
        LD B,A                                  ; строк в окне
        SUB (HL)
        RET NC
        NEG
        LD C,A                                  ; COUNT-SHOWN
        LD A,(TOP)
        LD E,A
        LD D,0
        LD H,D
        LD L,D
        PUSH BC
        DEC B
        JR Z,.divide
.multiply:
        ADD HL,DE
        DJNZ .multiply
.divide:
        LD E,C                                  ; DE — делитель, B — частное
.subtract:
        OR A
        SBC HL,DE
        JR C,.knob
        INC B
        JR .subtract
.knob:
        LD A,B
        POP BC
        LD C,A
        INC C                                   ; строка ползунка, с единицы
        LD D,1
.row:
        LD A,BAR_TRACK
        DEC C
        JR NZ,.put
        LD A,BAR_KNOB
.put:
        LD (BARCH),A
        PUSH BC
        PUSH DE
        LD HL,BARCH
        LD E,LINEW+1                            ; правая рамка окна
        LD BC,1
        CALL PRSRW_WND
        POP DE
        INC D
        POP BC
        DJNZ .row
        RET

; ROWBUF — в строку D окна.
; То же и цвет окна на строке. PRSRW пишет одни символы, а кнопки WC (API 8)
; красят свои клетки: после Esc в вопросе при выходе их след оставался в
; нижней строке списка, а после отказа записи — и под сообщением. Строку
; курсора не красим: её цвет ведут API 6/7 (CURSOR накрывает всю строку и
; помнит прежний цвет, CURSER его возвращает), а перекраска гасила бы полосу
; до следующего кадра — после пробела она мигала бы.
PAINT_ROW:
        LD A,(WND+12)
        CP D
        JR Z,PRINT_ROW
        CALL PRINT_ROW
        LD A,(WND+6)
        JP DRAW_TITLE.paint                     ; PRIAT сразу за PRSRW

PRINT_ROW:
        LD HL,ROWBUF
        LD E,1
        LD BC,LINEW
PRSRW_WND:                                      ; HL текст, BC длина, D/E — место
        LD IX,WND
        LD A,API_PRSRW
        JP WLD

; Текст HL (с нулём, чётной длины) по центру строки D окна: пробелов слева и
; справа поровну.
CENTER_ROW:
        PUSH DE
        PUSH HL
        CALL BLANK_ROW
        POP HL
        PUSH HL
        LD BC,0
.length:
        LD A,(HL)
        OR A
        JR Z,.place
        INC HL
        INC C
        JR .length
.place:
        LD A,LINEW
        SUB C
        SRL A
        LD E,A
        LD D,0
        LD HL,ROWBUF
        ADD HL,DE
        EX DE,HL
        POP HL
        LDIR
        POP DE
        JR PRINT_ROW

BLANK_ROW:
        LD HL,ROWBUF
        LD (HL)," "
        LD DE,ROWBUF+1
        LD BC,LINEW-1
        LDIR
        RET

; Собрать в ROWBUF строку номер A текущего экрана.
BUILD_ROW:
        PUSH AF
        CALL BLANK_ROW
        POP AF
        LD HL,SCREEN_NO
        BIT 0,(HL)
        JR NZ,PLUGIN_ROW

; Экран настроек: «название: значение».
        LD L,A
        LD H,0
        LD DE,VALUES
        ADD HL,DE
        LD C,(HL)                               ; значение
        PUSH BC
        CALL PARAM_AT                           ; IX — описание параметра
        LD L,(IX+4)
        LD H,(IX+5)
        LD DE,ROWBUF
        LD BC,LABELW
        LDIR                                    ; название
        LD A,":"
        LD (DE),A
        INC DE
        INC DE                                  ; пробел уже стоит
        POP BC
        LD A,C
        PUSH DE
        CALL VALUE_TEXT
        POP DE
        LD BC,VALW
        LDIR                                    ; подпись значения
        RET

; Экран плагинов: отметка, группа, название из заголовка и флаги из строки
; wc.ini — у выключенного плагина тоже, они вернутся вместе с отметкой.
PLUGIN_ROW:
        CALL PLUGIN_AT                          ; HL — запись списка
        PUSH HL
        LD BC,PGROUP
        ADD HL,BC
        LD A,(HL)
        LD C,A
        ADD A,A
        ADD A,A
        ADD A,C                                 ; метка — 5 символов
        LD C,A
        LD B,0
        LD HL,GROUP_LABELS
        ADD HL,BC
        LD DE,ROWBUF+4
        LD C,5
        LDIR
        POP HL
        LD BC,"]"*256+"["                       ; «[x]»
        LD E,"x"
        CP GROUP_SAVER*5
        JR NZ,.box
        LD BC,")"*256+"("                       ; заставка — одна из: «(*)»
        LD E,"*"
.box:
        LD A,C
        LD (ROWBUF),A
        LD A,B
        LD (ROWBUF+2),A
        LD A,E
        BIT 0,(HL)
        JR NZ,.mark
        LD A," "
.mark:
        LD (ROWBUF+1),A
        LD DE,ROWBUF+10                         ; название
        PUSH HL
        LD BC,PTITLE
        ADD HL,BC
        CALL SKIP_SPACES                        ; у двух заставок оно с пробела
        LD B,TITLEW-1
.title:
        LD A,(HL)
        OR A
        JR Z,.flags
        LD (DE),A
        INC HL
        INC DE
        DJNZ .title
.flags:
        POP HL
        CALL FLAGS_AT                           ; HL — флаги или Z
        RET Z
        LD DE,ROWBUF+FIELDX-1
        LD B,FIELDW
.copy_flags:
        LD A,(HL)
        CP ";"
        RET Z                                   ; дальше идёт подсказка
        CALL IS_EOL
        RET Z
        LD (DE),A
        INC HL
        INC DE
        DJNZ .copy_flags
        RET

; Флаги записи HL без ведущих пробелов. Выход: NZ и HL — текст; Z — строки
; плагина в тексте нет.
FLAGS_AT:
        LD BC,PFLAGS
        ADD HL,BC
        LD A,(HL)
        INC HL
        LD H,(HL)
        LD L,A
        OR H
        RET Z
        JP SKIP_SPACES                          ; выходит на непробеле: NZ

; --- правка флагов ----------------------------------------------------------
; Enter на экране плагинов правит флаги прямо в строке списка: на их месте
; встаёт поле строкового редактора WC (API 9) — курсор, вставка, Delete,
; русская раскладка. Enter переносит правку в текст wc.ini, Esc отменяет.
EDIT_FLAGS:
        LD A,(PCOUNT)
        OR A
        RET Z                                   ; список пуст: курсор не на записи
        CALL CURRENT
        CALL PLUGIN_AT
        LD (EDITREC),HL
        PUSH HL
        LD HL,EDITBUF                           ; поле — пробелы
        LD (HL)," "
        LD DE,EDITBUF+1
        LD BC,FLAGW-1
        LDIR
        POP HL
        LD DE,EDITBUF
        CALL FLAGS_AT
        LD C,0                                  ; длина текста в поле
        JR Z,.open
        LD B,FLAGW
.copy:
        LD A,(HL)
        CP ";"
        JR Z,.open                              ; дальше подсказка
        CALL IS_EOL
        JR Z,.open
        LD (DE),A
        INC HL
        INC DE
        INC C
        DJNZ .copy
; Поле полное: дальше до «;» или конца строки должны быть одни пробелы — их
; поле и так уберёт. Иначе флаги длиннее поля, и Enter без правки записал бы
; их обрезанными (аудит Codex R36-3): такие флаги здесь не правим.
.more:
        LD A,(HL)
        CP ";"
        JR Z,.open
        CALL IS_EOL
        JR Z,.open
        INC HL
        CP " "
        JR Z,.more
        LD HL,0
        LD (EDITREC),HL
        LD HL,MSG_FLAGS
        JP SHOW_MESSAGE
.open:
        LD A,C
        LD (EDITLEN),A
        LD IX,WND
        LD A,API_CURSER
        CALL WLD                                ; полоса курсора списка не мешает
        EXX
        LD HL,FLAGW                             ; HL' — размер буфера
        EXX
        LD A,(EDITLEN)
        CP FIELDW
        JR C,.cursor
        LD A,FIELDW-1                           ; длинные флаги: курсор в конце поля
.cursor:
        LD C,A
        LD B,FIELDW                             ; видимая ширина
        LD HL,EDITBUF
        LD IX,WND
        LD D,(IX+12)                            ; строка поля — строка курсора
        LD E,FIELDX
        LD A,#FD
        CALL ISTR                               ; редактор типа 2
.loop:
        EI
        HALT
        LD A,API_ESC
        CALL WLD
        JR NZ,.cancel
        LD A,API_ENTER
        CALL WLD
        JR NZ,.accept
        LD IX,WND
        XOR A
        CALL ISTR                               ; клавиши
        LD IX,WND
        LD A,2
        CALL ISTR                               ; показать поле
        JR .loop
.accept:
        CALL .finish
        LD HL,EDITBUF+FLAGW                     ; длина без хвостовых пробелов
        LD B,FLAGW
.trim:
        DEC HL
        LD A,(HL)
        CP " "
        JR NZ,.length
        DJNZ .trim
.length:
        LD A,B
        LD (EDITLEN),A
        JP APPLY
.cancel:
        CALL .finish
        LD HL,0
        LD (EDITREC),HL
        JP PAINT
.finish:
        LD IX,WND
        LD A,1
        CALL ISTR                               ; убрать курсор поля
        LD A,API_WAITUP
        JP WLD                                  ; Enter и Esc не дойдут до списка

; Строковый редактор WC: подкоманда в A.
ISTR:
        EX AF,AF'
        LD A,API_ISTR
        JP WLD

; HL — запись списка номер A.
PLUGIN_AT:
        LD HL,PLIST
        OR A
        RET Z
        LD B,A
        LD DE,PITEM
.step:
        ADD HL,DE
        DJNZ .step
        RET

; Курсор на B строк вверх или вниз; упёршись в край окна, сдвигаем список.
; Перерисовка — только если список сдвинулся.
PAGE_UP:
        LD A,(SHOWN)
        LD B,A
        JR UP_BY
GO_HOME:
        LD B,PMAX
UP_BY:
        LD HL,STEP_UP
        JR MOVE_BY
PAGE_DOWN:
        LD A,(SHOWN)
        LD B,A
        JR DOWN_BY
GO_END:
        LD B,PMAX
DOWN_BY:
        LD HL,STEP_DOWN
; Строку курсора (IX+12) можно менять только погасив полосу: API_CURSOR
; зажигает её в текущей строке и запоминает прежний цвет строки в IX+15,
; API_CURSER возвращает этот цвет. Без CURSER каждая пройденная строка так и
; оставалась подсвеченной. Новую полосу зажигаем сразу, а не в цикле после
; HALT: при автоповторе шаг идёт каждый кадр, и полоса, зажжённая только на
; миг между HALT и следующим шагом, на экране не держалась — курсор пропадал.
MOVE_BY:
        LD (.step+1),HL
        PUSH BC
        LD IX,WND
        LD A,API_CURSER
        CALL WLD                                ; полосу с прежней строки снять
        POP BC
        LD IX,WND                               ; шагам — описатель окна
        LD A,(TOP)
        PUSH AF
.again:
        PUSH BC
.step:
        CALL STEP_UP                            ; адрес шага подставляется
        POP BC
        DJNZ .again
        POP AF
        LD HL,TOP
        CP (HL)
        CALL NZ,PAINT                           ; список сдвинулся
        LD IX,WND
        LD A,API_CURSOR
        JP WLD                                  ; полоса — на новой строке

; Шаги курсора: IX — описатель окна (его ставит MOVE_BY).
STEP_UP:
        LD A,(IX+12)
        DEC A
        JR Z,.scroll
        LD (IX+12),A
        RET
.scroll:
        LD HL,TOP
        LD A,(HL)
        OR A
        RET Z
        DEC (HL)
        RET

STEP_DOWN:
        LD A,(IX+12)
        CP (IX+13)
        JR NC,.scroll
        INC A
        LD (IX+12),A
        RET
.scroll:
        LD A,(TOP)
        ADD A,(IX+13)
        LD HL,COUNT
        CP (HL)
        RET NC                                  ; ниже списка ничего нет
        LD HL,TOP
        INC (HL)
        RET

; --- список плагинов --------------------------------------------------------
; Каталог WC сканируется целиком, поэтому в списке видны и те .WMF, которых
; ещё нет в wc.ini. Отметка «использовать» — это строка в секции [PLUGINS].
SCAN_PLUGINS:
        LD HL,PLIST
        LD (PLPTR),HL
        XOR A
        LD (PCOUNT),A
        CALL ENTER_WC                           ; каталог WC в служебном потоке
        RET NZ
        LD A,1
        EX AF,AF'
        LD A,API_ADIR
        CALL WLD                                ; начать перебор сначала
.next:
        LD A,(PCOUNT)
        CP PMAX
        RET NC
        LD DE,ENTRYBUF
        LD A,%00000100                          ; размер и любой тип
        EX AF,AF'
        LD A,API_NXTETY2
        CALL WLD
        RET Z                                   ; каталог кончился
        LD A,(ENTRYBUF+4)
        AND #10
        JR NZ,.next                             ; каталоги не берём
        LD HL,ENTRYBUF+5                        ; имя записи
        LD A,(HL)
        OR A
        JR Z,.next                              ; запись без имени
        CALL IS_WMF
        JR C,.next
        CALL ADD_PLUGIN
        JR .next

; Имя по HL кончается на .WMF? Выход: CF=0 — да.
IS_WMF:
        PUSH HL
        LD B,0
.length:
        LD A,(HL)
        OR A
        JR Z,.end
        INC HL
        INC B
        JR .length
.end:
        LD A,B
        CP 5                                    ; минимум «x.WMF»
        JR C,.no
        DEC HL
        DEC HL
        DEC HL
        DEC HL                                  ; HL — на точку
        LD DE,EXT_WMF
        LD B,4
.compare:
        LD A,(DE)
        LD C,A
        LD A,(HL)
        CALL UPPER
        CP C
        JR NZ,.no
        INC HL
        INC DE
        DJNZ .compare
        POP HL
        OR A
        RET
.no:
        POP HL
        SCF
        RET

UPPER:
        CP "a"
        RET C
        CP "z"+1
        RET NC
        SUB "a"-"A"
        RET

EXT_WMF DB ".WMF"

; Добавить имя по HL в список и связать запись со строкой wc.ini.
ADD_PLUGIN:
        LD DE,(PLPTR)
        INC DE                                  ; за отметкой идёт имя
        LD B,NAMEW
.copy:
        LD A,(HL)
        OR A
        JR Z,.pad
        CALL UPPER
        LD (DE),A
        INC HL
        INC DE
        DJNZ .copy
        JR .stored
.pad:
        XOR A
        LD (DE),A
        INC DE
        DJNZ .pad
.stored:
        XOR A
        LD (DE),A
        LD HL,(PLPTR)
        CALL LINK_ITEM
        LD DE,PITEM
        ADD HL,DE
        LD (PLPTR),HL
        LD HL,PCOUNT
        INC (HL)
        RET

; Связать запись HL со строкой секции [PLUGINS]: отметка — есть ли включённая
; строка; PLINE и PFLAGS — строка и её флаги, у выключенной строки тоже.
; HL сохраняется.
LINK_ITEM:
        PUSH HL
        INC HL                                  ; имя записи
        CALL IN_PLUGINS                         ; A — отметка, DE — строка или 0
        POP HL
        LD (HL),A
        PUSH HL
        LD BC,PLINE
        ADD HL,BC
        LD (HL),E
        INC HL
        LD (HL),D
        INC HL                                  ; PFLAGS — сразу за PLINE
        LD A,D
        OR E
        JR Z,.store
        EX DE,HL
        LD A,(HL)
        CP ";"
        JR NZ,.named
        INC HL                                  ; у выключенной строки имя за «;»
.named:
        CALL SKIP_NAME
        EX DE,HL
.store:
        LD (HL),E
        INC HL
        LD (HL),D
        POP HL
        RET

; Заново связать все записи с текстом: после правки адреса строк сменились.
RELINK:
        LD HL,PLIST
        LD A,(PCOUNT)
        OR A
        RET Z
        LD B,A
.item:
        PUSH BC
        CALL LINK_ITEM
        LD DE,PITEM
        ADD HL,DE
        POP BC
        DJNZ .item
        RET

; Прочитать первый сектор каждого .WMF из списка: название (+165) и тип (+197).
; Отдельным проходом, потому что поиск файла сбивает перебор каталога.
READ_TITLES:
        LD HL,PLIST
        LD A,(PCOUNT)
        OR A
        RET Z
        LD B,A
.item:
        PUSH BC
        PUSH HL
        LD (TITLEPTR),HL
        LD DE,QUERYBUF+1                        ; запрос [тип,имя,0]
        INC HL
        LD BC,NAMEW+1
        LDIR
        XOR A
        LD (QUERYBUF),A
        LD HL,QUERYBUF
        LD A,API_FENTRY
        CALL WLD
        JR Z,.untitled
        LD A,API_GFILE
        CALL WLD
        LD HL,SECTOR
        LD B,1
        LD A,API_LOAD512
        CALL WLD
        JR C,.untitled
        LD HL,(TITLEPTR)
        LD DE,PTYPE
        ADD HL,DE
        LD A,(SECTOR+197)
        LD (HL),A                               ; тип плагина
        INC HL
        EX DE,HL
        LD HL,SECTOR+165
        LD BC,TITLEW-1
        LDIR                                    ; название
        XOR A
        LD (DE),A
        CALL SET_GROUP
        JR .next
.untitled:
        LD HL,(TITLEPTR)                        ; заголовок не прочитан — имя файла
        LD DE,PTYPE
        ADD HL,DE
        LD (HL),#FF
        INC HL
        EX DE,HL
        LD HL,(TITLEPTR)
        INC HL
        LD BC,NAMEW+1
        LDIR
        CALL SET_GROUP                          ; тип #FF — группа «file»
.next:
        POP HL
        LD DE,PITEM
        ADD HL,DE
        POP BC
        DJNZ .item
        RET

; Группа записи TITLEPTR: обязательные — по имени файла, остальные — по
; заголовку. Заставка (#02) и autoexec (#06) — по типу. Плагин со своими
; расширениями (+64) — «file», даже если WC заодно показывает его в F10:
; FT812 Viewer (#03) по сути просмотрщик. «F10» — только #03 и #11 без
; расширений; меню просмотрщиков, F2 и F4 — тоже работа с файлом.
SET_GROUP:
        LD HL,(TITLEPTR)
        INC HL                                  ; имя файла
        LD DE,CORE_NAMES
.core:
        LD A,(DE)
        OR A
        JR Z,.by_type                           ; список обязательных кончился
        PUSH HL
        PUSH DE
.compare:
        LD A,(DE)
        CP (HL)
        JR NZ,.other
        OR A
        JR Z,.is_core                           ; оба имени кончились
        INC HL
        INC DE
        JR .compare
.other:
        POP DE
        POP HL
.skip:
        LD A,(DE)                               ; к следующему имени в списке
        INC DE
        OR A
        JR NZ,.skip
        JR .core
.is_core:
        POP DE
        POP HL
        LD A,GROUP_CORE
        JR .store
.by_type:
        LD HL,(TITLEPTR)
        LD DE,PTYPE
        ADD HL,DE
        LD A,(HL)                               ; тип из заголовка
        LD B,GROUP_AUTO
        CP #06
        JR Z,.put
        LD B,GROUP_SAVER
        CP #02
        JR Z,.put
        LD B,GROUP_MENU
        CP #03
        JR Z,.menu
        CP #11
        JR Z,.menu
.file:
        LD B,GROUP_FILE
        JR .put
.menu:
        LD A,(SECTOR+64)                        ; первое своё расширение или 0;
        CP "!"                                  ; у прочитанного заголовка SECTOR
        JR NC,.file                             ; ещё цел — тип #03/#11 только там
.put:
        LD A,B
.store:
        LD HL,(TITLEPTR)
        LD DE,PGROUP
        ADD HL,DE
        LD (HL),A
        RET

; Без этих плагинов WC не работает, поэтому их отметку снять нельзя.
CORE_NAMES:
        DB "FILEX.WMF",0
        DB "PLM.WMF",0
        DB 0

GROUP_LABELS:                                   ; в порядке GROUP_*
        DB "core "
        DB "auto "
        DB "F10  "
        DB "saver"
        DB "file "

; Отсортировать список по названию: без учёта регистра и ведущих пробелов,
; у пары плагинов название в заголовке начинается с пробела. Плагинов не
; больше 32, поэтому хватает простой сортировки обменами.
SORT_PLUGINS:
        LD A,(PCOUNT)
        CP 2
        RET C
.pass:
        XOR A
        LD (SWAPPED),A
        LD HL,PLIST
        LD A,(PCOUNT)
        DEC A
        LD B,A                                  ; пар в проходе
.pair:
        PUSH BC
        PUSH HL
        LD DE,PITEM
        EX DE,HL
        ADD HL,DE
        EX DE,HL                                ; HL — запись, DE — следующая
        CALL TITLE_AFTER                        ; CF=1 — HL должна идти после DE
        JR NC,.keep
        CALL SWAP_ITEMS
        LD A,1
        LD (SWAPPED),A
.keep:
        POP HL
        LD DE,PITEM
        ADD HL,DE
        POP BC
        DJNZ .pair
        LD A,(SWAPPED)
        OR A
        JR NZ,.pass
        RET

; Сравнить названия записей HL и DE. Выход: CF=1 — HL идёт после DE.
TITLE_AFTER:
        PUSH HL
        PUSH DE
        LD BC,PGROUP                            ; сначала группа
        ADD HL,BC
        LD A,(HL)
        EX DE,HL
        ADD HL,BC
        CP (HL)
        EX DE,HL
        POP DE
        POP HL
        JR Z,.same_group
        CCF                                     ; группа HL больше — HL после DE
        RET
.same_group:
        PUSH HL
        PUSH DE
        LD BC,PTITLE
        ADD HL,BC
        EX DE,HL
        ADD HL,BC
        EX DE,HL                                ; HL, DE — названия
        CALL SKIP_SPACES
        EX DE,HL
        CALL SKIP_SPACES
        EX DE,HL
.compare:
        LD A,(DE)
        CALL UPPER
        LD C,A
        LD A,(HL)
        CALL UPPER
        CP C
        JR NZ,.differ                           ; CF уже задан сравнением
        OR A
        JR Z,.equal                             ; оба кончились
        INC HL
        INC DE
        JR .compare
.differ:
        CCF                                     ; A>C — HL после DE: CF=1
        JR NZ,.done
.equal:
        OR A
.done:
        POP DE
        POP HL
        RET

SKIP_SPACES:
        LD A,(HL)
        CP " "
        RET NZ
        INC HL
        JR SKIP_SPACES

; Обменять записи HL и DE целиком.
SWAP_ITEMS:
        PUSH HL
        PUSH DE
        PUSH DE
        LD DE,SWAPBUF
        LD BC,PITEM
        PUSH HL
        LDIR                                    ; HL -> SWAPBUF
        POP DE
        POP HL
        PUSH HL
        LD BC,PITEM
        LDIR                                    ; DE -> HL
        POP DE
        LD HL,SWAPBUF
        LD BC,PITEM
        LDIR                                    ; SWAPBUF -> DE
        POP DE
        POP HL
        RET

; Пропустить имя файла в строке wc.ini: HL — начало имени, выход HL — первый
; байт за ним (пробел, «;» или конец строки).
SKIP_NAME:
        LD A,(HL)
        CALL WORD_END
        RET Z
        INC HL
        JR SKIP_NAME

; Z — символ A заканчивает имя файла в строке wc.ini.
WORD_END:
        CP " "
        RET Z
        CP ";"
        RET Z
; Z — символ A заканчивает строку.
IS_EOL:
        OR A
        RET Z
        CP 13
        RET Z
        CP 10
        RET

; Строка плагина с именем HL в секции [PLUGINS]. Имя считается только в
; начале строки, «;» прямо перед ним — строка выключена. Включённая строка
; важнее выключенной. Выход: A=1 и DE — включённая строка; A=0 и DE —
; выключенная; A=0 и DE=0 — строки нет. HL сохраняется.
IN_PLUGINS:
        LD DE,0
        LD (SPARE),DE                           ; выключенной строки пока нет
        LD DE,(PLUGSEC)
        LD A,D
        OR E
        JR Z,.done
.line:
        LD A,(DE)
        OR A
        JR Z,.done
        CP "["
        JR Z,.done                              ; началась следующая секция
        CALL IS_EOL
        JR Z,.step
        PUSH DE                                 ; начало строки
        CP ";"
        JR NZ,.compare
        INC DE                                  ; у выключенной строки имя за «;»
.compare:
        PUSH HL
        CALL SAME_NAME
        POP HL
        POP BC                                  ; BC — начало строки
        JR NZ,.skip
        LD A,(BC)
        CP ";"
        JR NZ,.active
        LD A,(SPARE+1)
        OR A
        JR NZ,.skip                             ; берём первую выключенную
        LD (SPARE),BC
        JR .skip
.active:
        LD D,B
        LD E,C
        LD A,1
        RET
.skip:
        LD A,(DE)                               ; до конца строки
        CALL IS_EOL
        JR Z,.eol
        INC DE
        JR .skip
.eol:
        OR A
        JR Z,.done
.step:
        INC DE
        JR .line
.done:
        LD DE,(SPARE)
        XOR A
        RET

; Z — имя HL (заглавными, с нулём) стоит в тексте DE целым словом.
SAME_NAME:
        LD A,(HL)
        OR A
        JR Z,.end
        LD C,A
        LD A,(DE)
        CALL UPPER
        CP C
        RET NZ
        INC HL
        INC DE
        JR SAME_NAME
.end:
        LD A,(DE)
        JR WORD_END

; Найти начало секции [PLUGINS] в тексте и запомнить его.
FIND_PLUGINS:
        LD HL,PLUGKEY
        LD DE,INIBUF
        CALL FIND_KEY                           ; DE — сразу за «[PLUGINS]»
        JR NC,.found
        LD DE,0
.found:
        LD (PLUGSEC),DE
        RET

PLUGHEAD DB 13                                  ; перевод строки перед заголовком
PLUGKEY DB "[PLUGINS]",0

; --- параметры -------------------------------------------------------------
; Значения в wc.ini однозначные, поэтому плагин правит цифру прямо в тексте
; файла: комментарии, порядок строк и остальные секции остаются нетронутыми.
; Ключ ищется в своей секции: DRV= и соседи есть и у левой, и у правой панели.
PARAMS:
        DW SEC_SETUP, KEY_FREQ, LBL_FREQ, VAL_FREQ
        DB 3
        DW SEC_SETUP, KEY_PATHS, LBL_PATHS, VAL_NOYES
        DB 2
        DW SEC_SETUP, KEY_CURSOR, LBL_CURSOR, VAL_NOYES
        DB 2
        DW SEC_SETUP, KEY_MODE, LBL_MODE, VAL_MODE
        DB 3
        DW SEC_SETUP, KEY_SAVER, LBL_SAVER, VAL_SAVER
        DB 10
        DW SEC_SETUP, KEY_LOGO, LBL_LOGO, VAL_ONOFF
        DB 2
        DW SEC_LEFT, KEY_DRV, LBL_LDRV, VAL_DRV
        DB 7
        DW SEC_LEFT, KEY_INFO, LBL_LINFO, VAL_ONOFF
        DB 2
        DW SEC_LEFT, KEY_SORT, LBL_LSORT, VAL_SORT
        DB 5
        DW SEC_RIGHT, KEY_DRV, LBL_RDRV, VAL_DRV
        DB 7
        DW SEC_RIGHT, KEY_INFO, LBL_RINFO, VAL_ONOFF
        DB 2
        DW SEC_RIGHT, KEY_SORT, LBL_RSORT, VAL_SORT
        DB 5
PARAM_SIZE  EQU 9
PARAM_COUNT EQU 12
        ASSERT PARAM_COUNT >= 2, сообщению SHOW_TEXT на экране настроек нужны две строки
VALW        EQU 10                              ; ширина подписи значения
LABELW      EQU 15                              ; ширина названия параметра
        ASSERT PARAM_COUNT*PARAM_SIZE == $-PARAMS

SEC_SETUP   DB "[SETUP]",0
SEC_LEFT    DB "[LPANEL]",0
SEC_RIGHT   DB "[RPANEL]",0

KEY_FREQ    DB "CPU_FREQ=",0
KEY_PATHS   DB "SavePaths=",0
KEY_CURSOR  DB "SavePosition=",0
KEY_MODE    DB "TextMode=",0
KEY_SAVER   DB "ScreenSaver=",0
KEY_LOGO    DB "Logo=",0
KEY_DRV     DB "DRV=",0
KEY_INFO    DB "INFO=",0
KEY_SORT    DB "CSORT=",0

LBL_FREQ    DB "CPU speed      "
LBL_PATHS   DB "Remember dirs  "
LBL_CURSOR  DB "Save cursor    "
LBL_MODE    DB "Text mode      "
LBL_SAVER   DB "Screen saver   "
LBL_LOGO    DB "Title logo     "
LBL_LDRV    DB "Left drive     "
LBL_LINFO   DB "Left file info "
LBL_LSORT   DB "Left sorting   "
LBL_RDRV    DB "Right drive    "
LBL_RINFO   DB "Right file info"
LBL_RSORT   DB "Right sorting  "

VAL_FREQ    DB "3.5 MHz   ","7 MHz     ","14 MHz    "
VAL_NOYES   DB "no        ","yes       "
VAL_MODE    DB "80x25     ","80x30     ","90x36     "
VAL_SAVER   DB "disabled  ","1 minute  ","2 minutes ","3 minutes ","4 minutes "
            DB "5 minutes ","6 minutes ","7 minutes ","8 minutes ","9 minutes "
VAL_ONOFF   DB "disabled  ","enabled   "
VAL_DRV     DB "IDEnemoMas","SD (ZC)   ","SD (NGS)  ","IDEsmucMas","IDEsmucSla"
            DB "IDEnemoSla","SD2 (ZC)  "
VAL_SORT    DB "off       ","by name   ","by ext    ","by size   ","by date   "

; Разобрать [SETUP]: значение каждого параметра и адрес его цифры в тексте.
PARSE_SETUP:
        LD IX,PARAMS
        LD HL,VALUES
        LD (CURPTR),HL
        LD HL,PLACES
        LD (PLCPTR),HL
        LD B,PARAM_COUNT
.next:
        PUSH BC
        CALL FIND_PARAM                         ; DE — цифра значения
        JR NC,.have
        LD DE,0                                 ; ключа в файле нет
.have:
        LD HL,(PLCPTR)
        LD (HL),E
        INC HL
        LD (HL),D
        INC HL
        LD (PLCPTR),HL
        LD A,D
        OR E
        JR Z,.zero
        LD A,(DE)
        SUB "0"
        CP (IX+8)                               ; значение вне набора — первое
        JR C,.store
.zero:
        XOR A
.store:
        LD HL,(CURPTR)
        LD (HL),A
        INC HL
        LD (CURPTR),HL
        LD BC,PARAM_SIZE
        ADD IX,BC
        POP BC
        DJNZ .next
        RET

; Найти параметр IX: сначала заголовок его секции, затем «Ключ=» до следующей
; секции. Выход: CF=0 и DE — цифра значения; CF=1 — параметра нет.
FIND_PARAM:
        LD L,(IX+0)
        LD H,(IX+1)
        LD DE,INIBUF
        CALL FIND_KEY                           ; DE — за заголовком секции
        RET C
        LD L,(IX+2)
        LD H,(IX+3)

; Найти текст HL в wc.ini, начиная с DE. Выход: CF=0 и DE — сразу за ним;
; CF=1 — нет. Ключ параметра ищется только в своей секции: «[» в начале
; строки открывает следующую, и дальше него поиск не идёт. Совпадение — только
; с начала строки, как читает wc.ini сам WC: «;CPU_FREQ=0» и слова в
; комментарии за «;» ключом не считаются.
FIND_KEY:
        LD B,13                                 ; начало поиска — как начало строки
.scan:
        LD A,(DE)
        OR A
        SCF
        RET Z                                   ; текст кончился
        LD A,B
        CALL IS_EOL
        JR NZ,.next                             ; не начало строки
        LD A,(DE)
        CP "["
        JR NZ,.try
        LD A,(HL)
        CP "["
        SCF
        RET NZ                                  ; секция кончилась
.try:
        PUSH HL
        PUSH DE
.compare:
        LD A,(HL)
        OR A
        JR Z,.found
        LD C,A
        LD A,(DE)
        CP C
        JR NZ,.mismatch
        INC HL
        INC DE
        JR .compare
.mismatch:
        POP DE
        POP HL
.next:
        LD A,(DE)
        LD B,A                                  ; прежний символ
        INC DE
        JR .scan
.found:
        POP AF                                  ; начало совпадения больше не нужно
        POP HL
        OR A                                    ; CF=0, DE стоит за найденным
        RET

; Подпись значения A для параметра IX. Выход: HL — её текст.
VALUE_TEXT:
        LD L,(IX+6)
        LD H,(IX+7)
        OR A
        RET Z
        LD B,A
        LD DE,VALW
.step:
        ADD HL,DE
        DJNZ .step
        RET

; --- окна и тексты ----------------------------------------------------------
WND     DB 5+16+128+64,0
        DB 255,255
        DB LINEW+2,2
        DB %01011111
        DB 0
        DW #0000
        DB 0,0
        DB 1,0
        DB %11100001
        DB 0
        DW TITLE_SETUP
        DW FOOT_SETUP
        DW 0

TITLE_SETUP DB #0E,#09,"WC SETUP",0
TITLE_PLUGS DB #0E,#09,"WC PLUGINS",0
FOOT_SETUP  DB #0B,1,#09,"Space - change  Tab - plugins  F2 - save  Esc - exit",0
FOOT_PLUGS  DB #0B,1,#09,"Space - use  Enter - flags  Tab - settings  F2 - save  Esc",0

; Сообщения печатаются по центру строки шириной LINEW (чётной), поэтому их
; длина тоже чётная: иначе отступы слева и справа не сравнять.
MSG_SAVED   DB "wc.ini saved",0
        ASSERT (($-MSG_SAVED-1) & 1) == 0
MSG_FAILED  DB "wc.ini was NOT saved",0
        ASSERT (($-MSG_FAILED-1) & 1) == 0
; Claude - 2026-09-26 - begin
; Хвост прошлой попытки того же размера, что wc.ini (SAME_SIZE_AS_INI): не
; удаляем — может делить цепочку с wc.ini; нужна проверка тома (CHKDSK).
MSG_CHECK   DB "wc.ini: check the disk",0
        ASSERT (($-MSG_CHECK-1) & 1) == 0
; Claude - 2026-09-26 - end
MSG_FULL    DB "wc.ini would be too long",0
        ASSERT (($-MSG_FULL-1) & 1) == 0
MSG_NEW     DB "No wc.ini yet: F2 creates it",0
        ASSERT (($-MSG_NEW-1) & 1) == 0
MSG_LONG    DB "wc.ini is too long to edit",0
        ASSERT (($-MSG_LONG-1) & 1) == 0
MSG_FLAGS   DB "Flags are longer than 64 chars",0
        ASSERT (($-MSG_FLAGS-1) & 1) == 0
        ASSERT FLAGW == 64, MSG_FLAGS называет ширину поля
MSG_UNREAD  DB "wc.ini could not be read",0
        ASSERT (($-MSG_UNREAD-1) & 1) == 0
MSG_KEY     DB "Press any key...",0
        ASSERT (($-MSG_KEY-1) & 1) == 0
MSG_ASK     DB "Save changed settings?",0
        ASSERT (($-MSG_ASK-1) & 1) == 0
        ASSERT (LINEW & 1) == 0

; Конец кода: дальше в файле ничего нет, буферы и переменные живут в RAM.
CODE_END:
        ENT
        ALIGN 512,0
FILE_END:

; --- переменные в RAM, в файл не попадают -----------------------------------
        ASSERT CODE_END <= INIBUF, код плагина дорос до своих данных
        ASSERT PLIST + PMAX*PITEM <= VALUES
        ASSERT EDITBUF + FLAGW <= #B000, буферы налезли на область WC и CORE32
        ASSERT VALUES + PARAM_COUNT <= PLACES
        ASSERT PLACES + 2*PARAM_COUNT <= ROWBUF
        ASSERT ROWBUF + LINEW <= VARS
        ASSERT SWAPBUF + PITEM <= EDITBUF
        ASSERT EDITBUF + FLAGW <= #B000
        ASSERT PFLAGS == PLINE+2
        ASSERT FIELDX + FIELDW == LINEW + 1
INI_SIZE EQU VARS+0                             ; конец текста wc.ini
TOP      EQU VARS+2                             ; первая показанная строка
SHOWN    EQU VARS+3                             ; сколько строк в окне
COUNT    EQU VARS+4                             ; сколько строк в списке
CURPTR   EQU VARS+5                             ; курсор разбора значений
PLCPTR   EQU VARS+7                             ; курсор разбора адресов
CURRENT_NO EQU VARS+11                          ; параметр под курсором
DIGIT    EQU VARS+12                            ; цифра нового значения
PLPTR    EQU VARS+13                            ; курсор заполнения списка
PCOUNT   EQU VARS+15                            ; сколько .WMF найдено
PLUGSEC  EQU VARS+16                            ; начало секции [PLUGINS]
SCREEN_NO EQU VARS+18                           ; 0 — настройки, 1 — плагины
ROWNO    EQU VARS+20                            ; строка, которую печатаем
NEWPTR   EQU VARS+21                            ; курсор нового текста
LINEHEAD EQU VARS+23                            ; начало текущей строки секции
FILE_LEN EQU VARS+25                            ; размер wc.ini из FENTRY
INI_STATE EQU VARS+27                           ; 0 прочитан, 1 нет, 2 слишком длинный,
                                                ; 3 не прочитался (ошибка чтения)
INSPOS   EQU VARS+112                           ; место вставки строки ключа
INSLEN   EQU VARS+114                           ; её длина
TITLEPTR EQU VARS+28                            ; запись, чей заголовок читаем
QUERYBUF EQU VARS+32                            ; запрос FENTRY: [тип,имя 8.3,0]
SWAPPED  EQU VARS+48                            ; в проходе сортировки был обмен
EDITREC  EQU VARS+50                            ; запись, чьи флаги правили, или 0
EDITLEN  EQU VARS+52                            ; длина правленых флагов
SPARE    EQU VARS+54                            ; выключенная строка при поиске
BARCH    EQU VARS+56                            ; символ полосы прокрутки для PRSRW
MODIFIED EQU VARS+57                            ; ≠0 — текст правили, на носителе он другой
QUIET    EQU VARS+58                            ; ≠0 — SAVE_INI по вопросу при выходе
SWAPBUF  EQU VARS+64                            ; запись при обмене, PITEM байт
EDITBUF  EQU VARS+128                           ; поле правки флагов, FLAGW байт

        SAVEBIN "Build/SETUP.WMF",START_CODE,FILE_END-START_CODE
