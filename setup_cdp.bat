@echo off
rem CDP background delivery: sign in to Teams web in the dedicated Edge profile and check targets.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0e3_monitor_native.ps1" -CdpSetup
