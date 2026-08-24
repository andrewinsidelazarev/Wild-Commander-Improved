/*
 * Компактный потоковый декодер RFC 1951 для ZIP-плагина Wild Commander.
 *
 * Построение и декодирование канонических кодов Хаффмана выполнено по
 * открытому эталонному коду puff.c Марка Адлера из zlib/contrib/puff
 * (лицензия zlib). Остальной код адаптирован для потоковой работы на Z80:
 * вход читается из потока Commander, а результат записывается частями.
 */
#include "inflate.h"

#define MAX_BITS 15
#define MAX_LIT_CODES 286
#define MAX_DIST_CODES 30
#define FIXED_LIT_CODES 288
#define MAX_CODES (MAX_LIT_CODES + MAX_DIST_CODES)

static u8 bit_buffer;
static u8 bit_count;

static u8 lengths[MAX_CODES];
static u16 lit_count[MAX_BITS + 1];
static u16 lit_symbol[FIXED_LIT_CODES];
static u16 dist_count[MAX_BITS + 1];
static u16 dist_symbol[MAX_DIST_CODES];
static u16 offsets[MAX_BITS + 1];

static const u16 length_base[29] = {
    3, 4, 5, 6, 7, 8, 9, 10,
    11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115,
    131, 163, 195, 227, 258
};

static const u8 length_extra[29] = {
    0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4,
    5, 5, 5, 5, 0
};

static const u16 distance_base[30] = {
    1, 2, 3, 4, 5, 7, 9, 13,
    17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073,
    4097, 6145, 8193, 12289, 16385, 24577
};

static const u8 distance_extra[30] = {
    0, 0, 0, 0, 1, 1, 2, 2,
    3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10,
    11, 11, 12, 12, 13, 13
};

static const u8 code_order[19] = {
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5,
    11, 4, 12, 3, 13, 2, 14, 1, 15
};

static u16 get_bits(u8 need)
{
    u16 value = 0;
    u16 mask = 1;
    u8 byte;

    while (need--) {
        if (bit_count == 0) {
            if (!zip_read_data_byte(&byte)) {
                return 0;
            }
            bit_buffer = byte;
            bit_count = 8;
        }
        if (bit_buffer & 1) {
            value |= mask;
        }
        bit_buffer >>= 1;
        bit_count--;
        mask <<= 1;
    }
    return value;
}

/* Возвращает <0 для переполненного дерева, 0 для полного, >0 для неполного. */
static s16 construct(u16 *count, u16 *symbol, const u8 *source, u16 number)
{
    u16 index;
    u16 len;
    u16 item;
    s32 left;

    for (len = 0; len <= MAX_BITS; len++) {
        count[len] = 0;
    }
    for (item = 0; item < number; item++) {
        count[source[item]]++;
    }
    if (count[0] == number) {
        return 0;
    }

    left = 1;
    for (len = 1; len <= MAX_BITS; len++) {
        left <<= 1;
        left -= count[len];
        if (left < 0) {
            return -1;
        }
    }

    offsets[1] = 0;
    for (len = 1; len < MAX_BITS; len++) {
        offsets[len + 1] = offsets[len] + count[len];
    }

    for (item = 0; item < number; item++) {
        len = source[item];
        if (len != 0) {
            index = offsets[len]++;
            symbol[index] = item;
        }
    }
    return (s16)left;
}

static s16 decode(const u16 *count, const u16 *symbol)
{
    u16 code = 0;
    u16 first = 0;
    u16 index = 0;
    u16 amount;
    u8 len;

    for (len = 1; len <= MAX_BITS; len++) {
        code |= get_bits(1);
        if (zip_error) {
            return -1;
        }
        amount = count[len];
        if (code >= first && code < first + amount) {
            return (s16)symbol[index + code - first];
        }
        index += amount;
        first = (first + amount) << 1;
        code <<= 1;
    }
    return -1;
}

static u8 copy_match(u16 distance, u16 length)
{
    u16 source;
    u8 value;

    if (zip_total_out < 0x10000UL && distance > (u16)zip_total_out) {
        return 0;
    }

    source = ((u16)zip_total_out - distance) & 0x7fff;
    while (length--) {
        if (source < 0x4000) {
            value = *((volatile u8 *)source);
        } else {
            value = *((volatile u8 *)(source + 0x8000));
        }
        if (!zip_emit_byte(value)) {
            return 0;
        }
        source = (source + 1) & 0x7fff;
    }
    return 1;
}

static u8 decode_codes(void)
{
    s16 decoded;
    u16 symbol;
    u16 length;
    u16 distance;

    for (;;) {
        decoded = decode(lit_count, lit_symbol);
        if (decoded < 0) {
            return 0;
        }
        symbol = (u16)decoded;
        if (symbol < 256) {
            if (!zip_emit_byte((u8)symbol)) {
                return 0;
            }
        } else if (symbol == 256) {
            return 1;
        } else {
            symbol -= 257;
            if (symbol >= 29) {
                return 0;
            }
            length = length_base[symbol] + get_bits(length_extra[symbol]);
            if (zip_error) {
                return 0;
            }

            decoded = decode(dist_count, dist_symbol);
            if (decoded < 0 || decoded >= 30) {
                return 0;
            }
            symbol = (u16)decoded;
            distance = distance_base[symbol] + get_bits(distance_extra[symbol]);
            if (zip_error || !copy_match(distance, length)) {
                return 0;
            }
        }
    }
}

static u8 stored_block(void)
{
    u16 length;
    u16 inverse;
    u8 lo;
    u8 hi;
    u8 value;

    bit_buffer = 0;
    bit_count = 0;
    if (!zip_read_data_byte(&lo) || !zip_read_data_byte(&hi)) {
        return 0;
    }
    length = lo | ((u16)hi << 8);
    if (!zip_read_data_byte(&lo) || !zip_read_data_byte(&hi)) {
        return 0;
    }
    inverse = lo | ((u16)hi << 8);
    if ((u16)~length != inverse) {
        return 0;
    }
    while (length--) {
        if (!zip_read_data_byte(&value) || !zip_emit_byte(value)) {
            return 0;
        }
    }
    return 1;
}

static u8 fixed_block(void)
{
    u16 symbol;

    for (symbol = 0; symbol < 144; symbol++) {
        lengths[symbol] = 8;
    }
    for (; symbol < 256; symbol++) {
        lengths[symbol] = 9;
    }
    for (; symbol < 280; symbol++) {
        lengths[symbol] = 7;
    }
    for (; symbol < FIXED_LIT_CODES; symbol++) {
        lengths[symbol] = 8;
    }
    if (construct(lit_count, lit_symbol, lengths, FIXED_LIT_CODES) < 0) {
        return 0;
    }

    for (symbol = 0; symbol < MAX_DIST_CODES; symbol++) {
        lengths[symbol] = 5;
    }
    if (construct(dist_count, dist_symbol, lengths, MAX_DIST_CODES) < 0) {
        return 0;
    }
    return decode_codes();
}

static u8 dynamic_block(void)
{
    u16 nlen;
    u16 ndist;
    u16 ncode;
    u16 index;
    u16 total;
    u16 repeat;
    u8 previous;
    s16 decoded;
    s16 result;

    nlen = get_bits(5) + 257;
    ndist = get_bits(5) + 1;
    ncode = get_bits(4) + 4;
    if (zip_error || nlen > MAX_LIT_CODES || ndist > MAX_DIST_CODES) {
        return 0;
    }

    for (index = 0; index < 19; index++) {
        lengths[index] = 0;
    }
    for (index = 0; index < ncode; index++) {
        lengths[code_order[index]] = (u8)get_bits(3);
    }
    if (zip_error || construct(lit_count, lit_symbol, lengths, 19) != 0) {
        return 0;
    }

    total = nlen + ndist;
    index = 0;
    previous = 0;
    while (index < total) {
        decoded = decode(lit_count, lit_symbol);
        if (decoded < 0) {
            return 0;
        }
        if (decoded < 16) {
            previous = (u8)decoded;
            lengths[index++] = previous;
        } else if (decoded == 16) {
            if (index == 0) {
                return 0;
            }
            repeat = get_bits(2) + 3;
            if (zip_error || index + repeat > total) {
                return 0;
            }
            while (repeat--) {
                lengths[index++] = previous;
            }
        } else if (decoded == 17) {
            previous = 0;
            repeat = get_bits(3) + 3;
            if (zip_error || index + repeat > total) {
                return 0;
            }
            while (repeat--) {
                lengths[index++] = 0;
            }
        } else if (decoded == 18) {
            previous = 0;
            repeat = get_bits(7) + 11;
            if (zip_error || index + repeat > total) {
                return 0;
            }
            while (repeat--) {
                lengths[index++] = 0;
            }
        } else {
            return 0;
        }
    }

    if (lengths[256] == 0) {
        return 0;
    }
    result = construct(lit_count, lit_symbol, lengths, nlen);
    if (result != 0 && (result < 0 || nlen != lit_count[0] + lit_count[1])) {
        return 0;
    }
    result = construct(dist_count, dist_symbol, lengths + nlen, ndist);
    if (result != 0 && (result < 0 || ndist != dist_count[0] + dist_count[1])) {
        return 0;
    }
    return decode_codes();
}

u8 inflate_raw(void)
{
    u8 last;
    u8 type;

    bit_buffer = 0;
    bit_count = 0;
    do {
        last = (u8)get_bits(1);
        type = (u8)get_bits(2);
        if (zip_error) {
            return 0;
        }
        if (type == 0) {
            if (!stored_block()) {
                return 0;
            }
        } else if (type == 1) {
            if (!fixed_block()) {
                return 0;
            }
        } else if (type == 2) {
            if (!dynamic_block()) {
                return 0;
            }
        } else {
            return 0;
        }
    } while (!last);

    /* Следующая структура ZIP начинается с границы следующего байта. */
    bit_buffer = 0;
    bit_count = 0;
    return 1;
}
