# WinPE Auto Deploy Technical Solution

## 1. Objective

This repository provides a Windows 11 deployment solution based on WinPE. It automates image discovery, disk partitioning, OS application, first-boot preparation, and first-logon Docker payload execution for UEFI `amd64` targets.

The design target is a controlled deployment flow with one prepared image source and an optional post-logon Docker payload bundle.

## 2. End-to-End Flow

The solution is divided into three runtime stages:

1. Build stage  
   `Build-WinPEAutoDeploy.ps1` creates a reusable WinPE work directory, renders deployment parameters into repository templates, optionally embeds driver packages into `X:\drivers-payload`, and injects the rendered files into `boot.wim`.

2. Deployment stage  
   After the target machine boots into WinPE, `startnet.cmd` launches `deploy.cmd`. The script discovers the deployment media, wipes the target disk, applies `install.wim`, configures boot files, stages OOBE and first-boot assets, persists logs, and shuts down WinPE.

3. First-logon stage  
   `SetupComplete.cmd` (staged into `W:\Windows\Setup\Scripts`) runs near the end of setup. It enables WinRE and executes `register-firstboot.ps1`. On the first successful user logon, `firstboot.ps1` (launched via `firstboot-launcher.vbs`) starts Docker Desktop, waits for the daemon to become ready, and then runs the payload scripts.

## 3. Key Components

### 3.1 Build and Media Preparation

- `scripts/Build-WinPEAutoDeploy.ps1` builds the customized WinPE work directory and renders template tokens such as `__TARGET_DISK__`, `__WIM_INDEX__`, and partition layout settings.
- `scripts/Prepare-WinPEUsb.ps1` prepares the dual-partition USB media and copies `install.wim`, `winpe-autodeploy.tag`, and optional Docker payload files.
- `scripts/Generate-WinPEIso.ps1` packages the customized media into an ISO for VM or physical-machine testing. When `install.wim` or payloads are supplied, it uses a temporary staging copy and leaves the original work directory unchanged.
- `scripts/Export-CleanWinPEIso.ps1` creates a stock ADK WinPE ISO with no project automation injected.

### 3.2 WinPE Runtime

- `templates/startnet.cmd` initializes WinPE and transfers control to `deploy.cmd`.
- `templates/deploy.cmd` performs source discovery, target-disk resolution, GPT partitioning, image apply, BCDBoot, driver injection, unattend staging, WinRE path configuration, first-boot asset staging, Docker payload staging, log preservation, and shutdown. EFI is fixed at 100 MB, MSR is fixed at 16 MB, Recovery defaults to 1024 MB, Windows can be auto-sized or fixed, and an optional Data partition can consume the remaining space before Recovery when a fixed Windows size is used. Driver injection, unattend staging, WinRE path configuration, and first-logon staging are warning-only; failures are logged but do not stop a successful image apply and boot configuration.
- `templates/unattend.xml` configures OOBE bypass for automated deployment.
  - oobeSystem pass: Skips network setup and privacy settings. Account creation screens remain visible.
  - Does not configure locale, product key, or other OOBE answers.

### 3.3 First-Logon Automation

- `templates/SetupComplete.cmd` enables WinRE in the deployed OS and registers the first-logon automation entry by calling `register-firstboot.ps1`.
- `templates/firstboot-launcher.vbs` launches `firstboot.ps1` through `wscript.exe` with a hidden window to prevent flashing a console at logon.
- `templates/register-firstboot.ps1` creates `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\CodexFirstBoot` pointing to the VBS launcher. If Docker Desktop is already installed, it also creates `HKLM\...\Run\DockerDesktopAutoStart` for all users.
- `templates/firstboot.ps1` starts Docker Desktop, waits for the process and daemon (via `docker info` polling), and scans ordered `C:\Payload\DockerImages\NN-name\` service directories.
  - For each service directory it runs `load_images.bat`.
  - Then it runs `install_service.bat`.
  - For service names matching `*win11-install`, it parses `C:\CloudPrimeAppstore\docker-compose.yml` to extract 1Panel port and credentials, falling back to built-in defaults.
  - For service names matching `*CIKE-install`, it opens a detached CIKE success information window.

## 4. Data Layout

### 4.1 Deployment Media

```text
\sources\install.wim
\sources\winpe-autodeploy.tag
\payload\docker-images\10-win11-install\load_images.bat      optional
\payload\docker-images\10-win11-install\install_service.bat  optional
\payload\docker-images\20-CIKE-install\load_images.bat       optional
\payload\docker-images\20-CIKE-install\install_service.bat   optional
\payload\docker-images\<NN-name>\*.tar                        optional
\payload\docker-images\<NN-name>\<other files>               optional
```

Driver payloads are embedded at build time, not discovered from deployment media. When `-DriversDirectory` is supplied, its contents are copied into `boot.wim` as `X:\drivers-payload` and injected into the offline Windows image with `DISM /Add-Driver /Recurse`.

### 4.2 Files Staged Into the Deployed OS

```text
C:\Payload\DockerImages\...
C:\ProgramData\FirstBoot\firstboot.ps1
C:\ProgramData\FirstBoot\firstboot-launcher.vbs
C:\ProgramData\FirstBoot\register-firstboot.ps1
C:\ProgramData\FirstBoot\setupcomplete.log
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

`load_images.bat` and `install_service.bat` run in visible `cmd.exe` windows during automation. The core first-logon script waits for each process and records the exit code; the payload batch files control their own console text and close behavior. After success, `*win11-install` opens a detached 1Panel credential window and `*CIKE-install` opens a detached CIKE success window. Sensitive values are displayed in the detached window but are not written by `firstboot.ps1` to its main log.

## 6. Constraints and Risks

- Both USB preparation and runtime deployment are destructive operations and wipe disks.
- Source discovery intentionally accepts exactly one valid deployment source and stops before disk changes when zero or multiple sources are found.
- `-TargetDisk auto` currently resolves to disk `0`; explicit disk numbers should be used when the target hardware layout is not guaranteed.
- Docker automation depends on Docker Desktop being present in the deployed image; this project starts and waits for Docker, but does not install Docker Desktop during first logon.
- Payload discovery is directory-based and expects ordered `NN-name` service folders containing `load_images.bat` and/or `install_service.bat`.
- The deployment runtime ends with `wpeutil shutdown`, so unattended lab validation needs either virtual power-on automation or manual power-on after WinPE finishes.
