; state.inc — состояние плагина (зануляется при запуске).

; Всё состояние зануляется при каждом запуске.
State:
        INCLUDE "vars.inc"
PanelIX:        DW 0
SavedIFF:       DB 0
SavedPg0:       DB 0
ScratchPg:      DB 0
BootDev:        DB 0                    ; номер DOS_SWP загрузочного устройства, #FF — нет
Dev:            DB 0                    ; выбранное устройство (DOS_SWP)
DevIndex:       DB 0                    ; строка в списке
Touched:        DB 0                    ; запись была — обновить панели
Cylinders:      DW 0
CsdVersion:     DB 0                    ; биты 7-6 CSD карты: 0 — v1 (SDSC), #40 — v2
Model:          DS 40,0
ModelLen:       DB 0
Label:          DS 11,0
LabelLen:       DB 0
Field:          DB 0                    ; 0 — кластер, 1 — метка
SpcIndex:       DB 0                    ; 0 — авто, 1..7 — 512 Б..32 КиБ
LayoutResult:   DB 0                    ; 0 — разметка готова, иначе LAY_*
IoLba:          DD 0
IoCount:        DD 0
Done:           DD 0
Total:          DD 0
Serial:         DD 0
FormatResult:   DB 0                    ; 0 — готово, 1 — отказ записи, 2 — Esc, 3 — сверка
BarPct:         DB 0                    ; нарисованные проценты, #FF — ещё нет
IoEnd:          DD 0
ChsSector:      DB 0                    ; сектор поля CHS (ChsField)
ZeroLeft:       DD 0                    ; секторов обнулить (ZeroRange)
BarDone:        DD 0                    ; рабочие DrawBar
BarTotal:       DD 0
Line:           DS TEXT_W,32
Number:         DS 12,0
StateEnd:
