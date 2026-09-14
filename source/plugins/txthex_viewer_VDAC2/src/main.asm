; TXTVIEW2 v0.26 — TXT/HEX для Wild Commander Improved и VDAC2 1024x768.
; Потоковый движок: TXTVIEW v0.26, графический транспорт: Weather VDAC2.
; Комментарии — русский UTF-8; весь интерфейс и помощь — английские.
        INCLUDE "constants.inc"
        ORG 0
        DS 16,0
        DB "WildCommanderMDL",#0E,0
        DB PLUGIN_PAGES,0
        DB 0,(ENDPL-RE+511)/512
        INCLUDE "descriptors.inc"
        DB 0,0
        ASSERT $ <= 63
        DS 63-$,0
        DB 3
        DB "TXTWRDINIINFHTMA80ASMDIZNFOBINLOGCFG"
        DS 60,0
        DB 0
        DD #FFFFFFFF
HeaderName:
        DB "TXT/HEX VDAC2 v0.26"
        DS 32-($-HeaderName)," "
        DB 5
        DS 6,0
MenuName:
        DB "TXT / HEX - VDAC2"
        DS 24-($-MenuName)," "
        DS 512-$,0
        DISP #8000

WLD             EQU #6006
WC_LANG         EQU #781A
WC_ABORT        EQU #6004
CACHE           EQU #B000
CACHE_SIZE      EQU #1000
HISTORY         EQU #A800
HISTORY_COUNT   EQU 256
BINEXT          EQU 9
GRID            EQU #2000
SCREEN_COLUMNS  EQU 78
SCREEN_ROWS     EQU 22
CACHE_ROWS      EQU SCREEN_ROWS+1       ; запасная полоса готовится до CMD_SWAP
; Сверху остаётся только состояние файла: название программы и имя файла
; не занимают отдельные строки. Освободившаяся высота даёт две строки текста;
; шаг 29 сохраняет небольшой зазор у нижнего бара и между высокими диакритиками.
BAR_HEIGHT      EQU 40
HEADER_BOTTOM   EQU BAR_HEIGHT
TEXT_TOP        EQU 52
TEXT_STEP       EQU 29
FOOTER_TOP      EQU 768-BAR_HEIGHT
; Латинские подписи имеют видимый контур в строках 11..30 клетки шрифта.
; Начало клетки совпадает с началом бара: текст оказывается в его середине.
; Старые дополнительные 8/11 пикселей опускали надписи к нижнему разделителю.
BAR_TEXT_Y      EQU 0
        ASSERT TEXT_TOP+(SCREEN_ROWS-1)*TEXT_STEP+34 < FOOTER_TOP

; Файл открывается до FT812: оба устройства используют одну SPI-шину.
; IX панели сохраняем первым действием. Всё состояние, включая графические
; флаги, обнуляем при каждом запуске, так что повторный F3 не зависит от F10.
RE:
        PUSH IX
        LD (Launch),A
        EX AF,AF'
        LD (Extension),A
        EX AF,AF'
        PUSH BC
        LD HL,State
        LD DE,State+1
        LD BC,StateEnd-State-1
        LD (HL),0
        LDIR
        LD HL,GraphicsState
        LD DE,GraphicsState+1
        LD BC,GraphicsStateEnd-GraphicsState-1
        LD (HL),0
        LDIR
        POP HL
        LD A,(Launch)
        CP 3
        JP Z,MenuOnly
        OR A
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
        CALL MapGrid
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
        JR NZ,.sample
        LD A,(Extension)
        CP BINEXT
        JR NZ,.start
        JR .hex
.sample:
        LD A,(BinarySample)
        OR A
        JR Z,.start
.hex:
        LD A,1
        LD (HexMode),A
.start:
        LD A,SCREEN_COLUMNS
        LD (Width),A
        LD A,SCREEN_ROWS
        LD (Rows),A
        LD A,1
        EX AF,AF'
        LD A,86
        CALL WLD
        CALL FT_Boot
        JP C,VideoFailed
        CALL FT_LoadAssets
        JP C,VideoFailed
        LD A,1
        LD (FtReady),A
        CALL GoHome
        CALL DrawPage
        LD A,4
        EX AF,AF'
        LD A,66
        CALL WLD
        LD A,46
        CALL WLD
MainLoop:
        EI
        HALT
        LD A,(FtFault)
        OR A
        JP NZ,VideoFailed
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
        CALL RestoreVideo
ExitPlain:
        POP IX
        XOR A
        RET
RestoreVideo:
        CALL FT_Deselect
        CALL MapGrid                    ; GEDPL портит #1000: только свободная страница!
        XOR A
        LD (FtReady),A
        EX AF,AF'
        LD A,64
        CALL WLD
        LD A,46
        JP WLD
VideoFailed:
        CALL RestoreVideo
        LD HL,VideoError
        CALL MessageBox
        JP ExitPlain
OpenFailed:
        LD HL,OpenError
        CALL MessageBox
        JP ExitPlain
MenuOnly:
        CALL MapGrid
        LD A,15
        CALL WLD
        LD HL,MenuInfo
        CALL MessageBox
        JP ExitPlain

; API переключения окна #0000 может менять IX и альтернативные регистры.
; Всегда сохраняем основные регистры. Кэш страницы здесь намеренно отсутствует:
; WC, FILEX и ISTR тоже могут переключить окно между нашими вызовами.
MapGrid:
        XOR A
        EX AF,AF'
        LD A,80
        JR MapWindow
Data_Page:
        EX AF,AF'
        LD A,78
MapWindow:
        PUSH BC
        PUSH DE
        PUSH HL
        PUSH IX
        CALL WLD
        POP IX
        POP HL
        POP DE
        POP BC
        RET
Saver_Frame:
        EI
        HALT
        RET

        INCLUDE "stream.inc"
        INCLUDE "unicode.inc"
        INCLUDE "detect.inc"
        INCLUDE "view.inc"
        INCLUDE "hex.inc"
        INCLUDE "navigation.inc"
        INCLUDE "ui.inc"
        INCLUDE "search.inc"
        INCLUDE "ft812.asm"
        INCLUDE "screen.inc"
        INCLUDE "state.inc"
        INCLUDE "tables.inc"
        INCLUDE "cp1251.inc"
        INCLUDE "assets.inc"
ENDPL:
        ASSERT ENDPL <= HISTORY
        DS ((ENDPL-RE+511)/512)*512-(ENDPL-RE),0
        ENT
        INCLUDE "pages.inc"
