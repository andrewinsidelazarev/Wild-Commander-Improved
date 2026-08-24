	.module inflate_crt0
	.globl _inflate_test_main

	.area _HEADER (ABS)
	.org 0x8000
_inflate_test_entry::
	call _inflate_test_main
	ret

	;; Порядок сегментов для компоновщика тестового образа.
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
