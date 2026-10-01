; FDI2FDD — запись UKV FDI через настоящий ВГ93. UTF-8 без BOM.
; Только относительные страницы WC: 0 — код/FILEX, 1 — таблица, 2 — формат.
; Пустые страницы PLM не инициализирует: ни один байт оттуда не читается
; до явной загрузки/заполнения. Файловые вызовы выполняются до DI и FDC.
        DEVICE ZXSPECTRUM128
        ORG 0
FileStart:
        DS 16,0
        DB "WildCommanderMDL",#10,0,3,0
        DB 0,(CodeEnd-CodeStart+511)/512
        DS 10,0
        DS 15,0
        DB 1                           ; только Enter, не F3
        DB "FDI"
        DS 93,0
        DB 0
        DD #100000
NameHeader:
        DB "FDI to real floppy v0.2"
        DS 32-($-NameHeader),32
        DB 0                           ; только расширение, без F10/резидентности
        DS 512-$,0
        DISP #8000
WLD     EQU #6006
IOBUF   EQU #AC00                       ; FILEX: ниже служебного LOBU #B000
SEQBUF  EQU #A800                       ; отдельный кеш потока, FILEX его не портит
STREAM  EQU #C000                       ; собственная относительная страница 2
MAXSTREAM EQU 6656                      ; хвост из #4E до самого PAYLOAD: медленный привод
SAFEEND EQU 5900                        ; обязательные поля до этой границы
TIGHTEND EQU 6160                       ; запас для +1% скорости и конца дорожки
PAYLOAD EQU #DA00                       ; после 6656 байт потока, до #FFFF

CodeStart:
Entry:
        OR A
        RET NZ
        PUSH IX
        LD A,I
        PUSH AF
        PUSH DE
        PUSH HL                        ; DE:HL размера из входа WC
        LD H,B
        LD L,C
        PUSH HL
        LD HL,State
        LD DE,State+1
        LD BC,StateEnd-State-1
        LD (HL),0
        LDIR
        POP BC
        POP HL
        LD (FileSize),HL
        POP DE
        LD (FileSize+2),DE
        LD H,B
        LD L,C
        POP AF
        JP PO,.irqoff
        LD A,1
        LD (SavedIFF),A
.irqoff:
        LD DE,FileName+1
        LD B,255
.name: LD A,(HL)
        LD (DE),A
        INC HL
        INC DE
        OR A
        JR Z,.named
        DJNZ .name
        XOR A
        LD (DE),A
.named:
        LD A,15
        CALL WLD
.select:
        XOR A
        LD (Reselect),A
        CALL Options
        JR C,.result
        CALL CloseWindow
        CALL ShowWindow
        LD HL,MsgProbe                 ; контроллер, дисковод, дискета и защита
        CALL Message                   ; записи проверяются сразу после выбора
        CALL ProbeDisk                 ; дисковода (пользователь, 2026-10-01),
        JR NC,.ready                   ; а не после вопроса и разбора образа
        CP ERR_DRIVE                   ; выбран не тот дисковод (его нет, пуст,
        JR Z,.again                    ; дискета защищена): после сообщения —
        CP ERR_DISK                    ; снова к выбору A B C D, а не в WC
        JR Z,.again
        CP ERR_WP
        JR NZ,.result
.again: LD HL,Reselect
        INC (HL)
        JR .result
.ready: CALL Warning
        JR C,.result
        LD HL,MsgChecking
        CALL Message
        CALL OpenInput
        JR C,.result
        CALL Validate
        JR C,.result
        CALL RunDisk
.result:
        LD (Result),A
        CALL CloseFDC
        LD A,(Result)
        CP ERR_BREAK
        JR Z,.leave                    ; Esc/Abort/не-Y: без дополнительных вопросов
        CALL Summary
        LD A,46
        CALL WLD
        LD A,47
        CALL WLD
        LD A,(Reselect)
        OR A
        JR Z,.leave
        CALL CloseWindow
        JP .select
.leave:
        LD A,46                        ; клавиша выхода не должна достаться панелям WC
        CALL WLD
        CALL CloseWindow
        POP IX
        LD A,(SavedIFF)
        OR A
        JR Z,.restoredi
        XOR A                          ; исходный файл/каталог не изменены
        EI
        RET
.restoredi:
        XOR A
        DI
        RET

ERR_IMAGE EQU 1
ERR_FILE EQU 2
ERR_DRIVE EQU 3
ERR_DISK EQU 4
ERR_WP EQU 5
ERR_SEEK EQU 6
ERR_WRITE EQU 7
ERR_VERIFY EQU 8
ERR_BREAK EQU 9
ERR_TIMEOUT EQU 10
ERR_NOFDC EQU 11

        INCLUDE "image.inc"
        INCLUDE "sequential.inc"
        INCLUDE "fdc.inc"
        INCLUDE "ui.inc"

; Всё состояние зануляется при каждом запуске, включая SOW и счётчики.
State:
FileSize: DD 0
ReqOff: DD 0
DataOff: DW 0
TableStart: DW 0
TableLimit: DW 0
TablePtr: DW 0
TracksTotal: DW 0
TracksLeft: DW 0
TracksDone: DW 0
ApproxExpected: DW 0
ApproxDone: DW 0
ExpectedBytes: DD 0
ApproxBytes: DD 0
Number32: DD 0
IgnoredDone: DW 0
TrackBase: DD 0
SectorSize: DW 0
DataSum: DW 0
Gap3: DB 0
Tight: DB 0
SyncZeros: DB 0
SectorCount: DB 0
SectorIndex: DB 0
Cylinder: DB 0
Side: DB 0
Heads: DB 0
Drive: DB 0
Result: DB 0
ImageReason: DW 0
FdcOpen: DB 0
SavedIFF: DB 0
Saved29: DB 0
Physical: DB 0
StreamEnd: DW 0
TransferLeft: DW 0
TransferStart: DW 0
TransferLimit: DW 0
TransferKind: DB 0
NeedSpin: DB 0
LastCmd: DW 0
PayloadPtr: DW 0
DataPtrs: DS 64,0
Validating: DB 0
Mismatch: DB 0
ReadStatus: DB 0
WindowOpen: DB 0
RetryLeft: DB 0
TrackTries: DB 0
Reselect: DB 0                         ; 1 — после сообщения вернуться к выбору дисковода
ErrorCode: DB 0
VerifyPass: DB 0
LastRead: DW 0
ReadLeft: DW 0
ReadDst: DW 0
TargetBase: DD 0
SeqBase: DD 0
SeqNext: DD 0
SeqValid: DB 0
ChangedBytes: DS 64,0
Ignored: DS 32,0
Filex: DS 32,0
TrackDesc: DS 7+32*7,0
Plans: DS 32,0                         ; 0 — good, 1 — bad CRC, 2 — bad CRC с заменами
Window: DS 22,0
Line: DS 41,32
Bar: DS 40,32
FileName: DS 257,0
StateEnd:
CodeEnd:
        ASSERT CodeEnd <= SEQBUF
        ASSERT SEQBUF+512 <= IOBUF
        ASSERT IOBUF+1024 <= #B000
        ASSERT STREAM+MAXSTREAM <= PAYLOAD
        ASSERT PAYLOAD+TIGHTEND <= #10000
        ENT
        DS ((CodeEnd-CodeStart+511)/512)*512-(CodeEnd-CodeStart),0
FileEnd:
        SAVEBIN "build/FDI2FDD.WMF",FileStart,FileEnd-FileStart
