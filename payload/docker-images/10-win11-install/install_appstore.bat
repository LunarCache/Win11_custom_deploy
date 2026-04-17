@echo off
setlocal enabledelayedexpansion
title 10-win11-install Service Setup

set "BASE_DIR=C:\CloudPrimeAppstore"
set "APP_TARGET_DIR=%BASE_DIR%\resource\apps\local"
set "APP_PACKAGE=apps.zip"
set "COMPOSE_FILE=%BASE_DIR%\docker-compose.yml"
set "PAYLOAD_LOG=%~1"

cd /d "%~dp0"

call :log ==================================================
call :log 10-win11-install service setup is running
call :log ==================================================
call :log [NOTICE] This window is part of first-boot deployment.
call :log [NOTICE] Do not close it unless you want to interrupt the current payload step.

call :log [1/5] Creating directory structure...
if not exist "%APP_TARGET_DIR%" mkdir "%APP_TARGET_DIR%"
if errorlevel 1 (
    call :log [ERROR] Failed to create %APP_TARGET_DIR%.
    exit /b 1
)

call :log [2/5] Generating docker-compose.yml...
(
echo services:
echo   1panel-gpu:
echo     container_name: 1panel-gpu
echo     image: cloud-harbor.com:8080/app/1panel:gpu
echo     restart: unless-stopped
echo     ports:
echo       - "10086:10086"
echo     dns:
echo       - 223.5.5.5
echo       - 119.29.29.29
echo       - 8.8.8.8
echo     environment:
echo       - PANEL_PORT=10086
echo       - PANEL_USERNAME=admin
echo       - PANEL_PASSWORD=Cp@12345
echo       - PANEL_ENTRANCE=entrance
echo       - TZ=Asia/Shanghai
echo     volumes:
echo       - C:\CloudPrimeAppstore:/opt/1panel
echo       - /var/run/docker.sock:/var/run/docker.sock
) > "%COMPOSE_FILE%"
if errorlevel 1 (
    call :log [ERROR] Failed to write %COMPOSE_FILE%.
    exit /b 1
)
call :append_log [INFO] docker-compose.yml generated at %COMPOSE_FILE%.

call :log [3/5] Verifying %APP_PACKAGE%...
if not exist "%APP_PACKAGE%" (
    call :log [ERROR] Cannot find %APP_PACKAGE% in %~dp0
    call :show_error_window Cannot find %APP_PACKAGE% in %~dp0
    exit /b 1
)

call :log [4/5] Extracting apps to %APP_TARGET_DIR%...
call :run_and_log tar -xf "%APP_PACKAGE%" -C "%APP_TARGET_DIR%"
if errorlevel 1 (
    call :log [ERROR] Failed to extract %APP_PACKAGE%.
    call :show_error_window Failed to extract %APP_PACKAGE%. See the payload log for details.
    exit /b 1
)

call :log [5/5] Starting CloudPrimeAppstore via Docker...
cd /d "%BASE_DIR%"
call :run_and_log docker compose up -d
if errorlevel 1 (
    call :log [ERROR] docker compose up -d failed.
    call :show_error_window docker compose up -d failed. See the payload log for details.
    exit /b 1
)

echo ==================================================
echo.
echo    CloudPrimeAppstore Installation Complete!
echo    URL: http://localhost:10086/entrance
echo    Username: admin
echo    Password: Cp@12345
echo.
echo ==================================================

call :append_log [INFO] CloudPrimeAppstore installation completed successfully.
call :append_log [INFO] URL: http://localhost:10086/entrance
call :append_log [INFO] Username and password are displayed by firstboot.ps1 in a detached credential window after the installer exits.
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
start "CloudPrimeAppstore Setup Error" cmd /k "title CloudPrimeAppstore Setup Error && echo ================================================== && echo. && echo    CloudPrimeAppstore setup failed. && echo    %* && echo. && echo    Review the payload log for details. && echo ================================================== && pause"
exit /b 0

:run_and_log
if defined PAYLOAD_LOG (
    >> "%PAYLOAD_LOG%" echo [COMMAND] %*
    >> "%PAYLOAD_LOG%" 2>&1 %*
) else (
    %*
)
exit /b %ERRORLEVEL%
