; Поток 0 идёт только вперёд. Поток 1 нужен исключительно FILEX fallback:
; позиционная операция не должна менять кластер/NSDC потока 0.
; SEQBUF — один физический блок, в том числе частичный последний блок.
OpenInput:
        LD HL,FileName
        LD A,59
        CALL WLD
        JR Z,InputError
        LD (FileSize),HL
        LD (FileSize+2),DE
        LD A,62
        CALL WLD
        JP C,InputError
        LD D,#FE
        LD A,57
        CALL WLD
        XOR A
        RET
InputError:
        LD A,ERR_FILE
        SCF
        RET
ReadSequential:
        LD (LastRead),BC
        CALL RangeCheck
        RET C
        LD (ReadLeft),BC
        LD HL,IOBUF
        LD (ReadDst),HL
        ; Блок запроса раньше текущего кеша: только здесь обычный READ_AT.
        LD A,(SeqValid)
        OR A
        JR Z,.loop
        LD HL,(ReqOff+2)
        LD DE,(SeqBase+2)
        OR A
        SBC HL,DE
        JP C,ReadBlock
        JR NZ,.loop
        LD HL,(ReqOff)
        LD DE,(SeqBase)
        OR A
        SBC HL,DE
        JP C,ReadBlock
.loop: LD HL,(ReqOff)
        LD A,H
        AND #FE
        LD H,A
        LD L,0
        LD (TargetBase),HL
        LD HL,(ReqOff+2)
        LD (TargetBase+2),HL
        LD A,(SeqValid)
        OR A
        JR Z,.fetch
        LD HL,(TargetBase+2)
        LD DE,(SeqBase+2)
        OR A
        SBC HL,DE
        JR NZ,.fetch
        LD HL,(TargetBase)
        LD DE,(SeqBase)
        OR A
        SBC HL,DE
        JR Z,.copy
.fetch:
        ; Не смешивать LOADNONE с отложенными байтами кеша: пропускаем
        ; только полные НЕПРОЧИТАННЫЕ блоки от реального SeqNext.
        LD HL,(SeqNext+2)
        LD DE,(TargetBase+2)
        OR A
        SBC HL,DE
        JR NZ,.skip
        LD HL,(SeqNext)
        LD DE,(TargetBase)
        OR A
        SBC HL,DE
        JR Z,.read
.skip: PUSH IY
        LD HL,SEQBUF
        LD B,1
        LD A,61
        CALL WLD
        POP IY
        JP C,InputError
        CP #FF
        JP Z,InputError
        CALL AdvanceSequence
        XOR A
        LD (SeqValid),A
        JR .fetch
.read: LD HL,(SeqNext)
        LD (SeqBase),HL
        LD HL,(SeqNext+2)
        LD (SeqBase+2),HL
        PUSH IY
        LD HL,SEQBUF
        LD B,1
        LD A,48
        CALL WLD
        POP IY
        JP C,InputError
        LD DE,SEQBUF+512
        OR A
        SBC HL,DE
        JP NZ,InputError               ; короткий блок/EOF не маскируется
        CALL AdvanceSequence
        LD A,1
        LD (SeqValid),A
.copy: LD HL,(ReqOff)
        LD A,H
        AND 1
        LD H,A                          ; смещение внутри 512
        PUSH HL
        LD DE,512
        EX DE,HL
        OR A
        SBC HL,DE                       ; доступно в кеше
        LD DE,(ReadLeft)
        OR A
        SBC HL,DE
        LD BC,(ReadLeft)
        JR C,.limited
        JR .length
.limited:
        ADD HL,DE
        LD B,H
        LD C,L
.length:
        POP HL
        LD DE,SEQBUF
        ADD HL,DE
        LD DE,(ReadDst)
        PUSH BC
        LDIR
        LD (ReadDst),DE
        POP BC
        LD HL,(ReqOff)
        ADD HL,BC
        LD (ReqOff),HL
        JR NC,.nohigh
        LD HL,(ReqOff+2)
        INC HL
        LD (ReqOff+2),HL
.nohigh:
        LD HL,(ReadLeft)
        OR A
        SBC HL,BC
        LD (ReadLeft),HL
        LD A,H
        OR L
        JP NZ,.loop
        RET
AdvanceSequence:
        LD HL,(SeqNext)
        LD DE,512
        ADD HL,DE
        LD (SeqNext),HL
        RET NC
        LD HL,(SeqNext+2)
        INC HL
        LD (SeqNext+2),HL
        OR A
        RET
