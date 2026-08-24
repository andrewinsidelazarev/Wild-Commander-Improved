#include "wc_api.h"
#include "inflate.h"

#define CONTROL_INPUT       ((volatile u16 *)0x7e00)
#define CONTROL_LENGTH      ((volatile u16 *)0x7e02)
#define CONTROL_RESULT      ((volatile u8 *)0x7e04)
#define CONTROL_ERROR       ((volatile u8 *)0x7e05)
#define CONTROL_CONSUMED    ((volatile u16 *)0x7e06)
#define CONTROL_OUTPUT_SIZE ((volatile u32 *)0x7e08)

u32 zip_total_out;
u8 zip_error;

static u16 input_start;
static u16 input_position;
static u16 input_end;

u8 zip_read_data_byte(u8 *value)
{
    if (input_position >= input_end) {
        zip_error = 1;
        return 0;
    }
    *value = *((volatile u8 *)input_position++);
    return 1;
}

u8 zip_emit_byte(u8 value)
{
    u16 history_position = (u16)zip_total_out & 0x7fff;

    if (history_position < 0x4000) {
        *((volatile u8 *)history_position) = value;
    } else {
        *((volatile u8 *)(history_position + 0x8000)) = value;
    }
    zip_total_out++;
    return 1;
}

void inflate_test_main(void)
{
    input_start = *CONTROL_INPUT;
    input_position = input_start;
    input_end = input_start + *CONTROL_LENGTH;
    zip_total_out = 0;
    zip_error = 0;

    *CONTROL_RESULT = inflate_raw();
    *CONTROL_ERROR = zip_error;
    *CONTROL_CONSUMED = input_position - input_start;
    *CONTROL_OUTPUT_SIZE = zip_total_out;
}
