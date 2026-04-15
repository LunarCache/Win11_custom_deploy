@echo off
setlocal
title 10-win11-install Service Setup

echo ==================================================
echo  10-win11-install service setup is running
echo ==================================================
echo [NOTICE] This window is part of first-boot deployment.
echo [NOTICE] Do not close it unless you want to interrupt the current payload step.
echo.

call "%~dp0install_appstore.bat" %*
exit /b %ERRORLEVEL%
