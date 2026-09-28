; Codex - 2026-07-17 - begin
; Wild Commander v1.11i 2026-09-24 — исследованная улучшенная сборка из восстановленных
; Codex - 2026-07-17 - end
; исходников и аннотированных exact-модулей, для которых исходник ещё не доказан.
; Основание исследования — локальный эталон exe/boot.$C, а не исходники репозитория.
; Границы кода и данных проверяются по эталонному образу; пока назначение области
; не доказано, её байты сохраняются явно, без выдуманных названий и трактовок.
;
; Состав файла и основные точки входа:
;   #6011 WC_ENTRY       — запуск коммандера и установка WildDOS;
;   #6049 WC_MAIN_LOOP   — кадровый диспетчер клавиатуры и команд панелей;
;   #6715 I_N_T          — обработчик IM2;
;   #7143 TAB4E          — начало подсистемы PS/2 и строкового ввода;
;   #7828 PBINIT         — интерфейс окон и индикатора прогресса;
;   #8531 F36            — файловые операции и команды функциональных клавиш;
;   #9149 NXTFL          — просмотрщики, запуск форматов и плагины;
;   #9B7C WCINI          — чтение wc.ini, пути панелей, загрузка плагинов;
;   #C000 WDOS.INSTALL_WILDDOS — физический загрузчик WildDOS;
;   #5AAA DEHRUST        — рабочий адрес распаковщика драйверов после копирования.
; Сборка: SJASMPlus 1.21. SHA-256 полезной нагрузки вычисляется по
; Build/boot.payload.bin; SHA-256 готового exe/boot.$C выводит build.ps1.

        INCLUDE "PHYSICAL_MEMORY_MAP.ASM"
        INCLUDE "VERSION.ASM"

        ORG #6011

; Переключаемая 16-КиБ страница по #C000 используется как общий файловый,
; просмотровый и загрузочный буфер. Это адрес окна памяти, а не имя процедуры.
RAM_PAGE_C000 EQU #C000
; Claude - 2026-09-26 - begin
; Символы нижней рамки окна для WCIF (L7828_28 — FLL исторического исходника):
; D — левый угол «└» (#C0), E — правый «┘» (#D9), заполнение «─» (#C4) — в C.
; Прежде эта константа ошибочно считалась адресом JR Z в образе WildDOS.
FRAME_BOTTOM_CHARS EQU #C0D9
; Claude - 2026-09-26 - end

; Модули разделены по назначению и порядку включения оригинальных исходников.
; ASSERT немедленно останавливает сборку при смещении любой доказанной границы.

        INCLUDE "MD20.ASM"
        ASSERT $ == #7143, нарушена граница MD20.ASM

        INCLUDE "PS2P.ASM"
        ASSERT $ == #7828, нарушена граница PS2P.ASM

        INCLUDE "WCIF.ASM"
        ASSERT $ == #7EA0, нарушена граница WCIF.ASM

        INCLUDE "WCVLS.ASM"
        ASSERT $ == #8531, нарушена граница WCVLS.ASM

        MODULE WCFX
        INCLUDE "WCFX.ASM"
        ENDMODULE
        ASSERT $ == #9149, нарушена граница WCFX.ASM

        MODULE WCVW
        INCLUDE "WCVW.ASM"
        ENDMODULE
        ASSERT $ == #9B7C, нарушена граница WCVW.ASM

        MODULE WCINI
        INCLUDE "WCINI.ASM"
        ENDMODULE
        ; WCINI отдаёт место расширению WildDOS по мере выноса диалога в
        ; плагин настроек, поэтому граница проверяется сверху, а не точно.
        ASSERT $ <= #AB9F, WCINI.ASM вырос за прежнюю границу

; Claude - 2026-09-26 - begin
; Ресурсы запуска, извлечённые из поставляемого образа: шрифт FONT32L3.CDB
; (#800 байт) и распаковщики MLZ50F.CCB (#E9) и DEHR1M.CCB (#117). Прежде они
; лежали здесь несжатыми (2560 байт) и VDAC копировал их LDIR; теперь это
; HR-потоки из build.ps1 (упаковка MHMT со сверкой обратной распаковкой), а VDAC
; распаковывает их DEHR ядра (#5AAA): шрифт — в страницы #01 и #09 с #C000,
; пару MLZ50F+DEHR1M, склеенную в порядке назначения, — в #01 с #FE00. Байты в
; этих страницах те же, что прежде.
FONT32L3_PACKED:
        INCBIN "../Build/FONT32L3.CPD"
DECODERS_PACKED:
        INCBIN "../Build/DECODERS.CPD"
; Claude - 2026-09-26 - end

; Codex - 2026-07-16 - begin
; В исходном образе эта область была заполнена нулями. Улучшенная сборка хранит
; здесь продолжение WildDOS: короткий установщик и код исправлений. Расширение
; устанавливается в первую приватную страницу Improved (#E8) и вызывается через
; окно #C000 с обязательным восстановлением прежней страницы. Диапазон Improved
; #E8..#EF отделён от RAM-диска Mounter #C0..#E7 и системных страниц #F0..#FF
; общим контрактом PHYSICAL_MEMORY_MAP.ASM.

; Codex - 2026-07-17 - begin
; Интерфейс известен обоим проходам сборки. Таблица JP начинается ровно с
; #C000, поэтому продолжение шлюза следует сразу после ID_COUNT строк.
        MODULE WDOS_EXT
RUNTIME_START EQU #C000
        INCLUDE "CORE32_EXT_API.ASM"
GATE_CONTINUE EQU RUNTIME_START+ID_COUNT*3
        ENDMODULE
; Claude - 2026-09-27 - begin
; Runtime-адрес начала части 2 (WDOS_EXT_PART2_START) пишет build.ps1 после
; отдельной сборки расширения. Проход замера (WDOS_MEASURE_PASS) собирает
; образ без потоков расширения: build.ps1 берёт из него место потоков —
; WDOS_EXTENSION_PACKED..#BF60 и хвост от WDOS_EXTENSION2_PACKED до #E000 — и
; по нему выбирает границу частей.
        IFNDEF WDOS_SYMBOL_PASS
        IFDEF WDOS_MEASURE_PASS
WDOS_EXT_PART2_START EQU WDOS_EXT.RUNTIME_START+1
        ELSE
        INCLUDE "../Build/CORE32_EXT_PARTS.INC"
        ENDIF
        ENDIF
; Claude - 2026-09-27 - end

        IFDEF WDOS_SYMBOL_PASS
; Символический проход нужен только для карты адресов @WDOS.* отдельной сборки
; расширения. Метка LB59F названа по историческому адресу установщика
; (#B59F); с укорочением WCINI он сдвинулся, адрес берётся по метке.
LB59F:
WDOS_INSTALL_COPY:
        LDIR                            ; исходный CORE32 #C00C -> #4000
        LD HL,PLUGIN_REFRESH_TEMPLATE
        LD C,PLUGIN_REFRESH_LENGTH      ; после LDIR BC=0, DE=WDOS.END=#5BF2
        LDIR                            ; постоянный обработчик, вне буфера F9
        RET
; Автозапуск типа #06 живёт в нулевой области: точные модули не двигаются.
        INCLUDE "PLUGIN_REFRESH.ASM"
        INCLUDE "AUTOEXEC.ASM"
        DS #C000-$,0
        ELSE
; Codex - 2026-07-17 - end
LB59F:
WDOS_INSTALL_COPY:
; Claude - 2026-09-27 - begin
        ; Файл дочитан до конца? Метка сборки — в самом его конце, за потоком
        ; части 2 расширения. Проверка — до любой распаковки: загрузчик,
        ; прочитавший не весь файл (прежний размер — 124 сектора), оставил бы
        ; чужие байты и на месте потока кода ядра, и на месте части 2. Метки
        ; нет — красный бордюр и остановка: такой WC запускать нельзя.
        LD A,(WDOS_EXTENSION2_PACKED_END)
        CP low WDOS_EXTENSION2_MARK
        JP NZ,WDOS_TAIL_MISSING
        LD A,(WDOS_EXTENSION2_PACKED_END+1)
        CP high WDOS_EXTENSION2_MARK
        JP NZ,WDOS_TAIL_MISSING
        ; Ядро в файле (ниже, #C000): драйверы DR1..DR4 и DEHR как есть — их
        ; сюда LDIR (HL, DE, BC ставит заглушка), код #4000..DR1 — HR-потоком:
        ; его разворачивает только что поставленный DEHR (#5AAA). Поток лежит
        ; выше приёмника — DEHR его не переносит.
        LDIR
        PUSH IX
        LD HL,WDOS_CORE_PACKED
        LD DE,WDOS.START
        CALL #5AAA
        POP IX
        LD DE,WDOS.END
; Claude - 2026-09-27 - end
        ; DE — сразу за ядром. Устанавливаем обработчик до FINI и любого
        ; запуска плагинов. Шаблон по #BF60 далее не нужен: F9 может свободно
        ; использовать весь LOBU.
        LD HL,PLUGIN_REFRESH_TEMPLATE
        LD BC,PLUGIN_REFRESH_LENGTH
        LDIR
; Claude - 2026-09-26 - begin
        ; Шина SPI Z-Controller (#77 — выбор устройств, #57 — данные) общая у
        ; SD-карты и FT812 платы VDAC2, а аппаратный сброс TS-Config её не
        ; нормализует: если сброс пришёлся на обмен, защёлка #77 остаётся с
        ; выбранным FT812 (#07) или SD. До первого обращения WC к шине (чтение
        ; wc.ini в FINI) снимаем выбор обоих (#03), даём 16 байт #FF — 128
        ; тактов, чтобы устройство закончило начатую фазу, — и снова пишем #03.
        ; Это проверенная на железе последовательность SpiBusIdle из порта
        ; Zuma Deluxe для VDAC2/FT812. Раньше, в INIT, шина не используется.
        LD BC,#0077
        LD A,#03
        OUT (C),A
        LD C,#57
        LD A,#FF
        LD D,16
.spi_idle_clock:
        OUT (C),A
        DEC D
        JR NZ,.spi_idle_clock
        LD C,#77
        LD A,#03
        OUT (C),A
; Claude - 2026-09-26 - end
        LD BC,#13AF
        IN A,(C)
        PUSH BC
        PUSH AF
        LD A,WC_PHYS_CORE32_EXT_PAGE
        OUT (C),A
; Codex - 2026-07-17 - begin
        ; DEHR уже скопирован по #5AAA. Он распаковывает проверенный HR-поток
        ; прямо в подключённую страницу #E8, начиная с runtime-адреса #C000.
        ; DEHR разрушает IX и оба набора BC/DE/HL. IX сохраняем. Здесь нет
        ; живых альтернативных BC/DE/HL: установщик вызывается однократно из
        ; WC_ENTRY после INIT, до FINI, а не через API работающего менеджера.
        ; Удаление их лишнего сохранения даёт место копированию обработчика,
        ; сохраняя начало AUTOEXEC и весь фиксированный хвост boot.$C.
        ; Стек #5FFE остаётся вне окна #C000; DEHR балансирует свои PUSH/POP.
        ; Точный DEHR2 не выполняет EX AF,AF' и не изменяет AF'.
        PUSH IX
        LD HL,WDOS_EXTENSION_PACKED
        LD DE,WDOS_EXT.RUNTIME_START
        CALL #5AAA
        POP IX
; Codex - 2026-07-17 - end
; Claude - 2026-09-27 - begin
        ; Часть 2 расширения лежит в хвосте файла, в загрузочной странице окна
        ; #C000: вернуть её, перенести поток на место потока части 1 (та уже
        ; распакована) и распаковать оттуда в #E8. Затем EXT_INSTALL_TAIL:
        ; упакованные драйверы ядра — в #E8, на их место в #05 — резидентный
        ; блок. BC=#13AF и загрузочная страница — из стека.
        POP AF
        POP BC
        PUSH BC
        PUSH AF
        OUT (C),A                       ; метку файла проверили в начале
        LD HL,WDOS_EXTENSION2_PACKED
        LD DE,WDOS_EXTENSION_PACKED
        LD BC,WDOS_EXTENSION2_LENGTH
        LDIR
        LD BC,#13AF
        LD A,WC_PHYS_CORE32_EXT_PAGE
        OUT (C),A
        PUSH IX
        LD HL,WDOS_EXTENSION_PACKED
        LD DE,WDOS_EXT_PART2_START
        CALL #5AAA
        POP IX
        CALL WDOS_EXT.RUNTIME_START+WDOS_EXT.ID_INSTALL_TAIL*3
; Claude - 2026-09-27 - end
        POP AF
        POP BC
        OUT (C),A
        RET
; Claude - 2026-09-27 - begin
WDOS_TAIL_MISSING:
        DI
        LD A,2
        OUT (#FE),A
        HALT
; Claude - 2026-09-27 - end

; Codex - 2026-07-17 - begin
WDOS_EXTENSION_PACKED:
        IFNDEF WDOS_MEASURE_PASS
        INCBIN "../Build/CORE32_EXT.CPD"
        ENDIF
WDOS_EXTENSION_PACKED_END:
        ; AUTOEXEC имеет фиксированные внешние адреса и не должен зависеть от
        ; степени сжатия расширения. #BF69 — его доказанное штатное начало.
        ASSERT WDOS_EXTENSION_PACKED_END <= #BF60, расширение пересекло шаблон обработчика
        INCLUDE "PLUGIN_REFRESH.ASM"
; Автозапуск типа #06 живёт в нулевой области: точные модули не двигаются.
        INCLUDE "AUTOEXEC.ASM"
        DS #C000-$,0
        ASSERT $ == #C000, нарушена граница нулевой области
        ENDIF
; Codex - 2026-07-17 - end
; Codex - 2026-07-16 - end

        IFDEF WDOS_SYMBOL_PASS
; Осмысленный CORE32 содержит загрузчик, ядро, точные упакованные драйверы
; и оригинальный DEHR2. MODULE изолирует исторические имена WildDOS от имён WC.
        MODULE WDOS
        INCLUDE "CORE32.ASM"
        ENDMODULE
; Codex - 2026-07-16 - begin
        ASSERT $ <= #DC00, нарушена конечная граница CORE32.ASM
; Codex - 2026-07-16 - end

; Хвост до полного размера payload: нули до #DC00, затем 17 байт,
; побайтно совпадающих с началом WildDOS #C000..#C010. Исполнение этой копии
; не доказано; структура записана явно, чтобы отдельный бинарный файл не скрывал её.
LDBD3:
        DS      #DC00-$,0
BOOT_TAIL_WILDDOS_PREFIX:
        DB      #21,#0C,#C0,#11,#00,#40,#01,#C7,#1B
        DB      #ED,#B0,#C9,#C3,#62,#43,#C3,#03
        ASSERT  $ == #DC11, нарушена конечная граница payload
        ELSE
; Claude - 2026-09-27 - begin
; Физический образ ядра. Прежде CORE32 лежал здесь как есть (#C00C..#DBFD), и
; LDIR переносил его в #4000..#5BF1. С 2026-09-27 в файле: заглушка установщика
; (#C000, на месте WDOS.INSTALL_WILDDOS), драйверы DR1..DR4 и DEHR как есть
; (LDIR — в #5176..#5BF1) и код ядра #4000..#5175 HR-потоком — его разворачивает
; DEHR (WDOS_INSTALL_COPY). Так boot.$C короче на ~1,1 КиБ: предел файла —
; 32768 байт (ниже). Байты ядра — из символического прохода (build.ps1:
; CORE32_RAW.bin, CORE32_CODE.CPD); сам CORE32.ASM собирается за логическим
; концом файла ради символов WDOS.*, build.ps1 отрезает его и сверяет байты.
; Прежние 17 байт по #DC00 (копия начала WildDOS; исполнение их не доказано)
; вместе с образом ядра ушли.
WDOS_CORE_STUB:
        LD HL,WDOS_CORE_RAW
        LD DE,WDOS.DR1
        LD BC,WDOS_CORE_RAW_LENGTH
        JP WDOS_INSTALL_COPY
        ASSERT WDOS_CORE_STUB == WDOS.INSTALL_WILDDOS, заглушка не на месте прежней
        ASSERT $ == WDOS.CORE32, заглушка установщика не 12 байт
WDOS_CORE_RAW:
        INCBIN "../Build/CORE32_RAW.bin"
WDOS_CORE_RAW_LENGTH EQU $-WDOS_CORE_RAW
        ASSERT WDOS_CORE_RAW_LENGTH == WDOS.END-WDOS.DR1, CORE32_RAW.bin не от этого ядра
WDOS_CORE_PACKED:
        INCBIN "../Build/CORE32_CODE.CPD"
; Часть 2 расширения (HR-поток CORE32_EXT2.CPD) — за потоком кода ядра, в
; той же загрузочной странице окна #C000. Весь boot.$C — не
; длиннее 32768 байт (конец не дальше #E000): BIOS TS-Conf читает файл целыми
; кластерами с #6000, и при кластере 32 КиБ (обычном у SDHC после SD
; Formatter) второй кластер — это 64 КиБ с #6000: через #FFFF он затирал
; #0000..#5FFF — экран, системные переменные и стек BIOS в странице 5, и
; машина падала до старта WC (стенд combo64: файл 35345 байт, два кластера).
; 32768 байт — один кластер 32 КиБ; меньшие кластеры в сумме тоже не дальше
; #DFFF. Кластер 64 КиБ не годится ни для какого boot.$C. Поэтому граница
; частей — по месту (build.ps1): поток части 1 занимает всё до #BF60, в хвост
; идёт остаток. Последний сектор Hobeta не добивается: 128 целых секторов —
; уже 32785 байт. WCVW.RUNHOB читает до конца цепочки — ему это всё равно.
WDOS_EXTENSION2_PACKED:
        IFNDEF WDOS_MEASURE_PASS
        INCBIN "../Build/CORE32_EXT2.CPD"
        ENDIF
WDOS_EXTENSION2_PACKED_END:
WDOS_EXTENSION2_LENGTH EQU WDOS_EXTENSION2_PACKED_END-WDOS_EXTENSION2_PACKED
; Метка сборки за потоком: установщик по ней видит, что файл дочитан.
WDOS_EXTENSION2_MARK EQU WDOS_EXTENSION2_LENGTH ^ #A55A
        DW WDOS_EXTENSION2_MARK
WDOS_BOOT_TAIL_END:                     ; логический конец файла (build.ps1)
        ASSERT WDOS_EXTENSION_PACKED+WDOS_EXTENSION2_LENGTH <= #BF60, часть 2 не помещается на место потока части 1
        ASSERT $ <= #E000, boot.$C длиннее 32768 байт - не загрузится с карты с кластером 32 КиБ
; Символы WildDOS: CORE32.ASM — за логическим концом файла. ORG #C000 модуля
; прежние байты не перекрывает: sjasmplus --raw пишет подряд; build.ps1 режет.
        MODULE WDOS
        INCLUDE "CORE32.ASM"
        ENDMODULE
        ENDIF
; Claude - 2026-09-27 - end
