@echo off
rem Start the E3 calibrator local service and open it in the browser. Keep this window open while using it.
rem Keep this file ASCII only: cmd misreads non-ASCII lines after chcp 65001.
chcp 65001 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0e3_monitor_native.ps1" -Calibrator
if %errorlevel% neq 0 pause
