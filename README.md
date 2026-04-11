# WinPE Auto Deploy

This workspace contains a reusable WinPE automation set for applying a single `install.wim` from a USB data partition.

## What it builds

- UEFI-only WinPE automation on `amd64`
- Automatic scan of mounted volumes `C:` through `Z:` for `\sources\install.wim`
- Automatic wipe of target `Disk 0`
- Automatic `DISM /Apply-Image`, `BCDBoot`, and WinRE configuration
- Unified deployment log at `X:\AutoDeploy.log`

## Files

- `scripts\Build-WinPEAutoDeploy.ps1`
- `scripts\Generate-WinPEIso.ps1`
- `scripts\Prepare-WinPEUsb.ps1`
- `templates\startnet.cmd`
- `templates\deploy.cmd`
- `templates\diskpart-uefi.txt`

## Usage

Run these commands from a normal elevated PowerShell session. The scripts bootstrap the required ADK environment variables themselves.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Build-WinPEAutoDeploy.ps1 -Force -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 -WimIndex 1 -TargetDisk 0
.\scripts\Prepare-WinPEUsb.ps1 -UsbDiskNumber 2 -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 -InstallWimPath C:\WorkSpace\Win11_Custom\install.wim
```

To generate an ISO for VM testing after the WinPE work directory has been built:

```powershell
.\scripts\Generate-WinPEIso.ps1 -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 -Force
```

## Notes

- `Prepare-WinPEUsb.ps1` is destructive. It clears the selected USB disk and recreates it as a dual-partition device.
- The USB disk is initialized as `MBR` for broad removable-device firmware compatibility. The deployed target OS disk is still partitioned as `GPT`.
- The deploy script only accepts exactly one `\sources\install.wim`. If zero or multiple matches are found, deployment stops before any target disk changes are made.
- The prepared USB data partition also gets a `\sources\winpe-autodeploy.tag` marker. The WinPE deploy script requires both files, which prevents it from accidentally picking up an unrelated `install.wim` on an internal disk.
- Recovery partition metadata is finalized after the WinRE copy step, so the partition is writable during deployment and hidden again before reboot.
- The deployment prefers `W:\Windows\System32\Recovery\Winre.wim` when it exists. If that file is missing after apply, deployment still completes; only WinRE remains disabled.
- `X:\AutoDeploy.log` now uses explicit `[INFO]`, `[WARNING]`, and `[ERROR]` markers to make postmortem review easier.
- To change the default target disk or WIM index, rebuild the WinPE work directory with different `-TargetDisk` or `-WimIndex` values.
- `Generate-WinPEIso.ps1` creates a bootable WinPE ISO from the existing work directory. Use it for Hyper-V Gen 2 or other UEFI VM tests.

## Partition layout notes

- `diskpart-uefi.txt` intentionally stays as a pure command file because `diskpart /s` parsing is less forgiving than PowerShell or batch.
- The created layout is: EFI (`S:`), MSR, Windows (`W:`), Recovery (`R:`).
- The Recovery partition is created after the Windows partition, then marked as a true hidden Windows recovery partition later by `deploy.cmd`.
