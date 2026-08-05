; FILEX.WMF — одностраничный провайдер публичного API 77 Wild Commander.
;
; Первые байты намеренно позиционно независимы: WC сначала выполняет их по
; #8000. Установщик только публикует физическую страницу в состоянии CORE32.
; Затем постоянный шлюз подключает ту же страницу к #C000 и вызывает #C010,
; куда собрана основная реализация.

        DEVICE ZXSPECTRUM128

        MODULE WDOS
        INCLUDE "../../../Build/CORE32_WDOS_SYMBOLS.INC"
        ENDMODULE
        INCLUDE "../../CORE32_FILEX_API.ASM"
        INCLUDE "../../CORE32_EXT_API.ASM"

; Установщик патчит непосредственный операнд LD A,#page внутри резидентного
; шлюза FILEX. Обычные байты состояния #6000..#6010 принадлежат менеджеру
; плагинов и меняются при F10, тогда как код по #6A48 остаётся постоянным.
FILEX_PROVIDER_PAGE_ADDR EQU #6A48

        ORG #0000
START_CODE:
        DS 16,0
        DB "WildCommanderMDL"
        DB #0A
        DB #00
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
        XOR A
        RET
        DS #C010-$,0
        ASSERT $ == #C010, изменился фиксированный вход FILEX

        INCLUDE "FILEX_RUNTIME.ASM"

MAIN_RUNTIME_END:
        ASSERT MAIN_RUNTIME_END-#C000 <= #4000, FILEX вышел за одну страницу
        ENT
PLUGIN_FILE_END:
        SAVEBIN "Build/FILEX.WMF",START_CODE,PLUGIN_FILE_END-START_CODE
