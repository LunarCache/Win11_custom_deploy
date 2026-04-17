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
  - EFI `S:` (100 MB, FAT32, label `System`)
  - MSR (16 MB)
  - Windows `W:` (NTFS, label `Windows`)
  - Recovery `R:` (about 1024 MB, NTFS, label `Recovery`)

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
  - `firstboot-launcher.vbs`
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
11. Persist logs and shut down WinPE.

## Post-deployment components

### `templates\unattend.xml`

- Hides only the wireless network setup page during OOBE.
- Does not set locale, region, account creation, product key, or other OOBE answers.
- Leaves the rest of the first-run Windows setup flow unchanged.

### `templates\SetupComplete.cmd`

- Enables WinRE with `reagentc /enable`.
- Runs `register-firstboot.ps1`.

### `templates\register-firstboot.ps1`

- Registers `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\CodexFirstBoot`.
- Uses `Run`, not `RunOnce`, so first-logon setup can retry on later logons.
- Points the Run entry at `wscript.exe` and `firstboot-launcher.vbs` so logon does not flash a blank console window.
- If Docker Desktop already exists, registers `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\DockerDesktopAutoStart`.

### `templates\firstboot-launcher.vbs`

- Launches `firstboot.ps1` through `wscript.exe` without showing an empty console window at logon.

### `templates\firstboot.ps1`

- Logs to `C:\ProgramData\FirstBoot\firstboot.log`.
- Writes per-script payload logs to `C:\ProgramData\FirstBoot\PayloadLogs`.
- If `C:\Payload\DockerImages` does not exist, it marks completion and unregisters itself.
- If `C:\Payload\DockerImages` exists but contains no ordered `NN-name` service directories, it also marks completion and unregisters itself.
- If `docker.exe` is missing, it exits with code `1` so Windows runs it again at the next logon.
- For the current first-logon run, it starts Docker Desktop in the background with `docker desktop start`, falling back to `Docker Desktop.exe` when needed.
- It waits for the `Docker Desktop` process to appear, then performs a short `docker info` readiness check.
- If Docker becomes ready, it scans ordered `C:\Payload\DockerImages\NN-name\` service directories.
- For each service directory, it runs:
  - `load_images.bat`
  - `install_service.bat`
- If a service directory contains neither of those scripts, it is logged and skipped.
- Payload logs are written as `C:\ProgramData\FirstBoot\PayloadLogs\<service>_<script>_<timestamp>.log`.
- `load_images.bat` and `install_service.bat` run in visible `cmd.exe` windows; their own batch logic controls console text and close behavior.
- Service names matching `*win11-install` open a detached 1Panel credential window after `install_service.bat` succeeds.
- Service names matching `*CIKE-install` open a detached CIKE success window after `install_service.bat` succeeds.
- Final success popups are detached and do not block the first-logon flow from completing.
- It creates `done.tag` and removes the Run entry only when all detected payload scripts return exit code `0`.

Important limitation:

- Retry behavior applies while Docker is unavailable, not ready, or a payload batch file returns non-zero.
- Payload execution is directory-based and expects ordered `NN-name` service folders containing `load_images.bat` and `install_service.bat`.

## Operational notes

- All build and media-preparation scripts assume Windows ADK is installed under:
  - `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit`
- `Prepare-WinPEUsb.ps1` refuses to touch disks reported as boot/system disks.
- The deployment process stops before disk changes if zero or multiple valid sources are found.
- Logs are preserved to the deployed OS and, when possible, back to the deployment media.
