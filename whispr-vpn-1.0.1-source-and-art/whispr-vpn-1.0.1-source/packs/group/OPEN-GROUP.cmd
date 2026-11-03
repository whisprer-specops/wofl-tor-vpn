@echo off
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7.2 or later is required. Install PowerShell 7, then retry.
  pause
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -STA -File "%~dp0Open-Group.ps1"
if errorlevel 1 pause
