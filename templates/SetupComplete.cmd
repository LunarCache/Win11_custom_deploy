@echo off
setlocal EnableExtensions

rem SetupComplete.cmd runs near the end of mini-setup/OOBE preparation.
rem We use it to enable WinRE inside the deployed OS and then register the
rem first-logon Docker payload importer.

set "FIRSTBOOT_DIR=C:\ProgramData\FirstBoot"
set "LOG=%FIRSTBOOT_DIR%\setupcomplete.log"

if not exist "%FIRSTBOOT_DIR%" md "%FIRSTBOOT_DIR%"

>> "%LOG%" echo [%DATE% %TIME%] [INFO] SetupComplete started.

reagentc /enable >> "%LOG%" 2>&1
if errorlevel 1 (
    >> "%LOG%" echo [%DATE% %TIME%] [WARNING] WinRE enable failed during SetupComplete.
) else (
    >> "%LOG%" echo [%DATE% %TIME%] [INFO] WinRE enable completed successfully.
)

if not exist "%FIRSTBOOT_DIR%\register-firstboot.ps1" (
    >> "%LOG%" echo [%DATE% %TIME%] [WARNING] register-firstboot.ps1 was not found. Skipping first-logon registration.
    exit /b 0
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%FIRSTBOOT_DIR%\register-firstboot.ps1" >> "%LOG%" 2>&1
if errorlevel 1 (
    >> "%LOG%" echo [%DATE% %TIME%] [WARNING] First-logon registration failed.
    exit /b 0
)

>> "%LOG%" echo [%DATE% %TIME%] [INFO] First-logon registration completed successfully.
exit /b 0
