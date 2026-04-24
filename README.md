# WinPE Auto Deploy

This repository builds a reusable UEFI-only WinPE deployment environment for applying a single Windows image from prepared media and finishing post-deployment setup on first logon.

## What the project does

- Builds an `amd64` WinPE work directory from Windows ADK.
- Injects project automation into `boot.wim` instead of modifying stock ADK scripts in place.
- Boots into WinPE and automatically searches `C:` through `Z:` for exactly one prepared source containing:
  - `\sources\install.wim`
  - `\sources\winpe-autodeploy.tag`
- Wipes the configured target disk and creates a configurable GPT layout:
  - EFI `S:` (100 MB)
  - MSR (16 MB)
  - Windows `W:` (Primary — auto or specified size)
  - Optional Data partition using the remaining space after a fixed-size Windows partition
  - Recovery `R:` (default 1024 MB, configurable)
- Applies the selected WIM index with `DISM`, rebuilds boot files with `BCDBoot`, and stages `unattend.xml`, `SetupComplete.cmd`, and first-logon scripts into the deployed OS.
- Preserves the main deployment log to:
  - `X:\AutoDeploy.log`
  - `W:\Windows\Temp\AutoDeploy.log`
  - `\<deployment-media>\DeployLogs\AutoDeploy.log` when the source media is still available
- Optionally copies `\payload\docker-images\*` from deployment media into `W:\Payload\DockerImages` (staged to `C:\Payload\DockerImages` in the deployed OS).
- Optionally injects out-of-box drivers from `X:\drivers-payload` into the deployed Windows Driver Store using `DISM /Add-Driver /Recurse`.

## Repository layout

- `scripts\Build-WinPEAutoDeploy.ps1`
  - Creates or rebuilds the WinPE work directory.
  - Mounts `media\sources\boot.wim`.
  - Renders template tokens such as `__TARGET_DISK__` and `__WIM_INDEX__`.
  - Injects the runtime and post-deployment assets into `Windows\System32` inside the mounted image.
  - Optionally embeds out-of-box drivers into `X:\drivers-payload` via `-DriversDirectory`.
- `scripts\Prepare-WinPEUsb.ps1`
  - Destructively prepares a dual-partition USB disk (MBR for compatibility).
  - Uses `MakeWinPEMedia.cmd /UFD` to populate the FAT32 boot partition.
  - Copies `install.wim`, `winpe-autodeploy.tag`, and optional payload files to the NTFS data partition.
- `scripts\Generate-WinPEIso.ps1`
  - Packages an existing customized work directory as an ISO.
  - Can optionally bundle `install.wim` and payload files into a temporary staging copy before packaging.
  - Leaves the original `WinPEWorkDir\media` tree unchanged.
- `scripts\Export-CleanWinPEIso.ps1`
  - Produces a stock WinPE ISO with no project-specific automation injected.
  - Intended for maintenance or image-capture scenarios.
- `templates\deploy.cmd`
  - Main WinPE runtime entry.
  - Finds the source image, partitions the target disk, applies Windows, configures boot, stages files, and shuts down WinPE.
- `templates\startnet.cmd`
  - WinPE bootstrap entry point that runs `wpeinit` and then `deploy.cmd`.
- `templates\unattend.xml`
  - Configures OOBE bypass for automated deployment.
  - oobeSystem pass: Skips network setup and privacy settings. Account creation screens remain visible.
  - Does not configure locale, product key, or other OOBE answers.
  - Note: generalize pass is not needed because the deployment flow does not run sysprep after driver injection.
- `templates\SetupComplete.cmd`
  - Runs `reagentc /enable` inside the deployed OS.
  - Runs `register-firstboot.ps1` to register the first-logon task.
- `templates\firstboot-launcher.vbs`
  - Launches `firstboot.ps1` through `wscript.exe` with a hidden window.
- `templates\register-firstboot.ps1`
  - Registers `HKLM\...\Run\CodexFirstBoot` to launch the VBS wrapper.
  - Registers `HKLM\...\Run\DockerDesktopAutoStart` for all users when Docker Desktop is already installed.
- `templates\firstboot.ps1`
  - Runs on user logon from `HKLM\...\Run\CodexFirstBoot`.
  - Ensures Docker is present and ready (using `docker desktop start` and polling `docker info`).
  - Scans ordered `NN-name` service directories under `C:\Payload\DockerImages`.
  - Executes `load_images.bat` and `install_service.bat` in visible windows.
  - `*win11-install` service: Parses `C:\CloudPrimeAppstore\docker-compose.yml` to display 1Panel credentials, falling back to built-in defaults.
  - `*CIKE-install` service: Displays CIKE success information.
  - Removes the Run registration only after all detected payload scripts return exit code `0`.
- `payload\docker-images\`
  - Optional Docker payload directories staged into the deployed OS for first-logon automation.
- `payload\drivers\`
  - Optional out-of-box driver packages organized by category (chipset, graphics, network, audio).
  - Drivers are embedded into the WinPE image at build time via `-DriversDirectory` and injected into the deployed Windows Driver Store at deploy time.

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
  -TargetDisk auto
```

Important defaults:

- `-Architecture amd64`
- `-WinPEWorkDir C:\WinPE_AutoDeploy_amd64`
- `-WimIndex 1`
- `-TargetDisk auto` (selects the first disk, disk 0; or specify a disk number directly)

With driver injection:

```powershell
.\scripts\Build-WinPEAutoDeploy.ps1 `
  -Force `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -WimIndex 1 `
  -TargetDisk auto `
  -DriversDirectory C:\Drivers\MyHardware
```

The `-DriversDirectory` parameter embeds all driver files from the specified directory into the root of the WinPE image at `X:\drivers-payload`. At deploy time, these drivers are injected into the target Windows Driver Store using `DISM /Add-Driver /Recurse`.

With custom partition layout (256 GB Windows + Data partition):

```powershell
.\scripts\Build-WinPEAutoDeploy.ps1 `
  -Force `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -WimIndex 1 `
  -TargetDisk auto `
  -WindowsPartitionSizeGB 256 `
  -CreateDataPartition `
  -WindowsPartitionLabel "System" `
  -DataPartitionLabel "Data"
```

Partition customization parameters:

- `-WindowsPartitionSizeGB` — Size of Windows partition in GB. `0` (default) = use all remaining space minus Recovery.
- `-CreateDataPartition` — If set, creates a Data partition using remaining space after Windows.
- `-WindowsPartitionLabel` — Custom label for Windows partition (empty = no label).
- `-DataPartitionLabel` — Custom label for Data partition (empty = default "Data").
- `-RecoverySizeMB` — Recovery partition size in MB (default: 1024).

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

## Parameter format requirements

To avoid ambiguity and runtime errors, all parameters follow strict format requirements:

### Build parameters (`Build-WinPEAutoDeploy.ps1`)

| Parameter | Type | Format | Valid Values | Default |
|-----------|------|--------|--------------|---------|
| `-Architecture` | String | Literal | `amd64` only | `amd64` |
| `-WinPEWorkDir` | String | Path | Valid absolute or relative path | `C:\WinPE_AutoDeploy_amd64` |
| `-WimIndex` | Integer | Number | Image index passed to `DISM /Apply-Image` | `1` |
| `-TargetDisk` | String | `auto` or Number | `auto` or `0-9+` (disk number) | `auto` |
| `-DriversDirectory` | String | Path (optional) | Valid directory path, omit if unused | *(none)* |
| `-Force` | Switch | Flag | Present/absent | *(absent)* |
| `-WindowsPartitionSizeGB` | Integer | Number | `0` = auto, or a fixed Windows size in GB | `0` |
| `-CreateDataPartition` | Switch | Flag | Present/absent | *(absent)* |
| `-WindowsPartitionLabel` | String | Label (optional) | Windows volume label text; avoid double quotes `"` | *(empty)* |
| `-DataPartitionLabel` | String | Label (optional) | Windows volume label text; avoid double quotes `"` | *(empty = "Data")* |
| `-RecoverySizeMB` | Integer | Number | Recovery partition size in MB | `1024` |

**Important notes:**
- **TargetDisk**: Must be either the literal string `auto` (selects first disk) or a non-negative integer (`0`, `1`, `2`, etc.)
- **Partition labels**: Windows labels cannot contain double quotes `"`. Use single quotes or escape properly in PowerShell: `-WindowsPartitionLabel 'My System'`
- **Partition sizes**: Use `0` for auto-sizing the Windows partition. Fixed Windows size is specified in GB, and Recovery size is specified in MB. The optional Data partition uses the remaining space between Windows and Recovery.

### USB preparation parameters (`Prepare-WinPEUsb.ps1`)

| Parameter | Type | Format | Valid Values | Required |
|-----------|------|--------|--------------|----------|
| `-UsbDiskNumber` | Integer | Number | Disk number from `Get-Disk` | Yes |
| `-Architecture` | String | Literal | `amd64` only | No |
| `-WinPEWorkDir` | String | Path | Valid directory path | No |
| `-InstallWimPath` | String | Path | Valid `.wim` file path | Yes |
| `-DockerImagesDirectory` | String | Path (optional) | Valid directory path | No |
| `-BootPartitionSizeMB` | Integer | Number | `1024-32768` MB | No (`2048`) |
| `-AdkRoot` | String | Path | Windows ADK root path | No |

### ISO generation parameters (`Generate-WinPEIso.ps1`)

| Parameter | Type | Format | Valid Values | Required |
|-----------|------|--------|--------------|----------|
| `-WinPEWorkDir` | String | Path | Valid directory path | Yes |
| `-IsoPath` | String | Path (optional) | Output `.iso` path | No |
| `-InstallWimPath` | String | Path (optional) | Valid `.wim` file path | No |
| `-DockerImagesDirectory` | String | Path (optional) | Valid directory path | No |
| `-AdkRoot` | String | Path | Windows ADK root path | No |
| `-Force` | Switch | Flag | Present/absent | No |

## Runtime behavior

When the target machine boots into the prepared WinPE image:

1. `startnet.cmd` runs `wpeinit` and launches `deploy.cmd`.
2. `deploy.cmd` scans `C:` through `Z:` for exactly one valid deployment source.
3. If zero or multiple matches are found, deployment stops before touching the target disk.
4. DiskPart wipes the configured target disk and creates a configurable GPT partition layout:
   - EFI `S:` (100 MB), MSR (16 MB), Windows `W:`, Recovery `R:`.
   - Windows partition can be auto-sized (remaining space) or fixed size.
   - Optional Data partition is created only when `-WindowsPartitionSizeGB` is fixed and `-CreateDataPartition` is set; it uses the remaining space before Recovery.
5. `DISM /Apply-Image` applies the configured WIM index to `W:\`.
6. `BCDBoot` writes UEFI boot files to `S:\`.
7. If `X:\drivers-payload` exists, `DISM /Add-Driver /Recurse` injects all out-of-box drivers into the deployed Windows Driver Store.
8. `unattend.xml` is staged to `W:\Windows\Panther\unattend.xml`. The unattend.xml file configures OOBE bypass:
   - oobeSystem pass: Skips network setup and privacy settings. Account creation screens remain visible.
9. `W:\Windows\System32\reagentc.exe /Setreimage` points WinRE to `W:\Windows\System32\Recovery`.
10. `firstboot.ps1`, `register-firstboot.ps1`, and `SetupComplete.cmd` are staged into the deployed OS.
11. If present, `\payload\docker-images\*` is copied to `W:\Payload\DockerImages`.
12. Logs are persisted and WinPE shuts down. The next power-on starts Windows OOBE from the deployed disk.

## First-logon behavior

After Windows boots:

- `SetupComplete.cmd` enables WinRE with `reagentc /enable`.
- `register-firstboot.ps1` creates `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\CodexFirstBoot`.
- `register-firstboot.ps1` points that Run entry at `wscript.exe` and `firstboot-launcher.vbs` so the hidden first-logon task does not flash an empty console.
- If Docker Desktop already exists at `C:\Program Files\Docker\Docker\Docker Desktop.exe`, `register-firstboot.ps1` also creates `HKLM\...\Run\DockerDesktopAutoStart`.
- `firstboot.ps1` runs on the first successful user logon and behaves as follows:
  - If `C:\Payload\DockerImages` does not exist, it writes `done.tag`, removes the Run entry, and exits.
  - If `C:\Payload\DockerImages` exists but contains no ordered `NN-name` service directories, it writes `done.tag`, removes the Run entry, and exits.
  - If `docker.exe` is missing, it exits with code `1` so the Run entry remains for the next logon.
  - It starts Docker Desktop in the background with `docker desktop start`, falls back to launching `Docker Desktop.exe` directly when needed, then waits for the `Docker Desktop` process to appear.
  - After the process appears, it performs a short `docker info` readiness check before running any payload script.
  - If Docker becomes ready, it scans `C:\Payload\DockerImages\NN-name\` service directories in name order.
  - For each service directory, it runs `load_images.bat` when present and `install_service.bat` when present.
  - Payload logs are written to `C:\ProgramData\FirstBoot\PayloadLogs\<service>_<script>_<timestamp>.log`.
  - `load_images.bat` and `install_service.bat` run in visible `cmd.exe` windows during first-logon automation. Window text and close behavior are controlled by the payload batch files.
  - `*win11-install` opens a detached CloudPrimeAppStore credential window after its `install_service.bat` succeeds.
  - `*CIKE-install` opens a detached CIKE success window after its `install_service.bat` succeeds.
  - Final success popups are detached windows and do not block or interrupt the first-logon flow from completing.
  - It creates `C:\ProgramData\FirstBoot\done.tag` and removes the Run entry only if all detected payload scripts succeed.

Important limitation:

- Retry behavior covers both Docker readiness failures and payload script failures.
- Payload services are discovered by ordered service directories and fixed script names: `load_images.bat` and `install_service.bat`.

## Payload layout

On deployment media:

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

Driver packages are not discovered from deployment media at runtime. Pass their source directory to `Build-WinPEAutoDeploy.ps1 -DriversDirectory`; the build embeds the tree into `boot.wim` as `X:\drivers-payload`.

Inside the deployed OS after staging:

```text
C:\Payload\DockerImages\...
C:\ProgramData\FirstBoot\firstboot.ps1
C:\ProgramData\FirstBoot\firstboot-launcher.vbs
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
  - `C:\ProgramData\FirstBoot\PayloadLogs\<service>_load_images_<timestamp>.log`
  - `C:\ProgramData\FirstBoot\PayloadLogs\<service>_install_service_<timestamp>.log`
