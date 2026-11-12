@echo off
chcp 65001 >nul
title Teams Command Receiver
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0teams_receiver.ps1" -Listen -Continuous
rem When the receiver ends with an error, check the program files for transfer damage and say which file.
if errorlevel 1 if exist "%~dp0tools\check_files.ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\check_files.ps1"
pause
