@echo off
setlocal enabledelayedexpansion

set "BASE_DIR=C:\1Panel"
set "APP_TARGET_DIR=%BASE_DIR%\resource\apps\local"
set "APP_PACKAGE=apps.zip"
set "COMPOSE_FILE=%BASE_DIR%\docker-compose.yml"
set "PAYLOAD_LOG=%~1"

cd /d "%~dp0"

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
echo       - C:\1Panel:/opt/1panel
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
    pause
    exit /b 1
)

call :log [4/5] Extracting apps to %APP_TARGET_DIR%...
call :run_and_log tar -xf "%APP_PACKAGE%" -C "%APP_TARGET_DIR%"
if errorlevel 1 (
    call :log [ERROR] Failed to extract %APP_PACKAGE%.
    pause
    exit /b 1
)

call :log [5/5] Starting 1Panel via Docker...
cd /d "%BASE_DIR%"
call :run_and_log docker compose up -d
if errorlevel 1 (
    call :log [ERROR] docker compose up -d failed.
    pause
    exit /b 1
)

echo ==================================================
echo.
echo    1Panel Installation Complete!
echo    URL: http://localhost:10086/entrance
echo    Username: admin
echo    Password: Cp@12345
echo.
echo ==================================================
pause

call :append_log [INFO] 1Panel installation completed successfully.
call :append_log [INFO] URL: http://localhost:10086/entrance
call :append_log [INFO] Username displayed in console during execution.
call :append_log [INFO] Password displayed in console during execution, the window remains open for review, and the password is intentionally not written to the log.
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
