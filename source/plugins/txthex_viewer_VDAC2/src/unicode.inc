        INCLUDE "decoder.inc"

; Однобайтовые кодировки переводятся прямо в Unicode. CP1251 не проходит
; через CP866: сербские, македонские, украинские буквы и типографика сохраняются.
Byte866:
        CP #80
        JR NC,.table
        LD E,A
        LD D,0
        OR A
        RET
.table:
        LD HL,Unicode866
ByteTable:
        SUB #80
        LD E,A
        LD D,0
        ADD HL,DE
        ADD HL,DE
        LD E,(HL)
        INC HL
        LD D,(HL)
        OR A
        RET

; DE=Unicode -> HL=номер глифа. ASCII находится без подкачки страницы.
; Для Latin/Greek/Cyrillic до U+05FF в странице 1 есть прямой индекс.
; Остальные коды ищутся двоичным поиском в той же странице.
; Для неизвестного символа возвращаем отдельный U+FFFD, без изменения файла.
LookupGlyph:
        LD A,D
        OR A
        JR NZ,.lookup
        LD A,E
        SUB 32
        CP 95
        JR NC,.lookup
        LD L,A
        LD H,0
        RET
.lookup:
        LD A,D
        CP FAST_GLYPH_HIGH
        JR NC,.binary
        ; Data_Page сохраняет DE. Таблица содержит и отсутствующие коды:
        ; им соответствует U+FFFD, поэтому быстрый путь не меняет Unicode.
        LD A,1
        CALL Data_Page
        EX DE,HL
        ADD HL,HL
        LD BC,FAST_GLYPH_TABLE
        ADD HL,BC
        LD A,(HL)
        INC HL
        LD H,(HL)
        LD L,A
        RET
.binary:
        LD (Wanted),DE
        LD A,1
        CALL Data_Page
        LD BC,0
        LD DE,FONT_CODE_COUNT
.loop:
        LD H,B
        LD L,C
        OR A
        SBC HL,DE
        JR NC,.missing
        ADD HL,DE
        ADD HL,DE
        SRL H
        RR L
        LD (Mid),HL
        ADD HL,HL
        LD A,(HL)
        INC HL
        LD H,(HL)
        LD L,A
        PUSH DE
        LD DE,(Wanted)
        OR A
        SBC HL,DE
        POP DE
        JR C,.greater
        JR Z,.found
        LD DE,(Mid)
        JR .loop
.greater:
        LD BC,(Mid)
        INC BC
        JR .loop
.found:
        LD HL,(Mid)
        RET
.missing:
        LD HL,GLYPH_REPLACEMENT
        RET

; Одна экранная клетка: буква и её канонические диакритики U+0300..036F.
; Перед композициями выполняется только PeekByte; обычный ASCII не декодируем
; дважды. При неподдержанном сочетании откатываем LE32 Position к началу знака.
; Возврат: CF=EOF, A=ASCII-разделитель или 32, HL=глиф. Кириллическая U+040D
; не превращается в CR: управляющие коды проверяются со старшим байтом Unicode.
ReadCluster:
        CALL ReadChar
        RET C
        LD DE,(Decoded)
        LD A,D
        OR A
        JR NZ,.letter
        LD A,E
        CP 32
        JR C,.control
        CP 127
        JR Z,.dot
.letter:
        CALL LookupGlyph
        LD (Cluster),HL
        LD A,(Encoding)
        CP 2
        JR NZ,.done
.mark:
        CALL PeekByte
        JR C,.done
        CP #CC
        JR Z,.maybe
        CP #CD
        JR NZ,.done
.maybe:
        LD HL,Position
        LD DE,MarkPosition
        CALL Copy32
        CALL ReadChar
        JR C,.restore
        LD HL,(Decoded)
        LD A,H
        CP 3
        JR NZ,.restore
        LD A,L
        CP #70
        JR NC,.restore
        CALL ComposeGlyph
        JR NC,.restore
        LD (Cluster),HL
        JR .mark
.restore:
        LD HL,MarkPosition
        LD DE,Position
        CALL Copy32
.done:
        LD HL,(Cluster)
        LD A,32
        OR A
        RET
.control:
        CP 9
        RET Z
        CP 10
        RET Z
        CP 13
        RET Z
.dot:
        LD HL,"."-32
        LD A,32
        OR A
        RET

; Поиск пары (Cluster, Decoded), записи по 6 байтов. CF=1 означает найденную
; композицию. Номера синтетических ударных букв находятся после Unicode-глифов.
ComposeGlyph:
        LD A,1
        CALL Data_Page
        LD BC,0
        LD DE,COMPOSE_COUNT
.loop:
        LD H,B
        LD L,C
        OR A
        SBC HL,DE
        JR NC,.missing
        ADD HL,DE
        ADD HL,DE
        SRL H
        RR L
        LD (Mid),HL
        PUSH DE
        ADD HL,HL
        LD D,H
        LD E,L
        ADD HL,HL
        ADD HL,DE
        LD DE,COMPOSE_TABLE
        ADD HL,DE
        LD A,(HL)
        INC HL
        LD D,(HL)
        LD E,A
        INC HL
        PUSH HL
        EX DE,HL
        LD DE,(Cluster)
        OR A
        SBC HL,DE
        POP HL
        JR NZ,.compared
        LD A,(HL)
        INC HL
        LD D,(HL)
        LD E,A
        INC HL
        PUSH HL
        EX DE,HL
        LD DE,(Decoded)
        OR A
        SBC HL,DE
        POP HL
        JR NZ,.compared
        LD A,(HL)
        INC HL
        LD H,(HL)
        LD L,A
        POP DE
        SCF
        RET
.compared:
        POP DE
        JR C,.greater
        LD DE,(Mid)
        JR .loop
.greater:
        LD BC,(Mid)
        INC BC
        JR .loop
.missing:
        OR A
        RET
