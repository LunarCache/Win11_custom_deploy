# WinPE Auto Deploy Technical Solution

## 1. Objective

This repository provides a Windows 11 deployment solution based on WinPE. It automates image discovery, disk partitioning, OS application, first-boot preparation, and first-logon Docker payload execution for UEFI `amd64` targets.

The design target is a controlled deployment flow with one prepared image source and an optional post-logon Docker payload bundle.

## 2. End-to-End Flow

The solution is divided into three runtime stages:

1. Build stage  
   `Build-WinPEAutoDeploy.ps1` creates a reusable WinPE work directory and injects repository templates into `boot.wim`.

2. Deployment stage  
   After the target machine boots into WinPE, `startnet.cmd` launches `deploy.cmd`. The script discovers the deployment media, wipes the target disk, applies `install.wim`, configures boot files, stages OOBE and first-boot assets, and reboots.

3. First-logon stage  
   `SetupComplete.cmd` enables WinRE and registers `CodexFirstBoot`. On the first successful user logon, `firstboot.ps1` starts Docker Desktop, waits for the daemon to become ready, and then runs the payload scripts.

## 3. Key Components

### 3.1 Build and Media Preparation

- `scripts/Build-WinPEAutoDeploy.ps1` builds the customized WinPE work directory and renders template tokens such as `__TARGET_DISK__` and `__WIM_INDEX__`.
- `scripts/Prepare-WinPEUsb.ps1` prepares the dual-partition USB media and copies `install.wim` plus optional Docker payload files.
- `scripts/Generate-WinPEIso.ps1` packages the customized media into an ISO for VM or physical-machine testing.

### 3.2 WinPE Runtime

- `templates/startnet.cmd` initializes WinPE and transfers control to `deploy.cmd`.
- `templates/deploy.cmd` performs source discovery, GPT partitioning, image apply, BCDBoot, WinRE path configuration, log preservation, and first-boot asset staging.
- `templates/unattend.xml` preconfigures language settings and skips only the network page in OOBE.

### 3.3 First-Logon Automation

- `templates/SetupComplete.cmd` enables WinRE in the deployed OS and registers the first-logon automation entry.
- `templates/firstboot-launcher.vbs` launches `firstboot.ps1` through `wscript.exe` without showing a blank console window at logon.
- `templates/register-firstboot.ps1` creates `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\CodexFirstBoot`.
- `templates/firstboot.ps1` registers Docker Desktop auto-start in `HKCU`, starts Docker Desktop for the current session, waits for the daemon to become ready, and scans ordered `C:\Payload\DockerImages\NN-name\` service directories.
  - For each service directory it runs `load_images.bat`
  - Then it runs `install_service.bat`

## 4. Data Layout

### 4.1 Deployment Media

```text
\sources\install.wim
\sources\winpe-autodeploy.tag
\payload\docker-images\10-win11-install\load_images.bat      optional
\payload\docker-images\10-win11-install\install_service.bat  optional
\payload\docker-images\20-CIKE-install\load_images.bat       optional
\payload\docker-images\20-CIKE-install\install_service.bat   optional
\payload\docker-images\*.tar                    optional
```

### 4.2 Files Staged Into the Deployed OS

```text
C:\Payload\DockerImages\...
C:\ProgramData\FirstBoot\firstboot.ps1
C:\ProgramData\FirstBoot\firstboot-launcher.vbs
C:\ProgramData\FirstBoot\register-firstboot.ps1
C:\Windows\Setup\Scripts\SetupComplete.cmd
```

## 5. Logging

Deployment logs:

- `X:\AutoDeploy.log`
- `C:\Windows\Temp\AutoDeploy.log`
- `\<deployment-media>\DeployLogs\AutoDeploy.log`

First-logon logs:

- `C:\ProgramData\FirstBoot\setupcomplete.log`
- `C:\ProgramData\FirstBoot\register-firstboot.log`
- `C:\ProgramData\FirstBoot\firstboot.log`
- `C:\ProgramData\FirstBoot\PayloadLogs\<service>_load_images_<timestamp>.log`
- `C:\ProgramData\FirstBoot\PayloadLogs\<service>_install_service_<timestamp>.log`

`load_images.bat` and `install_service.bat` run in visible `cmd.exe` windows during automation and close automatically on success. Those windows display a do-not-close notice because closing them interrupts the current payload step. After success, the `10-win11-install` service opens a detached 1Panel credential window and the `20-CIKE-install` service opens a detached CIKE success window. Those final popups are detached and do not block the first-logon flow from completing. On failure, the batch script opens a detached error window. Sensitive values are not persisted in the payload log.

## 6. Constraints and Risks

- Both USB preparation and runtime deployment are destructive operations and wipe disks.
- Source discovery intentionally accepts exactly one valid deployment source to reduce the risk of using the wrong image.
- Docker automation depends on Docker Desktop rather than a standalone Windows `dockerd` service.
- Payload discovery is directory-based and expects ordered `NN-name` service folders containing `load_images.bat` and `install_service.bat`.
