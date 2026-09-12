; Русская страница помощи TXTEDIT. Выбор языка выполняет F1MENU.
; Исходник и комментарии — UTF-8; выводимые буквы — байты CP866 для шрифта WC.
; Перед каждой строкой оставлен читаемый русский текст. Названия физических
; клавиш сохранены как на клавиатуре. Длина строк не превышает 62 клетки.

; Помощь редактора
F1T_RU DB #9,#E,#8F,#AE,#AC,#AE,#E9,#EC," ",#E0,#A5,#A4,#A0,#AA,#E2,#AE,#E0,#A0,0
; Нажмите любую клавишу для закрытия
F1B_RU DB #9,#E,#8D,#A0,#A6,#AC,#A8,#E2,#A5," ",#AB,#EE,#A1,#E3,#EE," ",#AA,#AB,#A0,#A2,#A8,#E8,#E3," ",#A4,#AB,#EF," ",#A7,#A0,#AA,#E0,#EB,#E2,#A8,#EF,0

F1A_RU
; Управление:
        DB #93,#AF,#E0,#A0,#A2,#AB,#A5,#AD,#A8,#A5,":",#D
; Esc - Выход: Y - сохранить, N - не сохранять, Esc - отмена
        DB 1,"Esc - ",#82,#EB,#E5,#AE,#A4,": Y - ",#E1,#AE,#E5,#E0,#A0,#AD,#A8,#E2,#EC,", N - ",#AD,#A5," ",#E1,#AE,#E5,#E0,#A0,#AD,#EF,#E2,#EC,", Esc - ",#AE,#E2,#AC,#A5,#AD,#A0,#D
        DB #D
; Ctrl+S - Сохранить изменения
        DB 1,"Ctrl+S - ",#91,#AE,#E5,#E0,#A0,#AD,#A8,#E2,#EC," ",#A8,#A7,#AC,#A5,#AD,#A5,#AD,#A8,#EF,#D
; Ctrl+Alt+S - Сохранить как
        DB 1,"Ctrl+Alt+S - ",#91,#AE,#E5,#E0,#A0,#AD,#A8,#E2,#EC," ",#AA,#A0,#AA,#D
; Ctrl+F - Поиск текста
        DB 1,"Ctrl+F - ",#8F,#AE,#A8,#E1,#AA," ",#E2,#A5,#AA,#E1,#E2,#A0,#D
; Ctrl+G - Искать дальше
        DB 1,"Ctrl+G - ",#88,#E1,#AA,#A0,#E2,#EC," ",#A4,#A0,#AB,#EC,#E8,#A5,#D
; Ctrl+Home / Ctrl+End - Начало / конец файла
        DB 1,"Ctrl+Home / Ctrl+End - ",#8D,#A0,#E7,#A0,#AB,#AE," / ",#AA,#AE,#AD,#A5,#E6," ",#E4,#A0,#A9,#AB,#A0,#D
; Ctrl+C / Ctrl+X / Ctrl+V - Копировать / Вырезать / Вставить
        DB 1,"Ctrl+C / Ctrl+X / Ctrl+V - ",#8A,#AE,#AF,#A8,#E0,#AE,#A2,#A0,#E2,#EC," / ",#82,#EB,#E0,#A5,#A7,#A0,#E2,#EC," / ",#82,#E1,#E2,#A0,#A2,#A8,#E2,#EC,#D
; Shift+Right/Down/PgDn/End - Расширить выделение
        DB 1,"Shift+Right/Down/PgDn/End - ",#90,#A0,#E1,#E8,#A8,#E0,#A8,#E2,#EC," ",#A2,#EB,#A4,#A5,#AB,#A5,#AD,#A8,#A5,#D
; Shift+Left/Up - Изменить выделение
        DB 1,"Shift+Left/Up - ",#88,#A7,#AC,#A5,#AD,#A8,#E2,#EC," ",#A2,#EB,#A4,#A5,#AB,#A5,#AD,#A8,#A5,#D
; Enter - Новая строка; Tab - Вставить табуляцию
        DB 1,"Enter - ",#8D,#AE,#A2,#A0,#EF," ",#E1,#E2,#E0,#AE,#AA,#A0,"; Tab - ",#82,#E1,#E2,#A0,#A2,#A8,#E2,#EC," ",#E2,#A0,#A1,#E3,#AB,#EF,#E6,#A8,#EE,#D
        DB #D
; Ctrl+Shift - Переключить русскую/английскую раскладку
        DB 1,"Ctrl+Shift - ",#8F,#A5,#E0,#A5,#AA,#AB,#EE,#E7,#A8,#E2,#EC," ",#E0,#E3,#E1,#E1,#AA,#E3,#EE,"/",#A0,#AD,#A3,#AB,#A8,#A9,#E1,#AA,#E3,#EE," ",#E0,#A0,#E1,#AA,#AB,#A0,#A4,#AA,#E3,#D
        DB #D
; Другие клавиши:
        DB #84,#E0,#E3,#A3,#A8,#A5," ",#AA,#AB,#A0,#A2,#A8,#E8,#A8,":",#D
; PgUp, PgDn, Home, End, Delete, Backspace, Insert, CapsLock
        DB 1,"PgUp, PgDn, Home, End, Delete, Backspace, Insert, CapsLock",#D
; F2 - Включить/выключить подсветку синтаксиса
        DB 1,"F2 - ",#82,#AA,#AB,#EE,#E7,#A8,#E2,#EC,"/",#A2,#EB,#AA,#AB,#EE,#E7,#A8,#E2,#EC," ",#AF,#AE,#A4,#E1,#A2,#A5,#E2,#AA,#E3," ",#E1,#A8,#AD,#E2,#A0,#AA,#E1,#A8,#E1,#A0,#D
; F3 - Инспектор / калькулятор
        DB 1,"F3 - ",#88,#AD,#E1,#AF,#A5,#AA,#E2,#AE,#E0," / ",#AA,#A0,#AB,#EC,#AA,#E3,#AB,#EF,#E2,#AE,#E0,#D
        DB 0
F1A_RU_END
