; Обвязка теста секторов: все модули плагина без заголовка WMF. Тест
; (test_sectors.py) ставит переменные и вызывает процедуру с адресом возврата
; Stop (HALT).
        DEVICE ZXSPECTRUM128
        ORG #8000
        INCLUDE "../consts.inc"
Stop:   HALT
        INCLUDE "../device.inc"
        INCLUDE "../write.inc"
        INCLUDE "../ui.inc"
        INCLUDE "../layout.inc"
        INCLUDE "../state.inc"
        ASSERT $ <= ID_BUF
        SAVEBIN "../build/sectors_harness.bin",#8000,$-#8000
