#requires -Version 7.0
#requires -RunAsAdministrator
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:tray=$null;$script:timer=$null;$script:probe=$null;$script:operation=$null;$script:launch=$null
$script:icons=@{};$script:locked=$false;$script:context=$null
$script:trayMutex=[Threading.Mutex]::new($false,'Global\whisprHybridTray010')
try {
    if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA){throw 'Use Open-Tray.ps1; the tray requires PowerShell -STA.'}
    try{$script:locked=$script:trayMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$script:locked=$true}
    if(-not $script:locked){throw 'The Hybrid VPN tray is already running. Check the notification overflow (^).'}
    . "$PSScriptRoot/client/Common.ps1"
    . "$PSScriptRoot/tray/Model.ps1"
    $script:homeDir=Get-HybridHome;$script:stateDir=Get-HybridState
    if($PSScriptRoot -ne $script:homeDir){throw 'Use the installed Open-Tray.ps1.'}
    Assert-HybridManifest $script:homeDir
    Assert-TrayAddon $script:homeDir
    $script:guard='UNKNOWN';$script:guardAt=[datetime]::MinValue;$script:session=$null
    $script:peer=Get-Content -LiteralPath (Join-Path $script:stateDir 'peer.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-TrayPeer $script:peer $script:peer.ssh_alias
    $profiles=Join-Path $script:stateDir 'profiles';[void](New-Item -ItemType Directory -Path $profiles -Force)
    $cached=Join-Path $profiles ($script:peer.ssh_alias+'.json')
    # Preserve the known working exit for later re-selection. This never changes active peer.json.
    if(-not (Test-Path -LiteralPath $cached)){Write-HybridJson $script:peer $cached}
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HybridTrayNative {
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
}
'@
    foreach($color in @('green','orange','red','gray')){
        $bitmap=[Drawing.Bitmap]::new(32,32);$graphics=[Drawing.Graphics]::FromImage($bitmap)
        $brush=[Drawing.SolidBrush]::new([Drawing.Color]::FromName($color));$pen=[Drawing.Pen]::new([Drawing.Color]::White,2)
        try {
            $graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.Clear([Drawing.Color]::Transparent);$graphics.FillEllipse($brush,3,3,26,26);$graphics.DrawEllipse($pen,3,3,26,26)
            $handle=$bitmap.GetHicon()
            try {$borrowed=[Drawing.Icon]::FromHandle($handle);$script:icons[$color]=$borrowed.Clone()}
            finally {[void][HybridTrayNative]::DestroyIcon($handle)}
        } finally {$pen.Dispose();$brush.Dispose();$graphics.Dispose();$bitmap.Dispose()}
    }
    $script:context=[Windows.Forms.ApplicationContext]::new()
    $script:tray=[Windows.Forms.NotifyIcon]::new()
    $script:tray.Icon=$script:icons.gray;$script:tray.Text='whispr Hybrid VPN — checking status'
    $script:menu=[Windows.Forms.ContextMenuStrip]::new()
    $script:tray.ContextMenuStrip=$script:menu
    function Add-TrayItem([string]$Text,[scriptblock]$Action){
        $item=[Windows.Forms.ToolStripMenuItem]::new($Text)
        if($Action){$item.add_Click($Action)}
        [void]$script:menu.Items.Add($item)
        return $item
    }
    function Show-TrayError($ErrorRecord){
        [void][Windows.Forms.MessageBox]::Show([string]$ErrorRecord,'Hybrid VPN','OK','Error')
    }
    function Get-TrayOwnerAlive($Session){
        if(-not $Session){return $false}
        $process=$null
        try {
            $process=[Diagnostics.Process]::GetProcessById([int]$Session.OwnerPid)
            return (-not $process.HasExited -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$Session.OwnerStartedTicks -and $process.MainModule.FileName -eq [string]$Session.OwnerPath)
        }catch{return $false}finally{if($process){$process.Dispose()}}
    }
    function Get-TrayTunnelUp($Session){
        if(-not $Session -or -not $Session.TunnelGuid){return $false}
        foreach($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()){
            if($nic.Id.Trim('{}') -eq ([string]$Session.TunnelGuid).Trim('{}') -and $nic.OperationalStatus -eq [Net.NetworkInformation.OperationalStatus]::Up){return $true}
        }
        return $false
    }
    function Start-TrayScript([string]$Name,[string[]]$Arguments=@(),[bool]$Visible=$true){
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
        $start.WorkingDirectory=$script:homeDir
        # All script names and switches are supplied by fixed menu actions, never by user text.
        $start.UseShellExecute=$true
        $start.Arguments='-NoLogo -NoProfile -File "'+(Join-Path $script:homeDir $Name)+'"'
        foreach($argument in $Arguments){
            if($argument -notmatch '^[a-zA-Z0-9-]+$'){throw 'Invalid launch argument.'}
            $start.Arguments+=' '+$argument
        }
        $start.WindowStyle=if($Visible){[Diagnostics.ProcessWindowStyle]::Normal}else{[Diagnostics.ProcessWindowStyle]::Minimized}
        return [Diagnostics.Process]::Start($start)
    }
    function Start-TrayRecovery([bool]$ExitAfter){
        if($script:operation){throw 'Another tray operation is running.'}
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($arg in @('-NoLogo','-NoProfile','-File',(Join-Path $script:homeDir 'Recover.ps1'))){$start.ArgumentList.Add($arg)}
        $p=[Diagnostics.Process]::Start($start)
        $script:operation=@{Kind='recovery';Process=$p;Out=$p.StandardOutput.ReadToEndAsync();Err=$p.StandardError.ReadToEndAsync();ExitAfter=$ExitAfter}
    }
    function Update-Tray {
        if($script:operation -and $script:operation.Process.HasExited){
            $op=$script:operation;$script:operation=$null
            try {
                if($op.Kind -eq 'recovery'){
                    $output=$op.Out.GetAwaiter().GetResult()+$op.Err.GetAwaiter().GetResult()
                    [IO.File]::WriteAllText((Join-Path $script:stateDir 'tray-recovery.log'),$output)
                    if($op.Process.ExitCode -ne 0){throw "Recovery failed. Protection may remain armed.`n$output"}
                    Assert-TrayDisconnected $script:homeDir
                    if($op.ExitAfter){$script:context.ExitThread();return}
                }
                # Preparation publishes a profile only after successful, validated completion.
            }catch{Show-TrayError $_}finally{$op.Process.Dispose()}
        }
        if($script:probe){
            if($script:probe.Process.HasExited){
                $p=$script:probe
                try {
                    $value=$p.Out.GetAwaiter().GetResult().Trim()
                    [void]$p.Err.GetAwaiter().GetResult()
                    $script:guard=if($p.Process.ExitCode -eq 0 -and $value -in @('ARMED','DISARMED')){$value}else{'UNKNOWN'}
                    $script:guardAt=[datetime]::UtcNow
                }finally{$p.Process.Dispose();$script:probe=$null}
            }elseif(([datetime]::UtcNow-$script:probe.Started).TotalSeconds -gt 4){
                try{$script:probe.Process.Kill()}catch{}
                $script:probe.Process.Dispose();$script:probe=$null;$script:guard='UNKNOWN'
            }
        }
        if(-not $script:probe){
            $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $script:homeDir 'bin/whispr-vpn-guard.exe'))
            $start.ArgumentList.Add('status');$start.UseShellExecute=$false;$start.CreateNoWindow=$true
            $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            $p=[Diagnostics.Process]::Start($start)
            $script:probe=@{Process=$p;Out=$p.StandardOutput.ReadToEndAsync();Err=$p.StandardError.ReadToEndAsync();Started=[datetime]::UtcNow}
        }
        $script:session=$null
        $sessionPath=Join-Path $script:stateDir 'session.json'
        if(Test-Path -LiteralPath $sessionPath){$script:session=Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json -AsHashtable}
        $script:peer=Get-Content -LiteralPath (Join-Path $script:stateDir 'peer.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-TrayPeer $script:peer $script:peer.ssh_alias
        $ownerAlive=Get-TrayOwnerAlive $script:session;$tunUp=Get-TrayTunnelUp $script:session
        $guard=if(([datetime]::UtcNow-$script:guardAt).TotalSeconds -le 8){$script:guard}else{'UNKNOWN'}
        $view=Get-TrayPresentation -Guard $guard -Session $script:session -OwnerAlive $ownerAlive -TunnelUp $tunUp
        if($view.Color -eq 'green' -and $script:session.UdpExit -ne $script:peer.endpoint){$view.Label='Exit / session mismatch';$view.Color='red'}
        if($script:operation){$view.Label='Operation: '+$script:operation.Kind;$view.Color='orange'}
        if($script:launch){
            if($ownerAlive -or $script:launch.HasExited){$script:launch.Dispose();$script:launch=$null}
            else{$view.Label='Launching session';$view.Color='orange'}
        }
        $script:statusItem.Text=$view.Label
        $script:tray.Icon=$script:icons[$view.Color]
        $tip='Hybrid VPN | '+$view.Label+' | '+$script:peer.ssh_alias
        $script:tray.Text=$tip.Substring(0,[Math]::Min(63,$tip.Length))
        $idle=$null -eq $script:operation -and $null -eq $script:launch
        $script:connectItem.Enabled=$view.CanConnect -and $idle
        $script:recoverItem.Enabled=$idle;$script:exitItem.Enabled=$idle
        $script:exitMenu.Enabled=$view.CanSelect -and $idle
        foreach($alias in @('nyc1','lon1','sgp1','syd1')){
            $file=Join-Path $script:stateDir "profiles/$alias.json"
            $saved=Test-Path -LiteralPath $file
            $script:exitItems[$alias].Checked=$alias -eq $script:peer.ssh_alias
            $script:exitItems[$alias].Text=$alias+$(if($saved){' — ready'}else{' — prepare (sudo)'})
        }
    }
    function Show-TrayInfo {
        $s=$script:session
        $tcp=if($s -and $s.ContainsKey('TcpExit')){[string]$s.TcpExit}else{'not verified'}
        $udp=if($s -and $s.ContainsKey('UdpExit')){[string]$s.UdpExit}else{'not verified'}
        $verified=if($s -and $s.ContainsKey('LastVerifiedUtc')){[string]$s.LastVerifiedUtc}else{'none'}
        $failure=if($s -and $s.ContainsKey('Failure') -and $s.State -eq 'failed-protection-retained'){"`nFailure: $($s.Failure)"}else{''}
        $text="Tray 0.1.0 / working core 0.4.0-fix5`n`nStatus: $($script:statusItem.Text)`nGuard: $script:guard`nUDP exit: $($script:peer.ssh_alias) / $($script:peer.endpoint):$($script:peer.port)`nLast verified TCP/Tor IP: $tcp`nLast verified UDP IP: $udp`nLast verification (UTC): $verified$failure`n`nTCP and DNS use Tor; its exit is automatic.`nUDP uses the selected VPS, not Tor.`nLAN/private-network exceptions remain direct.`nStored IPs are historical; green additionally requires a live matching supervisor, an Up recorded TUN, ARMED guard and a verification age <=150 seconds. This is not a complete leak/crash certification."
        [void][Windows.Forms.MessageBox]::Show($text,'Hybrid VPN — connection information','OK','Information')
    }
    $script:statusItem=Add-TrayItem 'Checking status...' $null;$script:statusItem.Enabled=$false
    $script:connectItem=Add-TrayItem 'Connect' {try{Assert-TrayDisconnected $script:homeDir;$script:launch=Start-TrayScript 'Start.ps1' @() $false;Update-Tray}catch{Show-TrayError $_}}
    $script:recoverItem=Add-TrayItem 'Disconnect / Recover' {try{Start-TrayRecovery $false;Update-Tray}catch{Show-TrayError $_}}
    $script:exitMenu=Add-TrayItem 'UDP / VPS exit (disconnect to change)' $null
    $script:exitItems=@{}
    foreach($alias in @('nyc1','lon1','sgp1','syd1')){
        $entry=[Windows.Forms.ToolStripMenuItem]::new($alias);$entry.Tag=$alias
        $entry.add_Click({
            param($sender,$eventArgs)
            try {
                $selected=[string]$sender.Tag
                $profile=Join-Path $script:stateDir "profiles/$selected.json"
                if(Test-Path -LiteralPath $profile){Select-TrayExit $selected $script:homeDir $script:stateDir;Update-Tray}
                else {
                    $answer=[Windows.Forms.MessageBox]::Show("Prepare $selected using your existing SSH alias? This installs/configures the dedicated WireGuard exit on that VPS and asks for its wofl sudo password in a visible terminal. Allow inbound UDP 51832 in its DigitalOcean firewall. Your current selected profile is retained. After preparation, select $selected again, then Connect.",'Prepare VPS exit','YesNo','Question')
                    if($answer -eq [Windows.Forms.DialogResult]::Yes){
                        $p=Start-TrayScript 'Prepare-Exit.ps1' @('-Server',$selected,'-Pause') $true
                        $script:operation=@{Kind='exit preparation';Process=$p};Update-Tray
                    }
                }
            }catch{Show-TrayError $_}
        })
        [void]$script:exitMenu.DropDownItems.Add($entry);$script:exitItems[$alias]=$entry
    }
    [void](Add-TrayItem 'Connection information...' {try{Show-TrayInfo}catch{Show-TrayError $_}})
    [void](Add-TrayItem 'Open routing log' {try{$p=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/notepad.exe'));$p.UseShellExecute=$false;$p.ArgumentList.Add((Join-Path $script:stateDir 'engine-stderr.log'));$child=[Diagnostics.Process]::Start($p);$child.Dispose()}catch{Show-TrayError $_}})
    [void](Add-TrayItem 'About...' {[void][Windows.Forms.MessageBox]::Show("whispr Hybrid VPN`nTray 0.1.0 | core 0.4.0-fix5`n© 2026 whispr.dev`n`nTCP / DNS: Tor. UDP: your WireGuard VPS.`nNo automatic startup or automatic reconnection.`nClosing the tray alone leaves the independent session running.",'About Hybrid VPN','OK','Information')})
    [void]$script:menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
    [void](Add-TrayItem 'Close tray only — keep VPN running' {$script:context.ExitThread()})
    $script:exitItem=Add-TrayItem 'Disconnect and Exit' {try{Start-TrayRecovery $true;Update-Tray}catch{Show-TrayError $_}}
    $script:tray.add_DoubleClick({try{Show-TrayInfo}catch{Show-TrayError $_}})
    $script:timer=[Windows.Forms.Timer]::new();$script:timer.Interval=2000
    $script:timer.add_Tick({try{Update-Tray}catch{$script:guard='UNKNOWN';$script:statusItem.Text='Status unavailable';$script:tray.Icon=$script:icons.red;$script:connectItem.Enabled=$false;$script:exitMenu.Enabled=$false;$script:tray.Text='Hybrid VPN | status unavailable';try{[IO.File]::WriteAllText((Join-Path $script:stateDir 'tray-error.log'),$_.Exception.ToString())}catch{}}})
    $script:tray.Visible=$true;Update-Tray;$script:timer.Start()
    [Windows.Forms.Application]::Run($script:context)
} catch {[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Hybrid VPN tray could not start','OK','Error')}
finally {
    if($script:timer){$script:timer.Stop();$script:timer.Dispose()}
    if($script:tray){$script:tray.Visible=$false;$script:tray.Dispose()}
    if($script:probe){try{if(-not $script:probe.Process.HasExited){$script:probe.Process.Kill()}}catch{};$script:probe.Process.Dispose()}
    # Disposing a Process handle does not terminate its child. Never stop a VPN in tray cleanup.
    if($script:operation){$script:operation.Process.Dispose()}
    if($script:launch){$script:launch.Dispose()}
    if($script:context){$script:context.Dispose()}
    foreach($icon in $script:icons.Values){$icon.Dispose()}
    if($script:locked){$script:trayMutex.ReleaseMutex()};$script:trayMutex.Dispose()
}
