        DEVICE ZXSPECTRUM128
        ORG 0

WmfStart:
        DS 16,0
        DB "WildCommanderMDL"
        DB #10                         ; текущий формат заголовка плагина
        DB 0
        DB 3                           ; код и две страницы истории по 16 КиБ
        DB 0                           ; относительная страница 0 по адресу #8000

        DB 0,CodeBlocks                ; страница 0: исполняемый образ
        DB 1,0                         ; страница 1: история #0000..#3FFF
        DB 2,0                         ; страница 2: история #C000..#FFFF
        DB 0,0
        DB 0,0
        DB 0,0

        DS 15,0
        DB 1                           ; запуск по расширению: только Enter, без F3

        DB "ZIP"
        DS 31*3,0

        DB 0
        DD #FFFFFFFF                   ; полный диапазон размеров файлов FAT32
        DB "ZIP unpacker"
        DS 32-12," "
        DB #00                         ; запуск только по расширению
        DS 6,0
        DS 24,0
        DS 32,0
        DS 252,0                       ; параметры INI не используются

        ASSERT $-WmfStart == 512

CodeStart:
        INCBIN "../build/code.bin"
CodeEnd:
CodeBlocks EQU (CodeEnd-CodeStart+511)/512
        ASSERT CodeEnd-CodeStart <= #4000
        ASSERT CodeBlocks <= 32
        DS CodeBlocks*512-(CodeEnd-CodeStart),0
WmfEnd:

        SAVEBIN "build/UNZIP.WMF",WmfStart,WmfEnd-WmfStart
