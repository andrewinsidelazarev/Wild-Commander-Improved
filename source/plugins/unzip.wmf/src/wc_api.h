#ifndef WC_API_H
#define WC_API_H

typedef unsigned char u8;
typedef signed char s8;
typedef unsigned int u16;
typedef signed int s16;
typedef unsigned long u32;
typedef signed long s32;

extern u32 archive_size;
extern u16 archive_name_ptr;
extern u16 saved_panel_ix;
extern u8 unzip_window[];

void wc_gedpl(void) __naked;
void wc_clone_streams(void) __naked;
void wc_select_stream(u8 stream) __naked;
u8 wc_load_sector(u8 *buffer) __naked;
u8 wc_fentry(const u8 *query) __naked;
void wc_gfile(void) __naked;
void wc_gdir(void) __naked;
u8 wc_mkfile(const u8 *create_block) __naked;
u8 wc_mkdir(const u8 *name) __naked;
u8 wc_delete(const u8 *query) __naked;
u8 wc_rename(const u8 *old_query, const u8 *new_name) __naked;
u8 wc_append(const u8 *data, u16 length) __naked;
u8 wc_filex(u8 *block) __naked;
void wc_map_page_0000(u8 page) __naked;
void wc_map_page_c000(u8 page) __naked;
void wc_show_window(void) __naked;
void wc_close_window(void) __naked;
void wc_print(const u8 *text, u16 length, u8 y, u8 x) __naked;
u8 wc_enter(void) __naked;
u8 wc_escape(void) __naked;
u8 wc_scan_key(void) __naked;
u8 wc_any_key(void) __naked;
void wc_wait_key_release(void) __naked;
void wc_wait_frame(void) __naked;

#endif
