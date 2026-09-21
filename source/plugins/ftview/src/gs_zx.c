// Связь с General Sound / NeoGS со стороны ZX. Порт #BB: запись — команда,
// чтение — статус (бит 0: команда ещё не принята, бит 7: байт данных не
// забран). Порт #B3: данные в обе стороны. Протокол драйвера — в gsdrv.s:
// поток идёт парами через оба регистра, команды — только между парами.
//
// Банк изображений загружает драйвер через ПЗУ GS до перехода в видеобанк и
// оставляет результат в общем кадре (gs_loaded). Видеобанку нужен только
// короткий обмен: команды, позиция воспроизведения и поток сэмплов.

__sfr __at 0xBB gs_port;
__sfr __at 0xB3 gs_data;

#define GS_PING   0x01
#define GS_FLUSH  0x02
#define GS_PLAY   0x03
#define GS_PAUSE  0x04
#define GS_RATE   0x05
#define GS_POS    0x06
#define GS_SINGLE 0x07
#define GS_EXIT   0xF4
// Частота прерываний GS: шаг фазы = rate * 65536 / 37500.
#define GS_INT_HZ 37500UL

#ifndef FTVIEW_VIDEO_BANK
#include "gsdrv.h"

// Ждём (статус & mask) == value не дольше frames кадров WC. Счётчик опросов
// ограничивает ожидание и при остановленном таймере.
bool gs_wait(u8 mask, u8 value, u8 frames)
{
  u8 tick = *(volatile u8*)_TMN;
  u16 polls = 0;
  do
    if ((gs_port & mask) == value) return true;
  while (--polls && (u8)(*(volatile u8*)_TMN - tick) < frames);
  return false;
}

bool gs_put(u8 value)
{
  if (!gs_wait(0x80, 0, 2)) return false;
  gs_data = value;
  return true;
}

// #F3 возвращает ПЗУ (или прежний драйвер) в цикл команд, #14 загружает
// драйвер, #13 передаёт ему управление, ответ на PING подтверждает запуск.
// Эмуляция GS без процессора (Unreal GSType=BASS) команд #13/#14 не
// исполняет и PING не проходит: тогда звук остаётся у FT812.
// gs_stage — этап, на котором загрузка остановилась (0 — драйвер работает,
// 1 — карты нет, 2 — #F3, 3 — #14, 4 — #13, 5 — PING); видеобанк выводит его
// рядом с выбранным звуковым устройством.
u8 gs_stage;
bool gs_boot()
{
  u16 i;
  u8 reply[3];
  (void)gs_data;                       // снять возможный непрочитанный ответ
  gs_stage = 1;
  if (gs_port == 0xFF) return false;   // пустая шина: карты нет
  gs_stage = 2;
  gs_port = 0xF3;
  if (!gs_wait(1, 0, 3)) return false;
  gs_stage = 3;
  gs_data = sizeof(gs_driver) & 255;
  gs_port = 0x14;
  // После #F3 ПЗУ сначала выполняет тёплый старт (~8 мс) и лишь затем берёт
  // следующую команду.
  if (!gs_wait(1, 0, 25) || !gs_put(sizeof(gs_driver) >> 8) ||
      !gs_put(GS_DRIVER_ORG & 255) || !gs_put(GS_DRIVER_ORG >> 8)) return false;
  for (i = 0; i < sizeof(gs_driver); ++i)
    if (!gs_put(gs_driver[i])) return false;
  if (!gs_wait(0x81, 0, 2)) return false;
  gs_stage = 4;
  gs_data = GS_DRIVER_ORG & 255;
  gs_port = 0x13;
  if (!gs_wait(1, 0, 2) || !gs_put(GS_DRIVER_ORG >> 8) || !gs_wait(0x80, 0, 2))
    return false;
  gs_stage = 5;
  gs_port = GS_PING;
  for (i = 0; i < 3; ++i)
  {
    if (!gs_wait(0x80, 0x80, 2)) return false;
    reply[i] = gs_data;
  }
  if (!gs_wait(1, 0, 2) || reply[0] != 'G' || reply[1] != 'S' ||
      reply[2] != GS_DRIVER_VERSION) return false;
  gs_stage = 0;
  return true;
}

#else

// Ждём (статус & C) == B. Выход: CF=0 — дождались, CF=1 — нет ответа
// за 65536 опросов (~0,2 с при 14 МГц). Портит A и DE, сохраняет BC и HL.
void gs_until() __naked
{
  __asm
    ld de, #0
00001$:
    in a, (0xBB)
    and c
    cp b
    ret z
    dec de
    ld a, d
    or e
    jr nz, 00001$
    scf
    ret
  __endasm;
}

// Байт команды или её параметра. Возврат 1, когда драйвер его принял, а для
// последнего байта команды — выполнил её.
bool gs_cmd(u8 code) __naked
{
  code;
  __asm
    ld l, a
    ld bc, #0x0001
    call _gs_until
    jr c, 00001$
    ld a, l
    out (0xBB), a
    call _gs_until
    jr c, 00001$
    ld a, #1
    ret
00001$:
    xor a
    ret
  __endasm;
}

// Указатель чтения кольца драйвера (#8000..#FFFF) или 0 при сбое. Перед
// запросом GS должен забрать последний байт данных: иначе ответ GS нельзя
// отличить от собственного байта ZX.
u16 gs_pos() __naked
{
  __asm
    ld bc, #0x0080
    call _gs_until
    jr c, 00001$
    ld c, #1
    call _gs_until
    jr c, 00001$
    ld a, #6
    out (0xBB), a
    ld bc, #0x8080
    call _gs_until
    jr c, 00001$
    in a, (0xB3)
    ld l, a
    call _gs_until
    jr c, 00001$
    in a, (0xB3)
    ld h, a
    ld bc, #0x0001
    call _gs_until
    jr c, 00001$
    ex de, hl
    ret
00001$:
    ld de, #0
    ret
  __endasm;
}

// Передать count > 0 сэмплов. Пары идут конвейером: чётный байт — OUTI в
// регистр данных #B3, нечётный — в регистр команд #BB; GS забирает один
// канал, пока ZX заполняет другой. B считает байты пары (OUTI и DJNZ), D —
// проходы по 256. Нечётный хвост — командой #07 и байтом в #B3. Ожидание
// канала — не больше 768 опросов (~1,5 мс): драйвер забирает байт за
// единицы микросекунд даже во время своего прерывания. Старший байт адреса
// порта (B) карта GS не декодирует. Быстрый путь без переходов: GS 12 МГц
// принимает ~5,4 мкс на байт против ~8,6 мкс при обмене по одному регистру.
bool gs_send(u8 *data, u16 count) __naked
{
  data; count;
  __asm
    ld a, e
    push af
    and #0xFE
    ld b, a
    or d
    jr z, 00030$
    ld e, b
    dec de
    inc d
    ld c, #0xB3
00001$:
    in a, (0xBB)
    rlca
    jr c, 00010$
00002$:
    outi
    in a, (0xBB)
    rrca
    jr c, 00020$
00003$:
    ld a, (hl)
    out (0xBB), a
    inc hl
    djnz 00001$
    dec d
    jr nz, 00001$
00030$:
    pop af
    rrca
    ld a, #1
    ret nc
    ; Нечётный хвост: #07, снятие бита команды — байт в регистр данных.
    ld bc, #0x0001
    call _gs_until
    jr c, 00041$
    ld a, #0x07             ; GS_SINGLE
    out (0xBB), a
    call _gs_until
    jr c, 00041$
    ld a, (hl)
    out (0xB3), a
    ld a, #1
    ret
    ; Регистр данных занят: три опроса на шаг счётчика таймаута.
00010$:
    ld e, #0
00011$:
    in a, (0xBB)
    rlca
    jr nc, 00002$
    in a, (0xBB)
    rlca
    jr nc, 00002$
    in a, (0xBB)
    rlca
    jr nc, 00002$
    dec e
    jr nz, 00011$
    jr 00040$
    ; Регистр команд занят.
00020$:
    ld e, #0
00021$:
    in a, (0xBB)
    rrca
    jr nc, 00003$
    in a, (0xBB)
    rrca
    jr nc, 00003$
    in a, (0xBB)
    rrca
    jr nc, 00003$
    dec e
    jr nz, 00021$
00040$:
    pop af
00041$:
    xor a
    ret
  __endasm;
}

#endif
