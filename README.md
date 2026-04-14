# WinPE Auto Deploy

This repository builds a reusable UEFI-only WinPE deployment environment for applying a single Windows image from prepared media and finishing post-deployment setup on first logon.

## What the project does

- Builds an `amd64` WinPE work directory from Windows ADK.
- Injects project automation into `boot.wim` instead of modifying stock ADK scripts in place.
- Boots into WinPE and automatically searches `C:` through `Z:` for exactly one prepared source containing:
  - `\sources\install.wim`
  - `\sources\winpe-autodeploy.tag`
- Wipes the configured target disk and recreates a fixed GPT layout:
  - EFI `S:`
  - MSR
  - Windows `W:`
  - Recovery `R:`
- Applies the selected WIM index with `DISM`, rebuilds boot files with `BCDBoot`, and stages `unattend.xml`, `SetupComplete.cmd`, and first-logon scripts into the deployed OS.
- Preserves the main deployment log to:
  - `X:\AutoDeploy.log`
  - `W:\Windows\Temp\AutoDeploy.log`
  - `\<deployment-media>\DeployLogs\AutoDeploy.log` when the source media is still available
- Optionally copies `\payload\docker-images\*` from deployment media into `C:\Payload\DockerImages` inside the deployed OS.

## Repository layout

- `scripts\Build-WinPEAutoDeploy.ps1`
  - Creates or rebuilds the WinPE work directory.
  - Mounts `media\sources\boot.wim`.
  - Renders template tokens such as `__TARGET_DISK__` and `__WIM_INDEX__`.
  - Injects the runtime and post-deployment assets into `Windows\System32` inside the mounted image.
- `scripts\Prepare-WinPEUsb.ps1`
  - Destructively prepares a dual-partition USB disk.
  - Uses `MakeWinPEMedia.cmd /UFD` to populate the FAT32 boot partition.
  - Copies `install.wim`, `winpe-autodeploy.tag`, and optional payload files to the NTFS data partition.
- `scripts\Generate-WinPEIso.ps1`
  - Packages an existing customized work directory as an ISO.
  - Can optionally bundle `install.wim` and payload files into a temporary staging copy before packaging.
- `scripts\Export-CleanWinPEIso.ps1`
  - Produces a stock WinPE ISO with no project-specific automation injected.
  - Intended for maintenance or image-capture scenarios.
- `templates\deploy.cmd`
  - Main WinPE runtime entry.
  - Finds the source image, partitions the target disk, applies Windows, configures boot, stages files, and reboots.
- `templates\diskpart-uefi.txt`
  - DiskPart template used at runtime.
- `templates\startnet.cmd`
  - WinPE bootstrap entry point that runs `wpeinit` and then `deploy.cmd`.
- `templates\unattend.xml`
  - Offline OOBE settings for `zh-CN`.
  - Only skips the network setup page during OOBE; the rest of the first-run flow remains standard Windows setup.
- `templates\SetupComplete.cmd`
  - Runs `reagentc /enable` inside the deployed OS.
  - Registers `firstboot.ps1` through `register-firstboot.ps1`.
- `templates\firstboot.ps1`
  - Runs on user logon from `HKLM\...\Run`.
  - Ensures Docker is present and ready.
  - Executes `load_images.bat` and `install_appstore.bat` if they exist in `C:\Payload\DockerImages`.
  - Writes payload logs to `C:\ProgramData\FirstBoot\PayloadLogs\`.
  - Removes the Run registration only after Docker is ready and all detected payload scripts return exit code `0`.

## Requirements

- Windows host with Windows ADK and WinPE add-on installed.
- Elevated PowerShell session for all scripts that build media or modify disks.
- UEFI target machines only.
- A valid `install.wim`.

Default ADK root expected by the scripts:

```text
C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit
```

## Common workflow

### 1. Build the customized WinPE work directory

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Build-WinPEAutoDeploy.ps1 `
  -Force `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -WimIndex 1 `
  -TargetDisk 0
```

Important defaults:

- `-Architecture amd64`
- `-WinPEWorkDir C:\WinPE_AutoDeploy_amd64`
- `-WimIndex 1`
- `-TargetDisk 0`

### 2. Prepare a deployment USB

```powershell
.\scripts\Prepare-WinPEUsb.ps1 `
  -UsbDiskNumber 1 `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -InstallWimPath C:\WorkSpace\Win11_Custom\install.wim
```

Optional payload copy:

```powershell
.\scripts\Prepare-WinPEUsb.ps1 `
  -UsbDiskNumber 1 `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -InstallWimPath C:\WorkSpace\Win11_Custom\install.wim `
  -DockerImagesDirectory C:\Payload\DockerImages
```

USB-specific notes:

- The script is destructive and clears the selected disk.
- The USB disk is initialized as `MBR` for removable-media compatibility.
- The boot partition defaults to `2048 MB` and must be between `1024` and `32768` MB.
- The script refuses to operate on a disk that Windows reports as `IsBoot` or `IsSystem`.
- If `-DockerImagesDirectory` is provided, the script validates that path before any disk-wiping step begins.

### 3. Generate an ISO for VM testing

Using the existing work directory only:

```powershell
.\scripts\Generate-WinPEIso.ps1 `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -Force
```

Bundling `install.wim` and payloads into the ISO:

```powershell
.\scripts\Generate-WinPEIso.ps1 `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -InstallWimPath C:\Images\install.wim `
  -DockerImagesDirectory C:\Payload\DockerImages `
  -Force
```

Important behavior:

- `Generate-WinPEIso.ps1` packages the current contents of `WinPEWorkDir\media`.
- If `-InstallWimPath` or `-DockerImagesDirectory` is used, the script first creates a temporary staging copy of the work directory, injects those files there, and packages from that staging tree.
- The original `WinPEWorkDir\media` contents are left unchanged.
- Optional source paths are validated before staging begins, and any temporary staging tree is cleaned up if packaging later fails.

### 4. Export a plain WinPE ISO

```powershell
.\scripts\Export-CleanWinPEIso.ps1 -Force
```

By default this creates:

- `C:\WinPE_Clean_amd64`
- `C:\WinPE_Clean_amd64.iso`

## Runtime behavior

When the target machine boots into the prepared WinPE image:

1. `startnet.cmd` runs `wpeinit` and launches `deploy.cmd`.
2. `deploy.cmd` scans `C:` through `Z:` for exactly one valid deployment source.
3. If zero or multiple matches are found, deployment stops before touching the target disk.
4. DiskPart wipes the configured target disk and creates the fixed GPT partition layout.
5. `DISM /Apply-Image` applies the configured WIM index to `W:\`.
6. `BCDBoot` writes UEFI boot files to `S:\`.
7. `unattend.xml` is staged to `W:\Windows\Panther\unattend.xml`.
8. `W:\Windows\System32\reagentc.exe /Setreimage` points WinRE to `W:\Windows\System32\Recovery`.
9. `firstboot.ps1`, `register-firstboot.ps1`, and `SetupComplete.cmd` are staged into the deployed OS.
10. If present, `\payload\docker-images\*` is copied to `W:\Payload\DockerImages`.
11. Logs are persisted and WinPE reboots.

## First-logon behavior

After Windows boots:

- `SetupComplete.cmd` enables WinRE with `reagentc /enable`.
- `register-firstboot.ps1` creates `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\CodexFirstBoot`.
- `firstboot.ps1` runs on the first successful user logon and behaves as follows:
  - If `C:\Payload\DockerImages` does not exist, it writes `done.tag`, removes the Run entry, and exits.
  - If `docker.exe` is missing, it exits with code `1` so the Run entry remains for the next logon.
  - If Docker is installed but not ready, it tries to start Docker Desktop and related services, then retries `docker info` for up to 30 attempts with 10-second waits.
  - If Docker becomes ready, it executes:
    - `C:\Payload\DockerImages\load_images.bat` when present
    - `C:\Payload\DockerImages\install_appstore.bat` when present
  - `load_images.bat` runs hidden, uses the same payload logging format as `install_appstore.bat`, and writes its execution details to `C:\ProgramData\FirstBoot\PayloadLogs\load_images_<timestamp>.log`.
  - `install_appstore.bat` runs in a visible console window, writes non-sensitive execution details to `C:\ProgramData\FirstBoot\PayloadLogs\install_appstore_<timestamp>.log`, shows the final username/password only in the console window, and keeps that window open after success.
  - It creates `C:\ProgramData\FirstBoot\done.tag` and removes the Run entry only if all detected payload scripts succeed.

Important limitation:

- Retry behavior covers both Docker readiness failures and payload script failures.
- Payload scripts are still discovered by fixed filenames only: `load_images.bat` and `install_appstore.bat`.

## Payload layout

On deployment media:

```text
\sources\install.wim
\sources\winpe-autodeploy.tag
\payload\docker-images\load_images.bat          optional
\payload\docker-images\install_appstore.bat     optional
\payload\docker-images\*.tar                    optional
\payload\docker-images\<other files>            optional
```

Inside the deployed OS after staging:

```text
C:\Payload\DockerImages\...
C:\ProgramData\FirstBoot\firstboot.ps1
C:\ProgramData\FirstBoot\register-firstboot.ps1
C:\ProgramData\FirstBoot\setupcomplete.log
C:\Windows\Setup\Scripts\SetupComplete.cmd
```

## Safety notes

- `Prepare-WinPEUsb.ps1` permanently clears the selected USB disk.
- WinPE deployment permanently clears the configured target disk.
- Source discovery requires both `install.wim` and `winpe-autodeploy.tag`, which reduces the risk of selecting the wrong image source.
- The runtime assumes the applied Windows partition will be mounted as `W:` and the EFI partition as `S:`.

## Logging

- WinPE deployment log:
  - `X:\AutoDeploy.log`
  - `C:\Windows\Temp\AutoDeploy.log` after staging to the deployed OS
  - `\<deployment-media>\DeployLogs\AutoDeploy.log` when available
- First-logon logs:
  - `C:\ProgramData\FirstBoot\setupcomplete.log`
  - `C:\ProgramData\FirstBoot\register-firstboot.log`
  - `C:\ProgramData\FirstBoot\firstboot.log`
  - `C:\ProgramData\FirstBoot\PayloadLogs\load_images_<timestamp>.log`
  - `C:\ProgramData\FirstBoot\PayloadLogs\install_appstore_<timestamp>.log`
