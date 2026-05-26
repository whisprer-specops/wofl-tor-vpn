param(
  [string]$Binary = ".\target\release\torvpn-win.exe",
  [string]$Profile = ".\profiles\default_win.toml"
)

$dest = "C:\ProgramData\torvpn"
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item $Binary "$dest\torvpn-win.exe" -Force
Copy-Item $Profile "$dest\profile.toml" -Force

# Install service
$binpath = "`"$dest\torvpn-win.exe`" ServiceRun --profile `"$dest\profile.toml`""
sc.exe create TorVPN binPath= $binpath start= auto | Out-Null
sc.exe description TorVPN "Tor-routed VPN daemon" | Out-Null
sc.exe failure TorVPN reset= 60 actions= restart/5000 | Out-Null

Write-Host "[+] Installed service 'TorVPN' with binpath: $binpath"
Start-Sleep -Seconds 1
sc.exe start TorVPN | Out-Null
Write-Host "[+] Service started"
