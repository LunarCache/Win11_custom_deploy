# WinPE Auto Deploy Context

This project provides a WinPE-based Windows deployment pipeline built around a customized `boot.wim`, a single prepared `install.wim` source, optional first-logon Docker payload execution, and optional out-of-box driver injection.

## Current implementation summary

- Architecture is fixed to `amd64`.
- Target boot mode is UEFI only.
- The deployment target disk, WIM index, and partition layout are rendered into `deploy.cmd` during the build phase.
- Supports custom partition layouts: configurable Windows partition size, optional remaining-space Data partition, configurable Recovery partition size.
- Supports out-of-box driver injection via the `-DriversDirectory` parameter. Drivers are embedded into `boot.wim` as `X:\drivers-payload`; runtime deployment does not scan `payload\drivers` from USB or ISO media.
- Runtime source selection is strict: WinPE scans `C:` through `Z:` and requires exactly one volume containing both:
  - `\sources\install.wim`
  - `\sources\winpe-autodeploy.tag`
- The target disk is wiped and repartitioned as GPT with a configurable layout:
  - EFI `S:` (100 MB, FAT32, label `System`)
  - MSR (16 MB)
  - Windows `W:` (NTFS, configurable label, auto-sized or fixed size)
  - Optional Data partition (remaining space before Recovery when a fixed Windows size is used, configurable label)
  - Recovery `R:` (configurable size, default 1024 MB, NTFS, label `Recovery`)

## Build-time components

### `scripts\Build-WinPEAutoDeploy.ps1`

- Requires Administrator.
- Recreates ADK environment variables inside PowerShell.
- Runs `copype.cmd`.
- Mounts `media\sources\boot.wim`.
- Supports partition customization via parameters:
  - `-WindowsPartitionSizeGB` - fixed size or 0 for auto
  - `-CreateDataPartition` - enables Data partition creation
  - `-WindowsPartitionLabel` - custom label for Windows partition
  - `-DataPartitionLabel` - custom label for Data partition
  - `-RecoverySizeMB` - recovery partition size (default: 1024)
- Supports out-of-box driver injection via `-DriversDirectory` parameter
- Target disk supports `'auto'` (currently resolves to disk 0 at WinPE runtime) or a specific disk number.
- Injects these rendered templates into `Windows\System32` inside the mounted image:
  - `deploy.cmd`
  - `startnet.cmd`
  - `firstboot.ps1`
  - `firstboot-launcher.vbs`
  - `register-firstboot.ps1`
  - `SetupComplete.cmd`
  - `unattend.xml`
- Optionally embeds drivers into `X:\drivers-payload`

### `scripts\Prepare-WinPEUsb.ps1`

- Requires Administrator.
- Destructively rebuilds the selected disk as `MBR` for removable-media compatibility.
- Creates:
  - FAT32 boot partition labeled `WINPE`
  - NTFS data partition labeled `IMAGES`
- Uses `MakeWinPEMedia.cmd /UFD` for the boot partition.
- Copies `install.wim` and the marker file to `\sources`.
- Boot partition size is configurable via `-BootPartitionSizeMB` (default 2048 MB, range 1024-32768).
- Refuses to operate on disks marked as `IsBoot` or `IsSystem`.
- Optionally copies payloads to `\payload\docker-images`.

### `scripts\Generate-WinPEIso.ps1`

- Packages the current `WinPEWorkDir\media` as an ISO.
- Can optionally inject `install.wim` and payloads into a temporary staging copy before packaging.
- The original work directory is left unchanged after ISO creation.
- Optional source paths are validated before staging, and the temporary staging tree is removed even if packaging later fails.

### `scripts\Common-WinPEHelpers.ps1`

- Shared helper functions imported by all scripts:
  - `Set-AdkEnvironment` - bootstraps ADK environment variables
  - `Test-IsAdministrator` - validates elevated PowerShell session
  - `New-DirectoryIfMissing` - creates directories if they don't exist
  - `Invoke-ExternalCommand` - executes external tools and throws on non-zero exit
  - `Write-WinPEAutoDeployTag` - writes the source marker file
  - `Copy-DockerPayloadTree` - copies Docker payload directories
  - `New-TemporaryDirectory` - creates temporary staging directories

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
3. Dynamically generate `X:\diskpart-runtime.txt` from rendered partition settings.
4. Partition the configured target disk.
5. Apply the selected image index with `DISM`.
6. Run `BCDBoot`.
7. If `X:\drivers-payload` exists, inject all out-of-box drivers using `DISM /Add-Driver /Recurse` into the deployed Windows Driver Store.
8. Stage `unattend.xml` to `W:\Windows\Panther\unattend.xml`.
9. Set WinRE image path with `W:\Windows\System32\reagentc.exe`.
10. Stage first-logon scripts into the deployed OS.
11. Copy optional payload files from `\payload\docker-images`.
12. Persist logs in multiple locations:
    - `X:\AutoDeploy.log`
    - `W:\Windows\Temp\AutoDeploy.log`
    - `\<deployment-media>\DeployLogs\AutoDeploy.log` when source media is available
13. Shut down WinPE.

## Post-deployment components

### `templates\unattend.xml`

- Configures OOBE bypass for automated deployment.
- oobeSystem pass: Skips network setup and privacy settings. Account creation screens remain visible.
- Does not configure locale, product key, or other OOBE answers.
- Note: generalize pass is not needed because the deployment flow does not run sysprep after driver injection.

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
- `Prepare-WinPEUsb.ps1` refuses to touch disks reported as boot/system disks (`IsBoot` or `IsSystem`).
- The deployment process stops before disk changes if zero or multiple valid sources are found.
- Logs are preserved to multiple locations for troubleshooting:
  - `X:\AutoDeploy.log` (WinPE runtime)
  - `C:\Windows\Temp\AutoDeploy.log` (deployed OS)
  - `\<deployment-media>\DeployLogs\AutoDeploy.log` (when media is available)
- Driver injection at deploy time uses `DISM /Add-Driver /Recurse` on `X:\drivers-payload`.
