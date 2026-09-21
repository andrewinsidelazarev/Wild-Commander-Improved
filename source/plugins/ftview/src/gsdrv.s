; Драйвер потокового PCM8 для процессора General Sound / NeoGS.
;
; Загружается командой ПЗУ GS #14 по адресу #5000 и запускается командой #13.
; Область #4000..#44FF занята переменными и стеком ПЗУ: её обработчик
; прерываний работает, пока идёт загрузка, поэтому код лежит выше.
; Чтение процессором GS адресов #6000..#7FFF защёлкивает байт в ЦАП канала
; A9..A8. Поэтому здесь нет ни кода, ни стека, ни переменных из этой области.
;
; Кольцо 32 КиБ: страница 2 в окне #8000..#FFFF (страница 1 пересекается с
; #4000..#7FFF, страница 0 — ПЗУ).
;
; Поток — конвейер из двух однобайтовых каналов ZX: чётный сэмпл пары идёт
; в регистр данных (#B3, бит 7 статуса), нечётный — в регистр команд (#BB,
; бит 0). Пока GS забирает один канал, ZX уже заполняет другой; обмен по
; одному регистру ждал бы каждую сторону по очереди (~8,6 мкс на байт против
; ~5,4 мкс здесь при GS 12 МГц). После чётного сэмпла драйвер ждёт только
; нечётный: команды приходят лишь между парами, когда оба канала пусты.
; Нечётный хвост порции ZX отдаёт командой #07. Параметры команд идут
; следующими байтами регистра команд, ответы — через #B3 от GS.
;
; Прерывание 37,5 кГц: фазовый аккумулятор HL += BC (шаг = rate*65536/37500),
; перенос сдвигает указатель чтения BC'. Пустое кольцо (BC' = DE) удерживает
; последний сэмпл, позиция при этом не растёт: ZX видит остановку звуковых
; часов. Главные HL/BC принадлежат обработчику, DE — указатель записи главного
; цикла, D'/E' — страницы таблиц ЦАП; команды используют A и память. EXX при
; разрешённых прерываниях запрещён.

        .module gsdrv
        .area   _GSDRV (ABS)
        .org    0x5000

MPAG    = 0x00
ZXCMD   = 0x01
ZXDATRD = 0x02
ZXDATWR = 0x03
ZXSTAT  = 0x04
CLRCBIT = 0x05
VOL1    = 0x06
VOL2    = 0x07
VOL3    = 0x08
VOL4    = 0x09

RING    = 0x8000
PAGE    = 2
; IM2. Байт вектора на шине GS в цикле подтверждения прерывания не определён:
; ПЗУ работает в IM1, и шину в этом цикле никто не ведёт (Unreal и модель
; дают #FF, настоящая карта — что угодно). Поэтому таблица — 257 одинаковых
; байтов #50: какой бы байт ни пришёл, адрес обработчика — #5050.
IM2TAB  = 0x5C00
ISR     = 0x5050
STACK   = 0x5E00
VERSION = 2

gs_entry:
        di
        ld      sp,#STACK
        ld      a,#PAGE
        out     (MPAG),a
        ; Таблицы тождества: (#60vv)=vv, (#62vv)=vv. Чтение такого адреса
        ; выводит vv в канал 0 (левый) или 2 (правый) без записи в ЦАП-окно.
        ld      hl,#0x6000
1$:     ld      (hl),l
        inc     l
        jr      nz,1$
        ld      h,#0x62
2$:     ld      (hl),l
        inc     l
        jr      nz,2$
        ; Каналы 1 и 3 не используются: фиксируем в них середину шкалы.
        ld      a,#0x80
        ld      (0x6180),a
        ld      (0x6380),a
        ld      a,(0x6080)
        ld      a,(0x6180)
        ld      a,(0x6280)
        ld      a,(0x6380)
        ld      a,#0x3F
        out     (VOL1),a
        out     (VOL2),a
        out     (VOL3),a
        out     (VOL4),a
        ld      hl,#IM2TAB
        ld      de,#IM2TAB+1
        ld      bc,#256
        ld      (hl),#>ISR
        ldir
        ld      a,#>IM2TAB
        ld      i,a
        im      2
        call    flush
        jp      main
gs_init_end::

; Прерывание 37,5 кГц — по адресу, который даёт таблица IM2.
        .org    ISR
gs_isr::
        ex      af,af'
        add     hl,bc
        jr      c,isr_step
        ex      af,af'
        ei
        ret
isr_step:
        ld      a,e                     ; указатель записи главного цикла
        exx
        cp      c
        jr      z,isr_check
isr_next:
        ld      a,(bc)
        inc     c
        jr      z,isr_page
isr_out:
        ld      l,a
        ld      h,d
        ld      a,(hl)
gs_dac_left::
        ld      h,e
        ld      a,(hl)
gs_dac_right::
        exx
        ex      af,af'
        ei
        ret
isr_page:
        inc     b
        jr      nz,isr_out
        ld      b,#0x80
        jr      isr_out
isr_check:
        exx
        ld      a,d
        exx
        cp      b
        jr      nz,isr_next
        exx                             ; кольцо пусто: держим сэмпл
        ex      af,af'
        ei
        ret


; Главный цикл. Чётный сэмпл пары (бит 7) проверяется раньше команды: ZX
; пишет команду только в пустые каналы, поэтому порядок однозначен.
; Указатель записи живёт только в DE: прерывание сравнивает с ним указатель
; чтения напрямую. Поэтому DE никогда не должен забегать вперёд записанных
; данных: при переходе страницы E=0 при старом D (отставание — безопасно),
; а D меняется одной командой сразу на новое значение, без #00.
main:
        in      a,(ZXSTAT)
        add     a,a
        jr      nc,poll
rx_even:
        in      a,(ZXDATRD)
        ld      (de),a
        inc     e
        jr      z,page_even
rx_wait:
        in      a,(ZXSTAT)
        rrca
        jr      nc,rx_wait
        in      a,(ZXCMD)
        out     (CLRCBIT),a
        ld      (de),a
        inc     e
        jp      nz,main
        call    page
        jp      main
page_even:
        call    page
        jr      rx_wait
poll:   in      a,(ZXSTAT)
        add     a,a
        jr      c,rx_even
        and     #2
        jr      z,main
        in      a,(ZXCMD)
        cp      #0xF3
        jp      z,exit_rom
        cp      #0xF4
        jp      z,exit_rom
        dec     a
        jr      z,cmd_ping
        dec     a
        jr      z,cmd_flush
        dec     a
        jr      z,cmd_play
        dec     a
        jr      z,cmd_pause
        dec     a
        jr      z,cmd_rate
        dec     a
        jr      z,cmd_pos
        dec     a
        jr      z,cmd_single
done:   out     (CLRCBIT),a
        jr      main

; Следующие 256 байтов кольца: D+1, после #FF — снова #80.
page:   ld      a,d
        inc     a
        jr      nz,1$
        ld      a,#0x80
1$:     ld      d,a
        ret

; #07: одиночный сэмпл через регистр данных. Снятый бит команды разрешает
; ZX прислать байт; после приёма бит команды больше не трогаем — ZX может
; уже прислать следующую команду.
cmd_single:
        out     (CLRCBIT),a
1$:     in      a,(ZXSTAT)
        add     a,a
        jr      nc,1$
        in      a,(ZXDATRD)
        ld      (de),a
        inc     e
        jp      nz,main
        call    page
        jp      main

; #01: ответ 'G','S',версия. Бит команды снимается только после того, как
; ZX прочитал последний байт: иначе новый байт данных ZX был бы неотличим от
; ещё не прочитанного ответа.
cmd_ping:
        ld      a,#'G
        call    reply
        ld      a,#'S
        call    reply
        ld      a,#VERSION
        call    reply
        jr      done

; #02: очистить кольцо и встать на паузу.
cmd_flush:
        call    flush
        jr      done

; #03: воспроизводить с частотой из #05.
cmd_play:
        di
        ld      bc,(rate)
        ei
        jr      done

; #04: пауза, позиция сохраняется.
cmd_pause:
        di
        ld      bc,#0
        ei
        jr      done

; #05 lo hi: шаг фазы. Каждый параметр — следующий байт команды.
cmd_rate:
        call    next
        ld      (rate),a
        call    next
        ld      (rate+1),a
        ld      a,b
        or      c
        jr      z,done
        jr      cmd_play

; #06: указатель чтения #8000..#FFFF, младший байт первым.
cmd_pos:
        di
        exx
        ld      (tmp),bc
        exx
        ei
        ld      a,(tmp)
        call    reply
        ld      a,(tmp+1)
        call    reply
        jr      done

; Следующий байт команды-параметра.
next:   out     (CLRCBIT),a
1$:     in      a,(ZXSTAT)
        rrca
        jr      nc,1$
        in      a,(ZXCMD)
        ret

; Отправить A и дождаться, пока ZX его прочитает.
reply:  out     (ZXDATWR),a
1$:     in      a,(ZXSTAT)
        add     a,a
        jr      c,1$
        ret

; Пустое кольцо, пауза, нулевая фаза; D'/E' — страницы таблиц ЦАП.
flush:  di
        ld      de,#RING
        exx
        ld      bc,#RING
        ld      de,#0x6062
        exx
        ld      hl,#0
        ld      b,h
        ld      c,l
        ei
        ret

; #F3/#F4: вернуть GS в ПЗУ тем же тёплым стартом, что команда ПЗУ #F3.
; Переменные ПЗУ в #4000..#41FF драйвер не трогал.
exit_rom:
        di
        im      1
        xor     a
        ld      i,a
        out     (MPAG),a
        out     (CLRCBIT),a
        jp      0xC000

gs_vars::
rate:   .dw     0
tmp:    .dw     0
gs_end::
