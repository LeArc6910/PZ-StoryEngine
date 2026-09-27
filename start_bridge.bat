@echo off
rem StoryEngine bridge launcher.
rem Opens a console window that shows the bridge log. Press Ctrl+C or close the window to stop it.
rem Extra arguments are passed to bridge.py (start_bridge_mock.bat passes --mock).

setlocal
set "MOCK="
echo %* | find /i "--mock" >nul && set "MOCK=1"
if defined MOCK (title StoryEngine Bridge - mock) else (title StoryEngine Bridge)
chcp 65001 >nul
cd /d "%~dp0"
set PYTHONIOENCODING=utf-8
set PYTHONUTF8=1

set "PY="
where python >nul 2>nul && set "PY=python"
if not defined PY where py >nul 2>nul && set "PY=py -3"
if not defined PY goto no_python

powershell -NoProfile -Command "if (Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object { $_.CommandLine -like '*bridge.py*' }) { exit 1 }"
if errorlevel 1 goto already_running

if not exist "bridge\config.toml" goto no_config

if not defined MOCK if not defined OPENAI_API_KEY echo [WARN] OPENAI_API_KEY is not set. Real AI calls will fail. Run setx, then open a new window.

echo ============================================================
if defined MOCK (echo  StoryEngine bridge - MOCK mode, no API calls) else (echo  StoryEngine bridge)
echo  Press Ctrl+C or close this window to stop the bridge.
echo ============================================================
%PY% -u bridge\bridge.py --config bridge\config.toml %*
echo.
echo Bridge stopped.
pause
exit /b 0

:no_python
echo [ERROR] Python was not found. Install Python 3.11 or newer and try again.
pause
exit /b 1

:already_running
echo [ERROR] Another StoryEngine bridge is already running. Close its window first.
pause
exit /b 1

:no_config
echo [ERROR] bridge\config.toml was not found. Copy bridge\config.example.toml to bridge\config.toml and edit it.
pause
exit /b 1
