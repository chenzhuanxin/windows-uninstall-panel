@echo off
title Uninstall Panel - Portable Edition
rem  Panel: http://127.0.0.1:8791/   Close this window to stop.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0UninstallPanel.ps1"
if errorlevel 1 pause
