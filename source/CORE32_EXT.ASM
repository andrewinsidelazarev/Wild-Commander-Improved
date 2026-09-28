; Codex - 2026-07-16 - begin
; Дополнительные исправления WildDOSFileCore.
;
; Этот файл физически хранится в свободной области boot.$C перед CORE32.
; INSTALL_WILDDOS копирует его в выделенную физическую страницу #E8. Короткий
; шлюз WildDOS временно подключает эту страницу к окну #C000, поддерживает
; вложенные вызовы и восстанавливает страницу и состояние прерываний.

RUNTIME_START:
; Codex - 2026-07-17 - begin
        INCLUDE "CORE32_EXT_API.ASM"
; Codex - 2026-07-17 - end

; Каждая внешняя точка занимает ровно JP. Номер после CALL шлюза выбирает
; соответствующую строку без изменения входных регистров функции.
ENTRY_TABLE:
        JP STREAM_WITH_HANDLER
        JP READ_SECTORS
        JP STREAM_IO_ERROR
        JP INIT_FREE_SCAN
        JP CHECK_FREE_SCAN_LIMIT
        JP NEXT_FREE_FAT_SECTOR
        JP FAT_SECTOR_IN_RANGE
        JP POSITION_FAT_READ
        JP CLASSIFY_IN_VOLUME                   ; с 2026-09-27 — с границей тома
        JP FAT_LINK_ERROR
        JP SAVE_FAT_SECTOR
        JP REFINE_NAME_CLASSIFICATION
        JP IS_EOC_BEFORE_HL
        JP RESET_DIR_HISTORY
        JP SAVE_PREVIOUS_DIR_LBA
        JP PRESERVE_OLDER_DIR_SECTOR
        JP BEGIN_LFN_COMPARE
        JP COMPARE_LFN_CHAR
        JP DELETE_ENTRY_WITH_LFN
        JP ALLOCATE_FILE
        JP RFRH_SAFE
        JP RECORD_FAT_LINK_ERROR
        JP LOAD_FAT_CONFIG
; Codex - 2026-07-16 - begin
        JP VALIDATE_NAME
        JP MAP_OLDER_LFN_POINTER
        JP UNPACK_DRIVER
        IFDEF WDOS_EXPERIMENTAL_ZC_RUNTIME
        JP ZC_WAIT_READY
        JP ZC_WAIT_TOKEN
        JP ZC_WAIT_BUSY
        JP ZC_DATA_RESPONSE
        JP ZC_DMA_WAIT
        JP ZC_START_READ
        JP ZC_READ_BLOCK
        JP ZC_WRITE_READY
        JP ZC_START_WRITE
        JP ZC_CHECK_TOKEN
        ENDIF
        JP ZERO_CLUSTER_TAIL
; Codex - 2026-07-17 - begin
        JP COPY_ENTRY_AND_CAPTURE
        JP APPEND_BYTES
        JP COPY_TO_ENTRY
        JP FILEX_CONTEXT_BRIDGE
        JP LOAD_FREE_HINT
        JP NOTE_FREED_CHAIN
        JP SAVE_NEXT_FREE_HINT
        JP GET_DATA_CLUSTER_LIMIT
        JP STREAM_NEXT_CLUSTER
; Codex - 2026-07-17 - end
; Codex - 2026-07-16 - end
; Claude - 2026-09-24 - begin
        JP STATUS_TAIL
; Claude - 2026-09-24 - end
; Claude - 2026-09-25 - begin
        JP CLOCK_NOW
        JP CREATE_ENTRY
        JP RENAME_ENTRY
        JP MKDIR_ENTRY
        JP DIR_ALIVE_ENTRY
        JP ENTRY_LANDED
; Claude - 2026-09-25 - end
; Claude - 2026-09-26 - begin
        JP CHECK_STAMP
        JP PLAIN_ALIAS
; Claude - 2026-09-26 - end
; Claude - 2026-09-27 - begin
        JP TREE_CHILD_ENTRY
        JP STREAM_LINK
        JP DIR_LIST_OPEN
        JP DIR_STREAM_OPEN
        JP FILE_CHAIN
        JP DIR_GROW
        JP CLASSIFY_DATA
        JP EXT_INSTALL_TAIL
        JP ALIAS_RESET
        JP ALIAS_ADD
        JP ALIAS_SCAN
; Claude - 2026-09-27 - end
ENTRY_TABLE_END:
        ASSERT ENTRY_TABLE_END-ENTRY_TABLE == ID_COUNT*3, нарушена таблица шлюза

; Продолжение фиксированного шлюза после подключения страницы #E8.
; IX указывает на сохранённый стековый кадр, L содержит номер функции.
; Кадр: HL'/DE'/BC'/AF', IX, HL/DE/BC/AF, адрес возврата.
GATE_CONTINUE:
; Claude - 2026-09-27 - begin
        ; Вход в шлюз не из расширения (в окне #C000 была не #E8): его страница
        ; и IFF (D кадра: ≠0 — EI на выходе) — внешние для CORE_MKSG и
        ; CORE_SRHFCL: на время поиска места они возвращаются (Codex R29-01).
        ; Вложенный вход их не трогает.
        LD A,(IX-2)
        CP @WC_PHYS_CORE32_EXT_PAGE
        JR Z,.outer_known
        LD (OUTER_PAGE),A
        LD A,(IX-1)
        LD (OUTER_IFF),A
.outer_known:
; Claude - 2026-09-27 - end
        ; Номер функции прочитан до paging, когда байт ещё принадлежал
        ; вызывающей странице. Сам адрес возврата увеличиваем уже здесь:
        ; кадр находится в постоянном окне и переживает вложенные шлюзы.
        INC (IX+18)
        JR NZ,.return_address_ready
        INC (IX+19)
.return_address_ready:
        LD H,0
        LD C,L
        LD B,H
        ADD HL,HL
        ADD HL,BC
        LD BC,ENTRY_TABLE
        ADD HL,BC
        LD BC,GATE_FINISH
        PUSH BC
        PUSH HL

        ; POP читает тот же входной кадр, не меняя его содержимого.
        ; После восстановления всех регистров SP стоит на адресе возврата.
        ; 24 DEC SP возвращают его к подготовленным target/GATE_FINISH;
        ; DEC SP не меняет ни регистры, ни возвращённые входные флаги.
        LD SP,IX
        EXX
        POP HL
        POP DE
        POP BC
        EXX
        EX AF,AF'
        POP AF
        EX AF,AF'
        POP IX
        POP HL
        POP DE
        POP BC
        POP AF
        DUP 24
        DEC SP
        EDUP
        RET

; Перенести оба возвращённых набора и IX поверх уже ненужных входных
; регистров. Всё состояние принадлежит текущему стековому кадру: вложенный
; вызов не может перезаписать указатель или регистры внешнего вызова.
; На входе SP -> page/IFF, затем 18 байт входного кадра и адрес возврата.
; После PUSH новый блок выходов начинается на 18 байт ниже page/IFF.
; Копируем его на 20 байт выше, оставляя само слово page/IFF нетронутым.
; Дополнительная глубина стека этой фазы — 20 байт; IY не используется.
GATE_FINISH:
        PUSH AF,BC,DE,HL,IX
        EX AF,AF'
        EXX
        PUSH AF,BC,DE,HL
        LD HL,17
        ADD HL,SP
        PUSH HL
        LD BC,20
        ADD HL,BC
        EX DE,HL
        POP HL
        LD BC,18
        LDDR
        ; После LDDR DE указывает на второй байт page/IFF.
        EX DE,HL
        DEC HL
        LD SP,HL
        JP @WDOS.EXTENSION_GATE_AFTER

; Перейти по FAT из потокового LOAD512/SAVE512. После отказа CURIT HL
; больше не является указателем на FAT-запись: GIPAG вызывать запрещено.
; Общая ошибка выставляет ABT/EOC и CF, как остальные повреждённые ссылки.
; Claude - 2026-09-21 - begin
; Сюда LOAD512 приходит только при промахе кэша STREAM_NEXT_CACHED. Удачно
; прочитанный CURIT сектор помечается признаком FATTAG текущего поколения FAT:
; следующие переходы в пределах этого сектора обходятся без чтения и шлюзов.
; Claude - 2026-09-21 - end
STREAM_NEXT_CLUSTER:
        CALL @WDOS.CURIT
        JP C,FAT_LINK_ERROR
; Claude - 2026-09-21 - begin
        CALL @WDOS.FAT_CACHE_TAG        ; HL (запись в SECBU) сохраняется
; Claude - 2026-09-21 - end
        JP STREAM_LINK                  ; прежде JP GIPAG: ноль — в корень

; Вызвать общий потоковый код с временным обработчиком DE и восстановить именно
; прежний адрес NW0, а не безусловно RDDSE. Флаги/A/HL результата LOAD512
; сохраняются.
STREAM_WITH_HANDLER:
; Claude - 2026-09-21 - begin
        ; B — число блоков для LOAD512: прежний LD BC,(NW0+1) заменял его
        ; старшим байтом адреса обработчика, и LOADNON/LOAD256 проходили не
        ; B блоков, а ~#51. Прежний обработчик сохраняем через HL (те же 5 байт).
        PUSH HL
        LD HL,(@WDOS.NW0+1)
        EX (SP),HL
; Claude - 2026-09-21 - end
        LD (@WDOS.NW0+1),DE
        CALL @WDOS.LOAD512
        POP DE
        LD (@WDOS.NW0+1),DE
        RET

; Codex - 2026-07-17 - begin
; Скопировать текущую ENTRY вызывающему коду и одновременно сохранить точное
; положение найденной SFN-записи. После XFENTRY указатель записи находится в
; альтернативном BC, а LLHL содержит абсолютный LBA её секторного буфера.
; APPEND дополнительно сверяет все 32 байта на диске перед каждой фиксацией.
COPY_ENTRY_AND_CAPTURE:
; Codex - 2026-07-17 - begin
        ; Исторический TENTRY сохранял Z/S/C входного AF через LDIR. FENTRY
        ; использует этот Z как результат поиска, поэтому служебная проверка
        ; положения записи не должна подменять его собственными флагами.
        PUSH AF
; Codex - 2026-07-17 - end
        PUSH DE
        EXX
        LD (APPEND_FOUND_POINTER),BC
        EXX
        LD HL,(@WDOS.LLHL)
        LD (APPEND_DIRECTORY_LBA),HL
        LD HL,(@WDOS.LLHL+2)
        LD (APPEND_DIRECTORY_LBA+2),HL

        XOR A
        LD (APPEND_VALID),A
        LD (APPEND_READY),A
        LD (APPEND_LBA_VALID),A
        LD BC,(APPEND_FOUND_POINTER)
        CALL ENTRY_OFFSET
        JR C,.copy_saved_entry
        LD (APPEND_DIRECTORY_OFFSET),HL
        LD A,1
        LD (APPEND_VALID),A

.copy_saved_entry:
        LD HL,@WDOS.ENTRY,DE,APPEND_ENTRY,BC,32
        LDIR
; Claude - 2026-09-24 - begin
        ; Поток найденной записи (страница окна #0000), где лежит имя, по
        ; которому её нашли, и само это имя: по ним GENTRY узнает копию —
        ; создание того же имени из того же буфера в другой панели. Имя
        ; копируется целиком: отпечаток «длина и сумма» путал перестановки
        ; (WC_History.txt и CW_History.txt).
        LD A,(#6000)
        LD (FOUND_STREAM),A
        LD HL,(@WDOS.CGDE)
        INC HL                                  ; за типом запроса — имя
        LD (FOUND_NAME),HL
        LD DE,FOUND_TEXT
        LD BC,256
        LDIR                                    ; с запасом: имя до 255 знаков
; Claude - 2026-09-24 - end
        POP DE
        LD HL,@WDOS.ENTRY,BC,32
; Codex - 2026-07-17 - begin
        POP AF
; Codex - 2026-07-17 - end
        LDIR
        RET

; GENTRY (ID_COPY_TO_ENTRY): перенос 32 байт из HL в рабочую ENTRY — ровно
; то, что GENTRY делал всегда. Внешние плагины зовут его напрямую (#4033) и
; ждут простого переноса, поэтому время здесь не ставится.
COPY_TO_ENTRY:
        LD DE,@WDOS.ENTRY
        LD BC,32
        LDIR
        RET

; Перенос шаблона в ENTRY со временем новой записи (ID_CREATE_ENTRY).
;
; Зовёт только обёртка MKFILE/MKDIR коммандера (L6011_238, API 72/73); сама
; она часов не читает: прежний перенос часов L6011_100 брал их без проверки,
; и сбитые часы давали новой записи мусорную дату, — он больше не вызывается.
; Время читается здесь (CLOCK_NOW): у каждого поля проверяются BCD и диапазон, а
; при сбитых часах ставится 2026-01-01 00:00. Сбитыми считаются и часы с годом
; раньше 2026: после севшей батарейки они идут с 2000-го. Шлюз уже запретил прерывания,
; так что обработчик WC, который сам выбирает регистры CMOS для часов в
; шапке, между выбором регистра и чтением не вмешается.
;
; Копия файла или каталога сохраняет время оригинала. Обёртка передаёт в DE
; параметр создания: у MKDIR это [имя,0], у MKFILE — [атрибут][размер 4]
; [имя,0]. Копирование WC (COPYF, DIRCOPY) создаёт объект из того же буфера,
; по которому только что нашло источник, и в другой панели. Если имя нового
; объекта лежит там же, где имя последней найденной записи, не изменилось,
; тип совпадает (MKDIR — каталог, MKFILE — файл), а поток другой, время
; берётся у найденной записи из APPEND_ENTRY. Иначе — часы: так же и при
; пересоздании файла на месте, которое идёт в том же потоке.
; Claude - 2026-09-26 - begin
; Сначала все поля времени ставятся по часам. У копии затем берутся штампы
; оригинала — изменения и создания (с долями секунды, если их не больше 199),
; — каждый, только если он есть в календаре (STAMP_IN_CALENDAR); иначе у копии
; остаётся текущий. Дата доступа копии — всегда текущая: копию только что
; записали.
CREATE_ENTRY:
        PUSH DE
        LD DE,@WDOS.ENTRY,BC,32
        LDIR
        CALL CLOCK_NOW
        LD (@WDOS.ENTRY+14),HL                  ; время создания
        LD (@WDOS.ENTRY+22),HL                  ; время изменения
        LD (@WDOS.ENTRY+16),DE                  ; дата создания
        LD (@WDOS.ENTRY+18),DE                  ; дата доступа
        LD (@WDOS.ENTRY+24),DE                  ; дата изменения
        XOR A
        LD (@WDOS.ENTRY+13),A                   ; доли секунды создания
        POP DE
        LD A,(#6000)
        LD HL,FOUND_STREAM
        CP (HL)
        RET Z                                   ; тот же поток — не копия
        LD HL,(FOUND_NAME)
        OR A
        SBC HL,DE                               ; имя найденного минус параметр
        LD C,#10                                ; MKDIR: [имя,0] — каталог
        JR Z,.named
        LD A,H
        OR A
        RET NZ
        LD A,L
        CP 5
        RET NZ
        LD C,0                                  ; MKFILE: имя за атрибутом и размером — файл
.named:
        LD A,(APPEND_ENTRY+11)
        AND #10
        CP C
        RET NZ                                  ; не тот тип объекта
        LD HL,(FOUND_NAME)
        LD DE,FOUND_TEXT
        LD B,0                                  ; не больше 256 знаков
.name:
        LD A,(DE)
        CP (HL)
        RET NZ                                  ; в буфере уже другое имя
        OR A
        JR Z,.same                              ; совпало до нуля
        INC HL
        INC DE
        DJNZ .name
        RET                                     ; без нуля — не узнаём
.same:
        LD HL,(APPEND_ENTRY+22)
        LD DE,(APPEND_ENTRY+24)
        CALL STAMP_IN_CALENDAR
        JR C,.creation                          ; изменения нет в календаре
        LD (@WDOS.ENTRY+22),HL
        LD (@WDOS.ENTRY+24),DE
.creation:
        LD HL,(APPEND_ENTRY+14)
        LD DE,(APPEND_ENTRY+16)
        CALL STAMP_IN_CALENDAR
        RET C                                   ; создания нет в календаре
        LD (@WDOS.ENTRY+14),HL
        LD (@WDOS.ENTRY+16),DE
        LD A,(APPEND_ENTRY+13)
        CP 200
        RET NC                                  ; долей больше 1,99 с не бывает
        LD (@WDOS.ENTRY+13),A
        RET
; Claude - 2026-09-26 - end

; Claude - 2026-09-25 - begin
; RENAME (ID_RENAME): создать запись с новым именем и удалить прежнюю. Вход:
; HL — [тип, старое имя, 0], DE — новое имя с нулём. Выход: NZ — переименовано;
; Z — нет, A — код для FEEM (окно F6): 8 — прежней записи нет (либо её поиск не
; прочитал каталог, CF=1, как у исходного ядра); код SVHDFL без отказа
; носителя (1–4 — имя, 16 — нет места) — новую не писали; при отказе носителя
; — 0 или #0F («UNKNOWN ERROR!!») либо #FF (исход неизвестен).
; Прежнюю не удалось удалить — только что созданная запись удаляется (#E5),
; цепочка не освобождается: иначе две записи смотрели бы на одну цепочку, и
; удаление любой из них потом освободило бы данные другой. Новая остаётся,
; только если короткая запись прежней, перечитанная с носителя (до трёх
; попыток), помечена удалённой (.recheck), либо если после отказа носителя в
; SVHDFL новая всё же легла на цепочку прежней (.not_created) — тогда прежняя
; удаляется как обычно. A=0 после отката не значит «всё как было»: если
; удаление прежней легло, а её сектор не перечитался, ссылок на цепочку не
; остаётся (потерянные кластеры — лучше общей цепочки), а при частичном
; удалении у прежней уже стёрто длинное имя. #FF — откат не удался или новую
; запись не проверить: на цепочке могут остаться обе записи.
RENAME_ENTRY:
        PUSH HL
        PUSH DE
        CALL @WDOS.SRHDRN
        LD A,8
        LD (@WDOS.FCTS+0),HL
        LD (@WDOS.FCTS+2),DE
        POP HL                                  ; новое имя
        POP DE                                  ; прежний запрос
        RET Z                                   ; прежней записи нет
        CALL RENAME_MARK_OLD                    ; где лежит прежняя SFN (BC — она)
        LD A,(@WDOS.ENTRY+11)
        LD (RENAME_ATTR),A                      ; атрибут целиком — ENTREZ его урежет
        PUSH DE
        CALL @WDOS.SVHDFL                       ; запись с новым именем из ENTRY
        POP HL                                  ; прежний запрос
        JR NZ,.not_created
; Дальше новое имя — только NXTBU: [тип, имя, 0], нормализованный так, как
; его записал SVHDFL (исходный текст может отличаться пробелами и точками).
.created:
        CALL @WDOS.DELEN
        JR Z,.recheck
.done:
        CALL RENAME_KEEP_ATTR                   ; вернуть атрибут новой записи
        XOR A
        INC A
        RET                                     ; NZ — переименовано
; DELEN сообщил отказ. Удалять новую запись можно, только если прежняя на
; месте: если удаление легло на носитель, а драйвер вернул ошибку, откат снёс
; бы последнюю ссылку на цепочку. Но и поиск прежнего имени тут не довод:
; DELETE_ENTRY_WITH_LFN пишет секторы с LFN раньше сектора SFN, и при отказе
; последнего длинное имя уже стёрто, а короткая запись жива — поиск её не
; находит. Поэтому сектор прежней SFN читается заново: новая запись остаётся,
; только если на месте прежней лежит #E5. Не читается или место неизвестно —
; откат: потерянная цепочка лучше двух записей на одной.
.recheck:
        CALL RENAME_OLD_GONE
        JR Z,.done
; Коды для FEEM (окно F6): удачный откат — A=0, «UNKNOWN ERROR!!», как у
; прежнего ядра при отказе DELEN (A=1 от DELEN дал бы «Long Name is not
; valid!»). DELEN при ошибке чтения каталога возвращает A=8 с CF=1 — это не
; «новой нет», а неизвестность: A=#FF.
.undo:
        LD HL,@WDOS.NXTBU
        CALL @WDOS.DELEN                        ; только запись, цепочку не освобождать
        JR C,.lost                              ; каталог не прочитан
        JR NZ,.rolled                           ; новая удалена
        CP 8:JR NZ,.lost                        ; новая не удалена
.rolled:
        XOR A                                   ; Z, A=0 — не переименовано
        RET
.lost:
        LD A,#FF                                ; исход неизвестен: могут остаться обе
.failed:
        CP A                                    ; Z — не переименовано
        RET
; SVHDFL отказал. Без ошибки носителя (ABT=0) — имя занято или недопустимо,
; места нет: новую запись не писали. При ошибке носителя она могла лечь: тогда
; на цепочке уже две записи. Поиск NXTBU: есть с цепочкой прежней — довести
; переименование (удалить прежнюю); нет — не переименовано; неизвестно или
; чужой кластер — не переименовано, A=#FF.
.not_created:
        LD B,A
        LD A,(@WDOS.ABT):OR A
        LD A,B
        JR Z,.failed
        PUSH HL
        CALL ENTRY_LANDED                       ; FCTS — цепочка прежней
        POP HL
        JR C,.lost
        JR NZ,.created
        JR .failed

; Запомнить место короткой записи прежнего имени: сектор (LLHL) и смещение в
; нём (BC — запись в LOBU/LOBU2 после SRHDRN). Неясный BC — место неизвестно.
; HL (новое имя для SVHDFL) и DE сохраняются.
RENAME_MARK_OLD:
        PUSH HL
        CALL .mark
        POP HL
        RET
.mark:
        LD HL,(@WDOS.LLHL)
        LD (RENAME_OLD_LBA),HL
        LD HL,(@WDOS.LLHL+2)
        LD (RENAME_OLD_LBA+2),HL
        CALL ENTRY_OFFSET
        JR NC,.keep
        LD HL,#FFFF                             ; место неизвестно
.keep:
        LD (RENAME_OLD_OFFSET),HL
        RET

; Claude - 2026-09-26 - begin
; Смещение короткой записи в её секторе. Вход: BC — запись в LOBU/LOBU2 (после
; SRHDRN или XFENTRY). Выход: CF=0, HL — смещение 0..511; CF=1 — BC не
; указывает на начало записи в этих буферах. Портит A.
ENTRY_OFFSET:
        LD A,C:AND #1F:JR NZ,.no
        LD A,B:SUB high @WDOS.LOBU:CP 4:JR NC,.no
        AND 1:LD H,A,L,C                        ; AND сбросил CF
        RET
.no:
        SCF
        RET
; Claude - 2026-09-26 - end

; Z — короткая запись прежнего имени на носителе помечена удалённой (#E5).
; NZ — она на месте, её сектор не читается или место неизвестно.
RENAME_OLD_GONE:
        LD A,(RENAME_OLD_OFFSET+1):CP 2:RET NC  ; #FF — место неизвестно, NZ
        LD C,3                                  ; попытки чтения
.read:
        PUSH BC
        LD HL,(RENAME_OLD_LBA),DE,(RENAME_OLD_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        POP BC
        JR Z,.got
        DEC C
        JR NZ,.read
        OR 1                                    ; не читается: NZ
        RET
.got:
        LD HL,@WDOS.LOBU,DE,(RENAME_OLD_OFFSET)
        ADD HL,DE
        LD A,(HL):CP #E5
        RET

; MKDIR (ID_MKDIR, вход ядра #403C): создать каталог. Вход: HL — имя с нулём.
; Выход: Z — создан; NZ — ошибка, A — код (16 — нет места, 1–4 — имя, из них 2
; — исчерпаны суффиксы ~N короткого имени; #FF — отказ носителя, в том числе
; при записи FAT в MKSG: IO_RESULT отдаёт #FF). Прежде
; запись каталога публиковалась в родителе (SVHDFL)
; до записи его первого сектора и обнуления хвоста кластера: отказ записи тела
; оставлял каталог, чьё тело — старые данные свободного кластера (обрывки
; записей удалённых файлов), и последующий обход или F8 мог освободить по ним
; чужие цепочки. Теперь тело пишется первым; при отказе тела цепочка
; освобождается (DELCHA сохраняет код ошибки; отказ самой записи FAT при этом
; не проверяется — тогда могут остаться потерянные кластеры). Отказ
; носителя при записи в родителе неоднозначен (сектор мог лечь) — см. .parent.
MKDIR_ENTRY:
        LD (@WDOS.CGHL),HL
        LD HL,0
        LD (@WDOS.SIZIK),HL
        LD (@WDOS.SIZIK+2),HL
        LD A,#10
        LD (@WDOS.EFLG),A
        LD DE,0
        LD HL,512
        CALL MKSG_CHECKED                       ; отказ чтения FAT — #FF, не 16
        RET NZ
        LD HL,@WDOS.FCTS
        CALL @WDOS.GIPAG                        ; поток — на первый сектор каталога
        LD HL,@WDOS.ENTRY                       ; «.»: сам каталог
        LD (HL),"."
        INC HL
        LD (HL),#20
        INC HL
        LD A,32
        LD B,9
        CALL @WDOS.NOPING+1
        LD HL,(@WDOS.CUHL)
        LD (@WDOS.CLSHL),HL
        LD HL,(@WDOS.CUDE)
        LD (@WDOS.CLSDE),HL
        LD HL,@WDOS.ENTRY
        LD DE,@WDOS.LOBU
        LD BC,32
        LDIR
        LD HL,@WDOS.ENTRY+1                     ; «..»: родитель
        LD (HL),"."
        LD HL,(@WDOS.LSTCAT)
        LD (@WDOS.CLSHL),HL
        LD HL,(@WDOS.LSTCAT+2)
        LD (@WDOS.CLSDE),HL
        LD HL,@WDOS.ENTRY
        LD BC,32
        LDIR
        ; Намеренно обнуляются 513 байт от LOBU+64: исходный ноль и 512 LDIR.
        ; 65 байт заходят в LOBU2, чтобы ZERO_CLUSTER_TAIL получил непрерывный
        ; нулевой сектор от LOBU+64 после записей «.» и «..».
        LD H,D
        LD L,E
        INC DE
        LD BC,512
        LD (HL),0
        LDIR
        LD HL,@WDOS.LOBU
        LD A,1
        CALL @WDOS.SAFE_SDDSE
        JR NZ,.io
        LD A,(@WDOS.BSECPC)
        LD HL,@WDOS.LOBU+64
        CALL ZERO_CLUSTER_TAIL
        JR NZ,.io
        LD HL,(@WDOS.CGHL)                      ; тело на месте — теперь запись
        CALL @WDOS.SVHDFL                       ; в родителе (шаблон — ENTRY)
        JR NZ,.parent
.made:
        XOR A
        RET
.io:
        LD A,#FF                                ; отказ носителя, не имя
.drop:
        OR A                                    ; NZ: код ошибки не ноль, флаги —
        JP @WDOS.DELCHA                         ; от него; DELCHA хранит AF
; SVHDFL отказал. Без ошибки носителя (ABT=0) — это имя или место: в родителе
; ничего не писали, цепочку освободить. При ошибке носителя сектор с записью
; мог лечь, хоть драйвер и вернул отказ: освободить цепочку тогда значило бы
; оставить в родителе каталог на свободном кластере. Имя ищется заново: есть с
; нашим кластером — каталог создан; поиск прошёл и не нашёл — освободить;
; иначе (не читается, имя с чужим кластером) — цепочка остаётся, отказ.
.parent:
        LD B,A
        LD A,(@WDOS.ABT):OR A
        LD A,B
        JR Z,.drop
        CALL ENTRY_LANDED
        JR NC,.known
        LD A,#FF:OR A                           ; неизвестно: цепочку не трогаем
        RET
.known:
        JR NZ,.made                             ; запись легла — каталог создан
        JR .io                                  ; записи нет — освободить

; ENTRY_LANDED (и ID_ENTRY_LANDED для MKFILE ядра): после отказа носителя в
; SVHDFL — легла ли всё же новая запись. Ищется NXTBU — [тип, имя, 0] в том
; виде, в каком SVHDFL его записал (исходный текст «new » дал бы «NEW» и не
; нашёлся бы). Выход: CF=1 — неизвестно (ошибка чтения либо имя с чужим
; кластером); иначе NZ — запись есть и указывает на FCTS, Z — записи нет.
; FCTS (первый кластер для DELCHA) сохраняется.
ENTRY_LANDED:
        LD HL,@WDOS.FCTS,DE,LANDED_CLUSTER,BC,4:LDIR
        LD HL,@WDOS.NXTBU
        CALL @WDOS.SRHDRN
        PUSH AF,HL,DE
        LD HL,LANDED_CLUSTER,DE,@WDOS.FCTS,BC,4:LDIR
        POP DE,HL,AF
        RET C                                   ; ошибка чтения
        RET Z                                   ; записи нет
        LD BC,(LANDED_CLUSTER):OR A:SBC HL,BC:JR NZ,.foreign
        LD HL,(LANDED_CLUSTER+2):SBC HL,DE:JR NZ,.foreign
        LD A,1:OR A                             ; наша запись: NZ, CF=0
        RET
.foreign:
        SCF
        RET

; DIR_ALIVE (ID_DIR_ALIVE): жив ли каталог соседней панели после операции,
; которая могла его удалить (F8, код возврата плагина 3). Занятости кластера
; в FAT мало: удалённый каталог мог уйти под новый файл, и панель писала бы
; записи каталога в его данные. Первый сектор кластера должен начинаться
; записью «.» каталога на этот же кластер, второй — запись «..» каталога, а
; родитель из неё — ссылаться на него живой записью каталога (обход родителя
; — не больше 4096 секторов). У второй записи проверяются только «..» в
; первых двух байтах и бит каталога; занятость родителя в FAT и его
; достижимость от корня — нет: это защита от кластера, ушедшего под файл, а
; не проверка целостности тома. Вход: DE:HL — кластер. Выход: Z — каталог на
; месте; NZ — нет, либо FAT или сектор не читаются, либо предел обхода.
DIR_ALIVE_ENTRY:
        LD (DIR_ALIVE_CLUSTER),HL
        LD (DIR_ALIVE_CLUSTER+2),DE
        CALL @WDOS.CURIT
        JP C,.no
        LD A,(HL):INC HL:OR (HL):INC HL:OR (HL):INC HL:OR (HL)
        JP Z,.no                                ; свободен в FAT
        LD HL,DIR_ALIVE_CLUSTER
        CALL @WDOS.GIPAG
        RET NZ
        LD HL,@WDOS.LOBU,B,1
        CALL @WDOS.LOAD512
        JP C,.no
        LD HL,@WDOS.LOBU
        LD A,(HL):CP ".":RET NZ
        LD B,10
.blank:
        INC HL
        LD A,(HL):CP " ":RET NZ
        DJNZ .blank
        LD HL,@WDOS.LOBU
        CALL .match
        RET NZ                                  ; «.» — не каталог на этот кластер
; «.» цела и тогда, когда кластер уже отдан файлу, ещё не писавшему данных
; (MKFILE выделяет, не трогая содержимого). Поэтому родитель из «..» должен
; ссылаться на каталог живой записью каталога. Вторая запись обязана быть
; «..» каталога — иначе номер родителя не из чего взять.
        LD HL,(@WDOS.LOBU+32),DE,".."
        OR A:SBC HL,DE:JR NZ,.no
        LD A,(@WDOS.LOBU+43):AND #10:JR Z,.no
        LD HL,(@WDOS.LOBU+58),DE,(@WDOS.LOBU+52)
        LD A,H:OR L:OR D:OR E
        JR NZ,.parent
        LD HL,(@WDOS.BROOTC),DE,(@WDOS.BROOTC+2)   ; «..»=0 — корень
.parent:
        LD (DIR_ALIVE_PARENT),HL
        LD (DIR_ALIVE_PARENT+2),DE
        LD HL,DIR_ALIVE_PARENT
        CALL @WDOS.GIPAG
        RET NZ
; Предел обхода: каталог FAT32 — не больше 65536 записей, 4096 секторов по
; 512 байт. Зацикленная цепочка испорченного тома иначе не кончалась бы
; (аудит Codex). Счётчик — в ячейке номера родителя: он уже не нужен. Он
; уменьшается до чтения сектора, поэтому 4097: полный каталог в 4096
; секторов читается целиком.
        LD HL,4097
        LD (DIR_ALIVE_PARENT),HL
.sector:
        LD HL,(DIR_ALIVE_PARENT)
        DEC HL
        LD (DIR_ALIVE_PARENT),HL
        LD A,H:OR L:JR Z,.no
        LD HL,@WDOS.LOBU,B,1
        CALL @WDOS.LOAD512
        JR C,.no
        LD HL,@WDOS.LOBU
.entry:
        LD A,(HL):OR A:JR Z,.no                 ; конец каталога — ссылки нет
        CP #E5:JR Z,.next
        CP ".":JR Z,.next
        CALL .match
        RET Z                                   ; жив: родитель на него ссылается
.next:
        LD DE,32:ADD HL,DE
        LD A,H:CP high (@WDOS.LOBU+512):JR C,.entry
        LD A,(@WDOS.EOC):CP #0F:JR NZ,.sector
.no:
        OR 1
        RET
; Z — запись по HL: каталог на DIR_ALIVE_CLUSTER (LFN и метка бита каталога
; не имеют). HL сохраняется. Зовёт и TREE_CHILD_ENTRY.
.match:
        PUSH HL
        LD DE,11:ADD HL,DE
        BIT 4,(HL):JR Z,.differ
        LD DE,20-11:ADD HL,DE
        LD E,(HL):INC HL:LD D,(HL)
        PUSH HL
        LD HL,(DIR_ALIVE_CLUSTER+2):OR A:SBC HL,DE
        POP HL
        JR NZ,.differ
        LD DE,26-21:ADD HL,DE
        LD E,(HL):INC HL:LD D,(HL)
        LD HL,(DIR_ALIVE_CLUSTER):OR A:SBC HL,DE
        POP HL
        RET
.differ:
        POP HL
        OR 1
        RET

; ENTREZ пишет в байт атрибута новой записи только бит каталога: «только
; чтение», «скрытый», «системный» и «архив» переименованного файла терялись
; (так было и в исходном ядре). Новая запись ищется по NXTBU — имени в том
; виде, в каком его записал SVHDFL; её сектор читается заново, и лишь если по
; вычисленному месту лежат те же 11 байт короткого имени, что нашёл поиск, в
; нём правится один байт атрибута и сектор пишется обратно: соседние записи в
; нём — ровно те, что на диске. Любая неясность — атрибут остаётся урезанным,
; но ничего чужого не трогается. Итог правки не проверяется: переименование
; уже состоялось, и RENAME сообщает NZ, даже если байт атрибута не записан.
RENAME_KEEP_ATTR:
        LD HL,@WDOS.NXTBU                       ; [тип, новое имя, 0] от SVHDFL
        CALL @WDOS.SRHDRN
        RET Z                                   ; новая запись не нашлась
        LD A,(RENAME_ATTR)
        LD HL,@WDOS.ENTRY+11
        CP (HL)
        RET Z                                   ; атрибут и так прежний
        CALL ENTRY_OFFSET                       ; BC — запись в LOBU/LOBU2
        RET C
        LD (RENAME_OFFSET),HL                   ; смещение записи в её секторе
        LD HL,(@WDOS.LLHL),DE,(@WDOS.LLHL+2)
        LD (RENAME_LBA),HL,(RENAME_LBA+2),DE
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        RET NZ
        LD HL,@WDOS.LOBU,DE,(RENAME_OFFSET)
        ADD HL,DE
        PUSH HL
        LD DE,@WDOS.ENTRY,B,11
.same:
        LD A,(DE):CP (HL):JR NZ,.other
        INC DE,HL
        DJNZ .same
        POP HL
        LD DE,11:ADD HL,DE
        LD A,(RENAME_ATTR)
        LD (HL),A
        LD (@WDOS.ENTRY+11),A
        LD HL,(RENAME_LBA),DE,(RENAME_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        JP WRITE_SECTORS
.other:
        POP HL
        RET
; Claude - 2026-09-25 - end

; Текущие время и дата FAT из часов CMOS. Выход: HL — время, DE — дата.
; У каждого поля проверяются BCD и диапазон, у дня — длина месяца
; (STAMP_IN_CALENDAR); сбитые часы или год раньше 2026 — 2026-01-01 00:00.
; Портит A, BC. Прерывания запрещает шлюз.
CLOCK_NOW:
; Два снимка подряд должны совпасть: поля читаются по одному, и если часы
; шагнули посреди чтения (23:59:59 -> 00:00:00 со сменой дня), первый снимок
; смешал бы старую дату с новым временем. Не сошлись — читаем снова.
        LD C,4                                  ; попыток согласованного снимка
.snapshot:
        PUSH BC
        LD DE,RTC_VALUES
        CALL READ_RTC
        JR C,.broken_pop
        LD DE,RTC_CHECK
        CALL READ_RTC
        JR C,.broken_pop
        POP BC
        LD HL,RTC_VALUES
        LD DE,RTC_CHECK
        LD B,6
.same:
        LD A,(DE)
        CP (HL)
        JR NZ,.moved
        INC HL
        INC DE
        DJNZ .same
        JR .stable
.moved:
        DEC C
        JR NZ,.snapshot
        JR CLOCK_BROKEN                         ; так и не встали — считаем сбитыми
.broken_pop:
        POP BC
        JR CLOCK_BROKEN
.stable:
; Дата FAT: (год-1980)<<9 | месяц<<5 | день; год часов считается от 2000.
        LD A,(RTC_VALUES+5)
        ADD A,20
        LD L,A
        LD H,0
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        LD A,(RTC_VALUES+4)
        OR L
        LD L,A
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        LD A,(RTC_VALUES+3)
        OR L
        LD L,A
        EX DE,HL                                ; DE — дата
; Время FAT: часы<<11 | минуты<<5 | секунды/2.
        LD A,(RTC_VALUES+2)
        LD L,A
        LD H,0
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        LD A,(RTC_VALUES+1)
        OR L
        LD L,A
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        LD A,(RTC_VALUES)
        SRL A
        OR L
        LD L,A                                  ; HL — время
; Часы могут отдать и 31.02, и 31.04: день сверяется с длиной месяца той же
; проверкой, что у CHECK_STAMP (провал — 2026-01-01 00:00), — выполнение
; переходит в неё. Время часов уже в пределах, его проверка ничего не меняет.

; Claude - 2026-09-26 - begin
; CHECK_STAMP (ID_CHECK_STAMP): штамп FAT с носителя — для программы. Вход:
; HL — время, DE — дата. Выход: CF=0 — штамп есть в календаре, HL и DE прежние;
; CF=1 — нет (STAMP_IN_CALENDAR): HL=0, DE — 2026-01-01. Портит A, BC. Зовут
; API 58 ядра (NXTETY2) и FILEX.
CHECK_STAMP:
        CALL STAMP_IN_CALENDAR
        RET NC
CLOCK_BROKEN:
        LD HL,0                                 ; 00:00:00
        LD DE,STAMP_FALLBACK_DATE
        RET

STAMP_FALLBACK_DATE EQU (2026-1980)<<9 | 1<<5 | 1

; Есть ли штамп FAT в календаре. Вход: DE — дата, HL — время. Выход: CF=0 —
; есть; CF=1 — нет: месяц не 1..12, день не 1..длина месяца (февраль года,
; кратного 4, — 29 дней; 2100-й тоже считается високосным, до него счёт
; точен), часы больше 23, минуты или секунды больше 59. Год FAT — любой
; (1980..2107). HL и DE сохраняются, портит A, BC.
STAMP_IN_CALENDAR:
        LD A,E
        AND 31
        JR Z,.bad                               ; дня 0 нет
        LD C,A                                  ; день
        LD A,D
        RRA                                     ; CF — старший бит месяца
        LD B,A                                  ; год от 1980: AND сбросил CF
        LD A,E
        RRA
        RRCA
        RRCA
        RRCA
        RRCA
        AND 15                                  ; месяц
        DEC A
        CP 12
        JR NC,.bad                              ; месяцев 0 и 13..15 нет
        CP 1
        JR Z,.february
; Месяц k+1 (k = 0..11) длиной 31 день, если k+[k<7] нечётно: январь, март,
; май, июль, август, октябрь, декабрь; остальные — 30.
        CP 7
        ADC A,0
        AND 1
        ADD A,30
.days:
        CP C
        RET C                                   ; день больше длины месяца
; Время: часы<<11 | минуты<<5 | секунды/2.
        LD A,L
        AND 31
        CP 30
        JR NC,.bad                              ; секунды 60..63
        LD A,H
        CP 24<<3
        JR NC,.bad                              ; часы 24..31
        OR #F8                                  ; CF=0; #FF — минуты от 56
        INC A
        RET NZ
        BIT 7,L
        RET Z                                   ; минуты 56..59
.bad:
        SCF
        RET
.february:
        LD A,B
        AND 3
        LD A,28
        JR NZ,.days
        INC A                                   ; високосный
        JR .days
; Claude - 2026-09-26 - end

; Прочитать шесть полей часов в DE — двоичные значения в порядке RTC_FIELDS —
; с проверкой BCD и диапазонов. Выход: CF=1 — поле испорчено.
READ_RTC:
        LD HL,RTC_FIELDS
.field:
        LD A,(HL)                               ; регистр CMOS
        INC HL
        LD BC,#DFF7
        OUT (C),A
        LD B,#BF
        IN C,(C)                                ; значение в BCD
        LD A,C
        AND #0F
        CP 10
        CCF
        RET C                                   ; единицы — не цифра
        LD B,A
        XOR C                                   ; десятки, сдвинутые на 4
        CP #A0
        CCF
        RET C
        RRCA
        LD C,A                                  ; десятки×8
        RRCA
        RRCA
        ADD A,C                                 ; десятки×10
        ADD A,B
        CP (HL)                                 ; не меньше наименьшего
        INC HL
        RET C
        LD C,A
        LD A,(HL)                               ; и не больше наибольшего
        INC HL
        CP C
        RET C
        LD A,C
        LD (DE),A
        INC DE
        LD A,L
        CP low (RTC_FIELDS+18)
        JR NZ,.field
        OR A                                    ; CF=0 — все поля целы
        RET

; Регистр CMOS, наименьшее и наибольшее значение поля — в порядке RTC_VALUES.
; Claude - 2026-09-25 - begin
; Конец таблицы ловится по младшему байту адреса: она не должна пересекать
; границу 256 байт. Код перед ней растёт — при нужде она сдвигается на начало
; следующей страницы (нули добивки упаковщик почти не замечает).
        IF (low $) > 256-18
        DS 256-(low $),0
        ENDIF
; Claude - 2026-09-25 - end
RTC_FIELDS:
        DB 0,0,59                               ; секунды
        DB 2,0,59                               ; минуты
        DB 4,0,23                               ; часы
        DB 7,1,31                               ; день
        DB 8,1,12                               ; месяц
        DB 9,26,99                              ; год от 2000: раньше 2026 — часы сбиты

; Хвост строки информации под панелью (WCFX.STATUS). Строка шириной во всю
; панель без рамки — 38 знаков, в режиме 90 колонок 43 — лежит в буфере
; коммандера LOBU (#B000, окно #8000), имя уже в +0..+12. Вход: IX — окно
; панели (+4 — его ширина: 40 или 45); Z — каталог; LOBU+44..+47 — время и
; дата элемента списка; размер — в ARRR коммандера. Выход в 38 знаках:
; +13..+22 — размер справа, с пробелом между тысячами, если в нём не больше
; восьми цифр, или «<DIR>»; +24..+31 — ДД.ММ.ГГ; +33..+37 — ЧЧ:ММ. В 43
; знаках размер занимает +13..+25 и разбит на тысячи всегда, дата
; ДД.ММ.ГГГГ — в +27..+36, время — в +38..+42. У записи без времени (нули)
; дата не показывается.
WC_LOBU     EQU #B000                           ; exact-адреса коммандера
WC_ARRR     EQU #7F2C
STATUS_STAMP EQU WC_LOBU+44                     ; время и дата от WCFX.STATUS

STATUS_TAIL:
        PUSH IX
        PUSH AF                                 ; Z — каталог
        LD A,(IX+4)
        SUB 45
        SBC A,A                                 ; #FF — 38 знаков, 0 — 43
        LD (STATUS_NARROW),A
        LD HL,WC_LOBU+13
        LD B,30                                 ; +13..+42
.blank:
        LD (HL)," "
        INC HL
        DJNZ .blank
        POP AF
        JR NZ,.file
        LD HL,DIR_TEXT
        LD DE,WC_LOBU+13
        LD BC,5
        LDIR
        JR .date
.file:
        LD HL,(WC_ARRR)
        LD DE,(WC_ARRR+2)
        LD IX,STATUS_DIGITS                     ; цифры, младшая первой
        LD C,0
.digit:
        PUSH BC
        CALL DIV10
        POP BC
        ADD A,"0"
        LD (IX+0),A
        INC IX
        INC C
        LD A,H
        OR L
        OR D
        OR E
        JR NZ,.digit
        LD E,#FF                                ; с пробелами между тысячами
        LD HL,WC_LOBU+25                        ; последний знак поля размера
        LD A,(STATUS_NARROW)
        OR A
        JR Z,.digits
        LD HL,WC_LOBU+22
        LD A,C
        CP 9
        SBC A,A                                 ; в 38 знаках — до восьми цифр
        LD E,A
.digits:
        LD B,C
        LD D,3
        LD IX,STATUS_DIGITS
.put:
        LD A,(IX+0)
        LD (HL),A
        DEC HL
        INC IX
        DEC B
        JR Z,.date
        DEC D
        JR NZ,.put
        LD D,3
        LD A,E
        OR A
        JR Z,.put
        LD (HL)," "                             ; пробел между тысячами
        DEC HL
        JR .put
.date:
        LD HL,(STATUS_STAMP+2)                  ; дата
        LD A,H
        OR L
        JR Z,.done                              ; у записи нет времени
        LD DE,WC_LOBU+24
        LD A,(STATUS_NARROW)
        OR A
        JR NZ,.day
        LD DE,WC_LOBU+27
.day:
        LD A,L
        AND 31
        CALL TWO_DIGITS                         ; день
        LD A,H
        SRL A
        LD C,A                                  ; год от 1980
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        LD A,H
        AND 15
        CALL DOT_TWO_DIGITS                     ; месяц
        LD A,C
        ADD A,80                                ; год от 1900
        LD C,18
.century:
        INC C
        SUB 100
        JR NC,.century
        ADD A,100
        LD L,A                                  ; год в веке, C — век
        LD A,(STATUS_NARROW)
        OR A
        JR NZ,.short_year
        LD A,C
        CALL DOT_TWO_DIGITS                     ; 43 знака: год целиком
        LD A,L
        CALL TWO_DIGITS
        JR .time
.short_year:
        LD A,L
        CALL DOT_TWO_DIGITS
.time:
        INC DE                                  ; пробел
        LD HL,(STATUS_STAMP)                    ; время
        LD A,H
        RRCA
        RRCA
        RRCA
        AND 31
        CALL TWO_DIGITS                         ; часы
        LD A,":"
        LD (DE),A
        INC DE
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        LD A,H
        AND 63
        CALL TWO_DIGITS                         ; минуты
.done:
        POP IX
        RET

DIR_TEXT    DB "<DIR>"

; DE:HL /= 10, A — остаток. Портит B.
DIV10:
        XOR A
        LD B,32
.bit:
        ADD HL,HL
        RL E
        RL D
        RLA
        CP 10
        JR C,.next
        SUB 10
        INC L
.next:
        DJNZ .bit
        RET

; Точка и две цифры числа A (0..99) — в (DE).
DOT_TWO_DIGITS:
        PUSH AF
        LD A,"."
        LD (DE),A
        INC DE
        POP AF
; Две цифры числа A (0..99) — в (DE). Портит B.
TWO_DIGITS:
        LD B,"0"-1
.tens:
        INC B
        SUB 10
        JR NC,.tens
        ADD A,10+"0"
        PUSH AF
        LD A,B
        LD (DE),A
        INC DE
        POP AF
        LD (DE),A
        INC DE
        RET

; Малый мост между одностраничным FILEX и приватным контекстом FENTRY.
; A=0: экспортировать LBA каталога, смещение и 32-байтовую запись в DE
;      (NZ=успех, Z=нет действительного контекста).
; A=1: инвалидировать контекст.
; A=2: импортировать те же 38 байт из HL после успешной транзакции.
FILEX_CONTEXT_BRIDGE:
        OR A:JR Z,.export
        CP 2:JR Z,.import
.export:
        JR C,.invalidate
        LD A,(APPEND_VALID):OR A:RET Z
        LD HL,APPEND_DIRECTORY_LBA,BC,38
        LDIR
        LD A,1:OR A
        RET
.invalidate:
        XOR A
        LD (APPEND_VALID),A
        LD (APPEND_READY),A
        LD (APPEND_LBA_VALID),A
        RET
.import:
        LD DE,APPEND_DIRECTORY_LBA,BC,38
        LDIR
        XOR A
        LD (APPEND_READY),A
        LD (APPEND_LBA_VALID),A
        INC A
        LD (APPEND_VALID),A
        OR A
        RET

APPEND_ERROR_CONTEXT       EQU #20
APPEND_ERROR_BUFFER        EQU #21
APPEND_ERROR_LENGTH        EQU #22
APPEND_ERROR_ENTRY_CHANGED EQU #23
APPEND_ERROR_SIZE_OVERFLOW EQU #24
APPEND_ERROR_BAD_CHAIN     EQU #25
APPEND_ERROR_IS_DIRECTORY  EQU #26
APPEND_ERROR_INTERNAL      EQU #27
APPEND_ERROR_ROLLBACK      EQU #2A

; Codex - 2026-07-27 - begin
; Дописать в найденный файл от 1 до 16 КиБ. Нулевой BC является успешной
; пустой операцией. Публичный буфер лежит в #4000..#BFFF. Внутренний FILEX
; дополнительно использует сериализованный нулевой scratch #2000..#2FFF;
; #C000 во время операции содержит это расширение.
; Контекст создаётся штатным XFENTRY/TENTRY и кэширует положение EOF, поэтому
; последовательные FTP-блоки не обходят FAT-цепочку заново.
APPEND_BYTES:
        PUSH DE
        LD A,B:OR C:JR NZ,.nonempty
        XOR A
        POP DE
        RET

.nonempty:
        LD (APPEND_SOURCE),HL
        LD A,B:CP #40:JR C,.length_ok
        JP NZ,.bad_length
        LD A,C:OR A:JP NZ,.bad_length
.length_ok:
        LD A,H:CP #20:JP C,.bad_buffer
        CP #C0:JP NC,.bad_buffer
        PUSH HL
        ADD HL,BC
        JP C,.bad_buffer_pop
        LD A,H:CP #C0:JR C,.buffer_end_ok
        JP NZ,.bad_buffer_pop
        LD A,L:OR A:JP NZ,.bad_buffer_pop
.buffer_end_ok:
        POP HL

        LD A,(APPEND_VALID):OR A:JP Z,.bad_context
        LD (APPEND_REMAINING),BC
        LD A,(APPEND_READY):OR A:JR NZ,.context_ready
        CALL APPEND_PREPARE
        JP NZ,.failed_without_rollback
.context_ready:

        LD HL,APPEND_CONTEXT,DE,APPEND_WORK_CONTEXT,BC,APPEND_CONTEXT_SIZE
        LDIR
        LD HL,(APPEND_SIZE),DE,(APPEND_SIZE+2)
        LD BC,(APPEND_REMAINING)
        ADD HL,BC:JR NC,.size_ready
        INC DE
        LD A,D:OR E:JP Z,.size_overflow
.size_ready:
        LD (APPEND_WORK_SIZE),HL
        LD (APPEND_WORK_SIZE+2),DE
        XOR A
        LD (APPEND_PENDING_NEW),A
        LD (APPEND_LINKED_NEW),A
        LD (APPEND_NEW_ACTIVE),A

        ; Вся недостающая цепочка выделяется заранее, но до commit остаётся
        ; отсоединённой от старого хвоста. Поэтому один APPEND может безопасно
        ; пересечь до 32 одно-секторных кластеров, а откату достаточно знать
        ; только голову новой цепочки.
        CALL APPEND_PREALLOCATE
        JP NZ,.failed_with_rollback

.write_loop:
        LD HL,(APPEND_REMAINING)
        LD A,H:OR L:JP Z,.commit
        LD A,(APPEND_WORK_NEEDS_CLUSTER):OR A
        CALL NZ,APPEND_ENSURE_CLUSTER
        JP NZ,.failed_with_rollback

        ; Полные выровненные секторы внутри одного кластера передаются драйверу
        ; одним вызовом. Все штатные драйверы принимают A=число секторов и сами
        ; продвигают HL. На границе кластера следующий проход заново вычислит
        ; LBA, поэтому физически несмежные кластеры не объединяются.
        LD HL,(APPEND_WORK_OFFSET)
        LD A,H:OR L:JR NZ,.single_sector
        LD HL,(APPEND_REMAINING)
        LD A,H:CP 2:JR C,.single_sector

        SRL A
        LD B,A
        LD A,(APPEND_WORK_SECTOR)
        LD C,A
        LD A,(@WDOS.BSECPC)
        SUB C
        CP B
        JR C,.run_ready
        LD A,B
.run_ready:
        LD (APPEND_RUN),A
        CALL APPEND_POSITION_SECTOR
        JP NZ,.failed_with_rollback
        LD HL,(APPEND_SOURCE)
        LD A,(APPEND_RUN)
        CALL WRITE_SECTORS
        JP NZ,.failed_with_rollback
        LD (APPEND_SOURCE),HL

        LD A,(APPEND_RUN)
        ADD A,A
        LD D,A
        LD E,0
        LD HL,(APPEND_REMAINING)
        OR A:SBC HL,DE
        LD (APPEND_REMAINING),HL

        LD A,(APPEND_WORK_SECTOR)
        LD B,A
        LD A,(APPEND_RUN)
        ADD A,B
        LD (APPEND_WORK_SECTOR),A
        LD B,A
        LD A,(@WDOS.BSECPC)
        CP B
        JP NZ,.write_loop
        XOR A
        LD (APPEND_WORK_SECTOR),A
        INC A
        LD (APPEND_WORK_NEEDS_CLUSTER),A
        JP .write_loop

.single_sector:
        CALL APPEND_POSITION_SECTOR
        JP NZ,.failed_with_rollback
        LD HL,(APPEND_WORK_OFFSET)
        LD A,H:OR L:JR Z,.clear_sector
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        JP NZ,.failed_with_rollback
        JR .sector_ready
.clear_sector:
        CALL APPEND_CLEAR_SECTOR
.sector_ready:
        LD HL,512
        LD DE,(APPEND_WORK_OFFSET)
        OR A:SBC HL,DE
        EX DE,HL
        LD HL,(APPEND_REMAINING)
        PUSH HL
        OR A:SBC HL,DE
        POP HL
        JR C,.chunk_ready
        LD H,D,L,E
.chunk_ready:
        LD (APPEND_CHUNK),HL

        LD DE,@WDOS.LOBU
        LD HL,(APPEND_WORK_OFFSET)
        ADD HL,DE
        EX DE,HL
        LD HL,(APPEND_SOURCE)
        LD BC,(APPEND_CHUNK)
        LDIR
        LD (APPEND_SOURCE),HL

        CALL APPEND_POSITION_SECTOR
        JR NZ,.failed_with_rollback
        LD HL,@WDOS.LOBU,A,1
        CALL WRITE_SECTORS
        JR NZ,.failed_with_rollback

        LD HL,(APPEND_REMAINING),DE,(APPEND_CHUNK)
        OR A:SBC HL,DE
        LD (APPEND_REMAINING),HL
        LD HL,(APPEND_WORK_OFFSET)
        ADD HL,DE
        LD (APPEND_WORK_OFFSET),HL
        LD DE,512
        OR A:SBC HL,DE
        JP NZ,.write_loop
        LD (APPEND_WORK_OFFSET),HL
        LD A,(APPEND_WORK_SECTOR):INC A
        LD B,A
        LD A,(@WDOS.BSECPC):CP B
        LD A,B
        JR NZ,.store_sector
        XOR A
        LD (APPEND_WORK_SECTOR),A
        INC A
        LD (APPEND_WORK_NEEDS_CLUSTER),A
        JP .write_loop
.store_sector:
        LD (APPEND_WORK_SECTOR),A
        JP .write_loop

.commit:
        CALL APPEND_COMMIT
        JR NZ,.failed_with_rollback
.committed:
        LD HL,APPEND_WORK_CONTEXT,DE,APPEND_CONTEXT,BC,APPEND_CONTEXT_SIZE
        LDIR
        XOR A
        LD (APPEND_PENDING_NEW),A
        LD (APPEND_LINKED_NEW),A
        LD (APPEND_NEW_ACTIVE),A
        LD HL,(APPEND_SOURCE)
        POP DE
        RET

.failed_with_rollback:
        LD (APPEND_LAST_ERROR),A
; Claude - 2026-09-25 - begin
        ; Отказ самой записи каталога неоднозначен: сектор мог лечь на носитель.
        ; Z — лёг (фиксация состоялась); CF — не прочитать: цепочку не трогать.
        CALL APPEND_DIR_OUTCOME
        JR Z,.committed
        JR C,.restore_original_error
; Claude - 2026-09-25 - end
        CALL APPEND_ROLLBACK
        JR Z,.restore_original_error
        LD A,APPEND_ERROR_ROLLBACK
        JR .return_error
.restore_original_error:
        LD A,(APPEND_LAST_ERROR)
        JR .return_error

.size_overflow:
        LD A,APPEND_ERROR_SIZE_OVERFLOW
.failed_without_rollback:
.return_error:
        OR A
        LD HL,(APPEND_SOURCE)
        POP DE
        RET

.bad_buffer_pop:
        POP HL
.bad_buffer:
        LD A,APPEND_ERROR_BUFFER
        JR .return_error
.bad_length:
        LD A,APPEND_ERROR_LENGTH
        JR .return_error
.bad_context:
        LD A,APPEND_ERROR_CONTEXT
        JR .return_error

; Проверить неизменность каталожной записи и восстановить положение EOF из
; её 32-битного размера. Для первого вызова обходится только существующая
; цепочка; дальнейшие вызовы используют сохранённый текущий кластер.
APPEND_PREPARE:
        CALL APPEND_VERIFY_DIRECTORY
        RET NZ
        LD A,(APPEND_ENTRY+11):BIT 4,A
        LD A,APPEND_ERROR_IS_DIRECTORY
        RET NZ

        LD HL,(APPEND_ENTRY+28),DE,(APPEND_ENTRY+30)
        LD (APPEND_SIZE),HL
        LD (APPEND_SIZE+2),DE
        LD HL,(APPEND_ENTRY+26),DE,(APPEND_ENTRY+20)
        LD A,D:AND #0F:LD D,A
        LD (APPEND_FIRST_CLUSTER),HL
        LD (APPEND_FIRST_CLUSTER+2),DE

        LD BC,(APPEND_SIZE),DE,(APPEND_SIZE+2)
        LD A,B:OR C:OR D:OR E:JR NZ,.nonzero_size
        LD HL,(APPEND_FIRST_CLUSTER),DE,(APPEND_FIRST_CLUSTER+2)
        LD A,D:OR E:OR H:OR L:JR Z,.empty_without_cluster
        CALL CLASSIFY_FAT_LINK
        JP C,.bad_chain
        JP Z,.bad_chain
        LD (APPEND_CURRENT_CLUSTER),HL
        LD (APPEND_CURRENT_CLUSTER+2),DE
        XOR A
        LD (APPEND_SECTOR),A
        LD (APPEND_OFFSET),A
        LD (APPEND_OFFSET+1),A
        LD (APPEND_NEEDS_CLUSTER),A
        JP .ready
.empty_without_cluster:
        XOR A
        LD (APPEND_CURRENT_CLUSTER),A
        LD (APPEND_CURRENT_CLUSTER+1),A
        LD (APPEND_CURRENT_CLUSTER+2),A
        LD (APPEND_CURRENT_CLUSTER+3),A
        LD (APPEND_SECTOR),A
        LD (APPEND_OFFSET),A
        LD (APPEND_OFFSET+1),A
        INC A
        LD (APPEND_NEEDS_CLUSTER),A
        JP .ready

.nonzero_size:
        LD HL,(APPEND_FIRST_CLUSTER),DE,(APPEND_FIRST_CLUSTER+2)
        CALL CLASSIFY_FAT_LINK
        JP C,.bad_chain
        JP Z,.bad_chain
        LD (APPEND_CURRENT_CLUSTER),HL
        LD (APPEND_CURRENT_CLUSTER+2),DE

        LD HL,(APPEND_SIZE)
        LD A,H:AND 1:LD H,A
        LD (APPEND_OFFSET),HL
        LD HL,(APPEND_SIZE),DE,(APPEND_SIZE+2)
        DUP 9
        SRL D:RR E:RR H:RR L
        EDUP
        LD A,(@WDOS.BSECPC):DEC A:AND L
        LD (APPEND_SECTOR),A
        LD A,(@WDOS.BSECPC)
.divide_cluster:
        CP 1:JR Z,.cluster_index_ready
        SRL D:RR E:RR H:RR L
        SRL A
        JR .divide_cluster
.cluster_index_ready:
        XOR A
        LD (APPEND_NEEDS_CLUSTER),A
        LD A,(APPEND_OFFSET):LD B,A
        LD A,(APPEND_OFFSET+1):OR B:JR NZ,.store_skip
        LD A,(APPEND_SECTOR):OR A:JR NZ,.store_skip
        LD A,1
        LD (APPEND_NEEDS_CLUSTER),A
        DEC HL
        ; Заём из high16 нужен только при переходе 0000 -> FFFF.
        LD A,H:AND L:CP #FF:JR NZ,.store_skip
        DEC DE
.store_skip:
        LD (APPEND_SKIP_COUNT),HL
        LD (APPEND_SKIP_COUNT+2),DE

.walk_chain:
        LD HL,(APPEND_SKIP_COUNT),DE,(APPEND_SKIP_COUNT+2)
        LD A,D:OR E:OR H:OR L:JR Z,.ready
        LD HL,(APPEND_CURRENT_CLUSTER),DE,(APPEND_CURRENT_CLUSTER+2)
        CALL APPEND_READ_FAT_LINK
        JR C,.bad_chain
        JR Z,.bad_chain
        LD (APPEND_CURRENT_CLUSTER),HL
        LD (APPEND_CURRENT_CLUSTER+2),DE
        LD HL,(APPEND_SKIP_COUNT),DE,(APPEND_SKIP_COUNT+2)
        DEC HL
        LD A,H:AND L:CP #FF:JR NZ,.skip_stored
        DEC DE
.skip_stored:
        LD (APPEND_SKIP_COUNT),HL
        LD (APPEND_SKIP_COUNT+2),DE
        JR .walk_chain

.ready:
; Codex - 2026-07-28 - begin
        ; Новый FENTRY заново вычислил EOF. Старый LBA мог относиться к другому
        ; файлу, кластеру или геометрии тома и не переносится в новый контекст.
        XOR A
        LD (APPEND_LBA_VALID),A
        INC A
; Codex - 2026-07-28 - end
        LD (APPEND_READY),A
        XOR A
        RET
.bad_chain:
        LD A,APPEND_ERROR_BAD_CHAIN
        OR A
        RET

; Получить следующую ссылку FAT для DE:HL. Обычный кластер возвращается как
; NZ/CF=0, EOC как Z/CF=0, повреждение как CF=1.
APPEND_READ_FAT_LINK:
        CALL @WDOS.CURIT
        RET C
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A
        EX DE,HL
        JP CLASSIFY_FAT_LINK

; Выделить одной операцией всю часть цепочки, которой не хватает для текущего
; вызова. Размер APPEND не превышает 16 КиБ, поэтому если в текущем кластере
; остаётся не менее 33 секторов, места гарантированно достаточно даже при
; ненулевом смещении внутри первого сектора.
APPEND_PREALLOCATE:
        LD A,(APPEND_WORK_NEEDS_CLUSTER):OR A:JR NZ,.allocate_all
        LD HL,(APPEND_WORK_CURRENT),DE,(APPEND_WORK_CURRENT+2)
        LD A,D:OR E:OR H:OR L:JR Z,.allocate_all

        LD A,(APPEND_WORK_SECTOR)
        LD C,A
        LD A,(@WDOS.BSECPC)
        SUB C
        CP 33
        JR NC,.nothing
        ADD A,A
        LD H,A
        LD L,0
        LD DE,(APPEND_WORK_OFFSET)
        OR A:SBC HL,DE
        EX DE,HL
        LD HL,(APPEND_REMAINING)
        OR A:SBC HL,DE
        JR C,.nothing
        JR Z,.nothing
        JR .allocate

.allocate_all:
        LD HL,(APPEND_REMAINING)
.allocate:
        PUSH HL
        LD HL,(APPEND_WORK_CURRENT),DE,(APPEND_WORK_CURRENT+2)
        LD (APPEND_PENDING_OLD_TAIL),HL
        LD (APPEND_PENDING_OLD_TAIL+2),DE
        POP HL
        LD DE,0
        CALL MKSG_CHECKED                       ; отказ чтения FAT — #FF, не 16
        RET NZ

        LD HL,(@WDOS.FCTS),DE,(@WDOS.FCTS+2)
        LD (APPEND_NEW_CLUSTER),HL
        LD (APPEND_NEW_CLUSTER+2),DE
        LD A,1
        LD (APPEND_PENDING_NEW),A

        LD HL,(APPEND_WORK_FIRST),DE,(APPEND_WORK_FIRST+2)
        LD A,D:OR E:OR H:OR L:JR NZ,.nothing
        LD HL,(APPEND_NEW_CLUSTER),DE,(APPEND_NEW_CLUSTER+2)
        LD (APPEND_WORK_FIRST),HL
        LD (APPEND_WORK_FIRST+2),DE
.nothing:
        XOR A
        RET

; При первом переходе через прежний EOF выбрать голову заранее выделенной
; отсоединённой цепочки. Дальше идти только по её уже построенным FAT-ссылкам.
; Прежний хвост проверяется и связывается с этой головой лишь во время commit.
APPEND_ENSURE_CLUSTER:
        LD A,(APPEND_PENDING_NEW):OR A:JR Z,.bad_chain
        LD A,(APPEND_NEW_ACTIVE):OR A:JR NZ,.next_cluster
        LD HL,(APPEND_NEW_CLUSTER),DE,(APPEND_NEW_CLUSTER+2)
        LD (APPEND_WORK_CURRENT),HL
        LD (APPEND_WORK_CURRENT+2),DE
        LD A,1
        LD (APPEND_NEW_ACTIVE),A
        XOR A
        LD (APPEND_WORK_NEEDS_CLUSTER),A
; Codex - 2026-07-28 - begin
        ; Сменили APPEND_WORK_CURRENT на голову новой цепочки: кэш LBA базы
        ; устарел.
        LD (APPEND_WORK_LBA_VALID),A
; Codex - 2026-07-28 - end
        RET

.next_cluster:
        LD HL,(APPEND_WORK_CURRENT),DE,(APPEND_WORK_CURRENT+2)
        CALL APPEND_READ_FAT_LINK
        JR C,.bad_chain
        JR Z,.bad_chain
        LD (APPEND_WORK_CURRENT),HL
        LD (APPEND_WORK_CURRENT+2),DE
        XOR A
        LD (APPEND_WORK_NEEDS_CLUSTER),A
; Codex - 2026-07-28 - begin
        ; Перешли по FAT-ссылке в следующий кластер: кэш LBA базы устарел.
        LD (APPEND_WORK_LBA_VALID),A
; Codex - 2026-07-28 - end
        RET
.bad_chain:
        LD A,APPEND_ERROR_BAD_CHAIN
        OR A
        RET

; Позиционировать драйвер на текущий сектор рабочего EOF.
APPEND_POSITION_SECTOR:
; Codex - 2026-07-17 - begin
        ; GIPAG принимает адрес четырёхбайтового номера кластера, а не сам
        ; номер в DE:HL. Передача значения как указателя давала случайный LBA.
; Codex - 2026-07-17 - end
; Codex - 2026-07-28 - begin
        ; Кэш переносится между успешными APPEND. Перед использованием
        ; проверяются кластер и параметры его отображения в LBA: даже если
        ; вызывающий код сменил том без нового FENTRY, устаревшая база не
        ; попадёт в драйвер.
        CALL APPEND_LBA_CACHE_MATCH
        JR Z,.recompute
        LD HL,(APPEND_WORK_LBA),DE,(APPEND_WORK_LBA+2)
        CALL APPEND_LBA_CACHE_RESTORE_STATE
        JR .add_sector
.recompute:
        LD HL,APPEND_WORK_CURRENT
        CALL @WDOS.GIPAG
        RET NZ
        LD HL,(@WDOS.LTHL),DE,(@WDOS.LTDE)
        LD (APPEND_WORK_LBA),HL
        LD (APPEND_WORK_LBA+2),DE
        CALL APPEND_LBA_CACHE_TAG
        LD A,1
        LD (APPEND_WORK_LBA_VALID),A
.add_sector:
; Codex - 2026-07-28 - end
        LD A,(APPEND_WORK_SECTOR)
        ADD A,L:LD L,A:JR NC,.position
        INC H:JR NZ,.position
        INC DE
.position:
        CALL @WDOS.PROZ
        XOR A
        RET

; Вернуть NZ, только если сохранённая база принадлежит текущему кластеру и
; текущей геометрии FAT. APPEND_ENSURE_CLUSTER также явно сбрасывает VALID,
; но полная сверка делает ошибку инвалидизации безопасным промахом кэша.
APPEND_LBA_CACHE_MATCH:
        LD A,(APPEND_WORK_LBA_VALID):OR A:JR Z,.miss

        LD HL,(APPEND_WORK_CURRENT),DE,(APPEND_WORK_LBA_CLUSTER)
        OR A:SBC HL,DE:JR NZ,.miss
        LD HL,(APPEND_WORK_CURRENT+2),DE,(APPEND_WORK_LBA_CLUSTER+2)
        OR A:SBC HL,DE:JR NZ,.miss

        LD A,(@WDOS.BSECPC)
        LD B,A
        LD A,(APPEND_WORK_LBA_BSECPC)
        CP B:JR NZ,.miss

        LD HL,(@WDOS.SDFAT),DE,(APPEND_WORK_LBA_SDFAT)
        OR A:SBC HL,DE:JR NZ,.miss
        LD HL,(@WDOS.SDFAT+2),DE,(APPEND_WORK_LBA_SDFAT+2)
        OR A:SBC HL,DE:JR NZ,.miss

        LD HL,(@WDOS.ADDTOP),DE,(APPEND_WORK_LBA_ADDTOP)
        OR A:SBC HL,DE:JR NZ,.miss
        LD HL,(@WDOS.ADDTOP+2),DE,(APPEND_WORK_LBA_ADDTOP+2)
        OR A:SBC HL,DE:JR NZ,.miss

        LD A,1
        OR A
        RET
.miss:
        XOR A
        RET

; Привязать уже сохранённый APPEND_WORK_LBA к текущему кластеру и геометрии.
APPEND_LBA_CACHE_TAG:
        PUSH HL,DE
        LD HL,(APPEND_WORK_CURRENT),DE,(APPEND_WORK_CURRENT+2)
        LD (APPEND_WORK_LBA_CLUSTER),HL
        LD (APPEND_WORK_LBA_CLUSTER+2),DE
        LD A,(@WDOS.BSECPC)
        LD (APPEND_WORK_LBA_BSECPC),A
        LD HL,(@WDOS.SDFAT),DE,(@WDOS.SDFAT+2)
        LD (APPEND_WORK_LBA_SDFAT),HL
        LD (APPEND_WORK_LBA_SDFAT+2),DE
        LD HL,(@WDOS.ADDTOP),DE,(@WDOS.ADDTOP+2)
        LD (APPEND_WORK_LBA_ADDTOP),HL
        LD (APPEND_WORK_LBA_ADDTOP+2),DE
        POP DE,HL
        RET

; GIPAG не только вычисляет LBA. Потоковый LOAD/SAVE затем полагается на
; сброшенные NSDC/EOC, текущий CUHL/CUDE и базовый LBA в CL*/LT*. Попадание
; кэша обязано воспроизвести это состояние; одного PROZ недостаточно.
; Вход/выход: DE:HL — кэшированный абсолютный LBA начала кластера.
APPEND_LBA_CACHE_RESTORE_STATE:
        LD (@WDOS.LTHL),HL
        LD (@WDOS.LTDE),DE
        LD (@WDOS.CLHL),HL
        LD (@WDOS.CLDE),DE
        LD HL,(APPEND_WORK_CURRENT),DE,(APPEND_WORK_CURRENT+2)
        LD (@WDOS.CUHL),HL
        LD (@WDOS.CUDE),DE
        XOR A
        LD (@WDOS.NSDC),A
        LD (@WDOS.EOC),A
        LD HL,(@WDOS.LTHL),DE,(@WDOS.LTDE)
        RET

APPEND_CLEAR_SECTOR:
        LD HL,@WDOS.LOBU,DE,@WDOS.LOBU+1,BC,511
        XOR A
        LD (HL),A
        LDIR
        RET

; Зафиксировать новую цепочку, FSInfo и лишь затем 32-битный размер каталога.
; До последней записи добавленные байты остаются за старым логическим EOF.
APPEND_COMMIT:
; Claude - 2026-09-25 - begin
        XOR A:LD (APPEND_DIR_ATTEMPTED),A      ; запись каталога ещё не начата
; Claude - 2026-09-25 - end
        LD A,(APPEND_PENDING_NEW):OR A:JR Z,.directory
        LD HL,(APPEND_PENDING_OLD_TAIL),DE,(APPEND_PENDING_OLD_TAIL+2)
        LD A,D:OR E:OR H:OR L:JR Z,.fsinfo
        CALL APPEND_LINK_NEW_CLUSTER
        RET NZ
.fsinfo:
        CALL RFRH_SAFE
        RET NZ
.directory:
        JP APPEND_UPDATE_DIRECTORY

APPEND_LINK_NEW_CLUSTER:
        LD HL,(APPEND_PENDING_OLD_TAIL),DE,(APPEND_PENDING_OLD_TAIL+2)
        CALL @WDOS.CURIT
        JR C,.bad_chain
        LD (APPEND_FAT_POINTER),HL
        LD DE,APPEND_OLD_LINK,BC,4
        LDIR
        LD HL,(APPEND_OLD_LINK),DE,(APPEND_OLD_LINK+2)
        CALL CLASSIFY_FAT_LINK
        JR C,.bad_chain
        JR NZ,.bad_chain

        LD HL,(APPEND_FAT_POINTER)
        LD DE,APPEND_NEW_CLUSTER
        LD A,(DE):LD (HL),A:INC DE,HL
        LD A,(DE):LD (HL),A:INC DE,HL
        LD A,(DE):LD (HL),A:INC DE,HL
        LD A,(HL):AND #F0:LD B,A
        LD A,(DE):AND #0F:OR B:LD (HL),A
        ; После начала записи FAT результат носителя может быть неоднозначным.
        ; Откат должен восстановить старую EOC-ссылку и когда драйвер вернул
        ; ошибку: повторная запись прежнего значения безопаснее оставленной
        ; ссылки на цепочку, которую затем освободит DLSG.
        LD A,1
        LD (APPEND_LINKED_NEW),A
        CALL SAVE_FAT_SECTOR
        RET NZ
        XOR A
        RET
.bad_chain:
        LD A,APPEND_ERROR_BAD_CHAIN
        OR A
        RET

; Прочитать и полностью сверить исходную SFN-запись. Это защищает от записи
; размера не в тот слот после любого постороннего FENTRY или изменения каталога.
APPEND_VERIFY_DIRECTORY:
        LD HL,(APPEND_DIRECTORY_LBA),DE,(APPEND_DIRECTORY_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        RET NZ
        LD HL,@WDOS.LOBU,DE,(APPEND_DIRECTORY_OFFSET)
        ADD HL,DE
        LD (APPEND_SLOT_POINTER),HL
        LD DE,APPEND_ENTRY,BC,32
.compare:
        LD A,(DE):CP (HL):JR NZ,.changed
        INC DE,HL
        DEC BC
        LD A,B:OR C:JR NZ,.compare
        LD HL,(APPEND_SLOT_POINTER)
        XOR A
        RET
.changed:
        LD A,APPEND_ERROR_ENTRY_CHANGED
        OR A
        RET

APPEND_UPDATE_DIRECTORY:
        CALL APPEND_VERIFY_DIRECTORY
        RET NZ
        LD (APPEND_SLOT_POINTER),HL
        LD DE,20:ADD HL,DE
        LD DE,(APPEND_WORK_FIRST+2)
        LD (HL),E:INC HL:LD A,D:AND #0F:LD (HL),A
        LD HL,(APPEND_SLOT_POINTER),DE,26
        ADD HL,DE
        LD DE,(APPEND_WORK_FIRST)
        LD (HL),E:INC HL:LD (HL),D
        LD HL,(APPEND_SLOT_POINTER),DE,28
        ADD HL,DE
        LD DE,(APPEND_WORK_SIZE)
        LD (HL),E:INC HL:LD (HL),D:INC HL
        LD DE,(APPEND_WORK_SIZE+2)
        LD (HL),E:INC HL:LD (HL),D
; Claude - 2026-09-24 - begin
        ; Дозапись меняет файл: время и дата изменения и дата доступа — по часам.
        CALL CLOCK_NOW
        PUSH DE                                 ; дата
        EX DE,HL                                ; DE — время
        LD HL,(APPEND_SLOT_POINTER),BC,22
        ADD HL,BC
        LD (HL),E:INC HL:LD (HL),D:INC HL       ; +22 время изменения
        POP DE
        LD (HL),E:INC HL:LD (HL),D              ; +24 дата изменения
        LD HL,(APPEND_SLOT_POINTER),BC,18
        ADD HL,BC
        LD (HL),E:INC HL:LD (HL),D              ; +18 дата доступа
; Claude - 2026-09-24 - end

; Claude - 2026-09-25 - begin
        ; Новая запись — на случай неоднозначного отказа записи (APPEND_DIR_OUTCOME).
        LD HL,(APPEND_SLOT_POINTER),DE,APPEND_NEW_ENTRY,BC,32
        LDIR
        LD A,1:LD (APPEND_DIR_ATTEMPTED),A
; Claude - 2026-09-25 - end
        LD HL,(APPEND_DIRECTORY_LBA),DE,(APPEND_DIRECTORY_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL WRITE_SECTORS
        RET NZ
APPEND_ENTRY_COMMITTED:
        XOR A:LD (APPEND_DIR_ATTEMPTED),A
        LD HL,APPEND_NEW_ENTRY,DE,APPEND_ENTRY,BC,32
        LDIR
        LD HL,APPEND_ENTRY,DE,@WDOS.ENTRY,BC,32
        LDIR
        XOR A
        RET

; Claude - 2026-09-25 - begin
; Исход отказа фиксации APPEND. Если отказала запись сектора каталога, он мог
; всё же лечь на носитель: тогда откат отцепил бы и освободил новую цепочку,
; а запись уже показывает новый размер (у файла, пустого до дозаписи, первый
; кластер — свободный). Сектор перечитывается. Выход: Z — на носителе новая
; запись, фиксация состоялась; NZ, CF=0 — прежняя запись либо отказ был до
; записи каталога: обычный откат; NZ, CF=1 — не прочитать или ни та ни другая:
; цепочку не трогать (хвост цепочки длиннее размера лучше ссылки на свободный
; кластер).
APPEND_DIR_OUTCOME:
        LD A,(APPEND_DIR_ATTEMPTED):OR A:JR Z,.old
        XOR A:LD (APPEND_DIR_ATTEMPTED),A
        LD HL,(APPEND_DIRECTORY_LBA),DE,(APPEND_DIRECTORY_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        JR NZ,.unknown
        LD HL,@WDOS.LOBU,DE,(APPEND_DIRECTORY_OFFSET)
        ADD HL,DE
        PUSH HL
        LD DE,APPEND_NEW_ENTRY
        CALL .same
        POP HL
        JP Z,APPEND_ENTRY_COMMITTED             ; легла новая запись
        LD DE,APPEND_ENTRY
        CALL .same
        JR Z,.old                               ; на носителе прежняя
.unknown:
        LD A,1:OR A
        SCF
        RET
.old:
        LD A,1:OR A                             ; NZ, CF=0 — откат
        RET
.same:                                          ; Z — 32 байта HL и DE равны
        LD B,32
.byte:
        LD A,(DE):CP (HL):RET NZ
        INC HL:INC DE
        DJNZ .byte
        RET
; Claude - 2026-09-25 - end

; При ошибке до обновления каталожной записи восстановить EOC старого хвоста
; и освободить отдельно выделенную цепочку. Ошибка самого отката имеет
; отдельный код, чтобы FTP-сервер не повторял операцию вслепую.
APPEND_ROLLBACK:
        LD A,(APPEND_PENDING_NEW):OR A:RET Z
        LD A,(APPEND_LINKED_NEW):OR A:JR Z,.release_new
        LD HL,(APPEND_PENDING_OLD_TAIL),DE,(APPEND_PENDING_OLD_TAIL+2)
        CALL @WDOS.CURIT
        RET C
        EX DE,HL
        LD HL,APPEND_OLD_LINK,BC,4
        LDIR
        CALL SAVE_FAT_SECTOR
        RET NZ
.release_new:
        XOR A
        LD (@WDOS.ABT),A
        LD HL,APPEND_NEW_CLUSTER
        CALL @WDOS.DLSG
        LD A,(@WDOS.ABT):OR A:RET NZ
        CALL RFRH_SAFE
        RET NZ
        XOR A
        LD (APPEND_PENDING_NEW),A
        LD (APPEND_LINKED_NEW),A
        LD (APPEND_NEW_ACTIVE),A
        RET
; Codex - 2026-07-27 - end
; Codex - 2026-07-17 - end

; Вызвать драйвер чтения/записи с единым признаком результата в ABT.
; Старые драйверы ABT не меняют и считаются успешными; исправленные драйверы
; записывают туда ненулевой код ошибки. На выходе ошибка даёт NZ, CF=1 и
; A=#FF (с 2026-09-26): прежде A был сырым кодом драйвера, и отказ записи FAT
; в MKSG доходил до окна F7/F5 как код имени 1 — «Long Name is not valid!».
READ_SECTORS:
        PUSH AF
        XOR A:LD (@WDOS.ABT),A
        POP AF
        CALL @WDOS.RDDSE
        JR IO_RESULT

WRITE_SECTORS:
        PUSH AF
        XOR A:LD (@WDOS.ABT),A
        POP AF
        CALL @WDOS.SDDSE

IO_RESULT:
        LD A,(@WDOS.ABT)
        OR A:RET Z
        LD A,#FF                                ; отказ носителя, NZ уже стоит
        SCF
        RET

; Записать нулевым буфером оставшиеся после первого секторы кластера.
; Вход: A — полное число секторов в кластере, HL — 512-байтовый нулевой
; буфер. LTHL:LTDE указывает на первый сектор. Каждый следующий LBA вычисляется
; отдельно; первая ошибка немедленно возвращается как NZ/CF=1.
ZERO_CLUSTER_TAIL:
        LD (ZERO_CLUSTER_BUFFER_LOAD+1),HL
ZERO_CLUSTER_TAIL_NEXT:
        DEC A
        RET Z
        PUSH AF
        LD HL,(@WDOS.LTHL),DE,(@WDOS.LTDE)
        INC HL
        LD A,H:OR L:JR NZ,.lba_ready
        INC DE
.lba_ready:
        CALL @WDOS.XPOZI
ZERO_CLUSTER_BUFFER_LOAD:
        LD HL,0
        LD A,1
        CALL WRITE_SECTORS
        POP BC
        RET NZ
        LD A,B
        JR ZERO_CLUSTER_TAIL_NEXT

; Нормализовать и классифицировать значение FAT32 в DE:HL.
; Старшие четыре служебных бита отбрасываются. Обычный кластер возвращает
; NZ/CF=0, EOC #0FFFFFF8..#0FFFFFFF — Z/CF=0, недопустимые 0, 1,
; #0FFFFFF0..#0FFFFFF7 — NZ/CF=1.
CLASSIFY_FAT_LINK:
        LD A,D:AND #0F:LD D,A
        OR E:OR H
        JR NZ,CLASSIFY_HIGH

CLASSIFY_LOW:
        LD A,L:CP 2:JR C,CLASSIFY_INVALID
        JR CLASSIFY_ORDINARY
CLASSIFY_HIGH:
        LD A,D:CP #0F:JR NZ,CLASSIFY_ORDINARY
        LD A,E:CP #FF:JR NZ,CLASSIFY_ORDINARY
        LD A,H:CP #FF:JR NZ,CLASSIFY_ORDINARY
        LD A,L:CP #F0:JR C,CLASSIFY_ORDINARY
        CP #F8:JR C,CLASSIFY_INVALID
        XOR A
        RET
CLASSIFY_ORDINARY:
; Codex - 2026-07-16 - begin
        ; Тот же A=1, NZ и сброшенный CF одним байтом короче. Освобождённый
        ; байт сохраняет точный физический размер после нормализации EOC.
        XOR A:INC A
; Codex - 2026-07-16 - end
        RET
; Claude - 2026-09-27 - begin
; CLASSIFY_DATA (ID_CLASSIFY_DATA — DLSG ядра; FILE_CHAIN): CLASSIFY_IN_VOLUME,
; и кластер цепочки корня недопустим. В цепочке файла и в освобождаемой
; цепочке его быть не может, а испорченная запись файла на кластере корня
; прежде проходила: F8 освобождал корень — том терял все имена, F5 копировал
; сектор корня (Codex R28-01). С 2026-09-27 — любой кластер корня, не только
; первый (Codex R27-04): таблицу строит ROOT_BUILD в начале DLSG
; (NOTE_FREED_CHAIN) и FILE_CHAIN. Прочие кластеры чужих цепочек так не
; ловятся (docs/01, 7.1). Выход — как у CLASSIFY_FAT_LINK; HL, DE сохраняются.
CLASSIFY_DATA:
        CALL CLASSIFY_IN_VOLUME
        RET C                                   ; недопустимая
        RET Z                                   ; EOC
        CALL ROOT_MEMBER                        ; Z — кластер корня (0 уже отвергнут)
        JR NZ,CLASSIFY_ORDINARY
; Claude - 2026-09-27 - end
CLASSIFY_INVALID:
        LD A,1:OR A
        SCF
        RET

; Claude - 2026-09-27 - begin
; DIR_CHAIN: цепочка каталога DE:HL (0 — корень, BROOTC) конечна и в томе:
; первый кластер — обычный, ссылки допустимы (0 — свободный кластер,
; недопустимые, за областью данных — порча), конец (EOC) — не дальше 4096
; секторов (каталог FAT32 — не больше 65536 записей; больше — цикл). Z —
; цела; NZ — нет, в том числе при отказе чтения FAT. Сектор FAT читается,
; только когда сменился: каталогу в одном секторе FAT — одно чтение (первое
; — всегда, SECBU до обхода мог быть чужим). Зовут NXTINI (DIR_LIST_OPEN),
; FNDSN и SVHDFL (DIR_STREAM_OPEN), TREE_CHILD: замкнутая цепочка каталога
; вешала панель, поиск и создание (Codex R26-02). У подкаталога в цепочке нет
; кластеров корня (ROOT_BUILD, с 2026-09-27): хвост, ушедший в корень, вёл
; F8 дерева по именам корня (Codex R27-04). Разрушает AF, BC, DE, HL.
DIR_CHAIN:
        LD A,H:OR L:OR D:OR E
        JR NZ,.first
        LD HL,(@WDOS.BROOTC),DE,(@WDOS.BROOTC+2)
.first:
        CALL CLASSIFY_IN_VOLUME
        JR C,.bad
        JR Z,.bad                               ; маркер конца вместо кластера
        LD BC,4096
        LD (DIR_CHAIN_LEFT),BC
        XOR A:LD (DIR_CHAIN_READ),A
        LD (DIR_CHAIN_SUB),A
        CALL TREE_CHILD_ENTRY.root              ; Z — сам корень: сверять не с чем
        JR Z,.link
        PUSH HL
        PUSH DE
        CALL ROOT_BUILD                         ; сектор FAT корня — в SECBU
        POP DE
        POP HL
        JR C,.bad
        LD A,1:LD (DIR_CHAIN_SUB),A
.link:
        LD A,(DIR_CHAIN_SUB):OR A
        JR Z,.own
        CALL ROOT_MEMBER
        JR Z,.bad                               ; кластер корня в цепочке подкаталога
.own:
        PUSH HL
        LD HL,(DIR_CHAIN_LEFT)
        LD A,(@WDOS.BSECPC):LD C,A:LD B,0
        OR A:SBC HL,BC
        LD (DIR_CHAIN_LEFT),HL
        POP HL
        JR C,.bad                               ; длиннее 4096 секторов — цикл
        CALL CHAIN_VALUE                        ; DE:HL — ссылка
        JR C,.bad
        CALL CLASSIFY_IN_VOLUME
        JR C,.bad                               ; свободный, недопустимый, за томом
        JR NZ,.link
        RET                                     ; конец цепочки: Z
.bad:
        OR 1
        RET

; CHAIN_VALUE: значение записи FAT кластера DE:HL (DIR_CHAIN, FILE_CHAIN).
; Сектор FAT читается CURIT в первый раз и затем, только когда сменился
; (DIR_CHAIN_READ; SECBU до обхода мог быть чужим). Выход: DE:HL —
; значение, CF=0; CF=1 — отказ чтения. Разрушает AF, BC.
CHAIN_VALUE:
        LD A,(DIR_CHAIN_READ):OR A
        JR Z,.read
        PUSH DE
        PUSH HL
        CALL @WDOS.STREAM_CACHE_SECTOR          ; Z — тот же сектор FAT, A — запись
        POP HL
        POP DE
        JR NZ,.read
        LD L,A:LD H,@WDOS.SECBU/1024
        ADD HL,HL:ADD HL,HL                     ; её адрес в SECBU
        JR .value
.read:
        CALL @WDOS.CURIT                        ; HL — запись FAT кластера
        RET C
        LD A,1:LD (DIR_CHAIN_READ),A
.value:
        LD E,(HL):INC HL:LD D,(HL):INC HL
        LD A,(HL):INC HL:LD H,(HL):LD L,A
        EX DE,HL
        OR A                                    ; CF=0
        RET

; FILE_CHAIN (ID_FILE_CHAIN, WCINI.CP_SOURCE — F5 файла): цепочка файла цела
; на всю длину данных. Первый вызов — A=0: HL → первый кластер, DE → размер
; (по 4 байта). Кластер 0 — только у пустого файла. Нужно ⌈размер/(512·SPC)⌉
; кластеров: каждый — обычный, в области данных тома и не корень
; (CLASSIFY_DATA), ссылка к следующему нужному — допустимая (0 — свободный:
; MKFILE отдал бы его копии, и цепочки источника и копии сцепились бы, проба
; 2026-09-27), EOC раньше — цепочка короче размера; запись FAT последнего
; нужного — EOC или ссылка в томе. Дальше не проверяется. Z — цела; NZ, CF=0 —
; нет (в том числе отказ чтения FAT). CF=1, A=1 — проверена очередная порция
; (остаток ненулевой и кратен 1024; первая короче 1024, если длина не кратна):
; продолжить вызовом с A≠0 (HL, DE не нужны). Шлюз держит прерывания
; выключенными, а обход файла в гигабайт при SPC=8 — десятки секунд (Codex
; R28-02): между порциями WCFX.FC_LOOP отдаёт кадр обработчику IM2. Цикл
; внутри нужной длины не ловится: чтение копии всё равно кончится на размере.
FILE_CHAIN:
        OR A
        JP NZ,.more                             ; продолжение после порции
        PUSH HL
        EX DE,HL
        LD DE,FILE_CHAIN_LEFT:LD BC,4:LDIR      ; размер
        LD A,(@WDOS.BSECPC)
        LD H,A:LD L,0:ADD HL,HL:DEC HL          ; 512·SPC−1 (у SPC=128 — #FFFF)
        LD DE,(FILE_CHAIN_LEFT):ADD HL,DE:LD (FILE_CHAIN_LEFT),HL
        LD HL,(FILE_CHAIN_LEFT+2):LD DE,0:ADC HL,DE:LD (FILE_CHAIN_LEFT+2),HL
        CALL .half_carry                        ; ÷2 с переносом суммы (размер ~4 ГиБ)
        LD B,8                                  ; и ещё ÷256: всего ÷512
.sectors:
        CALL .half
        DJNZ .sectors
        LD A,(@WDOS.BSECPC)
.clusters:
        SRL A:JR Z,.count                       ; ÷SPC
        PUSH AF:CALL .half:POP AF
        JR .clusters
.count:
        POP HL
        LD E,(HL):INC HL:LD D,(HL):INC HL
        LD A,(HL):INC HL:LD H,(HL):LD L,A
        EX DE,HL                                ; DE:HL — первый кластер
        CALL .left0
        JR NZ,.data
        LD A,H:OR L:OR D:OR E:RET Z             ; пустой файл без кластера
        XOR A:RET                               ; пустой с кластером — не мешает
.data:
        LD A,H:OR L:OR D:OR E
        JR Z,.bad                               ; данные есть, кластера нет
        PUSH HL
        PUSH DE
        CALL ROOT_BUILD                         ; кластеры корня — для CLASSIFY_DATA
        POP DE
        POP HL
        JP C,.bad
        JR .walk                                ; сектор FAT корня читан в этом обходе
.resume:
        XOR A:LD (DIR_CHAIN_READ),A             ; сектор FAT — читать заново
.walk:
        CALL CLASSIFY_DATA
        JR C,.bad
        JR Z,.bad                               ; EOC раньше конца данных
        PUSH HL                                 ; нужно на один кластер меньше
        LD HL,FILE_CHAIN_LEFT                   ; (счёт не 0: его ловит .left0)
.borrow:
        LD A,(HL):DEC (HL):INC HL
        OR A:JR Z,.borrow                       ; байт был 0 — заём из следующего
        POP HL
        CALL .left0
        JR Z,.last                              ; все кластеры данных на месте
        CALL CHAIN_VALUE
        JR C,.bad
        LD BC,(FILE_CHAIN_LEFT)
        LD A,B:AND 3:OR C
        JR NZ,.walk
        LD (FILE_CHAIN_CUR),HL                  ; остаток кратен 1024 — порция:
        LD (FILE_CHAIN_CUR+2),DE                ; DE:HL — следующий, не проверен
        LD A,1
        SCF
        RET
.more:
        LD HL,(FILE_CHAIN_CUR),DE,(FILE_CHAIN_CUR+2)
        JR .resume
.bad:
        OR 1
        RET
        ; Не исполняется. MHMT 2009 на содержимом без этого байта (сборка
        ; 2026-09-27) терял конец потока — проверка распаковки в build.ps1
        ; остановила сборку; лишний байт сдвигает поток, упаковка верна.
        NOP
.last:                                          ; последний кластер данных сам занят:
        CALL CHAIN_VALUE                        ; его запись FAT — EOC или ссылка в
        JR C,.bad                               ; томе, не 0 (свободный отдал бы
        CALL CLASSIFY_DATA                      ; MKFILE копии)
        JR C,.bad
        XOR A
        RET
; FILE_CHAIN_LEFT ÷ 2 (.half_carry — CF входит старшим битом).
.half:
        OR A
.half_carry:
        LD HL,FILE_CHAIN_LEFT+3
        RR (HL):DEC HL:RR (HL):DEC HL:RR (HL):DEC HL:RR (HL)
        RET
; Z — FILE_CHAIN_LEFT = 0. HL, DE сохраняются.
.left0:
        PUSH HL
        LD HL,(FILE_CHAIN_LEFT):LD A,H:OR L
        LD HL,(FILE_CHAIN_LEFT+2):OR H:OR L
        POP HL
        RET

; DIR_LIST_OPEN (ID_DIR_LIST_OPEN, NXTINI): каталог LSTCAT — DIR_CHAIN, затем
; GIPAG, как прежде. Испорчен — как отказ GIPAG: ABT=#FE, EOC=#FF, CF=1.
DIR_LIST_OPEN:
        LD HL,(@WDOS.LSTCAT),DE,(@WDOS.LSTCAT+2)
        CALL DIR_CHAIN
        JP NZ,FAT_LINK_ERROR
        LD HL,@WDOS.LSTCAT
        JP @WDOS.GIPAG

; DIR_STREAM_OPEN (ID_DIR_STREAM_OPEN, FNDSN и SVHDFL): каталог LSTCAT —
; DIR_CHAIN, затем поток на его начало: LSTCAT → CUHL/CUDE, TOS (NSDC=EOC=0),
; выход CF=0. Испорчен — ABT=#FE, EOC=#FF, CF=1: поиск — FIND_IO_ERROR,
; создание — SVHDFL_READ_ERROR (отказ носителя до любой записи).
DIR_STREAM_OPEN:
        LD HL,(@WDOS.LSTCAT),DE,(@WDOS.LSTCAT+2)
        CALL DIR_CHAIN
        JP NZ,FAT_LINK_ERROR
        LD HL,@WDOS.LSTCAT,DE,@WDOS.CUHL,BC,4:LDIR
        JP @WDOS.TOS

; DIR_GROW (ID_DIR_GROW, FIIL в SVHDFL): свободного места в каталоге нет.
; Z — цепочка ещё не кончилась (EOC=0): читать дальше, как прежде. Кончилась —
; продлить: каталог не больше 4096 секторов (65536 записей FAT32; запас —
; DIR_CHAIN_LEFT от проверки этого каталога в начале SVHDFL, каждое продление
; тратит BSECPC). Прежде каталог рос дальше, и после записи DIR_CHAIN отвергал
; его целиком — каталог становился недоступен (Codex R27-01). Затем SRHFCL,
; как прежде: кластер найден — NZ, CF=0 и регистры SRHFCL, в том числе
; альтернативные (шлюз их возвращает). Полон или нет места — A=16; отказ
; чтения FAT при поиске (FREE_SCAN_IO_FAILED) — A=#FF; в обоих NZ, CF=1.
DIR_GROW:
        LD A,(@WDOS.EOC):OR A:RET Z
        LD HL,(DIR_CHAIN_LEFT)
        LD A,(@WDOS.BSECPC):LD C,A:LD B,0
        OR A:SBC HL,BC
        JR C,.full                              ; каталог уже 4096 секторов
        LD (DIR_CHAIN_LEFT),HL
        CALL CORE_SRHFCL                        ; при прерываниях вызывающего
        JR C,.none
        OR 1                                    ; NZ, CF=0
        RET
.none:
        LD A,(FREE_SCAN_IO_FAILED):OR A
        LD A,#FF
        JR NZ,.fail
.full:
        LD A,16
.fail:
        OR A
        SCF
        RET

; STREAM_LINK (ID_STREAM_LINK): переход потока по записи FAT, HL — запись в
; SECBU (попадание кэша STREAM_NEXT_CACHED; промах — хвост STREAM_NEXT_CLUSTER).
; Ноль там — свободный кластер: GIPAG понял бы его как корень (0 — вход
; открытия корня), и поток шёл бы по корневому каталогу: чтение файла молча
; подменялось (F5 копировал байты корня), SAVE512 писал в корень (Codex
; R26-03). Ноль — порча ссылки, как недопустимые значения; иначе GIPAG.
STREAM_LINK:
        PUSH HL
        LD A,(HL):INC HL:OR (HL):INC HL:OR (HL):INC HL:OR (HL)
        POP HL
        JP NZ,@WDOS.GIPAG
        JP FAT_LINK_ERROR

; CLASSIFY_FAT_LINK для ядра (ID_CLASSIFY_FAT_LINK: GIPAG — первый кластер и
; каждый переход потока, DLSG, GIPP): обычный кластер за концом области
; данных тома (FAT_DATA_CLUSTER_LIMIT) — тоже недопустимая ссылка. Последний
; сектор FAT держит слоты за концом данных, и испорченная цепочка вела чтение
; и запись за границу тома (Codex R25-03). Граница не задана (не больше 2:
; том не монтирован HDD) — без проверки, как прежде. Прямые вызовы внутри
; расширения — прежний CLASSIFY_FAT_LINK.
CLASSIFY_IN_VOLUME:
        CALL CLASSIFY_FAT_LINK
        RET C                                   ; недопустимая
        RET Z                                   ; EOC
        PUSH HL
        PUSH DE
        LD BC,(FAT_DATA_CLUSTER_LIMIT):OR A:SBC HL,BC
        EX DE,HL
        LD BC,(FAT_DATA_CLUSTER_LIMIT+2):SBC HL,BC   ; CF — кластер ниже границы
        POP DE
        POP HL
        JR C,.inside
        PUSH HL                                 ; граница задана?
        LD HL,(FAT_DATA_CLUSTER_LIMIT+2):LD A,H:OR L
        LD HL,(FAT_DATA_CLUSTER_LIMIT):OR H
        JR NZ,.set
        LD A,L:CP 3                             ; CF — не задана
.set:
        POP HL
        JP NC,CLASSIFY_INVALID                  ; за областью данных
.inside:
        XOR A:INC A                             ; обычный: A=1, NZ, CF=0
        RET
; Claude - 2026-09-27 - end

; Проверить четыре байта непосредственно перед HL, не меняя указатель.
; Z означает точный маркер EOC, NZ — обычное значение или кластер.
IS_EOC_BEFORE_HL:
        PUSH HL
        DEC HL
        LD A,(HL):AND #0F:CP #0F:JR NZ,.no
        DEC HL
        LD A,(HL):CP #FF:JR NZ,.no
        DEC HL
        LD A,(HL):CP #FF:JR NZ,.no
        DEC HL
        LD A,(HL):CP #F8:JR C,.no
        POP HL
        XOR A
        RET
.no:
        POP HL
        LD A,1:OR A
        RET

; Зафиксировать повреждённую ссылку FAT и остановить текущую цепочку.
RECORD_FAT_LINK_ERROR:
        LD A,#FE
        LD (@WDOS.ABT),A
; Codex - 2026-07-16 - begin
        ; ABT хранит точный код повреждения, а EOC унифицирован с обычным
        ; концом цепочки: компактные исторические проверки ожидают #FF.
        INC A
; Codex - 2026-07-16 - end
        LD (@WDOS.EOC),A
        OR A
        RET

FAT_LINK_ERROR:
        CALL RECORD_FAT_LINK_ERROR
        SCF
        RET

; Claude - 2026-09-27 - begin
; TREE_CHILD (ID_TREE_CHILD): можно ли обходу дерева F5/F8 (WCINI.DL_ENTER,
; CP_ENTER) войти в каталог DE:HL — кластер записи, найденной FENTRY в
; текущем каталоге (родителе, LSTCAT). Каталог настоящий, если это не корень,
; его цепочка цела (в области данных, без свободных и недопустимых ссылок, не
; длиннее 4096 секторов), а первый сектор начинается записью «.» каталога на
; этот же кластер и второй — «..» каталога на родителя (у корня «..» бывает и
; 0, и номер корневого кластера — годится любой). Иначе запись испорчена, и обход
; пошёл бы не туда: кластер 0 или корня — по корню (F8 одного такого каталога
; удалял неотмеченные файлы корня, проверено 2026-09-27), общий с другим
; каталогом — по чужому дереву, внутри файла — по его данным, свободный в FAT
; — по удалённому каталогу, чьи файлы могли отдать кластеры другим. Выход:
; Z — входить; NZ —
; нельзя, в том числе при отказе FAT или чтения. Сектор — в LOBU (как у
; DIR_ALIVE), поток переставлен: вход в каталог (GLSTCAT) начнёт его заново.
TREE_CHILD_ENTRY:
        LD (DIR_ALIVE_CLUSTER),HL
        LD (DIR_ALIVE_CLUSTER+2),DE
        CALL .root
        JP Z,.no                                ; 0 или сам корень — не подкаталог
        PUSH HL                                 ; сам текущий каталог (Codex R26-01)
        LD BC,(@WDOS.LSTCAT):OR A:SBC HL,BC
        POP HL
        JR NZ,.other
        PUSH HL
        LD H,D:LD L,E
        LD BC,(@WDOS.LSTCAT+2):OR A:SBC HL,BC
        POP HL
        JP Z,.no
.other:
; Вся цепочка каталога (DIR_CHAIN): в области данных тома, ссылки допустимы
; (0 — свободный: каталог удалён, его файлы могли отдать кластеры другим),
; не длиннее 4096 секторов. Иначе обход дерева читал и писал бы за границей
; тома или перечислял бы замкнутую цепочку без конца (Codex R25-02, R25-03).
        CALL DIR_CHAIN
        JP NZ,.no
        LD HL,DIR_ALIVE_CLUSTER                 ; цепочка цела
        CALL @WDOS.GIPAG
        RET NZ
        LD HL,@WDOS.LOBU,B,1
        CALL @WDOS.LOAD512
        JR C,.no
        LD HL,@WDOS.LOBU
        LD A,(HL):CP ".":JR NZ,.no
        INC HL:LD B,10:CALL .spaces:JR NZ,.no   ; «.» и 10 пробелов
        LD HL,@WDOS.LOBU
        CALL DIR_ALIVE_ENTRY.match
        RET NZ                                  ; «.» — не каталог на этот кластер
        LD HL,(@WDOS.LOBU+32),DE,".."
        OR A:SBC HL,DE:JR NZ,.no
        LD HL,@WDOS.LOBU+34:LD B,9:CALL .spaces
        JR NZ,.no                               ; «..» и 9 пробелов
        LD A,(@WDOS.LOBU+43):AND #10:JR Z,.no   ; «..» — не каталог
        LD HL,(@WDOS.LSTCAT),DE,(@WDOS.LSTCAT+2)
        CALL .root
        JR Z,.at_root
        LD (DIR_ALIVE_CLUSTER),HL
        LD (DIR_ALIVE_CLUSTER+2),DE
        LD HL,@WDOS.LOBU+32
        JP DIR_ALIVE_ENTRY.match                ; Z — «..» на родителя
.at_root:
        LD HL,(@WDOS.LOBU+58),DE,(@WDOS.LOBU+52)   ; кластер «..»
        CALL .root
        RET Z                                   ; «..» — корень
.no:
        OR 1
        RET
; Z — B байт с HL — пробелы.
.spaces:
        LD A,(HL):CP " ":RET NZ
        INC HL
        DJNZ .spaces
        RET
; Z — DE:HL корень: 0 либо BROOTC. HL и DE сохраняются.
.root:
        LD A,H:OR L:OR D:OR E:RET Z
        PUSH HL
        LD BC,(@WDOS.BROOTC):OR A:SBC HL,BC
        POP HL
        RET NZ
        PUSH HL
        LD H,D:LD L,E
        LD BC,(@WDOS.BROOTC+2):OR A:SBC HL,BC
        POP HL
        RET

; ROOT_BUILD: кластеры цепочки корня (от BROOTC) — в ROOT_CLUSTERS, их число —
; в ROOT_COUNT, бит каждого (младшие 11 бит номера) — в ROOT_FILTER. Дальше
; ROOT_MAX (768) не записываются: корень FAT32 — до 4096 секторов, и при
; кластере от 4 КиБ (SPC ≥ 8, до 512 кластеров) таблица держит его целиком;
; длиннее бывает только при SPC 1..4 и корне больше 768 кластеров (больше
; 12288 записей при SPC=1) — дальние кластеры такого корня не защищены
; (docs/04). Обход — до конца цепочки, недопустимой ссылки (свободный, за
; томом) или до ROOT_MAX. Отказ чтения FAT — CF=1 и ROOT_FAILED≠0: ROOT_MEMBER
; тогда считает корнем любой кластер. Таблица одна на все тома и панели,
; поэтому строится заново перед каждым использованием: DLSG ядра
; (NOTE_FREED_CHAIN), FILE_CHAIN, DIR_CHAIN подкаталога. Сектор FAT корня
; остаётся в SECBU (DIR_CHAIN_READ=1). Разрушает AF, BC, DE, HL.
ROOT_BUILD:
        XOR A
        LD (ROOT_FAILED),A
        LD (DIR_CHAIN_READ),A                   ; первый сектор FAT — читать
        LD HL,0:LD (ROOT_COUNT),HL
        LD HL,ROOT_FILTER
        LD DE,ROOT_FILTER+1
        LD BC,255
        LD (HL),A
        LDIR
        LD HL,(@WDOS.BROOTC),DE,(@WDOS.BROOTC+2)
        LD BC,ROOT_CLUSTERS
.cluster:
        PUSH BC
        CALL CLASSIFY_IN_VOLUME
        POP BC
        JR C,.done                              ; недопустимая ссылка
        JR Z,.done                              ; конец цепочки
        PUSH HL
        LD HL,(ROOT_COUNT)
        INC HL
        LD (ROOT_COUNT),HL
        PUSH BC
        LD BC,ROOT_MAX+1
        OR A:SBC HL,BC                          ; CF — место в таблице ещё было
        POP BC
        POP HL
        JR NC,.full
        LD A,L:LD (BC),A:INC BC
        LD A,H:LD (BC),A:INC BC
        LD A,E:LD (BC),A:INC BC
        LD A,D:LD (BC),A:INC BC
        PUSH HL
        PUSH BC
        CALL ROOT_BIT
        LD A,(HL):OR B:LD (HL),A
        POP BC
        POP HL
        PUSH BC
        CALL CHAIN_VALUE
        POP BC
        JR NC,.cluster
        LD A,1:LD (ROOT_FAILED),A
        RET                                     ; CF=1
.full:
        LD HL,ROOT_MAX
        LD (ROOT_COUNT),HL
.done:
        OR A
        RET

; ROOT_MEMBER: Z — кластер DE:HL (нормализованный) из цепочки корня
; (ROOT_BUILD; при ROOT_FAILED≠0 — любой). Сначала бит фильтра: нет его — не
; корень, таблица не просматривается. HL, DE сохраняются; разрушает AF, BC.
ROOT_MEMBER:
        LD A,(ROOT_FAILED):OR A
        JR Z,.table
        XOR A                                   ; FAT корня не прочиталась
        RET
.table:
        PUSH HL
        CALL ROOT_BIT
        LD A,(HL):AND B
        POP HL
        JR Z,.no
        LD BC,(ROOT_COUNT)
        LD A,B:OR C:JR Z,.no
        PUSH IX
        LD IX,ROOT_CLUSTERS
.next:
        LD A,(IX+0):CP L:JR NZ,.skip
        LD A,(IX+1):CP H:JR NZ,.skip
        LD A,(IX+2):CP E:JR NZ,.skip
        LD A,(IX+3):CP D:JR Z,.found
.skip:
        INC IX:INC IX:INC IX:INC IX
        DEC BC:LD A,B:OR C:JR NZ,.next
        POP IX
.no:
        OR 1
        RET
.found:
        POP IX
        RET

; ROOT_BIT: бит фильтра корня для младшего слова кластера HL: HL — байт
; ROOT_FILTER, B — маска. Разрушает AF.
ROOT_BIT:
        LD A,L:AND 7:LD B,A
        LD A,H:AND 7:LD H,A
        SRL H:RR L
        SRL H:RR L
        SRL H:RR L                              ; (кластер & 2047) / 8
        PUSH DE
        LD DE,ROOT_FILTER:ADD HL,DE
        POP DE
        LD A,B
        LD B,1
        OR A:RET Z
.shift:
        SLA B
        DEC A:JR NZ,.shift
        RET

; Записи одного каталога на кластерах отмеченных объектов F8 (Codex R27-04,
; частичная защита; WCINI.DL_ALIAS до первого удаления). Испорченная запись
; на первом кластере соседа, или каталог, чья цепочка проходит через первый
; кластер соседа (через «.» и «..» каталога панели тоже), вела F8 по чужим
; данным: освобождались цепочки и удалялись файлы невыбранного объекта.
; Таблица ALIAS_TABLE — открытая адресация по младшим битам кластера, слот —
; кластер (0 — пуст), признаки (биты 0..6 — сколько отмеченных объектов на нём
; начинается, бит 7 — он в хвосте цепочки отмеченного каталога) и
; «фактически» (сколько записей каталога на нём начинается). Нарушение: на
; кластере начинаются два отмеченных объекта (две записи на одной цепочке —
; порча; удалить их по очереди нельзя: первое удаление освобождает цепочку, и
; второй каталог остался бы записью на свободном кластере, Codex R34-01),
; записей больше, чем отмеченных, или на кластере хвоста начинается хоть одна
; запись, в том числе отмеченная. Заполнена не больше чем наполовину (ALIAS_LOAD),
; пустой слот при поиске всегда найдётся.

; ALIAS_RESET (ID_ALIAS_RESET): пустая таблица. A=0 — начало проверки: и
; продолжение хвоста каталога (ALIAS_RESUME) забыть; A≠0 — сброс между
; заходами одной проверки, хвост продолжится.
ALIAS_RESET:
        OR A
        JR NZ,.keep
        LD (ALIAS_RESUME),A
.keep:
        LD HL,ALIAS_TABLE
        LD DE,ALIAS_TABLE+1
        LD BC,ALIAS_SLOTS*6-1
        LD (HL),0
        LDIR
        LD HL,0
        LD (ALIAS_USED),HL
        RET

; ALIAS_ADD (ID_ALIAS_ADD): отмеченный объект — первый кластер DE:HL, A —
; признак панели (0 — каталог). Первый кластер — «ожидаемо»+1; у каталога
; ещё и весь хвост цепочки — «ожидаемо»+0 (не дальше 4096 кластеров: каталог
; FAT32 — до 4096 секторов, длиннее — цикл, его отвергнет DIR_CHAIN при
; входе). Кластер 0 (пустой файл) и недопустимый (DLSG откажет сам) —
; пропуск; порча в хвосте — конец хвоста. Выход: CF=1 — места нет:
; ALIAS_SCAN, ALIAS_RESET с A≠0 и снова он же; хвост, не уместившийся в
; таблицу, продолжится с того же места (ALIAS_RESUME, ALIAS_NEXT); иначе
; CF=0: Z — внесён, NZ — отказ чтения FAT в хвосте каталога. IX сохраняется:
; шлюз возвращает IX функции вызывающему, а у WCINI.DL_ALIAS это описатель
; панели для GETen.
ALIAS_ADD:
        PUSH IX
        CALL .body
        POP IX
        RET
.body:
        PUSH AF
        CALL CLASSIFY_IN_VOLUME
        JP C,.skip                              ; 0, недопустимый, за томом
        JP Z,.skip                              ; EOC
        LD A,(ALIAS_RESUME):OR A
        JR Z,.fresh
        CALL .owner                             ; Z — тот же каталог, хвост дальше
        JR NZ,.fresh
        POP AF
        XOR A
        LD (ALIAS_RESUME),A
        LD (DIR_CHAIN_READ),A                   ; сектор FAT — читать заново
        LD HL,(ALIAS_NEXT),DE,(ALIAS_NEXT+2)    ; следующий кластер хвоста
        JR .insert
.fresh:
        XOR A:LD (ALIAS_RESUME),A
        PUSH HL
        LD HL,(ALIAS_USED)
        LD BC,ALIAS_LOAD-1
        OR A:SBC HL,BC                          ; CF — места на первый кластер и
        POP HL                                  ; хоть один кластер хвоста хватит
        JR C,.room
        POP AF
        SCF
        RET
.room:
        LD (ALIAS_OWNER),HL
        LD (ALIAS_OWNER+2),DE
        LD A,1
        CALL ALIAS_INSERT
        POP AF
        OR A
        JR Z,.tail_start                        ; каталог
        XOR A                                   ; файл — только первый кластер
        RET
.tail_start:
        XOR A:LD (DIR_CHAIN_READ),A
        LD HL,4096:LD (ALIAS_STEPS),HL
        LD HL,(ALIAS_OWNER),DE,(ALIAS_OWNER+2)
.tail:
        CALL CHAIN_VALUE
        JR C,.fail
        CALL CLASSIFY_IN_VOLUME
        JR C,.end                               ; порча ссылки
        JR Z,.end                               ; конец цепочки
        PUSH HL
        LD HL,(ALIAS_STEPS)
        DEC HL
        LD (ALIAS_STEPS),HL
        LD A,H:OR L
        POP HL
        JR Z,.end                               ; длиннее 4096 — цикл
.insert:
        PUSH HL
        LD HL,(ALIAS_USED)
        LD BC,ALIAS_LOAD
        OR A:SBC HL,BC                          ; CF — место есть
        POP HL
        JR NC,.pause
        PUSH HL
        PUSH DE
        XOR A
        CALL ALIAS_INSERT
        POP DE
        POP HL
        JR .tail
.pause:                                         ; таблица полна: продолжить с DE:HL
        LD (ALIAS_NEXT),HL
        LD (ALIAS_NEXT+2),DE
        LD A,1:LD (ALIAS_RESUME),A
        SCF
        RET
.end:
        XOR A
        RET
.skip:
        POP AF
        XOR A
        RET
.fail:
        OR 1                                    ; NZ, CF=0
        RET
; Z — DE:HL = ALIAS_OWNER. HL, DE сохраняются; разрушает AF, BC.
.owner:
        PUSH HL
        LD BC,(ALIAS_OWNER):OR A:SBC HL,BC
        POP HL
        RET NZ
        PUSH HL
        LD H,D:LD L,E
        LD BC,(ALIAS_OWNER+2):OR A:SBC HL,BC
        POP HL
        RET

; ALIAS_INSERT: кластер DE:HL (нормализованный) — в таблицу; A=1 — на нём
; начинается отмеченный объект (счёт +1, насыщение на 127), A=0 — кластер
; хвоста отмеченного каталога (бит 7). ALIAS_KEY — кластер. Разрушает AF, BC,
; DE, HL, IX.
ALIAS_INSERT:
        LD (ALIAS_KEY),HL
        LD (ALIAS_KEY+2),DE
        LD C,A
        CALL ALIAS_FIND
        JR Z,.have
        LD HL,(ALIAS_KEY):LD (IX+0),L:LD (IX+1),H
        LD HL,(ALIAS_KEY+2):LD (IX+2),L:LD (IX+3),H
        LD (IX+4),0:LD (IX+5),0
        LD HL,(ALIAS_USED):INC HL:LD (ALIAS_USED),HL
.have:
        LD A,C:OR A
        JR Z,.tail
        LD A,(IX+4):AND #7F:CP #7F:RET Z        ; счёт насыщен (два — уже нарушение)
        INC (IX+4)
        RET
.tail:
        SET 7,(IX+4)
        RET

; ALIAS_FIND: слот кластера ALIAS_KEY. Z — есть (IX — его слот); NZ — нет,
; IX — пустой слот, где ему место. Разрушает AF, DE, HL; BC сохраняется.
ALIAS_FIND:
        LD HL,(ALIAS_KEY)
        LD A,H:AND high (ALIAS_SLOTS-1):LD H,A  ; номер слота
        ADD HL,HL
        LD D,H:LD E,L
        ADD HL,HL
        ADD HL,DE                               ; ×6
        LD DE,ALIAS_TABLE:ADD HL,DE
        PUSH HL:POP IX
.probe:
        LD A,(IX+0):OR (IX+1):OR (IX+2):OR (IX+3)
        JR Z,.empty
        LD HL,ALIAS_KEY
        LD A,(IX+0):CP (HL):JR NZ,.next
        INC HL:LD A,(IX+1):CP (HL):JR NZ,.next
        INC HL:LD A,(IX+2):CP (HL):JR NZ,.next
        INC HL:LD A,(IX+3):CP (HL):RET Z
.next:
        LD DE,6:ADD IX,DE
        PUSH IX:POP HL
        LD DE,ALIAS_TABLE+ALIAS_SLOTS*6
        OR A:SBC HL,DE
        JR NZ,.probe
        LD IX,ALIAS_TABLE                       ; по кругу
        JR .probe
.empty:
        OR 1
        RET

; ALIAS_SCAN (ID_ALIAS_SCAN): живые короткие записи текущего каталога
; (LSTCAT; «.» и «..» тоже, LFN и метка тома — нет) против таблицы: запись на
; кластере из таблицы — «фактически»+1. Затем «фактически» > «ожидаемо» —
; на кластере отмеченного стоит ещё чья-то запись: F8 освободил бы её
; данные. A=0 — начало, A≠0 — продолжение: за вызов не больше
; ALIAS_PORTION_SECTORS секторов, CF=1 и A=1 — порция пройдена, звать снова
; (шлюз держит прерывания выключенными; между порциями WCINI.DL_SCAN отдаёт
; кадр IM2). Итог: Z, CF=0 — нарушений нет; NZ, CF=0 — есть, или каталог не
; читается (отказ, порча ссылки, длиннее 4096 секторов). Сектор — в LOBU,
; поток переставлен. IX сохраняется (как у ALIAS_ADD).
ALIAS_SCAN:
        PUSH IX
        CALL .body
        POP IX
        RET
.body:
        OR A
        JR NZ,.more
        LD HL,@WDOS.LSTCAT
        CALL @WDOS.GIPAG
        JP NZ,.bad
        LD HL,4097
        LD (ALIAS_LEFT),HL
.more:
        LD A,ALIAS_PORTION_SECTORS
        LD (ALIAS_PORTION),A
.sector:
        LD HL,(ALIAS_LEFT)
        DEC HL
        LD (ALIAS_LEFT),HL
        LD A,H:OR L:JP Z,.bad                   ; длиннее 4096 секторов
        LD HL,@WDOS.LOBU,B,1
        CALL @WDOS.LOAD512
        JP C,.bad
        LD HL,@WDOS.LOBU
.entry:
        LD A,(HL):OR A:JR Z,.end                ; конец каталога
        CP #E5:JR Z,.next
        PUSH HL
        LD DE,11:ADD HL,DE
        BIT 3,(HL):JR NZ,.skip                  ; LFN (#0F) и метка тома
        LD DE,20-11:ADD HL,DE
        LD E,(HL):INC HL:LD D,(HL)              ; старшее слово кластера
        LD BC,26-21:ADD HL,BC
        LD A,(HL):INC HL:LD H,(HL):LD L,A       ; младшее
        LD A,D:AND #0F:LD D,A
        LD A,H:OR L:OR D:OR E:JR Z,.skip
        LD (ALIAS_KEY),HL
        LD (ALIAS_KEY+2),DE
        CALL ALIAS_FIND
        JR NZ,.skip
        INC (IX+5):JR NZ,.skip
        DEC (IX+5)                              ; насыщение
.skip:
        POP HL
.next:
        LD DE,32:ADD HL,DE
        LD A,H:CP high (@WDOS.LOBU+512):JR C,.entry
        LD A,(@WDOS.EOC)
        CP #0F:JR Z,.end                        ; цепочка каталога кончилась
        OR A:JR NZ,.bad                         ; порча ссылки (#FF)
        LD HL,ALIAS_PORTION
        DEC (HL):JR NZ,.sector
        LD A,1
        SCF
        RET
.end:
        LD IX,ALIAS_TABLE
        LD BC,ALIAS_SLOTS
.check:
        LD A,(IX+4)
        BIT 7,A:JR Z,.first
        LD A,(IX+5):OR A:JR NZ,.bad             ; на кластере хвоста начинается запись
        LD A,(IX+4)
.first:
        AND #7F
        CP 2:JR NC,.bad                         ; два отмеченных на одной цепочке
        CP (IX+5):JR C,.bad                     ; записей больше, чем отмеченных
        LD DE,6:ADD IX,DE
        DEC BC:LD A,B:OR C:JR NZ,.check
        RET                                     ; Z, CF=0
.bad:
        OR 1
        RET
; Claude - 2026-09-27 - end

; Claude - 2026-09-26 - begin
; PLAIN_ALIAS (ID_PLAIN_ALIAS, вход LONG в ENTREZ ядра): короткое имя для
; длинного без «~n». LONG зовётся, когда имя нельзя записать одной короткой
; записью: ENTRY[0..10] — раскладка 8.3 из LNLNG с сохранённым регистром, а в
; ENTRY[0] ноль, если имя в 8.3 не укладывается (NESN) или в нём пробел
; (REFINE_NAME_CLASSIFICATION). Если раскладка полная (нет нуля, нет пробела в
; начале, нет знаков SNCEN — «+ , . ; = [ ]»), длинное имя нужно лишь ради
; заглавных букв: короткое — сама раскладка заглавными (ACS, как в SNCC).
; ENTRY на входе SNCC мог уже частично перевести в заглавные — не важно.
; Выход: Z — такого короткого в каталоге нет (FIND_ALIAS), ENTRY[0..10] и
; NXTBM — запись с ним, ядро строит LFN (LFN_ENTRIES); NZ — нужен «~n», как
; прежде; CF — каталог не прочитан (из FIND_ALIAS, A — её код). ENTRY[0..10]
; при NZ может остаться частично заглавным: путь «~n» строит их заново из
; текста имени (8 знаков основы, NOP32, расширение). Так «boot.$C» получает
; «BOOT    $C», как у Windows, и ПЗУ находит boot.$C после замены файла;
; прежде выходило «BOOTJ$~1.$C».
PLAIN_ALIAS:
        LD HL,@WDOS.ENTRY
        LD A,(HL)
        CP " "+1
        JR C,.long                              ; ноль или пробел в начале
        LD B,11
.check:
        LD A,(HL)
        OR A
        JR Z,.long
        CALL @WDOS.SNCEN
        JR Z,.long                              ; знак, запрещённый в 8.3
        CALL @WDOS.ACS
        LD (HL),A                               ; кандидат — заглавными в ENTRY
        INC HL
        DJNZ .check
        ; Как в цикле «~n» (BURA): кандидат и в ENTRY, и в NXTBM — FIND_ALIAS
        ; берёт текст запроса из NXTBM, а короткие имена каталога сравнивает
        ; с ENTRY (SNCH). Прежде ENTRY здесь был ещё в исходном регистре, и
        ; чужое «README  TXT» при запросе «ReadMe.txt» не находилось (Codex R18-1).
        LD HL,@WDOS.ENTRY
        LD DE,@WDOS.NXTBM
        LD BC,32
        LDIR                                    ; запись целиком, как NN
        CALL @WDOS.FIND_ALIAS                   ; Z — такого короткого нет
        RET C
        RET Z                                   ; Z, CF=0 — взято
.long:
        OR 1                                    ; NZ, CF=0 — «~n»
        RET
; Claude - 2026-09-26 - end

; Уточнить результат штатного анализатора SN/LN. Если исходное имя содержит
; хотя бы один пробел, короткая 8.3-запись недопустима: ENTRY[0]=0 заставляет
; генератор и поисковик использовать длинное имя.
REFINE_NAME_CLASSIFICATION:
        PUSH HL
        LD HL,(@WDOS.CGDE)
        INC HL
.scan:
        LD A,(HL):OR A:JR Z,.done
        CP " ":JR Z,.force_lfn
        INC HL
        JR .scan
.force_lfn:
        XOR A:LD (@WDOS.ENTRY),A
.done:
        POP HL
        LD A,1:OR A
        RET

; Codex - 2026-07-16 - begin
; Проверить имя длиной 1..255 байт. DE запоминает позицию после последнего
; значимого символа, поэтому конечная смесь пробелов и точек удаляется целиком.
; Z означает корректное имя; NZ — пустое, длиннее 255 или содержащее
; запрещённый символ.
VALIDATE_NAME:
        LD B,255
        LD DE,0
.scan:
        LD A,(HL):OR A:JR Z,.terminated
        CALL @WDOS.ENCEN:JR Z,.bad
        CP " ":JR Z,.next
        CP ".":JR Z,.next
        LD DE,HL
        INC DE
.next:
        INC HL
        DJNZ .scan
        LD A,(HL):OR A:JR NZ,.bad
.terminated:
        LD A,D:OR E:JR Z,.bad
        XOR A
        LD (DE),A
; Claude - 2026-09-25 - begin
; Имя — копия в NXTBU (зовёт только ENTREZ, с 2026-09-26 прямо, без ENVAL): ENTREZ копирует
; 256 байт, и за концом имени лежал хвост буфера вызывающего — остатки
; прежнего имени. Основа короткого имени (LONG) читает 8 знаков подряд и
; брала их: у «A» выходило «AZPRIV~1». Хвост до конца страницы NXTBU — нули.
        EX DE,HL
.zero:
        INC HL
        LD A,H:OR A
        JR NZ,.zeroed
        LD (HL),A
        JR .zero
.zeroed:
        XOR A                                   ; Z — имя годно
; Claude - 2026-09-25 - end
        RET
.bad:
        JP CLASSIFY_ORDINARY
; Codex - 2026-07-16 - end

; Начать симметричное сравнение LFN: начальные пробелы пропускаются и в
; поисковом запросе, и в сохранённом UTF-16 имени. Внутренние пробелы остаются
; значимыми.
BEGIN_LFN_COMPARE:
        LD A,1:LD (LFN_LEADING),A
        RET

; Совместимый заменитель ULNP.
; CF=1 — текущий символ совпал и сравнение надо продолжить;
; CF=0,Z=1 — несовпадение; CF=0,NZ — оба имени закончились одновременно.
COMPARE_LFN_CHAR:
        LD A,(LFN_LEADING):OR A:JR Z,.normal
.skip_query_spaces:
        LD A,(DE):CP " ":JR NZ,.leading_stored
        INC DE
        JR .skip_query_spaces
.leading_stored:
        CALL @WDOS.UCS
        OR A:JR Z,.mismatch
        CP " ":JR Z,.continue
        LD C,A
        XOR A:LD (LFN_LEADING),A
        LD A,C:CALL @WDOS.ACS:LD C,A
        LD A,(DE):OR A:JR Z,.decoded_end
        INC DE
        CALL @WDOS.ACS
        CP C:JR Z,.continue
        JR .mismatch
.decoded_end:
        LD A,C:INC A:JR NZ,.mismatch
        JR .matched

.normal:
        LD A,(DE):INC DE:OR A:JR Z,.query_end
        CALL @WDOS.ACS:LD C,A
        CALL @WDOS.UCS:OR A:JR Z,.mismatch
        CALL @WDOS.ACS:CP C:JR Z,.continue
.mismatch:
        XOR A
        RET
.continue:
        SCF
        RET
.query_end:
        CALL @WDOS.UCS:INC A:JR NZ,.mismatch
.matched:
        XOR A:INC A
        RET

; ALLOCATE_FILE (MKFILE ядра): итог выделения. MKSG MKFILE с 2026-09-27 зовёт
; сам, вне шлюза (Codex R28-02: здесь, при DI, файл в гигабайт выделялся
; минуту и дольше), AF — его итог; размер 0 — MKSG не звался (пустой файл
; имеет нулевой первый кластер: DEC в MKSG превратил бы счётчик в #FFFFFFFF).
; Z и CF=1 — цепочка записана (BUtoFAT кончает CF=1); Z и CF=0 — размер 0,
; HL=DE=0: FCTS=0; NZ — отказ MKSG, код 16 или #FF (MKSG_CHECKED.result).
; После MKSG не записывать FSInfo автоматически. На реальном SD-ZC этот
; дополнительный I/O зависал и в F5 COPY, и в транзакционном сохранении
; TXTEDIT. Найденная позиция остаётся в FSTFRC для текущего сеанса.
ALLOCATE_FILE:
        JP NZ,MKSG_CHECKED.result               ; отказ чтения FAT — #FF, не 16
        RET C                                   ; цепочка записана
        LD (@WDOS.FCTS),HL                      ; пустой файл
        LD (@WDOS.FCTS+2),HL
        RET

; Загрузить параметры FAT, включая BPB_ExtFlags. FATFLAGS хранит младший байт:
; бит 7 отключает зеркалирование, младшие четыре бита задают активную FAT.
LOAD_FAT_CONFIG:
        LD A,(@WDOS.LOBU+16)
        LD (@WDOS.BFATS),A
        OR A:JR Z,.bad

        LD A,(@WDOS.LOBU+40)
        LD (@WDOS.FATFLAGS),A
        BIT 7,A:JR Z,.flags_ok
        AND #0F
        LD B,A
        LD A,(@WDOS.BFATS)
        CP B:JR Z,.bad:JR C,.bad
.flags_ok:
        LD HL,(@WDOS.LOBU+36)
        LD (@WDOS.BFTSZ),HL
        LD HL,(@WDOS.LOBU+38)
        LD (@WDOS.BFTSZ+2),HL

        LD HL,(@WDOS.LOBU+44)
        LD (@WDOS.BROOTC),HL
        LD HL,(@WDOS.LOBU+46)
        LD A,H:AND #0F:LD H,A
        LD (@WDOS.BROOTC+2),HL

        XOR A
        RET
.bad:
        LD A,1:OR A
        RET

; Проверить значение DE:HL как начальную подсказку поиска. Допустимы только
; настоящие data-кластеры, для которых существует сектор внутри текущей FAT.
; Регистры DE:HL сохраняются; Z означает допустимое значение.
VALIDATE_FREE_HINT:
        PUSH HL,DE
        LD A,D:OR E:OR H:JR NZ,.minimum_ok
        LD A,L:CP 2:JR C,.bad_restore
.minimum_ok:
        LD BC,(FAT_DATA_CLUSTER_LIMIT)
        OR A:SBC HL,BC
        EX DE,HL
        LD BC,(FAT_DATA_CLUSTER_LIMIT+2)
        SBC HL,BC
        EX DE,HL
        JR NC,.bad_restore
        POP DE,HL

        PUSH HL,DE
        CALL @WDOS.DEL128
        CALL FAT_SECTOR_IN_RANGE
        POP DE,HL
        JR NC,.bad
        XOR A
        RET
.bad_restore:
        POP DE,HL
.bad:
        LD A,1:OR A
        RET

; Прочитать FSI_Nxt_Free. FSInfo является подсказкой: плохой сектор, сигнатуры,
; #FFFFFFFF, занятый кластер или выход за область данных не мешают монтированию.
; Для такого холодного старта RAM-курсор ставится в 15/16 области данных:
; штатный SRHFCL всё равно проверяет FAT и при необходимости делает полный wrap.
LOAD_FREE_HINT:
        LD HL,2:LD (@WDOS.FSTFRC),HL
        LD (FAT_DATA_CLUSTER_LIMIT),HL
        LD HL,0:LD (@WDOS.FSTFRC+2),HL
        LD (FAT_DATA_CLUSTER_LIMIT+2),HL

        ; SDFAT уже вычислен основной частью как первый data-сектор. Получить
        ; верхнюю границу кластеров непосредственно из ещё сохранённого BPB.
        LD HL,(@WDOS.LOBU+19)
        LD A,H:OR L:JR Z,.total32
        LD DE,0
        JR .total_ready
.total32:
        LD HL,(@WDOS.LOBU+32),DE,(@WDOS.LOBU+34)
.total_ready:
        LD BC,(@WDOS.SDFAT)
        OR A:SBC HL,BC
        EX DE,HL
        LD BC,(@WDOS.SDFAT+2)
        SBC HL,BC
        EX DE,HL
        JR C,.done
        LD A,(@WDOS.BSECPC)
.divide:
        CP 1:JR Z,.limit_ready
        SRL D:RR E:RR H:RR L
        SRL A
        JR .divide
.limit_ready:
        LD BC,2:CALL @WDOS.ADD4B
        LD (FAT_DATA_CLUSTER_LIMIT),HL
        LD (FAT_DATA_CLUSTER_LIMIT+2),DE
        CALL SET_COLD_FREE_HINT

        LD HL,(@WDOS.FSINF),DE,(@WDOS.FSINF+2)
        CALL @WDOS.XPOZI
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        JR NZ,.done
        CALL VALIDATE_FSINFO_SECTOR
        JR NZ,.done
        LD HL,(@WDOS.LOBU+492),DE,(@WDOS.LOBU+494)
        CALL VALIDATE_FREE_HINT
        JR NZ,.done
        LD (@WDOS.CAHL),HL
        LD (@WDOS.CADE),DE
        CALL @WDOS.CURIT
        JR C,.done
        LD A,(HL):INC HL
        OR (HL):INC HL
        OR (HL):INC HL
        OR (HL):JR NZ,.done
        LD HL,(@WDOS.CAHL),DE,(@WDOS.CADE)
        LD (@WDOS.FSTFRC),HL
        LD (@WDOS.FSTFRC+2),DE
.done:
        XOR A
        LD (@WDOS.ABT),A
        RET

; Выбрать безопасную read-only стартовую точку рядом с концом тома. CADE:CAHL
; здесь служит только временной копией limit/16; перед первым SRHFCL курсор всё
; равно заново загружается из FSTFRC.
SET_COLD_FREE_HINT:
        LD HL,(FAT_DATA_CLUSTER_LIMIT),DE,(FAT_DATA_CLUSTER_LIMIT+2)
        LD (@WDOS.FSTFRC),HL
        LD (@WDOS.FSTFRC+2),DE
        LD B,4
.divide:
        SRL D:RR E:RR H:RR L
        DJNZ .divide
        LD (@WDOS.CAHL),HL
        LD (@WDOS.CADE),DE
        LD HL,(@WDOS.FSTFRC),BC,(@WDOS.CAHL)
        OR A:SBC HL,BC
        LD (@WDOS.FSTFRC),HL
        LD HL,(@WDOS.FSTFRC+2),BC,(@WDOS.CADE)
        SBC HL,BC
        LD (@WDOS.FSTFRC+2),HL
        RET

GET_DATA_CLUSTER_LIMIT:
        LD HL,(FAT_DATA_CLUSTER_LIMIT),DE,(FAT_DATA_CLUSTER_LIMIT+2)
        XOR A
        RET

; Для read-only preflight FILEX хранить уже увеличенный CADE:CAHL. Если
; найденный кластер был последним в области данных, следующая подсказка
; безопасно оборачивается к 2. Сам MKSG эту точку не вызывает: его FAT-итератор
; одновременно живёт в альтернативном наборе регистров.
SAVE_NEXT_FREE_HINT:
        PUSH AF,BC,DE,HL
        LD HL,(@WDOS.CAHL),DE,(@WDOS.CADE)
        CALL VALIDATE_FREE_HINT
        JR Z,.store
        LD HL,2:LD DE,0
.store:
        LD (@WDOS.FSTFRC),HL
        LD (@WDOS.FSTFRC+2),DE
        POP HL,DE,BC,AF
        RET

; Освобождение не уничтожает подсказку. Ненулевая голова цепочки гарантированно
; станет свободной после успешной записи FAT и является точной новой позицией.
NOTE_FREED_CHAIN:
        LD HL,(@WDOS.LOBU),DE,(@WDOS.LOBU+2)
        LD A,D:OR E:OR H:OR L:RET Z
        LD (@WDOS.FSTFRC),HL
        LD (@WDOS.FSTFRC+2),DE
; Claude - 2026-09-27 - begin
        ; Кластеры корня для CLASSIFY_DATA (Codex R27-04): до первой правки
        ; SECBU в DLSG. Отказ чтения — ROOT_FAILED≠0: DLSG не освободит ничего.
        JP ROOT_BUILD
; Claude - 2026-09-27 - end

; Позиционировать устройство на сектор DE:HL относительно начала FAT с индексом
; A. После добавления FAT size, reserved sectors и partition base вызывается
; штатный XPOZI.
POSITION_FAT_INDEX:
        OR A:JR Z,.base
.next:
        LD BC,(@WDOS.BFTSZ)
        ADD HL,BC
        EX DE,HL
        LD BC,(@WDOS.BFTSZ+2)
        ADC HL,BC
        EX DE,HL
        DEC A:JR NZ,.next
.base:
        LD BC,(@WDOS.SFAT)
        CALL @WDOS.ADD4B
        CALL @WDOS.XSPOZ
        JP @WDOS.XPOZI

; Позиционирование чтения: при отключённом зеркалировании использовать только
; активную FAT, иначе FAT0.
POSITION_FAT_READ:
        LD A,(@WDOS.FATFLAGS)
        BIT 7,A:JR Z,.fat0
        AND #0F
        JP POSITION_FAT_INDEX
.fat0:
        XOR A
        JP POSITION_FAT_INDEX

; Проверить полный 32-битный относительный сектор FAT в DE:HL.
; CF=1 означает DE:HL < BFTSZ, CF=0 — сектор находится на границе или за ней.
FAT_SECTOR_IN_RANGE:
        PUSH HL,DE
        LD BC,(@WDOS.BFTSZ)
        OR A:SBC HL,BC
        EX DE,HL
        LD BC,(@WDOS.BFTSZ+2)
        SBC HL,BC
        POP DE,HL
        RET

; Записать текущий SECBU/LSTSE в корректные копии FAT. При обычном режиме —
; во все BFATS, при BPB_ExtFlags.bit7 — только в выбранную активную FAT.
SAVE_FAT_SECTOR:
; Claude - 2026-09-21 - begin
        ; FAT меняется: кэш сектора FAT всех страниц недействителен. Сброс до
        ; записи, чтобы и частично неудачная запись не оставила старый кэш.
        CALL @WDOS.FAT_CACHE_BUMP       ; разрушает HL, B, флаги
; Claude - 2026-09-21 - end
        LD A,(@WDOS.FATFLAGS)
        BIT 7,A:JR Z,.mirrored
        AND #0F
        LD HL,(@WDOS.LSTSE),DE,(@WDOS.LSTSE+2)
        CALL POSITION_FAT_INDEX
        LD HL,@WDOS.SECBU,A,1
        JP WRITE_SECTORS

.mirrored:
        LD A,(@WDOS.BFATS)
        OR A:JR Z,.failed
        LD B,A
        XOR A
.copy:
        PUSH BC,AF
        LD HL,(@WDOS.LSTSE),DE,(@WDOS.LSTSE+2)
        CALL POSITION_FAT_INDEX
        LD HL,@WDOS.SECBU,A,1
        CALL WRITE_SECTORS
        POP DE,BC
        RET NZ
        LD A,D
        INC A
        DJNZ .copy
        XOR A
        RET
.failed:
        JP CLASSIFY_ORDINARY

; Состояние полного поиска свободного кластера. DABC:DAHL хранит исходную
; подсказку, DUBA=1 означает, что поиск уже обернулся к кластеру 2.
INIT_FREE_SCAN:
        LD HL,(@WDOS.CAHL)
        LD (@WDOS.DABC),HL
        LD HL,(@WDOS.CADE)
        LD (@WDOS.DAHL),HL
        XOR A:LD (@WDOS.DUBA),A
; Claude - 2026-09-26 - begin
        LD (FREE_SCAN_IO_FAILED),A               ; отказов чтения FAT ещё не было
; Claude - 2026-09-26 - end
        RET

; Проверить текущий CADE:CAHL перед чтением свободного слота. Последний
; сектор FAT может содержать нулевые записи за концом data-области: они не
; являются кластерами. При достижении границы сразу перейти к кластеру 2.
; Выход: CF=1 при полном обороте; HL сохранён либо указывает на новый слот
; после wrap. AF/BC/DE временные; BC'/DE'/HL' сохранены. VALIDATE_FREE_HINT
; через DEL128 также меняет AF', как и обычный переход к сектору FAT.
CHECK_FREE_SCAN_LIMIT:
        PUSH HL
        LD HL,(@WDOS.CAHL),DE,(@WDOS.CADE)
        CALL VALIDATE_FREE_HINT
        JR Z,.valid
        POP HL
        JP NEXT_FREE_FAT_SECTOR.wrap
.valid:
        LD A,(@WDOS.DUBA):OR A:JR Z,.more
        LD DE,(@WDOS.DABC)
        OR A:SBC HL,DE:JR NZ,.more
        LD HL,(@WDOS.CADE),DE,(@WDOS.DAHL)
        OR A:SBC HL,DE:JR NZ,.more
        POP HL
        SCF
        RET
.more:
        POP HL
        OR A
        RET

; Загрузить FAT-сектор текущего CADE:CAHL. Курсор уже увеличен вызывающим
; FC/GETZE. Одинаковый путь нужен после занятого сектора, свободного последнего
; слота и записи очередной порции GENBU: ни один путь не должен обходить wrap.
; ID сохранён для внутренней ABI. На конце области данных разрешён один
; переход к кластеру 2; повторный конец означает отсутствие места.
NEXT_FREE_FAT_SECTOR:
        LD HL,(@WDOS.CAHL),DE,(@WDOS.CADE)
        CALL VALIDATE_FREE_HINT
        JR NZ,.wrap
; Claude - 2026-09-26 - begin
; Чтение сектора FAT. Отказ (CF, ABT≠0) запоминается для MKSG_CHECKED: MKSG
; отдаёт на нём тот же код 16, что и при нехватке места (ERG1; после ERG2
; ещё и DLSG сбрасывает ABT своим обменом). Прежде — JP CURIT.
.read:
        CALL @WDOS.CURIT
        RET NC
        LD A,(@WDOS.ABT)
        LD (FREE_SCAN_IO_FAILED),A
        SCF
        RET
; Claude - 2026-09-26 - end

.wrap:
        LD A,(@WDOS.DUBA):OR A:JR NZ,.full
        LD HL,(@WDOS.DAHL)
        LD A,H:OR L:JR NZ,.do_wrap
        LD HL,(@WDOS.DABC)
        LD A,H:OR A:JR NZ,.do_wrap
        LD A,L:CP 3:JR C,.full
.do_wrap:
        LD A,1:LD (@WDOS.DUBA),A
        LD HL,2:LD (@WDOS.CAHL),HL
        LD HL,0:LD (@WDOS.CADE),HL
        LD DE,0:LD HL,2
        JR .read                                ; прежде JP CURIT
.full:
        SCF
        RET

; Claude - 2026-09-26 - begin
; MKSG для MKFILE, MKDIR и APPEND. Код 16 (ERG1) MKSG отдаёт и при нехватке
; места, и при отказе чтения FAT во время поиска свободного кластера (CF
; SRHFCL/SRHFC). Отказ записан в FREE_SCAN_IO_FAILED — тогда A=#FF, NZ, CF=1,
; как у IO_RESULT: окно F5/F7 пишет «UNKNOWN ERROR!!», а не «Not Enough
; Space!» (Codex R24-02). Прочие исходы — как у MKSG, флаги прежние. Прямой
; вызов MKSG (вход ядра #402A, FILEX) по-прежнему отдаёт 16 в обоих случаях.
MKSG_CHECKED:
        CALL CORE_MKSG                          ; при прерываниях вызывающего
        RET Z                                   ; цепочка записана
.result:                                        ; ALLOCATE_FILE: MKSG уже отказал
        PUSH AF
        CP 16:JR NZ,.keep                       ; иной отказ — как есть
        LD A,(FREE_SCAN_IO_FAILED)
        OR A:JR Z,.keep                         ; нехватка места — как есть
        POP AF
        LD A,#FF:OR A                           ; отказ носителя
        SCF
        RET
.keep:
        POP AF
        RET
; Claude - 2026-09-26 - end

; Сбросить историю секторного окна перед новым поиском по каталогу.
RESET_DIR_HISTORY:
        XOR A
        LD (DIR_OLDER_VALID),A
        RET

; Сохранить реальный LBA предыдущего секторного буфера каталога. Это позволяет
; удалить LFN даже при переходе через границу кластера, где LBA не обязаны быть
; соседними.
SAVE_PREVIOUS_DIR_LBA:
; Codex - 2026-07-16 - begin
        PUSH HL
; Codex - 2026-07-16 - end
        LD HL,(@WDOS.LLHL)
        LD (DIR_PREVIOUS_LBA),HL
        LD HL,(@WDOS.LLHL+2)
        LD (DIR_PREVIOUS_LBA+2),HL
; Codex - 2026-07-16 - begin
        POP HL
; Codex - 2026-07-16 - end
        RET

; Перед сдвигом LOBU2 -> LOBU сохранить ещё более старый сектор. Максимальное
; FAT32-LFN занимает 20 записей, поэтому SFN и весь его LFN-прогон могут
; пересечь три сектора каталога.
PRESERVE_OLDER_DIR_SECTOR:
        PUSH AF,BC,DE,HL
        LD HL,@WDOS.LOBU,DE,DIR_OLDER_BUFFER,BC,512
        LDIR
        LD HL,(DIR_PREVIOUS_LBA)
        LD (DIR_OLDER_LBA),HL
        LD HL,(DIR_PREVIOUS_LBA+2)
        LD (DIR_OLDER_LBA+2),HL
        LD A,1:LD (DIR_OLDER_VALID),A
        POP HL,DE,BC,AF
        RET

; Codex - 2026-07-16 - begin
; Продолжить обратное сравнение максимального LFN в третьем секторе. Обычные
; указатели #3200..#35FF остаются без изменений; переход ниже #3200 допустим
; только на сохранённый последний слот более старого сектора #2000..#21FF.
MAP_OLDER_LFN_POINTER:
        LD A,H:CP high @WDOS.LOBU:JR NC,.ok
        CP high @WDOS.LOBU-1:JR NZ,.bad
        LD A,(DIR_OLDER_VALID):OR A:JR Z,.bad
        LD A,H:SUB #10:LD H,A
.ok:
        OR A
        RET
.bad:
        SCF
        RET
; Codex - 2026-07-16 - end

; Пометить удалёнными SFN и весь связанный LFN-прогон. Проверяются порядковые
; номера LFN и контрольная сумма SFN; поддерживается максимальное имя в 20
; LFN-записей через текущий, предыдущий и более старый сектор.
DELETE_ENTRY_WITH_LFN:
        LD H,B,L,C
        PUSH HL
        CALL @WDOS.LNCRC
        LD (DIR_LFN_CHECKSUM),A
        POP HL
        LD (HL),#E5
        LD A,B:AND #FE
        LD (@WDOS.COUNT),A
        LD D,A
        LD A,1:LD (DIR_EXPECTED_SEQUENCE),A
        XOR A
        LD (DIR_PREVIOUS_DIRTY),A
        LD (DIR_OLDER_DIRTY),A

.current:
        LD BC,0-32:ADD HL,BC
        LD A,H:CP D:JR C,.previous
        CALL .match_lfn:JR NZ,.write
        LD (HL),#E5
        JR C,.write
        JR .current

.previous:
        LD A,D:CP high @WDOS.LOBU2:JR NZ,.write
        LD HL,@WDOS.LOBE-32
.prev_loop:
        CALL .match_lfn:JR NZ,.write
        LD (HL),#E5
        LD A,1:LD (DIR_PREVIOUS_DIRTY),A
        JR C,.write
        LD BC,0-32:ADD HL,BC
        LD A,H:CP high @WDOS.LOBU:JR NC,.prev_loop

        LD A,(DIR_OLDER_VALID):OR A:JR Z,.write
        LD HL,DIR_OLDER_BUFFER+512-32
.older_loop:
        CALL .match_lfn:JR NZ,.write
        LD (HL),#E5
        LD A,1:LD (DIR_OLDER_DIRTY),A
        JR C,.write
        LD BC,0-32:ADD HL,BC
        LD A,H:CP high DIR_OLDER_BUFFER:JR NC,.older_loop

.write:
        LD A,(DIR_OLDER_DIRTY):OR A:JR Z,.write_previous
        LD HL,(DIR_OLDER_LBA),DE,(DIR_OLDER_LBA+2)
        CALL @WDOS.PROZ
        LD HL,DIR_OLDER_BUFFER,A,1
        CALL WRITE_SECTORS
        RET NZ

.write_previous:
        LD A,(DIR_PREVIOUS_DIRTY):OR A:JR Z,.write_current
        LD HL,(DIR_PREVIOUS_LBA),DE,(DIR_PREVIOUS_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL WRITE_SECTORS
        RET NZ

.write_current:
        LD HL,(@WDOS.LLHL),DE,(@WDOS.LLHL+2)
        CALL @WDOS.PROZ
        LD A,(@WDOS.COUNT)
        LD H,A,L,0
        LD A,1
        JP WRITE_SECTORS

.match_lfn:
        PUSH HL,DE
        LD A,(HL):LD D,A
        AND #1F:LD E,A
        LD A,(DIR_EXPECTED_SEQUENCE):CP E:JR NZ,.not_lfn
        LD BC,11:ADD HL,BC
        LD A,(HL):CP #0F:JR NZ,.not_lfn
        INC HL,HL
        LD A,(DIR_LFN_CHECKSUM):CP (HL):JR NZ,.not_lfn
        LD A,(DIR_EXPECTED_SEQUENCE):INC A
        LD (DIR_EXPECTED_SEQUENCE),A
        BIT 6,D:JR NZ,.last_lfn
        POP DE,HL
        XOR A
        RET
.last_lfn:
        POP DE,HL
        XOR A
        SCF
        RET
.not_lfn:
        POP DE,HL
        LD A,1:OR A
        RET

; Безопасно обновить FSInfo: проверить три сигнатуры, пометить Free_Count как
; неизвестный и записать Next_Free (либо #FFFFFFFF для нулевой подсказки).
RFRH_SAFE:
        LD HL,(@WDOS.FSINF),DE,(@WDOS.FSINF+2)
        CALL @WDOS.XPOZI
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        RET NZ

        CALL VALIDATE_FSINFO_SECTOR
        JR NZ,.bad

        LD HL,#FFFF
        LD (@WDOS.LOBU+488),HL
        LD (@WDOS.LOBU+490),HL
        LD HL,(@WDOS.FSTFRC),DE,(@WDOS.FSTFRC+2)
        CALL VALIDATE_FREE_HINT
        JR Z,.have_hint
        LD HL,#FFFF,DE,HL
.have_hint:
        LD (@WDOS.LOBU+492),HL
        LD (@WDOS.LOBU+494),DE
        LD HL,@WDOS.LOBU,A,1
        JP WRITE_SECTORS
.bad:
        LD A,1:OR A
        RET

; Claude - 2026-09-26 - begin
; Сигнатуры FSInfo в LOBU: «RRaA» в +0, «rrAa» в +484, 00 00 55 AA в +508 —
; побайтно по таблице (прежде — шесть сравнений слов, те же значения).
; Выход: Z — сектор FSInfo, NZ — нет. Портит A, B, DE, HL.
VALIDATE_FSINFO_SECTOR:
        LD HL,FSINFO_SIGNATURES
        LD DE,@WDOS.LOBU
        CALL .four
        RET NZ
        LD DE,@WDOS.LOBU+484
        CALL .four
        RET NZ
        LD DE,@WDOS.LOBU+508
.four:
        LD B,4
.byte:
        LD A,(DE)
        CP (HL)
        RET NZ
        INC HL
        INC DE
        DJNZ .byte
        RET                                     ; Z: все четыре совпали

FSINFO_SIGNATURES:
        DB "RRaA","rrAa",0,0,#55,#AA
; Claude - 2026-09-26 - end

; Общий выход потоковой операции при ошибке драйвера. Адрес/сектор потока ещё
; не продвинуты; EOC=#FF заставляет вызывающий код остановиться.
STREAM_IO_ERROR:
        LD A,#FF
        LD (@WDOS.ABT),A
        LD (@WDOS.EOC),A
; Codex - 2026-07-16 - begin
        ; Отличить ошибку I/O от штатного достижения EOC=#FF.
        SCF
; Codex - 2026-07-16 - end
        RET

; Codex - 2026-07-16 - begin
; Codex - 2026-07-17 - begin
; Все четыре блока распаковываются одинаково. SD-ZC уже упакован из конечного
; проверенного runtime, поэтому прежняя большая таблица наложения не нужна.
DSDZC_RUNTIME_READS EQU #393F
DSDZC_RUNTIME_CSH   EQU #3B17
DSDZC_RUNTIME_CMD18 EQU #3BB5
DSDZC_RUNTIME_CMD25 EQU #3BEA
DSDZC_RUNTIME_WAIT  EQU #3C6D

UNPACK_DRIVER:
        PUSH BC
; Claude - 2026-09-27 - begin
        ; Драйверы с установки лежат в DRIVERS_E8 этой страницы, а DOS_SWP
        ; передаёт прежний адрес в ядре (DR1..DR4 с #5176): тот же сдвиг.
        LD BC,DRIVERS_E8-@WDOS.DR1
        ADD HL,BC
; Claude - 2026-09-27 - end
        CALL @WDOS.DEHR
        POP BC
        LD A,B
        RET
; Codex - 2026-07-17 - end

; Боевой CORE32 распаковывает точный штатный DOSpSDZC35.CPD и не вызывает эти
; экспериментальные точки. Их реализация и дополнительные номера шлюза
; добавляются только специальной диагностической сборкой.
        IFDEF WDOS_EXPERIMENTAL_ZC_RUNTIME

; Общий аварийный выход SD-ZC: зафиксировать ошибку и снять chip-select.
ZC_MARK_ERROR:
        LD A,1
        LD (@WDOS.ABT),A
        CALL DSDZC_RUNTIME_CSH
        LD A,1
        OR A
        RET

; WAIT: дождаться #FF с конечным лимитом. Исходный AF восстанавливается,
; поскольку старые командные процедуры не использовали флаги WAIT.
ZC_WAIT_READY:
        PUSH AF,BC,DE,HL
        LD E,8
.outer:
        LD HL,0
        LD BC,#0057
.poll:
        IN A,(C)
        INC A
        JR Z,.ready
        DEC HL
        LD A,H:OR L
        JR NZ,.poll
        DEC E
        JR NZ,.outer
        CALL ZC_MARK_ERROR
.ready:
        POP HL,DE,BC,AF
        RET

; WTDO: дождаться первого байта, отличного от #FF. При тайм-ауте возвращается
; #FF, ABT устанавливается, а chip-select снимается.
ZC_WAIT_TOKEN:
        PUSH BC,DE,HL
        LD E,8
.outer:
        LD HL,0
        LD BC,#0057
.poll:
        IN A,(C)
        CP #FF
        JR NZ,.received
        DEC HL
        LD A,H:OR L
        JR NZ,.poll
        DEC E
        JR NZ,.outer
        CALL ZC_MARK_ERROR
        POP HL,DE,BC
        LD A,#FF
        OR A
        RET
.received:
        POP HL,DE,BC
        RET

; WTBY: дождаться снятия busy. Z означает успех, NZ — конечный тайм-аут.
ZC_WAIT_BUSY:
        PUSH BC,DE,HL
        LD E,8
.outer:
        LD HL,0
        LD BC,#0057
.poll:
        IN A,(C)
        OR A
        JR NZ,.ready
        DEC HL
        LD A,H:OR L
        JR NZ,.poll
        DEC E
        JR NZ,.outer
        CALL ZC_MARK_ERROR
        POP HL,DE,BC
        LD A,1
        OR A
        RET
.ready:
        POP HL,DE,BC
        XOR A
        RET

; Проверить ответ записи и дождаться снятия busy. При успехе счётчик блоков
; переносится из AF' в AF, как это делал прежний участок SDDSE.
ZC_DATA_RESPONSE:
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        CALL ZC_WAIT_TOKEN
        LD C,A
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        LD A,C:AND #1F:CP 5:JR NZ,.mark
        CALL ZC_WAIT_BUSY
        JR NZ,.failed
        EX AF,AF'
        CP A
        RET
.mark:
        CALL ZC_MARK_ERROR
.failed:
        LD A,1
        OR A
        RET

; Ограничить оба ожидания DMA. A сохраняется, CF=1 означает тайм-аут.
ZC_DMA_WAIT:
; Codex - 2026-07-16 - begin
; BC намеренно не восстанавливается: исходная последовательность оставляла
; BC=#27AF, и следующий OUT меняет только B, сохраняя обязательный C=#AF.
        PUSH AF,DE
        LD BC,#27AF
        LD DE,0
.poll:
        INF
        JP P,.ready
        DEC DE
        LD A,D:OR E
        JR NZ,.poll
        CALL ZC_MARK_ERROR
        POP DE,AF
        SCF
        RET
.ready:
        POP DE,AF
        OR A
        RET
; Codex - 2026-07-16 - end

; Начать многоблочное чтение. Счётчик остаётся в AF'; Z означает готовность.
ZC_START_READ:
        XOR A
        LD (@WDOS.ABT),A
        CALL DSDZC_RUNTIME_CMD18
        LD C,A
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        LD A,C:OR A:JR NZ,.mark
        XOR A
        RET
.mark:
        CALL ZC_MARK_ERROR
.failed:
        LD A,1
        OR A
        RET

; Прочитать блок штатной процедурой с уже ограниченными DMA-ожиданиями.
; При успехе вернуть счётчик из AF' и Z, при ошибке оставить AF' нетронутым.
ZC_READ_BLOCK:
        CALL DSDZC_RUNTIME_READS
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        EX AF,AF'
        CP A
        RET
.failed:
        CALL DSDZC_RUNTIME_CSH
        LD A,1
        OR A
        RET

; Проверить аппаратный запрет записи и одновременно начать новый результат I/O.
ZC_WRITE_READY:
        XOR A
        LD (@WDOS.ABT),A
        IN A,(#77)
        AND 2
        JR NZ,.failed
        XOR A
        RET
.failed:
        JP ZC_MARK_ERROR

; Начать многоблочную запись и дождаться готовности к первому блоку. При успехе
; счётчик переносится из AF' в AF для существующего цикла SDDSE.
ZC_START_WRITE:
        CALL DSDZC_RUNTIME_CMD25
        LD C,A
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        LD A,C:OR A:JR NZ,.mark
        CALL DSDZC_RUNTIME_WAIT
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        EX AF,AF'
        CP A
        RET
.mark:
        CALL ZC_MARK_ERROR
.failed:
        LD A,1
        OR A
        RET

; Токен данных чтения обязан быть #FE. Любой иной ответ завершает операцию.
ZC_CHECK_TOKEN:
        CP #FE
        JR NZ,.failed
        XOR A
        RET
.failed:
        JP ZC_MARK_ERROR
; Codex - 2026-07-16 - end

        ENDIF

; Claude - 2026-09-27 - begin
; EXT_INSTALL_TAIL (ID_INSTALL_TAIL; только установщик boot.$C, страница #E8 в
; окне #C000, обе части распакованы): упакованные драйверы ядра #5176..#5AA9 —
; в DRIVERS_E8, на их место — резидентный блок. Порядок важен: блок затирает
; драйверы.
EXT_INSTALL_TAIL:
        LD HL,@WDOS.DR1
        LD DE,DRIVERS_E8
        LD BC,DRIVERS_LENGTH
        LDIR
        LD HL,RESIDENT_SOURCE
        LD DE,RESIDENT_BASE
        LD BC,RESIDENT_LENGTH
        LDIR
        RET
DRIVERS_LENGTH                EQU @WDOS.DEHR-@WDOS.DR1
        ASSERT RESIDENT_BASE == @WDOS.DR1, резидентный блок не на месте драйверов

; Резидентный блок: код, который исполняется при снятой странице расширения,
; — в странице ядра #05 (всегда в окне #4000). Собран для RESIDENT_BASE,
; хранится здесь; EXT_INSTALL_TAIL копирует его на место драйверов.
;
; CORE_MKSG, CORE_SRHFCL (Codex R29-01): MKSG и SRHFCL — поиск свободного
; кластера, до ~2330 тактов на запись FAT, — из функций расширения (MKDIR,
; APPEND, рост каталога DIR_GROW) шли внутри шлюза, то есть при DI: на почти
; полном томе минуты без прерываний. Теперь на время поиска #E8 снимается: в
; окно #C000 возвращается страница внешнего вызывающего и его IFF
; (OUTER_PAGE/OUTER_IFF, их записывает GATE_CONTINUE при входе в шлюз не из
; расширения), процедура ядра исполняется при его прерываниях, а её вложенные
; вызовы шлюза подключают #E8 сами. Затем DI и снова #E8. Оба набора
; регистров проходят насквозь.
RESIDENT_SOURCE:
        DISP RESIDENT_BASE
RESIDENT_START:
OUTER_PAGE:     DB 0                    ; страница окна #C000 внешнего вызова
OUTER_IFF:      DB 0                    ; ≠0 — прерывания у него разрешены
CORE_MKSG:
        CALL LEAVE_EXT
        CALL @WDOS.MKSG
        JR ENTER_EXT
CORE_SRHFCL:
        CALL LEAVE_EXT
        CALL @WDOS.SRHFCL
ENTER_EXT:                              ; назад в расширение: DI, затем #E8
        DI
        PUSH AF
        PUSH BC
        LD A,@WC_PHYS_CORE32_EXT_PAGE
        LD BC,#13AF
        OUT (C),A
        POP BC
        POP AF
        RET
LEAVE_EXT:                              ; наружу: страница, затем IFF вызывающего
        PUSH AF
        PUSH BC
        LD A,(OUTER_PAGE)
        LD BC,#13AF
        OUT (C),A
        LD A,(OUTER_IFF)
        OR A
        POP BC
        JR Z,.keep_di
        POP AF
        EI
        RET
.keep_di:
        POP AF
        RET
RESIDENT_END:
        ENT
RESIDENT_LENGTH               EQU RESIDENT_END-RESIDENT_START
        ASSERT RESIDENT_BASE+RESIDENT_LENGTH <= @WDOS.DEHR, резидентный блок налез на DEHR
; Claude - 2026-09-27 - end

; Геометрия FAT32 и временное состояние подсказки аллокатора. Верхняя граница
; является исключительной: допустимы кластеры 2..limit-1.
; Claude - 2026-09-25 - begin
; Граница — свойство тома, а не страницы расширения: прежде одна ячейка здесь
; служила всем панелям, и после монтирования большего тома на другом
; устройстве аллокатор меньшего выдавал кластеры за концом его раздела. Теперь
; она лежит в странице потока рядом с FSTFRC/SDFAT (поле RECCAT драйвера, не
; используемое ни ядром, ни драйверами), своя у каждой панели и её клона.
FAT_DATA_CLUSTER_LIMIT        EQU @WDOS.RECCAT
; Claude - 2026-09-25 - end

; Последняя запись, найденная FENTRY (TENTRY): поток (страница окна #0000),
; адрес имени, по которому её искали, и копия этого имени.
FOUND_STREAM:                 DS 1
FOUND_NAME:                   DS 2
FOUND_TEXT:                   DS 256

; RENAME: место короткой записи прежнего имени (смещение #FFFF — неизвестно).
; Новое имя после SVHDFL — в NXTBU ядра. ENTRY_LANDED хранит FCTS на время
; поиска; DIR_ALIVE — кластер каталога и его родителя.
RENAME_OLD_LBA:               DS 4
RENAME_OLD_OFFSET:            DS 2
LANDED_CLUSTER:               DS 4
DIR_ALIVE_CLUSTER:            DS 4
DIR_ALIVE_PARENT:             DS 4
RENAME_ATTR:                  DS 1
RENAME_OFFSET:                DS 2
RENAME_LBA:                   DS 4

; Поля часов CMOS в двоичном виде: секунды, минуты, часы, день, месяц, год;
; второй снимок для сверки.
RTC_VALUES:                   DS 6
RTC_CHECK:                    DS 6

; Цифры размера для строки информации, младшая первой.
STATUS_DIGITS:                DS 10
STATUS_NARROW:                DS 1                ; #FF — строка в 38 знаков, 0 — в 43
        ; Последний байт таблицы — RTC_FIELDS+17: при начале с #xxEE она
        ; кончается на #xxFF, добивка (условие > 256-18) не нужна.
        ASSERT high RTC_FIELDS == high (RTC_FIELDS+17), конец полей ловится по младшему байту

; Codex - 2026-07-17 - begin
; Постоянный контекст APPEND хранится в выделенной странице расширения и не
; занимает рабочие буферы CORE32. Рабочая копия меняется во время вызова и
; становится постоянной только после успешной записи каталожной ENTRY.
APPEND_VALID:                 DS 1
APPEND_READY:                 DS 1
APPEND_FOUND_POINTER:         DS 2
APPEND_DIRECTORY_LBA:         DS 4
APPEND_DIRECTORY_OFFSET:      DS 2
APPEND_ENTRY:                 DS 32

APPEND_CONTEXT:
APPEND_SIZE:                  DS 4
APPEND_FIRST_CLUSTER:         DS 4
APPEND_CURRENT_CLUSTER:       DS 4
APPEND_SECTOR:                DS 1
APPEND_OFFSET:                DS 2
APPEND_NEEDS_CLUSTER:         DS 1
; Codex - 2026-07-28 - begin
; Постоянный ключ и значение LBA-кэша. Ключ защищает межвызовное
; переиспользование от смены кластера и параметров отображения FAT.
APPEND_LBA_VALID:             DS 1
APPEND_LBA_CLUSTER:           DS 4
APPEND_LBA_BSECPC:            DS 1
APPEND_LBA_SDFAT:             DS 4
APPEND_LBA_ADDTOP:            DS 4
APPEND_LBA:                   DS 4
; Codex - 2026-07-28 - end
APPEND_CONTEXT_END:
APPEND_CONTEXT_SIZE           EQU APPEND_CONTEXT_END-APPEND_CONTEXT

APPEND_WORK_CONTEXT:
APPEND_WORK_SIZE:             DS 4
APPEND_WORK_FIRST:            DS 4
APPEND_WORK_CURRENT:          DS 4
APPEND_WORK_SECTOR:           DS 1
APPEND_WORK_OFFSET:           DS 2
APPEND_WORK_NEEDS_CLUSTER:    DS 1
; Codex - 2026-07-28 - begin
APPEND_WORK_LBA_VALID:        DS 1
APPEND_WORK_LBA_CLUSTER:      DS 4
APPEND_WORK_LBA_BSECPC:       DS 1
APPEND_WORK_LBA_SDFAT:        DS 4
APPEND_WORK_LBA_ADDTOP:       DS 4
APPEND_WORK_LBA:              DS 4
; Codex - 2026-07-28 - end
        ASSERT $-APPEND_WORK_CONTEXT == APPEND_CONTEXT_SIZE, различается контекст APPEND

APPEND_SOURCE:                DS 2
APPEND_REMAINING:             DS 2
APPEND_CHUNK:                 DS 2
; Codex - 2026-07-27 - begin
APPEND_RUN:                   DS 1
; Codex - 2026-07-27 - end
APPEND_SKIP_COUNT:            DS 4
APPEND_PENDING_NEW:           DS 1
APPEND_LINKED_NEW:            DS 1
; Codex - 2026-07-27 - begin
APPEND_NEW_ACTIVE:            DS 1
; Codex - 2026-07-27 - end
APPEND_PENDING_OLD_TAIL:      DS 4
APPEND_NEW_CLUSTER:           DS 4
APPEND_OLD_LINK:              DS 4
APPEND_FAT_POINTER:           DS 2
APPEND_SLOT_POINTER:          DS 2
APPEND_LAST_ERROR:            DS 1
; Claude - 2026-09-25 - begin
APPEND_NEW_ENTRY:             DS 32               ; запись каталога после дозаписи
APPEND_DIR_ATTEMPTED:         DS 1                ; 1 — запись каталога начата
; Claude - 2026-09-25 - end
; Claude - 2026-09-26 - begin
FREE_SCAN_IO_FAILED:          DS 1                ; ≠0 — поиск места отказал на чтении FAT
; Claude - 2026-09-26 - end
; Claude - 2026-09-27 - begin
DIR_CHAIN_LEFT:               DS 2                ; DIR_CHAIN: секторов в запасе
DIR_CHAIN_READ:               DS 1                ; ≠0 — сектор FAT в обходе уже читан
FILE_CHAIN_LEFT:              DS 4                ; FILE_CHAIN: кластеров данных осталось
FILE_CHAIN_CUR:               DS 4                ; FILE_CHAIN: кластер после порции
; Claude - 2026-09-27 - end
; Codex - 2026-07-17 - end

; Служебное состояние лежит в сохранённом нулевом промежутке CORE32.
; Секторный буфер #2000 остаётся в штатном файловом окне #0000; код расширения
; исполняется независимо в окне #C000.
LFN_LEADING            EQU @WDOS.EXT_LFN_LEADING
DIR_PREVIOUS_LBA       EQU @WDOS.EXT_DIR_PREVIOUS_LBA
DIR_OLDER_LBA          EQU @WDOS.EXT_DIR_OLDER_LBA
DIR_OLDER_VALID        EQU @WDOS.EXT_DIR_OLDER_VALID
DIR_PREVIOUS_DIRTY     EQU @WDOS.EXT_DIR_PREVIOUS_DIRTY
DIR_OLDER_DIRTY        EQU @WDOS.EXT_DIR_OLDER_DIRTY
DIR_EXPECTED_SEQUENCE  EQU @WDOS.EXT_DIR_EXPECTED_SEQUENCE
DIR_LFN_CHECKSUM       EQU @WDOS.EXT_DIR_LFN_CHECKSUM
DIR_OLDER_BUFFER       EQU #2000

; Claude - 2026-09-27 - begin
; Упакованные драйверы ядра (DR1..DR4): сюда их переносит EXT_INSTALL_TAIL,
; отсюда распаковывает UNPACK_DRIVER. В потоке части 2 — одни нули.
DRIVERS_E8:                   DS DRIVERS_LENGTH
; Claude - 2026-09-27 - end

RUNTIME_END:
        ASSERT RUNTIME_END <= #10000, расширение вышло за пределы физической страницы
; Claude - 2026-09-27 - begin
; Рабочие таблицы без начальных значений — за концом распакованного
; расширения, в поток boot.$C не входят. Заполняются перед каждым
; использованием (ROOT_BUILD, DIR_CHAIN, ALIAS_RESET, ALIAS_SCAN с A=0).
ROOT_MAX                      EQU 768
ROOT_FAILED                   EQU RUNTIME_END          ; ≠0 — FAT корня не прочиталась
ROOT_COUNT                    EQU ROOT_FAILED+1        ; 2 байта
ROOT_FILTER                   EQU ROOT_COUNT+2         ; 256 байт: бит (кластер & 2047)
ROOT_CLUSTERS                 EQU ROOT_FILTER+256      ; по 4 байта
DIR_CHAIN_SUB                 EQU ROOT_CLUSTERS+ROOT_MAX*4 ; ≠0 — DIR_CHAIN подкаталога
ALIAS_SLOTS                   EQU 512
ALIAS_LOAD                    EQU ALIAS_SLOTS/2
ALIAS_PORTION_SECTORS         EQU 16
ALIAS_USED                    EQU DIR_CHAIN_SUB+1      ; занятых слотов
ALIAS_KEY                     EQU ALIAS_USED+2         ; искомый кластер
ALIAS_LEFT                    EQU ALIAS_KEY+4          ; секторов до предела
ALIAS_PORTION                 EQU ALIAS_LEFT+2         ; секторов до конца порции
ALIAS_STEPS                   EQU ALIAS_PORTION+1      ; 2 байта: кластеров хвоста до предела
ALIAS_RESUME                  EQU ALIAS_STEPS+2        ; ≠0 — хвост каталога продолжится
ALIAS_NEXT                    EQU ALIAS_RESUME+1       ; 4 байта: с какого кластера
ALIAS_OWNER                   EQU ALIAS_NEXT+4         ; 4 байта: первый кластер каталога
ALIAS_TABLE                   EQU ALIAS_OWNER+4        ; по 6 байт на слот
BSS_END                       EQU ALIAS_TABLE+ALIAS_SLOTS*6
        ASSERT BSS_END <= #10000, рабочие таблицы вышли за страницу #E8
        ASSERT (ALIAS_SLOTS & (ALIAS_SLOTS-1)) == 0, число слотов — степень двойки
; Claude - 2026-09-27 - end
; Codex - 2026-07-16 - end
