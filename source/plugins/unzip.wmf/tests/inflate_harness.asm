; Тестовая обвязка ядра Deflate для эмулятора Z80 (tests/test_inflate_z80.py).
; Образ грузится в #8000. Блок управления в #7E00:
;   +0 адрес входа, +2 длина входа, +4 результат (1 — успех), +5 zip_error,
;   +6 прочитано байт входа, +8 размер выхода (32 бита).
; Выход пишется только в кольцо истории (#0000..#3FFF и #C000..#FFFF).
                DEVICE ZXSPECTRUM128
                ORG #8000
harness_entry:
                ld hl,(#7E00)
                ld (in_ptr),hl
                ld (in_start),hl
                ld de,(#7E02)
                add hl,de
                ld (in_end),hl
                xor a
                ld (zip_error),a
                call out_reset
                call inflate_raw
                jr c,.fail
                call out_finish
                ld a,1
.done:          ld (#7E04),a
                ld a,(zip_error)
                ld (#7E05),a
                ld hl,(in_ptr)
                ld de,(in_start)
                or a
                sbc hl,de
                ld (#7E06),hl
                ld hl,(out_flushed)
                ld (#7E08),hl
                ld hl,(out_flushed+2)
                ld (#7E0A),hl
                ret
.fail:          xor a
                jr .done

; Единственное окно входа: больше данных нет.
in_more:        scf
                ret

; Отрезки кольца никуда не пишутся.
out_flush_hook: or a
                ret

core_fail:      ld a,1
                ld (zip_error),a
                ret

                INCLUDE "../src/inflate.asm"

zip_error       DB 0
in_start        DW 0
                INFLATE_VARS
                INFLATE_PAGES
harness_end:
                SAVEBIN "build/inflate_test.bin",#8000,harness_end-#8000
