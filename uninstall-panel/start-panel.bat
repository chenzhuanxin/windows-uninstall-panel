@echo off
setlocal
title Uninstall Panel
cd /d "%~dp0"

rem --- require admin (deep uninstall needs it) ---
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "PY=C:\Python314\python.exe"
if not exist "%PY%" set "PY=python"

echo ==========================================
echo   Uninstall Panel  /  http://127.0.0.1:8791/
echo   Close this window to stop the panel.
echo ==========================================
echo.

start "uninstall-panel-server" /min "%PY%" "%~dp0server.py"
timeout /t 3 /nobreak >nul

for /f "delims=" %%u in ('powershell -NoProfile -Command "try { (Get-Content -Raw '%~dp0panel.info.json' ^| ConvertFrom-Json).url } catch { '' }"') do set "URL=%%u"
if defined URL ( start "" "%URL%" ) else ( start "" "http://127.0.0.1:8791/" )

echo Panel is running. This window can stay minimized.
timeout /t 3 /nobreak >nul
