; Обвязка теста расчёта разметки: layout.inc отдельно от плагина. Тест
; (test_layout.py) пишет входные переменные, вызывает Run и читает Result:
; 0 — разметка готова, иначе код отказа LAY_*.
        DEVICE ZXSPECTRUM128
        ORG #8000
Run:    CALL Layout
        JR C,.store
        XOR A
.store: LD (Result),A
        HALT
        INCLUDE "../layout.inc"
        INCLUDE "../vars.inc"
Result: DB 0
        SAVEBIN "../build/layout_harness.bin",Run,$-Run
