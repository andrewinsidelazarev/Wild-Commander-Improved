@echo off
setlocal
if defined SDCC set "PATH=%SDCC%\bin;%PATH%"
python "%~dp0build.py"
if errorlevel 1 exit /b 1
python "%~dp0tests\test_ftview.py"
if errorlevel 1 exit /b 1
python "%~dp0tests\test_gs.py"
if errorlevel 1 exit /b 1
copy /b "%~dp0obj\FTVIEW.WMF" "%~dp0ftview.wmf" >nul
if errorlevel 1 exit /b 1
