; PLM.WMF — менеджер загрузки плагинов Wild Commander.
;
; Плагины перестают занимать пул постоянно. При установке менеджер помечает все
; нерезидентные плагины выгруженными, возвращает ватерлинию пула к резидентам и
; запоминает в каждом заголовке первый кластер его .WMF. Код плагина читается
; при первом запуске и остаётся в пуле, пока есть место.
;
; Ни одного байта в boot.$C не меняется: в образе нет свободного места (сплошной
; скан payload дал 94 нулевых байта, и те — переменные), поэтому перехваты
; ставятся в RAM установщиком, как это делает FILEX.
;
; Перехват 1 — общий пролог запуска L6011_241 (#70B2, 15 байт). Через него идут
; все запуски: по расширению, F10, меню просмотрщиков, F2/F4, заставка по
; таймеру и автозапуск #06.
; Перехват 2 — цикл загрузки блоков WALK (#97A4, 21 байт): ручная загрузка
; .WMF по Enter тоже перестаёт занимать пул.
;
; Первый кластер взять при регистрации нельзя: тип #06 выполняется уже после
; того, как все плагины загружены (тип #01 из [PLUGINS] WC намеренно не
; запускает — ALPL сравнивает тип с C=1 и выходит). Поэтому установщик один раз
; читает wc.ini, для каждой строки [PLUGINS] находит файл через SRHDRN и
; сверяет его 32-байтовое имя с заголовком в таблице.
;
; Три правила, проверенные на стенде и определившие конструкцию:
;   * буфер #B000..#BFFF принадлежит WC и CORE32: файловый вызов затирает там
;     всё, поэтому ни кода, ни данных менеджера в этом диапазоне быть не может;
;   * окно #C000 CORE32 тоже использует под свой буфер, поэтому файловые вызовы
;     делаются, когда там стоит свободная страница пула, а не таблица заголовков;
;   * прежнюю страницу окна #C000 возвращать не нужно: сразу за прологом WC сам
;     подключает туда страницу #00 (L6011_244).
;
; Поэтому менеджер работает из собственной страницы, подключённой к окну #8000:
; там же его буферы, а окно #C000 остаётся свободным. На время работы прерывания
; запрещены: страница #02 с кодом WC в это время не подключена.

        DEVICE ZXSPECTRUM128

; --- резидентные точки WC ---------------------------------------------------
GATEWAY         EQU #70B2       ; L6011_241 — общий пролог запуска плагина
GATEWAY_LENGTH  EQU 15
GATEWAY_PAGE_OP EQU GATEWAY+5   ; операнд LD A,#page внутри шлюза (3E по +4)
WALK            EQU #97A4       ; цикл загрузки блоков при регистрации
WALK_LENGTH     EQU 21
WALK_PAGE_OP    EQU WALK+1
LGW             EQU #97B9       ; выход цикла: фиксация ватерлинии
MENUBUILD       EQU #9908       ; MNU — построение окна меню F10 и его цикл клавиш
MENUBUILD_LENGTH EQU 8
MENUBUILD_PAGE_OP EQU MENUBUILD+1
MENUEXIT        EQU #99A0       ; F1e — убрать окно меню и вернуться в панели
MENUQUIT        EQU #99A3       ; F1E — вернуться, когда окна ещё не было
MENUEXEC        EQU #99A6       ; PSEXE — запустить плагин выбранной строки
MENUWND         EQU #8036       ; F11WND — описатель окна меню в странице WC
MENUWND_LENGTH  EQU 22          ; за описателем сразу идут его тексты
MENUTEXT        EQU #804C       ; F11TXT — заголовок окна
MENUTEXT_LENGTH EQU 16
MENUPICK        EQU #99AB       ; пересчёт строки меню в адрес записи при запуске
MENUTAB         EQU #BE00       ; таблица строк меню в буфере WC: строка -> старший байт записи
MENUPICK_LENGTH EQU 20
; Резидентные подпрограммы окна #4000: они доступны при любой странице в #8000
; и #C000, поэтому цикл меню может работать прямо из страницы менеджера.
PRWOW           EQU #792C       ; нарисовать окно по описателю IX
PRSRW           EQU #7D25       ; строка в окно: HL текст, BC длина, D/E координаты
RRESB           EQU #7ACE       ; восстановить фон под окном
CURSOR          EQU #7CD5       ; фаза мигания курсора строки (IX+12)
CURSER          EQU #7CF2       ; погасить курсор
CrUP            EQU #628E       ; курсор на строку вверх внутри окна
CrDN            EQU #6285       ; курсор на строку вниз
UPPP            EQU #7453       ; опрос клавиш: вверх, вниз, влево, вправо,
DWWW            EQU #7459       ; Enter, Delete и Esc. Все возвращают NZ,
LFFF            EQU #745F       ; если клавиша нажата.
RGGG            EQU #7465
PGU             EQU #746B       ; страница вверх и вниз
PGD             EQU #7471
HOME_KEY        EQU #7486       ; начало и конец списка
END_KEY         EQU #748B
ENKE            EQU #7477
DELE            EQU #7490
ESCK            EQU #749A
HEI             EQU #600E       ; высота текстового экрана: 25, 30 или 36
MNG8            EQU #68B1       ; L6011_110: A -> окно #8000
MNGC            EQU #68C1       ; L6011_114: A -> окно #C000
MNGC_PL         EQU #68F9       ; относительная страница плагина -> окно #C000
GIPAG           EQU #4012       ; поставить поток на кластер по (HL)
LOAD512         EQU #4015       ; прочитать B секторов в (HL)
SRHDRN          EQU #404E       ; найти запись каталога: HL -> [тип,имя,0]
OWN_PAGE        EQU #6002       ; тень страницы окна #8000
LOBU            EQU #B000       ; копия заголовка запускаемого плагина
PPGP            EQU #7F15       ; база текущего плагина
PPGM            EQU #7F16       ; ватерлиния пула
PPG2            EQU #7F17       ; ватерлиния, которую зафиксирует LGW
PHED            EQU #7F18       ; конец таблицы заголовков в окне #C000
BRRR            EQU #7F28       ; первый кластер файла, найденного SRHDRN
PLHPG           EQU #60         ; страница заголовков
PLGPG           EQU #61         ; первая страница пула
PLEPG           EQU #A0         ; первая страница за пулом
        IFDEF PLM_POOL_LIMIT
POOL_LIMIT      EQU PLM_POOL_LIMIT              ; уменьшенный предел для проверки вытеснения
        ELSE
POOL_LIMIT      EQU PLEPG-PLGPG
        ENDIF
HEADERS         EQU #C000       ; окно #C000

REC_BASE        EQU 0           ; база плагина, #FF — не загружен
REC_CLUSTER     EQU 1           ; первый кластер .WMF, 4 байта
REC_STAMP       EQU 5           ; отметка последнего запуска, 2 байта
REC_PAGES       EQU 34
REC_ENTRY       EQU 35
REC_BLOCKS      EQU 36
REC_NAME        EQU 165
REC_TYPE        EQU 197

; --- раскладка страницы менеджера -------------------------------------------
; Страница видна в двух окнах: #C000 (шлюзы) и #8000 (вся работа).
RUNTIME         EQU #C000
ENTRY           EQU RUNTIME+#300
VIEW            EQU #8000       ; та же страница в окне #8000
WORK            EQU VIEW+#1000  ; рабочая часть
COPY            EQU VIEW+#1A00  ; копия заголовка запускаемого плагина
SECTOR          EQU VIEW+#1C00  ; сектор заголовка .WMF при сверке
VARS            EQU VIEW+#1E00
NAMES           EQU VIEW+#2000  ; имена из [PLUGINS], 0 в конце списка
LIST            EQU VIEW+#2400  ; имена для меню F10, по 32 байта
INDEX           EQU VIEW+#2600  ; строка меню -> старший байт адреса записи
WNDCOPY         EQU VIEW+#2800  ; копия описателя окна меню, 22 байта
WNDTEXT         EQU VIEW+#2820  ; копия его заголовка и подвала, 64 байта
COUNT           EQU VARS+50     ; длина списка меню в байтах
PICKED          EQU VARS+52     ; адрес выбранной записи
MTOP            EQU VARS+56     ; первая показанная строка списка, считая с нуля
MCOUNT          EQU VARS+57     ; сколько всего строк в списке
MROWS           EQU VARS+58     ; сколько строк помещается в окно
BARCH           EQU VARS+59     ; символ полосы прокрутки для PRSRW
MCUR            EQU VARS+60     ; строка курсора в окне, помнится между вызовами

; Сколько строк показывать в окне меню. По умолчанию — сколько влезает в
; текстовый экран (25, 30 или 36 строк), с запасом на рамку и строку клавиш.
; PLM_MENU_ROWS уменьшает окно на стенде, чтобы проверить саму прокрутку.
        IFDEF PLM_MENU_ROWS
MENU_LIMIT      EQU PLM_MENU_ROWS
        ENDIF
BAR_TRACK       EQU #B0         ; дорожка полосы прокрутки
BAR_KNOB        EQU #DB         ; ползунок
BAR_COLUMN      EQU 33          ; правая граница окна меню

MODE            EQU VARS+0
INIPAGE         EQU VARS+1
CLUSTER         EQU VARS+2
OWN             EQU VARS+6      ; физическая страница менеджера
QUERY           EQU VARS+8      ; запрос [тип,имя,0] для SRHDRN
USAGE           EQU VARS+32     ; счётчик запусков: из него берутся отметки
RESTOP          EQU VARS+34     ; вершина резидентной части пула
NEXTBASE        EQU VARS+35     ; курсор уплотнения
NEEDED          EQU VARS+36     ; сколько страниц нужно загружаемому плагину
BEST            EQU VARS+37     ; кандидат на вытеснение
BESTSTAMP       EQU VARS+39     ; его отметка
RECORD          EQU VARS+41     ; запись загружаемого плагина: вытеснение портит HL
TRACE           EQU VARS+43     ; отладка: как закончился подбор места
EVICTED         EQU VARS+44     ; отладка: сколько раз вытесняли
MOVES           EQU VARS+45     ; отладка: сколько страниц перенесло уплотнение
ROUNDS          EQU VARS+46     ; отладка: сколько записей просмотрело уплотнение
EVBASE          EQU VARS+47     ; отладка: база вытесненного плагина
CFIRST          EQU VARS+48     ; отладка: первая база, найденная уплотнением

; Порты DMA TS-Conf: уплотнение переносит страницы ими, как это делает WC.
STS             EQU #27AF
DMASL           EQU #1AAF
DMASH           EQU #1BAF
DMASX           EQU #1CAF
DMADL           EQU #1DAF
DMADH           EQU #1EAF
DMADX           EQU #1FAF
DMA_T           EQU #28AF
DMA_N           EQU #26AF
DMA_C           EQU #27AF

        ORG #0000
START_CODE:
        DS 16,0
        DB "WildCommanderMDL"
        DB #0A                                  ; версия формата
        DB #00
        DB #01                                  ; одна страница
        DB #00                                  ; страница входа
        DB #00,(WORK_FILE_END-MAIN_FILE_START+511)/512
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DS 16,0
        DS 32*3,0
        DB #00
        DD #FFFFFFFF
PLM_NAME:
        DB "Plugin Loader Manager v0.4"
        DS 32-($-PLM_NAME)," "
        DB #06                                  ; тип: один раз при старте
        DB #00

        ALIGN 512,0
MAIN_FILE_START:
        DISP RUNTIME

; --- установщик -------------------------------------------------------------
; Выполняется по #8000: страница плагина уже в этом окне, поэтому и адреса тут
; «рабочие». Патчится только заведомо известный код.
PLM_INSTALL:
; Первая фаза идёт по #8000, где сейчас стоит сама страница плагина: отсюда
; видно только окно #4000 с кодом WC, поэтому здесь правится один шлюз запуска.
; Ни внутренних CALL по адресам #C0xx, ни ссылок на свои данные в этой фазе нет.
        DI
        LD A,(OWN_PAGE)
        LD (OWN),A                              ; своя физическая страница
        LD HL,VIEW+(ORIGINAL_GATEWAY-RUNTIME)
        LD DE,GATEWAY
        LD B,GATEWAY_LENGTH
        CALL VIEW+(COMPARE_VIEW-RUNTIME)
        JR Z,.patch_gateway
        EI
        XOR A
        RET                                     ; пролог не тот — не трогаем ничего
.patch_gateway:
        LD HL,VIEW+(GATEWAY_CODE-RUNTIME)
        LD DE,GATEWAY
        LD BC,GATEWAY_END-GATEWAY_CODE
        LDIR
        LD A,(OWN)
        LD (GATEWAY_PAGE_OP),A

; Вторая фаза: остальные перехваты лежат в окне #8000 (WALK по #97A4, меню по
; #991B и #99AB), поэтому туда надо вернуть верхнюю половину WC, а самим уйти
; в окно #C000.
        LD A,(OWN)
        CALL MNGC
        JP INSTALL_IN_C000

INSTALL_IN_C000:
        LD A,#02
        CALL MNG8                               ; верхняя половина WC в #8000

        LD HL,ORIGINAL_WALK
        LD DE,WALK
        LD B,WALK_LENGTH
        CALL COMPARE_VIEW
        JR NZ,.menu                             ; цикл не тот — оставляем прежним
        LD HL,WALK_CODE
        LD DE,WALK
        LD BC,WALK_END-WALK_CODE
        LDIR
        LD A,(OWN-VIEW+RUNTIME)
        LD (WALK_PAGE_OP),A
.menu:
        LD HL,ORIGINAL_MENUBUILD
        LD DE,MENUBUILD
        LD B,MENUBUILD_LENGTH
        CALL COMPARE_VIEW
        JR NZ,.done
        LD HL,ORIGINAL_MENUPICK
        LD DE,MENUPICK
        LD B,MENUPICK_LENGTH
        CALL COMPARE_VIEW
        JR NZ,.done                             ; меню правим только парой
        LD HL,MENUBUILD_CODE
        LD DE,MENUBUILD
        LD BC,MENUBUILD_LENGTH
        LDIR
        LD A,(OWN-VIEW+RUNTIME)
        LD (MENUBUILD_PAGE_OP),A
        CALL COPY_WINDOW                        ; описатель окна меню к себе
        LD HL,MENUPICK_CODE
        LD DE,MENUPICK
        LD BC,MENUPICK_LENGTH
        LDIR
.done:
; Рабочая часть и её продолжение живут в своей странице: возвращаем её в окно
; #8000 и уходим туда. Возврат в WC пойдёт обычным RET — вызывающий в #05.
        LD A,(OWN-VIEW+RUNTIME)
        CALL MNG8
        JP VIEW+(INSTALL_TAIL-RUNTIME)

INSTALL_TAIL:                                   ; выполняется по #8xxx
        LD A,#02
        LD (MODE),A
        CALL WORK                               ; освободить пул и запомнить файлы
        EI
        XOR A
        RET

; Эталоны: менеджер ставит перехват только поверх известного кода.
ORIGINAL_GATEWAY:
        DB #3A,#00,#B0                          ; LD A,(#B000)
        DB #32,#15,#7F                          ; LD (#7F15),A
        DB #21,#23,#B0                          ; LD HL,#B023
        DB #86                                  ; ADD A,(HL)
        DB #C6,#61                              ; ADD A,#61
        DB #C3,#B1,#68                          ; JP #68B1
ORIGINAL_WALK:
        DB #7E,#23,#CD,#F9,#68                  ; LD A,(HL):INC HL:CALL MNGC_PL
        DB #7E,#23,#B7,#28,#0B                  ; LD A,(HL):INC HL:OR A:JR Z,LGW
        DB #E5                                  ; PUSH HL
        DB #47,#21,#00,#C0,#CD,#15,#40          ; LD B,A:LD HL,#C000:CALL LOAD512
        DB #E1                                  ; POP HL
        DB #18,#EB                              ; JR WALK

; Меню плагинов WC рисует список целиком: высота окна равна числу строк плюс
; рамка, прокрутки нет вовсе. Поэтому перехватывается весь MNU — построение
; окна и цикл клавиш делает менеджер, а запуск и удаление остаются за WC.
ORIGINAL_MENUBUILD:
        DB #3A,#19,#7F                          ; LD A,(PHED+1)
        DB #FE,#C2                              ; CP #C2
        DB #DA,#A3,#99                          ; JP C,F1E
ORIGINAL_MENUPICK:
        DB #DD,#7E,#0C,#3D,#26,#00,#6F          ; LD A,(IX+12):DEC A:LD H,0:LD L,A
        DB #29,#29,#29,#29,#29,#29,#29,#29,#29  ; ADD HL,HL девять раз
        DB #01,#00,#C0,#09                      ; LD BC,#C000:ADD HL,BC

; Переключать окно #8000 отсюда нельзя: сам перехват в нём и лежит. Поэтому
; сначала менеджер подключается к #C000, а окно #8000 меняет уже его код.
MENUBUILD_CODE:
        DB #3E,#00                              ; LD A,#page
        DB #CD,#C1,#68                          ; CALL MNGC
        DB #C3,#08,#C3                          ; JP PLM_MENU — меню целиком наше
MENUBUILD_END:
        ASSERT MENUBUILD_END-MENUBUILD_CODE == MENUBUILD_LENGTH, перехват меню изменил длину

; Строка меню -> запись: таблицу строит сам менеджер при построении списка,
; поэтому здесь не нужно ни переключать страницы, ни звать менеджер.
MENUPICK_CODE:
        DB #DD,#7E,#0C                          ; LD A,(IX+12)
        DB #6F                                  ; LD L,A
        DB #26,#BE                              ; LD H,high MENUTAB
        DB #66                                  ; LD H,(HL) — старший байт записи
        DB #2E,#00                              ; LD L,0
        DB #00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00
MENUPICK_END:
        ASSERT MENUPICK_END-MENUPICK_CODE == MENUPICK_LENGTH, перехват выбора изменил длину


GATEWAY_CODE:
        DB #3A,#03,#60                          ; LD A,(#6003)
        DB #08                                  ; EX AF,AF'
        DB #3E,#00                              ; LD A,#page — правит установщик
        DB #CD,#C1,#68                          ; CALL #68C1
        DB #CD,#00,#C3                          ; CALL PLM_ENTRY
        DB #C3,#B1,#68                          ; JP #68B1
GATEWAY_END:
        ASSERT GATEWAY_END-GATEWAY_CODE == GATEWAY_LENGTH, шлюз запуска изменил длину

WALK_CODE:
        DB #3E,#00                              ; LD A,#page — правит установщик
        DB #CD,#C1,#68                          ; CALL #68C1
        DB #CD,#04,#C3                          ; CALL PLM_REGISTER
        DB #C3,#B9,#97                          ; JP LGW
WALK_END:
        ASSERT WALK_END-WALK_CODE <= WALK_LENGTH, перехват регистрации длиннее цикла

COMPARE_VIEW:
        LD A,(DE)
        CP (HL)
        RET NZ
        INC HL
        INC DE
        DJNZ COMPARE_VIEW
        RET

; Описатель окна меню и его тексты лежат в странице WC, а во время меню там
; стоит страница менеджера. Поэтому при установке, пока WC ещё в окне #8000,
; описатель копируется к себе, а указатели на тексты правятся на свою копию.
COPY_WINDOW:
        LD HL,MENUWND
        LD DE,WNDCOPY-VIEW+RUNTIME
        LD BC,MENUWND_LENGTH
        LDIR
        LD HL,MENUTEXT
        LD DE,WNDTEXT-VIEW+RUNTIME
        LD BC,MENUTEXT_LENGTH
        LDIR
        LD HL,WNDTEXT
        LD (WNDCOPY-VIEW+RUNTIME+16),HL         ; заголовок окна
        LD HL,FOOTER_TEXT
        LD (WNDCOPY-VIEW+RUNTIME+18),HL         ; подвал — свой, со счётчиком памяти
        RET

        ASSERT $-RUNTIME <= #300, установщик не помещается до постоянных входов
        DS ENTRY-$,0
        ASSERT $ == ENTRY, сдвинулся постоянный вход менеджера

; --- постоянные входы (вызываются из шлюзов, страница в окне #C000) ---------
; Заголовок запускаемого плагина лежит в LOBU (#B000) — в окне #8000, которое
; сейчас занято WC. Копируем его к себе, только потом подключаем себя к #8000:
; после этого #B000 станет нашей же памятью.
PLM_ENTRY:                                      ; #C300 — запуск плагина
        XOR A
        JR PLM_COMMON
        DS ENTRY+4-$,0
PLM_REGISTER:                                   ; #C304 — регистрация плагина
        LD A,#01
        JR PLM_COMMON
        DS ENTRY+8-$,0
PLM_MENU:                                       ; #C308 — меню плагинов целиком
        JP MENU_ENTRY
        DS ENTRY+16-$,0
PLM_COMMON:
        DI
        PUSH AF
        LD HL,LOBU
        LD DE,COPY-VIEW+RUNTIME
        LD BC,512
        LDIR                                    ; копия заголовка в свою страницу
        LD A,(OWN-VIEW+RUNTIME)
        CALL MNG8                               ; страница менеджера в окно #8000
        POP AF
        JP VIEW+(PLM_COMMON_VIEW-RUNTIME)       ; дальше — только в виде #8000

; Продолжение общего входа в «рабочем» виде адресов: рабочая часть переключает
; окно #C000 под свои нужды, поэтому возвращаться в код, собранный для #C000,
; после неё нельзя.
PLM_COMMON_VIEW:
        LD (MODE),A
        CALL WORK
        EI
        RET

; Окно #8000 переключается здесь, в коде по #C3xx: обе страницы наши, поэтому
; дальше меню работает уже в виде #8000.
MENU_ENTRY:
        LD A,(OWN-VIEW+RUNTIME)
        CALL MNG8
        JP MENU_SHOW

; Возвраты из меню в WC: сюда меню приходит, подключив себя к окну #C000.
MENU_TO_QUIT:
        LD A,#02
        CALL MNG8
        JP MENUQUIT                             ; F1E снимет IX и вернётся

MENU_TO_EXEC:
        CALL MENU_GIVE
        JP MENUEXEC                             ; PSEXE запустит выбранную строку

; Вернуть окно #8000 коммандеру и отдать ему ровно одну выбранную строку.
MENU_GIVE:
        LD A,(PICKED-VIEW+RUNTIME)
        EX AF,AF'                               ; MNG8 разрушает BC, но не AF'
        LD A,#02
        CALL MNG8
        EX AF,AF'
        LD (MENUTAB+1),A
        LD IX,MENUWND
        LD (IX+12),1
        RET

        ASSERT $-RUNTIME <= #1000, входы налезли на рабочую часть
        DS RUNTIME+#1000-$,0
        ENT                                     ; sjasmplus не вкладывает DISP

; --- рабочая часть: выполняется по #9000, окно #C000 свободно ---------------
        ASSERT $ == MAIN_FILE_START+#1000, сдвинулась рабочая часть
        DISP WORK

WORKER:
        LD A,(MODE)
        DEC A
        JP Z,REGISTER
        DEC A
        JP Z,INSTALL_SCAN

; Запуск: при необходимости загрузить плагин и вернуть страницу входа.
LAUNCH:
        CALL FIND_RECORD
        JR C,.by_copy                           ; записи нет — верим копии
        CALL TOUCH                              ; отметить время запуска
        LD A,(HL)
        CP #FF
        CALL Z,LOAD_PLUGIN                      ; HL — запись
        JR .ready
.by_copy:
        LD A,(COPY+REC_BASE)
.ready:
        LD (PPGP),A
        LD HL,COPY+REC_ENTRY
        ADD A,(HL)
        ADD A,PLGPG
        RET

; Отметить запись текущим значением счётчика запусков. HL — запись.
TOUCH:
        PUSH HL
        LD DE,REC_STAMP
        ADD HL,DE
        LD DE,(USAGE)
        INC DE
        LD (USAGE),DE
        LD (HL),E
        INC HL
        LD (HL),D
        POP HL
        RET

; Регистрация вручную загруженного .WMF: запомнить кластер, ничего не выделять.
REGISTER:
        LD A,PLHPG
        CALL MNGC
        LD HL,(PHED)
        LD DE,0-512
        ADD HL,DE                               ; только что добавленная запись
        PUSH HL
        INC HL
        EX DE,HL
        LD HL,BRRR
        LD BC,4
        LDIR                                    ; +1..+4 — первый кластер .WMF
        POP HL
        PUSH HL
        LD DE,REC_TYPE
        ADD HL,DE
        LD A,(HL)
        POP HL
        CP #06
        JR Z,REGISTER_RESIDENT
        LD (HL),#FF                             ; база: не загружен
        LD A,(PPGM)
        LD (PPG2),A                             ; LGW не сдвинет ватерлинию
        RET
REGISTER_RESIDENT:
        LD A,(HL)
        LD (PPGP),A
        JP LOAD_BLOCKS                          ; поток уже стоит за заголовком

; --- установка: освободить пул и запомнить кластеры -------------------------
INSTALL_SCAN:
        LD A,PLHPG
        CALL MNGC
        LD HL,HEADERS
        LD C,0                                  ; вершина резидентной части
.records:
        CALL RECORD_VALID
        JR C,.records_done
        PUSH HL
        LD DE,REC_TYPE
        ADD HL,DE
        LD A,(HL)
        POP HL
        CP #06
        JR Z,.resident
        LD (HL),#FF                             ; нерезидентный — выгружен
        JR .next_record
.resident:
        PUSH HL
        LD A,(HL)
        LD DE,REC_PAGES
        ADD HL,DE
        ADD A,(HL)                              ; база + страниц
        POP HL
        CP C
        JR C,.next_record
        LD C,A
.next_record:
        LD DE,512
        ADD HL,DE
        JR .records
.records_done:
        LD A,C
        LD (PPGM),A                             ; пул свободен выше резидентов
        LD (RESTOP),A                           ; ниже этой границы ничего не двигаем
        LD (INIPAGE),A
        LD HL,0
        LD (USAGE),HL
        XOR A
        LD (MTOP),A                             ; меню открывается с начала списка
        LD (MCUR),A

; Прочитать wc.ini в первую свободную страницу пула и вынести оттуда имена:
; после первого же файлового вызова текст там перестанет быть текстом, потому
; что CORE32 использует окно #C000 под свой буфер.
        LD HL,INI_QUERY
        CALL SRHDRN
        RET Z                                   ; нет wc.ini — выходим
        CALL STORE_CLUSTER
        LD HL,CLUSTER
        CALL GIPAG
        LD A,(INIPAGE)
        CALL MNGC_PL
        LD HL,HEADERS
        LD B,16                                 ; до 8 КиБ текста
        CALL LOAD512

        LD HL,HEADERS
        LD DE,INI_SECTION
        CALL FIND_SUBSTRING
        RET C
        LD DE,NAMES
.collect:
        PUSH DE                                 ; BUILD_QUERY занимает DE под QUERY
        CALL BUILD_QUERY
        POP DE
        JR C,.collected
        LD A,D
        CP high (NAMES+#0200)
        JR NC,.collected                        ; список заполнен
        PUSH HL
        LD HL,QUERY+1
        LD A,(HL)
        OR A
        JR Z,.skip_empty
.copy_name:
        LD A,(HL)
        LD (DE),A
        INC HL
        INC DE
        OR A
        JR NZ,.copy_name
.skip_empty:
        POP HL
        JR .collect
.collected:
        XOR A
        LD (DE),A                               ; пустое имя — конец списка

        LD HL,NAMES
.each_name:
        LD A,(HL)
        OR A
        RET Z
        LD DE,QUERY+1
        XOR A
        LD (QUERY),A                            ; тип: обычный файл
.build:
        LD A,(HL)
        LD (DE),A
        INC HL
        INC DE
        OR A
        JR NZ,.build
        PUSH HL
        CALL CAPTURE
        POP HL
        JR .each_name

; Найти файл плагина, сверить его заголовок с таблицей и записать кластер.
CAPTURE:
        LD A,(QUERY+1)
        OR A
        RET Z
        LD A,(INIPAGE)
        CALL MNGC_PL                            ; свободная страница под буфер CORE32
        LD HL,QUERY
        CALL SRHDRN
        RET Z                                   ; файла нет
        CALL STORE_CLUSTER
        LD HL,CLUSTER
        CALL GIPAG
        LD HL,SECTOR
        LD B,1
        CALL LOAD512                            ; первый сектор .WMF
        LD A,PLHPG
        CALL MNGC
        LD HL,HEADERS
.find:
        CALL RECORD_VALID
        RET C
        PUSH HL
        LD DE,REC_NAME
        ADD HL,DE
        EX DE,HL
        LD HL,SECTOR+REC_NAME
        LD B,32
        CALL COMPARE
        POP HL
        JR Z,.found
        LD DE,512
        ADD HL,DE
        JR .find
.found:
        INC HL                                  ; +1: поле кластера
        EX DE,HL
        LD HL,CLUSTER
        LD BC,4
        LDIR
        RET

; HL:DE после SRHDRN -> CLUSTER
STORE_CLUSTER:
        LD (CLUSTER),HL
        LD (CLUSTER+2),DE
        RET

; --- загрузка плагина по требованию -----------------------------------------
; Вход: COPY — копия заголовка (база #FF). Выход: A — база.
LOAD_PLUGIN:
        LD (RECORD),HL                          ; вытеснение и уплотнение портят HL
        PUSH HL
        LD DE,REC_PAGES
        ADD HL,DE
        LD A,(HL)
        LD (NEEDED),A                           ; сколько страниц нужно
        POP HL
        CALL ENSURE_SPACE                       ; при нехватке вытеснить и уплотнить
        JR C,LOAD_FAILED
        LD HL,(RECORD)
        LD A,(PPGM)
        LD C,A                                  ; база-кандидат
        LD A,(NEEDED)
        ADD A,C
        LD (PPGM),A
        LD (HL),C                               ; база в запись
        LD A,C
        LD (COPY+REC_BASE),A
        LD (PPGP),A

        INC HL
        LD DE,CLUSTER
        LD BC,4
        LDIR                                    ; кластер файла в буфер
        LD A,(INIPAGE)
        CALL MNGC_PL                            ; убрать таблицу из окна #C000
        LD HL,CLUSTER
        CALL GIPAG
        LD HL,SECTOR
        LD B,1
        CALL LOAD512                            ; пропустить сектор заголовка
        CALL LOAD_BLOCKS
        LD A,(COPY+REC_BASE)
        RET

LOAD_FAILED:
        ; Вернуть страницу самого менеджера: WC вызовет её по #8000, установщик
        ; увидит уже стоящий перехват и просто выйдет.
        LD A,(OWN)
        SUB PLGPG
        LD (COPY+REC_BASE),A
        LD HL,COPY+REC_ENTRY
        LD (HL),0
        RET

; Загрузить блоки по описанию COPY+36 в страницы плагина (база в PPGP).
LOAD_BLOCKS:
        LD HL,COPY+REC_BLOCKS
.next:
        LD A,(HL)
        INC HL
        CALL MNGC_PL
        LD A,(HL)
        INC HL
        OR A
        RET Z
        PUSH HL
        LD B,A
        LD HL,HEADERS
        CALL LOAD512
        POP HL
        JR .next

; --- место в пуле: вытеснение по давности и уплотнение ----------------------
; Выход: CF=0 — нужные NEEDED страниц помещаются начиная с PPGM.
ENSURE_SPACE:
        XOR A
        LD (EVICTED),A
.retry:
        LD A,(PPGM)
        LD B,A
        LD A,(NEEDED)
        ADD A,B
        JR C,.evict
        CP POOL_LIMIT
        JR C,.fits
.evict:
        CALL EVICT_ONE
        JR NC,.evicted
        LD A,#03
        LD (TRACE),A
        SCF
        RET                                     ; вытеснять некого — отказ
.evicted:
        LD A,(EVICTED)
        INC A
        LD (EVICTED),A
        CALL COMPACT
        JR .retry
.fits:
        LD A,#01
        LD (TRACE),A
        OR A
        RET

; Выгрузить самый давно использованный загруженный нерезидентный плагин.
; Выход: CF=0 — выгрузили, CF=1 — некого.
EVICT_ONE:
        LD HL,0
        LD (BEST),HL
        LD HL,#FFFF
        LD (BESTSTAMP),HL
        LD A,PLHPG
        CALL MNGC
        LD HL,HEADERS
.loop:
        CALL RECORD_VALID
        JR C,.chosen
        LD A,(HL)
        CP #FF
        JR Z,.next                              ; уже выгружен
        PUSH HL
        LD DE,REC_TYPE
        ADD HL,DE
        LD A,(HL)
        POP HL
        CP #06
        JR Z,.next                              ; резидент не трогаем
        PUSH HL
        LD DE,REC_STAMP
        ADD HL,DE
        LD E,(HL)
        INC HL
        LD D,(HL)                               ; DE — отметка записи
        LD HL,(BESTSTAMP)
        OR A
        SBC HL,DE
        POP HL
        JR C,.next                              ; текущий кандидат свежее
        PUSH HL
        LD DE,REC_STAMP
        ADD HL,DE
        LD E,(HL)
        INC HL
        LD D,(HL)
        LD (BESTSTAMP),DE
        POP HL
        LD (BEST),HL
.next:
        LD DE,512
        ADD HL,DE
        JR .loop
.chosen:
        LD HL,(BEST)
        LD A,H
        OR L
        SCF
        RET Z
        LD A,(HL)
        LD (EVBASE),A                           ; отладка: кого вытеснили
        LD (HL),#FF                             ; запись помечена выгруженной
        OR A
        RET

; Сдвинуть загруженные нерезидентные плагины вниз, закрыв дыры после вытеснения.
; Резиденты остаются на месте: их физические страницы прошиты в шлюзах.
COMPACT:
        XOR A
        LD (MOVES),A
        LD (ROUNDS),A
        LD A,(RESTOP)
        LD (NEXTBASE),A
.round:
        LD A,(ROUNDS)
        INC A
        LD (ROUNDS),A
        CALL FIND_LOWEST
        JR C,.done
        LD A,(HL)
        LD (CFIRST),A                           ; отладка: что нашли
        LD B,A                                  ; текущая база
        LD A,(NEXTBASE)
        CP B
        JR Z,.keep
        PUSH HL
        LD DE,REC_PAGES
        ADD HL,DE
        LD C,(HL)                               ; сколько страниц переносить
        POP HL
        CALL MOVE_PAGES                         ; A — куда, B — откуда, C — сколько
        LD A,(MOVES)
        INC A
        LD (MOVES),A
        LD A,(NEXTBASE)
        LD (HL),A                               ; новая база
.keep:
        PUSH HL
        LD DE,REC_PAGES
        ADD HL,DE
        LD A,(NEXTBASE)
        ADD A,(HL)
        LD (NEXTBASE),A
        POP HL
        JR .round
.done:
        LD A,(NEXTBASE)
        LD (PPGM),A                             ; ватерлиния над уплотнённой частью
        RET

; Найти загруженную нерезидентную запись с наименьшей базой не ниже NEXTBASE.
; Выход: HL — запись, CF=0; CF=1 — таких нет.
FIND_LOWEST:
        LD HL,0
        LD (BEST),HL
        LD A,#FF
        LD (BESTSTAMP),A                        ; здесь храним лучшую базу
        LD A,PLHPG
        CALL MNGC
        LD HL,HEADERS
.loop:
        CALL RECORD_VALID
        JR C,.chosen
        LD A,(HL)
        CP #FF
        JR Z,.next
        PUSH HL
        LD DE,REC_TYPE
        ADD HL,DE
        LD A,(HL)
        POP HL
        CP #06
        JR Z,.next
        LD A,(NEXTBASE)
        LD B,A
        LD A,(HL)
        CP B
        JR C,.next                              ; ниже курсора — уже уплотнён
        LD B,A
        LD A,(BESTSTAMP)
        CP B
        JR C,.next                              ; есть кандидат с меньшей базой
        JR Z,.next
        LD A,B
        LD (BESTSTAMP),A
        LD (BEST),HL
.next:
        LD DE,512
        ADD HL,DE
        JR .loop
.chosen:
        LD HL,(BEST)
        LD A,H
        OR L
        SCF
        RET Z
        OR A
        RET

; Перенести C страниц пула с логической B на логическую A (DMA, как в WC).
MOVE_PAGES:
        ADD A,PLGPG
        LD D,A                                  ; физическая страница назначения
        LD A,B
        ADD A,PLGPG
        LD E,A                                  ; физическая страница источника
.loop:
        CALL DMA_PAGE
        INC D
        INC E
        DEC C
        JR NZ,.loop
        RET

; Скопировать 16 КиБ физической страницы E в физическую страницу D.
DMA_PAGE:
        PUSH BC
        PUSH DE
        PUSH HL                                 ; HL — запись плагина у вызывающего
        LD HL,0
        LD BC,STS
        DB #ED,#70                              ; IN F,(C) — ждать свободный DMA
        JP M,$-2
        LD B,high DMASL:OUT (C),L
        LD B,high DMASH:OUT (C),H
        LD B,high DMASX:OUT (C),E
        LD B,high DMADL:OUT (C),L
        LD B,high DMADH:OUT (C),H
        LD B,high DMADX:OUT (C),D
        LD B,high DMA_T:LD A,31:OUT (C),A
        LD B,high DMA_N:LD A,255:OUT (C),A
        LD B,high DMA_C:LD A,%00000001:OUT (C),A
        LD B,high STS
        DB #ED,#70                              ; IN F,(C) — дождаться конца
        JP M,$-2
        POP HL
        POP DE
        POP BC
        RET

; --- меню F10: показывать только то, что из него запускается ----------------
; Типы, которые принимает PSEXE: #02, #03, #05, #11, #13, #15.
MENU_TYPE_OK:
        CP #02
        RET Z
        CP #03
        RET Z
        CP #05
        RET Z
        CP #11
        RET Z
        CP #13
        RET Z
        CP #15
        RET

MENU_WORK:
        LD A,PLHPG
        CALL MNGC
        LD HL,INDEX
        LD DE,INDEX+1
        LD BC,63
        LD (HL),0
        LDIR                                    ; строки меню считаем с чистой таблицы
        LD HL,HEADERS
        LD DE,LIST
        LD BC,0                                 ; накопленная длина списка
        PUSH IX
        LD IX,INDEX+1                           ; строки меню нумеруются с единицы
.loop:
        CALL RECORD_VALID
        JR C,.done
        CALL RECORD_TYPE
        CALL MENU_TYPE_OK
        JR NZ,.next
        LD A,H
        LD (IX+0),A                             ; строка меню -> старший байт записи
        INC IX
        PUSH HL
        PUSH BC
        LD BC,REC_NAME
        ADD HL,BC
        LD BC,32
        LDIR                                    ; имя в список
        POP BC
        POP HL
        LD A,C
        ADD A,32
        LD C,A
        JR NC,.next
        INC B
.next:
        PUSH BC
        LD BC,512
        ADD HL,BC
        POP BC
        JR .loop
.done:
        POP IX
        LD (COUNT),BC
        RET                                     ; список остался в своей странице

; --- меню плагинов: окно постоянной высоты, прокрутка и полоса прокрутки ----
; Всё меню работает из страницы менеджера в окне #8000. Вывод WC подключает к
; окну #C000 экран, а окно #8000 возвращает по тени #6002, поэтому страница
; менеджера всё это время на месте. Описатель окна и его тексты — своя копия:
; оригинал лежит в странице WC, которой в окне сейчас нет.
MENU_SHOW:
        DI
        CALL MENU_WORK                          ; имена запускаемых плагинов
        EI
        LD HL,(COUNT)
        LD A,H
        OR L
        JR NZ,.show
        LD A,(OWN)
        CALL MNGC
        JP MENU_TO_QUIT                         ; показывать нечего
.show:
        SRL H:RR L
        SRL H:RR L
        SRL H:RR L
        SRL H:RR L
        SRL H:RR L                              ; строк = длина списка / 32
        LD A,L
        LD (MCOUNT),A
        CALL MENU_HEIGHT
        LD (MROWS),A
        CALL MENU_CLAMP
        LD IX,WNDCOPY
        LD A,(MROWS)
        LD (IX+13),A                            ; столько строк видит курсор WC
        ADD A,2
        LD (IX+5),A                             ; высота окна: строки и рамка
        LD A,(MCUR)
        LD (IX+12),A
        CALL MENU_FOOTER                        ; сколько памяти пула ещё свободно
        CALL PRWOW
        CALL MENU_PAINT
MENU_LOOP:
        EI
        HALT
        CALL CURSOR
        CALL UPPP
        CALL NZ,MENU_UP
        CALL DWWW
        CALL NZ,MENU_DOWN
        CALL PGU
        CALL NZ,MENU_PAGE_UP
        CALL PGD
        CALL NZ,MENU_PAGE_DOWN
        CALL LFFF
        CALL NZ,MENU_HOME
        CALL RGGG
        CALL NZ,MENU_END
        CALL HOME_KEY
        CALL NZ,MENU_HOME
        CALL END_KEY
        CALL NZ,MENU_END
        CALL ESCK
        JR NZ,MENU_QUIT
        CALL ENKE
        JR NZ,MENU_RUN
        JR MENU_LOOP

; Выходы из меню. Вернуть в окно #8000 страницу WC отсюда нельзя: код меню в
; этом окне и лежит. Поэтому менеджер подключает себя к #C000 и передаёт
; управление своей же части, собранной для этого окна.
MENU_QUIT:
        CALL RRESB                              ; окно убирает свой же описатель
        LD A,(OWN)
        CALL MNGC
        JP MENU_TO_QUIT

MENU_RUN:
        CALL MENU_PICK
        LD A,(OWN)
        CALL MNGC
        JP MENU_TO_EXEC

; Запомнить выбранную строку и её запись: дальше страница менеджера уедет из
; окна #8000, и список будет недоступен.
MENU_PICK:
        LD A,(IX+12)
        LD (MCUR),A
        LD B,A
        LD A,(MTOP)
        ADD A,B                                 ; номер строки в полном списке
        LD L,A
        LD H,0
        LD DE,INDEX
        ADD HL,DE
        LD A,(HL)                               ; старший байт адреса записи
        LD (PICKED),A
        RET

; Подвал окна показывает, сколько памяти пула ещё свободно под плагины:
; удалять плагины из меню больше не нужно, а знать остаток полезно.
FOOTER_TEXT:
        DB #0B,11,#09                           ; отступ от края окна и цвет
        DB "Free: "
FOOTER_DIGITS:
        DB "0000K",0

MENU_FOOTER:
        LD A,(PPGM)
        LD B,A
        LD A,POOL_LIMIT
        SUB B
        JR NC,.pages
        XOR A                                   ; пул занят целиком
.pages:
        LD L,A
        LD H,0
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL                               ; страница пула — 16 КиБ
        LD DE,FOOTER_DIGITS
        LD BC,1000
        CALL .digit
        LD BC,100
        CALL .digit
        LD BC,10
        CALL .digit
        LD A,L
        ADD A,"0"
        LD (DE),A
; Ведущие нули заменяются пробелами: последняя цифра остаётся всегда.
        LD HL,FOOTER_DIGITS
        LD B,3
.blank:
        LD A,(HL)
        CP "0"
        RET NZ
        LD (HL)," "
        INC HL
        DJNZ .blank
        RET
.digit:
        LD A,"0"-1
.count:
        INC A
        OR A
        SBC HL,BC
        JR NC,.count
        ADD HL,BC
        LD (DE),A
        INC DE
        RET

; Сколько строк показывать: сколько помещается в текстовый экран, но не больше,
; чем есть в списке.
MENU_HEIGHT:
        LD A,(HEI)
        SUB 5                                   ; рамка окна, заголовок и клавиши
        IFDEF PLM_MENU_ROWS
        LD A,PLM_MENU_ROWS                      ; стендовая проверка прокрутки
        ENDIF
        LD B,A
        LD A,(MCOUNT)
        CP B
        RET C
        LD A,B
        RET

; Позиция прошлого открытия могла оказаться за пределами нового списка.
MENU_CLAMP:
        LD A,(MCOUNT)
        LD B,A
        LD A,(MROWS)
        NEG
        ADD A,B
        LD B,A                                  ; дальше этой строки не уехать
        LD A,(MTOP)
        CP B
        JR C,.top
        LD A,B
.top:
        LD (MTOP),A
        LD A,(MCUR)
        OR A
        JR Z,.first
        LD B,A
        LD A,(MROWS)
        CP B
        JR NC,.done
.first:
        LD A,1
        JR .set
.done:
        LD A,B
.set:
        LD (MCUR),A
        RET

; Перерисовать видимую часть списка и полосу прокрутки.
MENU_PAINT:
        LD A,(MTOP)
        LD L,A
        LD H,0
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL                               ; строка списка — 32 байта
        LD DE,LIST
        ADD HL,DE
        LD DE,#0101                             ; первая строка окна, колонка 1
        LD A,(MROWS)
        LD B,A
.row:
        PUSH BC
        PUSH DE
        PUSH HL
        LD BC,32
        CALL PRSRW
        POP HL
        LD BC,32
        ADD HL,BC
        POP DE
        INC D
        POP BC
        DJNZ .row

; Полоса прокрутки на правой границе окна: дорожка и ползунок в одну строку.
MENU_BAR:
        LD A,(MROWS)
        LD B,A
        LD A,(MCOUNT)
        CP B
        RET Z
        RET C                                   ; список влез целиком — полосы нет
        CALL MENU_KNOB                          ; строка ползунка, считая с нуля
        INC A
        LD C,A
        LD DE,#0100+BAR_COLUMN
        LD A,(MROWS)
        LD B,A
.row:
        LD A,BAR_TRACK
        DEC C
        JR NZ,.plain
        LD A,BAR_KNOB
.plain:
        LD (BARCH),A
        PUSH BC
        PUSH DE
        LD HL,BARCH
        LD BC,1
        CALL PRSRW
        POP DE
        INC D
        POP BC
        DJNZ .row
        RET

; Строка ползунка = MTOP * (MROWS-1) / (MCOUNT-MROWS), считая с нуля.
MENU_KNOB:
        LD A,(MROWS)
        DEC A
        LD B,A
        LD A,(MTOP)
        LD C,A
        LD HL,0
        LD A,B
        OR A
        JR Z,.divide
.multiply:
        LD D,0
        LD E,C
        ADD HL,DE
        DEC A
        JR NZ,.multiply
.divide:
        LD A,(MCOUNT)
        LD B,A
        LD A,(MROWS)
        NEG
        ADD A,B                                 ; делитель: MCOUNT-MROWS
        LD C,A
        LD B,0                                  ; частное
.step:
        LD A,H
        OR A
        JR NZ,.subtract
        LD A,L
        CP C
        JR C,.ready
.subtract:
        LD D,0
        LD E,C
        OR A
        SBC HL,DE
        INC B
        JR .step
.ready:
        LD A,B
        RET

; Вверх и вниз: пока курсор внутри окна — двигает его WC, на краю окна
; прокручивается сам список.
MENU_UP:
        LD A,(IX+12)
        DEC A
        JP NZ,CrUP
        LD A,(MTOP)
        OR A
        RET Z
        DEC A
        LD (MTOP),A
        JP MENU_PAINT

MENU_DOWN:
        LD A,(IX+12)
        CP (IX+13)
        JP C,CrDN
        LD A,(MTOP)
        LD B,A
        LD A,(MROWS)
        ADD A,B
        LD C,A
        LD A,(MCOUNT)
        CP C
        RET Z
        RET C
        LD A,B
        INC A
        LD (MTOP),A
        JP MENU_PAINT

; Home, End и стрелки вбок бросают в начало и конец всего списка — так же, как
; в оригинальном меню они бросали курсор в начало и конец окна.
MENU_HOME:
        CALL CURSER
        LD (IX+12),1
        XOR A
        LD (MTOP),A
        JP MENU_PAINT

MENU_END:
        CALL CURSER
        LD A,(IX+13)
        LD (IX+12),A
        LD A,(MCOUNT)
        LD B,A
        LD A,(MROWS)
        NEG
        ADD A,B
        LD (MTOP),A
        JP MENU_PAINT

; Страница вверх и вниз двигают окно на его высоту.
MENU_PAGE_UP:
        CALL CURSER
        LD (IX+12),1
        LD A,(MTOP)
        LD B,A
        LD A,(MROWS)
        LD C,A
        LD A,B
        SUB C
        JR NC,.set
        XOR A
.set:
        LD (MTOP),A
        JP MENU_PAINT

MENU_PAGE_DOWN:
        CALL CURSER
        LD A,(IX+13)
        LD (IX+12),A
        LD A,(MCOUNT)
        LD B,A
        LD A,(MROWS)
        NEG
        ADD A,B
        LD C,A                                  ; дальше этой строки не уехать
        LD A,(MTOP)
        LD B,A
        LD A,(MROWS)
        ADD A,B
        CP C
        JR C,.set
        LD A,C
.set:
        LD (MTOP),A
        JP MENU_PAINT

; Тип записи по HL в A; HL и BC сохраняются.
RECORD_TYPE:
        PUSH HL
        PUSH BC
        LD BC,REC_TYPE
        ADD HL,BC
        LD A,(HL)
        POP BC
        POP HL
        RET

; Найти запись запускаемого плагина по 32-байтовому имени.
; Выход: HL — адрес записи, CF=0; CF=1 — не найдена.
FIND_RECORD:
        LD A,PLHPG
        CALL MNGC
        LD HL,HEADERS
.next_record:
        CALL RECORD_VALID
        RET C
        PUSH HL
        LD DE,REC_NAME
        ADD HL,DE
        EX DE,HL
        LD HL,COPY+REC_NAME
        LD B,32
        CALL COMPARE
        POP HL
        RET Z
        LD DE,512
        ADD HL,DE
        JR .next_record

; CF=0 — по HL ещё лежит запись; CF=1 — таблица кончилась.
RECORD_VALID:
        PUSH HL
        PUSH DE                                 ; DE бывает курсором у вызывающего
        LD DE,(PHED)
        OR A
        SBC HL,DE
        POP DE
        POP HL
        CCF
        RET

; Сравнить B байт по HL и DE. Выход: Z — совпало.
COMPARE:
        LD A,(DE)
        CP (HL)
        RET NZ
        INC HL
        INC DE
        DJNZ COMPARE
        RET

; Найти образец DE (0 в конце) в тексте по HL. Выход: HL за образцом, CF=0.
FIND_SUBSTRING:
        PUSH HL
        PUSH DE
.inner:
        LD A,(DE)
        OR A
        JR Z,.hit
        CP (HL)
        JR NZ,.miss
        INC HL
        INC DE
        JR .inner
.hit:
        POP DE
        POP AF
        OR A
        RET
.miss:
        POP DE
        POP HL
        INC HL
        LD A,H
        OR A
        JR NZ,FIND_SUBSTRING                    ; #C000..#FFFF, дальше — конец
        SCF
        RET

; Собрать в QUERY запрос [тип,имя,0] из очередной строки [PLUGINS].
; Вход: HL — текст. Выход: HL — следующая строка, CF=1 — секция кончилась.
BUILD_QUERY:
        LD A,H
        CP #E0                                  ; прочитано только #C000..#DFFF
        JR NC,.end
        LD A,(HL)
        OR A
        JR Z,.end
        CP #0D
        JR NZ,.not_cr
        INC HL
        JR BUILD_QUERY
.not_cr:
        CP #0A
        JR NZ,.start
        INC HL
        JR BUILD_QUERY
.start:
        CP "["
        JR Z,.end
        XOR A
        LD (QUERY),A                            ; тип: обычный файл
        LD DE,QUERY+1
.copy:
        LD A,(HL)
        OR A
        JR Z,.done
        CP #0D
        JR Z,.done
        CP ";"
        JR Z,.tail
        CP " "
        JR Z,.tail
        LD (DE),A
        INC DE
        INC HL
        JR .copy
.tail:
        LD A,(HL)
        OR A
        JR Z,.done
        CP #0D
        JR Z,.done
        INC HL
        JR .tail
.done:
        XOR A
        LD (DE),A
        RET
.end:
        SCF
        RET

INI_QUERY:
        DB #00,"wc.ini",0
INI_SECTION:
        DB "[PLUGINS]",0

WORK_END:
        ASSERT WORK_END-WORKER <= COPY-WORK, рабочая часть налезла на буферы
        ENT
WORK_FILE_END:
PLUGIN_FILE_END:
        SAVEBIN "Build/PLM.WMF",START_CODE,PLUGIN_FILE_END-START_CODE
