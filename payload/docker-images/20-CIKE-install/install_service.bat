@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1
title 20-CIKE-install Service Setup

set "SCRIPT_DIR=%~dp0"
set "CIKE_DIR=C:\CIKE"
set "TARGET_DOCKER_DIR=C:\CIKE\docker"
set "PAYLOAD_LOG=%~1"

call :log ==================================================
call :log CIKE Docker service deploy tool
call :log ==================================================
call :log [NOTICE] This window is part of first-boot deployment.
call :log [NOTICE] Do not close it unless you want to interrupt the current payload step.
call :append_log [INFO] Working directory: %SCRIPT_DIR%

call :log [1/5] Verifying Docker state...
where docker >nul 2>&1
if errorlevel 1 (
    call :log [ERROR] Docker is not installed.
    call :show_error_window Docker is not installed.
    exit /b 1
)

docker info >nul 2>&1
if errorlevel 1 (
    call :log [ERROR] Docker is not running.
    call :show_error_window Docker is not running.
    exit /b 1
)

call :log [2/5] Ensuring target directory exists...
if not exist "%CIKE_DIR%" mkdir "%CIKE_DIR%"
if errorlevel 1 (
    call :log [ERROR] Failed to create %CIKE_DIR%.
    call :show_error_window Failed to create %CIKE_DIR%.
    exit /b 1
)

call :log [3/5] Copying payload files to %CIKE_DIR% while excluding image...
robocopy "%SCRIPT_DIR%\" "%CIKE_DIR%" /E /XD "image" /R:0 /W:0 /NFL /NDL /NJH /NJS /NC /NS >nul
if errorlevel 8 (
    call :log [ERROR] File copy failed.
    call :show_error_window File copy failed. See the payload log for details.
    exit /b 1
)
call :append_log [INFO] Payload files copied successfully.

call :log [4/5] Stopping existing CIKE containers...
if not exist "%TARGET_DOCKER_DIR%" (
    call :log [ERROR] Docker directory was not found after copy: %TARGET_DOCKER_DIR%
    call :show_error_window Docker directory was not found after copy: %TARGET_DOCKER_DIR%
    exit /b 1
)

pushd "%TARGET_DOCKER_DIR%" >nul
if errorlevel 1 (
    call :log [ERROR] Failed to enter %TARGET_DOCKER_DIR%.
    call :show_error_window Failed to enter %TARGET_DOCKER_DIR%.
    exit /b 1
)

call :run_and_log docker compose down -v --remove-orphans
if errorlevel 1 (
    call :append_log [WARNING] docker compose down returned a non-zero exit code. Continuing with deployment.
)

call :log [5/5] Starting CIKE services...
call :run_and_log docker compose up -d
if errorlevel 1 (
    popd >nul
    call :log [ERROR] docker compose up -d failed.
    call :show_error_window docker compose up -d failed. See the payload log for details.
    exit /b 1
)

popd >nul
call :append_log [INFO] CIKE deployment completed successfully.
call :append_log [INFO] CIKE Web: http://localhost:980
call :append_log [INFO] CIKE Admin Web: http://localhost:980/admin
call :append_log [INFO] CIKE Admin Account: admin@cloud.ai / admin
exit /b 0

:log
echo %*
call :append_log %*
exit /b 0

:append_log
if defined PAYLOAD_LOG (
    >> "%PAYLOAD_LOG%" echo %*
)
exit /b 0

:show_error_window
start "CIKE Setup Error" cmd /k "title CIKE Setup Error && echo ================================================== && echo. && echo    CIKE deployment failed. && echo    %* && echo. && echo    Review the payload log for details. && echo ================================================== && pause"
exit /b 0

:run_and_log
if defined PAYLOAD_LOG (
    >> "%PAYLOAD_LOG%" echo [COMMAND] %*
    >> "%PAYLOAD_LOG%" 2>&1 %*
) else (
    %*
)
exit /b %ERRORLEVEL%
