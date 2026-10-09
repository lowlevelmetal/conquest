@echo off
rem Remove the Online Galactic Conquest mod. Steam's "Verify integrity of game
rem files" also restores the original dle_crashpad.dll.
setlocal

set "GAME=%~1"
if "%GAME%"=="" set "GAME=C:\Program Files (x86)\Steam\steamapps\common\Battle"
set "DLL=%GAME%\dle_crashpad.dll"
set "ORIG=%GAME%\dle_crashpad_orig.dll"
set "VERIFY="

if not exist "%GAME%\Battlefront2.dll" goto notfound

rem Put Aspyr's DLL back, unless a game update already did (then the backup is stale).
set "LOADER="
if not exist "%DLL%" goto decided
type "%DLL%" >nul 2>&1
if errorlevel 1 goto unreadable
rem the loader carries both strings (a 0.1.0 loader only the second)
pushd "%GAME%"
findstr /m /c:"OnlineGalacticConquestLoader" /c:"dle_crashpad_orig" dle_crashpad.dll >nul 2>&1
set "FOUND=%errorlevel%"
popd
if "%FOUND%"=="0" set "LOADER=1"
:decided
if not exist "%ORIG%" goto nobackup
if not exist "%DLL%" goto restore
if defined LOADER goto restore
del "%ORIG%"
if errorlevel 1 goto failed
goto scripts
:restore
move /y "%ORIG%" "%DLL%" >nul
if errorlevel 1 goto failed
goto scripts
:nobackup
if not defined LOADER goto scripts
rem no backup to put back: remove the loader; Steam restores Aspyr's DLL
del "%DLL%"
if errorlevel 1 goto failed
set "VERIFY=1"

:scripts
if exist "%GAME%\conquest" rmdir /s /q "%GAME%\conquest"
if exist "%GAME%\conquest.log" del "%GAME%\conquest.log"
echo Removed.
if defined VERIFY echo Before playing, let Steam restore one game file: right-click the game in Steam,
if defined VERIFY echo choose Properties, Installed Files, then Verify integrity of game files.
pause
exit /b 0

:unreadable
echo Could not read dle_crashpad.dll in the game folder. Close the game and try again.
pause
exit /b 1

:failed
echo Removing failed. If the game is running, close it and try again.
pause
exit /b 1

:notfound
echo Could not find the game in:
echo   %GAME%
echo Run: uninstall.bat "D:\path\to\Battle"
pause
exit /b 1
