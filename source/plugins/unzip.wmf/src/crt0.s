	.module crt0
	.globl _plugin_main
	.globl _archive_size
	.globl _archive_name_ptr
	.globl _saved_panel_ix

	.area _HEADER (ABS)
	.org 0x8000
_plugin_entry::
	push ix
	ld (_saved_panel_ix), ix
	ld (_archive_size), hl
	ld (_archive_size + 2), de
	ld (_archive_name_ptr), bc
	call _plugin_main
	pop ix
	ret

	;; Порядок сегментов для компоновщика.
	.area _HOME
	.area _CODE
	.area _INITIALIZER
	.area _GSINIT
	.area _GSFINAL

	.area _DATA
	.area _INITIALIZED
	.area _BSEG
	.area _BSS
	.area _HEAP

	.area _GSINIT
	.area _GSFINAL
