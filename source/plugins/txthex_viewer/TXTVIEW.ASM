; Text & HEX Viewer — KOSHI/MGN, 2024; потоковый просмотрщик Improved, 2026.
; Исходники и комментарии — UTF-8 без BOM. Экран WC использует шрифт CP866.
;
; Память: код, параметры API и строки находятся в постоянном окне #8000.
; #A800..#AFFF — кольцо последних 256 переходов между экранными строками;
; #B000..#BFFF — единственный кэш файла, 4096 байт. Размер файла и все
; смещения — LE32. Никакого завершающего нуля в данных файла не требуется.
; API 77 временно заменяет окно #C000, поэтому кэш туда помещать нельзя.
        ORG 0
        DS 16,0
        DB "WildCommanderMDL",#0E,0
        DB 1,0
        DB 0,(ENDPL-RE+511)/512
        DS 10,0
        DS 15,0
        DB 3                           ; расширения обрабатываются по F3
        DB "TXTWRDINIINFHTMA80ASMDIZNFOBINLOGCFG"
        DS 60,0
        DB 0
        DD #FFFFFFFF                   ; полный диапазон размера FAT32
HeaderName:
        DB "Text&HEX Viewer v0.26"
        DS 32-($-HeaderName)," "
        DB 5                           ; F10 и меню выбора просмотрщика
        DS 6,0
MenuName:
        DB "Text / HEX / UTF-8"
        DS 24-($-MenuName)," "
        DS 512-$,0
        DISP #8000

WLD             EQU #6006
WC_LANG         EQU #781A
WC_ABORT        EQU #6004              ; защёлка Esc, устанавливаемая INT менеджера
CACHE           EQU #B000
CACHE_SIZE      EQU #1000
HISTORY         EQU #A800
HISTORY_COUNT   EQU 256
BINEXT          EQU 9

; RE сохраняет IX панели до любых вызовов API. При F10 файловые BC/DE/HL
; не определены: вместо старого чтения сырого каталога показываем подсказку.
; При обычном запуске копируем имя с ограничением 255 байт и заново делаем
; FENTRY: именно успешный FENTRY создаёт контекст позиционного READ_AT.
RE:
        PUSH IX
        LD (Launch),A
        EX AF,AF'
        LD (Extension),A
        EX AF,AF'
        LD H,B
        LD L,C
        PUSH HL
        LD HL,State
        LD DE,State+1
        LD BC,StateEnd-State-1
        LD (HL),0
        LDIR
        POP HL
        LD A,(Launch)
        CP 3
        JP Z,MenuOnly
        CP 0
        JR Z,.file
        CP 4
        JP NZ,ExitPlain
.file:
        LD DE,FileName+1
        LD B,255
.name:
        LD A,(HL)
        LD (DE),A
        INC HL
        INC DE
        OR A
        JR Z,.named
        DJNZ .name
        LD A,(HL)
        OR A
        JP NZ,OpenFailed
        LD (DE),A
.named:
        LD A,(FileName+1)
        OR A
        JP Z,OpenFailed
        ; GEDPL меняет палитру в #1000 текущей страницы окна #0000.
        ; Сначала выбираем свободную видеостраницу, до первого чтения файла.
        XOR A
        CALL MapVideoZero
        LD A,15
        CALL WLD
        LD HL,FileName
        LD A,59
        CALL WLD
        JP Z,OpenFailed
        LD (FileSize),HL
        LD (FileSize+2),DE
        LD A,62
        CALL WLD
        CALL QueryFilex
        CALL DetectEncoding
        LD A,(IoError)
        OR A
        JP NZ,OpenFailed
        LD A,(Launch)
        OR A
        JR NZ,.chooser
        LD A,(Extension)
        CP BINEXT
        JR NZ,.window
        JR .binary
.chooser:
        LD A,(BinarySample)
        OR A
        JR Z,.window
.binary:
        LD A,1
        LD (HexMode),A
.window:
        ; Часы менеджера рисуются поверх заголовка/подвала. Отключаем только
        ; их таймер на время плагина; WC восстанавливает флаг при возврате.
        LD A,1
        EX AF,AF'
        LD A,86
        CALL WLD
        LD HL,0
        LD (ViewWindow+4),HL
        LD (ViewWindow+8),HL
        LD IX,ViewWindow
        LD A,1
        CALL WLD
        LD A,(IX+4)
        LD (Width),A
        LD A,(IX+5)
        SUB 2
        LD (Rows),A
        CALL GoHome
        CALL DrawPage

; Опрос служебных клавиш предшествует KBSCN: эта функция потребляет скан-код.
; Долгий поиск и восстановление позиции отменяются Esc на границе кэша.
; Сам просмотрщик не вызывает ни одного записывающего файлового API.
MainLoop:
        EI
        HALT
        LD A,23
        CALL WLD
        JP NZ,ExitView
        LD A,16
        CALL WLD
        JP NZ,ExitView
        LD A,21
        CALL WLD
        CALL NZ,ToggleMode
        LD A,36
        CALL WLD
        CALL NZ,NextEncoding
        LD A,29
        CALL WLD
        CALL NZ,ShowHelp
        LD A,17
        CALL WLD
        CALL NZ,GoUp
        LD A,18
        CALL WLD
        CALL NZ,GoDown
        LD A,25
        CALL WLD
        CALL NZ,PageUp
        LD A,26
        CALL WLD
        CALL NZ,PageDown
        LD A,27
        CALL WLD
        JR Z,.not_home
        CALL GoHome
        CALL DrawPage
.not_home:
        LD A,28
        CALL WLD
        CALL NZ,GoEnd
        CALL SearchKey
        JP MainLoop

ExitView:
        LD IX,ViewWindow
        LD A,2
        CALL WLD
ExitPlain:
        POP IX
        XOR A
        RET

MenuOnly:
        XOR A
        CALL MapVideoZero
        LD A,15
        CALL WLD
        LD HL,MenuEnglish
        LD DE,MenuRussian
        CALL SelectLanguage
        CALL MessageBox
        JP ExitPlain
OpenFailed:
        LD HL,ErrorEnglish
        LD DE,ErrorRussian
        CALL SelectLanguage
        CALL MessageBox
        JP ExitPlain

        INCLUDE "STREAM.INC"
        INCLUDE "ENCODING.INC"
        INCLUDE "VIEW.INC"
        INCLUDE "UI.INC"

; Эти два входных байта нельзя помещать в обнуляемое состояние: они
; сохраняются до LDIR, который удаляет следы предыдущего запуска плагина.
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
RowOffsets:     DS 36*4,0
FilexBlock:     DS 32,0
StateEnd:

FileName:       DS 257,0               ; тип файла #00, имя 0..255, ноль
LineBuffer:     DS 90," "
InputBuffer:    DS 40," "
SearchBuffer:   DS 120,0               ; до 40 CP866-символов в UTF-8
InputLength:    EQU 40

        INCLUDE "TABLES.INC"
ENDPL:
        ASSERT ENDPL <= HISTORY       ; код/строки не пересекают историю
        ASSERT HISTORY+256*8 == CACHE
        ASSERT CACHE+CACHE_SIZE == #C000
        ; Заголовок объявляет целые секторы: хвост последнего сектора файла
        ; также хранится явно, а не зависит от остатка свободного места FAT.
        DS ((ENDPL-RE+511)/512)*512-(ENDPL-RE),0
        ENT
