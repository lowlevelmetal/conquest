@echo off
rem Remove the Online Galactic Conquest mod. Steam's "Verify integrity of game
rem files" also restores the original dle_crashpad.dll.
setlocal

set "GAME=%~1"
if "%GAME%"=="" set "GAME=C:\Program Files (x86)\Steam\steamapps\common\Battle"

if not exist "%GAME%\Battlefront2.dll" (
	echo Could not find the game in: %GAME%
	echo Run: uninstall.bat "D:\path\to\Battle"
	pause
	exit /b 1
)

if exist "%GAME%\dle_crashpad_orig.dll" move /y "%GAME%\dle_crashpad_orig.dll" "%GAME%\dle_crashpad.dll" >nul
if exist "%GAME%\conquest" rmdir /s /q "%GAME%\conquest"
if exist "%GAME%\conquest.log" del "%GAME%\conquest.log"

echo Removed.
pause
