// Покадровый режим MJPEG AVI: без звука, с PCM8 или µ-law mono. CMD_PLAYVIDEO сам
// строит дисплей-лист, поэтому поверх него нельзя надёжно дорисовать полосу.
// Здесь CMD_VIDEOFRAME декодирует в один из двух буферов, а плагин рисует кадр
// и HUD. Звук PCM8 выводит General Sound, без него — FT812; µ-law — всегда
// звуковой блок FT812, это его родной формат (avi_pcm.c).
// Неподдержанный звук остаётся у штатного CMD_PLAYVIDEO: этот режим не должен
// молча выключать звук. Проверка возможности управления выполняется до старта.

#define AVI_FIFO 0xE0000UL
#define AVI_FIFO_SIZE 0x20000UL
// Поля, нужные банку изображений (разбор заголовка и перемотка), собраны в
// структуру avi (avi_index.c): её копия передаётся через стек ядра (avi_far).
u32 avi_frame;
u32 avi_left;
u8 avi_paused, avi_keys;

// Клавиши WC обновляет в прерывании (50 Гц), а эмулятор и пользователь держат
// их считанные кадры. Опрос — раз в тик WC, в главном цикле и внутри долгих
// ожиданий (декодирование, подкачка): нажатия копятся в avi_edges, пока их не
// обработает главный цикл. Биты: Space, Left, Right, Home, PgDn, PgUp.
u8 avi_edges, key_tick;
void avi_keys_poll()
{
  u8 keys = 0;
  if (*(volatile u8*)_TMN == key_tick) return;
  key_tick = *(volatile u8*)_TMN;
  if (wc_api__bool(_SPKE)) keys |= 1;
  if (wc_api__bool(_LFFF)) keys |= 2;
  if (wc_api__bool(_RGGG)) keys |= 4;
  if (wc_api__bool(_HOME)) keys |= 8;
  if (wc_api__bool(_PGD)) keys |= 16;
  if (wc_api__bool(_PGU)) keys |= 32;
  avi_edges |= keys & ~avi_keys;
  avi_keys = keys;
}

#include "avi_pcm.c"

// Восемь страниц EVO резервируются заголовком WMF. В каждой используем
// 31 сектор: чтение целых 16 КиБ вернуло бы HL=0000, неотличимый от ошибки
// старой обёртки LOAD512. Кольцо вмещает 126976 байт (~0,33 с данного AVI).
#define AVI_CACHE_BYTES 0x3E00
u32 avi_disk_left;
u16 avi_cache_pos;
u8 avi_cache_head, avi_cache_tail, avi_cache_count;
// Диагностика стенда: число наблюдений пустого media FIFO после начала
// подачи и до конца файла. Насыщение исключает ложный ноль после переполнения.
u16 avi_empty_polls;
u8 avi_feed_started;
// Минимум данных, оставшихся в FT812 именно после блокирующего чтения SD.
// Обычный опрос мог пропустить провал, если сразу после чтения шла DMA.
u32 avi_min_after_read;

bool avi_cache_fill()
{
  u16 count;
  u8 sectors;
  if (!avi_disk_left || avi_cache_count == 8) return true;
  count = min(avi_disk_left, AVI_CACHE_BYTES);
  sectors = (count + 511) >> 9;
  wc_map_buffer(avi_cache_tail);
  if (*(volatile u8*)_ABT ||
      wc_load512(fs_buf, sectors) != 0xC000 + ((u16)sectors << 9))
  { view_failed = 1; return false; }
  if (avi_feed_started)
  {
    u32 queued = (avi_write - ft_rreg32(REG_MEDIAFIFO_READ)) & (AVI_FIFO_SIZE - 1);
    if (queued < avi_min_after_read) avi_min_after_read = queued;
  }
  avi_disk_left -= count;
  if (++avi_cache_tail == 9) avi_cache_tail = 1;
  ++avi_cache_count;
  return true;
}

// Одно продвижение media FIFO. false без view_failed означает, что FIFO
// уже полон: эту паузу используем для чтения следующей страницы с SD.
// Тот же примитив позволяет заранее наполнить FIFO до старта PCM.
bool avi_feed()
{
  u16 count, padded;
  u32 read, free;
  // Курсор FT812 оборачивается каждые 32 КиБ: его опрашиваем часто. Позиция
  // GS не накапливается (записано минус очередь), её нужно освежить лишь у
  // предела очереди: запрос к GS стоит нескольких обменов.
  if (avi_pcm_rate && !pcm_gs) pcm_poll();
  if (view_failed || !avi_left) return false;
  // У малосжатого звука при крошечных JPEG media FIFO вмещает несколько
  // секунд PCM. Не переполняем звуковое кольцо во время начального prefill.
  if (avi_pcm_rate && pcm_written - pcm_played >= 24576UL)
  {
    if (pcm_gs) pcm_poll();
    if (pcm_written - pcm_played >= 24576UL) return false;
  }
  count = min(avi_left, min(FS_BUF_SIZE, AVI_CACHE_BYTES - avi_cache_pos));
  read = ft_rreg32(REG_MEDIAFIFO_READ);
  free = (read - avi_write - 4) & (AVI_FIFO_SIZE - 1);
  if (avi_feed_started && read == avi_write && avi_empty_polls != 0xFFFF)
    ++avi_empty_polls;
  if (!avi_cache_count && !avi_cache_fill()) return false;
  if (count > AVI_FIFO_SIZE - avi_write) count = AVI_FIFO_SIZE - avi_write;
  padded = (count + 3) & 0xFFFC;
  if (free < padded) { avi_cache_fill(); return false; }
  {
    // volatile необходим для SDCC 4.3: вычисление адреса DMA иначе может
    // переиспользовать IY с указателем data. Проверяем реальные байты DMA.
    u8 * volatile data;
    u16 tail = count;
    wc_map_buffer(avi_cache_head);
    data = fs_buf + avi_cache_pos;
    // Звук FT812 идёт тем же SPI и временно меняет байты блока: только до DMA.
    if (avi_pcm_rate && !pcm_gs && !pcm_tee(data, count, filesize - avi_left)) return false;
    while (tail < padded) data[tail++] = 0;
    if (avi_pcm_rate && pcm_gs)
    {
      // GS: DMA блока в media FIFO идёт, пока процессор разбирает тот же
      // блок и отдаёт звук в GS. Ожидание GS прячется за передачей SPI;
      // блок при этом не меняется. Блок не пересекает страницу (<= 4 КиБ).
      bool ok;
      ts_set_dma_saddr_p((u16)data & 0x3FFF, *(u8*)_PAGE3);
      ft_start_write(AVI_FIFO + avi_write);
      if (padded >> 9) { ts_set_dma_size(512, padded >> 9); ts_dma_start(TS_DMA_RAM_SPI); }
      ok = pcm_tee(data, count, filesize - avi_left);
      ts_dma_wait();
      if (padded & 0x1FF)
      { ts_set_dma_size(padded & 0x1FF, 1); ts_dma_start(TS_DMA_RAM_SPI); ts_dma_wait(); }
      ft_spi_unsel();
      if (!ok) return false;
    }
    else ft_load_ram_dma(data, *(u8*)_PAGE3, AVI_FIFO + avi_write, padded);
  }
  avi_write = (avi_write + padded) & (AVI_FIFO_SIZE - 1);
  ft_wreg32(REG_MEDIAFIFO_WRITE, avi_write);
  avi_feed_started = 1;
  avi_left -= count;
  avi_cache_pos += count;
  if (avi_cache_pos == AVI_CACHE_BYTES)
  {
    avi_cache_pos = 0;
    if (++avi_cache_head == 9) avi_cache_head = 1;
    --avi_cache_count;
  }
  return true;
}

bool avi_prime()
{
  while (avi_feed())
  {
    avi_keys_poll();
    if (*(volatile u8*)_ABT) return false;
  }
  return !view_failed;
}

// Пустая очередь команд без DISPLAY-барьера не означает конец VIDEOFRAME.
// Поддерживаем оба потребителя, сохраняя ограничение таймера на зависший FT812.
bool avi_decode_wait()
{
  u8 tick = *(volatile u8*)_TMN;
  u16 polls = 0xFFFF;
  do
  {
    u16 cmd = ft_rreg16(FT_REG_CMDB_SPACE);
    avi_keys_poll();
    if (*(volatile u8*)_ABT || (cmd & 3) || view_failed) break;
    if (cmd == 0xFFC) return true;
    if (avi_feed()) { tick = *(volatile u8*)_TMN; polls = 0xFFFF; }
  } while (--polls && (u8)(*(volatile u8*)_TMN - tick) < 150);
  view_failed = 1;
  ft_cp_reset();
  return false;
}

// Декодировать следующий видеокадр потока в RGB565 по адресу dst. DISPLAY
// за VIDEOFRAME — барьер конца декодирования (см. avi_decode_wait).
bool avi_decode(u32 dst)
{
  ft_ccmd_start(cmdl); ft_VideoFrame(dst, AVI_RESULT); ft_Display();
  return fifo_flush() && avi_decode_wait();
}

// 1 — кадр avi_frame уже декодирован наперёд в задний буфер (avi_controls).
u8 avi_ahead;

// Операция банка изображений (avi_index.c) над копией общих полей. Копия
// лежит в хвосте первой страницы буфера (AVI_FAR, #FF00): окно #C000 не
// меняется вместе со страницей #8000, банк изображений читает файл в эту же
// страницу (не дальше #CFFF), а кэш занимает в странице 31 сектор
// (#C000..#FDFF) и перед каждым обращением сам выбирает страницу. Стек ядра
// WC у плагина неглубокий (ниже — буферы WC), копия на нём занимала 60 байт.
bool avi_far(u8 op)
{
  avi.op = op;
  avi.ok = 1;
  wc_map_buffer(1);
  *AVI_FAR = avi;
  far_call(AVI_FAR);
  wc_map_buffer(1);
  avi = *AVI_FAR;
  return avi.ok;
}

// avi_seek_pos != 0: поток продолжается с чанка перемотки после заголовка.
bool avi_restart(bool native)
{
  u32 base = avi_seek_pos & ~3UL;
  if (avi_pcm_rate) pcm_reset();
  ft_cp_reset();
  avi_ahead = 0;
  avi_write = 0; avi_frame = avi_seek_frame;
  avi_empty_polls = 0; avi_feed_started = 0;
  avi_min_after_read = AVI_FIFO_SIZE;
  ft_ccmd_start(cmdl);
  ft_MediaFifo(AVI_FIFO, AVI_FIFO_SIZE);
  if (!fifo_flush() || !fifo_wait(0xFFC)) return false;
  // Заголовок, JUNK и позицию диска готовит банк изображений; без
  // перемотки поток просто открывается заново с начала файла.
  if (base ? !avi_far(AVI_OP_HEADER) : !wc_rewind()) { view_failed = 1; return false; }
  avi_left = filesize - base;
  avi_disk_left = filesize - (base & ~511UL); avi_cache_pos = base & 511;
  avi_cache_head = avi_cache_tail = 1; avi_cache_count = 0;
  // Небольшая задержка перед стартом: заполняем собственный RAM-буфер EVO.
  while (avi_disk_left && avi_cache_count != 8)
    if (!avi_cache_fill()) return false;
  if (native) ft_PlayVideo(OPT_FULLSCREEN | OPT_SOUND | OPT_NOTEAR | OPT_MEDIAFIFO);
  else ft_VideoStart();
  // PLAYVIDEO забирает свои параметры из командного FIFO до конца видео.
  // Поэтому CMDB_SPACE=FFC без следующей команды ещё не означает завершение!
  // DISPLAY остаётся за декодером в очереди и служит барьером. SWAP здесь нет:
  // этот дополнительный DISPLAY сам по себе не меняет показанный кадр.
  ft_Display();
  return fifo_flush() && avi_decode_wait();
}

// Время берём из номера кадра и рациональной частоты strh. Деление на
// целую/дробную части исключает переполнение frame*scale. Для необычных
// больших scale/rate остаётся миллисекундная оценка из avih. Частый случай —
// целая частота и кадр < 65536: 16-битное деление SDCC в десятки раз дешевле
// библиотечного 32-битного (~10 000 тактов), а HUD рисуется на каждом кадре.
u16 avi_seconds(u32 frame)
{
  if (avi_scale == 1 && frame < 0x10000UL && avi_rate < 0x10000UL)
    return (u16)frame / (u16)avi_rate;
  if (avi_scale && avi_rate && avi_scale <= 65535 && avi_rate <= 65535)
    return (frame / avi_rate) * avi_scale + (frame % avi_rate) * avi_scale / avi_rate;
  return frame * (avi_period / 1000) / 1000;
}

void avi_time(u16 x, u16 seconds)
{
  ft_Number(x, 730, 26, FT_OPT_RIGHTX, seconds / 60);
  ft_Text(x, 730, 26, 0, ":");
  ft_Number(x + 9, 730, 26, 2, seconds % 60);
}

// Постоянная часть HUD вычисляется один раз на файл: размер и масштаб
// картинки, шаг полосы и полное время.
u16 hud_w, hud_h, hud_bar, hud_total;
u32 hud_ta, hud_te, hud_unit;
u8 hud_state;   // шаблон построен для avi_paused+1; 0 — не построен
void avi_hud_init()
{
  // Сначала выбираем ограничивающую сторону в 32 битах. Промежуточная
  // высота узкого кадра могла переполнить u16; округлённая ширина 0 затем
  // приводила к делению на ноль при расчёте матрицы. Минимум — один пиксель.
  if ((u32)avi_height * 1024 > (u32)avi_width * 700)
  {
    hud_h = 700; hud_w = (u32)avi_width * 700 / avi_height;
    if (!hud_w) hud_w = 1;
  }
  else
  {
    hud_w = 1024; hud_h = (u32)avi_height * 1024 / avi_width;
    if (!hud_h) hud_h = 1;
  }
  hud_ta = (u32)avi_width * 256 / hud_w;
  hud_te = (u32)avi_height * 256 / hud_h;
  hud_unit = avi_total / 1000 + 1;
  hud_bar = avi_total / hud_unit;
  hud_total = avi_seconds(avi_total);
  hud_state = 0;
}

// Команды кадра с HUD собираются один раз (и при смене паузы) шаблоном. На
// кадр меняются четыре слова: адрес картинки, положение полосы, минуты и
// секунды. Раньше каждый кадр заново строил ~60 слов вызовами SDK — около
// 47 000 тактов. Шаблон (до 292 байт со строкой звукового устройства) лежит
// в свободном хвосте кода видеобанка: область DATA до #BF80 занята. Код не
// заходит на этот адрес — проверяет build.py, длину шаблона — тест.
__at (0xBBD0) u32 hud_cmd[76];
#define HUD_CMD hud_cmd
u16 hud_len, hud_i_addr, hud_i_prog, hud_i_min, hud_i_sec;
void avi_hud_build()
{
  ft_ccmd_start(HUD_CMD);
  ft_Dlstart(); ft_Clear(1, 1, 1);
  hud_i_addr = ft_ccmdp + 1;
  ft_SetBitmap(0, FT_RGB565, avi_width, avi_height);
  ft_BitmapSize(FT_NEAREST, FT_BORDER, FT_BORDER, hud_w, hud_h);
  ft_BitmapTransformA(hud_ta);
  ft_BitmapTransformE(hud_te);
  ft_Begin(FT_BITMAPS);
  ft_Vertex2ii((1024 - hud_w) / 2, (700 - hud_h) / 2, 0, 0);
  // Виджеты/шрифт не должны наследовать матрицу масштабирования видео.
  ft_BitmapTransformA(256); ft_BitmapTransformE(256);
  ft_ColorRGB(255, 255, 255);
  hud_i_prog = ft_ccmdp + 3;
  ft_Progress(24, 708, 976, 12, FT_OPT_FLAT, 0, hud_bar);
  hud_i_min = ft_ccmdp + 3;
  ft_Number(80, 730, 26, FT_OPT_RIGHTX, 0);
  ft_Text(80, 730, 26, 0, ":");
  hud_i_sec = ft_ccmdp + 3;
  ft_Number(89, 730, 26, 2, 0);
  avi_time(980, hud_total);
  // Куда идёт звук. PCM8 без GS — номер этапа, на котором не загрузился
  // его драйвер (gs_stage: 1 — карты нет, 2..5 — ответ ПЗУ или драйвера).
  // Файл с µ-law сделан для FT812: «FT812 ulaw».
  if (avi_pcm_rate)
  {
    ft_Text(988, 748, 26, FT_OPT_RIGHTX,
            pcm_gs ? "GS" : avi_ulaw ? "FT812 ulaw" : "FT812 GS");
    if (!pcm_gs && !avi_ulaw) ft_Number(992, 748, 26, 0, ft_state >> 2 & 7);
  }
  ft_Text(512, 730, 26, FT_OPT_CENTERX,
          avi_paused ? "Paused: Space play | Left/Right seek | Esc exit" :
                       "Space pause | Left/Right seek | Home restart | Esc exit");
  ft_Display(); ft_ccmd(FT_CCMD_SWAP);
  hud_len = ft_ccmdp << 2;
  hud_state = avi_paused + 1;
}

// Время и полоса на соседний кадр — приращениями, без четырёх делений на
// кадр: счётчик кадров в секунде, секунды в минуте, кадры в делении полосы.
// После прыжка номера кадра, при дробной или нулевой (время по avih)
// частоте — полный расчёт.
u32 hud_frame;
u16 hud_sub, hud_min, hud_s60, hud_prog, hud_psub;
bool avi_draw(u32 address)
{
  u32 *c = HUD_CMD;
  if (hud_state != avi_paused + 1) avi_hud_build();
  if (avi_frame != hud_frame)
  {
    if (avi_frame == hud_frame + 1 && avi_scale == 1 && avi_rate &&
        avi_rate < 0x10000UL && hud_unit < 0x10000UL)
    {
      if (++hud_sub == (u16)avi_rate)
      {
        hud_sub = 0;
        if (++hud_s60 == 60) { hud_s60 = 0; ++hud_min; }
      }
      if (++hud_psub == (u16)hud_unit) { hud_psub = 0; ++hud_prog; }
    }
    else
    {
      u16 s = avi_seconds(avi_frame);
      hud_min = s / 60; hud_s60 = s % 60;
      hud_sub = avi_rate ? avi_frame % avi_rate : 0;
      hud_prog = avi_frame / hud_unit; hud_psub = avi_frame % hud_unit;
    }
    hud_frame = avi_frame;
  }
  c[hud_i_addr] = address;
  ((u16*)&c[hud_i_prog])[1] = hud_prog;
  c[hud_i_min] = hud_min;
  c[hud_i_sec] = hud_s60;
  return fifo_send((u8*)c, hud_len) && fifo_wait(0xFFC);
}

// Сэмпл, с которого пора показывать кадр avi_frame, то есть pcm_sample(), но
// приращениями: цикл спрашивает его много раз на кадр, а pcm_sample() стоит
// трёх 32-битных делений. Полный расчёт — только при прыжке номера кадра.
u32 due_frame, due_sample;
u16 due_acc, due_q, due_r;
// Позиция GS стоит нескольких обменов с картой, а нужна лишь у отметки
// кадра. За тик WC звук продвигается не больше чем на pcm_tick сэмплов
// (с запасом на 40 Гц): пока до отметки дальше, хватает опроса раз в тик.
// Ближе — ждём половину остатка по тактам Z80 (14 МГц, pcm_unit итераций
// цикла по 26 тактов на сэмпл) и спрашиваем снова: прерывания и медленная
// память лишь удлиняют ожидание, а половина остатка не даёт опоздать.
u16 pcm_tick, pcm_unit;
u8 poll_tick;

void delay26(u16 n) __naked
{
  n;
  __asm
00001$:
    dec hl
    ld a, h
    or l
    jr nz, 00001$
    ret
  __endasm;
}
u32 avi_due()
{
  if (avi_frame != due_frame)
  {
    if (avi_frame == due_frame + 1)
    {
      due_sample += due_q;
      due_acc += due_r;
      if (due_acc >= (u16)avi_rate) { due_acc -= (u16)avi_rate; ++due_sample; }
    }
    else
    {
      due_q = avi_pcm_rate / (u16)avi_rate;
      due_r = avi_pcm_rate % (u16)avi_rate;
      due_sample = pcm_sample(avi_frame);
      due_acc = (u32)(avi_frame % avi_rate) * due_r % avi_rate;
    }
    due_frame = avi_frame;
  }
  return due_sample;
}

// Перейти к кадру target: с ближайшей записи таблицы idx1 (первая перемотка
// её строит) или, без неё, с начала файла. Кадры до target декодируются без
// показа, звук до него отбрасывается. Без звука и без точки входа вперёд
// просто досчитываем кадры.
u8 index_asked;
bool avi_seek(u32 target)
{
  if (avi_pcm_rate) pcm_stop();
  avi.target = target;
  // Первая перемотка вглубь строит таблицу: ядро проходит цепочку FAT до
  // idx1 в конце файла, на больших файлах это секунды. Показываем, что
  // плеер занят; следующий кадр вернёт обычный HUD.
  if (target && !index_asked)
  {
    index_asked = 1;
    ft_ccmd_start(cmdl); ft_Dlstart(); ft_Clear(1, 1, 1);
    ft_Text(512, 384, 29, FT_OPT_CENTER, "Building seek index...");
    ft_Display(); ft_ccmd(FT_CCMD_SWAP);
    if (!fifo_flush() || !fifo_wait(0xFFC)) return false;
  }
  // ok 2: построение таблицы читало idx1 — позиция диска и первая страница
  // кэша заняты им, поток продолжать нельзя.
  avi_far(AVI_OP_SEEK);
  if (!avi_seek_pos && !avi_pcm_rate && target >= avi_frame && avi.ok == 1)
    return true;
  return avi_restart(false);
}

// PCM8 mono и видео используют один номер позиции. При переходе сбрасываем
// оба декодера и пропускаем звук до целевого сэмпла. Пауза запоминает точный
// сэмпл, а не округлённый кадр; продолжение не повторяет его звуковое начало.
// GS держит позицию сам: пауза и продолжение — его команды, без перезапуска.
// Неподдержанная аудиодорожка остаётся у штатного PLAYVIDEO со звуком.
bool avi_controls()
{
  u32 target = 0, elapsed = 0, address = 0, next = 0, pause_sample = 0;
  u8 tick, buffer = 0;
  bool available;
  pcm_live = 0; pcm_drop = 0; pcm_underruns = 0;
  avi_seek_pos = avi_seek_frame = avi_seek_audio = 0;
  // Разбор заголовка — в банке изображений: 1 — покадровый режим, 2 — сбой
  // чтения. Звук идёт на GS, если драйвер загружен, а частота не выше частоты
  // его прерываний: шаг фазы должен уместиться в 16 бит.
  avi_far(AVI_OP_PROBE);
  available = avi.ok == 1;
  if (avi.ok == 2) view_failed = 1;
  pcm_gs = gs_loaded && avi_pcm_rate && avi_pcm_rate <= GS_INT_HZ && !avi_ulaw;
  if (!wc_rewind()) { view_failed = 1; return true; }
  if (!available) { avi_pcm_rate = 0; return view_failed != 0; }
  if (avi_pcm_rate && pcm_gs)
  {
    // Шаг фазового аккумулятора драйвера: rate/37500 в долях 1/65536.
    u16 step = avi_pcm_rate == GS_INT_HZ ? 0xFFFF :
               ((u32)avi_pcm_rate << 16) / GS_INT_HZ;
    if (!gs_cmd(GS_RATE) || !gs_cmd(step) || !gs_cmd(step >> 8))
    { view_failed = 1; return true; }
  }
  wc_vmode(0x87);
  avi_paused = avi_keys = avi_edges = index_asked = 0;
  key_tick = *(volatile u8*)_TMN;
  avi_hud_init();
  pcm_tick = avi_pcm_rate / 40 + 1;
  pcm_unit = avi_pcm_rate ? 14000000UL / 26 / avi_pcm_rate : 0;
  // Не 0xFFFFFFFF: due_frame + 1 переполнилось бы в кадр 0 и первый вызов
  // avi_due() пошёл бы по приращению без начального полного расчёта. То же
  // для счётчиков HUD.
  due_frame = hud_frame = 0xFFFFFFFEUL;
  if (!avi_restart(false)) return true;
  if (avi_pcm_rate && !avi_prime()) return true;
  tick = *(volatile u8*)_TMN;
  while (!view_failed && !*(volatile u8*)_ABT)
  {
    u8 edge;
    bool restart = false, due;
    // Часы видео без звука — раз в тик: 32-битное умножение на каждом круге
    // цикла отнимало заметную долю подачи. Клавиши — avi_keys_poll().
    while (*(volatile u8*)_TMN != tick) { ++tick; elapsed += 20000; }
    avi_keys_poll();
    edge = avi_edges; avi_edges = 0;
    if ((edge | avi_keys) & 16) wc_exit(WC_NEXT_FILE);
    if ((edge | avi_keys) & 32) wc_exit(WC_PREV_FILE);
    // Кольцо FT812 опрашиваем всегда: его курсор оборачивается каждые 32 КиБ.
    if (avi_pcm_rate && (!pcm_gs || tick != poll_tick))
    { poll_tick = tick; pcm_poll(); }
    if (edge & 1)
    {
      avi_paused ^= 1; elapsed = 0;
      if (avi_pcm_rate)
      {
        if (avi_paused) { pause_sample = pcm_drop + pcm_played; pcm_stop(); }
        else if (pcm_gs) pcm_start();
        else
        {
          target = avi_frame ? avi_frame - 1 : 0;
          pcm_drop = pause_sample; restart = true;
        }
      }
      if (avi_frame && !avi_draw(address)) return true;
    }
    if (edge & 14)
    {
      u32 step = 10000000UL / avi_period;
      if (!step) step = 1;
      target = avi_frame ? avi_frame - 1 : 0;
      if (edge & 2) target = target > step ? target - step : 0;
      if (edge & 4) target = min(avi_total - 1, target + step);
      if (edge & 8) target = 0;
      if (avi_pcm_rate)
      {
        pcm_drop = min(avi_pcm_total, pcm_sample(target));
        pause_sample = pcm_drop;
      }
      restart = true;
      elapsed = 0;
    }
    if (restart)
    {
      // Перемотка длится секунды без опроса клавиш: состояние стрелок до неё
      // устарело. Иначе новое нажатие сразу после неё сочлось бы удержанием.
      avi_keys &= 1;
      if (!avi_seek(target)) return true;
      if (avi_pcm_rate && !avi_prime()) return true;
    }
    if (avi_pcm_rate && !avi_paused)
    {
      // Пока следующий кадр не готов — подача до заполнения FIFO. С готовым
      // кадром — по блоку за круг и не у самой отметки: длинная передача
      // звука в GS иначе сдвинула бы его показ.
      if (!avi_ahead) { if (!avi_prime()) return true; }
      else if (pcm_drop + pcm_played + pcm_tick < avi_due()) avi_feed();
    }
    // Декодирование наперёд: следующий кадр готовится в заднем буфере, пока
    // показан текущий, а в отметку кадра остаётся только показать его. Время
    // декодирования FT812 растёт со сложностью JPEG — оно больше не сдвигает
    // кадр относительно звука. Задний буфер свободен, когда смена дисплей-
    // листа уже произошла (REG_DLSWAP = 0): иначе декодер писал бы в
    // показываемый кадр. Первый кадр и кадры до цели перемотки декодируются
    // по требованию, как раньше.
    if (!avi_ahead && avi_frame > target && avi_frame < avi_total &&
        !avi_paused && !ft_rreg8(FT_REG_DLSWAP))
    {
      next = buffer ? avi_bytes : 0; buffer ^= 1;
      if (!avi_decode(next)) return true;
      avi_ahead = 1;
    }
    if (avi_pcm_rate)
    {
      if (pcm_gs && pcm_live)
      {
        u32 at = avi_due(), now = pcm_drop + pcm_played;
        if (now < at && at - now < pcm_tick)
        {
          // Готовый кадр ждём по тактам; неготовый — без ожидания.
          u16 half = avi_ahead ? (u16)(at - now) >> 1 : 0;
          if (half) delay26(half * pcm_unit);
          pcm_poll();
        }
      }
      due = pcm_drop + pcm_played >= avi_due() ||
            (!pcm_live && pcm_played == avi_pcm_total - pcm_drop);
    }
    else due = elapsed >= avi_period;
    if (avi_frame < avi_total &&
        (!avi_frame || avi_frame <= target || (!avi_paused && due)))
    {
      if (!avi_ahead)
      {
        next = buffer ? avi_bytes : 0; buffer ^= 1;
        if (!avi_decode(next)) return true;
      }
      avi_ahead = 0;
      address = next;
      ++avi_frame;
      if (avi_frame > target)
      {
        // Сначала показ — точно в отметку; очередь FIFO пополнит следующий
        // круг цикла.
        if (!avi_draw(address)) return true;
        if (avi_pcm_rate && !avi_paused && !pcm_live && !pcm_played) pcm_start();
      }
      if (elapsed >= avi_period) elapsed -= avi_period;
      if (avi_frame <= target) elapsed = 0;
    }
    if (avi_frame == avi_total && !avi_paused &&
        (!avi_pcm_rate || (!pcm_live && pcm_played == avi_pcm_total - pcm_drop)))
    { avi_paused = 1; if (!avi_draw(address)) return true; }
  }
  if (avi_pcm_rate) pcm_stop();
  return true;
}
