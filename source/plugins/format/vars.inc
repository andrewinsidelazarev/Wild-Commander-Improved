; vars.inc — переменные расчёта разметки (layout.inc) и записи тома.
; 32-битные числа — младший байт первым.

; Устройство (заполняет проверка устройства).
DevKind:        DB 0                    ; KIND_SD/KIND_LBA/KIND_CHS
DevSize:        DD 0                    ; секторов (у CHS — C*H*S)
DevHeads:       DB 0                    ; у CHS — головок и секторов на дорожке
DevSpt:         DB 0
SpcReq:         DB 0                    ; 0 — кластер по таблице, иначе секторов

; Разметка (Layout).
PartStart:      DD 0
PartLength:     DD 0
Spc:            DB 0
Reserved:       DW 0
FatSize:        DD 0
DataStart:      DD 0
Clusters:       DD 0
GeoHeads:       DB 0                    ; геометрия для CHS в MBR и BPB
GeoSpt:         DB 0

; Рабочие.
Align:          DW 0
Tmp2:           DW 0
Work:           DD 0
Work2:          DD 0
