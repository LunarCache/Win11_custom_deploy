@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
title 10-win11-install Image Import

set "TAR_FILE=image_test.tar"
set "PAYLOAD_LOG=%~1"

cd /d "%~dp0"

call :log ==================================================
call :log Docker image import tool
call :log ==================================================
call :log [NOTICE] This window is part of first-boot deployment.
call :log [NOTICE] Do not close it unless you want to interrupt the current payload step.
call :append_log [INFO] Working directory: %~dp0

call :log [1/2] Verifying %TAR_FILE%...
if not exist "%TAR_FILE%" (
    call :log [ERROR] Cannot find %TAR_FILE% in %~dp0
    exit /b 1
)

call :log [2/2] Importing Docker images from %TAR_FILE%...
call :run_and_log docker load -i "%TAR_FILE%"
if errorlevel 1 (
    call :log [ERROR] docker load failed. Confirm Docker Desktop is running and the tar file is valid.
    exit /b 1
)

call :append_log [INFO] Docker image import completed successfully.
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

:run_and_log
if defined PAYLOAD_LOG (
    >> "%PAYLOAD_LOG%" echo [COMMAND] %*
    >> "%PAYLOAD_LOG%" 2>&1 %*
) else (
    %*
)
exit /b %ERRORLEVEL%
