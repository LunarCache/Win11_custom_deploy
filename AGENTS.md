# Repository Guidelines

## Project Structure & Module Organization
This repository builds and packages a customized WinPE deployment environment for Windows 11.

- `scripts/`: primary PowerShell entry points and helpers:
  - `Build-WinPEAutoDeploy.ps1` - builds WinPE work directory and injects automation
  - `Prepare-WinPEUsb.ps1` - prepares dual-partition USB deployment media
  - `Generate-WinPEIso.ps1` - packages work directory as ISO
  - `Export-CleanWinPEIso.ps1` - produces stock WinPE ISO
  - `Common-WinPEHelpers.ps1` - shared helper functions used by all scripts
- `templates/`: injected runtime assets and deployment templates:
  - `startnet.cmd` - WinPE bootstrap entry
  - `deploy.cmd` - main deployment logic
  - `unattend.xml` - OOBE configuration
  - `SetupComplete.cmd` - post-deployment WinRE setup
  - `register-firstboot.ps1` - registers first-logon automation
  - `firstboot-launcher.vbs` - VBS wrapper for hidden execution
  - `firstboot.ps1` - Docker payload orchestration on first logon
- `docs/`: design notes, technical solution documents, SOPs, ISO creation guides, and generated delivery documents such as `.docx`.
- `payload/`: optional deployment payload staging assets:
  - `docker-images/` - Docker payload directories for first-logon automation
  - `drivers/` - optional driver source staging area; runtime driver injection only uses drivers embedded into `boot.wim` through `-DriversDirectory`
- `README.md`: operator workflow, prerequisites, and runtime behavior. Keep it aligned with script changes.

## Build, Test, and Development Commands
Run all build or media-prep scripts from an elevated PowerShell session.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Build-WinPEAutoDeploy.ps1 -Force -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 -WimIndex 1 -TargetDisk auto
.\scripts\Prepare-WinPEUsb.ps1 -UsbDiskNumber 1 -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 -InstallWimPath C:\Images\install.wim
.\scripts\Generate-WinPEIso.ps1 -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 -Force
.\scripts\Export-CleanWinPEIso.ps1 -Force
```

`Build-...` prepares `boot.wim` with automation injected. It supports partition customization (Windows partition size, optional remaining-space Data partition, Recovery size), driver injection via `-DriversDirectory`, and configurable target disk. `-TargetDisk auto` currently resolves to disk `0` at WinPE runtime; use an explicit disk number when hardware layout is not guaranteed. `Prepare-...` creates the dual-partition USB. `Generate-...` packages the customized ISO (optionally bundling install.wim and payloads via temporary staging). `Export-Clean...` produces a stock WinPE ISO without automation.

## Coding Style & Naming Conventions
Use PowerShell with 4-space indentation, `Set-StrictMode -Version Latest`, and `$ErrorActionPreference = 'Stop'` for operational scripts. Prefer approved verb-noun function names such as `New-DirectoryIfMissing`. Name scripts and helpers in PascalCase, and keep template token names uppercase with double underscores, for example `__TARGET_DISK__`.

All scripts should use `SupportsShouldProcess` for destructive operations and validate paths before any disk modifications. Scripts must import `Common-WinPEHelpers.ps1` for shared functions like `Set-AdkEnvironment`, `Test-IsAdministrator`, and `New-DirectoryIfMissing`.

Favor small helper functions, explicit parameter validation with `[ValidateRange]`, `[ValidateSet]`, and ASCII output for WinPE-consumed batch or DiskPart files.

For Chinese delivery `.docx` documents, use `宋体` for Chinese text and `Times New Roman` for Latin text, numbers, and technical identifiers. When a Markdown source has a matching generated `.docx`, update and validate both so the deliverable stays aligned with the source.

## Testing Guidelines
There is no automated test suite in this repository today. Validate changes with:

- syntax checks: `powershell -NoProfile -File .\scripts\<script>.ps1 -WhatIf` when supported
- ISO generation in a disposable VM
- USB preparation only against the intended removable disk

Document manual validation steps in the PR when changing deployment logic or disk operations.

## Commit & Pull Request Guidelines
Recent history uses short, imperative subjects, sometimes with prefixes like `feat:`, `fix`, or `docs:`. Keep commit titles concise and action-oriented, for example `fix: validate payload path before disk wipe`.

PRs should include:

- the operator-facing impact
- any destructive or disk-layout changes
- exact validation performed
- screenshots or logs when changing runtime behavior or documentation output

## Safety & Configuration
`Prepare-WinPEUsb.ps1`, WinPE runtime deployment (`deploy.cmd`), and DiskPart operations all wipe disks. Do not relax disk checks without updating `README.md` and documenting the risk clearly. Keep ADK path assumptions, target disk defaults, partition layouts, payload directory structures, and driver injection paths consistent across `scripts/`, `templates/`, and `docs/`.

Driver packages are embedded into `boot.wim` at build time as `X:\drivers-payload` when `Build-WinPEAutoDeploy.ps1 -DriversDirectory` is used. Current runtime deployment does not scan `payload\drivers` on USB or ISO media.

Key safety checks in place:
- `Prepare-WinPEUsb.ps1` refuses to operate on disks marked as `IsBoot` or `IsSystem`
- `deploy.cmd` stops if zero or multiple valid image sources are found
- Source discovery requires both `install.wim` and `winpe-autodeploy.tag` to prevent accidental deployment
- Target disk is validated before any partition operations
