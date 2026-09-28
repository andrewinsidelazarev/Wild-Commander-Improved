; Codex - 2026-07-17 - begin
; Отдельная сборка runtime расширения перед его HR-упаковкой в boot.$C.
; Адреса ядра создаёт символический проход BOOT.ASM и проверяет генератор.
; Codex - 2026-07-17 - end
; Claude - 2026-09-27 - begin
; Прежде весь модуль стоял внутри DISP #C000; теперь — ORG #C000 без DISP
; (байты те же): резидентный блок расширения собирается для страницы ядра
; своим DISP (#5176), а вложенный DISP sjasmplus не поддерживает.
; Claude - 2026-09-27 - end

        DEVICE ZXSPECTRUM128
        ORG #C000
        INCLUDE "PHYSICAL_MEMORY_MAP.ASM"

        MODULE WDOS
        INCLUDE "../Build/CORE32_WDOS_SYMBOLS.INC"
        ENDMODULE

        MODULE WDOS_EXT
        INCLUDE "CORE32_EXT.ASM"
        ENDMODULE
