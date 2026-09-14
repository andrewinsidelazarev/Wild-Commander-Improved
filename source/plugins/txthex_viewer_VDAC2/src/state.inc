Launch:         DB 0
Extension:      DB 0

; Состояние обнуляется при каждом входе. История и кэш могут содержать мусор:
; обращаться к ним разрешено лишь через HistCount/CacheValid соответственно.
State:
FileSize:       DD 0
Position:       DD 0
Top:            DD 0
PageAfter:      DD 0
TextStart:      DD 0
CacheBase:      DD 0
StreamNext:     DD 0
CacheLength:    DW 0
TransferEnd:    DW 0
CacheValid:     DB 0
HaveFilex:      DB 0
IoError:        DB 0
Cancelled:      DB 0
AllowCancel:    DB 0
HexMode:        DB 0
Choice:         DB 0                    ; 0=авто, 1=866, 2=1251, 3=UTF-8
Encoding:       DB 0                    ; 0=866, 1=1251, 2=UTF-8
Detected:       DB 0
HasBom:         DB 0
UtfBad:         DB 0
UtfSeen:        DB 0
BinarySample:   DB 0
UtfFirst:       DB 0
UtfRemaining:   DB 0
Score866:       DW 0
Score1251:      DW 0
Prev866:        DB 0
Prev1251:       DB 0
Width:          DB 0
Rows:           DB 0
DrawY:          DB 0
Column:         DB 0
HistIndex:      DB 0
HistCount:      DW 0
RowBegin:       DD 0
Target:         DD 0
Candidate:      DD 0
SavedTop:       DD 0
SearchStart:    DD 0
SearchLength:   DB 0
SearchAgain:    DB 0
RowsLeft:       DB 0
RowOffsets:     DS SCREEN_ROWS*4,0
ScrollTop:      DD 0
FilexBlock:     DS 32,0
StateEnd:

FileName:       DS 257,0               ; тип файла #00, имя 0..255, ноль
LineBuffer:     DS 90," "
InputBuffer:    DS 40," "
SearchBuffer:   DS 120,0               ; до 40 CP866-символов в UTF-8
InputLength:    EQU 40
