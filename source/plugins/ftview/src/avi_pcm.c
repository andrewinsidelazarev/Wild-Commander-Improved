// PCM извлекается при подаче AVI в media FIFO, без второго чтения SD.
// Вывод: драйвер General Sound (кольцо 32 КиБ в памяти GS, pcm_gs=1) или,
// без GS, звуковой блок FT812 (кольцо #C0000..#CFFFF, отдельно от кадров).
#define PCM_CAPACITY 32768UL
// avi_pcm_rate, avi_pcm_total, avi_movi_* и точка перемотки avi_seek_* —
// поля структуры avi (avi_controls.c).
u32 pcm_drop, pcm_seen, pcm_written, pcm_played, pcm_scan, pcm_remaining;
u16 pcm_read_last, pcm_underruns, pcm_base;
u8 pcm_live, pcm_head_size, pcm_head[8], pcm_gs;

// Номер кадра -> PCM-сэмпл. Разложение произведения исключает переполнение
// frame*sample_rate. probe допускает сюда целую частоту кадров 1..1000.
u32 pcm_sample(u32 frame)
{
  u16 fps = avi_rate;
  return frame * (avi_pcm_rate / fps) +
         (frame / fps) * (avi_pcm_rate % fps) +
         (frame % fps) * (avi_pcm_rate % fps) / fps;
}

void pcm_stop()
{
  if (pcm_gs) { if (!gs_cmd(GS_PAUSE)) fail(9); }
  else ft_pb_stop();
  pcm_live = 0;
}

// Мастер времени — реально воспроизведённые сэмплы. Опрашиваем курсор
// также в ожиданиях декодера. GS сам держит последний сэмпл при пустом
// кольце: его позиция просто не растёт. Кольцо FT812 повторило бы старый
// звук, поэтому там опустошение останавливает воспроизведение как сбой.
void pcm_poll()
{
  if (pcm_live)
  {
    if (pcm_gs)
    {
      // Запись GS = pcm_written mod 32768, чтение — ответ драйвера.
      u16 read = gs_pos();
      if (!read) { pcm_live = 0; fail(10); return; }
      pcm_played = pcm_written - (((u16)pcm_written - read) & 0x7FFF);
    }
    else
    {
      u16 read = (ft_rreg32(FT_REG_PLAYBACK_READPTR) - pcm_base) & 0x7FFF;
      pcm_played += (read - pcm_read_last) & 0x7FFF;
      pcm_read_last = read;
    }
    if (pcm_played >= avi_pcm_total - pcm_drop &&
        pcm_written == avi_pcm_total - pcm_drop)
    { pcm_played = avi_pcm_total - pcm_drop; pcm_stop(); }
    else if (pcm_played > pcm_written)
    {
      // Кольцо FT812 доиграло записанное и пошло по кругу. Данных больше
      // нет (конец ролика) — это конец звука, а не сбой: в заголовке
      // объявлено больше сэмплов, чем лежит в movi.
      ++pcm_underruns;
      pcm_stop();
      if (avi_left) fail(11);
      else pcm_played = pcm_written;
    }
  }
}

void pcm_reset()
{
  pcm_stop();
  if (pcm_gs) { if (!gs_cmd(GS_FLUSH)) fail(12); }
  // PLAY=1 принимается звуковым блоком асинхронно. Курсор некоторое время
  // ещё указывает в старый буфер. Выбираем непересекающуюся половину 64 КиБ:
  // переход курсора в неё однозначно подтверждает принятие нового старта.
  else pcm_base = (ft_rreg32(FT_REG_PLAYBACK_READPTR) & 0x8000) ? 0 : 0x8000;
  pcm_written = pcm_played = pcm_remaining = 0;
  pcm_seen = avi_seek_audio;
  pcm_scan = avi_seek_pos ? avi_seek_pos : avi_movi_start;
  pcm_read_last = pcm_head_size = 0;
}

void pcm_start()
{
  u16 polls = 0xFFFF;
  if (!pcm_written || pcm_drop >= avi_pcm_total) return;
  if (pcm_gs)
  {
    if (!gs_cmd(GS_PLAY)) { fail(13); return; }
    pcm_live = 1;
    return;
  }
  ft_wreg32(FT_REG_PLAYBACK_START, PCM_BASE + pcm_base);
  ft_wreg32(FT_REG_PLAYBACK_LENGTH, PCM_CAPACITY);
  ft_wreg16(FT_REG_PLAYBACK_FREQ, avi_pcm_rate);
  ft_wreg8(FT_REG_PLAYBACK_FORMAT, FT_LINEAR_SAMPLES);
  ft_wreg8(FT_REG_PLAYBACK_LOOP, 1);
  ft_wreg8(FT_REG_VOL_PB, 255);
  ft_wreg8(FT_REG_PLAYBACK_PLAY, 1);
  do
  {
    u32 read = ft_rreg32(FT_REG_PLAYBACK_READPTR) - PCM_BASE - pcm_base;
    if (read < PCM_CAPACITY)
    { pcm_played = read; pcm_read_last = read; pcm_live = 1; return; }
  } while (--polls && !*(volatile u8*)_ABT);
  pcm_stop(); fail(14);
}

// AVI PCM8 беззнаковый, FT812 LINEAR_SAMPLES знаковый. После отправки
// возвращаем исходные байты в буфер EVO: VIDEOFRAME получает неизменённый AVI.
void pcm_flip(u8 *data, u16 size)
{
  while (size--) { *data ^= 0x80; ++data; }
}

// Оба кольца по 32 КиБ. avi_feed держит в очереди не больше 24 КиБ, а порция
// не больше 4 КиБ, поэтому переполнение здесь — только признак сбоя.
bool pcm_write(u8 *data, u16 size)
{
  u16 part;
  if (!pcm_gs || pcm_written + size - pcm_played >= PCM_CAPACITY) pcm_poll();
  if (view_failed || pcm_written + size - pcm_played >= PCM_CAPACITY)
  { fail(15); return false; }
  if (pcm_gs)
  {
    // GS принимает беззнаковые сэмплы AVI как есть.
    if (!gs_send(data, size)) { fail(16); return false; }
    pcm_written += size;
    return true;
  }
  while (size)
  {
    u16 offset = pcm_written & 0x7FFF;
    part = min(size, PCM_CAPACITY - offset);
    pcm_flip(data, part);
    ft_write(data, PCM_BASE + pcm_base + offset, part);
    pcm_flip(data, part);
    pcm_written += part; data += part; size -= part;
  }
  return true;
}

// Чанки разбираются по длинам, включая заголовки на границах страниц EVO.
// Подпись 01wb внутри JPEG не является звуком. Вложенный LIST пока отклоняем:
// неподдержанный контейнер не должен превращаться в случайные PCM-сэмплы.
//
// Ассемблер: разбор идёт на каждой порции подачи, а SDCC тратил на 32-битные
// сравнения каждого байта заголовка тысячи тактов. Внутри блока смещения
// 16-битные (блок не больше 4 КиБ), 32-битная арифметика — только на границах
// чанков; заголовок копируется целиком. Рабочие: tee_ptr — текущий байт,
// tee_left — остаток блока в пределах movi, tee_pos — его позиция в файле,
// tee_n — длина шага. ABI 1: HL=data, DE=size, pos (u32) в стеке, его снимает
// сама функция.
u16 tee_ptr, tee_left, tee_n;
u32 tee_pos;
bool pcm_tee(u8 *data, u16 size, u32 pos) __naked
{
  data; size; pos;
  __asm
    ld (_tee_ptr), hl
    ld (_tee_left), de
    ld hl, #2
    add hl, sp
    ld de, #_tee_pos
    ld bc, #4
    ldir
    ; Лимит блока: min(size, movi_end - pos); за концом movi — ничего.
    ld hl, (_avi + 8)
    ld de, (_tee_pos)
    or a
    sbc hl, de
    ld c, l
    ld b, h
    ld hl, (_avi + 10)
    ld de, (_tee_pos + 2)
    sbc hl, de
    jp c, tee_ok
    ld a, h
    or l
    jr nz, tee_loop
    ld hl, (_tee_left)
    or a
    sbc hl, bc
    jr c, tee_loop
    ld (_tee_left), bc
tee_loop:
    ld hl, (_tee_left)
    ld a, h
    or l
    jp z, tee_ok
    ; Внутри звукового чанка: n = min(остаток блока, остаток чанка).
    ld hl, (_pcm_remaining)
    ld de, (_pcm_remaining + 2)
    ld a, d
    or e
    jr nz, tee_audio_left
    ld a, h
    or l
    jp z, tee_hdr
    ld de, (_tee_left)
    or a
    sbc hl, de
    jr nc, tee_audio_left
    ld hl, (_pcm_remaining)
    jr tee_audio_n
tee_audio_left:
    ld hl, (_tee_left)
tee_audio_n:
    ld (_tee_n), hl
    ; До pcm_drop сэмплы отбрасываются: n = min(n, drop - seen).
    ld hl, (_pcm_drop)
    ld de, (_pcm_seen)
    or a
    sbc hl, de
    ld c, l
    ld b, h
    ld hl, (_pcm_drop + 2)
    ld de, (_pcm_seen + 2)
    sbc hl, de
    jr c, tee_write
    ld a, h
    or l
    jr nz, tee_advance
    ld a, b
    or c
    jr z, tee_write
    ld hl, (_tee_n)
    or a
    sbc hl, bc
    jr c, tee_advance
    ld (_tee_n), bc
    jr tee_advance
tee_write:
    ld hl, (_tee_ptr)
    ld de, (_tee_n)
    call _pcm_write
    or a
    jp z, tee_ret
tee_advance:
    ld de, (_tee_n)
    ld hl, (_pcm_seen)
    add hl, de
    ld (_pcm_seen), hl
    jr nc, 00001$
    ld hl, (_pcm_seen + 2)
    inc hl
    ld (_pcm_seen + 2), hl
00001$:
    ld hl, (_pcm_remaining)
    or a
    sbc hl, de
    ld (_pcm_remaining), hl
    jr nc, 00002$
    ld hl, (_pcm_remaining + 2)
    dec hl
    ld (_pcm_remaining + 2), hl
00002$:
    call tee_step
    jp tee_loop
    ; Между чанками: пропуск до pcm_scan или сбор заголовка.
tee_hdr:
    ld hl, (_pcm_scan)
    ld de, (_tee_pos)
    or a
    sbc hl, de
    ld c, l
    ld b, h
    ld hl, (_pcm_scan + 2)
    ld de, (_tee_pos + 2)
    sbc hl, de
    jr c, tee_head
    ld a, h
    or l
    jp nz, tee_ok
    ld a, b
    or c
    jr z, tee_head
    ld hl, (_tee_left)
    or a
    sbc hl, bc
    jp c, tee_ok
    ld e, c
    ld d, b
    call tee_step
    jp tee_loop
tee_head:
    ld a, (_pcm_head_size)
    ld c, a
    ld b, #0
    ld a, #8
    sub c
    ld e, a
    ld d, b
    ld hl, (_tee_left)
    or a
    sbc hl, de
    jr nc, 00003$
    ld de, (_tee_left)
00003$:
    ld (_tee_n), de
    ld hl, #_pcm_head
    add hl, bc
    ex de, hl
    ld hl, (_tee_ptr)
    ld bc, (_tee_n)
    ldir
    ld de, (_tee_n)
    ld a, (_pcm_head_size)
    add a, e
    ld (_pcm_head_size), a
    call tee_step
    ld a, (_pcm_head_size)
    cp #8
    jp nz, tee_loop
    xor a
    ld (_pcm_head_size), a
    ; Данные чанка начинаются с tee_pos: длина <= movi_end - tee_pos.
    ld hl, (_avi + 8)
    ld de, (_tee_pos)
    or a
    sbc hl, de
    ld (_tee_n), hl
    ld hl, (_avi + 10)
    ld de, (_tee_pos + 2)
    sbc hl, de
    jp c, tee_fail
    call tee_fits
    jp c, tee_fail
    ld de, #_pcm_head
    ld hl, #tee_list
    call tee_tag
    jp z, tee_fail
    ; pcm_scan = tee_pos + length + (length & 1), не дальше movi_end.
    ld hl, (_tee_pos)
    ld de, (_pcm_head + 4)
    add hl, de
    ld (_pcm_scan), hl
    ld hl, (_tee_pos + 2)
    ld de, (_pcm_head + 6)
    adc hl, de
    ld (_pcm_scan + 2), hl
    ld a, (_pcm_head + 4)
    rra
    jr nc, 00004$
    ld hl, (_pcm_scan)
    ld de, #1
    add hl, de
    ld (_pcm_scan), hl
    ld hl, (_pcm_scan + 2)
    dec de
    adc hl, de
    ld (_pcm_scan + 2), hl
00004$:
    ld hl, (_avi + 8)
    ld de, (_pcm_scan)
    or a
    sbc hl, de
    ld hl, (_avi + 10)
    ld de, (_pcm_scan + 2)
    sbc hl, de
    jp c, tee_fail
    ld de, #_pcm_head
    ld hl, #tee_01wb
    call tee_tag
    jp nz, tee_loop
    ; Звуковой чанк: длина <= pcm_total - pcm_seen.
    ld hl, (_avi + 28)
    ld de, (_pcm_seen)
    or a
    sbc hl, de
    ld (_tee_n), hl
    ld hl, (_avi + 30)
    ld de, (_pcm_seen + 2)
    sbc hl, de
    jp c, tee_fail
    call tee_fits
    jp c, tee_fail
    ld hl, (_pcm_head + 4)
    ld (_pcm_remaining), hl
    ld hl, (_pcm_head + 6)
    ld (_pcm_remaining + 2), hl
    jp tee_loop
tee_fail:
    ld a, #1
    ld (_view_failed), a
    xor a
    jr tee_ret
tee_ok:
    ld a, #1
tee_ret:
    pop hl
    pop bc
    pop bc
    jp (hl)

    ; Шаг на DE байтов: указатель, остаток блока и позиция в файле.
tee_step:
    ld hl, (_tee_ptr)
    add hl, de
    ld (_tee_ptr), hl
    ld hl, (_tee_left)
    or a
    sbc hl, de
    ld (_tee_left), hl
    ld hl, (_tee_pos)
    add hl, de
    ld (_tee_pos), hl
    ret nc
    ld hl, (_tee_pos + 2)
    inc hl
    ld (_tee_pos + 2), hl
    ret

    ; CF=1, если длина заголовка (pcm_head+4) больше доступного HL:tee_n.
tee_fits:
    ex de, hl
    ld hl, (_pcm_head + 6)
    or a
    sbc hl, de
    jr z, 00005$
    ccf
    ret
00005$:
    ld hl, (_tee_n)
    ld de, (_pcm_head + 4)
    or a
    sbc hl, de
    ret

    ; Z, если четыре байта (DE) совпадают с тегом (HL).
tee_tag:
    ld b, #4
00006$:
    ld a, (de)
    cp (hl)
    ret nz
    inc de
    inc hl
    djnz 00006$
    ret
tee_list:
    .ascii "LIST"
tee_01wb:
    .ascii "01wb"
  __endasm;
}
