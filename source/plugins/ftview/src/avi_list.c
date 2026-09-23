// Список роликов каталога (банк списка, страница 10 WMF). Enter в плеере
// ставит видео на паузу и вызывает far_entry этого банка. Он читает активный
// каталог WC так же, как ядро при обходе каталога (кластер LSTCAT, GIPAG,
// LOAD512), оставляет AVI с видео MJPG, сортирует их по имени и показывает
// полупрозрачное окно поверх кадра, с курсором на текущем ролике. Имена —
// без «.avi», длинные обрезаются по ширине строки окна с «...».
// Вверх/вниз (с автоповтором), PgUp/PgDn, Home/End — выбор, Enter — запуск
// выбранного, Esc — назад к ролику.

#include "avi_shared.h"
#include "avi_list.h"

// Окно: рамка, строки списка. Имя — от WX0 + 28 до WX1 - 28: те же 16 точек
// от краёв полосы выбора, что и слева.
#define WX0 96
#define WX1 928
#define WY0 56
#define WY1 712
#define ROWH 32
#define ROWS 17
#define ROWY (WY0 + 56)
#define NAME_PX (WX1 - WX0 - 56)

#define LIST_MAX 80
// Имя в таблице — до NAME_MAX символов, при обрезке ещё «...» и ноль. Строка
// окна вмещает ~72 строчных или ~57 заглавных букв: обычное имя упирается в
// её ширину, а не в таблицу.
#define NAME_MAX 96
typedef struct
{
  u32 cluster, size;
  u8 key[16];         // ключ сортировки: латиница заглавными, кириллица — #80+номер
  char name[NAME_MAX + 4];  // имя на экране: ASCII, кириллица транслитом
} LIST_ENTRY;
// Команды окна (до ~2,3 КБ) и таблица (80 записей по 124 байта) — в первой
// странице буфера за сектором каталога (fs_buf, #C000..#C1FF), до блоков
// параметров #FE00: её кэш EVO плеер после списка всё равно читает заново —
// поток идёт с показанного кадра или с начала другого ролика. Страница
// отображена в #C000 всё время работы банка (list_run).
#define LIST_CMD ((void*)0xC200)
// Конец таблицы (#F2C0) не должен дойти до #FE00 — проверяет тест списка.
__at (0xCC00) LIST_ENTRY list_e[LIST_MAX];
u8 list_count, list_sel, list_top;
LIST_ENTRY list_tmp;

// Кластер активного каталога WC: вход ядра #4021 (TLSTCAT) копирует LSTCAT
// по адресу DE. Им же пользуется сам WC.
void dir_cluster(u32 *dst) __sdcccall(1) __naked
{
  dst;
  __asm
    ex de, hl
    push ix
    push iy
    call 0x4021
    pop iy
    pop ix
    ret
  __endasm;
}

// --- Имена -------------------------------------------------------------
// Длинное имя: первые восемь частей (104 символа UTF-16) — длиннее строка
// окна всё равно не вмещает. Части идут в обратном порядке, первой —
// последняя (бит 6); все несут контрольную сумму короткого имени, по которой
// длинное имя проверяется.
#define LFN_MAX 104
u16 lfn[LFN_MAX];
u8 lfn_ok, lfn_sum;
const u8 lfn_at[13] = {1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30};

// Кириллица транслитом: шрифты ПЗУ FT812 содержат только ASCII.
const char tr[32][5] = {
  "a", "b", "v", "g", "d", "e", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p",
  "r", "s", "t", "u", "f", "kh", "ts", "ch", "sh", "shch", "", "y", "", "e", "yu", "ya"};

// Ширины символов шрифта 28 из ПЗУ FT812 (list_run): имя обрезается по
// ширине строки окна, а не по числу букв.
u8 font_w[128];

LIST_ENTRY *nm_e;
u8 nm_n, nm_key_n, nm_cut;

void nm_put(char c)
{
  if (nm_n < NAME_MAX) nm_e->name[nm_n++] = c;
  else nm_cut = 1;
}

// Имя шире строки окна (или длиннее таблицы) — самое длинное начало, за
// которым ещё помещается «...»; пробелы перед «...» отбрасываются.
void nm_fit()
{
  u16 w = 0;
  u8 i, keep = 0, dots = font_w['.'] * 3;
  for (i = 0; i < nm_n; ++i)
  {
    w += font_w[(u8)nm_e->name[i]];
    if (w + dots <= NAME_PX) keep = i + 1;
  }
  if (nm_cut || w > NAME_PX)
  {
    while (keep && nm_e->name[keep - 1] == ' ') --keep;
    for (nm_n = keep, i = 0; i < 3; ++i) nm_e->name[nm_n++] = '.';
  }
  nm_e->name[nm_n] = 0;
}

void nm_key(u8 k)
{
  if (nm_key_n < 16) nm_e->key[nm_key_n++] = k;
}

// Символ имени (Unicode). На экран — ASCII, кириллица транслитом,
// подчёркивание — пробелом (им в именах файлов заменяют пробелы); в ключ
// сортировки — то же, латиница заглавными, кириллица после неё в своём
// порядке (Ё — сразу после Е), как в панели WC.
void nm_char(u16 c)
{
  if (c >= 0x410 && c < 0x450)
  {
    u8 n = (c - 0x410) & 31;
    const char *t = tr[n];
    if (*t) { nm_put(c < 0x430 ? *t - 32 : *t); ++t; }
    while (*t) nm_put(*t++);
    nm_key(0x80 + n + (n > 5));
  }
  else if (c == 0x401 || c == 0x451)
  {
    nm_put(c == 0x401 ? 'Y' : 'y'); nm_put('o');
    nm_key(0x86);
  }
  else if (c >= 0x20 && c < 0x7F)
  {
    if (c == '_') c = ' ';
    nm_put(c);
    nm_key(c >= 'a' && c <= 'z' ? c - 32 : c);
  }
  else { nm_put('?'); nm_key(0xFF); }
}

// Байт короткого имени: кодировка WC — CP866.
u16 cp866(u8 b)
{
  if (b < 0x80) return b;
  if (b < 0xA0) return 0x410 + b - 0x80;
  if (b < 0xB0) return 0x430 + b - 0xA0;
  if (b >= 0xE0 && b < 0xF0) return 0x440 + b - 0xE0;
  if (b == 0xF0) return 0x401;
  if (b == 0xF1) return 0x451;
  return '?';
}

u8 sfn_sum(u8 *e)
{
  u8 s = 0, i;
  for (i = 0; i < 11; ++i) s = (s >> 1 | s << 7) + e[i];
  return s;
}

// Запись каталога FAT32 (32 байта). Файлы *.AVI попадают в таблицу.
// Удалённая запись (#E5) — и короткая, и часть длинного имени — пропускается
// и обрывает длинное имя: иначе её бит 6 начал бы новое.
void dir_entry(u8 *e)
{
  u8 a = e[11], i;
  if (e[0] == 0xE5) { lfn_ok = 0; return; }
  if (a == 0x0F)
  {
    u8 seq = e[0] & 0x1F;
    if (e[0] & 0x40) { lfn_ok = 1; lfn_sum = e[13]; memset(lfn, 0, sizeof lfn); }
    if (!lfn_ok || e[13] != lfn_sum || !seq) { lfn_ok = 0; return; }
    // Номер части — до 20 (255 символов): смещение не считаем в байте.
    if (seq <= LFN_MAX / 13)
      for (i = 0; i < 13; ++i)
        lfn[(seq - 1) * 13 + i] = e[lfn_at[i]] | e[lfn_at[i] + 1] << 8;
    return;
  }
  if (!(a & 0x18) && e[8] == 'A' && e[9] == 'V' && e[10] == 'I')
  {
    u32 c = (u32)*(u16*)(e + 20) << 16 | *(u16*)(e + 26);
    // Таблица полна — дальше только текущий ролик, на место последнего:
    // курсор списка должен стоять на нём.
    if (list_count == LIST_MAX)
    {
      if (c != AVI_FAR->cluster) { lfn_ok = 0; return; }
      --list_count;
    }
    nm_e = &list_e[list_count++];
    nm_e->cluster = c;
    nm_e->size = *(u32*)(e + 28);
    nm_n = nm_key_n = nm_cut = 0;
    memset(nm_e->key, 0, sizeof nm_e->key);
    // «.avi» не показываем: в списке и так только AVI.
    if (lfn_ok && sfn_sum(e) == lfn_sum)
    {
      u8 n = 0;
      while (n < LFN_MAX && lfn[n] && lfn[n] != 0xFFFF) ++n;
      if (n > 4 && lfn[n - 4] == '.' && (lfn[n - 3] | 32) == 'a' &&
          (lfn[n - 2] | 32) == 'v' && (lfn[n - 1] | 32) == 'i') n -= 4;
      for (i = 0; i < n; ++i) nm_char(lfn[i]);
    }
    else
      // Короткое имя — без расширения. Первый байт #E5 (в CP866 — «х») FAT
      // хранит как #05.
      for (i = 0; i < 8 && e[i] != ' '; ++i) nm_char(cp866(i || e[0] != 5 ? e[i] : 0xE5));
    nm_fit();
  }
  lfn_ok = 0;
}

// Активный каталог целиком: по сектору, до записи с нулевым первым байтом
// (конец каталога) или конца цепочки. false — каталог не открылся.
bool dir_read()
{
  u32 dir;
  u16 sectors;
  u8 *e;
  dir_cluster(&dir);
  if (!wc_gipag(&dir)) return false;
  lfn_ok = 0;
  for (sectors = 0; sectors < 2048; ++sectors)
  {
    if (wc_load512(fs_buf, 1) != (u16)fs_buf + 512) break;
    for (e = fs_buf; e < fs_buf + 512; e += 32)
    {
      if (!e[0]) return true;
      dir_entry(e);
    }
  }
  return true;
}

// Кодек видеопотока по началу файла в fs_buf: 1 — первый strh описывает
// видео MJPG (регистр FOURCC не важен), 0 — другой кодек, 2 — судить не по
// чему (не RIFF/AVI или strh в начале нет). В список идут только 1; плеер
// (LIST_OP_MJPEG) сообщает о кодеке лишь при 0, а на 2 работает как раньше —
// в видеобанке места на саму проверку нет.
u8 buf_codec()
{
  u8 *p;
  if (memcmp(fs_buf, "RIFF", 4) || memcmp(fs_buf + 8, "AVI ", 4)) return 2;
  for (p = fs_buf + 12; p < fs_buf + 496; ++p)
    if (p[0] == 's' && p[1] == 't' && p[2] == 'r' && p[3] == 'h')
      return !memcmp(p + 8, "vids", 4) && (p[12] | 32) == 'm' && (p[13] | 32) == 'j' &&
             (p[14] | 32) == 'p' && (p[15] | 32) == 'g';
  return 2;
}

// Тот же кодек для ролика списка: его начало нужно ещё прочитать.
u8 file_codec(u32 *cluster)
{
  if (!wc_gipag(cluster) || wc_load512(fs_buf, 1) != (u16)fs_buf + 512) return 2;
  return buf_codec();
}

void list_sort()
{
  u8 i, j;
  for (i = 1; i < list_count; ++i)
    for (j = i; j && memcmp(list_e[j - 1].key, list_e[j].key, 16) > 0; --j)
    {
      list_tmp = list_e[j]; list_e[j] = list_e[j - 1]; list_e[j - 1] = list_tmp;
    }
}

// --- Окно --------------------------------------------------------------
// Окно поверх кадра: msg — сообщение вместо списка (чтение, пусто, ошибка).
bool list_show(LIST_SHARED *p, const char *msg)
{
  u8 i;
  ft_ccmd_start(LIST_CMD);
  ft_Dlstart(); ft_Clear(1, 1, 1);
  // Кадр под окном — так же, как его показывает плеер.
  ft_SetBitmap(p->address, FT_RGB565, AVI_FAR->width, AVI_FAR->height);
  ft_BitmapSize(FT_BILINEAR, FT_BORDER, FT_BORDER, p->view.w, p->view.h);
  ft_BitmapTransformA(p->view.ta); ft_BitmapTransformE(p->view.te);
  ft_Begin(FT_BITMAPS);
  ft_Vertex2ii((1024 - p->view.w) / 2, (768 - p->view.h) / 2, 0, 0);
  ft_BitmapTransformA(256); ft_BitmapTransformE(256);
  // Окно затемняет кадр на 72 %: картинка видна, текст читается и на светлой.
  ft_ColorRGB(0, 0, 0); ft_ColorA(184);
  ft_Begin(FT_RECTS);
  ft_Vertex2f(WX0 * 16, WY0 * 16); ft_Vertex2f(WX1 * 16, WY1 * 16);
  ft_ColorA(255); ft_ColorRGB(255, 255, 255);
  ft_Text(WX0 + 24, WY0 + 14, 28, 0, "Videos in this folder");
  if (msg) ft_Text(512, 360, 28, FT_OPT_CENTERX, msg);
  else
  {
    // «номер/всего»: номер — вправо к косой черте, всего — за ней.
    ft_Number(WX1 - 66, WY0 + 14, 28, FT_OPT_RIGHTX, list_sel + 1);
    ft_Text(WX1 - 64, WY0 + 14, 28, 0, "/");
    ft_Number(WX1 - 54, WY0 + 14, 28, 0, list_count);
    ft_ColorRGB(40, 110, 220); ft_ColorA(230);
    ft_Begin(FT_RECTS);
    ft_Vertex2f((WX0 + 12) * 16, (ROWY + (list_sel - list_top) * ROWH - 3) * 16);
    ft_Vertex2f((WX1 - 12) * 16, (ROWY + (list_sel - list_top + 1) * ROWH - 3) * 16);
    ft_ColorA(255);
    for (i = 0; i < ROWS && list_top + i < list_count; ++i)
    {
      LIST_ENTRY *le = &list_e[list_top + i];
      // Текущий ролик — жёлтым.
      if (le->cluster == AVI_FAR->cluster) ft_ColorRGB(255, 210, 90);
      else ft_ColorRGB(235, 235, 235);
      ft_Text(WX0 + 28, ROWY + i * ROWH, 28, 0, le->name);
    }
    ft_ColorRGB(170, 170, 170);
    ft_Text(512, WY1 - 36, 26, FT_OPT_CENTERX, "Up/Down select | Enter play | Esc back");
  }
  ft_Display(); ft_ccmd(FT_CCMD_SWAP);
  return fifo_flush() && fifo_wait(0xFFC);
}

// --- Клавиши -----------------------------------------------------------
void list_tick(u8 *tick)
{
  while (*(volatile u8*)_TMN == *tick) ;
  *tick = *(volatile u8*)_TMN;
}

// Биты: вверх, вниз, Enter, Esc, PgUp, PgDn, Home, End.
u8 list_keys()
{
  u8 k = 0;
  if (wc_api__bool(_UPPP)) k |= 1;
  if (wc_api__bool(_DWWW)) k |= 2;
  if (wc_api__bool(_ENKE)) k |= 4;
  if (wc_api__bool(_ESC) || *(volatile u8*)_ABT) k |= 8;
  if (wc_api__bool(_PGU)) k |= 16;
  if (wc_api__bool(_PGD)) k |= 32;
  if (wc_api__bool(_HOME)) k |= 64;
  if (wc_api__bool(_END)) k |= 128;
  return k;
}

void list_run(LIST_SHARED *p)
{
  u8 tick = *(volatile u8*)_TMN, prev = 0xFF, hold = 0, i;
  bool ok, redraw;
  const char *msg = 0;
  u32 root;
  p->chosen = 0;
  list_count = list_sel = list_top = 0;
  wc_map_buffer(1);
  view_failed = 0;
  // Ширины шрифта 28: ROM_FONTROOT указывает на таблицу шрифтов ПЗУ, блок
  // шрифта — 148 байт, ширины символов — его первые 128.
  ft_read(&root, 0x2FFFFCUL, 4);
  ft_read(font_w, root + 148 * (28 - 16), 128);
  if (list_show(p, "Reading folder..."))
  {
    ok = dir_read();
    // Только видео MJPG: заголовок читается из первого сектора каждого AVI.
    for (i = 0; i < list_count; )
      if (file_codec(&list_e[i].cluster) == 1) ++i;
      else list_e[i] = list_e[--list_count];
    list_sort();
    for (i = 0; i < list_count; ++i)
      if (list_e[i].cluster == AVI_FAR->cluster) list_sel = i;
    list_top = list_sel > ROWS / 2 ? list_sel - ROWS / 2 : 0;
    if (list_count > ROWS && list_top > list_count - ROWS) list_top = list_count - ROWS;
    if (!ok) msg = "Cannot read the folder";
    else if (!list_count) msg = "No MJPEG AVI files here";
    // Клавиша, открывшая список (Enter), ещё нажата: prev = все биты, в
    // счёт идут только новые нажатия. Окно перерисовывается при смене выбора.
    for (redraw = true;;)
    {
      u8 k, edge, old = list_sel;
      if (redraw && !list_show(p, msg)) break;
      redraw = false;
      list_tick(&tick);
      k = list_keys();
      edge = k & ~prev; prev = k;
      // Автоповтор перемещений: через 0,4 с удержания — каждые 60 мс.
      if (k & 0x33)
      {
        if (hold < 255) ++hold;
        if (hold > 20 && !(hold % 3)) edge |= k & 0x33;
      }
      else hold = 0;
      if (edge & 8) break;
      if (edge & 4)
      {
        // Enter — запуск выбранного ролика с начала, в том числе текущего
        // (в конце ролика — просмотр ещё раз). Назад к ролику — Esc.
        if (list_count)
        {
          p->chosen = 1;
          AVI_FAR->cluster = list_e[list_sel].cluster;
          AVI_FAR->size = list_e[list_sel].size;
        }
        break;
      }
      if (!list_count) continue;
      if ((edge & 1) && list_sel) --list_sel;
      if ((edge & 2) && list_sel + 1 < list_count) ++list_sel;
      if (edge & 16) list_sel = list_sel > ROWS ? list_sel - ROWS : 0;
      if (edge & 32) list_sel = list_sel + ROWS < list_count ? list_sel + ROWS : list_count - 1;
      if (edge & 64) list_sel = 0;
      if (edge & 128) list_sel = list_count - 1;
      if (list_sel != old)
      {
        if (list_sel < list_top) list_top = list_sel;
        if (list_sel >= list_top + ROWS) list_top = list_sel - ROWS + 1;
        redraw = true;
      }
    }
  }
  // Клавиши, закрывшие окно, не должны дойти до плеера: ждём, пока их
  // отпустят, и снимаем накопленный Esc (ABT).
  do list_tick(&tick); while (wc_api__bool(_ANYK));
  *(volatile u8*)_ABT = 0;
}

// --- Сообщения плеера --------------------------------------------------
// Окна показывает этот банк: в видеобанке на них не осталось места. Коды
// текста WC: 0E центрирует строку, 0C N — вниз на N строк, CR — в начало
// той же строки.
const WC_TX_WINDOW err_no_ft =
{
  WC_WIND_HDR_TXT, 0, 24, 10, 32, 5, 0x2F, 0, 0, 0, 0,
  "\x0E" " Error! ", "",
  "\x0E\x0C\x01" "No VDAC2 detected!"
};

const WC_TX_WINDOW err_codec =
{
  WC_WIND_HDR_TXT, 0, 19, 10, 42, 7, 0x2F, 0, 0, 0, 0,
  "\x0E" " Cannot play video ", "",
  "\x0E\x0C\x01" "Unsupported video codec.\r"
  "\x0E\x0C\x02" "FTView plays MJPEG AVI."
};

// Последние две цифры текста — место отказа плеера (fail_at): по нему
// разбирается редкий сбой, о котором сообщил пользователь.
const WC_TX_WINDOW err_file =
{
  WC_WIND_HDR_TXT, 0, 19, 10, 42, 8, 0x2F, 0, 0, 0, 0,
  "\x0E" " Cannot display file ", "",
  "\x0E\x0C\x01" "Unsupported, damaged or too large.\r"
  "\x0E\x0C\x02" "FT812 image memory: 1 MiB.\r"
  "\x0E\x0C\x03" "Build " BUILD_ID "   Reason 00"
};

// До нажатия любой клавиши (USPO — пока их отпустят, NUSP — нажатия), как
// закрывает свои окна сам WC. Выход в WC делает видеобанк после возврата.
void list_message(u8 op, u8 code)
{
  const WC_TX_WINDOW *window = op == LIST_OP_CODEC ? &err_codec :
                               op == LIST_OP_NOFT ? &err_no_ft : &err_file;
  if (op == LIST_OP_FILE)
  {
    // Текст окна лежит в ОЗУ страницы банка: цифры правим на месте.
    char *s = (char*)err_file.wnd_txt;
    while (*s) ++s;
    s[-2] = '0' + code / 10;
    s[-1] = '0' + code % 10;
  }
  wc_api_u16(_PRWOW, (u16)window);
  wc_api__bool(_USPO);
  wc_api__bool(_NUSP);
  wc_api_u16(_RRESB, (u16)window);
}

void far_entry(LIST_SHARED *p)
{
  if (p->op == LIST_OP_PICK) list_run(p);
  else if (p->op == LIST_OP_MJPEG) p->chosen = buf_codec() != 0;
  else list_message(p->op, p->code);
}

// WC входит только в банк изображений (#8000); эти имена нужны шлюзам crt0.s.
void main() __naked
{
  __asm
    ret
  __endasm;
}

void main_dispatch()
{
}
