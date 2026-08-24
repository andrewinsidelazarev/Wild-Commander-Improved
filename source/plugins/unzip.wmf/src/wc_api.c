#include "wc_api.h"

#define WCAPI 0x6006

void wc_gedpl(void) __naked
{
    __asm
        push ix
        push iy
        ld a, #15
        call WCAPI
        pop iy
        pop ix
        ret
    __endasm;
}

void wc_clone_streams(void) __naked
{
    __asm
        push ix
        push iy
        ld d, #0xfe
        ld a, #57
        call WCAPI
        pop iy
        pop ix
        ret
    __endasm;
}

void wc_select_stream(u8 stream) __naked
{
    stream;
    __asm
        ld d, a
        ld bc, #0xffff
        push ix
        push iy
        ld a, #57
        call WCAPI
        pop iy
        pop ix
        ret
    __endasm;
}

u8 wc_load_sector(u8 *buffer) __naked
{
    buffer;
    __asm
        push ix
        push iy
        ld b, #1
        ld a, #48
        call WCAPI
        pop iy
        pop ix
        jr c, 00100$
        xor a
        ret
00100$:
        ld a, #1
        ret
    __endasm;
}

u8 wc_fentry(const u8 *query) __naked
{
    query;
    __asm
        push ix
        push iy
        ld a, #59
        call WCAPI
        pop iy
        pop ix
        jr nz, 00100$
        xor a
        ret
00100$:
        ld a, #1
        ret
    __endasm;
}

void wc_gfile(void) __naked
{
    __asm
        push ix
        push iy
        ld a, #62
        call WCAPI
        pop iy
        pop ix
        ret
    __endasm;
}

void wc_gdir(void) __naked
{
    __asm
        push ix
        push iy
        ld a, #63
        call WCAPI
        pop iy
        pop ix
        ret
    __endasm;
}

u8 wc_mkfile(const u8 *create_block) __naked
{
    create_block;
    __asm
        push ix
        push iy
        ld a, #72
        call WCAPI
        pop iy
        pop ix
        jr nz, 00100$
        ld a, #1
        ret
00100$:
        xor a
        ret
    __endasm;
}

u8 wc_mkdir(const u8 *name) __naked
{
    name;
    __asm
        push ix
        push iy
        ld a, #73
        call WCAPI
        pop iy
        pop ix
        jr nz, 00100$
        ld a, #1
        ret
00100$:
        xor a
        ret
    __endasm;
}

u8 wc_delete(const u8 *query) __naked
{
    query;
    __asm
        push ix
        push iy
        ld a, #75
        call WCAPI
        pop iy
        pop ix
        jr nz, 00100$
        xor a
        ret
00100$:
        ld a, #1
        ret
    __endasm;
}

u8 wc_rename(const u8 *old_query, const u8 *new_name) __naked
{
    old_query;
    new_name;
    __asm
        push ix
        push iy
        ld a, #74
        call WCAPI
        pop iy
        pop ix
        jr nz, 00100$
        xor a
        ret
00100$:
        ld a, #1
        ret
    __endasm;
}

u8 wc_append(const u8 *data, u16 length) __naked
{
    data;
    length;
    __asm
        ld b, d
        ld c, e
        push ix
        push iy
        ld a, #76
        call WCAPI
        pop iy
        pop ix
        jr nz, 00100$
        ld a, #1
        ret
00100$:
        xor a
        ret
    __endasm;
}

u8 wc_filex(u8 *block) __naked
{
    block;
    __asm
        push ix
        push iy
        ld a, #77
        call WCAPI
        pop iy
        pop ix
        ret
    __endasm;
}

void wc_map_page_0000(u8 page) __naked
{
    page;
    /* Код 08h — EX AF,AF': номер страницы передаётся через A'. */
    __asm
        .db #0x08
        push ix
        push iy
        ld a, #78
        call WCAPI
        pop iy
        pop ix
        ret
    __endasm;
}

void wc_map_page_c000(u8 page) __naked
{
    page;
    /* Код 08h — EX AF,AF': номер страницы передаётся через A'. */
    __asm
        .db #0x08
        push ix
        push iy
        xor a
        call WCAPI
        pop iy
        pop ix
        ret
    __endasm;
}

void wc_show_window(void) __naked
{
    __asm
        push ix
        push iy
        ld ix, #_unzip_window
        ld a, #1
        call WCAPI
        pop iy
        pop ix
        ret
    __endasm;
}

void wc_close_window(void) __naked
{
    __asm
        push ix
        push iy
        ld ix, #_unzip_window
        ld a, #2
        call WCAPI
        pop iy
        pop ix
        ret
    __endasm;
}

void wc_print(const u8 *text, u16 length, u8 y, u8 x) __naked
{
    text;
    length;
    y;
    x;
    /* HL содержит текст, DE — длину, а Y и X упакованы в слово на стеке. */
    __asm
        ld b, d
        ld c, e
        push hl
        ld hl, #4
        add hl, sp
        ld d, (hl)
        inc hl
        ld e, (hl)
        pop hl
        push ix
        push iy
        ld ix, #_unzip_window
        ld a, #3
        call WCAPI
        pop iy
        pop ix
        pop hl
        inc sp
        inc sp
        jp (hl)
    __endasm;
}

u8 wc_enter(void) __naked
{
    __asm
        push ix
        push iy
        ld a, #22
        call WCAPI
        pop iy
        pop ix
        jr nz, 00100$
        xor a
        ret
00100$:
        ld a, #1
        ret
    __endasm;
}

u8 wc_escape(void) __naked
{
    __asm
        push ix
        push iy
        ld a, #23
        call WCAPI
        pop iy
        pop ix
        jr nz, 00100$
        xor a
        ret
00100$:
        ld a, #1
        ret
    __endasm;
}

u8 wc_scan_key(void) __naked
{
    /* A'=1 просит всегда возвращать код из основной таблицы TAI1. */
    __asm
        ld a, #1
        .db #0x08
        push ix
        push iy
        ld a, #42
        call WCAPI
        pop iy
        pop ix
        ret
    __endasm;
}

u8 wc_any_key(void) __naked
{
    __asm
        push ix
        push iy
        ld a, #45
        call WCAPI
        pop iy
        pop ix
        jr nz, 00100$
        xor a
        ret
00100$:
        ld a, #1
        ret
    __endasm;
}

void wc_wait_key_release(void) __naked
{
    __asm
        push ix
        push iy
        ld a, #46
        call WCAPI
        pop iy
        pop ix
        ret
    __endasm;
}

void wc_wait_frame(void) __naked
{
    __asm
        ei
        halt
        ret
    __endasm;
}
