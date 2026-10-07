@echo off
rem Install the Online Galactic Conquest mod into the Battlefront Classic Collection.
rem Run this from the extracted mod folder, or pass the game folder as an argument.
setlocal

set "HERE=%~dp0"
set "GAME=%~1"
if "%GAME%"=="" set "GAME=C:\Program Files (x86)\Steam\steamapps\common\Battle"

if not exist "%GAME%\Battlefront2.dll" (
	echo Could not find the Battlefront Classic Collection in:
	echo   %GAME%
	echo Drag the game folder onto install.bat, or run: install.bat "D:\path\to\Battle"
	echo In Steam: right-click the game, Manage, Browse local files shows the folder.
	pause
	exit /b 1
)

rem Keep Aspyr's crash reporter as the forwarding target. If the current DLL is
rem Aspyr's (first install, or Steam restored it after an update) it becomes the backup.
findstr /m "dle_crashpad_orig" "%GAME%\dle_crashpad.dll" >nul 2>&1
if errorlevel 1 (
	move /y "%GAME%\dle_crashpad.dll" "%GAME%\dle_crashpad_orig.dll" >nul
)
copy /y "%HERE%dle_crashpad.dll" "%GAME%\dle_crashpad.dll" >nul
xcopy /e /i /y /q "%HERE%conquest" "%GAME%\conquest" >nul

echo Installed. Start Battlefront II and open Multiplayer, then Galactic Conquest.
pause
