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
- Validates an optional `-DockerImagesDirectory` before any disk-wiping step.

### `scripts\Generate-WinPEIso.ps1`

- Packages the current `WinPEWorkDir\media` as an ISO.
- Can optionally inject `install.wim` and payloads into a temporary staging copy before packaging.
- The original work directory is left unchanged after ISO creation.
- Optional source paths are validated before staging, and the temporary staging tree is removed even if packaging later fails.

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
- Only skips the network setup page during OOBE.
- Leaves the rest of the first-run Windows setup flow unchanged.

### `templates\SetupComplete.cmd`

- Enables WinRE with `reagentc /enable`.
- Runs `register-firstboot.ps1`.

### `templates\register-firstboot.ps1`

- Registers `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\CodexFirstBoot`.
- Uses `Run`, not `RunOnce`, so first-logon setup can retry on later logons.

### `templates\firstboot.ps1`

- Logs to `C:\ProgramData\FirstBoot\firstboot.log`.
- Writes per-script payload logs to `C:\ProgramData\FirstBoot\PayloadLogs`.
- If `C:\Payload\DockerImages` does not exist, it marks completion and unregisters itself.
- If `docker.exe` is missing, it exits with code `1` so Windows runs it again at the next logon.
- If Docker Desktop is installed, it registers `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\DockerDesktopAutoStart` for future auto-start.
- For the current first-logon run, it starts Docker Desktop in the background with `docker desktop start`, falling back to `Docker Desktop.exe` when needed.
- It waits for the `Docker Desktop` process to appear, then performs a short `docker info` readiness check.
- If Docker becomes ready, it executes:
  - `load_images.bat`
  - `install_appstore.bat`
- `load_images.bat` uses the same per-script payload logging format as `install_appstore.bat`.
- `install_appstore.bat` keeps a visible console window, writes non-sensitive details to its own payload log, only shows the final credentials in the console window, and leaves the window open after success.
- It creates `done.tag` and removes the Run entry only when all detected payload scripts return exit code `0`.

Important limitation:

- Retry behavior applies while Docker is unavailable, not ready, or a payload batch file returns non-zero.
- Payload execution still only recognizes `load_images.bat` and `install_appstore.bat`.

## Operational notes

- All build and media-preparation scripts assume Windows ADK is installed under:
  - `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit`
- `Prepare-WinPEUsb.ps1` refuses to touch disks reported as boot/system disks.
- The deployment process stops before disk changes if zero or multiple valid sources are found.
- Logs are preserved to the deployed OS and, when possible, back to the deployment media.
