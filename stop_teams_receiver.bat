@echo off
rem Ask the running receiver to stop. The watchdog task will not start it again
rem until start_teams_receiver.bat is run. Keep this file ASCII only.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0teams_receiver.ps1" -Stop
pause
