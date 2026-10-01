; Проверка таблицы/диапазонов и создание MFM-потока.
; Ни один FDC OUT не разрешён до успешного завершения Validate.

; BC=длина, ReqOff=LE32, выход IOBUF. Проверяем диапазон до вызова FILEX.
RangeCheck:
        LD HL,(ReqOff)
        ADD HL,BC
        LD DE,(ReqOff+2)
        JR NC,.nocarry
        INC DE
        LD A,D
        OR E
        JP Z,ImageError
.nocarry:
        PUSH HL
        LD HL,(FileSize+2)
        OR A
        SBC HL,DE
        POP HL
        JP C,OffsetError
        JR NZ,.fits
        LD DE,(FileSize)
        OR A
        SBC HL,DE
        JP C,.fits
        JP NZ,OffsetError
.fits:
        OR A
        RET
ReadBlock:
        CALL RangeCheck
        RET C
        PUSH BC
        LD HL,Filex
        LD DE,Filex+1
        LD BC,31
        LD (HL),0
        LDIR
        LD HL,#0120
        LD (Filex),HL
        LD A,1
        LD (Filex+2),A
        LD HL,(ReqOff)
        LD (Filex+4),HL
        LD HL,(ReqOff+2)
        LD (Filex+6),HL
        LD HL,IOBUF
        LD (Filex+8),HL
        POP BC
        LD (Filex+10),BC
        PUSH IY
        LD D,1                         ; отдельный поток: FILEX меняет состояние DOS
        LD BC,#FFFF
        LD A,57
        CALL WLD
        LD HL,Filex
        LD A,77
        CALL WLD
        PUSH AF
        LD D,0
        LD BC,#FFFF
        LD A,57
        CALL WLD
        POP AF
        POP IY
        OR A
        JR NZ,.bad
        LD HL,(Filex+24)
        LD DE,(Filex+10)
        OR A
        SBC HL,DE
        JR NZ,.bad
        LD HL,(Filex+26)
        LD A,H
        OR L
        RET Z
.bad:  LD A,ERR_FILE
        SCF
        RET
ImageError:
        LD A,ERR_IMAGE
        SCF
        RET
OffsetError:
        LD HL,MsgOffset
        LD (ImageReason),HL
        JP ImageError
CapacityError:
        LD HL,MsgCapacity
        LD (ImageReason),HL
        JP ImageError
SizeCodeError:
        LD HL,MsgSizeCode
        LD (ImageReason),HL
        JP ImageError

MapTable:
        LD A,1
        EX AF,AF'
        XOR A
        JP WLD
MapTrack:
        LD A,2
        EX AF,AF'
        XOR A
        JP WLD

Validate:
        LD HL,(FileSize+2)
        LD DE,#0010
        OR A
        SBC HL,DE
        JP C,.sizeok
        JP NZ,ImageError
        LD HL,(FileSize)
        LD A,H
        OR L
        JP NZ,ImageError
.sizeok:
        LD BC,14
        CALL ReadSequential
        RET C
        LD HL,(IOBUF)
        LD DE,#4446
        OR A
        SBC HL,DE
        JP NZ,ImageError
        LD A,(IOBUF+2)
        CP 'I'
        JP NZ,ImageError
        LD A,(IOBUF+3)
        CP 2
        JP NC,ImageError
        LD HL,(IOBUF+4)
        LD A,H
        OR A
        JP NZ,ImageError
        LD A,L
        OR A
        JP Z,ImageError
        CP 87
        JP NC,ImageError
        LD HL,(IOBUF+6)
        LD A,H
        OR A
        JP NZ,ImageError
        LD A,L
        OR A
        JP Z,ImageError
        CP 3
        JP NC,ImageError
        LD (Heads),A
        LD HL,(IOBUF+4)
        CP 1
        JR Z,.heads
        ADD HL,HL
.heads:
        LD (TracksTotal),HL
        LD HL,(IOBUF+10)
        LD (DataOff),HL
        LD DE,#3F01                    ; таблица/описание занимают не более 16128
        OR A
        SBC HL,DE
        JP NC,ImageError
        LD HL,(IOBUF+12)
        LD DE,14
        ADD HL,DE
        JP C,ImageError
        LD (TableStart),HL
        LD DE,(DataOff)
        OR A
        SBC HL,DE
        JP NC,ImageError
        LD HL,(IOBUF+8)
        LD A,H
        OR L
        JR NZ,.desc
        LD HL,(DataOff)
        JR .limit
.desc:  LD DE,(DataOff)
        OR A
        SBC HL,DE
        JP NC,ImageError
        ADD HL,DE
.limit: LD DE,#C000
        ADD HL,DE
        LD (TableLimit),HL
        LD HL,0
        LD (DataSum),HL
.cache:
        LD HL,(DataOff)
        LD DE,(DataSum)
        OR A
        SBC HL,DE
        LD A,H
        OR L
        JR Z,.cached
        LD BC,1024
        LD A,H
        CP 4
        JR NC,.chunk
        LD B,H
        LD C,L
.chunk:
        LD (ReqOff),DE
        LD HL,0
        LD (ReqOff+2),HL
        CALL ReadSequential
        RET C
        CALL MapTable
        LD HL,(DataSum)
        LD BC,#C000
        ADD HL,BC
        EX DE,HL
        LD HL,IOBUF
        LD BC,(LastRead)
        LDIR
        LD HL,(DataSum)
        LD BC,(LastRead)
        ADD HL,BC
        LD (DataSum),HL
        JR .cache
.cached:
        ; Если описание есть, требуем завершающий NUL до начала данных.
        LD HL,(#C008)
        LD A,H
        OR L
        JR Z,.nodesc
        LD DE,#C000
        ADD HL,DE
        LD DE,(DataOff)
        LD BC,#C000
        EX DE,HL
        ADD HL,BC
        EX DE,HL
.descscan:
        LD A,(HL)
        OR A
        JR Z,.nodesc
        INC HL
        PUSH HL
        OR A
        SBC HL,DE
        POP HL
        JP NC,ImageError
        JR .descscan
.nodesc:
        LD A,1
        LD (Validating),A
        CALL ResetTracks
.track:
        CALL BreakCheck
        RET C
        CALL LoadTrack
        RET C
        CALL PrepareTrack
        RET C
        CALL NextTrack
        JR NZ,.track
        XOR A
        LD (Validating),A
        RET

ResetTracks:
        LD HL,(TableStart)
        LD DE,#C000
        ADD HL,DE
        LD (TablePtr),HL
        LD HL,(TracksTotal)
        LD (TracksLeft),HL
        XOR A
        LD (Cylinder),A
        LD (Side),A
        RET
NextTrack:
        LD A,(Side)
        INC A
        LD B,A
        LD A,(Heads)
        CP B
        LD A,B
        JR NZ,.side
        XOR A
        LD HL,Cylinder
        INC (HL)
.side: LD (Side),A
        LD HL,(TracksLeft)
        DEC HL
        LD (TracksLeft),HL
        LD A,H
        OR L
        RET

LoadTrack:
        CALL MapTable
        LD HL,(TablePtr)
        LD BC,7
        CALL TableBounds
        RET C
        PUSH HL
        LD DE,6
        ADD HL,DE
        LD A,(HL)
        LD (SectorCount),A
        POP HL
        CP 33
        JP NC,ImageError
        LD E,A
        LD D,0
        PUSH HL
        LD H,D
        LD L,E
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        OR A
        SBC HL,DE
        LD DE,7
        ADD HL,DE
        LD B,H
        LD C,L
        POP HL
        CALL TableBounds
        RET C
        LD DE,TrackDesc
        LDIR
        LD (TablePtr),HL
        LD HL,(TrackDesc+4)
        LD A,H
        OR L
        JP NZ,ImageError
        LD HL,(TrackDesc)
        LD DE,(DataOff)
        ADD HL,DE
        LD (TrackBase),HL
        LD HL,(TrackDesc+2)
        LD DE,0
        ADC HL,DE
        JP C,ImageError
        LD (TrackBase+2),HL
        ; Даже у пустой дорожки база не должна указывать за EOF.
        LD HL,(TrackBase)
        LD (ReqOff),HL
        LD HL,(TrackBase+2)
        LD (ReqOff+2),HL
        LD BC,0
        ; Только проверка диапазона: FILEX с length=0 не требуется.
        LD DE,(FileSize+2)
        OR A
        SBC HL,DE
        JP C,.ok
        JP NZ,ImageError
        LD HL,(FileSize)
        LD DE,(TrackBase)
        OR A
        SBC HL,DE
        JP C,ImageError
.ok:   XOR A
        RET
TableBounds:
        PUSH HL
        ADD HL,BC
        JR C,.bad
        LD DE,(TableLimit)
        OR A
        SBC HL,DE
        JR C,.ok
        JR NZ,.bad
.ok:   POP HL
        OR A
        RET
.bad:  POP HL
        JP ImageError

; IY — исходный C/H/R/N/flags/offset, индекс — SectorIndex.
PrepareTrack:
        LD HL,ChangedBytes
        LD DE,ChangedBytes+1
        LD BC,95                       ; счёт замен и флаги Ignore текущей дорожки
        LD (HL),0
        LDIR
        LD HL,0
        LD (DataSum),HL
        LD HL,PAYLOAD
        LD (PayloadPtr),HL
        XOR A
        LD (SectorIndex),A
        LD IY,TrackDesc+7
.sector:
        LD A,(SectorCount)
        LD HL,SectorIndex
        CP (HL)
        JP Z,.gaps
        LD A,(IY+3)
        CP 4                           ; 1793 поддерживает только 128..1024
        JP NC,SizeCodeError
        LD HL,128
        LD B,A
        OR A
        JR Z,.length
.shift: ADD HL,HL
        DJNZ .shift
.length:
        LD (SectorSize),HL
        LD DE,(DataSum)
        ADD HL,DE
        LD (DataSum),HL
        LD DE,TIGHTEND-32+1
        OR A
        SBC HL,DE
        JP NC,CapacityError
        LD A,(IY+4)
        BIT 6,A
        JP NZ,ImageError
        LD A,(IY+0)
        CALL CheckLiteral
        RET C
        LD A,(IY+1)
        CALL CheckLiteral
        RET C
        LD A,(IY+2)
        CALL CheckLiteral
        RET C
        ; S=0 у sector commands: H не сравнивается. Дубли C/R неоднозначны.
        LD HL,TrackDesc+7
        LD A,(SectorIndex)
        LD B,A
        OR A
        JR Z,.unique
.dup:  LD A,(HL)
        CP (IY+0)
        JR NZ,.other
        INC HL
        INC HL
        LD A,(HL)
        CP (IY+2)
        DEC HL
        DEC HL
        JP Z,ImageError
.other:
        LD DE,7
        ADD HL,DE
        DJNZ .dup
.unique:
        LD HL,(TrackBase)
        LD E,(IY+5)
        LD D,(IY+6)
        ADD HL,DE
        LD (ReqOff),HL
        LD HL,(TrackBase+2)
        LD DE,0
        ADC HL,DE
        JP C,ImageError
        LD (ReqOff+2),HL
        LD BC,(SectorSize)
        CALL RangeCheck                ; все обычные данные проверяются без чтения
        RET C
        LD A,1
        LD B,(IY+3)
        INC B
.mask: DJNZ .rotate
        JR .masked
.rotate:
        ADD A,A
        JR .mask
.masked:
        AND (IY+4)
        LD A,0
        JR NZ,.good
        LD A,1
.good: PUSH AF
        LD A,(Validating)
        OR A
        JR Z,.load
        POP AF
        OR A
        JP Z,.plan                     ; хорошему сектору достаточно таблицы/EOF
        PUSH AF
        LD BC,(SectorSize)
        CALL ReadBlock                 ; только bad CRC до принятия образа
        JR .loaded
.load: LD BC,(SectorSize)
        CALL ReadSequential
.loaded:
        JR NC,.readok
        POP BC
        RET
.readok:
        POP AF
        OR A
        JR Z,.saveplan
        LD HL,IOBUF
        LD BC,(SectorSize)
        LD DE,0
.raw:  LD A,(HL)
        CP #F5
        JR C,.rawnext
        CP #F8
        JR NC,.rawnext
        SUB #10                        ; E5/E6/E7 — литералы, плохой CRC сохраняется
        LD (HL),A
        INC DE
.rawnext:
        INC HL
        DEC BC
        LD A,B
        OR C
        JR NZ,.raw
        LD A,(SectorIndex)
        ADD A,A
        LD C,A
        LD B,0
        LD HL,ChangedBytes
        ADD HL,BC
        LD (HL),E
        INC HL
        LD (HL),D
        LD A,D
        OR E
        LD A,1
        JR Z,.saveplan
        LD A,(Validating)
        OR A
        JR Z,.changed
        LD HL,(ApproxExpected)
        INC HL
        LD (ApproxExpected),HL
        LD HL,(ExpectedBytes)
        ADD HL,DE
        LD (ExpectedBytes),HL
        JR NC,.changed
        LD HL,(ExpectedBytes+2)
        INC HL
        LD (ExpectedBytes+2),HL
.changed:
        LD A,2
.saveplan:
        PUSH AF
        CALL MapTrack
        LD A,(SectorIndex)
        ADD A,A
        LD E,A
        LD D,0
        LD HL,DataPtrs
        ADD HL,DE
        LD DE,(PayloadPtr)
        LD (HL),E
        INC HL
        LD (HL),D
        LD HL,IOBUF
        LD BC,(SectorSize)
        LDIR
        LD (PayloadPtr),DE
        POP AF
.plan: PUSH AF
        LD A,(SectorIndex)
        LD E,A
        LD D,0
        LD HL,Plans
        ADD HL,DE
        POP AF
        LD (HL),A
        LD DE,7
        ADD IY,DE
        LD HL,SectorIndex
        INC (HL)
        JP .sector
.gaps:
        XOR A
        LD (Tight),A
        LD A,12
        LD (SyncZeros),A
        LD A,54
        LD (Gap3),A
.fit:  LD HL,(DataSum)
        LD DE,146
        ADD HL,DE
        LD A,(Gap3)
        ADD A,62
        LD E,A
        LD D,0
        LD A,(SectorCount)
        LD B,A
        OR A
        JR Z,.fitted
.gap:  ADD HL,DE
        DJNZ .gap
        LD DE,SAFEEND+1
        OR A
        SBC HL,DE
        JR C,.fitted
        LD HL,Gap3
        DEC (HL)
        LD A,(HL)
        CP 23
        JR NZ,.fit
        ; Non-IBM: IAM не нужен; 32*4E до первого ID, 8*00 перед ID,
        ; ровно 12*00 перед DAM, три A1, GAP2=22, GAP3=24.
        LD A,1
        LD (Tight),A
        LD A,8
        LD (SyncZeros),A
        LD A,24
        LD (Gap3),A
        LD HL,(DataSum)
        LD DE,32
        ADD HL,DE
        LD DE,58+24
        LD A,(SectorCount)
        LD B,A
.tightgap:
        ADD HL,DE
        DJNZ .tightgap
        LD DE,TIGHTEND+1
        OR A
        SBC HL,DE
        JP NC,CapacityError
.fitted:
        XOR A
        RET
CheckLiteral:
        CP #F5
        JR C,.ok
        CP #F8
        JP C,ImageError
.ok:
        OR A
        RET

; BuildStream строит только в странице 2. Файл уже прочитан целиком на дорожку.
BuildStream:
        CALL MapTrack
        LD HL,STREAM
        LD DE,STREAM+1
        LD BC,MAXSTREAM-1
        LD (HL),#4E
        LDIR
        LD HL,STREAM
        LD A,(Tight)
        OR A
        JR Z,.normal
        LD B,32
        LD A,#4E
        CALL Fill
        JR .prefixdone
.normal:
        LD B,80
        LD A,#4E
        CALL Fill
        LD B,12
        XOR A
        CALL Fill
        LD B,3
        LD A,#F6
        CALL Fill
        LD (HL),#FC
        INC HL
        LD B,50
        LD A,#4E
        CALL Fill
.prefixdone:
        LD IY,TrackDesc+7
        XOR A
        LD (SectorIndex),A
.sector:
        LD A,(SectorIndex)
        LD DE,SectorCount
        LD A,(DE)
        LD DE,SectorIndex
        EX DE,HL
        CP (HL)
        EX DE,HL
        JP Z,.done
        CALL Sync
        LD (HL),#FE
        INC HL
        LD A,(IY+0)
        LD (HL),A
        INC HL
        LD A,(IY+1)
        LD (HL),A
        INC HL
        LD A,(IY+2)
        LD (HL),A
        INC HL
        LD A,(IY+3)
        LD (HL),A
        INC HL
        LD (HL),#F7
        INC HL
        LD B,22
        LD A,#4E
        CALL Fill
        CALL DataSync
        LD A,(IY+4)
        AND #80
        LD A,#FB
        JR Z,.dam
        LD A,#F8
.dam:  LD (HL),A
        INC HL
        PUSH HL
        CALL GetPayload
        POP DE                          ; DE — место данных в потоке
        PUSH BC
        LD A,(SectorIndex)
        PUSH HL
        LD HL,Plans
        LD C,A
        LD B,0
        ADD HL,BC
        LD A,(HL)
        POP HL
        POP BC
        OR A
        JR NZ,.badcrc
        EX DE,HL
        XOR A
.zero: LD (HL),A
        INC HL
        DEC BC
        LD A,B
        OR C
        JR NZ,.zeroreset
        LD (HL),#F7
        INC HL
        JR .gap3
.zeroreset:
        XOR A
        JR .zero
.badcrc:
        PUSH HL
        PUSH BC
        LDIR
        EX DE,HL                        ; HL — после данных
        PUSH HL
        POP IX
        POP BC
        POP HL                          ; исходные данные, длина BC
        LD DE,#CDB4                     ; CRC после A1 A1 A1
        LD A,(IY+4)
        AND #80
        LD A,#FB
        JR Z,.crcmark
        LD A,#F8
.crcmark:
        CALL CRCByte
.crcdata:
        LD A,(HL)
        INC HL
        CALL CRCByte
        DEC BC
        LD A,B
        OR C
        JR NZ,.crcdata
        LD A,D
        OR E
        LD A,0
        JR NZ,.wrong
        INC A                           ; если правильный CRC=0000, записываем 0001
.wrong: LD (IX+0),0
        LD (IX+1),A
        PUSH IX
        POP HL
        INC HL
        INC HL
.gap3: LD A,(Gap3)
        LD B,A
        LD A,#4E
        CALL Fill
        LD DE,7
        ADD IY,DE
        LD DE,SectorIndex
        LD A,(DE)
        INC A
        LD (DE),A
        JP .sector
.done: LD (StreamEnd),HL
        RET
Fill:  LD (HL),A
        INC HL
        DJNZ Fill
        RET
Sync:  LD A,(SyncZeros)
        LD B,A
        JR SyncRun
DataSync:
        LD B,12
SyncRun:
        XOR A
        CALL Fill
        LD A,#F5
        LD B,3
        JP Fill
GetPayload:
        LD A,(IY+3)
        LD BC,128
        OR A
        JR Z,.len
.shift: SLA C
        RL B
        DEC A
        JR NZ,.shift
.len:  LD A,(SectorIndex)
        ADD A,A
        LD E,A
        LD D,0
        LD HL,DataPtrs
        ADD HL,DE
        LD E,(HL)
        INC HL
        LD D,(HL)
        EX DE,HL
        RET
CRCByte:
        PUSH BC
        XOR D
        LD D,A
        LD B,8
.bit:  SLA E
        RL D
        JR NC,.next
        LD A,D
        XOR #10
        LD D,A
        LD A,E
        XOR #21
        LD E,A
.next: DJNZ .bit
        POP BC
        RET
