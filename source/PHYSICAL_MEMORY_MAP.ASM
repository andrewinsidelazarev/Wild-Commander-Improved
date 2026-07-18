; Системный контракт верхних физических страниц Wild Commander.
;
; Все диапазоны заданы полуинтервалами [FIRST, END): END в диапазон не входит.
; Этот файл не порождает байтов и должен подключаться каждым исходником,
; который несистемно использует верхние страницы. Смежность диапазонов и
; положение CORE32_EXT проверяются при сборке, поэтому одностороннее изменение
; границы немедленно завершит сборку ошибкой.

        IFNDEF WC_PHYSICAL_MEMORY_MAP_INCLUDED
WC_PHYSICAL_MEMORY_MAP_INCLUDED EQU 1

; TAP/SNA Mounter: временное хранение TAP/SNA/Z80.
WC_PHYS_TAPSNA_FIRST           EQU #A1
WC_PHYS_TAPSNA_END             EQU #C0

; TR-DOS Mounter: 40 страниц RAM-диска, #C0..#E7.
WC_PHYS_MOUNTER_FIRST          EQU #C0
WC_PHYS_MOUNTER_END            EQU #E8

; Приватные расширения улучшенного ядра: #E8..#EF.
WC_PHYS_IMPROVED_FIRST         EQU #E8
WC_PHYS_IMPROVED_END           EQU #F0
WC_PHYS_CORE32_EXT_PAGE        EQU WC_PHYS_IMPROVED_FIRST

; Штатные страницы Commander и системы: #F0..#FF.
WC_PHYS_COMMANDER_FIRST        EQU #F0
WC_PHYS_COMMANDER_END          EQU #100

        ASSERT WC_PHYS_TAPSNA_FIRST < WC_PHYS_TAPSNA_END, пустой диапазон TAP/SNA
        ASSERT WC_PHYS_TAPSNA_END == WC_PHYS_MOUNTER_FIRST, разрыв карты перед Mounter
        ASSERT WC_PHYS_MOUNTER_FIRST < WC_PHYS_MOUNTER_END, пустой диапазон Mounter
        ASSERT WC_PHYS_MOUNTER_END == WC_PHYS_IMPROVED_FIRST, коллизия Mounter/Improved
        ASSERT WC_PHYS_IMPROVED_FIRST < WC_PHYS_IMPROVED_END, пустой диапазон Improved
        ASSERT WC_PHYS_IMPROVED_END == WC_PHYS_COMMANDER_FIRST, коллизия Improved/Commander
        ASSERT WC_PHYS_COMMANDER_FIRST < WC_PHYS_COMMANDER_END, пустой диапазон Commander
        ASSERT WC_PHYS_COMMANDER_END == #100, верхняя граница карты должна быть #100
        ASSERT WC_PHYS_CORE32_EXT_PAGE >= WC_PHYS_IMPROVED_FIRST, CORE32_EXT ниже своего диапазона
        ASSERT WC_PHYS_CORE32_EXT_PAGE < WC_PHYS_IMPROVED_END, CORE32_EXT пересекает Commander

        ENDIF
