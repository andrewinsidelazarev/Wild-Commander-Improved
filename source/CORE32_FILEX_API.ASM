; Публичный ABI FILEX для Wild Commander Improved.
;
; Публичный вход: A=77, CALL #6006, HL указывает на блок FILEX_BLOCK_SIZE.
; Блок и все переданные буферы должны целиком лежать в #8000..#BFFF; буферы
; не должны пересекать блок параметров. API глобален и нереентерабелен.
; После возврата A и Z/NZ содержат status (Z только для OK), поля результата
; заполнены в блоке. AF/BC/DE/HL/IX считаются разрушенными, IY сохраняется.

FILEX_API_VERSION              EQU 1
FILEX_BLOCK_SIZE               EQU 32

FILEX_P_SIZE                   EQU 0
FILEX_P_VERSION                EQU 1
FILEX_P_OPERATION              EQU 2
FILEX_P_FLAGS                  EQU 3
FILEX_P_OFFSET                 EQU 4       ; dd: file offset or new EOF
FILEX_P_BUFFER                 EQU 8       ; dw: data/output/source-name buffer
FILEX_P_LENGTH                 EQU 10      ; dw: data/output buffer length
FILEX_P_AUX                    EQU 12      ; dw: secondary buffer/destination name
FILEX_P_AUX_LENGTH             EQU 14      ; dw: secondary buffer length
FILEX_P_SOURCE_DIR             EQU 16      ; dd: source directory cluster
FILEX_P_DEST_DIR               EQU 20      ; dd: destination directory cluster
FILEX_P_RESULT_COUNT           EQU 24      ; dd: bytes processed / capabilities
FILEX_P_STATUS                 EQU 28      ; db: FILEX_STATUS_*
FILEX_P_RESULT_FLAGS           EQU 29      ; db: operation-specific result
FILEX_P_RESERVED               EQU 30      ; dw: must be zero on input

FILEX_OP_QUERY_CAPS            EQU 0
FILEX_OP_READ_AT               EQU 1
FILEX_OP_WRITE_AT              EQU 2
FILEX_OP_SET_EOF32             EQU 3
FILEX_OP_GET_FS_INFO           EQU 4
FILEX_OP_MOVE_RENAME           EQU 5
FILEX_OP_SET_METADATA          EQU 6
FILEX_OP_READ_FAT              EQU 7
FILEX_OP_COUNT                 EQU 8

FILEX_CAP_READ_AT              EQU %00000001
FILEX_CAP_WRITE_AT             EQU %00000010
FILEX_CAP_SET_EOF32            EQU %00000100
FILEX_CAP_GET_FS_INFO          EQU %00001000
FILEX_CAP_MOVE_RENAME          EQU %00010000
FILEX_CAP_SET_METADATA         EQU %00100000
FILEX_CAP_MOVE_CURRENT_DIR     EQU %01000000
FILEX_CAP_READ_FAT             EQU %10000000

FILEX_FLAG_REPLACE             EQU %00000001
FILEX_FLAG_CURRENT_DIR         EQU %00000010
FILEX_FLAG_REFRESH_FREE        EQU %00000001

FILEX_STATUS_OK                EQU #00
FILEX_STATUS_EOF               EQU #01
FILEX_STATUS_BAD_BLOCK         EQU #10
FILEX_STATUS_BAD_VERSION       EQU #11
FILEX_STATUS_BAD_OPERATION     EQU #12
FILEX_STATUS_BAD_BUFFER        EQU #13
FILEX_STATUS_BAD_LENGTH        EQU #14
FILEX_STATUS_NO_CONTEXT        EQU #15
FILEX_STATUS_ENTRY_CHANGED     EQU #16
FILEX_STATUS_IS_DIRECTORY      EQU #17
FILEX_STATUS_READ_ONLY         EQU #18
FILEX_STATUS_NOT_FOUND         EQU #19
FILEX_STATUS_EXISTS            EQU #1A
FILEX_STATUS_NOT_EMPTY         EQU #1B
FILEX_STATUS_INVALID_NAME      EQU #1C
FILEX_STATUS_INVALID_MOVE      EQU #1D
FILEX_STATUS_FAT               EQU #20
FILEX_STATUS_MEDIA             EQU #21
FILEX_STATUS_NO_SPACE          EQU #22
FILEX_STATUS_SIZE_OVERFLOW     EQU #23
FILEX_STATUS_ROLLBACK          EQU #24
FILEX_STATUS_COMMITTED_CLEANUP EQU #25
FILEX_STATUS_INTERNAL          EQU #26

; Выходная структура GET_FS_INFO в FILEX_P_BUFFER, минимум FILEX_FS_SIZE байт.
FILEX_FS_SIZE                  EQU 48
FILEX_FS_VERSION               EQU 1
FILEX_FS_O_SIZE                EQU 0       ; db
FILEX_FS_O_VERSION             EQU 1       ; db
FILEX_FS_O_FLAGS               EQU 2       ; db: FILEX_FS_FLAG_*
FILEX_FS_O_SECTORS_PER_CLUSTER EQU 3       ; db
FILEX_FS_O_BYTES_PER_SECTOR    EQU 4       ; dw
FILEX_FS_O_RESERVED            EQU 6       ; dw
FILEX_FS_O_TOTAL_CLUSTERS      EQU 8       ; dd
FILEX_FS_O_FREE_CLUSTERS       EQU 12      ; dd or #FFFFFFFF
FILEX_FS_O_SERIAL              EQU 16      ; dd
FILEX_FS_O_LABEL               EQU 20      ; 11 bytes plus zero
FILEX_FS_O_TOTAL_SECTORS       EQU 32      ; dd
FILEX_FS_O_NEXT_FREE           EQU 36      ; dd or #FFFFFFFF
FILEX_FS_O_FAT_COUNT           EQU 40      ; db
FILEX_FS_O_ACTIVE_FAT          EQU 41      ; db
FILEX_FS_O_FAT_FLAGS           EQU 42      ; db (BPB_ExtFlags low byte)
FILEX_FS_O_MEDIA_STATE         EQU 43      ; db
FILEX_FS_O_FAT_SECTORS         EQU 44      ; dd

FILEX_FS_FLAG_MEDIA_PRESENT    EQU %00000001
FILEX_FS_FLAG_WRITABLE         EQU %00000010
FILEX_FS_FLAG_FREE_KNOWN       EQU %00000100
FILEX_FS_FLAG_LABEL_VALID      EQU %00001000
FILEX_FS_FLAG_WRITE_STATE_KNOWN EQU %00010000

; Входная и выходная структура SET_METADATA в FILEX_P_BUFFER.
FILEX_META_SIZE                EQU 16
FILEX_META_O_SIZE              EQU 0
FILEX_META_O_ATTR_MASK         EQU 1
FILEX_META_O_ATTR_VALUE        EQU 2
FILEX_META_O_TIME_MASK         EQU 3
FILEX_META_O_CREATE_TENTH      EQU 4
FILEX_META_O_CREATE_TIME       EQU 5       ; dw
FILEX_META_O_CREATE_DATE       EQU 7       ; dw
FILEX_META_O_ACCESS_DATE       EQU 9       ; dw
FILEX_META_O_WRITE_TIME        EQU 11      ; dw
FILEX_META_O_WRITE_DATE        EQU 13      ; dw
FILEX_META_O_APPLIED_ATTR      EQU 15

FILEX_META_TIME_CREATE         EQU %00000001
FILEX_META_TIME_ACCESS         EQU %00000010
FILEX_META_TIME_WRITE          EQU %00000100
FILEX_META_ALLOWED_ATTRS       EQU #27     ; R/O, hidden, system, archive
