;---------------------------------------
; Plasma screensaver
; by VBI'2014
;---------------------------------------

        DEVICE ZXSPECTRUM128

       	include "wcKernel.h.asm"
startCode
        IFNDEF __ALASM_CORG_ACTIVE
        ORG #0000
        DISP #0000
        DEFINE __ALASM_CORG_ACTIVE 1
__ALASM_CORG_CODE DEFL #0000
__ALASM_CORG_LOGICAL DEFL #0000
__ALASM_CORG_DISP DEFL 1
        ELSE
__ALASM_CORG_END DEFL __ALASM_CORG_CODE + ($ - __ALASM_CORG_LOGICAL)
__ALASM_CORG_NEW DEFL #0000
        IF __ALASM_CORG_NEW > __ALASM_CORG_END
        DS __ALASM_CORG_NEW - __ALASM_CORG_END,0
        ENDIF
        IF __ALASM_CORG_DISP
        ENT
        ENDIF
        DISP #0000
__ALASM_CORG_CODE DEFL __ALASM_CORG_NEW
__ALASM_CORG_LOGICAL DEFL #0000
__ALASM_CORG_DISP DEFL 1
        ENDIF
        include "pluginHead.asm"
        align 512
        DISP #8000
mainStart
		include "twister.asm"
mainEnd
        ENT
        align 512
block1  incbin "rorat3d wmf.tga.pix4.000"
        align 512
eblock1
block2  incbin "rorat3d wmf.tga.pix4.001"
        align 512
eblock2
block3  incbin "rorat3d wmf.tga.pix4.002"
        align 512
eblock3
endCode

	SAVEBIN "PLASMATW.WMF", startCode, endCode-startCode
