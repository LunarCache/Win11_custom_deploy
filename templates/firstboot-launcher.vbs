Option Explicit

Dim shell
Dim baseDir
Dim scriptPath
Dim command

baseDir = "C:\ProgramData\FirstBoot"
scriptPath = baseDir & "\firstboot.ps1"
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """"

Set shell = CreateObject("WScript.Shell")
shell.Run command, 0, False
