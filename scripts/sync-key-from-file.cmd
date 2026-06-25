@echo off
setlocal
cd /d "%~dp0"
echo Put your key in OPENAI_API_KEY.local.txt first.
echo Running sync. Full log: %~dp0sync-key-last.log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-key-from-file.ps1"
echo.
echo Exit code: %ERRORLEVEL%
echo.
type "%~dp0sync-key-last.log"
echo.
pause
