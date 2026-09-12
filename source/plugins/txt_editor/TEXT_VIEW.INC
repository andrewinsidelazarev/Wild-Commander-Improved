; AlexKorochinskiy / 2026-09-12
; Просмотр текста без изменения его байтов. CR, LF и CRLF завершают строку;
; Tab занимает клетки до следующей позиции, кратной восьми. Остальные
; управляющие байты показываются пробелами, но сохраняются как были.
;
; Адрес текста: слово смещения #0000..#3FFF и номер страницы #00..#3F.
; LHLCR указывает за левую часть, RHLCR — перед правой частью зазора.
; Только итератор допускает #40:0000 как EOF; подключать эту страницу нельзя.
; Колонки CURCOL, TARGETCOL, HSCROLL и COL_NOW — обычные числа LE24,
; а не адреса страниц. Даже строка из миллиона Tab не переполняет LE24.

; Сброс кэша обязателен после любой чужой процедуры переключения окна #0000.
; Все процедуры итератора меняют AF/BC/DE/HL; IX (окно редактора) сохраняется.
PTR_RESET LD A,#FF,(PTR_PAGE),A:RET

; Чтение физического адреса LNHLP. C: A=байт; NC: EOF, память не читается.
PTR_PEEK LD A,(LNHLP+2):CP PGM+1:RET NC
         LD B,A,A,(PTR_PAGE):CP B:JR Z,PTR_MAPPED
         LD A,B,(PTR_PAGE),A:CALL MNG0VPL
PTR_MAPPED LD HL,(LNHLP),A,(HL):SCF:RET

; Перейти к следующему физическому байту; #40:0000 остаётся неподвижным EOF.
PTR_NEXT LD A,(LNHLP+2):CP PGM+1:RET NC
         LD HL,(LNHLP):INC HL:BIT 6,H:JR Z,PTR_NEXT_STORE
         RES 6,H:INC A:LD (LNHLP+2),A
PTR_NEXT_STORE LD (LNHLP),HL:RET

; Шаг назад и чтение. На BOF возвращает NC, оставляя указатель на нуле.
PTR_BACK LD HL,(LNHLP),A,H:OR L:JR NZ,PTR_BACK_BYTE
         LD A,(LNHLP+2):OR A:RET Z
         DEC A:LD (LNHLP+2),A:LD HL,#4000
PTR_BACK_BYTE DEC HL:LD (LNHLP),HL:JP PTR_PEEK

; Чтение логического текста: зазор пропускается целиком. PTR_GAP сообщает
; рисованию, что здесь находится курсор, в том числе при пустом файле/EOF.
TEXT_PEEK LD HL,(LNHLP),DE,(LHLCR):OR A:SBC HL,DE:JR NZ,PTR_PEEK
          LD A,(LNHLP+2),B,A,A,(LHLCR+2):CP B:JR NZ,PTR_PEEK
          LD A,1,(PTR_GAP),A
          LD HL,RHLCR,DE,LNHLP,BC,3:LDIR
          CALL PTR_NEXT:JP PTR_PEEK

; После CR поглощаем только настоящий LF. TEXT_PEEK перескакивает через
; зазор даже при простом просмотре следующего байта. Если это не LF, надо
; вернуть исходный адрес: иначе начало следующей строки уже оказывается
; справа от зазора и рисование больше не обнаруживает там курсор.
; Это относится и к последнему CR файла, и к пустым строкам внутри текста.
SKIP_OPTIONAL_LF LD HL,(LNHLP),A,(LNHLP+2):PUSH HL,AF
                 CALL TEXT_PEEK:JR NC,OPTIONAL_LF_RESTORE
                 CP 10:JR NZ,OPTIONAL_LF_RESTORE
                 POP AF,HL:JP PTR_NEXT
OPTIONAL_LF_RESTORE POP AF,HL
                    LD (LNHLP),HL,(LNHLP+2),A:RET

; A=исходный байт -> B=число экранных клеток (1 либо остаток Tab до 8).
CELL_WIDTH LD B,1:CP 9:RET NZ
           LD A,(COL_NOW):AND 7:LD B,A,A,8:SUB B:LD B,A:RET
COL_INCREMENT LD HL,COL_NOW:INC (HL):RET NZ
              INC HL:INC (HL):RET NZ
              INC HL:INC (HL):RET
COL_ADD_CHAR CALL CELL_WIDTH
COL_ADD_LOOP CALL COL_INCREMENT:DJNZ COL_ADD_LOOP:RET

; Найти начало строки слева от курсора, затем посчитать её экранную колонку.
; Ни одного байта через зазор не переносим: подсчёт не может изменить файл.
; Результат: LINESTART и CURCOL. Чтение ограничено левой частью [0,LHLCR).
MEASURE_CURSOR CALL PTR_RESET
               LD HL,LHLCR,DE,LNHLP,BC,3:LDIR
MEASURE_BACK CALL PTR_BACK:JR NC,MEASURE_START
             CP 13:JR Z,MEASURE_AFTER_EOL
             CP 10:JR NZ,MEASURE_BACK
MEASURE_AFTER_EOL CALL PTR_NEXT
MEASURE_START LD HL,LNHLP,DE,LINESTART,BC,3:LDIR
              LD HL,0,(COL_NOW),HL:XOR A:LD (COL_NOW+2),A
MEASURE_LOOP LD HL,(LNHLP),DE,(LHLCR):OR A:SBC HL,DE:JR NZ,MEASURE_BYTE
             LD A,(LNHLP+2),B,A,A,(LHLCR+2):CP B:JR Z,MEASURE_DONE
MEASURE_BYTE CALL PTR_PEEK,COL_ADD_CHAR,PTR_NEXT:JR MEASURE_LOOP
MEASURE_DONE LD HL,COL_NOW,DE,CURCOL,BC,3:LDIR
             RET

; Горизонтальное окно сдвигается ровно настолько, чтобы курсор был виден.
; После Home колонка 0 одновременно возвращает левую границу к началу.
ADJUST_HORIZONTAL LD HL,(CURCOL),DE,(HSCROLL):OR A:SBC HL,DE
                  LD A,(HSCROLL+2),B,A,A,(CURCOL+2):SBC A,B
                  JR C,SCROLL_TO_CURSOR
                  OR A:JR NZ,SCROLL_RIGHT
                  LD A,H:OR A:JR NZ,SCROLL_RIGHT
                  LD A,L:CP (IX+4):RET C
SCROLL_RIGHT LD HL,(CURCOL),A,(IX+4):DEC A:LD E,A,D,0
             OR A:SBC HL,DE:LD (HSCROLL),HL
             LD A,(CURCOL+2):SBC A,0:LD (HSCROLL+2),A:RET
SCROLL_TO_CURSOR LD HL,CURCOL,DE,HSCROLL,BC,3:LDIR:RET

; После горизонтального движения/редактирования запоминаем полную колонку.
; Вертикальное движение её не меняет: короткая промежуточная строка не должна
; заставлять следующий Down забывать исходную позицию в длинной строке.
SYNC_COLUMN LD HL,CURCOL,DE,TARGETCOL,BC,3:LDIR
            LD A,(CURCOL),(CRX),A:RET

; Если удалён перенос перед верхней строкой, её новое начало уже раньше PGHLP.
; Не оставляем экран посреди склеенной строки и не меняем сам текст.
CLAMP_VIEW LD A,(PGHLP+2),B,A,A,(LINESTART+2):CP B:JR C,VIEW_TO_LINE
           RET NZ
           LD HL,(LINESTART),DE,(PGHLP):OR A:SBC HL,DE:RET NC
VIEW_TO_LINE LD HL,LINESTART,DE,PGHLP,BC,3:LDIR:RET

; Снимок перед одиночным движением (стрелки/Home/End). Текст не меняется,
; поэтому при прежних границах окна достаточно перенести один атрибут
; курсора. Перерисовка тысяч клеток на каждый шаг занимала миллионы тактов
; и давала заметное мигание и потерю быстрых нажатий.
NAV_BEGIN LD HL,PGHLP,DE,NAV_PAGE,BC,3:LDIR
          LD HL,HSCROLL,DE,NAV_SCROLL,BC,3:LDIR
          LD HL,LINESTART,DE,NAV_LINE,BC,3:LDIR
          LD A,(CRP+1),(NAV_ROW),A:RET

; При изменении выделения или горизонтальной прокрутки нужен REFRESH.
; Вертикальная прокрутка на одну строку переносит уже готовые клетки.
; Одиночный шаг может перейти только на соседнюю строку; сравнение начал
; строк отличает такой переход от движения внутри строки и упора в BOF/EOF.
NAV_REFRESH LD A,(MARKED),B,A,A,(REFFLG):OR B:JP NZ,REFRESH
            LD A,(CRFLG):OR A:JP Z,REFRESH
            CALL MEASURE_CURSOR,ADJUST_HORIZONTAL,CLAMP_VIEW
            LD HL,HSCROLL,DE,NAV_SCROLL:CALL NAV_COMPARE:JP NZ,REFRESH
            LD HL,LINESTART,DE,NAV_LINE:CALL NAV_COMPARE:JR Z,NAV_SAME_ROW
            LD A,(NAV_LINE+2),B,A,A,(LINESTART+2):CP B:JR NZ,NAV_ROW_ORDER
            LD HL,(LINESTART),DE,(NAV_LINE):OR A:SBC HL,DE
NAV_ROW_ORDER LD HL,NAV_ROW:JR C,NAV_PREVIOUS_ROW
              INC (HL):JR NAV_SAME_ROW
NAV_PREVIOUS_ROW DEC (HL)
NAV_SAME_ROW LD HL,PGHLP,DE,NAV_PAGE:CALL NAV_COMPARE:JR NZ,NAV_SCROLL_SCREEN
             LD A,(NAV_ROW):CP LNZ:JP C,REFRESH
             INC A:CP (IX+5):JP NC,REFRESH
             LD A,(NAV_ROW),D,A,E,0:LD (XY),DE
             CALL GADRW:LD (ROWADDR),HL
             LD HL,(CURSOR_ADDR),A,(CURSOR_ATTR),(HL),A
             LD HL,CURCOL,DE,COL_NOW,BC,3:LDIR
             CALL VIEW_CURSOR:JP CURTAT

; Переносим строки в безопасном направлении, отдельно символы и атрибуты.
; Сначала снимаем старый курсор, чтобы его инверсия не переехала вместе
; с текстом. После копирования LINE рисует только новую граничную строку.
; Это сохраняет подсветку/Tab остальных строк. При непрерывном Down
; у нижней границы больше не требуется заново разбирать весь экран.
NAV_SCROLL_SCREEN LD A,(NAV_ROW):CP LNZ-1:JR Z,NAV_SCROLL_UP
           LD B,A,A,(IX+5):DEC A:CP B:JP NZ,REFRESH
           LD A,(NAV_ROW):DEC A:LD (NAV_ROW),A
           LD DE,(LNZ+1)*256:CALL GADRW
           LD DE,(CURSOR_ADDR),A,(CURSOR_ATTR),(DE),A
           LD D,H,E,L:DEC D
           LD A,(IX+5):SUB LNZ+2
NAV_COPY_UP PUSH AF
            LD B,0,C,(IX+4):LDIR
            LD L,128,E,128,C,(IX+4):LDIR
            LD L,0,E,0:INC H:INC D
            POP AF:DEC A:JR NZ,NAV_COPY_UP
            JR NAV_NEW_ROW
NAV_SCROLL_UP LD A,LNZ,(NAV_ROW),A
              LD A,(IX+5):SUB 3:LD D,A,E,0:CALL GADRW
              LD DE,(CURSOR_ADDR),A,(CURSOR_ATTR),(DE),A
              LD D,H,E,L:INC D
              LD A,(IX+5):SUB LNZ+2
NAV_COPY_DOWN PUSH AF
              LD B,0,C,(IX+4):LDIR
              LD L,128,E,128,C,(IX+4):LDIR
              LD L,0,E,0:DEC H:DEC D
              POP AF:DEC A:JR NZ,NAV_COPY_DOWN
NAV_NEW_ROW LD HL,LINESTART,DE,LNHLP,BC,3:LDIR
            CALL PTR_RESET
            XOR A:LD (LINE_EOF),A,(CRFLG),A
            LD A,(NAV_ROW),D,A,E,0:LD (XY),DE:JP LINE

; Сравнение двух трёхбайтовых величин без зависимости от их формата.
NAV_COMPARE LD B,3
NAV_COMPARE_BYTE LD A,(DE):CP (HL):RET NZ
                 INC HL:INC DE:DJNZ NAV_COMPARE_BYTE:RET

; Перерисовка всего окна. CURCOL рассчитывается до вывода, поэтому даже
; курсор правее 65535-й колонки сразу получает правильную прокрутку.
PAGE    CALL MEASURE_CURSOR,ADJUST_HORIZONTAL,CLAMP_VIEW,PTR_RESET
        XOR A:LD (CRFLG),A,(LINE_EOF),A
        LD HL,PGHLP,DE,LNHLP,BC,3:LDIR
        LD HL,LNZ*256,(XY),HL
VIEW_ROW CALL LINE
         LD HL,XY+1:INC (HL):LD A,(HL):INC A:CP (IX+5):JR C,VIEW_ROW
         RET

; Единый вывод для обычного текста и подсветки. Классификатор FILLnCOL
; работает и слева от видимой области: скрытая кавычка/';' задаёт цвет хвоста.
; Scratch #BA00/#BA80 находится между заголовком окна и буферами Inspector.
LINE    LD DE,(XY):CALL GADRW:LD (ROWADDR),HL
        LD HL,0,(CRPOZ),HL,(COL_NOW),HL
        XOR A:LD (ROW_USED),A,(COL_NOW+2),A,(HLCFLG),A,(HLQFLG),A,(HLhexFLG),A,(HLdecFLG),A
        LD A," ",(PREVCHAR),A
        LD A,(LINE_EOF):OR A:JP NZ,VIEW_ROW_END
VIEW_BYTE XOR A:LD (PTR_GAP),A
          CALL TEXT_PEEK:PUSH AF
          LD A,(PTR_GAP):OR A:CALL NZ,VIEW_CURSOR
          POP AF:JR NC,VIEW_EOF
          CP 13:JR Z,VIEW_CR
          CP 10:JR Z,VIEW_LF
          PUSH AF:CALL CELL_WIDTH:LD A,B,(CELL_COUNT),A
          POP AF:CP 32:JR NC,VIEW_GLYPH
          LD A," "
VIEW_GLYPH LD (CELL_CHAR),A
           LD A,(HIGHLGT):OR A:LD A,DFCOL:JR Z,VIEW_DEFAULT
           LD A,(CELL_CHAR),DE,#BA00:CALL FILLnCOL
           LD A,(#BA80)
VIEW_DEFAULT LD (CELL_ATTR),A:CALL VIEW_SELECTION
VIEW_CELL CALL DRAW_CELL,COL_INCREMENT
          LD HL,CELL_COUNT:DEC (HL):JR NZ,VIEW_CELL
          CALL PTR_NEXT:JR VIEW_BYTE
VIEW_CR CALL PTR_NEXT,SKIP_OPTIONAL_LF:JR VIEW_ROW_END
VIEW_LF CALL PTR_NEXT

; Сначала выводим новые клетки, затем очищаем только оставшийся хвост.
; Предварительное стирание всей строки показывало промежуточные пробелы
; между кадрами даже при перемещении курсора по неизменному тексту.
VIEW_ROW_END LD A,(ROWADDR+1),H,A,A,(ROW_USED),L,A
             LD A,(IX+4):SUB L:JR Z,VIEW_ROW_CURSOR
             LD B,A,C," "
VIEW_CLEAR_TAIL LD (HL),C:SET 7,L:LD (HL),DFCOL:RES 7,L:INC L:DJNZ VIEW_CLEAR_TAIL
VIEW_ROW_CURSOR JP CURTAT
VIEW_EOF LD A,1,(LINE_EOF),A:JR VIEW_ROW_END

; COL_NOW - HSCROLL -> L=экранная колонка, C=видна. Проверяются все 24 бита.
VISIBLE_COLUMN LD HL,(COL_NOW),DE,(HSCROLL):OR A:SBC HL,DE
               LD A,(HSCROLL+2),B,A,A,(COL_NOW+2):SBC A,B
               OR A:RET NZ
               LD A,H:OR A:RET NZ
               LD A,L:CP (IX+4):RET NC
               SCF:RET
DRAW_CELL CALL VISIBLE_COLUMN:RET NC
          LD A,(ROWADDR+1),H,A,A,(CELL_CHAR),(HL),A
          LD A,L:INC A:LD (ROW_USED),A
          SET 7,L:LD A,(CELL_ATTR),(HL),A:RET
VIEW_CURSOR CALL VISIBLE_COLUMN:RET NC
            LD A,(ROWADDR+1),H,A:LD (CRPOZ),HL
            LD A,L,(CRP),A,A,(XY+1),(CRP+1),A:RET

; Выделение относится к исходным байтам, а не к нарисованным клеткам.
; Поэтому все восемь клеток одного Tab получают один и тот же атрибут.
VIEW_SELECTION LD A,(MARKED):OR A:RET Z
               LD A,(LNHLP+2),B,A,A,(BHLBLK+2):CP B:JR C,VIEW_MARK_UPPER
               RET NZ
VIEW_MARK_END
              LD HL,(LNHLP),DE,(BHLBLK):OR A:SBC HL,DE:RET C
VIEW_MARK_UPPER LD A,(LNHLP+2),B,A,A,(EHLBLK+2):CP B:RET C
                JR NZ,VIEW_MARK_YES
                LD HL,(LNHLP),DE,(EHLBLK):OR A:SBC HL,DE:RET NC
VIEW_MARK_YES LD A,MDCOL,(CELL_ATTR),A:RET

; Верхняя строка: следующий перенос (CRLF поглощается целиком).
PGMD    CALL PTR_RESET
        LD HL,PGHLP,DE,LNHLP,BC,3:LDIR
VIEW_DOWN CALL TEXT_PEEK:RET NC
          PUSH AF:CALL PTR_NEXT:POP AF
          CP 13:JR Z,VIEW_DOWN_CR
          CP 10:JR NZ,VIEW_DOWN
          JR VIEW_DOWN_STORE
VIEW_DOWN_CR CALL SKIP_OPTIONAL_LF
VIEW_DOWN_STORE LD HL,LNHLP,DE,PGHLP,BC,3:LDIR:SCF:RET

; Предыдущее начало строки. Сначала пропускаем перенос непосредственно
; перед PGHLP, затем ищем более ранний. BOF — допустимый результат с NC.
PGMUZ   CALL PTR_RESET
        LD HL,PGHLP,DE,LNHLP,BC,3:LDIR
        CALL PTR_BACK:JR NC,VIEW_UP_BOF
        CP 10:JR Z,VIEW_UP_LF
        CP 13:JR Z,VIEW_UP_SCAN
        JR VIEW_UP_SCAN
VIEW_UP_LF CALL PTR_BACK:JR NC,VIEW_UP_BOF
           CP 13:JR Z,VIEW_UP_SCAN
           CP 10:JR Z,VIEW_UP_FOUND
VIEW_UP_SCAN CALL PTR_BACK:JR NC,VIEW_UP_BOF
             CP 13:JR Z,VIEW_UP_FOUND
             CP 10:JR NZ,VIEW_UP_SCAN
VIEW_UP_FOUND CALL PTR_NEXT
              LD HL,LNHLP,DE,PGHLP,BC,3:LDIR:SCF:RET
VIEW_UP_BOF LD HL,LNHLP,DE,PGHLP,BC,3:LDIR:OR A:RET

; Посмотреть соседний байт, не двигая зазор. C=байт существует, A=байт.
PEEK_RIGHT CALL PTR_RESET
           LD HL,RHLCR,DE,LNHLP,BC,3:LDIR
           CALL PTR_NEXT:JP PTR_PEEK
PEEK_LEFT CALL PTR_RESET
          LD HL,LHLCR,DE,LNHLP,BC,3:LDIR:JP PTR_BACK

; Логический шаг: один байт или целая пара CRLF, в том числе на стыке страниц.
; Возвращается первый перемещённый байт; NC только при исходном EOF/BOF.
STEP_RIGHT CALL INCCUR:RET NC
           CP 13:JR NZ,STEP_DONE
           PUSH AF:CALL PEEK_RIGHT:JR NC,STEP_POP
           CP 10:CALL Z,INCCUR
STEP_POP POP AF
STEP_DONE SCF:RET
STEP_LEFT CALL DECCUR:RET NC
          CP 10:JR NZ,STEP_DONE
          PUSH AF:CALL PEEK_LEFT:JR NC,STEP_POP
          CP 13:CALL Z,DECCUR:JR STEP_POP

; Enter использует первый встреченный стиль EOL. Уже существующие переносы,
; включая смешанный файл, не преобразуются. Для нового файла принят CR.
DETECT_EOL LD A,13,(EOL_FIRST),A:XOR A:LD (EOL_SECOND),A
           CALL PTR_RESET
           LD HL,0,(LNHLP),HL:XOR A:LD (LNHLP+2),A
DETECT_LOOP CALL TEXT_PEEK:JR NC,DETECT_DONE
            PUSH AF:CALL PTR_NEXT:POP AF
            CP 10:JR Z,DETECT_LF
            CP 13:JR NZ,DETECT_LOOP
            CALL TEXT_PEEK:JR NC,DETECT_DONE
            CP 10:JR NZ,DETECT_DONE
            LD (EOL_SECOND),A:JR DETECT_DONE
DETECT_LF LD (EOL_FIRST),A
DETECT_DONE XOR A:RET

; Идти от начала строки до TARGETCOL, не пересекая перенос и не попадая
; внутрь Tab. Если Tab перекрывает цель, останавливаемся перед ним.
CRMFWD LD HL,0,(COL_NOW),HL:XOR A:LD (COL_NOW+2),A
       LD (FWD_BYTES),HL,(FWD_BYTES+2),A
       CALL PTR_RESET
       LD HL,RHLCR,DE,LNHLP,BC,3:LDIR:CALL PTR_NEXT
       LD HL,LNHLP,DE,FWD_SOURCE,BC,3:LDIR
CRFWD_LOOP LD HL,(COL_NOW),DE,(TARGETCOL):OR A:SBC HL,DE
           LD A,(TARGETCOL+2),B,A,A,(COL_NOW+2):SBC A,B:JR NC,FWD_MOVE
           CALL PTR_PEEK:JR NC,FWD_MOVE
           CP 13:JR Z,FWD_MOVE
           CP 10:JR Z,FWD_MOVE
           CALL COL_ADD_CHAR
           LD HL,(TARGETCOL),DE,(COL_NOW):OR A:SBC HL,DE
           LD A,(COL_NOW+2),B,A,A,(TARGETCOL+2):SBC A,B:JR C,FWD_MOVE
           LD HL,FWD_BYTES:INC (HL):JR NZ,FWD_COUNTED
           INC HL:INC (HL):JR NZ,FWD_COUNTED
           INC HL:INC (HL)
FWD_COUNTED CALL PTR_NEXT:JR CRFWD_LOOP

; После определения колонки переносим выбранный диапазон через зазор.
; Окна #0000/#C000 подключаются один раз на страницу, а не на каждый символ:
; переход Down к 70000-й колонке не делает 140000 вызовов диспетчера WC.
; FWD_BYTES — LE24, BC — его младшее слово. Нулевое BC при ненулевом старшем
; байте означает очередные 65536 байт; старший байт уменьшается до первого LDI.
FWD_MOVE LD HL,(FWD_BYTES),A,(FWD_BYTES+2):OR H,L:RET Z
         CALL PTR_BACK
         LD HL,LNHLP,DE,FWD_END,BC,3:LDIR
         LD A,(LHLCR+2):CALL MNG0VPL
         LD A,(FWD_SOURCE+2):CALL MNGCVPL
         LD HL,(LHLCR),DE,(FWD_SOURCE):SET 7,D:SET 6,D
         LD BC,(FWD_BYTES)
FWD_COPY LD A,B:OR C:JR NZ,FWD_HAVE
         LD A,(FWD_BYTES+2):OR A:JR Z,FWD_DONE
         DEC A:LD (FWD_BYTES+2),A
FWD_HAVE LDI
         BIT 6,H:JR Z,FWD_DST_READY
         RES 6,H
         PUSH BC,DE,HL
         LD A,(LHLCR+2):INC A:LD (LHLCR+2),A:CALL MNG0VPL
         POP HL,DE,BC
FWD_DST_READY LD A,D:OR A:JR NZ,FWD_COPY
              LD DE,#C000
              PUSH BC,HL
              LD A,(FWD_SOURCE+2):INC A:LD (FWD_SOURCE+2),A
              CP PGM+1:CALL C,MNGCVPL
              POP HL,BC:JR FWD_COPY
FWD_DONE LD (LHLCR),HL
         LD HL,FWD_END,DE,RHLCR,BC,3:LDIR:RET

CURCOL DS 3,0
TARGETCOL DS 3,0
HSCROLL DS 3,0
COL_NOW DS 3,0
LINESTART DS 3,0
ROWADDR DW 0
ROW_USED DB 0
CURSOR_ADDR DW 0
CURSOR_ATTR DB 0
NAV_PAGE DS 3,0
NAV_SCROLL DS 3,0
NAV_LINE DS 3,0
NAV_ROW DB 0
PTR_PAGE DB #FF
PTR_GAP DB 0
CELL_COUNT DB 0
CELL_CHAR DB 0
CELL_ATTR DB 0
EOL_FIRST DB 13
EOL_SECOND DB 0
FWD_BYTES DS 3,0
FWD_SOURCE DS 3,0
FWD_END DS 3,0
