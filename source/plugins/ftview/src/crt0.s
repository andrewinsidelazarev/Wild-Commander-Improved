
	.module crt0
	.globl	_main
	.globl	_main_dispatch
	.globl	_far_entry
	.globl	_wc_video_bank
	.globl	_far_call
	.globl	_ret_sp

	.area	_HEADER (ABS)
	.org 	0x8000
	jp _main
	; Вход для вызова из видеобанка (far_call). Адрес одинаков в обоих
	; банках; в видеобанке far_entry — пустая функция, её никто не вызывает.
	jp _far_entry

; В обоих банках эти короткие шлюзы находятся по одним адресам. API 79
; переключает #8000, а следующая инструкция уже берётся из нового банка.
; Адреса main_dispatch и far_entry у каждого банка свои; общий входной кадр
; лежит в #BFE0..#BFED.
	.area _BANKSWITCH (ABS)
	.org 0xBF80
_wc_video_bank:
	ld sp, (_ret_sp)
	; Логические адреса кадра совпадают, физические страницы различаются.
	; Переносим все 14 байтов через стек ядра, который API 79 не переключает.
	ld hl, #0xBFE0
	ld b, #7
00001$:
	ld e, (hl)
	inc hl
	ld d, (hl)
	inc hl
	push de
	djnz 00001$
	ld a, #9
	ex af, af'
	ld a, #79		; API 79 MNG8_PL (десятичный номер)
	call 0x6006
	ld hl, #0xBFED
	ld b, #7
00002$:
	pop de
	ld (hl), d
	dec hl
	ld (hl), e
	dec hl
	djnz 00002$
	jp _main_dispatch

; Видеобанк вызывает far_entry банка изображений: HL — адрес блока
; параметров в стеке ядра (он общий для обоих банков). Возврат — только
; через блок: A и DE портит обратное переключение. IX/IY сохраняются.
_far_call:
	push ix
	push iy
	push hl
	xor a
	ex af, af'
	ld a, #79		; API 79 MNG8_PL (десятичный номер)
	call 0x6006
	pop hl
	push hl
	call 0x8003
	pop hl
	ld a, #9
	ex af, af'
	ld a, #79		; API 79 MNG8_PL (десятичный номер)
	call 0x6006
	pop iy
	pop ix
	ret

	;; Ordering of segments for the linker.
	.area	_HOME
	.area	_CODE
	.area	_INITIALIZER
	.area   _GSINIT
	.area   _GSFINAL

	.area	_DATA
	.area	_INITIALIZED
	.area	_BSEG
	.area   _BSS
	.area   _HEAP

	.area   _GSINIT
	.area   _GSFINAL

