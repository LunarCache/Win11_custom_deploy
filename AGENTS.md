# Repository Guidelines

## Project Structure & Module Organization
This repository builds and packages a customized WinPE deployment environment for Windows 11.

- `scripts/`: primary PowerShell entry points such as `Build-WinPEAutoDeploy.ps1`, `Prepare-WinPEUsb.ps1`, and shared helpers in `Common-WinPEHelpers.ps1`.
- `templates/`: injected runtime assets and deployment templates, including `deploy.cmd`, `startnet.cmd`, `unattend.xml`, and first-boot scripts.
- `docs/`: design and architecture notes.
- `win11-install/`: deployment payload artifacts such as `.tar`, `.bat`, and app bundles used after first logon.
- `README.md`: operator workflow, prerequisites, and runtime behavior. Keep it aligned with script changes.

## Build, Test, and Development Commands
Run all build or media-prep scripts from an elevated PowerShell session.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Build-WinPEAutoDeploy.ps1 -Force -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 -WimIndex 1 -TargetDisk 0
.\scripts\Prepare-WinPEUsb.ps1 -UsbDiskNumber 1 -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 -InstallWimPath C:\Images\install.wim
.\scripts\Generate-WinPEIso.ps1 -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 -Force
.\scripts\Export-CleanWinPEIso.ps1 -Force
```

`Build-...` prepares `boot.wim`, `Prepare-...` creates the dual-partition USB, `Generate-...` packages the customized ISO, and `Export-Clean...` produces a stock WinPE ISO.

## Coding Style & Naming Conventions
Use PowerShell with 4-space indentation, `Set-StrictMode -Version Latest`, and `$ErrorActionPreference = 'Stop'` for operational scripts. Prefer approved verb-noun function names such as `New-DirectoryIfMissing`. Name scripts and helpers in PascalCase, and keep template token names uppercase with double underscores, for example `__TARGET_DISK__`.

Favor small helper functions, explicit parameter validation, and ASCII output for WinPE-consumed batch or DiskPart files.

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
`Prepare-WinPEUsb.ps1` and WinPE runtime deployment both wipe disks. Do not relax disk checks without updating `README.md` and documenting the risk clearly. Keep ADK path assumptions, target disk defaults, and payload layout consistent across `scripts/`, `templates/`, and `docs/`.
