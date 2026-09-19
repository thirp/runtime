@echo off
setlocal
cd /d "%~dp0\.."
echo ci_build_windows: cwd=%CD%
call "%~1"
if errorlevel 1 exit /b 1
where openssl
where odin
call scripts\build_windows.bat dataplane
exit /b %ERRORLEVEL%
