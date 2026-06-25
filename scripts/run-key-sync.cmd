@echo off
setlocal
cd /d "%~dp0.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0sync-vercel-openai-key.ps1"
echo.
pause
