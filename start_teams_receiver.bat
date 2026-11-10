@echo off
chcp 65001 >nul
title Teams Command Receiver
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0teams_receiver.ps1" -Listen -Continuous
pause
 