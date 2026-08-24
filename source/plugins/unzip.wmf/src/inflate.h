#ifndef INFLATE_H
#define INFLATE_H

#include "wc_api.h"

extern u32 zip_total_out;
extern u8 zip_error;

u8 zip_read_data_byte(u8 *value);
u8 zip_emit_byte(u8 value);
u8 inflate_raw(void);

#endif
