@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem This script runs inside WinPE from X:\Windows\System32.
rem High-level flow:
rem 1. Find exactly one prepared install.wim source.
rem 2. Partition the target disk dynamically based on partition parameters.
rem 3. Apply the selected image to W: and make it bootable.
rem 4. Prepare the WinRE path from the applied Windows partition.
rem 5. Stage first-logon automation files and optional Docker payloads.
rem 6. Preserve the deployment log and reboot.

rem These tokens are rendered by Build-WinPEAutoDeploy.ps1 when boot.wim is customized.
rem TARGET_DISK can be 'auto' for automatic detection, or a specific disk number.
set "TARGET_DISK=__TARGET_DISK__"
set "WIM_INDEX=__WIM_INDEX__"
set "WINDOWS_PARTITION_SIZE=__WINDOWS_PARTITION_SIZE__"
set "CREATE_DRIVE_D=__CREATE_DRIVE_D__"
set "WINDOWS_PARTITION_LABEL=__WINDOWS_PARTITION_LABEL__"
set "DATA_PARTITION_LABEL=__DATA_PARTITION_LABEL__"
set "RECOVERY_SIZE=__RECOVERY_SIZE__"
set "DETECTED_DISK="

rem X: is the RAM disk used by WinPE, so it is a safe place for transient logs and runtime scripts.
set "LOG=X:\AutoDeploy.log"
set "SCRIPT_DIR=%~dp0"
set "DEPLOYED_OS_LOG=W:\Windows\Temp\AutoDeploy.log"
set "MEDIA_LOG_DIR="

rem The marker file prevents accidental use of an unrelated install.wim found on another volume.
set "SOURCE_TAG=winpe-autodeploy.tag"

rem Recovery GUID used by Windows for the final GPT recovery partition type.
set "WIM_PATH="
set "SOURCE_MEDIA_DRIVE="
set "MATCH_COUNT=0"
set "CANDIDATE_LIST=X:\wim-candidates.txt"
set "DEPLOYMENT_WARNINGS=0"

> "%LOG%" (
    echo ==================================================
    echo AutoDeploy started at %DATE% %TIME%
    echo ==================================================
)

call :log_info "Configured target disk: %TARGET_DISK%"
call :log_info "Configured WIM index: %WIM_INDEX%"

rem Resolve the target disk: either use the explicit value or auto-detect.
call :detect_target_disk
if errorlevel 1 (
    call :fail "Target disk detection failed."
    exit /b 1
)
call :log_info "Resolved target disk: %DETECTED_DISK%"

rem Source discovery is intentionally strict: zero or multiple matches both stop the deployment.
call :scan_sources

if "%MATCH_COUNT%"=="0" (
    call :fail "No prepared USB source was found. Expected \sources\install.wim and \sources\!SOURCE_TAG! on exactly one mounted volume."
    exit /b 1
)

if not "%MATCH_COUNT%"=="1" (
    call :log_info "Candidate list:"
    for /f "usebackq delims=" %%L in ("%CANDIDATE_LIST%") do call :log_info "  %%L"
    call :fail "Expected exactly one install.wim candidate, but found %MATCH_COUNT%."
    exit /b 1
)

set /p WIM_PATH=<"%CANDIDATE_LIST%"
for %%I in ("!WIM_PATH!") do set "SOURCE_MEDIA_DRIVE=%%~dI"
if defined SOURCE_MEDIA_DRIVE set "MEDIA_LOG_DIR=!SOURCE_MEDIA_DRIVE!\DeployLogs"
call :log_info "Using image file: !WIM_PATH!"

call :generate_diskpart_script
if errorlevel 1 (
    call :fail "Failed to generate DiskPart script."
    exit /b 1
)

call :log_info "Partitioning target disk %DETECTED_DISK%"
diskpart /s "%DISKPART_SCRIPT%" >> "%LOG%" 2>&1
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

call :inject_drivers
call :handle_step_result "Inject drivers"
call :stage_unattend_xml
call :handle_step_result "Stage unattend.xml"
call :configure_winre
call :handle_step_result "Configure WinRE"
call :stage_firstboot_assets
call :handle_step_result "Stage first-logon assets"

if "!DEPLOYMENT_WARNINGS!"=="1" (
    call :log_warning "Deployment completed with non-fatal warnings. Review %LOG% for details."
) else (
    call :log_info "Deployment completed successfully with no warnings."
)
call :log_info "The system will shutdown now. OOBE will start automatically on next boot."
call :persist_logs
wpeutil shutdown
exit /b 0

:generate_diskpart_script
rem Generate the DiskPart script dynamically based on partition parameters.
rem All sizes are in MB for DiskPart.
set "DISKPART_SCRIPT=X:\diskpart-runtime.txt"
call :log_info "Generating DiskPart script for disk %DETECTED_DISK%"
type nul > "%DISKPART_SCRIPT%"

rem Write DiskPart commands
>> "%DISKPART_SCRIPT%" echo select disk %DETECTED_DISK%
>> "%DISKPART_SCRIPT%" echo clean
>> "%DISKPART_SCRIPT%" echo convert gpt

rem EFI System Partition (100 MB)
>> "%DISKPART_SCRIPT%" echo create partition efi size=100
>> "%DISKPART_SCRIPT%" echo format quick fs=fat32 label="System"
>> "%DISKPART_SCRIPT%" echo assign letter=S

rem Microsoft Reserved Partition (16 MB)
>> "%DISKPART_SCRIPT%" echo create partition msr size=16

rem Windows partition
if "%WINDOWS_PARTITION_SIZE%"=="0" (
    rem Auto: Windows takes all remaining space minus Recovery
    >> "%DISKPART_SCRIPT%" echo create partition primary
    >> "%DISKPART_SCRIPT%" echo shrink minimum=%RECOVERY_SIZE%
    if not "%WINDOWS_PARTITION_LABEL%"=="" (
        >> "%DISKPART_SCRIPT%" echo format quick fs=ntfs label="%WINDOWS_PARTITION_LABEL%"
    ) else (
        >> "%DISKPART_SCRIPT%" echo format quick fs=ntfs
    )
    >> "%DISKPART_SCRIPT%" echo assign letter=W
) else (
    rem Specified: Windows partition with exact size
    set /a WIN_SIZE_MB=%WINDOWS_PARTITION_SIZE% * 1024
    >> "%DISKPART_SCRIPT%" echo create partition primary size=!WIN_SIZE_MB!
    if not "%WINDOWS_PARTITION_LABEL%"=="" (
        >> "%DISKPART_SCRIPT%" echo format quick fs=ntfs label="%WINDOWS_PARTITION_LABEL%"
    ) else (
        >> "%DISKPART_SCRIPT%" echo format quick fs=ntfs
    )
    >> "%DISKPART_SCRIPT%" echo assign letter=W

    rem Optional Data partition
    if "%CREATE_DRIVE_D%"=="1" (
        >> "%DISKPART_SCRIPT%" echo create partition primary
        >> "%DISKPART_SCRIPT%" echo shrink minimum=%RECOVERY_SIZE%
        if not "%DATA_PARTITION_LABEL%"=="" (
            >> "%DISKPART_SCRIPT%" echo format quick fs=ntfs label="%DATA_PARTITION_LABEL%"
        ) else (
            >> "%DISKPART_SCRIPT%" echo format quick fs=ntfs label="Data"
        )
    )
)

rem Recovery partition
rem When Windows size is specified and no Data partition is created, Recovery must be
rem explicitly sized. Otherwise it would consume all remaining disk space.
if "%WINDOWS_PARTITION_SIZE%"=="0" (
    rem Auto-size Windows: Recovery space already reserved via shrink
    >> "%DISKPART_SCRIPT%" echo create partition primary
) else if not "%CREATE_DRIVE_D%"=="1" (
    rem Fixed Windows size, no Data partition: explicit Recovery size
    >> "%DISKPART_SCRIPT%" echo create partition primary size=%RECOVERY_SIZE%
) else (
    rem Fixed Windows + Data partition: Recovery space already reserved via shrink on Data partition
    >> "%DISKPART_SCRIPT%" echo create partition primary
)
>> "%DISKPART_SCRIPT%" echo format quick fs=ntfs label="Recovery"
>> "%DISKPART_SCRIPT%" echo assign letter=R
>> "%DISKPART_SCRIPT%" echo set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac
>> "%DISKPART_SCRIPT%" echo gpt attributes=0x8000000000000001
>> "%DISKPART_SCRIPT%" echo exit

call :log_info "DiskPart script generated at %DISKPART_SCRIPT%"
if "%WINDOWS_PARTITION_SIZE%"=="0" (
    call :log_info "  Windows partition: use all remaining space (minus Recovery)"
) else (
    call :log_info "  Windows partition: %WINDOWS_PARTITION_SIZE% GB (fixed size)"
)
if "%CREATE_DRIVE_D%"=="1" (
    call :log_info "  Data partition: enabled (remaining space after Windows)"
) else (
    call :log_info "  Data partition: disabled"
)
call :log_info "  Recovery partition: %RECOVERY_SIZE% MB"
exit /b 0

:inject_drivers
call :log_info "Starting driver injection from X:\drivers-payload"
if not exist "X:\drivers-payload\" (
    call :log_info "No drivers payload found. Skipping driver injection."
    exit /b 0
)

call :log_info "Injecting drivers into W:\ (this may take several minutes)..."
dism /Image:W:\ /Add-Driver /Driver:"X:\drivers-payload" /Recurse >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log_warning "DISM /Add-Driver reported errors. Check %LOG% for details."
    exit /b 2
)

call :log_info "Driver injection completed successfully."
exit /b 0

:stage_unattend_xml
call :log_info "Staging unattend.xml to preconfigure OOBE language settings and skip the network page"
if not exist "W:\Windows\Panther" md "W:\Windows\Panther" >> "%LOG%" 2>&1
copy /y "!SCRIPT_DIR!unattend.xml" "W:\Windows\Panther\unattend.xml" >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log_warning "Failed to stage unattend.xml. Automatic OOBE bypass may fail."
    exit /b 2
)
call :log_info "unattend.xml staged successfully."
exit /b 0

:configure_winre
call :log_info "Setting WinRE path to W:\Windows\System32\Recovery"

"W:\Windows\System32\reagentc.exe" /Setreimage /Path W:\Windows\System32\Recovery /Target W:\Windows >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log_warning "reagentc /Setreimage failed with exit code !errorlevel!. SetupComplete will attempt to enable WinRE later."
    exit /b 2
)

call :log_info "WinRE path configured successfully using W:\Windows\System32\reagentc.exe"
exit /b 0

:stage_firstboot_assets
call :log_info "Staging first-logon automation assets"

if not exist "W:\ProgramData\FirstBoot" md W:\ProgramData\FirstBoot >> "%LOG%" 2>&1
if not exist "W:\Windows\Setup\Scripts" md W:\Windows\Setup\Scripts >> "%LOG%" 2>&1

if not exist "!SCRIPT_DIR!firstboot.ps1" (
    call :log_warning "Missing firstboot.ps1 in WinPE runtime. Docker payload import will not be available."
    exit /b 2
)

if not exist "!SCRIPT_DIR!register-firstboot.ps1" (
    call :log_warning "Missing register-firstboot.ps1 in WinPE runtime. Docker payload import will not be available."
    exit /b 2
)

if not exist "!SCRIPT_DIR!firstboot-launcher.vbs" (
    call :log_warning "Missing firstboot-launcher.vbs in WinPE runtime. Docker payload import will not be available."
    exit /b 2
)

if not exist "!SCRIPT_DIR!SetupComplete.cmd" (
    call :log_warning "Missing SetupComplete.cmd in WinPE runtime. Docker payload import will not be available."
    exit /b 2
)

copy /y "!SCRIPT_DIR!firstboot.ps1" "W:\ProgramData\FirstBoot\firstboot.ps1" >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log_warning "Failed to stage firstboot.ps1 into the deployed OS."
    exit /b 2
)

copy /y "!SCRIPT_DIR!register-firstboot.ps1" "W:\ProgramData\FirstBoot\register-firstboot.ps1" >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log_warning "Failed to stage register-firstboot.ps1 into the deployed OS."
    exit /b 2
)

copy /y "!SCRIPT_DIR!firstboot-launcher.vbs" "W:\ProgramData\FirstBoot\firstboot-launcher.vbs" >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log_warning "Failed to stage firstboot-launcher.vbs into the deployed OS."
    exit /b 2
)

copy /y "!SCRIPT_DIR!SetupComplete.cmd" "W:\Windows\Setup\Scripts\SetupComplete.cmd" >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log_warning "Failed to stage SetupComplete.cmd into the deployed OS."
    exit /b 2
)

call :stage_docker_payloads
if errorlevel 2 exit /b 2
exit /b 0

:stage_docker_payloads
if not defined SOURCE_MEDIA_DRIVE (
    call :log_warning "Source media drive was not captured. Skipping payload staging."
    exit /b 2
)

set "DOCKER_PAYLOAD_SOURCE=!SOURCE_MEDIA_DRIVE!\payload\docker-images"
if not exist "!DOCKER_PAYLOAD_SOURCE!" (
    call :log_info "No payload directory found on deployment media at \payload\docker-images."
    exit /b 0
)

call :log_info "Copying payloads from !DOCKER_PAYLOAD_SOURCE! to W:\Payload\DockerImages"
if not exist "W:\Payload\DockerImages" md W:\Payload\DockerImages >> "%LOG%" 2>&1
xcopy /E /I /Y "!DOCKER_PAYLOAD_SOURCE!\*" "W:\Payload\DockerImages\" >> "%LOG%" 2>&1
if errorlevel 1 (
    call :log_warning "Failed to copy payload files into the deployed OS."
    exit /b 2
)

call :log_info "Payloads staged successfully."
exit /b 0

:persist_logs
rem Preserve the WinPE RAM-disk log anywhere durable that is currently available.
if exist "W:\Windows" (
    if not exist "W:\Windows\Temp" md W:\Windows\Temp >nul 2>&1
    copy /y "%LOG%" "!DEPLOYED_OS_LOG!" >nul 2>&1
)

if defined MEDIA_LOG_DIR (
    if not exist "!MEDIA_LOG_DIR!" md "!MEDIA_LOG_DIR!" >nul 2>&1
    copy /y "%LOG%" "!MEDIA_LOG_DIR!\AutoDeploy.log" >nul 2>&1
)
exit /b 0

:detect_target_disk
rem Resolve the target disk number for deployment.
rem TARGET_DISK='auto' → use the first disk (disk 0)
rem TARGET_DISK=<number> → use the specified disk
call :log_info "Resolving target disk..."

if /i "%TARGET_DISK%"=="auto" (
    call :log_info "Auto mode: selecting the first disk (disk 0)."
    set "DETECTED_DISK=0"
) else (
    call :log_info "Explicit mode: using disk %TARGET_DISK%."
    set "DETECTED_DISK=%TARGET_DISK%"
)

call :log_info "Target disk resolved: %DETECTED_DISK%"
exit /b 0

:scan_sources
call :log_info "Scanning C: through Z: for \sources\install.wim on prepared USB data volumes"
set "WIM_PATH="
set "SOURCE_MEDIA_DRIVE="
set "MEDIA_LOG_DIR="
set "MATCH_COUNT=0"
type nul > "%CANDIDATE_LIST%"

rem WinPE drive letters are not stable across hardware, so scan a range instead of hard-coding one letter.
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\sources\install.wim" if exist "%%D:\sources\!SOURCE_TAG!" (
        set /a MATCH_COUNT+=1
        >> "%CANDIDATE_LIST%" echo %%D:\sources\install.wim
        call :log_info "Found candidate !MATCH_COUNT!: %%D:\sources\install.wim"
    )
)
exit /b 0

:handle_step_result
if errorlevel 2 (
    set "DEPLOYMENT_WARNINGS=1"
    call :log_warning "%~1 completed with non-fatal warnings."
    exit /b 0
)
if errorlevel 1 (
    call :fail "%~1 failed unexpectedly."
    exit /b 1
)
call :log_info "%~1 completed successfully."
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
call :persist_logs
echo.
echo ERROR: %~1
echo See %LOG% for details.
pause
exit /b 1
