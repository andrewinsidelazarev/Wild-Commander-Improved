; FILEX.WMF — одностраничный провайдер публичного API 77 Wild Commander.
;
; Первые байты намеренно позиционно независимы: WC сначала выполняет их по
; #8000. Установщик только публикует физическую страницу в состоянии CORE32.
; Затем постоянный шлюз подключает ту же страницу к #C000 и вызывает #C010,
; куда собрана основная реализация.
;
; Claude - 2026-10-10 - begin
; С 2026-10-10 FILEX.WMF — обязательная часть расширения ядра: в нём хранится
; оверлей страницы #E8 (холодный код CORE32_EXT, которому нет места в boot.$C)
; и ставит его при ранней установке (+33 bit 0: ядро зовёт #06 с A=#07 сразу
; после загрузки FILEX, до остальных плагинов). Ставит, только если штамп
; сборки в #E8 совпал со своим; иначе OVERLAY_STATE=2, и AX_RUN останавливает
; WC с сообщением (FILEX_REQUIRED).
; Claude - 2026-10-10 - end

        DEVICE ZXSPECTRUM128

        MODULE WDOS
        INCLUDE "../../../Build/CORE32_WDOS_SYMBOLS.INC"
        ENDMODULE
        INCLUDE "../../CORE32_FILEX_API.ASM"
        INCLUDE "../../CORE32_EXT_API.ASM"
; Claude - 2026-10-10 - begin
        INCLUDE "../../PHYSICAL_MEMORY_MAP.ASM"
        INCLUDE "../../../Build/CORE32_EXT_OVERLAY.INC"
; Claude - 2026-10-10 - end

; Установщик патчит непосредственный операнд LD A,#page внутри резидентного
; шлюза FILEX. Обычные байты состояния #6000..#6010 принадлежат менеджеру
; плагинов и меняются при F10, тогда как код по #6A48 остаётся постоянным.
FILEX_PROVIDER_PAGE_ADDR EQU #6A48

        ORG #0000
START_CODE:
        DS 16,0
        DB "WildCommanderMDL"
        DB #0A
; Claude - 2026-10-10: +33 bit 0 — ранняя установка (оверлей ядра до прочих плагинов).
        DB #01
        DB #01
        DB #00
        DB #00,(PLUGIN_FILE_END-MAIN_FILE_START+511)/512
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DS 16,0
        DS 32*3,0
        DB #00
        DD #FFFFFFFF
FILEX_PLUGIN_NAME:
        DB "FILEX API provider v1"
        DS 32-($-FILEX_PLUGIN_NAME)," "
        DB #06
        DB #00

        ALIGN 512,0
MAIN_FILE_START:
        DISP #C000

; Выполняется по #8000, поэтому здесь нет относительных переходов или ссылок
; на локальный код, собранный для runtime-адреса #C000.
FILEX_INSTALL:
        LD A,(#6002)
        LD (FILEX_PROVIDER_PAGE_ADDR),A
; Claude - 2026-10-10 - begin
        JP FILEX_OVERLAY_INSTALL-#4000          ; та же страница по #8000
; Claude - 2026-10-10 - end
        DS #C010-$,0
        ASSERT $ == #C010, изменился фиксированный вход FILEX

        INCLUDE "FILEX_RUNTIME.ASM"

; Claude - 2026-10-10 - begin
; Поставить оверлей расширения ядра в страницу #E8 (по EXT_OVERLAY_START).
; Исполняется из установщика по #8000: свои данные и абсолютные переходы — по
; адресу минус #4000, остальное — JR/DJNZ. Второй вызов (AX_RUN, A=#06) видит
; OVERLAY_STATE=1 и выходит. На время копирования #E8 стоит в окне #C000 при
; закрытых прерываниях, как в шлюзе расширения; страница окна и IFF
; вызывающего возвращаются (ложный ноль LD A,I на NMOS ловит счётчик #6009).
FILEX_OVERLAY_INSTALL:
        LD A,(OVERLAY_STATE)
        DEC A
        JR Z,.done                              ; уже стоит
        LD A,(#6009)
        LD B,A
        LD D,1
        LD A,I
        DI
        JP PE,.iff_saved-#4000
        LD A,(#6009)
        SUB B
        LD D,A                                  ; ≠0 — прерывание было: EI
.iff_saved:
        LD BC,#13AF
        IN E,(C)                                ; страница окна #C000
        PUSH DE
        LD A,WC_PHYS_CORE32_EXT_PAGE
        OUT (C),A
        LD HL,EXT_STAMP_ADDR
        LD DE,FILEX_EXT_STAMP-#4000
        LD B,4
.compare:
        LD A,(DE)
        CP (HL)
        JR NZ,.foreign                          ; FILEX от другой сборки
        INC HL
        INC DE
        DJNZ .compare
        LD HL,FILEX_OVERLAY_IMAGE-#4000
        LD DE,EXT_OVERLAY_START
        LD BC,EXT_OVERLAY_LENGTH
        LDIR
        LD A,1
        JR .state
.foreign:
        LD A,2
.state:
        LD (OVERLAY_STATE),A
        POP DE
        LD A,E
        LD BC,#13AF
        OUT (C),A
        LD A,D
        OR A
        JR Z,.done
        EI
.done:
        XOR A
        RET
FILEX_EXT_STAMP:
        DB EXT_STAMP_0,EXT_STAMP_1,EXT_STAMP_2,EXT_STAMP_3
FILEX_OVERLAY_IMAGE:
        INCBIN "../../../Build/CORE32_EXT_OVL.bin"
        ASSERT $-FILEX_OVERLAY_IMAGE == EXT_OVERLAY_LENGTH, оверлей не той длины
; Claude - 2026-10-10 - end

MAIN_RUNTIME_END:
        ASSERT MAIN_RUNTIME_END-#C000 <= #4000, FILEX вышел за одну страницу
        ENT
PLUGIN_FILE_END:
        SAVEBIN "Build/FILEX.WMF",START_CODE,PLUGIN_FILE_END-START_CODE
