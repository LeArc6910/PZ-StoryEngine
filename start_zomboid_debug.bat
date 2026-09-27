@echo off
rem Starts Project Zomboid in debug mode (-debug): debug menu, Lua errors shown on screen,
rem and the StoryEngine debug options in the right-click menu.
rem Steam must be running. Usage: double-click, or "start_zomboid_debug.bat --check" to only print the game path.

setlocal
set "GAME_DIR="
for %%D in (
    "E:\SteamLibrary\steamapps\common\ProjectZomboid"
    "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid"
    "D:\SteamLibrary\steamapps\common\ProjectZomboid"
) do (
    if not defined GAME_DIR if exist "%%~D\ProjectZomboid64.exe" set "GAME_DIR=%%~D"
)
if not defined GAME_DIR goto no_game

if /i "%~1"=="--check" (
    echo Game found: %GAME_DIR%
    exit /b 0
)

tasklist /FI "IMAGENAME eq ProjectZomboid64.exe" 2>nul | find /i "ProjectZomboid64.exe" >nul
if not errorlevel 1 goto already_running

tasklist /FI "IMAGENAME eq steam.exe" 2>nul | find /i "steam.exe" >nul
if errorlevel 1 echo [WARN] Steam does not seem to be running. Start Steam first if the game fails to launch.

echo Starting Project Zomboid in debug mode...
start "" /d "%GAME_DIR%" "%GAME_DIR%\ProjectZomboid64.exe" -debug
exit /b 0

:no_game
echo [ERROR] ProjectZomboid64.exe was not found. Edit GAME_DIR paths at the top of this file.
pause
exit /b 1

:already_running
echo [ERROR] Project Zomboid is already running. Close it first.
pause
exit /b 1
