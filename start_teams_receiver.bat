@echo off
chcp 65001 >nul
title Teams Command Receiver
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0teams_receiver.ps1" -Listen -Continuous
rem A normal stop (stop request from the settings page or stop_teams_receiver.bat) closes this window.
if not errorlevel 1 exit /b 0
rem The receiver ended with an error: check the program files for transfer damage, say which file, and keep the window open.
if exist "%~dp0tools\check_files.ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\check_files.ps1"
pause
