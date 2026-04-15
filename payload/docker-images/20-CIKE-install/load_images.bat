@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1
title 20-CIKE-install Image Import

set "PAYLOAD_LOG=%~1"
set "IMAGE_DIR=%~dp0image"

call :log ==================================================
call :log CIKE Docker image import tool
call :log ==================================================
call :log [NOTICE] This window is part of first-boot deployment.
call :log [NOTICE] Do not close it unless you want to interrupt the current payload step.
call :append_log [INFO] Working directory: %~dp0
call :append_log [INFO] Image directory: %IMAGE_DIR%

call :log [1/3] Verifying Docker state...
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

call :log [2/3] Verifying image archives...
if not exist "%IMAGE_DIR%" (
    call :log [ERROR] Image directory was not found: %IMAGE_DIR%
    call :show_error_window Image directory was not found: %IMAGE_DIR%
    exit /b 1
)

pushd "%IMAGE_DIR%" >nul
if errorlevel 1 (
    call :log [ERROR] Failed to enter image directory: %IMAGE_DIR%
    call :show_error_window Failed to enter image directory: %IMAGE_DIR%
    exit /b 1
)

for %%F in (
    elasticsearch_8.11.3.tar
    quay.io_minio_minio_RELEASE.2025-06-13T11-33-47Z.tar
    mysql_8.0.39.tar
    cloudprime_ragflow-dev_v0.22.0.v2.5.1.tar
    valkey_valkey_8.tar
    infiniflow_sandbox-executor-manager_latest.tar
) do (
    if not exist "%%F" (
        call :log [ERROR] Missing image archive: %%F
        call :show_error_window Missing image archive: %%F
        popd >nul
        exit /b 1
    )
)

call :log [3/3] Loading Docker images...
call :load_archive elasticsearch_8.11.3.tar elasticsearch
if errorlevel 1 (
    popd >nul
    exit /b 1
)

call :load_archive quay.io_minio_minio_RELEASE.2025-06-13T11-33-47Z.tar minio
if errorlevel 1 (
    popd >nul
    exit /b 1
)

call :load_archive mysql_8.0.39.tar mysql
if errorlevel 1 (
    popd >nul
    exit /b 1
)

call :load_archive cloudprime_ragflow-dev_v0.22.0.v2.5.1.tar ragflow
if errorlevel 1 (
    popd >nul
    exit /b 1
)

call :load_archive valkey_valkey_8.tar valkey
if errorlevel 1 (
    popd >nul
    exit /b 1
)

call :load_archive infiniflow_sandbox-executor-manager_latest.tar sandbox-executor
if errorlevel 1 (
    popd >nul
    exit /b 1
)

popd >nul
call :append_log [INFO] CIKE Docker image import completed successfully.
exit /b 0

:load_archive
call :log [INFO] Loading %~2 from %~1...
call :run_and_log docker load -q -i "%~1"
if errorlevel 1 (
    call :log [ERROR] Failed to load archive %~1.
    call :show_error_window Failed to load archive %~1. See the payload log for details.
    exit /b 1
)
call :append_log [INFO] Loaded image archive %~1 successfully.
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
start "CIKE Image Load Error" cmd /k "title CIKE Image Load Error && echo ================================================== && echo. && echo    CIKE image import failed. && echo    %* && echo. && echo    Review the payload log for details. && echo ================================================== && pause"
exit /b 0

:run_and_log
if defined PAYLOAD_LOG (
    >> "%PAYLOAD_LOG%" echo [COMMAND] %*
    >> "%PAYLOAD_LOG%" 2>&1 %*
) else (
    %*
)
exit /b %ERRORLEVEL%
