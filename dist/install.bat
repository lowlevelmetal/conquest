@echo off
rem Install the Online Galactic Conquest mod into the Battlefront Classic Collection.
rem Run this from the extracted mod folder, or pass the game folder as an argument.
rem The game cannot start without a dle_crashpad.dll, so the loader is copied
rem in full first and Aspyr's DLL is only moved aside once it can be replaced.
setlocal

set "HERE=%~dp0"
set "GAME=%~1"
if "%GAME%"=="" set "GAME=C:\Program Files (x86)\Steam\steamapps\common\Battle"
set "DLL=%GAME%\dle_crashpad.dll"
set "ORIG=%GAME%\dle_crashpad_orig.dll"

if not exist "%GAME%\Battlefront2.dll" goto notfound

rem the scripts first (replaced wholesale): without the loader the game ignores them
if exist "%GAME%\conquest\lua" rmdir /s /q "%GAME%\conquest\lua"
xcopy /e /i /y /q "%HERE%conquest" "%GAME%\conquest" >nul
if errorlevel 1 goto failed
copy /y "%HERE%dle_crashpad.dll" "%DLL%.new" >nul
if errorlevel 1 goto failed

rem Keep Aspyr's crash reporter as the forwarding target. If the current DLL is
rem Aspyr's (first install, or Steam restored it after an update) it becomes the backup.
set "MOVED="
if not exist "%DLL%" goto place
type "%DLL%" >nul 2>&1
if errorlevel 1 goto unreadable
rem the loader carries both strings (a 0.1.0 loader only the second); findstr
rem gets the bare file name because Wine's findstr cannot open quoted paths
pushd "%GAME%"
findstr /m /c:"OnlineGalacticConquestLoader" /c:"dle_crashpad_orig" dle_crashpad.dll >nul 2>&1
set "FOUND=%errorlevel%"
popd
if "%FOUND%"=="0" goto place
move /y "%DLL%" "%ORIG%" >nul
if errorlevel 1 goto failed_new
set "MOVED=1"

:place
move /y "%DLL%.new" "%DLL%" >nul
if errorlevel 1 goto restore
echo Installed. Start Battlefront II and open Multiplayer, then Galactic Conquest.
pause
exit /b 0

:restore
if defined MOVED move /y "%ORIG%" "%DLL%" >nul
:failed_new
del "%DLL%.new" >nul 2>&1
:failed
echo.
echo Installing failed. If the game is running, close it and run install.bat again.
echo Your antivirus may also have blocked the copy. The game still starts as before.
pause
exit /b 1

:unreadable
del "%DLL%.new" >nul 2>&1
echo.
echo Could not read dle_crashpad.dll in the game folder. Close the game and try again.
pause
exit /b 1

:notfound
echo Could not find the Battlefront Classic Collection in:
echo   %GAME%
echo Drag the game folder onto install.bat, or run: install.bat "D:\path\to\Battle"
echo In Steam: right-click the game, Manage, Browse local files shows the folder.
pause
exit /b 1
