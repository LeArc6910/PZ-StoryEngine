@echo off
rem StoryEngine: copy the mod from the repo into the Steam Workshop upload folder.
rem Run this before uploading an update from the in-game Workshop screen.
rem The copy gets the release id (StoryEngine); the repo keeps the dev id (StoryEngineDev).
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
  pause
  exit /b 1
)
rem The repo copy is the development build (id=StoryEngineDev, name "... [DEV]").
rem Turn the uploaded copy back into the release mod (id=StoryEngine).
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f = Join-Path $env:USERPROFILE 'Zomboid\Workshop\StoryEngine\Contents\mods\StoryEngine\42\mod.info'; (Get-Content -LiteralPath $f) -replace '^id=.*$', 'id=StoryEngine' -replace '^name=.*$', 'name=AI Story Engine' | Set-Content -LiteralPath $f -Encoding ASCII; Get-Content -LiteralPath $f | Select-String '^(id|name)='"
if %ERRORLEVEL% NEQ 0 (
  echo Could not set the release id in mod.info. Do not upload.
  pause
  exit /b 1
)
echo Copied to %DST% as the release build.
pause
