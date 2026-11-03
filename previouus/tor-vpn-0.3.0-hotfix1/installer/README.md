# Staging

`stage.ps1` downloads and checksums the pinned official Tor bundle before
installation. Repair.ps1 invokes it automatically. It supports Windows
PowerShell 5.1 and PowerShell 7; tar.exe must be available (included in current
Windows 10/11).

The previous 0.2.0 Inno EXE and staging cache were removed. The supported entry
point for this repair release is `..\Repair.ps1` from elevated PowerShell.
