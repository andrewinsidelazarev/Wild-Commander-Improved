#include "wc_api.h"
#include "inflate.h"

#define INPUT_SIZE 512
#define OUTPUT_SIZE 512
#define PATH_SIZE 384
#define NAME_SIZE 256
#define UI_WIDTH 58
#define BAR_WIDTH 54
#define BAR_FILLED 0xdb
#define BAR_EMPTY 0xb1

#define FILEX_BLOCK_SIZE 32
#define FILEX_VERSION 1
#define FILEX_READ_AT 1
#define EOCD_SIZE 22
#define EOCD_SEARCH_SIZE 65557UL

#define SIG_LOCAL   0x04034b50UL
#define SIG_CENTRAL 0x02014b50UL
#define SIG_EOCD    0x06054b50UL
#define SIG_ZIP64   0x06064b50UL
#define SIG_DESC    0x08074b50UL

#define METHOD_STORED 0
#define METHOD_DEFLATE 8

enum {
    ERR_NONE = 0,
    ERR_IO,
    ERR_TRUNCATED,
    ERR_NOT_ZIP,
    ERR_ENCRYPTED,
    ERR_METHOD,
    ERR_ZIP64,
    ERR_NAME,
    ERR_PATH,
    ERR_STREAMED_STORED,
    ERR_DEFLATE,
    ERR_CRC,
    ERR_SIZE,
    ERR_DIRECTORY,
    ERR_CREATE,
    ERR_WRITE,
    ERR_RENAME,
    ERR_SELF,
    ERR_CANCELLED
};

enum {
    REPLACE_CANCEL = 0,
    REPLACE_YES,
    REPLACE_NO,
    REPLACE_ALL
};

u32 archive_size;
u16 archive_name_ptr;
u16 saved_panel_ix;
u8 unzip_window[18];

u32 zip_total_out;
u8 zip_error;

static u8 input_buffer[INPUT_SIZE];
static u8 output_buffer[OUTPUT_SIZE];
static u8 path_buffer[PATH_SIZE];
static u8 query_buffer[NAME_SIZE + 6];
static u8 target_name[NAME_SIZE];
static u8 archive_name[NAME_SIZE];
static u8 temp_name[13];
static u8 ui_line[UI_WIDTH];
static u8 filex_block[FILEX_BLOCK_SIZE];

static u16 input_index;
static u16 input_valid;
static u16 output_used;
static u32 archive_position;
static u32 data_limit_end;
static u32 data_start_position;
static u32 expected_size;
static u32 expected_crc;
static u32 running_crc;
static u32 progress_quotient;
static u8 progress_remainder;
static u8 progress_percent;
static u8 progress_drawn;
static u8 data_limit_active;
static u8 expected_size_known;
static u8 discard_output;
static u8 skip_display;
static u8 output_depth;
static u8 temp_active;
static u8 error_code;
static u8 changed_directory;
static u8 replace_all;
static u16 archive_entry_count;
static u16 archive_entry_index;
static u8 finish_after_skip;

/* Управляющие коды заголовка и палитра окна повторяют оформление ChkDsk. */
static const u8 window_title[] = {0x0e, 9, ' ', 'Z', 'I', 'P', ' ',
                                  'u', 'n', 'p', 'a', 'c', 'k', 'e', 'r',
                                  ' ', 0};
static const u8 prefix_unzip[] = "unziping: ";
static const u8 prefix_skip[] = "skipping: ";
static const u8 done_text[] = "done";
static const u8 press_key_text[] = "Press any key";
static const u8 replace_question[] = "Replace existing file?";
static const u8 replace_options[] = "[Y] Yes  [N] No  [A] All  [Esc] Cancel";

static const u32 crc_nibble[16] = {
    0x00000000UL, 0x1db71064UL, 0x3b6e20c8UL, 0x26d930acUL,
    0x76dc4190UL, 0x6b6b51f4UL, 0x4db26158UL, 0x5005713cUL,
    0xedb88320UL, 0xf00f9344UL, 0xd6d6a3e8UL, 0xcb61b38cUL,
    0x9b64c2b0UL, 0x86d3d2d4UL, 0xa00ae278UL, 0xbdbdf21cUL
};

static void set_error(u8 code)
{
    if (error_code == ERR_NONE) {
        error_code = code;
    }
    zip_error = 1;
}

static u16 string_length(const u8 *text)
{
    u16 length = 0;
    while (text[length]) {
        length++;
    }
    return length;
}

static void copy_string(u8 *destination, const u8 *source)
{
    while ((*destination++ = *source++) != 0) {
    }
}

static u8 upper_ascii(u8 value)
{
    if (value >= 'a' && value <= 'z') {
        value -= 'a' - 'A';
    }
    return value;
}

static u8 strings_equal_ci(const u8 *left, const u8 *right)
{
    while (*left && *right) {
        if (upper_ascii(*left++) != upper_ascii(*right++)) {
            return 0;
        }
    }
    return *left == *right;
}

static void initialise_window(void)
{
    u16 title = (u16)window_title;

    unzip_window[0] = 0x81;       /* тень и двойная рамка в стиле ChkDsk */
    unzip_window[1] = 0;
    unzip_window[2] = 0xff;
    unzip_window[3] = 0xff;
    unzip_window[4] = 64;
    unzip_window[5] = 9;
    unzip_window[6] = 0x1f;       /* синий фон, ярко-белый текст */
    unzip_window[7] = 0;
    /* PRWOW сам запишет сюда адрес сохранённого фона; FFFF запрещает сохранение. */
    unzip_window[8] = 0;
    unzip_window[9] = 0;
    unzip_window[10] = 0;
    unzip_window[11] = 0;
    unzip_window[12] = (u8)title;
    unzip_window[13] = (u8)(title >> 8);
    unzip_window[14] = 0;
    unzip_window[15] = 0;
    unzip_window[16] = 0;
    unzip_window[17] = 0;
}

static void restore_history_mapping(void)
{
    wc_map_page_c000(2);
}

static u32 progress_threshold(u8 percent)
{
    u16 remainder_product = (u16)progress_remainder * percent;
    u32 threshold = progress_quotient * percent;

    threshold += (remainder_product + 99) / 100;
    return threshold;
}

static void fill_spaces(void)
{
    u8 index;
    for (index = 0; index < UI_WIDTH; index++) {
        ui_line[index] = ' ';
    }
}

static void ui_draw_percent(void)
{
    u8 filled;
    u8 index;

    fill_spaces();
    ui_line[27] = '0' + progress_percent / 100;
    ui_line[28] = '0' + (progress_percent / 10) % 10;
    ui_line[29] = '0' + progress_percent % 10;
    ui_line[30] = '%';
    wc_print(ui_line, UI_WIDTH, 2, 3);

    filled = ((u16)progress_percent * BAR_WIDTH) / 100;
    /* Полоса занимает прежние 54 знакоместа, меняется только её оформление. */
    for (index = 0; index < BAR_WIDTH; index++) {
        ui_line[index + 2] = index < filled ? BAR_FILLED : BAR_EMPTY;
    }
    wc_print(ui_line, UI_WIDTH, 4, 3);
}

static void ui_draw_name(const u8 *path)
{
    u16 path_length = string_length(path);
    const u8 *prefix = skip_display ? prefix_skip : prefix_unzip;
    u8 index;
    u8 prefix_length = skip_display ? sizeof(prefix_skip) - 1 :
                                      sizeof(prefix_unzip) - 1;
    u8 available = UI_WIDTH - prefix_length;

    fill_spaces();
    for (index = 0; index < prefix_length; index++) {
        ui_line[index] = prefix[index];
    }

    if (path_length <= available) {
        for (index = 0; index < path_length; index++) {
            ui_line[prefix_length + index] = path[index];
        }
    } else {
        ui_line[prefix_length] = '.';
        ui_line[prefix_length + 1] = '.';
        ui_line[prefix_length + 2] = '.';
        path += path_length - (available - 3);
        for (index = 3; index < available; index++) {
            ui_line[prefix_length + index] = *path++;
        }
    }
    wc_print(ui_line, UI_WIDTH, 6, 3);
}

static void ui_draw_centered(const u8 *text, u8 y)
{
    u16 length = string_length(text);
    u8 index;
    u8 start;

    fill_spaces();
    if (length > UI_WIDTH) {
        length = UI_WIDTH;
    }
    start = (UI_WIDTH - (u8)length) / 2;
    for (index = 0; index < length; index++) {
        ui_line[start + index] = text[index];
    }
    wc_print(ui_line, UI_WIDTH, y, 3);
}

static void ui_draw_prompt_path(const u8 *path)
{
    u16 length = string_length(path);
    u8 index;

    fill_spaces();
    if (length <= UI_WIDTH) {
        for (index = 0; index < length; index++) {
            ui_line[index] = path[index];
        }
    } else {
        ui_line[0] = '.';
        ui_line[1] = '.';
        ui_line[2] = '.';
        path += length - (UI_WIDTH - 3);
        for (index = 3; index < UI_WIDTH; index++) {
            ui_line[index] = *path++;
        }
    }
    wc_print(ui_line, UI_WIDTH, 4, 3);
}

static u8 ui_confirm_replace(void)
{
    u8 key;
    u8 choice;

    ui_draw_centered(replace_question, 2);
    ui_draw_prompt_path(path_buffer);
    ui_draw_centered(replace_options, 6);
    restore_history_mapping();

    /* Не принимаем Enter, которым пользователь запустил ZIP, за ответ Yes. */
    wc_wait_key_release();
    for (;;) {
        wc_wait_frame();
        if (wc_escape()) {
            choice = REPLACE_CANCEL;
            break;
        }
        if (wc_enter()) {
            choice = REPLACE_YES;
            break;
        }
        key = upper_ascii(wc_scan_key());
        if (key == 'Y') {
            choice = REPLACE_YES;
            break;
        }
        if (key == 'N') {
            choice = REPLACE_NO;
            break;
        }
        if (key == 'A') {
            choice = REPLACE_ALL;
            break;
        }
        if (key == 27) {
            choice = REPLACE_CANCEL;
            break;
        }
    }
    wc_wait_key_release();

    /* После ответа возвращаем обычные строки прогресса. */
    ui_draw_percent();
    ui_draw_name(path_buffer);
    restore_history_mapping();
    return choice;
}

static u8 ui_update(const u8 *path, u8 force)
{
    u8 old = progress_percent;

    while (progress_percent < 99 &&
           archive_position >= progress_threshold(progress_percent + 1)) {
        progress_percent++;
    }
    if (force || old != progress_percent || progress_drawn != progress_percent) {
        ui_draw_percent();
        ui_draw_name(path);
        progress_drawn = progress_percent;
        restore_history_mapping();
    }
    if (wc_escape()) {
        set_error(ERR_CANCELLED);
        return 0;
    }
    return 1;
}

static void ui_finish(void)
{
    u8 frames = 25;
    progress_percent = 100;
    ui_draw_percent();
    ui_draw_name(done_text);
    while (frames--) {
        wc_wait_frame();
    }
}

static void ui_error(void)
{
    const u8 *text;

    if (error_code == ERR_CANCELLED) {
        return;
    }
    /* Массив указателей здесь не используется из-за ошибки SDCC 4.3 при
       инициализации таблицы строковых констант в единой странице памяти. */
    switch (error_code) {
    case ERR_IO: text = (const u8 *)"device read error"; break;
    case ERR_TRUNCATED: text = (const u8 *)"truncated ZIP archive"; break;
    case ERR_NOT_ZIP: text = (const u8 *)"invalid ZIP structure"; break;
    case ERR_ENCRYPTED: text = (const u8 *)"encrypted ZIP is unsupported"; break;
    case ERR_METHOD: text = (const u8 *)"unsupported compression method"; break;
    case ERR_ZIP64: text = (const u8 *)"ZIP64 is unsupported"; break;
    case ERR_NAME: text = (const u8 *)"invalid or too long name"; break;
    case ERR_PATH: text = (const u8 *)"unsafe archive path"; break;
    case ERR_STREAMED_STORED:
        text = (const u8 *)"streamed Stored entry unsupported";
        break;
    case ERR_DEFLATE: text = (const u8 *)"invalid Deflate stream"; break;
    case ERR_CRC: text = (const u8 *)"CRC32 mismatch"; break;
    case ERR_SIZE: text = (const u8 *)"entry size mismatch"; break;
    case ERR_DIRECTORY: text = (const u8 *)"cannot create directory"; break;
    case ERR_CREATE: text = (const u8 *)"cannot create output file"; break;
    case ERR_WRITE: text = (const u8 *)"cannot write output file"; break;
    case ERR_RENAME: text = (const u8 *)"cannot publish output file"; break;
    case ERR_SELF: text = (const u8 *)"archive cannot overwrite itself"; break;
    default: text = (const u8 *)"unknown error"; break;
    }
    fill_spaces();
    ui_line[0] = 'E';
    ui_line[1] = 'R';
    ui_line[2] = 'R';
    ui_line[3] = 'O';
    ui_line[4] = 'R';
    ui_line[5] = ':';
    ui_line[6] = ' ';
    {
        u8 index = 7;
        while (*text && index < UI_WIDTH) {
            ui_line[index++] = *text++;
        }
    }
    wc_print(ui_line, UI_WIDTH, 4, 3);
    fill_spaces();
    {
        u8 index;
        u8 start = (UI_WIDTH - (sizeof(press_key_text) - 1)) / 2;
        for (index = 0; index < sizeof(press_key_text) - 1; index++) {
            ui_line[start + index] = press_key_text[index];
        }
    }
    wc_print(ui_line, UI_WIDTH, 6, 3);
    restore_history_mapping();
    /* Клавишу Enter, которой запустили архив, нельзя принимать за закрытие
       сообщения об ошибке: сначала дожидаемся её физического отпускания. */
    wc_wait_key_release();
    while (!wc_any_key()) {
        wc_wait_frame();
    }
}

static u8 refill_input(void)
{
    u32 remaining;

    if (archive_position >= archive_size) {
        set_error(ERR_TRUNCATED);
        return 0;
    }
    wc_select_stream(0);
    if (wc_load_sector(input_buffer)) {
        set_error(ERR_IO);
        return 0;
    }
    remaining = archive_size - archive_position;
    input_valid = remaining < INPUT_SIZE ? (u16)remaining : INPUT_SIZE;
    input_index = 0;
    return 1;
}

static u8 read_archive_byte(u8 *value)
{
    if (input_index >= input_valid && !refill_input()) {
        return 0;
    }
    *value = input_buffer[input_index++];
    archive_position++;
    return 1;
}

u8 zip_read_data_byte(u8 *value)
{
    if (data_limit_active && archive_position >= data_limit_end) {
        set_error(ERR_DEFLATE);
        return 0;
    }
    return read_archive_byte(value);
}

static u8 read_u16(u16 *value)
{
    u8 lo;
    u8 hi;
    if (!read_archive_byte(&lo) || !read_archive_byte(&hi)) {
        return 0;
    }
    *value = lo | ((u16)hi << 8);
    return 1;
}

static u8 read_u32(u32 *value)
{
    u16 lo;
    u16 hi;
    if (!read_u16(&lo) || !read_u16(&hi)) {
        return 0;
    }
    *value = lo | ((u32)hi << 16);
    return 1;
}

static u8 skip_bytes(u16 count)
{
    u8 value;
    while (count--) {
        if (!read_archive_byte(&value)) {
            return 0;
        }
    }
    return 1;
}

static u8 sanitise_character(u8 value)
{
    if (value < 32 || value == '"' || value == '*' || value == ':' ||
        value == '<' || value == '>' || value == '?' || value == '|') {
        return '_';
    }
    return value;
}

static u8 convert_utf8_pair(u8 first, u8 second, u8 *converted)
{
    if (first == 0xd0) {
        if (second == 0x81) {
            *converted = 0xf0;           /* заглавная Ё */
            return 1;
        }
        if (second >= 0x90 && second <= 0x9f) {
            *converted = 0x80 + second - 0x90;
            return 1;
        }
        if (second >= 0xa0 && second <= 0xaf) {
            *converted = 0x90 + second - 0xa0;
            return 1;
        }
        if (second >= 0xb0 && second <= 0xbf) {
            *converted = 0xa0 + second - 0xb0;
            return 1;
        }
    } else if (first == 0xd1) {
        if (second == 0x91) {
            *converted = 0xf1;           /* строчная ё */
            return 1;
        }
        if (second >= 0x80 && second <= 0x8f) {
            *converted = 0xe0 + second - 0x80;
            return 1;
        }
    }
    *converted = '_';
    return 1;
}

static u8 canonicalise_path(u16 length, u8 *is_directory)
{
    u16 read = 0;
    u16 write = 0;

    while (read < length) {
        u16 start = read;
        u16 component_length;

        while (read < length && path_buffer[read] != '/') {
            read++;
        }
        component_length = read - start;
        while (component_length &&
               (path_buffer[start + component_length - 1] == ' ' ||
                path_buffer[start + component_length - 1] == '.')) {
            component_length--;
        }
        if (component_length == 0 || component_length > 255) {
            set_error(ERR_PATH);
            return 0;
        }
        if ((component_length == 1 && path_buffer[start] == '.') ||
            (component_length == 2 && path_buffer[start] == '.' &&
             path_buffer[start + 1] == '.')) {
            set_error(ERR_PATH);
            return 0;
        }
        while (component_length--) {
            path_buffer[write++] = path_buffer[start++];
        }
        if (read < length) {
            path_buffer[write++] = '/';
            read++;
        }
    }
    if (write && path_buffer[write - 1] == '/') {
        write--;
        *is_directory = 1;
    }
    if (write == 0) {
        set_error(ERR_PATH);
        return 0;
    }
    path_buffer[write] = 0;
    return 1;
}

static u8 read_entry_name(u16 raw_length, u8 utf8, u8 *is_directory)
{
    u16 remaining = raw_length;
    u16 output = 0;
    u8 value;
    u8 next;
    u8 need;

    *is_directory = 0;
    if (raw_length == 0) {
        set_error(ERR_NAME);
        return 0;
    }

    while (remaining) {
        if (!read_archive_byte(&value)) {
            return 0;
        }
        remaining--;

        if (utf8 && value >= 0x80) {
            if (value == 0xd0 || value == 0xd1) {
                if (!remaining || !read_archive_byte(&next)) {
                    set_error(ERR_NAME);
                    return 0;
                }
                remaining--;
                if ((next & 0xc0) != 0x80) {
                    set_error(ERR_NAME);
                    return 0;
                }
                convert_utf8_pair(value, next, &value);
            } else {
                if ((value & 0xf0) == 0xe0) {
                    need = 2;
                } else if ((value & 0xf8) == 0xf0) {
                    need = 3;
                } else {
                    set_error(ERR_NAME);
                    return 0;
                }
                if (remaining < need) {
                    set_error(ERR_NAME);
                    return 0;
                }
                while (need--) {
                    if (!read_archive_byte(&next) || (next & 0xc0) != 0x80) {
                        set_error(ERR_NAME);
                        return 0;
                    }
                    remaining--;
                }
                value = '_';
            }
        }

        if (value == 0) {
            set_error(ERR_NAME);
            return 0;
        }
        if (value == '/' || value == '\\') {
            if (output == 0) {
                set_error(ERR_PATH);
                return 0;
            }
            if (path_buffer[output - 1] != '/') {
                if (output >= PATH_SIZE - 1) {
                    set_error(ERR_NAME);
                    return 0;
                }
                path_buffer[output++] = '/';
            }
            if (remaining == 0) {
                *is_directory = 1;
            }
        } else {
            if (output >= PATH_SIZE - 1) {
                set_error(ERR_NAME);
                return 0;
            }
            path_buffer[output++] = sanitise_character(value);
        }
    }
    return canonicalise_path(output, is_directory);
}

static u8 read_extra(u16 extra_length)
{
    u16 tag;
    u16 size;

    while (extra_length) {
        if (extra_length < 4 || !read_u16(&tag) || !read_u16(&size)) {
            set_error(ERR_TRUNCATED);
            return 0;
        }
        extra_length -= 4;
        if (size > extra_length) {
            set_error(ERR_TRUNCATED);
            return 0;
        }
        if (tag == 0x0001) {
            set_error(ERR_ZIP64);
            return 0;
        }
        if (!skip_bytes(size)) {
            return 0;
        }
        extra_length -= size;
    }
    return 1;
}

static u8 *make_query(u8 type, const u8 *name)
{
    u8 *write = query_buffer;
    *write++ = type;
    while ((*write++ = *name++) != 0) {
    }
    return query_buffer;
}

static u16 buffer_u16(const u8 *buffer)
{
    return (u16)buffer[0] | ((u16)buffer[1] << 8);
}

static void block_u16(u8 offset, u16 value)
{
    filex_block[offset] = (u8)value;
    filex_block[offset + 1] = (u8)(value >> 8);
}

static void block_u32(u8 offset, u32 value)
{
    filex_block[offset] = (u8)value;
    filex_block[offset + 1] = (u8)(value >> 8);
    filex_block[offset + 2] = (u8)(value >> 16);
    filex_block[offset + 3] = (u8)(value >> 24);
}

static u8 filex_read_at(u32 offset, u8 *buffer, u16 length)
{
    block_u32(4, offset);
    block_u16(8, (u16)buffer);
    block_u16(10, length);
    if (wc_filex(filex_block) != 0) {
        return 0;
    }
    return buffer_u16(filex_block + 24) == length &&
           buffer_u16(filex_block + 26) == 0;
}

static u8 valid_eocd(u32 offset)
{
    u16 entries;
    u16 comment_length;

    if (!filex_read_at(offset, output_buffer, EOCD_SIZE)) {
        return 0;
    }
    if (output_buffer[0] != 'P' || output_buffer[1] != 'K' ||
        output_buffer[2] != 5 || output_buffer[3] != 6 ||
        buffer_u16(output_buffer + 4) != 0 ||
        buffer_u16(output_buffer + 6) != 0) {
        return 0;
    }
    entries = buffer_u16(output_buffer + 10);
    if (entries == 0 || entries == 0xffff ||
        entries != buffer_u16(output_buffer + 8)) {
        return 0;
    }
    comment_length = buffer_u16(output_buffer + 20);
    if (offset + EOCD_SIZE + comment_length != archive_size) {
        return 0;
    }
    archive_entry_count = entries;
    return 1;
}

static void detect_entry_count(void)
{
    u32 minimum;
    u32 end;
    u32 start;
    u32 candidate;
    u16 length;
    u16 index;
    u8 clear;

    archive_entry_count = 0;
    if (archive_size < EOCD_SIZE) {
        return;
    }
    for (clear = 0; clear < FILEX_BLOCK_SIZE; clear++) {
        filex_block[clear] = 0;
    }
    filex_block[0] = FILEX_BLOCK_SIZE;
    filex_block[1] = FILEX_VERSION;
    filex_block[2] = FILEX_READ_AT;

    minimum = archive_size > EOCD_SEARCH_SIZE
              ? archive_size - EOCD_SEARCH_SIZE : 0;
    end = archive_size;
    for (;;) {
        start = end - minimum > INPUT_SIZE ? end - INPUT_SIZE : minimum;
        length = (u16)(end - start);
        if (!filex_read_at(start, input_buffer, length)) {
            return;
        }
        index = length - 4;
        for (;;) {
            if (input_buffer[index] == 'P' && input_buffer[index + 1] == 'K' &&
                input_buffer[index + 2] == 5 && input_buffer[index + 3] == 6) {
                candidate = start + index;
                if (valid_eocd(candidate)) {
                    return;
                }
            }
            if (index == 0) {
                break;
            }
            index--;
        }
        if (start == minimum) {
            return;
        }
        end = start + 3;
    }
}

static u8 prepare_streams(void)
{
    wc_clone_streams();
    wc_select_stream(0);
    make_query(0x00, archive_name);
    if (!wc_fentry(query_buffer)) {
        set_error(ERR_IO);
        return 0;
    }
    /* FILEX читает EOCD позиционно, не меняя будущий последовательный поток.
       Если провайдера нет или EOCD нестандартный, остаётся безопасный LOAD512. */
    detect_entry_count();
    wc_gfile();
    wc_select_stream(1);
    return 1;
}

static u8 return_to_base(void)
{
    wc_select_stream(1);
    while (output_depth) {
        make_query(0x10, (const u8 *)"..");
        if (!wc_fentry(query_buffer)) {
            set_error(ERR_DIRECTORY);
            return 0;
        }
        wc_gdir();
        output_depth--;
    }
    return 1;
}

static u8 enter_directory(const u8 *name)
{
    make_query(0x10, name);
    if (!wc_fentry(query_buffer)) {
        if (!wc_mkdir(query_buffer + 1)) {
            set_error(ERR_DIRECTORY);
            return 0;
        }
        changed_directory = 1;
        make_query(0x10, name);
        if (!wc_fentry(query_buffer)) {
            set_error(ERR_DIRECTORY);
            return 0;
        }
    }
    if (output_depth == 63) {
        set_error(ERR_PATH);
        return 0;
    }
    wc_gdir();
    output_depth++;
    return 1;
}

static u8 navigate_entry(u8 is_directory)
{
    u16 position = 0;
    u16 start;
    u16 length;
    u16 index;
    u8 last;

    if (!return_to_base()) {
        return 0;
    }

    while (path_buffer[position]) {
        start = position;
        while (path_buffer[position] && path_buffer[position] != '/') {
            position++;
        }
        length = position - start;
        last = path_buffer[position] == 0;
        if (length >= NAME_SIZE) {
            set_error(ERR_NAME);
            return 0;
        }
        for (index = 0; index < length; index++) {
            target_name[index] = path_buffer[start + index];
        }
        target_name[length] = 0;

        if (!last || is_directory) {
            if (!enter_directory(target_name)) {
                return 0;
            }
        }
        if (!last) {
            position++;
        }
    }
    return 1;
}

static u8 choose_file_action(u8 *skip_entry)
{
    u8 choice;

    *skip_entry = 0;
    make_query(0x10, target_name);
    if (wc_fentry(query_buffer)) {
        set_error(ERR_RENAME);
        return 0;
    }

    make_query(0x00, target_name);
    if (!wc_fentry(query_buffer)) {
        return 1;
    }

    if (!replace_all) {
        /* Решение принимается до создания временного файла и записи данных. */
        choice = ui_confirm_replace();
        if (choice == REPLACE_CANCEL) {
            set_error(ERR_CANCELLED);
            return 0;
        }
        if (choice == REPLACE_NO) {
            *skip_entry = 1;
            return 1;
        }
        if (choice == REPLACE_ALL) {
            replace_all = 1;
        }
    }

    if (output_depth == 0 && strings_equal_ci(target_name, archive_name)) {
        set_error(ERR_SELF);
        return 0;
    }
    return 1;
}

static void make_temp_candidate(u8 number)
{
    temp_name[0] = 'W';
    temp_name[1] = 'C';
    temp_name[2] = 'U';
    temp_name[3] = 'Z';
    temp_name[4] = '0';
    temp_name[5] = '0' + number / 10;
    temp_name[6] = '0' + number % 10;
    temp_name[7] = '0';
    temp_name[8] = '.';
    temp_name[9] = '$';
    temp_name[10] = '$';
    temp_name[11] = '$';
    temp_name[12] = 0;
}

static u8 begin_temp_file(void)
{
    u8 candidate;
    u8 *create;

    for (candidate = 0; candidate < 100; candidate++) {
        make_temp_candidate(candidate);
        make_query(0x00, temp_name);
        if (wc_fentry(query_buffer)) {
            continue;
        }
        make_query(0x10, temp_name);
        if (wc_fentry(query_buffer)) {
            continue;
        }

        create = query_buffer;
        create[0] = 0;
        create[1] = 0;
        create[2] = 0;
        create[3] = 0;
        create[4] = 0;
        copy_string(create + 5, temp_name);
        if (wc_mkfile(create)) {
            temp_active = 1;
            changed_directory = 1;
            return 1;
        }
    }
    set_error(ERR_CREATE);
    return 0;
}

static u8 flush_output(void)
{
    if (output_used == 0) {
        return 1;
    }
    wc_select_stream(1);
    make_query(0x00, temp_name);
    if (!wc_fentry(query_buffer) || !wc_append(output_buffer, output_used)) {
        set_error(ERR_WRITE);
        return 0;
    }
    output_used = 0;
    return ui_update(path_buffer, 0);
}

u8 zip_emit_byte(u8 value)
{
    u16 history_position;
    u32 crc;

    if (expected_size_known && zip_total_out >= expected_size) {
        set_error(ERR_SIZE);
        return 0;
    }

    history_position = (u16)zip_total_out & 0x7fff;
    if (history_position < 0x4000) {
        *((volatile u8 *)history_position) = value;
    } else {
        *((volatile u8 *)(history_position + 0x8000)) = value;
    }

    crc = running_crc ^ value;
    crc = (crc >> 4) ^ crc_nibble[crc & 15];
    crc = (crc >> 4) ^ crc_nibble[crc & 15];
    running_crc = crc;
    zip_total_out++;

    if (discard_output) {
        /* При ответе No распаковываем неизвестный Deflate-поток только в
           кольцевую память: на устройство не создаётся и не пишется файл. */
        output_used++;
        if (output_used == OUTPUT_SIZE) {
            output_used = 0;
            /* Индикатор не изображает распаковку пропущенного файла, но Esc
               по-прежнему проверяется во время длинного Deflate-потока. */
            if (wc_escape()) {
                set_error(ERR_CANCELLED);
                return 0;
            }
        }
        return 1;
    }

    output_buffer[output_used++] = value;
    if (output_used == OUTPUT_SIZE && !flush_output()) {
        return 0;
    }
    return 1;
}

static void reset_output(u32 size, u8 size_known)
{
    zip_total_out = 0;
    output_used = 0;
    running_crc = 0xffffffffUL;
    expected_size = size;
    expected_size_known = size_known;
    zip_error = 0;
}

static u8 skip_data_bytes(u32 count)
{
    u16 available;
    u16 consume;

    skip_display = 1;
    if (!ui_update(path_buffer, 1)) {
        skip_display = 0;
        return 0;
    }

    /* LOADNONE нельзя смешивать с буферизованным ZIP-потоком: на реальном
       устройстве это рассинхронизировало позицию. Пропускаем целые буферы
       обычным проверенным LOAD512, но без побайтного цикла и без прогресса. */
    while (count) {
        available = input_valid - input_index;
        if (!available) {
            if (!refill_input()) {
                skip_display = 0;
                return 0;
            }
            available = input_valid;
            if (wc_escape()) {
                skip_display = 0;
                set_error(ERR_CANCELLED);
                return 0;
            }
        }
        consume = count < (u32)available ? (u16)count : available;
        input_index += consume;
        archive_position += consume;
        count -= consume;
    }
    skip_display = 0;
    return 1;
}

static u8 copy_stored(u32 compressed_size)
{
    u8 value;
    while (compressed_size--) {
        if (!zip_read_data_byte(&value) || !zip_emit_byte(value)) {
            return 0;
        }
    }
    return 1;
}

static u8 read_descriptor(u32 *crc, u32 *compressed, u32 *uncompressed)
{
    u32 first;
    if (!read_u32(&first)) {
        return 0;
    }
    if (first == SIG_DESC) {
        if (!read_u32(crc)) {
            return 0;
        }
    } else {
        *crc = first;
    }
    return read_u32(compressed) && read_u32(uncompressed);
}

static u8 finish_skipped_known(u8 has_descriptor, u32 header_crc,
                               u32 compressed_size, u32 uncompressed_size)
{
    u32 descriptor_crc;
    u32 descriptor_compressed;
    u32 descriptor_uncompressed;

    if (!has_descriptor) {
        return 1;
    }
    data_limit_active = 0;
    if (!read_descriptor(&descriptor_crc, &descriptor_compressed,
                         &descriptor_uncompressed)) {
        return 0;
    }
    if (descriptor_compressed != compressed_size ||
        (uncompressed_size != 0 && descriptor_uncompressed != uncompressed_size)) {
        set_error(ERR_SIZE);
        return 0;
    }
    if (header_crc != 0 && descriptor_crc != header_crc) {
        set_error(ERR_CRC);
        return 0;
    }
    return 1;
}

static u8 validate_entry(u8 has_descriptor, u32 header_compressed,
                         u32 actual_compressed, u32 header_uncompressed,
                         u32 header_crc)
{
    u32 actual_crc = ~running_crc;
    u32 descriptor_crc;
    u32 descriptor_compressed;
    u32 descriptor_uncompressed;

    if (has_descriptor) {
        data_limit_active = 0;
        if (!read_descriptor(&descriptor_crc, &descriptor_compressed,
                             &descriptor_uncompressed)) {
            return 0;
        }
        if (descriptor_compressed != actual_compressed ||
            descriptor_uncompressed != zip_total_out) {
            set_error(ERR_SIZE);
            return 0;
        }
        if (descriptor_crc != actual_crc) {
            set_error(ERR_CRC);
            return 0;
        }
    } else {
        if (header_compressed != actual_compressed ||
            header_uncompressed != zip_total_out) {
            set_error(ERR_SIZE);
            return 0;
        }
        if (header_crc != actual_crc) {
            set_error(ERR_CRC);
            return 0;
        }
    }
    return 1;
}

static u8 commit_temp_file(void)
{
    make_query(0x10, target_name);
    if (wc_fentry(query_buffer)) {
        set_error(ERR_RENAME);
        return 0;
    }

    make_query(0x00, target_name);
    if (wc_fentry(query_buffer)) {
        make_query(0x00, target_name);
        if (!wc_fentry(query_buffer) || !wc_delete(query_buffer)) {
            set_error(ERR_RENAME);
            return 0;
        }
    }

    make_query(0x00, temp_name);
    if (!wc_rename(query_buffer, target_name)) {
        set_error(ERR_RENAME);
        return 0;
    }
    temp_active = 0;
    return 1;
}

static void cleanup_temp(void)
{
    u8 saved_error;
    if (!temp_active) {
        return;
    }
    saved_error = error_code;
    wc_select_stream(1);
    make_query(0x00, temp_name);
    if (wc_fentry(query_buffer)) {
        wc_delete(query_buffer);
    }
    temp_active = 0;
    error_code = saved_error;
    zip_error = saved_error != ERR_NONE;
}

static u8 process_entry(u16 flags, u16 method, u32 header_crc,
                        u32 compressed_size, u32 uncompressed_size,
                        u8 is_directory)
{
    u8 has_descriptor = (flags & 0x0008) != 0;
    u8 compressed_known = !has_descriptor || compressed_size != 0;
    u8 skip_entry = 0;
    u32 actual_compressed;

    if (!ui_update(path_buffer, 1) || !navigate_entry(is_directory)) {
        return 0;
    }
    if (is_directory) {
        if (uncompressed_size != 0 || compressed_size != 0) {
            set_error(ERR_DIRECTORY);
            return 0;
        }
    } else {
        if (!choose_file_action(&skip_entry)) {
            return 0;
        }
        if (skip_entry && archive_entry_count != 0 &&
            archive_entry_index == archive_entry_count) {
            /* Последний отклонённый файл читать не нужно: после него остаётся
               только центральный каталог, а файловая система не изменяется. */
            finish_after_skip = 1;
            return 1;
        }
        if (!skip_entry && !begin_temp_file()) {
            return 0;
        }
    }

    data_start_position = archive_position;
    data_limit_active = compressed_known;
    if (compressed_known) {
        data_limit_end = archive_position + compressed_size;
        if (data_limit_end < archive_position || data_limit_end > archive_size) {
            set_error(ERR_TRUNCATED);
            return 0;
        }
    }

    if (skip_entry && compressed_known) {
        /* Размер известен из локального заголовка: No пропускает сжатые
           байты напрямую, не распаковывая их и не записывая устройство. */
        if (!skip_data_bytes(compressed_size)) {
            return 0;
        }
        actual_compressed = archive_position - data_start_position;
        data_limit_active = 0;
        if (actual_compressed != compressed_size) {
            set_error(ERR_SIZE);
            return 0;
        }
        return finish_skipped_known(has_descriptor, header_crc,
                                    compressed_size, uncompressed_size);
    }

    reset_output(uncompressed_size, !has_descriptor);
    discard_output = skip_entry;
    skip_display = skip_entry;
    if (skip_entry && !ui_update(path_buffer, 1)) {
        discard_output = 0;
        skip_display = 0;
        return 0;
    }
    if (is_directory) {
        /* Корректная запись каталога не содержит данных файла. */
    } else if (method == METHOD_STORED) {
        if (has_descriptor && !compressed_known) {
            discard_output = 0;
            skip_display = 0;
            set_error(ERR_STREAMED_STORED);
            return 0;
        }
        if (!copy_stored(compressed_size)) {
            discard_output = 0;
            skip_display = 0;
            return 0;
        }
    } else if (method == METHOD_DEFLATE) {
        if (!inflate_raw()) {
            discard_output = 0;
            skip_display = 0;
            if (error_code == ERR_NONE) {
                set_error(ERR_DEFLATE);
            }
            return 0;
        }
    } else {
        discard_output = 0;
        skip_display = 0;
        set_error(ERR_METHOD);
        return 0;
    }

    actual_compressed = archive_position - data_start_position;
    data_limit_active = 0;
    discard_output = 0;
    skip_display = 0;
    if (compressed_known && actual_compressed != compressed_size) {
        set_error(ERR_SIZE);
        return 0;
    }
    if (skip_entry) {
        output_used = 0;
    } else if (!is_directory && !flush_output()) {
        return 0;
    }
    if (!validate_entry(has_descriptor, compressed_size, actual_compressed,
                        uncompressed_size, header_crc)) {
        return 0;
    }
    if (!is_directory && !skip_entry && !commit_temp_file()) {
        return 0;
    }
    return 1;
}

static u8 extract_archive(void)
{
    u32 signature;
    u32 header_crc;
    u32 compressed_size;
    u32 uncompressed_size;
    u16 version;
    u16 flags;
    u16 method;
    u16 ignored;
    u16 name_length;
    u16 extra_length;
    u8 is_directory;

    for (;;) {
        if (!read_u32(&signature)) {
            return 0;
        }
        if (signature == SIG_CENTRAL || signature == SIG_EOCD) {
            return 1;
        }
        if (signature == SIG_ZIP64) {
            set_error(ERR_ZIP64);
            return 0;
        }
        if (signature != SIG_LOCAL) {
            set_error(ERR_NOT_ZIP);
            return 0;
        }
        archive_entry_index++;

        if (!read_u16(&version) || !read_u16(&flags) || !read_u16(&method) ||
            !read_u16(&ignored) || !read_u16(&ignored) || !read_u32(&header_crc) ||
            !read_u32(&compressed_size) || !read_u32(&uncompressed_size) ||
            !read_u16(&name_length) || !read_u16(&extra_length)) {
            return 0;
        }
        if ((flags & 0x0041) != 0) {
            set_error(ERR_ENCRYPTED);
            return 0;
        }
        if (method != METHOD_STORED && method != METHOD_DEFLATE) {
            set_error(ERR_METHOD);
            return 0;
        }
        if (compressed_size == 0xffffffffUL || uncompressed_size == 0xffffffffUL) {
            set_error(ERR_ZIP64);
            return 0;
        }
        if (!read_entry_name(name_length, (flags & 0x0800) != 0,
                             &is_directory) || !read_extra(extra_length)) {
            return 0;
        }
        if (!process_entry(flags, method, header_crc, compressed_size,
                           uncompressed_size, is_directory)) {
            return 0;
        }
        if (finish_after_skip) {
            return 1;
        }
    }
}

static void copy_archive_name(void)
{
    const u8 *source = (const u8 *)archive_name_ptr;
    u16 index = 0;

    while (index < NAME_SIZE - 1 && source[index]) {
        archive_name[index] = source[index];
        index++;
    }
    archive_name[index] = 0;
}

static void reset_state(void)
{
    input_index = INPUT_SIZE;
    input_valid = 0;
    output_used = 0;
    archive_position = 0;
    data_limit_active = 0;
    expected_size_known = 0;
    discard_output = 0;
    skip_display = 0;
    output_depth = 0;
    temp_active = 0;
    error_code = ERR_NONE;
    zip_error = 0;
    changed_directory = 0;
    replace_all = 0;
    archive_entry_count = 0;
    archive_entry_index = 0;
    finish_after_skip = 0;
    progress_percent = 0;
    progress_drawn = 0xff;
    progress_quotient = archive_size / 100;
    progress_remainder = (u8)(archive_size % 100);
}

u8 plugin_main(void)
{
    u8 success;

    copy_archive_name();
    reset_state();
    initialise_window();

    wc_gedpl();
    wc_show_window();
    ui_draw_percent();
    ui_draw_name(archive_name);

    success = prepare_streams();
    if (success) {
        wc_map_page_0000(1);      /* младшие 16 КиБ истории Deflate */
        wc_map_page_c000(2);      /* старшие 16 КиБ истории Deflate */
        success = extract_archive();
    }
    cleanup_temp();
    if (!return_to_base()) {
        success = 0;
    }

    if (success && changed_directory) {
        ui_finish();
    } else if (!success) {
        ui_error();
    }
    wc_close_window();
    wc_gedpl();
    /* Код 3 штатно просит WCVW перечитать активную панель уже после того,
       как NYAU восстановит страницы и стек вызывающего Commander. */
    return changed_directory ? 3 : 0;
}
