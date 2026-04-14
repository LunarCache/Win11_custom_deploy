@echo off
setlocal EnableExtensions

rem SetupComplete.cmd runs near the end of mini-setup/OOBE preparation.
rem We use it to enable WinRE inside the deployed OS and then register the
rem first-logon Docker payload importer.

set "FIRSTBOOT_DIR=C:\ProgramData\FirstBoot"
set "LOG=%FIRSTBOOT_DIR%\setupcomplete.log"
set "TIMING_HELPER=%FIRSTBOOT_DIR%\Update-InstallTiming.ps1"
set "TIMING_FILE=%FIRSTBOOT_DIR%\install-timing.json"

if not exist "%FIRSTBOOT_DIR%" md "%FIRSTBOOT_DIR%"

>> "%LOG%" echo [%DATE% %TIME%] [INFO] SetupComplete started.
if exist "%TIMING_HELPER%" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%TIMING_HELPER%" -TimingFilePath "%TIMING_FILE%" -Phase setup_complete -Event Start >> "%LOG%" 2>&1

reagentc /enable >> "%LOG%" 2>&1
if errorlevel 1 (
    >> "%LOG%" echo [%DATE% %TIME%] [WARNING] WinRE enable failed during SetupComplete.
) else (
    >> "%LOG%" echo [%DATE% %TIME%] [INFO] WinRE enable completed successfully.
)

if not exist "%FIRSTBOOT_DIR%\register-firstboot.ps1" (
    >> "%LOG%" echo [%DATE% %TIME%] [WARNING] register-firstboot.ps1 was not found. Skipping first-logon registration.
    if exist "%TIMING_HELPER%" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%TIMING_HELPER%" -TimingFilePath "%TIMING_FILE%" -Phase setup_complete -Event Complete -Status warning >> "%LOG%" 2>&1
    exit /b 0
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%FIRSTBOOT_DIR%\register-firstboot.ps1" >> "%LOG%" 2>&1
if errorlevel 1 (
    >> "%LOG%" echo [%DATE% %TIME%] [WARNING] First-logon registration failed.
    if exist "%TIMING_HELPER%" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%TIMING_HELPER%" -TimingFilePath "%TIMING_FILE%" -Phase setup_complete -Event Complete -Status warning >> "%LOG%" 2>&1
    exit /b 0
)

>> "%LOG%" echo [%DATE% %TIME%] [INFO] First-logon registration completed successfully.
if exist "%TIMING_HELPER%" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%TIMING_HELPER%" -TimingFilePath "%TIMING_FILE%" -Phase setup_complete -Event Complete -Status success >> "%LOG%" 2>&1
exit /b 0
