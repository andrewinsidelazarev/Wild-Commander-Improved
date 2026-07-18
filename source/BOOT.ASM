; Codex - 2026-07-17 - begin
; Wild Commander v1.10i — исследованная улучшенная сборка из восстановленных
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
;   #9B7C F9STP          — настройка и обработка wc.ini;
;   #C000 WDOS.INSTALL_WILDDOS — физический загрузчик WildDOS;
;   #5AAA DEHRUST        — рабочий адрес распаковщика драйверов после копирования.
; Сборка: SJASMPlus 1.21. Ожидаемый SHA-256 полезной нагрузки:
; 9fb3b6a2a29ea2730201f4a0ff5c10cc7f666a1118a6d3a016f72e3d5c8fda7c

        INCLUDE "PHYSICAL_MEMORY_MAP.ASM"

        ORG #6011

; Переключаемая 16-КиБ страница по #C000 используется как общий файловый,
; просмотровый и загрузочный буфер. Это адрес окна памяти, а не имя процедуры.
RAM_PAGE_C000 EQU #C000
; Адрес команды `JR Z` в физическом образе WildDOS. WC использует его как
; готовый двухбайтовый фрагмент при построении условия фильтра каталога.
DIR_FILTER_PATCH EQU #C0D9

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
        ASSERT $ == #AB9F, нарушена граница WCINI.ASM

; Точные двоичные ресурсы, извлечённые из поставляемого образа.
LAB9F:
FONT32L3 EQU LAB9F
        INCBIN "FONT32L3.CDB"
        ASSERT $ == #B39F, нарушена граница FONT32L3.CDB

LB39F:
DEHR1M EQU LB39F
        INCBIN "DEHR1M.CCB"
        ASSERT $ == #B4B6, нарушена граница DEHR1M.CCB

LB4B6:
MLZ50F EQU LB4B6
        INCBIN "MLZ50F.CCB"
        ASSERT $ == #B59F, нарушена граница MLZ50F.CCB

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

        IFDEF WDOS_SYMBOL_PASS
; Символический проход нужен только для карты адресов @WDOS.* отдельной сборки
; расширения. Временный установщик сохраняет физический адрес #B59F.
LB59F:
WDOS_INSTALL_COPY:
        LDIR                            ; исходный CORE32 #C00C -> #4000
        RET
        DS #C000-$,0
        ELSE
; Codex - 2026-07-17 - end
LB59F:
WDOS_INSTALL_COPY:
        LDIR                            ; исходный CORE32 #C00C -> #4000
        LD BC,#13AF
        IN A,(C)
        PUSH AF
        LD A,WC_PHYS_CORE32_EXT_PAGE
        OUT (C),A
; Codex - 2026-07-17 - begin
        ; DEHR уже скопирован по #5AAA. Он распаковывает проверенный HR-поток
        ; прямо в подключённую страницу #E8, начиная с runtime-адреса #C000.
        ; В отличие от прежнего LDIR, DEHR разрушает IX и альтернативные
        ; регистры; временно сохранить их в ещё не используемых данных CORE32.
        LD (#5115),IX
        EXX
        LD (#5117),BC
        LD (#5119),DE
        LD (#511B),HL
        EXX
        EX AF,AF'
        PUSH AF
        POP HL
        LD (#511D),HL
        EX AF,AF'
        LD HL,WDOS_EXTENSION_PACKED
        LD DE,WDOS_EXT.RUNTIME_START
        CALL #5AAA
        LD IX,(#5115)
        EX AF,AF'
        LD HL,(#511D)
        PUSH HL
        POP AF
        EX AF,AF'
        EXX
        LD BC,(#5117)
        LD DE,(#5119)
        LD HL,(#511B)
        EXX
; Codex - 2026-07-17 - end
        POP AF
        LD BC,#13AF
        OUT (C),A
        RET

; Codex - 2026-07-17 - begin
WDOS_EXTENSION_PACKED:
        INCBIN "../Build/CORE32_EXT.CPD"
WDOS_EXTENSION_PACKED_END:
        ASSERT WDOS_EXTENSION_PACKED_END <= #C000, упакованное расширение WildDOS не помещается
        DS #C000-$,0
        ASSERT $ == #C000, нарушена граница нулевой области
        ENDIF
; Codex - 2026-07-17 - end
; Codex - 2026-07-16 - end

; Осмысленный CORE32 содержит загрузчик, ядро, точные упакованные драйверы
; и оригинальный DEHR2. MODULE изолирует исторические имена WildDOS от имён WC.
        MODULE WDOS
        INCLUDE "CORE32.ASM"
        ENDMODULE
        ASSERT DIR_FILTER_PATCH == WDOS.LC069_5, нарушен адрес фильтра каталога
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
