// Блок параметров банка списка роликов (страница 10 WMF). Лежит в окне #C000,
// в первой странице буфера за кэшем EVO (#C000..#FDFF): это окно одно и то же
// во всех банках. Вызов — far_call(LIST_PAGE, LIST_FAR) из видеобанка. Текущий
// ролик (кластер) и размер кадра банк берёт из копии полей AVI в AVI_FAR,
// выбранный ролик (кластер и размер файла) кладёт туда же.

// Кадр на экране: растяжение и матрица. В видеобанке это переменные HUD
// (avi_controls.c) — они копируются в блок одним присваиванием.
typedef struct
{
  u16 w, h;           // размер на экране
  u32 ta, te;         // BITMAP_TRANSFORM_A/E
} LIST_VIEW;

typedef struct
{
  u8 chosen;          // выход: 1 — выбран ролик (Enter), в том числе текущий
  u8 op;              // вход: LIST_OP_*
  u32 address;        // кадр на экране (RAM_G), под окном списка
  LIST_VIEW view;
  u8 code;            // вход: место отказа плеера для окна сообщения
} LIST_SHARED;

#define LIST_FAR ((LIST_SHARED*)0xFE00)
#define LIST_PAGE 10

// Что делает банк списка. Кроме самого списка он показывает окна сообщений
// плеера: в видеобанке на них не осталось места.
#define LIST_OP_PICK 0    // окно списка роликов
#define LIST_OP_CODEC 1   // «Unsupported video codec»
#define LIST_OP_FILE 2    // «Cannot display file»
#define LIST_OP_MJPEG 3   // кодек по началу файла в fs_buf: chosen 0 — чужой
#define LIST_OP_NOFT 4    // «No VDAC2 detected!»
