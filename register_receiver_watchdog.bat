@echo off
rem Register two Windows tasks: receiver watchdog (every 10 minutes) and receiver autostart at logon.
rem Keep this file ASCII only.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0e3_monitor_native.ps1" -RegisterReceiverWatchdog
pause
