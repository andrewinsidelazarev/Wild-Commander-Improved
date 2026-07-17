; Codex - 2026-07-17 - begin
; Отдельная сборка runtime расширения перед его HR-упаковкой в boot.$C.
; Адреса ядра создаёт символический проход BOOT.ASM и проверяет генератор.

        DEVICE ZXSPECTRUM128
        ORG 0
        DISP #C000

        MODULE WDOS
        INCLUDE "../Build/CORE32_WDOS_SYMBOLS.INC"
        ENDMODULE

        MODULE WDOS_EXT
        INCLUDE "CORE32_EXT.ASM"
        ENDMODULE

        ENT
; Codex - 2026-07-17 - end
