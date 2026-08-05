; Автономная проверка FILEX на физически заполненном FAT32-томе.
; Образ заранее содержит ноль свободных кластеров, но файл результата имеет
; выделенный сектор, поэтому итог сохраняется без дополнительной аллокации.

        DEVICE ZXSPECTRUM128

        INCLUDE "../../source/CORE32_FILEX_API.ASM"

WLD                     EQU #6006
RESULT_STATUS           EQU RESULT_BUFFER+8
RESULT_API_STATUS       EQU RESULT_BUFFER+9
RESULT_STAGE            EQU RESULT_BUFFER+10
RESULT_BLOCK_STATUS     EQU RESULT_BUFFER+11

        ORG #0000
START_CODE:
        DS 16,0
        DB "WildCommanderMDL"
        DB #0A
        DB #00
        DB #01
        DB #00
        DB #00,(PLUGIN_FILE_END-MAIN_FILE_START+511)/512
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DB #00,#00
        DS 16,0
        DS 32*3,0
        DB #00
        DD #FFFFFFFF
FILEXNST_PLUGIN_NAME:
        DB "FILEX full disk regression"
        DS 32-($-FILEXNST_PLUGIN_NAME)," "
        DB #03
        DB #00

        ALIGN 512,0
MAIN_FILE_START:
        DISP #8000

PLUGIN:
        PUSH IX
        CALL GEDPL
        LD D,#FE:CALL STREAM_API
        LD D,#FF:CALL STREAM_API
        CALL INITIALIZE_RESULT

        LD A,1:LD (RESULT_STAGE),A
        LD HL,TEST_DIRECTORY_FIND
        CALL FENTRY
        JP Z,FAIL_SEARCH
        LD DE,ENTRY_BUFFER
        CALL TENTRY
        LD HL,(ENTRY_BUFFER+26),DE,(ENTRY_BUFFER+20)
        LD A,D:AND #0F:LD D,A
        CALL GDIR

        LD A,2:LD (RESULT_STAGE),A
        LD HL,NO_SPACE_FIND
        CALL FENTRY
        JP Z,FAIL_SEARCH
        CALL RESET_FILEX_BLOCK
        LD A,FILEX_OP_SET_EOF32
        LD (FILEX_BLOCK+FILEX_P_OPERATION),A
        LD HL,1
        LD (FILEX_BLOCK+FILEX_P_OFFSET),HL
        LD HL,FILEX_BLOCK
        LD A,77
        CALL WLD
        LD (RESULT_API_STATUS),A
        LD A,(FILEX_BLOCK+FILEX_P_STATUS)
        LD (RESULT_BLOCK_STATUS),A
        CP FILEX_STATUS_NO_SPACE
        JP NZ,FAIL_SEMANTIC
        LD A,(RESULT_API_STATUS)
        CP FILEX_STATUS_NO_SPACE
        JP NZ,FAIL_SEMANTIC

        ; Повторный FENTRY/TENTRY проверяет именно опубликованную запись:
        ; размер и первый кластер обязаны остаться нулевыми.
        LD A,3:LD (RESULT_STAGE),A
        LD HL,NO_SPACE_FIND
        CALL FENTRY
        JP Z,FAIL_SEARCH
        LD DE,ENTRY_BUFFER
        CALL TENTRY
        LD HL,(ENTRY_BUFFER+20)
        LD A,H:OR L:JP NZ,FAIL_SEMANTIC
        LD HL,(ENTRY_BUFFER+26)
        LD A,H:OR L:JP NZ,FAIL_SEMANTIC
        LD HL,(ENTRY_BUFFER+28)
        LD A,H:OR L:JP NZ,FAIL_SEMANTIC
        LD HL,(ENTRY_BUFFER+30)
        LD A,H:OR L:JP NZ,FAIL_SEMANTIC

        LD A,#FF:LD (RESULT_STAGE),A
        LD A,1:LD (RESULT_STATUS),A
        JP WRITE_RESULT

FAIL_SEARCH:
        LD A,#FD
        LD (RESULT_API_STATUS),A
        JR FAIL
FAIL_SEMANTIC:
FAIL:
        LD A,#FF:LD (RESULT_STATUS),A

WRITE_RESULT:
        LD HL,RESULT_FIND
        CALL FENTRY
        JR Z,FINISH
        CALL GFILE
        LD HL,RESULT_BUFFER
        LD B,1
        CALL SAVE512
FINISH:
        POP IX
        RET

INITIALIZE_RESULT:
        LD HL,RESULT_BUFFER,DE,RESULT_BUFFER+1,BC,511
        XOR A:LD (HL),A:LDIR
        LD HL,RESULT_SIGNATURE_BYTES,DE,RESULT_BUFFER,BC,8
        LDIR
        RET

RESET_FILEX_BLOCK:
        LD HL,FILEX_BLOCK,DE,FILEX_BLOCK+1,BC,FILEX_BLOCK_SIZE-1
        XOR A:LD (HL),A:LDIR
        LD A,FILEX_BLOCK_SIZE:LD (FILEX_BLOCK+FILEX_P_SIZE),A
        LD A,FILEX_API_VERSION:LD (FILEX_BLOCK+FILEX_P_VERSION),A
        RET

GEDPL:
        LD A,15:JP WLD
STREAM_API:
        LD A,57:JP WLD
SAVE512:
        LD A,49:JP WLD
TENTRY:
        LD A,51:JP WLD
FENTRY:
        LD A,59:JP WLD
GFILE:
        LD A,62:JP WLD
GDIR:
        LD A,63:JP WLD

RESULT_SIGNATURE_BYTES:
        DB "FILEXNS1"
TEST_DIRECTORY_FIND:
        DB #10,"FXFULL",0
NO_SPACE_FIND:
        DB #00,"NOSPACE.BIN",0
RESULT_FIND:
        DB #00,"NSRESULT.BIN",0

FILEX_BLOCK:
        DS FILEX_BLOCK_SIZE,0
ENTRY_BUFFER:
        DS 32,0
RESULT_BUFFER:
        DS 512,0

        ENT
PLUGIN_FILE_END:
        SAVEBIN "Build/FILEXNST.WMF",START_CODE,PLUGIN_FILE_END-START_CODE
