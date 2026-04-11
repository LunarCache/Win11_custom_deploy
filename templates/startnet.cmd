@echo off
rem startnet.cmd is the first user-customizable entry point WinPE runs after boot.
rem Keep it minimal: initialize WinPE networking/PnP first, then jump to the real deployment script.
wpeinit
rem deploy.cmd lives inside boot.wim under X:\Windows\System32 because Build-WinPEAutoDeploy.ps1 injects it there.
call X:\Windows\System32\deploy.cmd
