; ВГ93/Beta Disk. #29AF=80 открывает порты и отключает виртуальные A..D.
; Старый TRDUMP на выходе пишет 0: это теряет маску виртуальных дисков Mounter.
; Здесь возвращаем авторитетную маску из NVRAM B0, саму ячейку не меняем.
OpenFDC:
        LD BC,#DFF7
        LD A,#B0
        OUT (C),A
        LD B,#BF
        IN A,(C)
        LD (Saved29),A
        LD BC,#29AF
        LD A,#80
        OUT (C),A
        LD (FdcOpen),A
        CALL SelectSide
        LD B,0                          ; ~1 мс: если ВГ93 держали в сбросе (#FF бит 2),
.settle: DJNZ .settle                   ; после его снятия он сам пишет 01 в регистр сектора
        CALL ForceIdle
        ; Есть ли контроллер: регистр сектора ВГ93 хранит записанное. Без
        ; контроллера шина отвечает одним и тем же (#FF) на оба значения.
        ; На настоящей машине чтение сразу за записью иногда давало не то
        ; (пользователь, 10-01: «controller not found» при живом контроллере):
        ; между записью и чтением пауза, попыток восемь, отказ — только если
        ; не совпала ни одна.
        LD E,8
.probe: LD A,#55
        CALL .echo
        JR NZ,.again
        LD A,#AA
        CALL .echo
        JR Z,.present
.again: LD B,0                          ; ~1 мс между попытками
.pause: DJNZ .pause
        DEC E
        JR NZ,.probe
        LD A,ERR_NOFDC
        SCF
        RET
.echo:  LD D,A
        OUT (#5F),A
        LD B,16                         ; 60 мкс на 3,5 МГц
.hold:  DJNZ .hold
        IN A,(#5F)
        CP D
        RET
.present:
        LD A,#08                       ; RESTORE, head load, 6 ms step
        OUT (#1F),A
        CALL WaitCommand
        RET C
        IN A,(#1F)
        BIT 2,A
        JR Z,.drive
        BIT 7,A
        JR NZ,.disk
        XOR A
        LD (Physical),A
        CALL WaitIndex
        RET C
        IN A,(#1F)                     ; без дискеты WP может быть активен: сначала INDEX
        BIT 6,A
        JR NZ,.wp
        CALL SpinUpFromIndex             ; первое ребро уже принято WaitIndex
        RET C
        CALL WaitIndex
        RET C
        JP StampOk
.drive: LD A,ERR_DRIVE
        SCF
        RET
.disk: LD A,ERR_DISK
        SCF
        RET
.wp:   LD A,ERR_WP
        SCF
        RET
StampOk:
        CALL Stamp
        XOR A
        RET
; Отметка времени последней команды ВГ93 по счётчику кадров WC (#6009, 50 Гц).
; По ней EnsureMotor узнаёт о долгой паузе. Регистры и флаги сохраняются.
Stamp:  PUSH HL
        LD HL,(#6009)
        LD (LastCmd),HL
        POP HL
        RET
CloseFDC:
        LD A,(FdcOpen)
        OR A
        RET Z
        CALL ForceIdle                  ; без нового RESTORE/SEEK
        LD A,(Physical)
        OUT (#3F),A                     ; track register снова соответствует головке
        LD A,#04                       ; reset released, HLT/head load off
        OUT (#FF),A
        LD A,(Saved29)
        LD BC,#29AF
        OUT (C),A
        XOR A
        LD (FdcOpen),A
        LD B,#FF                       ; вернуть частоту/кэш, что были до плагина
        LD A,14
        JP WLD
ForceIdle:
        LD A,#D0
        OUT (#1F),A
        LD B,16                        ; 60 мкс на 3,5 МГц: статус после D0 готов через 32
.quiet: DJNZ .quiet
        RET
SpinUp:
        ; Раскрутка — по индексным импульсам, а не по времени: пять оборотов,
        ; около секунды. Прежний отсчёт циклов (~1,5 с) зависел от частоты CPU,
        ; а ВГ93 после команды держит HLD/мотор ограниченное время (15 оборотов;
        ; Unreal — 2 с): к проверке индекса мотор уже стоял, выходило «No disk».
        CALL WaitIndex                   ; первое ребро может быть неполным оборотом
        RET C
SpinUpFromIndex:
        LD B,5                           ; пять ПОЛНЫХ интервалов INDEX..INDEX
.turn: PUSH BC
        CALL WaitIndex
        POP BC
        RET C
        DJNZ .turn
        XOR A
        RET
SelectSide:
        LD A,(Side)
        OR A
        LD A,#3C                       ; MFM, side 0 (выбор стороны инверсный)
        JR Z,.side
        LD A,#2C
.side: LD B,A
        LD A,(Drive)
        OR B
        OUT (#FF),A
        RET
SeekTrack:
        CALL EnsureMotor                ; долгий LOAD512/UI мог остановить мотор
        RET C
        CALL SelectSide
        LD A,(Physical)
        OUT (#3F),A                    ; вернуть физический регистр после чужого C
        LD A,(Cylinder)
        OUT (#7F),A
        LD A,#18                       ; без V: ID.C может отличаться от цилиндра
        OUT (#1F),A
        CALL WaitCommand
        RET C
        CALL Stamp
        IN A,(#1F)
        AND #91                        ; busy, seek error, not ready
        JR NZ,.bad
        LD A,(Cylinder)
        LD (Physical),A
        OR A
        RET
.bad:  LD A,ERR_SEEK
        SCF
        RET

; Вход: Physical — настоящий цилиндр (track register мог содержать ID.C).
; Выход: CF=0 — мотор уже готов; CF=1, A — ошибка. BC/DE/HL сохранены.
; FORCE INTERRUPT даёт type I status: bit 5 = HLD AND HLT. D0 сам мотор
; не запускает. Если HLD истёк, SEEK с h=1 к ТОЙ ЖЕ позиции заново грузит
; головку; пять новых INDEX обязательны до любой команды данных. Проверка
; общая для SEEK и ReadBytes/WriteBytes, поэтому покрывает паузу любого
; происхождения, включая минуту в ErrorChoice и файловые/оконные API.
EnsureMotor:
        PUSH BC
        PUSH DE
        PUSH HL
        LD A,(NeedSpin)                 ; диалог Retry/Ignore/Abort: думали долго
        OR A
        JR NZ,.spin
        LD HL,(#6009)                   ; кадров с прошлой команды: ВГ93 держит HLD
        LD DE,(LastCmd)                 ; 15 оборотов (3 с), Unreal — 2 с; раскрутка
        OR A                            ; заново после 1,5 с простоя. Бит 5 статуса
        SBC HL,DE                       ; type I не читаем: после D0 эмулятор его не
        LD A,H                          ; выставляет, раскрутка шла бы перед каждой
        OR A                            ; командой и сбивала порядок ID (стенд 10-01).
        JR NZ,.spin
        LD A,L
        CP 75
        JR C,.ready
.spin:  XOR A
        LD (NeedSpin),A
        CALL ForceIdle
        IN A,(#3F)
        PUSH AF                         ; сохранить ID.C для секторной команды
        CALL SelectSide
        LD A,(Physical)
        OUT (#3F),A
        OUT (#7F),A
        LD A,#18                       ; SEEK без verify: чужие ID.C допустимы
        OUT (#1F),A
        CALL WaitCommand
        JR C,.restoretrack
        IN A,(#1F)
        AND #91
        JR NZ,.seekerror
        CALL SpinUp
        CALL NC,Stamp
        JR .restoretrack
.seekerror:
        LD A,ERR_SEEK
        SCF
.restoretrack:
        POP HL                          ; H = прежний track register, L = флаги
        PUSH AF                         ; ошибка/CF не теряются при OUT
        LD A,H
        OUT (#3F),A
        POP AF
        JR .out
.ready: XOR A
.out:  POP HL
        POP DE
        POP BC
        RET

; Ожидания type I/index с EI; Esc опрашивается каждые 256 итераций.
; Счёт итераций — конечная граница даже при остановившемся INT. На 3,5 МГц
; 65536 итераций — около 1,4 с без учёта опроса Esc: команде позиционирования
; даём 4 таких отрезка (RESTORE через весь диск — 3 с), индексу — 3 (пустой
; дисковод: «No disk in drive» секунд через пять, а не через двадцать).
WaitCommand:
        LD DE,0
        LD B,4
.loop: IN A,(#FF)
        BIT 7,A
        JR NZ,.done
        DEC DE
        LD A,E
        OR A
        JR NZ,.count
        CALL BreakCheck
        RET C
.count: LD A,D
        OR E
        JR NZ,.loop
        DJNZ .loop
        LD A,ERR_TIMEOUT
        SCF
        RET
.done: XOR A
        RET
WaitIndex:
        LD C,0
        CALL .edge
        RET C
        LD C,2
.edge: LD DE,0
        LD B,3
.loop: IN A,(#1F)                      ; вызывать только при type I status
        AND 2
        CP C
        JR Z,.done
        DEC DE
        LD A,E
        OR A
        JR NZ,.count
        CALL BreakCheck
        RET C
.count: LD A,D
        OR E
        JR NZ,.loop
        DJNZ .loop
        LD A,ERR_DISK
        SCF
        RET
.done: XOR A
        RET
BreakCheck:
        LD A,(FdcOpen)                  ; Validate идёт ДО очистки ABT в RunDisk
        OR A
        JR Z,.keyboard                  ; там проверяем живую клавишу, не boot-мусор
        CALL BoundaryCheck              ; короткий рабочий Esc мог уже отпуститься
        RET C
.keyboard:
        PUSH BC
        PUSH DE
        PUSH HL
        PUSH IX
        PUSH IY
        LD A,23
        CALL WLD
        POP IY
        POP IX
        POP HL
        POP DE
        POP BC
        JR NZ,.break
        XOR A
        RET
.break: LD A,ERR_BREAK
        SCF
        RET

; Передача по DRQ на 3,5 МГц (частоту ставит RunDisk: на 14 МГц стробы портов
; ВГ93 короче, чем ему нужно, — на настоящей машине запись шла с ошибками).
; Во время передачи нельзя вызывать WC/PS2 или файловые функции, DI не даёт
; резидентам отнять 32 мкс. Такт — 0,2857 мкс; пределы FD179X при 1 МГц:
; запись 23,5 мкс (82 T), чтение 27 мкс (94 T).
;   Опрос: IN A,(#FF) / AND #C0 / JR NZ — 25 T, порт читается на 11-м такте.
;   Сторож встроен в опрос так, что между двумя чтениями порта всегда 39 T
;   (25 + DEC + JP): на каждом уровне счётчика свой опрос. Третий уровень
;   (раз в 65536 опросов, 0,73 с) — 47 T.
;   После каждого байта пять опросов подряд без счётчика, по 25 T: следующий
;   DRQ приходит через 52..77 T после записи и попадает в них.
;   Запись: байт уходит сразу (OUTI, строб на 14–16-м такте), INTRQ разбирается
;   после него; лишний OUTI по INTRQ безвреден, HL возвращается назад.
;   От DRQ до строба: в потоке 25+35=60 T (17,1 мкс), в ожидании первого
;   байта 39+35=74 T (21,1 мкс), раз в 0,73 с — 82 T (23,4 мкс).
;   Чтение: сначала JP M (байт в память по INTRQ писать нельзя), порт читается
;   на 11-м такте INI: 25+41=66 T (18,9 мкс), 39+41=80 T (22,9 мкс), 88 T.
; Сторож: 4*65536 опросов — 2,9 с; самая долгая команда (RNF, пять оборотов) —
; секунда. Esc проверяется между командами, не здесь. Объём считается после
; команды по сдвигу HL.
; Число обращений к порту данных ограничено пределом DE: B (его уменьшают сами
; OUTI/INI, порт #7F узнаётся по младшему байту) считает байты блока, C' —
; блоки по 256. После последнего разрешённого байта — TransferFull: ждёт
; INTRQ, а ещё один DRQ — ошибка. Иначе зависший DRQ без INTRQ обходил сторож
; (тот считает только пустые опросы), HL шёл через всю память при DI. Проверка
; JR Z после байта — 7 T, уже после строба порта, на бюджет не влияет.
; Вход: A — команда, HL — буфер, DE — ожидаемый предел. Выход: HL — за
; последним байтом, TransferLeft = предел − передано; больше предела — ошибка.
WriteBytes:
        PUSH AF
        CALL EnsureMotor
        JP C,TransferNotStarted
        POP AF
        LD (TransferStart),HL
        LD (TransferLimit),DE
        EX AF,AF'
        LD A,ERR_WRITE
        LD (TransferKind),A
        EX AF,AF'
        CALL InitTransferCount
        LD DE,0
        DI
        OUT (#1F),A
.wait:  IN A,(#FF)
        AND #C0
        JR NZ,.event
        DEC E
        JP NZ,.wait
        IN A,(#FF)
        AND #C0
        JR NZ,.event
        DEC D
        JP NZ,.wait
        IN A,(#FF)
        AND #C0
        JR NZ,.event
        EXX
        DEC B
        EXX
        JP NZ,.wait
        JP TransferTimeout
.event: OUTI
        JR Z,.block                     ; блок байтов исчерпан
        ADD A,A                         ; CF = INTRQ
        JR C,.done
.stream:
        DUP 5
        IN A,(#FF)
        AND #C0
        JR NZ,.event
        EDUP
        JP .wait
.block: ADD A,A
        JR C,.done                      ; INTRQ: лишний OUTI отменяет DEC HL
        EXX
        DEC C
        EXX
        JP NZ,.stream
        JP TransferFull
.done:  DEC HL                          ; последний OUTI был не по DRQ
        JP TransferDone
ReadBytes:
        PUSH AF
        CALL EnsureMotor
        JP C,TransferNotStarted
        POP AF
        LD (TransferStart),HL
        LD (TransferLimit),DE
        EX AF,AF'
        LD A,ERR_VERIFY
        LD (TransferKind),A
        EX AF,AF'
        CALL InitTransferCount
        LD DE,0
        DI
        OUT (#1F),A
.wait:  IN A,(#FF)
        AND #C0
        JR NZ,.event
        DEC E
        JP NZ,.wait
        IN A,(#FF)
        AND #C0
        JR NZ,.event
        DEC D
        JP NZ,.wait
        IN A,(#FF)
        AND #C0
        JR NZ,.event
        EXX
        DEC B
        EXX
        JP NZ,.wait
        JP TransferTimeout
.event: JP M,TransferDone
        INI
        JR Z,.block                     ; блок байтов исчерпан
.stream:
        DUP 5
        IN A,(#FF)
        AND #C0
        JR NZ,.event
        EDUP
        JP .wait
.block: EXX
        DEC C
        EXX
        JP NZ,.stream
; Предел исчерпан: к порту данных больше не обращаемся. INTRQ — команда
; закончилась; ещё один DRQ — контроллер просит больше буфера: ошибка.
; Молчание ограничено прежним сторожем.
TransferFull:
.wait:  IN A,(#FF)
        AND #C0
        JR NZ,.event
        DEC E
        JP NZ,.wait
        IN A,(#FF)
        AND #C0
        JR NZ,.event
        DEC D
        JP NZ,.wait
        IN A,(#FF)
        AND #C0
        JR NZ,.event
        EXX
        DEC B
        EXX
        JP NZ,.wait
        JP TransferTimeout
.event: JP M,TransferDone
        LD A,(TransferKind)
        JP TransferFail
; B — байтов в первом блоке (младший байт предела, 0 — 256), C' — блоков
; (предел/256 с округлением вверх), B' — сторож ожидания, C — порт данных.
; A (команда) сохраняется.
InitTransferCount:
        PUSH AF
        LD B,E
        LD A,E
        OR A
        LD A,D
        JR Z,.pages
        INC A
.pages: EXX
        LD C,A
        LD B,4
        EXX
        LD C,#7F
        POP AF
        RET
TransferDone:
        IN A,(#1F)
        LD (ReadStatus),A
        EI
        CALL Stamp
        PUSH HL
        LD DE,(TransferStart)
        OR A
        SBC HL,DE                       ; передано байтов
        EX DE,HL
        LD HL,(TransferLimit)
        OR A
        SBC HL,DE                       ; предел − передано
        JR C,.over
        LD (TransferLeft),HL
        POP HL
        OR A
        RET
.over: POP HL                          ; контроллер запросил больше буфера
        LD A,(TransferKind)
        JR TransferFail
TransferTimeout:
        EI                              ; Esc проверяется только ПОСЛЕ цикла DRQ
        CALL BoundaryCheck
        JR C,TransferFail
        LD A,ERR_TIMEOUT
TransferFail:
        PUSH AF
        CALL ForceIdle
        POP AF
        EI
        CALL Stamp
        SCF
        RET
TransferNotStarted:
        POP BC                          ; снять сохранённую команду, оставить A/CF
        RET
WriteStatus:
        LD A,(ReadStatus)
        BIT 7,A
        JR NZ,.disk
        BIT 6,A
        JR NZ,.wp
        AND #3D                        ; lost, CRC/RNF, fault, busy
        RET Z
        LD A,ERR_WRITE
        SCF
        RET
.disk: LD A,ERR_DISK
        SCF
        RET
.wp:   LD A,ERR_WP
        SCF
        RET

; Проверка сразу после выбора дисковода: контроллер, дисковод, дискета,
; защита записи. Контроллер затем закрывается (частота WC и маска #29AF
; возвращаются): вопрос и разбор образа идут на обычной частоте, RunDisk
; открывает его заново — дискету за это время могли вынуть.
ProbeDisk:
        CALL StartFDC
        PUSH AF
        CALL CloseFDC
        POP AF
        RET
StartFDC:
        XOR A                           ; защёлку Esc (#6004) WC сам не обнуляет:
        LD (#6004),A                    ; до первого Esc в ней мусор — ложный выход
        LD BC,0                         ; Z80 на 3,5 МГц до первого обращения к ВГ93;
        LD A,14                         ; частоту WC вернёт CloseFDC (TURBOPL, B=#FF)
        CALL WLD
        JP OpenFDC
; Работа дорожками: один проход WRITE SECTOR в порядке ID, затем весь
; порядок READ ADDRESS и два чередующихся прохода проверки данных.
; Сравнение 1024 байт дольше GAP3, поэтому не проверяем соседние ID подряд.
RunDisk:
        CALL StartFDC
        RET C
        CALL ResetTracks
.track:
        CALL BreakCheck
        RET C
        CALL LoadTrack
        RET C
        CALL PrepareTrack
        RET C
        CALL BuildStream
        CALL Progress
        CALL MapTrack
        CALL SeekTrack
        RET C
        LD A,2                          ; дорожка, не сошедшаяся при сверке, пишется
        LD (TrackTries),A               ; заново целиком — ещё два раза, без вопросов
.again: LD A,3
        LD (RetryLeft),A
.format:
        CALL ForceIdle
        LD HL,STREAM
        LD DE,MAXSTREAM
        LD A,#F4
        CALL WriteBytes
        JR C,.formatfailed
        PUSH HL
        CALL WriteStatus
        POP HL
        JR C,.formatfailed
        LD DE,(StreamEnd)
        OR A
        SBC HL,DE                       ; индекс не обрезал обязательную часть
        JR NC,.formatted
        LD A,ERR_WRITE
        SCF
.formatfailed:
        LD (ErrorCode),A
        CALL FatalError
        RET C
        LD HL,RetryLeft
        DEC (HL)
        JR NZ,.format
        LD A,(ErrorCode)                ; Ignore форматирования не имеет смысла
        SCF
        RET
.formatted:
        XOR A
        LD (SectorIndex),A
.write:
        LD A,(SectorIndex)
        LD HL,SectorCount
        CP (HL)
        JR Z,.ids
        CALL SelectSector
        CALL GetPlan
        OR A
        JR NZ,.nextwrite                ; bad CRC уже записан форматированием
        CALL WriteWithChoice
        RET C
.nextwrite:
        LD HL,SectorIndex
        INC (HL)
        JR .write
.ids:   CALL BreakCheck
        RET C
        CALL VerifyIDs                  ; ПОСЛЕ записи всей дорожки, включая tight
        JR C,.badtrack
        CALL VerifyFast
        JR NC,.verified
.badtrack:
        CALL FatalError
        RET C
        CALL ForceIdle
        LD HL,TrackTries                ; записалось не то (настоящая машина, 10-01):
        LD A,(HL)                       ; сначала вся дорожка заново, и только если
        OR A                            ; не помогло — по секторам с вопросом
        JR Z,.bysector
        DEC (HL)
        JP .again
.bysector:
        CALL VerifyIDsWithChoice
        RET C
        CALL VerifySlow
        RET C
.verified:
        CALL CountChanged               ; один раз на дорожку, повторы не считаются
        LD HL,(TracksDone)
        INC HL
        LD (TracksDone),HL
        CALL Progress
        CALL NextTrack
        JP NZ,.track
        XOR A
        RET
; FatalError сохраняет код ошибки, CF=1 только для немедленного выхода.
FatalError:
        CP ERR_BREAK
        SCF
        RET Z
        CP ERR_DISK
        SCF
        RET Z
        CP ERR_WP
        SCF
        RET Z
        OR A
        RET
SelectSector:
        LD A,(SectorIndex)
        LD E,A
        LD D,0
        LD H,D
        LD L,E
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        OR A
        SBC HL,DE
        LD DE,TrackDesc+7
        ADD HL,DE
        PUSH HL
        POP IY
        RET
SectorRegisters:
        LD A,(IY+0)
        OUT (#3F),A
        LD A,(IY+2)
        OUT (#5F),A
        RET
BoundaryCheck:
        LD A,(#6004)                    ; между командами, не отвлекает быстрый проход
        OR A
        JP NZ,UserAbort
        RET
WriteSector:
        CALL BoundaryCheck
        RET C
        CALL SectorRegisters
        CALL GetPayload
        LD D,B
        LD E,C
        LD A,(IY+4)
        AND #80
        LD A,#A0
        JR Z,.command
        INC A
.command:
        CALL WriteBytes
        RET C
        CALL WriteStatus
        RET C
        LD HL,(TransferLeft)
        LD A,H
        OR L
        RET Z
        LD A,ERR_WRITE
        SCF
        RET
WriteWithChoice:
.again: LD A,3
        LD (RetryLeft),A
.try:   CALL WriteSector
        RET NC
        CALL FatalError
        RET C
        PUSH AF
        CALL ForceIdle
        POP AF
        LD HL,RetryLeft
        DEC (HL)
        JR NZ,.try
        LD A,ERR_WRITE
        CALL ErrorChoice
        RET C
        OR A
        JR Z,.again                    ; Retry повторяет именно этот сектор
        XOR A                          ; Ignore не записан, проверять его нельзя
        RET
GetPlan:
        LD A,(SectorIndex)
        LD E,A
        LD D,0
        LD HL,Plans
        ADD HL,DE
        LD A,(HL)
        RET
GetIgnored:
        LD A,(SectorIndex)
        LD E,A
        LD D,0
        LD HL,Ignored
        ADD HL,DE
        LD A,(HL)
        OR A
        RET
MarkIgnored:
        CALL GetIgnored
        RET NZ                         ; единственный счётчик на сектор
        LD (HL),1
        LD HL,(IgnoredDone)
        INC HL
        LD (IgnoredDone),HL
        RET
CountChanged:
        LD A,(SectorCount)
        LD B,A
        OR A
        RET Z
        LD IX,ChangedBytes
        LD IY,Plans
.loop:  LD A,(IY+0)
        CP 2
        JR NZ,.next
        LD HL,(ApproxDone)
        INC HL
        LD (ApproxDone),HL
        LD E,(IX+0)
        LD D,(IX+1)
        LD HL,(ApproxBytes)
        ADD HL,DE
        LD (ApproxBytes),HL
        JR NC,.next
        LD HL,(ApproxBytes+2)
        INC HL
        LD (ApproxBytes+2),HL
.next:  INC IX
        INC IX
        INC IY
        DJNZ .loop
        RET
VerifyFast:
        XOR A
        LD (VerifyPass),A
.pass:  CALL BreakCheck
        RET C
        LD A,(VerifyPass)
        LD (SectorIndex),A
.sector:
        LD A,(SectorCount)
        LD HL,SectorIndex
        CP (HL)
        JR Z,.nextpass
        JR C,.nextpass
        CALL GetIgnored
        JR NZ,.next
        CALL SelectSector
        CALL VerifySector
        RET C
.next:  LD A,(SectorIndex)
        ADD A,2
        LD (SectorIndex),A
        JR .sector
.nextpass:
        LD HL,VerifyPass
        INC (HL)
        LD A,(HL)
        CP 2
        JR NZ,.pass
        XOR A
        RET
VerifySlow:
        XOR A
        LD (SectorIndex),A
.sector:
        LD A,(SectorCount)
        LD HL,SectorIndex
        CP (HL)
        RET Z
        CALL BreakCheck
        RET C
        CALL GetIgnored
        JR NZ,.next
        CALL SelectSector
        CALL VerifyWithChoice
        RET C
.next:  LD HL,SectorIndex
        INC (HL)
        JR .sector
VerifyWithChoice:
.again: LD A,3
        LD (RetryLeft),A
.try:   CALL VerifySector
        RET NC
        CALL FatalError
        RET C
        CALL ForceIdle
        LD HL,RetryLeft                 ; сверка, и до трёх раз: запись заново и
        LD A,(HL)                       ; снова сверка; вопрос — только после сверки
        OR A
        JR Z,.ask
        DEC (HL)
        CALL GetPlan                    ; перечитывать испорченное бесполезно: сектор
        OR A                            ; пишется заново (кроме сектора с намеренно
        JR NZ,.try                      ; плохим CRC — он записан форматированием)
        CALL WriteSector
        JR NC,.try
        CALL FatalError
        RET C
        CALL ForceIdle
        JR .try
.ask:   LD A,ERR_VERIFY
        CALL ErrorChoice
        RET C
        OR A
        JR Z,.again
        XOR A
        RET
VerifyIDsWithChoice:
.again: LD A,3
        LD (RetryLeft),A
.try:   CALL VerifyIDs
        RET NC
        CALL FatalError
        RET C
        PUSH AF
        CALL ForceIdle
        POP AF
        LD HL,RetryLeft
        DEC (HL)
        JR NZ,.try
        LD A,(SectorCount)
        OR A
        JP Z,VerifyError
        LD A,ERR_VERIFY
        CALL ErrorChoice
        RET C
        OR A
        JR Z,.again
        XOR A
        RET
VerifySector:
        CALL BoundaryCheck
        RET C
        CALL SectorRegisters
        CALL GetPayload
        LD D,B
        LD E,C
        LD HL,IOBUF
        LD A,#80                       ; S=0: H не сравниваем; H проверяет READ ADDRESS
        CALL ReadBytes
        RET C
        LD A,(ReadStatus)
        BIT 7,A
        JP NZ,DiskNotReady
        LD HL,(TransferLeft)
        LD A,H
        OR L
        JR NZ,VerifyError
        CALL GetPlan
        OR A
        LD B,0
        JR Z,.status
        LD B,8                          ; намеренно плохой CRC должен вернуться как CRC
.status:
        LD A,(ReadStatus)
        AND #DD                         ; кроме DRQ и record type
        CP B
        JR NZ,VerifyError
        LD A,(IY+4)
        AND #80
        RRCA
        RRCA
        LD B,A
        LD A,(ReadStatus)
        AND #20
        CP B
        JR NZ,VerifyError
        CALL GetPayload
        LD DE,IOBUF
.compare:
        LD A,(DE)
        CP (HL)
        JR NZ,VerifyError
        INC HL
        INC DE
        DEC BC
        LD A,B
        OR C
        JR NZ,.compare
        XOR A
        RET
VerifyError:
        LD A,ERR_VERIFY
        SCF
        RET
DiskNotReady:
        LD A,ERR_DISK
        SCF
        RET
VerifyIDs:
        CALL EnsureMotor                ; Retry READ ADDRESS после долгой паузы
        RET C
        CALL ForceIdle                  ; type I status для INDEX
        CALL WaitIndex
        RET C
        LD IY,TrackDesc+7
        XOR A
        LD (SectorIndex),A
.id:   LD DE,6
        LD HL,IOBUF
        LD A,#C0
        CALL ReadBytes
        RET C
        LD A,(ReadStatus)
        BIT 7,A
        JP NZ,DiskNotReady
        LD A,(SectorCount)
        OR A
        JR NZ,.present
        LD A,(ReadStatus)
        CP #10                          ; пять оборотов без ID: RNF
        JR NZ,VerifyError
        LD HL,(TransferLeft)
        LD DE,6
        OR A
        SBC HL,DE
        JR NZ,VerifyError
        RET
.present:
        LD A,(ReadStatus)
        AND #FD
        JR NZ,VerifyError
        LD HL,(TransferLeft)
        LD A,H
        OR L
        JR NZ,VerifyError
        LD HL,IOBUF
        PUSH IY
        POP DE
        LD B,4
.compare:
        LD A,(DE)
        CP (HL)
        JR NZ,VerifyError
        INC HL
        INC DE
        DJNZ .compare
        LD DE,7
        ADD IY,DE
        LD HL,SectorIndex
        INC (HL)
        LD A,(SectorCount)
        CP (HL)
        JR NZ,.id
        XOR A
        RET
