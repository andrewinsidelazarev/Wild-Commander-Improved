
// Видео требует запаса на чтение SD: штатные 7 МГц WC не обеспечивают
// поток данного MJPEG даже с DMA. API 14 выбирает 14 МГц, сохраняя кэш,
// а B=FF возвращает настройки WC. Никакие значения в INI не изменяются.
void wc_video_clock(u8 enabled) __sdcccall(1) __naked
{
  enabled;
  __asm
    or a
    ld bc, #0xFF00
    jr z, 00999$
    ld bc, #0x0002
00999$:
    ld a, #_TURBOPL
    jp _WCAPI
  __endasm;
}

// Номера 1..8 относятся к страницам буфера, выделенным именно этому WMF. API 0
// вычисляет физическую страницу и обновляет теневой PAGE3, которым пользуются
// LOAD512 и DMA. Простая запись порта без обновления PAGE3 здесь недопустима.
void wc_map_buffer(u8 page) __sdcccall(1) __naked
{
  page;
  __asm
    ex af, af
    xor a
    jp _WCAPI
  __endasm;
}

bool wc_api__bool(u8 a) __sdcccall(0) __naked
{
  a;  // to avoid SDCC warning
  __asm
    ld hl, #2
    add hl, sp
    ld a, (hl)
    call _WCAPI
    ld l, #0
    ret z
    inc l
    ret
  __endasm;
}

void wc_api_u16(u8 a, u16 b) __sdcccall(0) __naked
{
  a;  // to avoid SDCC warning
  b;  // to avoid SDCC warning
  __asm
    ld hl, #2
    add hl, sp
    ld a, (hl)
    inc hl
    ld c, (hl)
    inc hl
    ld b, (hl)
    ; WC принимает адрес окна в IX, а SDCC использует IX для локальных
    ; переменных вызывающей функции. Передаём аргумент, сохранив прежний IX.
    push ix
    push bc
    pop ix
    call _WCAPI
    pop ix
    ret
  __endasm;
}

bool wc_vmode(u8 a) __sdcccall(0) __naked
{
  a;  // to avoid SDCC warning
  __asm
    ld hl, #2
    add hl, sp
    ld a, (hl)
    ex af, af
    ld a, #_GVmod
    jp _WCAPI
  __endasm;
}

u16 wc_load512(u8 *a, u8 b) __sdcccall(0) __naked
{
  a;  // to avoid SDCC warning
  b;  // to avoid SDCC warning
  __asm
    ld hl, #2
    add hl, sp
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld b, (hl)
    ex de, hl
    ld a, #_LOAD512
    call _WCAPI
    ; После длинного потока драйвер может вернуть управление с DI. FTView
    ; работает как интерактивный плагин: ему нужны IM2, Esc и таймер ожиданий.
    ; EI не меняет CF и не мешает проверить результат LOAD512 ниже.
    ei
    ; Успех: HL указывает за прочитанные секторы. Ошибка CF=1: возвращаем
    ; ноль, чтобы C-код отличал отказ от полного чтения. Конец цепочки
    ; с CF=0 не отвергаем: последний сектор файла может быть прочитан.
    ret nc
    ld hl, #0
    ret
  __endasm;
}

// API 61 (LOADNONE): тот же потоковый проход, что LOAD512, но без передачи
// данных — продвигает позицию на count секторов (1..255) по цепочке FAT.
// Нужен перемотке: смещение в файле достигается без чтения его содержимого.
bool wc_skip512(u8 count) __sdcccall(1) __naked
{
  count;
  __asm
    ld b, a
    ld hl, #0xC000
    push ix
    ld a, #_LOADNONE
    call _WCAPI
    pop ix
    ei
    ld a, #0
    ret c
    inc a
    ret
  __endasm;
}

// После чтения заголовка заново открываем цепочку исходного файла через
// сохранённый WC начальный кластер. Возвращаем false при ошибке FAT.
bool wc_rewind() __sdcccall(0) __naked
{
  __asm
    push ix
    ld a, #_GIPAGPL
    call _WCAPI
    pop ix
    ei
    ld l, #0
    ret c
    inc l
    ret
  __endasm;
}

void wc_exit(u8 rc) __sdcccall(0) __naked
{
  // Выход непосредственно в WC, минуя вложенные C-вызовы. __sdcccall(0) __naked обязателен:
  // аргумент берётся из SP+2, а затем восстанавливается исходный стек плагина.
  rc;  // to avoid SDCC warning
  __asm
    ld hl, #2
    add hl, sp
    ld a, (hl)
    ; Любой выход (Esc, соседний файл, ошибка) восстанавливает видеосреду.
    ; Код возврата держим на стеке: cleanup вправе менять все рабочие регистры.
    push af
    call _view_cleanup
    pop af
    ld ix, (_ret_ix)
    ld iy, (_ret_iy)
    ld sp, (_ret_sp)
    ei
    ret
  __endasm;
}
