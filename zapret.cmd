@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0zapret-panel.ps1"
if errorlevel 1 pause
