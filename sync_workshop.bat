@echo off
rem StoryEngine: copy the mod from the repo into the Steam Workshop upload folder.
rem Run this before uploading an update from the in-game Workshop screen.
setlocal
set SRC=%~dp0mod\StoryEngine
set DST=%USERPROFILE%\Zomboid\Workshop\StoryEngine\Contents\mods\StoryEngine
if not exist "%SRC%\42\mod.info" (
  echo Mod folder not found: %SRC%
  pause
  exit /b 1
)
robocopy "%SRC%" "%DST%" /MIR /NFL /NDL /NJH /NJS /NP
if %ERRORLEVEL% GEQ 8 (
  echo Copy failed.
) else (
  echo Copied to %DST%
)
pause
