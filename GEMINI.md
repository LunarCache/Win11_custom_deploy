# WinPE Auto Deploy Context

This project provides a WinPE-based Windows deployment pipeline built around a customized `boot.wim`, a single prepared `install.wim` source, and optional first-logon Docker payload execution.

## Current implementation summary

- Architecture is fixed to `amd64`.
- Target boot mode is UEFI only.
- The deployment target disk and WIM index are rendered into `deploy.cmd` during the build phase.
- Runtime source selection is strict: WinPE scans `C:` through `Z:` and requires exactly one volume containing both:
  - `\sources\install.wim`
  - `\sources\winpe-autodeploy.tag`
- The target disk is wiped and repartitioned as GPT with:
  - EFI `S:`
  - MSR
  - Windows `W:`
  - Recovery `R:`

## Build-time components

### `scripts\Build-WinPEAutoDeploy.ps1`

- Requires Administrator.
- Recreates ADK environment variables inside PowerShell.
- Runs `copype.cmd`.
- Mounts `media\sources\boot.wim`.
- Injects these rendered templates into `Windows\System32` inside the mounted image:
  - `deploy.cmd`
  - `diskpart-uefi.txt`
  - `startnet.cmd`
  - `firstboot.ps1`
  - `register-firstboot.ps1`
  - `SetupComplete.cmd`
  - `unattend.xml`

### `scripts\Prepare-WinPEUsb.ps1`

- Requires Administrator.
- Destructively rebuilds the selected disk as `MBR`.
- Creates:
  - FAT32 boot partition labeled `WINPE`
  - NTFS data partition labeled `IMAGES`
- Uses `MakeWinPEMedia.cmd /UFD` for the boot partition.
- Copies `install.wim` and the marker file to `\sources`.
- Optionally copies payloads to `\payload\docker-images`.

### `scripts\Generate-WinPEIso.ps1`

- Packages the current `WinPEWorkDir\media` as an ISO.
- Can optionally copy `install.wim` and payloads into `media\` before packaging.
- Those copied artifacts remain in the work directory after the ISO is created.

### `scripts\Export-CleanWinPEIso.ps1`

- Creates a plain ADK-generated WinPE ISO with no project automation injected.

## Runtime flow

### `templates\startnet.cmd`

- Runs `wpeinit`.
- Calls `X:\Windows\System32\deploy.cmd`.

### `templates\deploy.cmd`

Main responsibilities:

1. Create and write `X:\AutoDeploy.log`.
2. Find exactly one valid deployment source.
3. Render `diskpart-uefi.txt` with the configured target disk.
4. Partition the disk.
5. Apply the selected image index with `DISM`.
6. Run `BCDBoot`.
7. Stage `unattend.xml`.
8. Set WinRE image path with `W:\Windows\System32\reagentc.exe`.
9. Stage first-logon scripts into the deployed OS.
10. Copy optional payload files from `\payload\docker-images`.
11. Persist logs and reboot.

## Post-deployment components

### `templates\unattend.xml`

- Sets locale to `zh-CN`.
- Hides major OOBE screens.
- Creates a local `Admin` account with a blank password.
- Enables one automatic logon for `Admin`.

### `templates\SetupComplete.cmd`

- Enables WinRE with `reagentc /enable`.
- Runs `register-firstboot.ps1`.

### `templates\register-firstboot.ps1`

- Registers `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\CodexFirstBoot`.
- Uses `Run`, not `RunOnce`, so first-logon setup can retry on later logons.

### `templates\firstboot.ps1`

- Logs to `C:\ProgramData\FirstBoot\firstboot.log`.
- If `C:\Payload\DockerImages` does not exist, it marks completion and unregisters itself.
- If `docker.exe` is missing, it exits with code `1` so Windows runs it again at the next logon.
- If Docker is installed but not ready, it tries to start Docker Desktop and related services, then retries `docker info` for up to 30 attempts.
- If Docker becomes ready, it executes:
  - `load_images.bat`
  - `install_appstore.bat`
- It then creates `done.tag` and removes the Run entry.

Important limitation:

- Retry behavior only applies while Docker is unavailable or not ready.
- Failures inside payload batch files are logged, but they do not block `done.tag` creation.

## Operational notes

- All build and media-preparation scripts assume Windows ADK is installed under:
  - `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit`
- `Prepare-WinPEUsb.ps1` refuses to touch disks reported as boot/system disks.
- The deployment process stops before disk changes if zero or multiple valid sources are found.
- Logs are preserved to the deployed OS and, when possible, back to the deployment media.
