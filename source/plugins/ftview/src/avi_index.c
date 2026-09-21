// Быстрая перемотка AVI. Код исполняется в банке изображений по вызову
// видеобанка (far_call): страница видео почти заполнена.
//
// Таблица строится при первой перемотке, а не при открытии файла. Запись k
// относится к кадру F = k*step: это первый чанк idx1, начиная с которого есть
// и кадр F, и звук с сэмпла S = F*pcm_rate/fps. Хранятся абсолютное смещение
// чанка, число видеочанков и звуковых байтов до него. Таблица лежит в RAM_G
// над двумя кадрами и не пересекается ни с media FIFO, ни с кольцом FT812.
//
// Перемотка подаёт FT812 заголовок AVI до 'movi', выравнивающий JUNK и поток
// с найденного чанка. Видеобанк досчитывает кадры до цели без показа и
// отбрасывает лишние сэмплы.

#define AVI_INDEX 0xD0000UL
#define AVI_INDEX_MAX 5460

// Общие поля AVI. В видеобанке это его рабочие переменные (см. макросы в
// avi_controls.c); для far_call копия структуры кладётся в стек ядра, который
// виден обоим банкам.
typedef struct
{
  u8 op;              // AVI_OP_*
  u8 ok;
  u16 pcm_rate;
  u32 movi_start;     // позиция после FOURCC 'movi'
  u32 movi_end;       // конец LIST movi
  u32 total, rate, scale, bytes, pcm_total;
  u32 target;         // AVI_OP_SEEK: кадр назначения
  u32 seek_pos, seek_frame, seek_audio;
  u32 write;          // указатель записи media FIFO
  u32 period;         // avih: микросекунд на кадр
  u16 width, height;  // avih: размер кадра
  u8 ulaw;            // звук µ-law (WAVEFORMAT 7): только звуковой блок FT812
} AVI_SHARED;

#define AVI_OP_SEEK 1     // точка входа для target (нули — с начала файла);
                          // ok 2 — чтение idx1 сдвинуло позицию диска
#define AVI_OP_HEADER 2   // заголовок в FIFO, поток на seek_pos
#define AVI_OP_PROBE 3    // разбор заголовка: ok 1 — покадровый режим, 2 — сбой
// Копия полей для банка изображений: свободный хвост первой страницы буфера.
#define AVI_FAR ((AVI_SHARED*)0xFF00)

// Раскладка RAM_G: слово результата декодера над двумя кадрами, кольцо PCM
// FT812 с #C0000. Нужна и разбору заголовка в банке изображений.
#define AVI_RESULT 0xDFFFCUL
#define PCM_BASE 0xC0000UL

// Общие поля. В видеобанке — рабочие переменные плеера, в банке изображений —
// копия для разбора заголовка. Имена полей — через макросы.
AVI_SHARED avi;
#define avi_total avi.total
#define avi_rate avi.rate
#define avi_scale avi.scale
#define avi_bytes avi.bytes
#define avi_write avi.write
#define avi_pcm_rate avi.pcm_rate
#define avi_pcm_total avi.pcm_total
#define avi_movi_start avi.movi_start
#define avi_movi_end avi.movi_end
#define avi_seek_pos avi.seek_pos
#define avi_seek_frame avi.seek_frame
#define avi_seek_audio avi.seek_audio
#define avi_period avi.period
#define avi_width avi.width
#define avi_height avi.height
#define avi_ulaw avi.ulaw

#ifndef FTVIEW_VIDEO_BANK

// Состояние таблицы текущего файла: 0 — не строилась, 1 — есть, 2 — нет.
u8 index_state;
u16 index_step, index_count;

// Пропуск секторов от начала файла (сразу после wc_rewind, на границе
// кластера). LOADNON ядра на каждый кластер заново читает сектор FAT (CURIT
// без кэша): на файле 52 МБ с кластером 4 КиБ это 12 808 чтений SD, и первая
// перемотка в Unreal шла ~30 с. Поэтому цепочку проходит сам плагин. CURIT
// (#44A5, вход для внешних плагинов) читает сектор FAT в SECBU один раз на
// 128 кластеров, следующие записи берутся из SECBU (#3000) напрямую: страница
// WildDOS стоит в окне #0000, пока работает плагин (#6000 = #600B). Поток на
// итоговый кластер ставит GIPAG (#44D7), остаток кластера дочитывается
// LOAD512. От LOADNON пропуск не зависит: до исправления ядра 2026-09-21 он
// проходил ~81 блок за вызов вместо B.
#define WD_SECBU  0x3000
#define WD_BSECPC 0x3894
#define WD_CUHL   0x38A8
u32 fw_cluster, fw_count;
u8 fw_base[4], fw_rest;

// fw_count — секторы от начала текущего кластера потока (CUHL/CUDE). Делит
// их на BSECPC (степень двойки): остаток — в fw_rest, целые кластеры
// проходит по цепочке и ставит поток на итоговый кластер (GIPAG). fw_base —
// кластер без младших 7 бит, чей сектор FAT сейчас в SECBU. Возврат 1; 0 —
// CURIT не прочитал FAT, ссылка не кластер (0, 1, повреждённый, конец
// цепочки раньше срока) или GIPAG не встал. Деление здесь, а не в C: SDCC 4.3
// проверял результат переменного сдвига через IY, заданный лишь в теле цикла.
bool fat_walk() __naked
{
  __asm
    push ix
    push iy
    ld a, (0x3894)
    ld c, a
    dec a
    ld b, a
    ld a, (_fw_count)
    and b
    ld (_fw_rest), a
    ld hl, (_fw_count)
    ld de, (_fw_count + 2)
00010$:
    srl c
    jr c, 00011$
    srl d
    rr e
    rr h
    rr l
    jr 00010$
00011$:
    ld (_fw_count), hl
    ld (_fw_count + 2), de
    ld a, h
    or l
    or d
    or e
    jp z, 00008$
    ld hl, (0x38A8)
    ld de, (0x38AA)
00001$:
    ld a, l
    and #0x80
    ld (_fw_base), a
    ld a, h
    ld (_fw_base + 1), a
    ld (_fw_base + 2), de
    call 0x44A5
    jp c, 00009$
00002$:
    ld c, (hl)
    inc hl
    ld b, (hl)
    inc hl
    ld e, (hl)
    inc hl
    ld a, (hl)
    and #0x0F
    ld d, a
    or e
    jr nz, 00003$
    ld a, b
    or a
    jr nz, 00004$
    ld a, c
    cp #2
    jp c, 00009$
    jr 00004$
00003$:
    ld a, d
    cp #0x0F
    jr nz, 00004$
    ld a, e
    and b
    inc a
    jr nz, 00004$
    ld a, c
    cp #0xF7
    jp nc, 00009$
00004$:
    ld (_fw_cluster), bc
    ld (_fw_cluster + 2), de
    ld hl, (_fw_count)
    ld a, h
    or l
    jr nz, 00005$
    ld hl, (_fw_count + 2)
    dec hl
    ld (_fw_count + 2), hl
    ld hl, #0
00005$:
    dec hl
    ld (_fw_count), hl
    ld a, h
    or l
    jr nz, 00006$
    ld hl, (_fw_count + 2)
    ld a, h
    or l
    jr z, 00012$
00006$:
    ld a, c
    and #0x80
    ld hl, #_fw_base
    cp (hl)
    jr nz, 00007$
    inc hl
    ld a, b
    cp (hl)
    jr nz, 00007$
    inc hl
    ld a, e
    cp (hl)
    jr nz, 00007$
    inc hl
    ld a, d
    cp (hl)
    jr nz, 00007$
    ld a, c
    and #0x7F
    ld l, a
    ld h, #0
    add hl, hl
    add hl, hl
    ld a, h
    add a, #0x30
    ld h, a
    jp 00002$
00007$:
    ld l, c
    ld h, b
    jp 00001$
00012$:
    ld hl, #_fw_cluster
    call 0x44D7
    jr nz, 00009$
00008$:
    pop iy
    pop ix
    ld a, #1
    ret
00009$:
    pop iy
    pop ix
    xor a
    ret
  __endasm;
}

bool disk_skip(u32 sectors)
{
  u8 spc = *(u8*)WD_BSECPC, n;
  if (*(u8*)0x6000 != *(u8*)0x600B || !spc || (spc & (spc - 1)))
  {
    // WildDOS не в окне #0000: прежний пропуск через API.
    while (sectors)
    {
      n = sectors > 255 ? 255 : sectors;
      if (!wc_skip512(n)) { view_failed = 1; return false; }
      sectors -= n;
    }
    return true;
  }
  fw_count = sectors;
  if (!fat_walk()) { view_failed = 1; return false; }
  while (fw_rest)
  {
    n = fw_rest > 31 ? 31 : fw_rest;
    if (wc_load512(fs_buf, n) != 0xC000 + ((u16)n << 9))
    { view_failed = 1; return false; }
    fw_rest -= n;
  }
  return true;
}

// Установить побайтовое чтение header_byte() на абсолютное смещение pos:
// начало файла, пропуск целых секторов, затем хвост сектора по байту.
u8 disk_moved;
bool file_seek(u32 pos)
{
  u16 skip = pos & 511;
  disk_moved = 1;
  if (!wc_rewind() || !disk_skip(pos >> 9)) return false;
  header_left = filesize - (pos & ~511UL);
  header_pos = header_size = 0;
  while (skip--) header_byte();
  return !view_failed;
}

// 16 байтов записи idx1: указатель в fs_buf или, на границе чтения, копия.
u8 idx_tmp[16];
u8 *idx_entry()
{
  u8 i;
  if (header_size - header_pos >= 16)
  {
    header_pos += 16;
    return fs_buf + header_pos - 16;
  }
  for (i = 0; i < 16; ++i) idx_tmp[i] = header_byte();
  return idx_tmp;
}

// Рабочие переменные построения — статические: стек ядра WC у плагина
// неглубокий, а здесь он глубже всего (перемотка -> чтение idx1 -> пропуск
// секторов в ядре). ib_exit — шаг, на котором построение остановилось
// (0 — таблица есть): после отказа его видно в памяти страницы.
u32 ib_pos, ib_size, ib_n, ib_frame, ib_sample, ib_video, ib_audio, ib_base;
u32 ib_entry[3], ib_sample_step, ib_pcm_total, ib_off, ib_len;
u16 ib_k, ib_count, ib_step, ib_rem, ib_sample_rem, ib_fps;
u8 ib_tries, ib_exit;
void index_build(AVI_SHARED *p)
{
  ib_frame = ib_sample = ib_video = ib_audio = ib_base = ib_sample_step = 0;
  ib_k = ib_rem = ib_sample_rem = 0;
  ib_fps = p->rate;
  index_state = 2;
  ib_exit = 1;
  // Кадры над таблицей; заголовок до 'movi' повторно подаётся в FIFO и
  // ограничен 64 КиБ; для звука нужна целая частота кадров.
  if (p->bytes > AVI_INDEX / 2 || p->movi_start > 0x10000UL ||
      (p->pcm_rate && (p->scale != 1 || !ib_fps))) return;
  ib_pcm_total = p->pcm_rate ? p->pcm_total : 0;
  // idx1 обычно сразу за LIST movi; допускаем несколько чанков JUNK.
  ib_pos = p->movi_end + (p->movi_end & 1);
  ib_exit = 2;
  for (ib_tries = 0;; ++ib_tries)
  {
    if (ib_tries == 8 || ib_pos + 8 > filesize || !file_seek(ib_pos)) return;
    ib_n = avi_word();
    ib_size = avi_word();
    if (ib_n == 0x31786469UL) break; // idx1
    ib_pos += 8 + ib_size + (ib_size & 1);
  }
  ib_exit = 3;
  if (ib_size > filesize - ib_pos - 8) return;
  ib_exit = 4;
  ib_n = ib_size >> 4;
  ib_step = p->total / AVI_INDEX_MAX + 1;
  ib_count = (p->total + ib_step - 1) / ib_step;
  if (ib_pcm_total)
  {
    // S(k+1) = S(k) + step*pcm_rate/fps с остатком: без деления на каждую
    // запись и с тем же округлением вниз, что pcm_sample() видеобанка.
    ib_sample_step = (u32)ib_step * p->pcm_rate;
    ib_sample_rem = ib_sample_step % ib_fps;
    ib_sample_step /= ib_fps;
  }
  while (ib_n-- && ib_k < ib_count)
  {
    u8 *e = idx_entry();
    bool is_video, is_audio;
    if (view_failed || *(volatile u8*)_ABT) return;
    memcpy(&ib_off, e + 8, 4);
    memcpy(&ib_len, e + 12, 4);
    // Смещения idx1 бывают от FOURCC 'movi' (так пишет ffmpeg) и абсолютные.
    if (!ib_video && !ib_audio && !ib_k)
      ib_base = ib_off < p->movi_start ? p->movi_start - 4 : 0;
    is_video = e[0] == '0' && e[1] == '0' && e[2] == 'd' && (e[3] == 'c' || e[3] == 'b');
    is_audio = ib_pcm_total && !memcmp(e, "01wb", 4);
    while (ib_k < ib_count && ((is_video && ib_video >= ib_frame) ||
                               (is_audio && ib_audio + ib_len > ib_sample)))
    {
      ib_entry[0] = ib_base + ib_off;
      ib_entry[1] = ib_video;
      ib_entry[2] = ib_audio;
      ft_write(ib_entry, AVI_INDEX + (u32)ib_k * 12, 12);
      ++ib_k;
      ib_frame += ib_step;
      ib_sample += ib_sample_step;
      ib_rem += ib_sample_rem;
      if (ib_rem >= ib_fps) { ib_rem -= ib_fps; ++ib_sample; }
    }
    if (is_video) ++ib_video;
    if (is_audio) ib_audio += ib_len;
  }
  // Кадры за обрезанным idx1 перематываются от последней записи.
  ib_exit = 5;
  if (!ib_k) return;
  index_count = ib_k;
  index_step = ib_step;
  index_state = 1;
  ib_exit = 0;
}

// Точка входа для p->target. Испорченная запись не должна увести поток за
// пределы movi; тогда, как и без таблицы, возвращаются нули.
u32 is_e[3];
void index_seek(AVI_SHARED *p)
{
  u32 *e = is_e;
  u16 k;
  p->seek_pos = p->seek_frame = p->seek_audio = 0;
  // Переходу в начало таблица не нужна, а её построение проходит весь файл.
  if (!p->target) return;
  disk_moved = 0;
  if (!index_state) index_build(p);
  if (disk_moved) p->ok = 2;
  if (index_state != 1) return;
  k = p->target / index_step;
  if (k >= index_count) k = index_count - 1;
  ft_read(e, AVI_INDEX + (u32)k * 12, 12);
  if (e[0] > p->movi_start && e[0] < p->movi_end && !(e[0] & 1) && e[1] <= p->target)
  {
    p->seek_pos = e[0];
    p->seek_frame = e[1];
    p->seek_audio = e[2];
  }
}

// Заголовок AVI до FOURCC 'movi' включительно и выравнивающий чанк JUNK.
// За ними в FIFO идёт файл с base = seek_pos & ~3, так что CMD_VIDEOSTART и
// CMD_VIDEOFRAME видят непрерывный поток чанков; байты base..seek_pos
// становятся хвостом JUNK. DMA передаёт длины, кратные четырём: смещения
// чанков AVI и сам заголовок чётны, поэтому заполнитель — 0 или 2 байта.
// На выходе диск стоит на секторе base: видеобанк читает дальше сам.
bool index_header(AVI_SHARED *p)
{
  u32 left = p->movi_start;
  u16 count;
  wc_map_buffer(1);
  if (!wc_rewind()) return false;
  while (left)
  {
    count = min(left, FS_BUF_SIZE);
    if (!read_chunk(left)) return false;
    left -= count;
    if (!left)
    {
      u8 fill = -(u8)(p->movi_start + 8) & 3;
      memcpy(fs_buf + count, "JUNK\0\0\0\0\0\0", 10);
      fs_buf[count + 4] = fill + (p->seek_pos & 3);
      count += 8 + fill;
    }
    ft_load_ram_dma(fs_buf, *(u8*)_PAGE3, 0xE0000UL + p->write, count);
    p->write += count;
  }
  ft_wreg32(REG_MEDIAFIFO_WRITE, p->write);
  // Пропуск идёт от начала файла: проход цепочки начинается с границы
  // кластера, а заголовок мог закончиться посреди кластера.
  return wc_rewind() && disk_skip(p->seek_pos >> 9);
}

u32 avi_position()
{
  return filesize - header_left - header_size + header_pos;
}

// Обходим реальные границы LIST/чанков. Не ищем строки avih/strh внутри
// данных изображения или JUNK. Глубина вложения ограничена рабочим стеком.
// Разбор выполняется один раз на файл, поэтому живёт в банке изображений.
bool avi_probe()
{
  u32 ends[4], pos, id, size, end;
  u8 depth = 0, video = 0, sound = 0, stream = 0, kind = 0, pcm_ok = 0, gs;
  header_left = filesize; header_pos = header_size = 0;
  avi_period = avi_total = 0;
  avi_scale = avi_rate = 0;
  avi_width = avi_height = 0;
  avi_pcm_rate = 0; avi_pcm_total = 0; avi_ulaw = 0;
  if (avi_word() != 0x46464952UL) return false; // RIFF
  size = avi_word();
  if (filesize < 12 || size < 4 || size > filesize - 8 ||
      avi_word() != 0x20495641UL) return false; // AVI
  ends[0] = size + 8;
  for (;;)
  {
    pos = avi_position();
    while (pos == ends[depth] && depth) --depth;
    if (view_failed || pos > ends[depth] || ends[depth] - pos < 8) return false;
    id = avi_word(); size = avi_word(); pos += 8;
    if (size > ends[depth] - pos) return false;
    end = pos + size;
    if (id == 0x5453494CUL) // LIST
    {
      if (size < 4) return false;
      id = avi_word();
      if (id == 0x69766F6DUL)
      { avi_movi_start = avi_position(); avi_movi_end = end; break; } // movi
      if (id == 0x6C726468UL || id == 0x6C727473UL) // hdrl / strl
      {
        if (id == 0x6C727473UL) { ++stream; kind = 0; }
        if (depth == 3 || (end & 1)) return false;
        ends[++depth] = end;
        continue;
      }
    }
    else if (id == 0x68697661UL && size >= 40) // avih
    {
      u8 field;
      for (field = 0; field < 10; ++field)
      {
        u32 value = avi_word();
        if (field == 0) avi_period = value;
        if (field == 4) avi_total = value;
        if (field == 8) { if (value > 2047) return false; avi_width = value; }
        if (field == 9) { if (value > 2047) return false; avi_height = value; }
      }
    }
    else if (id == 0x68727473UL && size >= 28) // strh
    {
      id = avi_word();
      if (id == 0x73646976UL && avi_word() == 0x47504A4DUL) // vids/MJPG
      {
        if (stream != 1) return false;
        video = 1;
        avi_word(); avi_word(); avi_word();
        avi_scale = avi_word(); avi_rate = avi_word();
      }
      if (id == 0x73647561UL) // auds
      {
        sound = 1; kind = 1;
        if (stream != 2 || size < 36) return false;
        avi_word(); avi_word(); avi_word(); avi_word(); // handler/flags/priority/initial
        if (avi_word() != 1) return false; // scale: один PCM8-сэмпл
        id = avi_word();
        if (!id || id > 48000) return false;
        avi_pcm_rate = id;
        if (avi_word()) return false; // общая нулевая временная шкала
        avi_pcm_total = avi_word();
      }
    }
    else if (id == 0x66727473UL && kind && size >= 16) // audio strf/WAVEFORMAT
    {
      // PCM (1) — беззнаковые 8 бит; µ-law (7) — родной формат звукового
      // блока FT812 с большим динамическим диапазоном: байты идут в FT812
      // без пересчёта. Оба — моно, 8 бит, байт на сэмпл.
      id = avi_word();
      if ((id == 0x00010001UL || id == 0x00010007UL) && avi_word() == avi_pcm_rate &&
          avi_word() == avi_pcm_rate && avi_word() == 0x00080001UL)
      { pcm_ok = 1; avi_ulaw = id == 0x00010007UL; }
    }
    end += size & 1;
    if (end > ends[depth]) return false;
    while (avi_position() < end && !view_failed) header_byte();
  }
  avi_bytes = ((u32)avi_width * avi_height * 2 + 3) & 0xFFFFFFFCUL;
  // Звук пойдёт на GS, если драйвер загружен, а частота не выше частоты его
  // прерываний: шаг фазы должен уместиться в 16 бит (то же решает видеобанк).
  gs = gs_loaded && avi_pcm_rate && avi_pcm_rate <= GS_INT_HZ && !avi_ulaw;
  // Два RGB565-кадра, слово результата и 128 КиБ media FIFO не пересекаются.
  // Кольцо FT812 лежит в RAM_G с #C0000; GS его не требует.
  if (sound && (!pcm_ok || !avi_pcm_total || avi_scale != 1 ||
                !avi_rate || avi_rate > 1000 ||
                avi_bytes > (gs ? AVI_RESULT : PCM_BASE) / 2))
  { avi_pcm_rate = 0; return false; }
  return !view_failed && video && avi_width && avi_height &&
         avi_total && avi_period >= 1000 && avi_period <= 10000000UL &&
         avi_bytes <= AVI_RESULT / 2;
}

void far_entry(AVI_SHARED *p)
{
  view_failed = 0;
  if (p->op == AVI_OP_SEEK) index_seek(p);
  else if (p->op == AVI_OP_HEADER) p->ok = index_header(p) && !view_failed;
  else if (p->op == AVI_OP_PROBE)
  {
    avi = *p;
    avi.ok = avi_probe();
    if (view_failed) avi.ok = 2;
    *p = avi;
  }
}

#else

void far_entry(AVI_SHARED *p)
{
  p;
}

#endif
