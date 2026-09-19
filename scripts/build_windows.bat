echo ENTERED_BUILD_WINDOWS
@echo on
REM Build Windows binaries for thirp-runtime.
REM   scripts\build_windows.bat            all CLIs + libthirp.dll (local convenience)
REM   scripts\build_windows.bat dataplane  agent, caller, libthirp.dll only
setlocal enabledelayedexpansion

cd /d "%~dp0\.."
set ROOT=%CD%

set MODE=all
if /i "%~1"=="dataplane" set MODE=dataplane
if not "%~1"=="" if /i not "%~1"=="dataplane" (
    echo build_windows: unknown mode: %~1 (use all or dataplane) >&2
    exit /b 1
)

if not exist VERSION.txt (
    echo Error: VERSION.txt is missing >&2
    exit /b 1
)

set /p VERSION=<VERSION.txt

for /f "tokens=*" %%i in ('git rev-parse HEAD 2^>nul') do set COMMIT=%%i
if "!COMMIT!"=="" set COMMIT=unknown

echo Building thirp-runtime %VERSION% for Windows (%MODE%)...

where odin
if errorlevel 1 (
    echo Error: odin compiler not found. Install from https://odin-lang.org/ >&2
    exit /b 1
)

where openssl
if errorlevel 1 (
    echo Error: OpenSSL not found. Install OpenSSL 3 for Windows >&2
    echo See: https://wiki.openssl.org/index.php/Binaries >&2
    echo PATH=%PATH% >&2
    exit /b 1
)

set OUT=%ROOT%\dist\thirp-runtime-windows-%VERSION%
if exist "%OUT%" rd /s /q "%OUT%"
mkdir "%OUT%"

echo Building binaries...
if /i "%MODE%"=="all" (
    odin build broker_cli -out:"%OUT%\thirp-broker.exe" -define:THIRP_COMMIT="\"%COMMIT%\""
    if errorlevel 1 exit /b 1
    odin build web_ingress_cli -out:"%OUT%\thirp-web-ingress.exe" -define:THIRP_COMMIT="\"%COMMIT%\""
    if errorlevel 1 exit /b 1
)
odin build agent_cli -out:"%OUT%\thirp-agent.exe" -define:THIRP_COMMIT="\"%COMMIT%\""
if errorlevel 1 exit /b 1
odin build caller_cli -out:"%OUT%\thirp-connect.exe" -define:THIRP_COMMIT="\"%COMMIT%\""
if errorlevel 1 exit /b 1
odin build c_abi -build-mode:shared -out:"%OUT%\libthirp.dll"
if errorlevel 1 exit /b 1

copy "%ROOT%\c_abi\thirp.h" "%OUT%\thirp.h"
copy "%ROOT%\LICENSE" "%OUT%\LICENSE"
copy "%ROOT%\NOTICE" "%OUT%\NOTICE"

echo.
echo Windows binaries built in %OUT%
echo.
if /i "%MODE%"=="all" (
    "%OUT%\thirp-broker.exe" --version
) else (
    "%OUT%\thirp-agent.exe" --version
    "%OUT%\thirp-connect.exe" --version
)
