# WinPE Auto Deploy Context

This project provides a reusable automation framework for UEFI-only WinPE deployments. It automates the entire lifecycle from building the WinPE environment and preparing bootable media to the final OS configuration and optional Docker payload importing.

## Project Overview

- **Core Technology:** Windows ADK (WinPE), PowerShell, Batch/CMD, DiskPart.
- **Architecture:** UEFI-only, `amd64`.
- **Primary Goal:** Automated "wipe and reload" of a target disk using a custom `install.wim` from a dual-partition USB (FAT32 for boot, NTFS for large WIM files).

## Key Components

### 1. Build & Authoring (`scripts/`)
- `Build-WinPEAutoDeploy.ps1`: Prepares the WinPE work directory. It injects the automation scripts into `boot.wim`, renders configuration tokens, and injects `WinPE-WMI` and `WinPE-WinReCfg` (specifically `zh-cn` and `en-us` language packs) to provide native `reagentc` support.
- `Prepare-WinPEUsb.ps1`: Destructive script that formats a USB drive with two partitions and stages the `install.wim` and deployment markers.
- `Generate-WinPEIso.ps1`: Creates a bootable ISO from the prepared work directory (useful for VM testing).

### 2. WinPE Runtime (`templates/`)
- `startnet.cmd`: The WinPE entry point. Initializes environment and calls `deploy.cmd`.
- `deploy.cmd`: The main automation engine. Performs source discovery, disk partitioning, and image application. It utilizes an adaptive search logic for `reagentc.exe`, checking both the local WinPE environment and the deployed OS partition for maximum reliability.
- `diskpart-uefi.txt`: Template for GPT partitioning (EFI, MSR, Windows, Recovery).

### 3. Post-Deployment (`templates/`)
- `SetupComplete.cmd`: Runs automatically on first boot. Enables WinRE and registers `firstboot.ps1`.
- `firstboot.ps1`: Imports Docker images from `C:\Payload\DockerImages` and cleans up the first-logon registration.

## Building and Running

### Preparation
Run these commands from an **elevated** PowerShell session with Windows ADK installed.

```powershell
# 1. Build the WinPE working directory (Injects automation into boot.wim)
.\scripts\Build-WinPEAutoDeploy.ps1 -WinPEWorkDir C:\WinPE_AutoDeploy -WimIndex 1 -TargetDisk 0

# 2. Prepare the bootable USB (Destructive)
.\scripts\Prepare-WinPEUsb.ps1 -UsbDiskNumber 1 -WinPEWorkDir C:\WinPE_AutoDeploy -InstallWimPath C:\Path\To\install.wim
```

### Deployment
1. Boot the target machine from the prepared USB in UEFI mode.
2. WinPE will automatically:
   - Search for the USB data partition (marked with `winpe-autodeploy.tag`).
   - Wipe `Disk 0` (or the disk specified during build).
   - Apply the WIM and configure boot files.
   - Log progress to `X:\AutoDeploy.log` (preserved to `C:\Windows\Temp\AutoDeploy.log` on completion).

## Development Conventions

- **Tokens:** `deploy.cmd` uses `__TARGET_DISK__` and `__WIM_INDEX__` as placeholders, which are replaced by `Build-WinPEAutoDeploy.ps1` during the build phase.
- **Error Handling:** Deployment stops immediately if zero or multiple valid `install.wim` sources are found to prevent accidental data loss.
- **Logging:** All automation steps use `[INFO]`, `[WARNING]`, and `[ERROR]` prefixes for easier parsing.
- **Elevation:** All scripts in `scripts/` require Administrator privileges for DISM and DiskPart operations.
