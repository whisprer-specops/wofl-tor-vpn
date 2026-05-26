# Stop and delete service
sc.exe stop TorVPN | Out-Null
Start-Sleep -Seconds 1
sc.exe delete TorVPN | Out-Null
Write-Host "[+] Service removed"

# Optional: Remove files
$dest = "C:\ProgramData\torvpn"
if (Test-Path $dest) {
  Remove-Item -Recurse -Force $dest
  Write-Host "[+] Removed $dest"
}
