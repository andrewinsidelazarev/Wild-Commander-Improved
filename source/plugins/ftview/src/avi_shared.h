#pragma once
// Общие поля AVI. В видеобанке это его рабочие переменные (макросы avi_* в
// avi_index.c); банку изображений (far_call) и банку списка копия структуры
// передаётся в AVI_FAR.
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
  u32 cluster;        // первый кластер ролика (avi_rewind)
  // Размер файла ролика. filesize (#BFE6) у каждого банка кода свой: после
  // выбора в списке у банка изображений там остался бы прежний ролик.
  u32 size;
} AVI_SHARED;

#define AVI_OP_SEEK 1     // точка входа для target (нули — с начала файла);
                          // ok 2 — чтение idx1 сдвинуло позицию диска
#define AVI_OP_HEADER 2   // заголовок в FIFO, поток на seek_pos
#define AVI_OP_PROBE 3    // разбор заголовка: ok 1 — покадровый режим, 2 — сбой
// Копия полей для банков изображений и списка: свободный хвост первой
// страницы буфера.
#define AVI_FAR ((AVI_SHARED*)0xFF00)

// Раскладка RAM_G: слово результата декодера над двумя кадрами, кольцо PCM
// FT812 с #C0000. Нужна и разбору заголовка в банке изображений.
#define AVI_RESULT 0xDFFFCUL
#define PCM_BASE 0xC0000UL
