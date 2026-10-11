; WMF #11: переменный список расширений перед блоками кода.
; Все числа little-endian. Старые форматы #02..#10 остаются без изменений.
; Заголовок по-прежнему 512 байт; +260..+511 — прежняя схема параметров INI.
; Запись метаданных: длина имени (1..255), код обработчика (0..255), имя.
; Имена — ASCII без точки, в верхнем регистре. Количество записей — LE16.
; Блок занимает ceil(bytes/512) секторов сразу после заголовка; затем код.
        IFNDEF WC_WMF_FORMAT_INCLUDED
WC_WMF_FORMAT_INCLUDED EQU 1
WMF_DYNAMIC_VERSION EQU #11
WMF_META_BYTES      EQU 48       ; LE16: значащие байты списка, без добивки
WMF_META_COUNT      EQU 50       ; LE16: число записей, не число обработчиков
WMF_META_PTR        EQU 52       ; LE16: только RAM, загрузчик заменяет нули
WMF_META_FORMAT     EQU 54       ; 1: length, handler, name; остальные — отказ
WMF_META_SCHEMA     EQU 1
WMF_REGISTER        EQU #5300    ; регистрация, включая прежние заголовки
WMF_MATCH           EQU #5303    ; поиск по расширению, A — индекс/код
WMF_SKIP            EQU #5306    ; пропуск метаданных при загрузке через PLM
WMF_ERROR           EQU #5309    ; сообщение об отказе регистрации, A — причина
WMF_NEXT            EQU #530C    ; следующая запись с подходящим Enter/F3
WMF_MENU_FIT        EQU #530F    ; меню Shift+F3: плагин для текущего файла (2026-10-11)
WMF_RUNTIME_BASE    EQU WMF_REGISTER
WMF_RUNTIME_LIMIT   EQU #5AAA    ; ниже распаковщика CORE32
        ASSERT WMF_META_FORMAT < 63, метаданные перекрыли поле Enter/F3
        ENDIF
