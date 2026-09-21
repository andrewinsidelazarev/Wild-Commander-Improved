
#include <stdio.h>
#include <string.h>
#include <defs.h>
#include <sdklib.h>
#include <ft812.h>
#include <ft812lib.h>
#include <tslib.h>
#include <wc_api.h>
#include "tsconf.h"
#include <esp_spi_defs.h>

#include <wc_api.c>
#ifndef FTVIEW_VIDEO_BANK
#include <esp32.c>
#endif

typedef struct
{
  u8 sig[3];
  u8 type;
  u16 xs;
  u16 ys;
} DXP;

typedef struct
{
  u16 sig;
  u16 len;
  u8 prec;
  u8 ys[2];
  u8 xs[2];
} SOF;

typedef struct
{
  u32 sig;
  u8 xs[4];
  u8 ys[4];
  u8 bits;
  u8 ctype;
} IHDR;

typedef struct
{
  u32 len;
  u32 sig;
} tRNS;

#define FS_BUF_SIZE 0x1000
// Вторая страница выделяется самим WC по заголовку WMF и отображается в
// #C000 через API 0. Это собственная память плагина, не буфер интерфейса WC.
// Чтение восьми секторов за вызов уменьшает накладные расходы LOAD512/FAT.
// Код, cmdl и состояние остаются в #8000..#BFFF, отдельно от файловых данных.
__at (0xC000) u8 fs_buf[0x4000];
u8 cmdl[0x180];

// У плагина нет стандартного CRT: инициализируем состояние явно при входе.
// Запись через приведение указателя к const запрещена правилами C.
u8 state_ft, state_esp, graphics_active;
// Единственные общие данные двух банков кода. При переходе через API 79
// адреса не меняются; обычные глобальные переменные новый банк создаёт заново.
// Диапазон закреплён проверками сборки и не пересекается с DATA/буфером #C000.
__at (0xBFE0) u16 ret_sp;
__at (0xBFE2) u16 ret_ix;
__at (0xBFE4) u16 ret_iy;
__at (0xBFE6) u32 filesize;
__at (0xBFEA) u8 file_ext;
__at (0xBFEB) u8 call_type;
// Банк изображений загрузил драйвер General Sound: звук AVI идёт на GS.
// При любом выходе видеобанк возвращает GS в ПЗУ (см. view_cleanup).
__at (0xBFEC) u8 gs_loaded;
// Для AVI VDAC2 инициализирует банк изображений: state_ft в битах 0..1,
// биты 2..4 — этап отказа загрузки GS (gs_stage, 0 — драйвер работает),
// бит 7 — видеосреда WC уже изменена и требует восстановления.
__at (0xBFED) u8 ft_state;
void wc_video_bank();
void far_call(void *param);

// Признак неудачной загрузки текущего файла. Сбрасывается при входе в плагин;
// нужен для общего выхода в WC после ошибки чтения, формата или сопроцессора.
u8 view_failed;
#define VIEW_TOO_LARGE 2

// left — число ещё не переданных байтов файла. Читаем не больше fs_buf,
// округляя только запрос к WC до целых секторов. Возвращаем true лишь если
// LOAD512 продвинул указатель на весь запрошенный объём. Последний неполный
// сектор допустим, но его байты за EOF потребитель не должен передавать FT812.
bool read_chunk(u32 left)
{
  u16 count = min(left, FS_BUF_SIZE);
  u8 sectors = (count + 511) >> 9;
  if (!count || *(volatile u8*)_ABT ||
      wc_load512(fs_buf, sectors) != (u16)fs_buf + ((u16)sectors << 9))
  {
    view_failed = 1;
    return false;
  }
  return true;
}

// Ждём wanted свободных байтов в командном FIFO. Значение 0xFFC означает,
// что очередь пуста; потоковое видео требует ещё и команды-барьера (см. AVI).
// Младшие ненулевые биты — ошибка сопроцессора.
// Ограничение 150 тиков WC прерывает зависший декодер. Независимый счётчик
// опросов гарантирует выход и при остановленном таймере. Esc отменяет ожидание.
// При неудаче сбрасываем сопроцессор, чтобы следующий файл мог открыться.
bool fifo_wait(u16 wanted)
{
  u8 tick = *(volatile u8*)_TMN;
  u16 polls = 0xFFFF;
  do
  {
    u16 space = ft_rreg16(FT_REG_CMDB_SPACE);
    if (*(volatile u8*)_ABT || (space & 3)) break;
    if (space >= wanted && space <= 0xFFC) return true;
  } while (--polls && (u8)(*(volatile u8*)_TMN - tick) < 150);
  view_failed = 1;
  ft_cp_reset();
  return false;
}

// Передаём count полезных байтов в FIFO, дожидаясь свободного места порциями.
// FT812 требует длину, кратную четырём: хвост последней порции зануляем,
// иначе в поток попадают старые байты буфера. У data должны быть доступны
// до трёх дополнительных байтов. Нулевую длину в функцию SDK не передаём.
bool fifo_send(u8 *data, u16 count)
{
  u16 padded = (count + 3) & 0xFFFC;
  u16 tail = count;
  // Все вызывающие передают буфер с запасом до кратной четырём границы.
  while (tail < padded) data[tail++] = 0;
  while (padded)
  {
    // Ждём места для всей порции. Повторное чтение SPACE с маской могло
    // превратить код ошибки 0xFFF в допустимые 0xFFC между двумя опросами.
    u16 part = min(padded, 0xFFC);
    if (!fifo_wait(part)) return false;
    // OTIR тратит 21 такт Z80 на байт: при штатных 7 МГц WC этого мало
    // для AVI около 380 КБ/с, и звуковое кольцо повторяет старые сэмплы.
    // Данные и cmdl лежат в разных собственных страницах; DMA передаёт ровно
    // part байтов (кратно четырём), не захватывая хвост последнего сектора.
    ft_load_ram_dma(data, *(u8*)((u16)data >= 0xC000 ? _PAGE3 : _PAGE2),
                    FT_REG_CMDB_WRITE, part);
    data += part;
    padded -= part;
  }
  return true;
}

// Отправляем команды, накопленные SDK в cmdl, через тот же проверяемый путь,
// что и данные. Счётчик SDK измеряется в 32-битных словах, не в байтах.
bool fifo_flush()
{
  u16 count = ft_ccmdp << 2;
  ft_ccmdp = 0;
  return fifo_send((u8*)ft_ccmdb, count);
}

#include "gs_zx.c"

// Единый выход нужен и при ошибке, и при PgUp/PgDn: остановить видео/звук,
// снять выбор SPI, вернуть палитру и теневые видеорегистры WC. API 64 пишет
// палитру по #1000, поэтому сначала отображаем свободную видеостраницу API 80;
// нельзя выполнять GEDPL поверх страницы файловой системы или плагина.
void view_cleanup()
{
#ifdef FTVIEW_VIDEO_BANK
  // Драйвер GS отдаёт управление ПЗУ: иначе другие программы не получат
  // штатных команд GS. Выполняется и тогда, когда VDAC2 не найден.
  if (gs_loaded)
  {
    (void)gs_data;  // непрочитанный ответ драйвера не должен задержать выход
    gs_cmd(GS_EXIT);
    gs_loaded = 0;
  }
#endif
  if (!graphics_active) return;
  ft_cp_reset();
  ft_wreg8(FT_REG_PLAYBACK_PLAY, 0);
  ft_wreg8(FT_REG_INT_EN, 0);
  ft_spi_unsel();
  wc_video_clock(0);
  __asm
    push ix
    xor a
    ex af, af
    ld a, #80
    call _WCAPI
    xor a
    ex af, af
    ld a, #_MNGV_PL
    call _WCAPI
    pop ix
  __endasm;
  graphics_active = state_ft = 0;
}

// --- Extensions ---------------------------
enum
{
  EXT_JPG,
  EXT_PNG,
  EXT_DLS,
  EXT_DXP,
  EXT_AVI,
  EXT_XM,
  EXT_XMZ,
};

// --- Windows ------------------------------
const WC_TX_WINDOW err_no_ft =
{
  /* window with header and text   */  WC_WIND_HDR_TXT,
  /* cursor color mask             */  0,
  /* X,Y (position)                */  24, 10,
  /* W,H (size)                    */  32, 5,
  /* paper/ink (window color)      */  0x2F,
  /* -reserved-                    */  0,
  /* window restore buffer address */  0,
  /* separators                    */  0, 0,
  /* header text                   */  "\x0E" " Error! ",
  /* footer text                   */  "",
  /* window text                   */  "\x0E\x0C\x01" "No VDAC2 detected!",
};

#ifndef FTVIEW_VIDEO_BANK
const WC_TX_WINDOW err_no_esp =
{
  /* window with header and text   */  WC_WIND_HDR_TXT,
  /* cursor color mask             */  0,
  /* X,Y (position)                */  24, 10,
  /* W,H (size)                    */  32, 5,
  /* paper/ink (window color)      */  0x2F,
  /* -reserved-                    */  0,
  /* window restore buffer address */  0,
  /* separators                    */  0, 0,
  /* header text                   */  "\x0E" " Error! ",
  /* footer text                   */  "",
  /* window text                   */  "\x0E\x0C\x01" "No ESP32 detected!",
};
#endif

// Сообщение остаётся на текстовом экране WC; повреждённый файл не должен
// молча показывать последний кадр предыдущего просмотра.
const WC_TX_WINDOW err_file =
{
  WC_WIND_HDR_TXT, 0, 19, 10, 42, 7, 0x2F, 0, 0, 0, 0,
  "\x0E" " Cannot display file ", "",
  "\x0E\x0C\x01" "Unsupported, damaged or too large.\r"
  "\x0E" "FT812 image memory: 1 MiB."
};

#ifndef FTVIEW_VIDEO_BANK
const WC_TX_WINDOW err_size =
{
  WC_WIND_HDR_TXT, 0, 19, 10, 42, 7, 0x2F, 0, 0, 0, 0,
  "\x0E" " Error! ", "",
  // Текст WC начинается с внутренней строки 1. Смещаем на 2 к середине
  // окна высотой 7; код 0E вычисляет горизонтальный центр по длине строки.
  "\x0C\x02\x0E" "Image too large"
};

const WC_TX_WINDOW win_about =
{
  /* window with header and text   */  WC_WIND_HDR_TXT,
  /* cursor color mask             */  0,
  /* X,Y (position)                */  22, 10,
  /* W,H (size)                    */  36, 5,
  /* paper/ink (window color)      */  0x4F,
  /* -reserved-                    */  0,
  /* window restore buffer address */  0,
  /* separators                    */  0, 0,
  /* header text                   */  "\x0E" " About ",
  /* footer text                   */  "",
  /* window text                   */  "\x0E\x0C\x01" "FT812 Viewer v1.2, (c)2024 TSL"
};
#endif

// --- FT812 --------------------------------
// Инициализация того же режима 1024x768@59, что использовал исходный плагин.
// Ожидания ID/CPURESET ограничены: неверный статус VDAC2 не должен навечно
// оставлять WC внутри ft_init из старого SDK. Регистры развёртки не зависят
// от пропорций открываемого изображения и после этого больше не меняются.
// Для AVI её выполняет банк изображений до перехода (см. ft_state).
#ifndef FTVIEW_VIDEO_BANK
bool vdac2_init()
{
  u16 tries = 0xFFFF;
  if ((ts_rreg(TS_STATUS) & 7) != 7) return false;
  graphics_active = 1;
  ft_cmd(FT_CMD_PWRDOWN);
  ft_cmd(FT_CMD_ACTIVE);
  ft_cmd(FT_CMD_SLEEP);
  ft_cmd(FT_CMD_CLKEXT);
  ft_cmdp(FT_CMD_CLKSEL, 8 | 0x40);
  ft_cmd(FT_CMD_ACTIVE);
  ft_cmd(FT_CMD_RST_PULSE);
  while (ft_rreg8(FT_REG_ID) != FT_ID || ft_rreg16(FT_REG_CPURESET))
    if (!--tries || *(volatile u8*)_ABT) return false;

  ft_wreg8(FT_REG_PCLK, 0);
  ft_wreg16(FT_REG_HCYCLE, 1344);
  ft_wreg16(FT_REG_HOFFSET, 320);
  ft_wreg16(FT_REG_HSYNC0, 24);
  ft_wreg16(FT_REG_HSYNC1, 160);
  ft_wreg16(FT_REG_VCYCLE, 806);
  ft_wreg16(FT_REG_VOFFSET, 37);
  ft_wreg16(FT_REG_VSYNC0, 2);
  ft_wreg16(FT_REG_VSYNC1, 8);
  ft_wreg16(FT_REG_HSIZE, 1024);
  ft_wreg16(FT_REG_VSIZE, 768);
  ft_wreg8(FT_REG_SWIZZLE, 0);
  ft_wreg8(FT_REG_PCLK_POL, 0);
  ft_wreg8(FT_REG_CSPREAD, 0);
  ft_ccmd_start(cmdl);
  ft_ClearColorRGB(0, 0, 0);
  ft_Clear(1, 1, 1);
  ft_Display();
  ft_write_dl(cmdl, 3);
  ft_wreg8(FT_REG_DLSWAP, FT_DLSWAP_FRAME);
  ft_wreg8(FT_REG_ADAPTIVE_FRAMERATE, 0);
  ft_wreg32(FT_REG_GPIOX_DIR, 0x8000UL);
  ft_wreg32(FT_REG_GPIOX, 0x9200UL);
  ft_wreg8(FT_REG_PCLK, 1);
  // Плагин использует таймер WC, отдельные прерывания FT812 ему не нужны.
  ft_wreg8(FT_REG_INT_EN, 0);
  return true;
}

bool esp_init()
{
  esp_cmd(ESP_CMD_NOP);
  esp_rd_end();
  esp_wr_end();

  // +++ detect

  return true;
}
#endif

#ifndef FTVIEW_VIDEO_BANK
// Буферный разбор заголовка: JPEG может иметь EXIF/APP-сегменты длиннее
// 4 КиБ. Содержимое сегментов пропускаем по длине, а не ищем FF Cx внутри
// произвольных данных: FF C4, например, обозначает таблицу Хаффмана, не SOF.
u32 header_left;
u16 header_pos, header_size;
u16 image_x, image_y;

u8 header_byte()
{
  // После отказа чтения avi_word()/разбор маркера ещё могут запросить
  // остальные байты поля. Не повторяем LOAD512 поверх ошибочного потока.
  if (view_failed) return 0;
  if (header_pos == header_size)
  {
    if (!header_left || !read_chunk(header_left))
    { view_failed = 1; return 0; }
    header_size = min(header_left, FS_BUF_SIZE);
    header_pos = 0;
    header_left -= header_size;
  }
  return fs_buf[header_pos++];
}

// Считываем RIFF little-endian независимо от выравнивания поля в буфере.
u32 avi_word()
{
  u32 value = header_byte();
  value |= (u32)header_byte() << 8;
  value |= (u32)header_byte() << 16;
  value |= (u32)header_byte() << 24;
  return value;
}
#endif

#include "avi_index.c"

#ifndef FTVIEW_VIDEO_BANK
u16 header_word()
{
  u16 hi = header_byte();
  return (hi << 8) | header_byte();
}

// Разрешаем только форматы, поддержанные CMD_LOADIMAGE FT81x: baseline JPEG
// (8 бит, один или три компонента) и PNG 8 бит без чересстрочной развёртки.
// До передачи сжатых данных проверяем, что результат поместится в RAM_G
// (1 МиБ), а ширина/высота — в 11-битные поля BITMAP_SIZE_H/LAYOUT_H.
bool image_header(u8 is_jpg)
{
  u8 pixel_bytes = 2;
  u16 extra = 0;
  header_left = filesize;
  header_pos = header_size = 0;
  if (is_jpg)
  {
    u8 marker;
    u16 length;
    if (header_word() != 0xFFD8) return false;
    for (;;)
    {
      if (view_failed || header_byte() != 0xFF) return false;
      do { marker = header_byte(); } while (marker == 0xFF && !view_failed);
      if (view_failed || marker == 0 || marker == 0xD8 || marker == 0xD9 ||
          marker == 0xDA || (marker >= 0xD0 && marker <= 0xD7)) return false;
      length = header_word();
      if (view_failed || length < 2) return false;
      if (marker == 0xC0)
      {
        u8 components;
        if (length < 11 || header_byte() != 8) return false;
        image_y = header_word();
        image_x = header_word();
        components = header_byte();
        if ((components != 1 && components != 3) || length != 8 + 3 * components)
          return false;
        pixel_bytes = (components == 1) ? 1 : 2;
        break;
      }
      // Остальные SOF — progressive/lossless/extended JPEG. Таблицы DHT,
      // DAC и маркер JPG сюда не относятся и могут быть пропущены по длине.
      if (marker >= 0xC0 && marker <= 0xCF &&
          marker != 0xC4 && marker != 0xC8 && marker != 0xCC) return false;
      length -= 2;
      while (length-- && !view_failed) header_byte();
    }
  }
  else
  {
    u8 type;
    if (filesize < 33 || !read_chunk(filesize) ||
        memcmp(fs_buf, "\x89PNG\x0D\x0A\x1A\x0A", 8) ||
        memcmp(fs_buf + 8, "\0\0\0\x0D" "IHDR", 8) ||
        fs_buf[16] || fs_buf[17] || fs_buf[20] || fs_buf[21] ||
        fs_buf[24] != 8 || fs_buf[26] || fs_buf[27] || fs_buf[28]) return false;
    image_x = ((u16)fs_buf[18] << 8) | fs_buf[19];
    image_y = ((u16)fs_buf[22] << 8) | fs_buf[23];
    type = fs_buf[25];
    if (type == 0) pixel_bytes = 1;
    else if (type == 3) { pixel_bytes = 1; extra = 512; }
    else if (type != 2 && type != 6) return false;
  }
  if (view_failed || !image_x || !image_y) return false;
  if (image_x > 2047 || image_y > 2047 ||
      (u32)image_x * image_y * pixel_bytes + extra > 0x100000UL)
  { view_failed = VIEW_TOO_LARGE; return false; }
  return wc_rewind();
}

void show_jpg_png(u8 is_jpg)
{
  u32 left = filesize;
  if (!image_header(is_jpg))
  { if (!view_failed) view_failed = 1; return; }
  wc_vmode(0x87);
  ft_ccmd_start(cmdl);
  ft_Dlstart();
  ft_Clear(1, 1, 1);
  // CMD_LOADIMAGE сам выставляет формат и адрес палитры. Ручное угадывание
  // по tRNS ломало индексированные PNG с несколькими прозрачными цветами.
  // SWAP выполняем после декодирования, не показывая старое содержимое RAM_G.
  ft_LoadImage(FT_RAM_G, 0);
  if (!fifo_flush()) return;
  while (left)
  {
    u16 count = min(left, FS_BUF_SIZE);
    if (!read_chunk(left) || !fifo_send(fs_buf, count)) return;
    left -= count;
  }
  if (!fifo_wait(0xFFC)) return;
  ft_Begin(FT_BITMAPS);
  ft_Vertex2ii((1024 - min(1024, image_x)) >> 1,
              (768 - min(768, image_y)) >> 1, 0, 0);
  ft_Display();
  ft_ccmd(FT_CCMD_SWAP);
  if (fifo_flush()) fifo_wait(0xFFC);
}

void show_dxp()
{
  u32 sz, o;
  u16 xo, yo;
  DXP *d;

  // Проверяем длину до unsigned-вычитания: размер 0..7 раньше превращался
  // в почти 4 ГиБ. Размеры DXT1 кратны четырём; два массива занимают xs*ys/2.
  if (filesize < sizeof(DXP) || !read_chunk(filesize))
  { view_failed = 1; return; }
  sz = filesize - sizeof(DXP);
  d = (DXP*)fs_buf;
  if (memcmp(d->sig, "DXP", 3) || d->type > 1 ||
      !d->xs || !d->ys || ((d->xs | d->ys) & 3) ||
      d->xs > 2047 || d->ys > 2047 || !sz)
  { view_failed = 1; return; }
  o = (u32)d->xs * ((u32)d->ys >> 2);
  if (o > 0x80000UL || (!d->type && sz != o * 2))
  { view_failed = 1; return; }
  xo = (1024 - min(1024, d->xs)) >> 1;
  yo = (768 - min(768, d->ys)) >> 1;
  wc_vmode(0x87);

  ft_ccmd_start(cmdl);
  ft_Dlstart();
  ft_Clear(1, 1, 1);
  // ft_ccmd(ft_SaveContext());

  ft_BitmapHandle(0);
  ft_SetBitmap(FT_RAM_G + o, FT_L2, d->xs, d->ys);
  ft_BitmapHandle(1);
  ft_SetBitmap(FT_RAM_G, FT_RGB565, d->xs >> 2, d->ys >> 2);
  ft_BitmapSize(FT_NEAREST, FT_BORDER, FT_BORDER, d->xs, d->ys);

  ft_Begin(FT_BITMAPS);
  ft_ColorA(255);
  ft_BlendFunc(FT_ONE, FT_ZERO);
  ft_Vertex2ii(xo, yo, 0, 0);

  ft_ColorMask(1, 1, 1, 0);
  ft_BitmapTransformA(64);
  ft_BitmapTransformE(64);
  ft_BlendFunc(FT_ONE_MINUS_DST_ALPHA, FT_ZERO);
  ft_Vertex2ii(xo, yo, 1, 0);
  ft_BlendFunc(FT_DST_ALPHA, FT_ONE);
  ft_Vertex2ii(xo, yo, 1, 1);

  // ft_RestoreContext();
  // ft_SetBase(10);
  // ft_Number(0, 0, 18, 0, filesize);

  ft_Display();
  // Формируем новый дисплей-лист, но показываем его только после загрузки
  // пикселей. Иначе FT812 рисует старые данные RAM_G под новым описателем.
  if (!fifo_flush() || !fifo_wait(0xFFC)) return;

  {
    u8 *bptr = fs_buf + sizeof(DXP);
    u16 bsz = min(filesize, FS_BUF_SIZE) - sizeof(DXP);

    if (d->type == 0)
    {
      u32 gptr = FT_RAM_G;

      while (sz)
      {
        u16 s = min(sz, bsz);
        ft_write(bptr, gptr, s);
        gptr += s, sz -= s, bptr = fs_buf, bsz = FS_BUF_SIZE;

        if (sz && !read_chunk(sz)) return;
      }
    }
    else
    {
      ft_ccmd_start(cmdl);
      ft_Inflate(FT_RAM_G);
      if (!fifo_flush()) return;

      while (sz)
      {
        u16 s = min(sz, bsz);
        if (!fifo_send(bptr, s)) return;
        sz -= s, bptr = fs_buf, bsz = FS_BUF_SIZE;

        if (sz && !read_chunk(sz)) return;
      }

      if (!fifo_wait(0xFFC)) return;
    }
  }
  ft_ccmd(FT_CCMD_SWAP);
  if (fifo_flush()) fifo_wait(0xFFC);
}

void show_dls()
{
  u32 left = filesize;
  u32 dest = FT_RAM_DL;
  // RAM_DL в FT812 — ровно 8 КиБ, инструкции имеют длину четыре байта.
  // Не допускаем запись за её границу или обращение к SDK с длиной ноль.
  if (!left || left > 8192 || (left & 3))
  { view_failed = 1; return; }
  wc_vmode(0x87);
  while (left)
  {
    u16 count = min(left, FS_BUF_SIZE);
    if (!read_chunk(left)) return;
    ft_write(fs_buf, dest, count);
    dest += count;
    left -= count;
  }
  // За коротким списком ставим DISPLAY: не исполняем хвост предыдущего DLS.
  if (filesize < 8192)
  {
    memset(fs_buf, 0, 4);
    ft_write(fs_buf, dest, 4);
  }
  ft_wreg8(FT_REG_DLSWAP, FT_DLSWAP_FRAME);
}

#else
#include "avi_controls.c"

// Штатное воспроизведение со звуком использует то же двухступенчатое чтение:
// упреждающий буфер в собственных страницах EVO -> media FIFO FT812.
void show_avi()
{
  u32 left = filesize;
  wc_video_clock(1);
  ft_wreg32(FT_REG_FREQUENCY, 64000000UL);
  if (avi_controls()) return;
  if (left < 12 || !read_chunk(left) ||
      memcmp(fs_buf, "RIFF", 4) || memcmp(fs_buf + 8, "AVI ", 4))
  { view_failed = 1; return; }

  wc_vmode(0x87);
  ft_wreg32(FT_REG_FREQUENCY, 64000000UL);
  avi_restart(true);
}
#endif

#ifndef FTVIEW_VIDEO_BANK
void play_xm()
{
  esp_cmd(ESP_CMD_XM_STOP);
  esp_wait_busy(10000);
  esp_cmd(ESP_CMD_KILL_OBJECTS);
  esp_wait_busy(10000);
  
  u8 h = esp_create_obj(filesize, (file_ext == EXT_XM) ? OBJ_TYPE_XM : OBJ_TYPE_ZIP);

  u32 sz = filesize;
  u32 offs = 0;

  while (sz)
  {
    u32 s = min(sz, FS_BUF_SIZE);
    u8 sec = (s + 511) >> 9;

    if (!read_chunk(sz)) return;

    esp_wr_reg32(ESP_REG_DATA_SIZE, s);
    esp_wr_reg32(ESP_REG_DATA_OFFSET, offs);
    esp_cmd(ESP_CMD_WRITE_OBJECT);
    esp_wait_status(ESP_ST_DATA_M2S, 2000);
    esp_send_dma((u16)fs_buf, *(u8*)_PAGE3, 512, sec);

    offs += s;
    sz -= s;
  }

  if (file_ext == EXT_XMZ)
  {
    esp_wr_reg8(ESP_REG_OBJ_TYPE, OBJ_TYPE_XM);
    esp_wr_reg32(ESP_REG_DATA_SIZE, filesize);
    esp_cmd(ESP_CMD_UNZIP);
    esp_wait_busy(10000);
  }
  
  esp_cmd(ESP_CMD_XM_INIT);
  esp_wait_busy(10000);
  esp_cmd(ESP_CMD_XM_PLAY);
  esp_wait_busy(10000);
}
#endif

// --- Aux functions ------------------------
void wait_esc_key()
{
  while (1)
  {
    __asm
      ei
      halt
    __endasm;

    if (wc_api__bool(_ESC))
      break;
  }
}

// Окно ошибки или сведений до Esc, затем выход в WC.
void show_window(const WC_TX_WINDOW *window)
{
  wc_api_u16(_PRWOW, (u16)window);
  wait_esc_key();
  wc_api_u16(_RRESB, (u16)window);
  wc_exit(WC_EXIT);
}

void main_start()
{
  // ABT — накопленный флаг, не текущее состояние клавиши. WC не сбрасывает
  // его перед каждым плагином: старый Esc не должен отменять новый просмотр.
  *(volatile u8*)_ABT = 0;
  // Audio player
#ifndef FTVIEW_VIDEO_BANK
  if (file_ext == EXT_XM || file_ext == EXT_XMZ)
  {
    if (!state_esp)
      state_esp = esp_init() ? 1 : 2;

    if (state_esp != 1)
      show_window(&err_no_esp);
    else
      play_xm();
  }

  // Viewer
  else
#endif
  {
#ifndef FTVIEW_VIDEO_BANK
    if (!state_ft)
      state_ft = vdac2_init() ? 1 : 2;
#else
    state_ft = ft_state & 3;
    graphics_active = ft_state >> 7;
#endif

    if (state_ft != 1)
      show_window(&err_no_ft);

    else switch (file_ext)
    {
#ifndef FTVIEW_VIDEO_BANK
      case EXT_JPG:
      case EXT_PNG:
        show_jpg_png(file_ext == EXT_JPG);
      break;

      case EXT_DXP:
        show_dxp();
      break;

      case EXT_DLS:
        show_dls();
      break;
#else
      case EXT_AVI:
        show_avi();
      break;
#endif
    }
  }

  // Не оставляем WC ждать клавиш поверх незавершённой загрузки.
  if (view_failed)
  {
    view_cleanup();
    if (!*(volatile u8*)_ABT)
#ifndef FTVIEW_VIDEO_BANK
      show_window(view_failed == VIEW_TOO_LARGE ? &err_size : &err_file);
#else
      show_window(&err_file);
#endif
    wc_exit(WC_EXIT);
  }

  // poll keys
  while (1)
  {
    __asm
      // HALT при DI не проснётся от клавиатуры. Включаем IM2 явно.
      ei
      halt
    __endasm;

    if (wc_api__bool(_PGD))   // PgDn - next file
      wc_exit(WC_NEXT_FILE);

    if (wc_api__bool(_PGU))   // PgUp - previous file
      wc_exit(WC_PREV_FILE);

    if (wc_api__bool(_ESC))   // Esc - exit
      wc_exit(WC_EXIT);

    if ((file_ext == EXT_XM) || (file_ext == EXT_XMZ))
      wc_exit(WC_EXIT);
  }
}

// ------------------------------------------
void main() __naked
{
  __asm
    ld (_ret_sp), sp
    ld (_ret_ix), ix
    ld (_ret_iy), iy
    ld (_call_type), a
    ex af, af
    ld (_file_ext), a
    ld (_filesize), hl
    ld (_filesize + 2), de
    jp _main_dispatch
  __endasm;
}

// Входной регистровый контракт захвачен до возможного пролога SDCC.
void main_dispatch()
{
#ifndef FTVIEW_VIDEO_BANK
  // ABT — накопленный флаг Esc: WC не сбрасывает его перед плагином. Для AVI
  // gs_boot и vdac2_init идут здесь, ещё до main_start. Esc, которым вышли из
  // прошлого просмотра, обрывал ожидание FT812 после сброса, и плагин
  // сообщал «No VDAC2 detected!».
  *(volatile u8*)_ABT = 0;
  gs_loaded = 0;
  index_state = 0;
  // Переход выполняется до инициализации FT812. Шлюз восстанавливает входной
  // SP и не возвращается в старый банк: все пути выхода принадлежат видеобанку.
  // Драйвер GS загружается здесь: его код не занимает место видеобанка.
  if (call_type == WC_CALL_EXT && file_ext == EXT_AVI)
  {
    gs_loaded = gs_boot();
    graphics_active = 0;
    ft_state = (vdac2_init() ? 1 : 2) | gs_stage << 2;
    if (graphics_active) ft_state |= 0x80;
    wc_video_bank();
  }
#endif
  view_failed = 0;
  state_ft = state_esp = graphics_active = 0;
#ifndef FTVIEW_VIDEO_BANK
  switch (call_type)
  {
    case WC_CALL_EXT:
      wc_map_buffer(1);
      main_start();
    break;

    case WC_CALL_MENU:
      show_window(&win_about);
    break;

    default:
      wc_exit(WC_EXIT);
  }
#else
  // Видеобанк получает управление только из шлюза для AVI.
  wc_map_buffer(1);
  main_start();
#endif
}
