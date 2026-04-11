@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem This script runs inside WinPE from X:\Windows\System32.
rem High-level flow:
rem 1. Find exactly one prepared install.wim source.
rem 2. Partition the target disk according to diskpart-uefi.txt.
rem 3. Apply the selected image to W: and make it bootable.
rem 4. If embedded WinRE exists, copy it into the Recovery partition and register it.
rem 5. Finalize Recovery partition metadata so Windows treats it as a hidden recovery volume.

rem These tokens are rendered by Build-WinPEAutoDeploy.ps1 when boot.wim is customized.
set "TARGET_DISK=__TARGET_DISK__"
set "WIM_INDEX=__WIM_INDEX__"

rem X: is the RAM disk used by WinPE, so it is a safe place for transient logs and runtime scripts.
set "LOG=X:\AutoDeploy.log"
set "SCRIPT_DIR=%~dp0"

rem The marker file prevents accidental use of an unrelated install.wim found on another volume.
set "SOURCE_TAG=winpe-autodeploy.tag"

rem Recovery GUID used by Windows for the final GPT recovery partition type.
set "RECOVERY_GUID=de94bba4-06d1-4d40-a16a-bfd50179d6ac"
set "WIM_PATH="
set "MATCH_COUNT=0"

> "%LOG%" (
    echo ==================================================
    echo AutoDeploy started at %DATE% %TIME%
    echo ==================================================
)

call :log_info "Configured target disk: %TARGET_DISK%"
call :log_info "Configured WIM index: %WIM_INDEX%"

rem Source discovery is intentionally strict: zero or multiple matches both stop the deployment.
call :scan_sources

if "%MATCH_COUNT%"=="0" (
    call :fail "No prepared USB source was found. Expected \sources\install.wim and \sources\!SOURCE_TAG! on exactly one mounted volume."
    exit /b 1
)

if not "%MATCH_COUNT%"=="1" (
    call :log_info "Candidate list:"
    for /L %%I in (1,1,%MATCH_COUNT%) do call :log_info "  %%I. !WIM_CANDIDATE_%%I!"
    call :fail "Expected exactly one install.wim candidate, but found %MATCH_COUNT%."
    exit /b 1
)

set "WIM_PATH=!WIM_CANDIDATE_1!"
call :log_info "Using image file: !WIM_PATH!"

if not exist "!SCRIPT_DIR!diskpart-uefi.txt" (
    call :fail "Missing DiskPart template at !SCRIPT_DIR!diskpart-uefi.txt"
    exit /b 1
)

set "RUNTIME_DISKPART=X:\diskpart-runtime.txt"
call :log_info "Rendering runtime DiskPart script at !RUNTIME_DISKPART!"
> "!RUNTIME_DISKPART!" (
    rem Replace the target-disk token at runtime so the static template stays reusable.
    for /f "usebackq delims=" %%L in ("!SCRIPT_DIR!diskpart-uefi.txt") do (
        set "LINE=%%L"
        setlocal EnableDelayedExpansion
        set "LINE=!LINE:__TARGET_DISK__=%TARGET_DISK%!"
        echo(!LINE!
        endlocal
    )
)
if errorlevel 1 (
    call :fail "Failed to write runtime DiskPart script to !RUNTIME_DISKPART!"
    exit /b 1
)

call :log_info "Partitioning target disk"
diskpart /s "!RUNTIME_DISKPART!" >> "%LOG%" 2>&1
if errorlevel 1 (
    call :fail "DiskPart failed. Review %LOG%."
    exit /b 1
)

if not exist "W:\" (
    call :fail "Windows partition W: was not created."
    exit /b 1
)

if not exist "S:\" (
    call :fail "EFI partition S: was not created."
    exit /b 1
)

if not exist "R:\" (
    call :fail "Recovery partition R: was not created."
    exit /b 1
)

rem Apply the chosen Windows image onto the main OS partition.
call :log_info "Applying image to W:\"
dism /Apply-Image /ImageFile:"!WIM_PATH!" /Index:%WIM_INDEX% /ApplyDir:W:\ >> "%LOG%" 2>&1
if errorlevel 1 (
    call :fail "DISM apply failed. Review %LOG%."
    exit /b 1
)

if not exist "W:\Windows" (
    call :fail "Applied image does not contain W:\Windows."
    exit /b 1
)

rem bcdboot writes the firmware boot files into the EFI System Partition.
call :log_info "Writing UEFI boot files"
bcdboot W:\Windows /s S: /f UEFI >> "%LOG%" 2>&1
if errorlevel 1 (
    call :fail "BCDBoot failed. Review %LOG%."
    exit /b 1
)

call :configure_winre

rem Only after the copy is finished do we hide/tag the Recovery partition as a real Windows recovery volume.
call :finalize_recovery_partition

call :log_info "Deployment completed successfully. The system will reboot in 5 seconds."
timeout /t 5 >nul
wpeutil reboot
exit /b 0

:configure_winre
if not exist "W:\Windows\System32\Recovery\Winre.wim" (
    rem Missing WinRE should not block the base OS deployment.
    call :log_warning "Embedded WinRE was not found at W:\Windows\System32\Recovery\Winre.wim. Skipping WinRE configuration."
    exit /b 0
)

call :log_info "Configuring WinRE from W:\Windows\System32\Recovery\Winre.wim"
md R:\Recovery\WindowsRE >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log_warning "Failed to create R:\Recovery\WindowsRE. WinRE will remain disabled."
    exit /b 0
)

copy /y "W:\Windows\System32\Recovery\Winre.wim" "R:\Recovery\WindowsRE\Winre.wim" >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log_warning "Failed to copy Winre.wim to the recovery partition. WinRE will remain disabled."
    exit /b 0
)

reagentc /Setreimage /Path R:\Recovery\WindowsRE /Target W:\Windows >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log_warning "reagentc /Setreimage failed. WinRE will remain disabled."
    exit /b 0
)

reagentc /Enable /Target W:\Windows >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log_warning "reagentc /Enable failed. WinRE will remain disabled."
    exit /b 0
)

call :log_info "WinRE configured successfully."
exit /b 0

:finalize_recovery_partition
set "RECOVERY_DISKPART=X:\diskpart-recovery-finalize.txt"
call :log_info "Finalizing recovery partition metadata"
> "!RECOVERY_DISKPART!" (
    rem Partition 4 is the Recovery partition created by diskpart-uefi.txt.
    echo select disk %TARGET_DISK%
    echo select partition 4
    echo set id=%RECOVERY_GUID%
    echo gpt attributes=0x8000000000000001
    rem Remove the drive letter so the deployed OS sees it as a hidden recovery partition, not a normal data volume.
    echo remove letter=R noerr
    echo exit
)

diskpart /s "!RECOVERY_DISKPART!" >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log_warning "Failed to finalize the recovery partition metadata."
    exit /b 0
)

call :log_info "Recovery partition metadata finalized."
exit /b 0

:scan_sources
call :log_info "Scanning C: through Z: for \sources\install.wim on prepared USB data volumes"
set "WIM_PATH="
set "MATCH_COUNT=0"
for /L %%I in (1,1,25) do set "WIM_CANDIDATE_%%I="

rem WinPE drive letters are not stable across hardware, so scan a range instead of hard-coding one letter.
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\sources\install.wim" if exist "%%D:\sources\!SOURCE_TAG!" (
        set /a MATCH_COUNT+=1
        set "WIM_CANDIDATE_!MATCH_COUNT!=%%D:\sources\install.wim"
        call :log_info "Found candidate !MATCH_COUNT!: %%D:\sources\install.wim"
    )
)
exit /b 0

:log_info
call :log_line INFO "%~1"
exit /b 0

:log_warning
call :log_line WARNING "%~1"
exit /b 0

:log_error
call :log_line ERROR "%~1"
exit /b 0

:log_line
echo [%DATE% %TIME%] [%~1] %~2
>> "%LOG%" echo [%DATE% %TIME%] [%~1] %~2
exit /b 0

:fail
call :log_error "%~1"
echo.
echo ERROR: %~1
echo See %LOG% for details.
pause
exit /b 1
