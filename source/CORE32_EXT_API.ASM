; Codex - 2026-07-17 - begin
; Общие номера шлюза страницы расширения WildDOS. Файл включается как в
; конечный runtime, так и в символический проход основной сборки.
ID_STREAM_WITH_HANDLER        EQU 0
ID_READ_SECTORS               EQU 1
ID_STREAM_IO_ERROR            EQU 2
ID_INIT_FREE_SCAN             EQU 3
ID_CHECK_FREE_SCAN_LIMIT      EQU 4
ID_NEXT_FREE_FAT_SECTOR       EQU 5
ID_FAT_SECTOR_IN_RANGE        EQU 6
ID_POSITION_FAT_READ          EQU 7
ID_CLASSIFY_FAT_LINK          EQU 8
ID_FAT_LINK_ERROR             EQU 9
ID_SAVE_FAT_SECTOR            EQU 10
ID_REFINE_NAME_CLASSIFICATION EQU 11
ID_IS_EOC_BEFORE_HL           EQU 12
ID_RESET_DIR_HISTORY          EQU 13
ID_SAVE_PREVIOUS_DIR_LBA      EQU 14
ID_PRESERVE_OLDER_DIR_SECTOR  EQU 15
ID_BEGIN_LFN_COMPARE          EQU 16
ID_COMPARE_LFN_CHAR           EQU 17
ID_DELETE_ENTRY_WITH_LFN      EQU 18
ID_ALLOCATE_FILE              EQU 19
ID_RFRH_SAFE                  EQU 20
ID_RECORD_FAT_LINK_ERROR      EQU 21
ID_LOAD_FAT_CONFIG            EQU 22
ID_VALIDATE_NAME              EQU 23
ID_MAP_OLDER_LFN_POINTER      EQU 24
ID_UNPACK_DRIVER              EQU 25

; Экспериментальный source/DSDZC.ASM исторически использует номера 26..35.
; Диагностическая сборка сохраняет эту ABI и прежние номера следующих строк.
; В боевой сборке эти десять шлюзов отсутствуют, а рабочие строки сдвинуты вниз.
        IFDEF WDOS_EXPERIMENTAL_ZC_RUNTIME
ID_ZC_WAIT_READY              EQU 26
ID_ZC_WAIT_TOKEN              EQU 27
ID_ZC_WAIT_BUSY               EQU 28
ID_ZC_DATA_RESPONSE           EQU 29
ID_ZC_DMA_WAIT                EQU 30
ID_ZC_START_READ              EQU 31
ID_ZC_READ_BLOCK              EQU 32
ID_ZC_WRITE_READY             EQU 33
ID_ZC_START_WRITE             EQU 34
ID_ZC_CHECK_TOKEN             EQU 35
ID_ZERO_CLUSTER_TAIL          EQU 36
ID_COPY_ENTRY_AND_CAPTURE     EQU 37
ID_APPEND_BYTES               EQU 38
ID_COPY_TO_ENTRY              EQU 39
ID_FILEX_CONTEXT_BRIDGE       EQU 40
ID_LOAD_FREE_HINT             EQU 41
ID_NOTE_FREED_CHAIN           EQU 42
ID_SAVE_NEXT_FREE_HINT        EQU 43
ID_GET_DATA_CLUSTER_LIMIT     EQU 44
ID_STREAM_NEXT_CLUSTER        EQU 45
ID_STATUS_TAIL                EQU 46
; Claude - 2026-09-25 - begin
ID_CLOCK_NOW                  EQU 47
ID_CREATE_ENTRY               EQU 48
ID_RENAME                     EQU 49
ID_MKDIR                      EQU 50
ID_DIR_ALIVE                  EQU 51
ID_ENTRY_LANDED               EQU 52
; Claude - 2026-09-25 - end
; Claude - 2026-09-26 - begin
ID_CHECK_STAMP                EQU 53
ID_PLAIN_ALIAS                EQU 54
; Claude - 2026-09-26 - end
; Claude - 2026-09-27 - begin
ID_TREE_CHILD                 EQU 55
ID_STREAM_LINK                EQU 56
ID_DIR_LIST_OPEN              EQU 57
ID_DIR_STREAM_OPEN            EQU 58
ID_FILE_CHAIN                 EQU 59
ID_DIR_GROW                   EQU 60
ID_CLASSIFY_DATA              EQU 61
ID_INSTALL_TAIL               EQU 62
ID_ALIAS_RESET                EQU 63
ID_ALIAS_ADD                  EQU 64
ID_ALIAS_SCAN                 EQU 65
ID_COUNT                      EQU 66
; Claude - 2026-09-27 - end
        ELSE
ID_ZERO_CLUSTER_TAIL          EQU 26
ID_COPY_ENTRY_AND_CAPTURE     EQU 27
ID_APPEND_BYTES               EQU 28
ID_COPY_TO_ENTRY              EQU 29
ID_FILEX_CONTEXT_BRIDGE       EQU 30
ID_LOAD_FREE_HINT             EQU 31
ID_NOTE_FREED_CHAIN           EQU 32
ID_SAVE_NEXT_FREE_HINT        EQU 33
ID_GET_DATA_CLUSTER_LIMIT     EQU 34
ID_STREAM_NEXT_CLUSTER        EQU 35
ID_STATUS_TAIL                EQU 36
; Claude - 2026-09-25 - begin
; Текущие время и дата FAT из часов CMOS с проверкой (та же CLOCK_NOW, что у
; CREATE_ENTRY): HL — время, DE — дата. Нужна FILEX, чтобы ставить время
; изменения при записи и усечении.
ID_CLOCK_NOW                  EQU 37
; Перенос шаблона в ENTRY со временем новой записи — для MKFILE/MKDIR самого
; WC (API 72/73). GENTRY (#4033, ID_COPY_TO_ENTRY) остаётся простым переносом.
ID_CREATE_ENTRY               EQU 38
; RENAME ядра (#4D13) с откатом: прежнюю запись не удалось удалить — удаляется
; только что созданная, чтобы две записи не делили одну цепочку (не удался и
; откат — A=#FF, обе могут остаться); после отказа носителя в SVHDFL новая
; запись ищется (ENTRY_LANDED).
ID_RENAME                     EQU 39
; MKDIR ядра (#403C): тело каталога пишется до записи в родителе, при отказе
; цепочка освобождается (DELCHA; при отказе записи FAT могут остаться
; потерянные кластеры) — каталог с мусором свободного кластера не появляется; отказ
; носителя при записи в родителе разбирается поиском (ENTRY_LANDED).
ID_MKDIR                      EQU 40
; Каталог соседней панели жив ли (DEL_REFRESH/OTHER_REFRESH): кластер занят в
; FAT, начинается записями «.» (на себя) и «..» (два байта имени и бит
; каталога), а родитель из «..» ссылается на него записью каталога — не ушёл
; ли кластер под файл после удаления. Сам родитель (FAT, путь от корня) не
; проверяется: это не проверка целостности тома.
ID_DIR_ALIVE                  EQU 41
; После отказа носителя в SVHDFL: легла ли новая запись — поиск NXTBU (MKFILE
; ядра #4039 через MKFILE_FAIL; в расширении так же RENAME и MKDIR).
ID_ENTRY_LANDED               EQU 42
; Claude - 2026-09-25 - end
; Claude - 2026-09-26 - begin
; Штамп FAT с носителя — для программы (API 58 ядра, FILEX GET/SET_METADATA):
; HL — время, DE — дата. Штампа нет в календаре (месяц, день месяца, часы > 23,
; минуты или секунды > 59) — CF=1, HL=0, DE — 2026-01-01; иначе CF=0, HL и DE
; прежние.
ID_CHECK_STAMP                EQU 43
; Короткое имя без «~n» для имени 8.3, которому длинное нужно лишь ради
; заглавных букв (вход LONG в ENTREZ): Z — взято, NZ — «~n», CF — ошибка чтения.
ID_PLAIN_ALIAS                EQU 44
; Claude - 2026-09-26 - end
; Claude - 2026-09-27 - begin
; Можно ли обходу дерева F5/F8 войти в каталог DE:HL (кластер записи из
; текущего каталога): Z — первый сектор начинается «.» на него и «..» на
; текущий каталог; NZ — запись испорчена или не читается.
ID_TREE_CHILD                 EQU 45
; Переход потока по записи FAT (HL — запись в SECBU): ноль — порча ссылки, иначе
; GIPAG (попадание кэша STREAM_NEXT_CACHED; промах — STREAM_NEXT_CLUSTER).
ID_STREAM_LINK                EQU 46
; NXTINI: проверить цепочку каталога LSTCAT, затем GIPAG; испорчена — CF=1.
ID_DIR_LIST_OPEN              EQU 47
; FNDSN и SVHDFL: проверить цепочку каталога LSTCAT, затем поток на его начало
; (CUHL/CUDE, TOS); испорчена — CF=1.
ID_DIR_STREAM_OPEN            EQU 48
; F5 файла: цепочка файла (A=0; HL → первый кластер, DE → размер, по 4 байта)
; цела на всю длину данных: Z — да, NZ — нет; CF=1, A=1 — проверена очередная
; порция (до 1024 кластеров), продолжить вызовом с A≠0 (между порциями — кадр
; IM2).
ID_FILE_CHAIN                 EQU 49
; SVHDFL (FIIL): места нет — читать дальше (Z), продлить каталог не дальше
; 4096 секторов (NZ, CF=0, кластер — как у SRHFCL) или отказ (NZ, CF=1, A=16
; — полон или нет места, #FF — отказ чтения FAT).
ID_DIR_GROW                   EQU 50
; DLSG ядра (освобождение цепочки): ссылка — как ID_CLASSIFY_FAT_LINK с
; границей тома, и кластер цепочки корня тоже недопустим (таблицу кластеров
; корня DLSG строит в начале, ID_NOTE_FREED_CHAIN).
ID_CLASSIFY_DATA              EQU 51
; Только установщик boot.$C, сразу после распаковки обеих частей расширения:
; упакованные драйверы ядра — в страницу #E8, резидентный блок — на их место.
ID_INSTALL_TAIL               EQU 52
; F8 до удаления (WCINI.DL_ALIAS): пустая таблица кластеров отмеченных. A=0 —
; начало проверки; A≠0 — сброс между заходами (хвост каталога продолжится).
ID_ALIAS_RESET                EQU 53
; Отмеченный объект: DE:HL — первый кластер, A — признак панели (0 — каталог:
; и весь хвост цепочки). CF=1 — таблица полна (сначала ID_ALIAS_SCAN и
; ID_ALIAS_RESET с A≠0, потом этот же объект снова: хвост продолжится); иначе
; Z — внесён, NZ — отказ чтения FAT.
ID_ALIAS_ADD                  EQU 54
; Записи текущего каталога на носителе против таблицы: A=0 — начало, CF=1 и
; A=1 — пройдена порция, звать снова с A≠0; Z — ни одна неотмеченная запись не
; стоит на кластере отмеченного; NZ — стоит, или каталог не читается.
ID_ALIAS_SCAN                 EQU 55
ID_COUNT                      EQU 56
; Claude - 2026-09-27 - end
        ENDIF
; Claude - 2026-09-27 - begin
; Резидентный блок расширения живёт в странице ядра #05 на месте упакованных
; драйверов DR1..DR4 (#5176..#5AA9); драйверы установщик переносит в #E8.
RESIDENT_BASE                 EQU #5176
; Claude - 2026-09-27 - end
; Codex - 2026-07-17 - end
