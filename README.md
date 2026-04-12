# WinPE Auto Deploy

This workspace contains a reusable WinPE automation set for applying a single `install.wim` from a USB data partition.

## What it builds

- UEFI-only WinPE automation on `amd64`
- Automatic scan of mounted volumes `C:` through `Z:` for `\sources\install.wim`
- Automatic wipe of target `Disk 0`
- Automatic `DISM /Apply-Image`, `BCDBoot`, WinRE path registration, and SetupComplete WinRE enable
- Offline OOBE configuration that allows skipping the network requirement on first boot
- Optional first-logon Docker payload import from `C:\Payload\DockerImages`
- Unified deployment log at `X:\AutoDeploy.log`

## Files

- `scripts\Build-WinPEAutoDeploy.ps1`
- `scripts\Generate-WinPEIso.ps1`
- `scripts\Prepare-WinPEUsb.ps1`
- `templates\firstboot.ps1`
- `templates\register-firstboot.ps1`
- `templates\SetupComplete.cmd`
- `templates\startnet.cmd`
- `templates\deploy.cmd`
- `templates\diskpart-uefi.txt`

## Usage

Run these commands from a normal elevated PowerShell session. The scripts bootstrap the required ADK environment variables themselves.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Build-WinPEAutoDeploy.ps1 -Force -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 -WimIndex 1 -TargetDisk 0
.\scripts\Prepare-WinPEUsb.ps1 -UsbDiskNumber 1 -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 -InstallWimPath C:\WorkSpace\Win11_Custom\install.wim
```

If you also want Docker image tar files copied to the deployment media:

```powershell
.\scripts\Prepare-WinPEUsb.ps1 -UsbDiskNumber 1 -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 -InstallWimPath C:\WorkSpace\Win11_Custom\install.wim -DockerImagesDirectory C:\Payload\DockerImages
```

To generate an ISO for VM testing after the WinPE work directory has been built:

```powershell
.\scripts\Generate-WinPEIso.ps1 -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 -Force
```

## Notes

- `Prepare-WinPEUsb.ps1` is destructive. It clears the selected USB disk and recreates it as a dual-partition device.
- `Prepare-WinPEUsb.ps1` now defaults the FAT32 boot partition to `2048 MB`. Override it with `-BootPartitionSizeMB` if you need a different size.
- The USB disk is initialized as `MBR` for broad removable-device firmware compatibility. The deployed target OS disk is still partitioned as `GPT`.
- The deploy script only accepts exactly one `\sources\install.wim`. If zero or multiple matches are found, deployment stops before any target disk changes are made.
- The prepared USB data partition also gets a `\sources\winpe-autodeploy.tag` marker. The WinPE deploy script requires both files, which prevents it from accidentally picking up an unrelated `install.wim` on an internal disk.
- The Recovery partition is created with its final GPT type and hidden attributes directly during `diskpart` execution.
- The deployment sets the WinRE path to `W:\Windows\System32\Recovery` during WinPE. `Build-WinPEAutoDeploy.ps1` now injects `WinPE-WMI` and `WinPE-WinReCfg` (with `zh-cn` and `en-us` language packs) into the WinPE image. Additionally, `deploy.cmd` uses adaptive search logic to locate `reagentc.exe` in either the WinPE environment or the deployed OS, ensuring successful configuration even if component injection is partially skipped. `SetupComplete.cmd` then runs `reagentc /enable` inside the deployed OS to finalize the activation.
- The deployment also writes `BypassNRO=1` into the offline SOFTWARE hive so Windows OOBE can skip the network requirement on first boot.
- `X:\AutoDeploy.log` now uses explicit `[INFO]`, `[WARNING]`, and `[ERROR]` markers to make postmortem review easier.
- Before WinPE reboots or stops on an error, it also tries to preserve the current log to the deployed OS at `C:\Windows\Temp\AutoDeploy.log` and to the deployment media at `\DeployLogs\AutoDeploy.log` when those destinations are available.
- If `\payload\docker-images` exists on the deployment media, WinPE copies it into `C:\Payload\DockerImages` inside the deployed OS.
- `SetupComplete.cmd` first runs `reagentc /enable`, then registers a persistent HKLM Run entry, and `firstboot.ps1` removes that entry only after all Docker tar files import successfully. This allows automatic retry on later logons if Docker is not ready on the first attempt.
- To change the default target disk or WIM index, rebuild the WinPE work directory with different `-TargetDisk` or `-WimIndex` values.
- `Generate-WinPEIso.ps1` creates a bootable WinPE ISO from the existing work directory. Use it for Hyper-V Gen 2 or other UEFI VM tests.

## Payload layout

- Deployment media source partition:
  - `\sources\install.wim`
  - `\sources\winpe-autodeploy.tag`
  - `\payload\docker-images\*.tar` (optional)
- Deployed OS after WinPE staging:
  - `C:\Payload\DockerImages\*.tar`
  - `C:\ProgramData\FirstBoot\firstboot.ps1`
  - `C:\ProgramData\FirstBoot\register-firstboot.ps1`
  - `C:\Windows\Setup\Scripts\SetupComplete.cmd`

## Partition layout notes

- `diskpart-uefi.txt` intentionally stays as a pure command file because `diskpart /s` parsing is less forgiving than PowerShell or batch.
- The created layout is: EFI (`S:`), MSR, Windows (`W:`), Recovery (`R:`).
- The Recovery partition is created after the Windows partition, assigned drive letter `R:`, and then marked with the Windows recovery GPT type and attributes by `diskpart-uefi.txt`.
