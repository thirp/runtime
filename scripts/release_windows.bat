@echo off
REM Thin wrapper: Windows data-plane release packaging lives in release_windows.ps1.
setlocal
cd /d "%~dp0\.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0release_windows.ps1" %*
exit /b %ERRORLEVEL%
