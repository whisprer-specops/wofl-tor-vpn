#requires -Version 7.2
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[void][Windows.Forms.Application]::SetHighDpiMode([Windows.Forms.HighDpiMode]::PerMonitorV2)
[Windows.Forms.Application]::EnableVisualStyles()
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
try{$admin=[Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$identity.Dispose()}
if(-not $admin){
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSScriptRoot 'runtime/powershell/pwsh.exe'))
    $start.UseShellExecute=$true;$start.Verb='runas';$start.Arguments='-NoLogo -NoProfile -STA -WindowStyle Hidden -File "'+$PSCommandPath+'"'
    try{[void][Diagnostics.Process]::Start($start)}catch{[void][Windows.Forms.MessageBox]::Show('Administrator approval was cancelled. The VPN was not changed.','whispr VPN')}
    return
}
if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA){throw 'Start whispr VPN using its Start menu shortcut.'}
. "$PSScriptRoot/Model.ps1"
$script:job=$null;$script:buttons=@{};$script:timer=$null;$script:splash=$null;$script:main=$null
$script:mutex=[Threading.Mutex]::new($false,'Global\whisprVpnDesktop100');$script:locked=$false
$script:art=$null;$script:icon=$null
function Show-SuiteMessage([string]$Text,[string]$Title='whispr VPN'){
    [void][Windows.Forms.MessageBox]::Show($script:main,$Text,$Title,'OK','Information')
}
function Get-SuiteDeviceLabel {
    $name=([Environment]::MachineName -replace '[^A-Za-z0-9 ._-]','_').Trim()
    if($name -cnotmatch '^[A-Za-z0-9]'){$name='PC-'+$name}
    if($name.Length -gt 64){$name=$name.Substring(0,64)}
    return $name
}
function Start-SuiteProcess([string]$HostPath,[string]$Script,[string[]]$Arguments=@(),[switch]$Visible){
    $p=[Diagnostics.ProcessStartInfo]::new($HostPath);$p.UseShellExecute=[bool]$Visible
    if($Visible){$p.WindowStyle='Normal'}
    $p.WorkingDirectory=Split-Path $Script -Parent
    foreach($a in @('-NoLogo','-NoProfile','-STA')+$(if($Visible){@()}else{@('-WindowStyle','Hidden')})+@('-File',$Script)+$Arguments){$p.ArgumentList.Add($a)}
    if(-not $Visible){$p.CreateNoWindow=$true;$p.RedirectStandardOutput=$true;$p.RedirectStandardError=$true}
    return [Diagnostics.Process]::Start($p)
}
function Refresh-SuiteControls {
    $core=Get-SuiteCoreRoot;$state=Get-SuiteStateRoot
    $installed=(Test-Path -LiteralPath (Join-Path $core 'install-owner.txt')) -and (Test-Path -LiteralPath (Join-Path $core 'Tray.ps1')) -and (Test-Path -LiteralPath (Join-Path $core 'client/Common.ps1'))
    $hasKey=Test-Path -LiteralPath (Join-Path $state 'device-key.json')
    $hasPeer=Test-Path -LiteralPath (Join-Path $state 'peer.json')
    $script:buttons.Tray.Enabled=$hasPeer -and $hasKey -and $installed
    foreach($name in @('Import','Tools','Export','Create','Update','Recover')){$script:buttons[$name].Enabled=$installed -and $hasKey}
    $script:buttons.Setup.Enabled=$true
    $script:status.Text=if(-not $installed -and ($hasKey -or $hasPeer)){'Saved identity/exits found; client setup needs completing. Choose Set up this PC to resume after any required recovery.'}elseif($hasPeer){'VPN configured. Open the tray for its live connection status.'}elseif($hasKey){'Device identity ready. Export its public request, then import your approved group file.'}else{'Welcome. Set up this PC to create its own private device identity.'}
}
function Start-SuiteOperation([string]$Operation,[string[]]$Extra=@()){
    if($script:job){return}
    $hostPath=Get-SuiteCoreHost $PSScriptRoot
    $id=[guid]::NewGuid().ToString('N')
    $p=Start-SuiteProcess $hostPath (Join-Path $PSScriptRoot 'Worker.ps1') (@('-Operation',$Operation,'-JobId',$id,'-DeviceName',(Get-SuiteDeviceLabel))+$Extra)
    $script:job=@{Process=$p;Id=$id;Out=$p.StandardOutput.ReadToEndAsync();Err=$p.StandardError.ReadToEndAsync();Operation=$Operation}
    foreach($b in $script:buttons.Values){$b.Enabled=$false}
    $script:status.Text=if($Operation -eq 'Setup'){'Setting up this PC. First-time routing-engine downloads need Internet access; checksums are verified.'}else{'Working: '+$Operation+'. The result will appear here.'}
    $script:progress.Visible=$true;$script:progress.Style='Marquee'
}
function Show-SuiteAbout {
    $dialog=[Windows.Forms.Form]::new();$dialog.Text='About whispr VPN';$dialog.Size=[Drawing.Size]::new(760,650)
    $dialog.StartPosition='CenterParent';$dialog.AutoScaleMode='Dpi';$dialog.Icon=$script:icon
    $text=[Windows.Forms.RichTextBox]::new();$text.Dock='Fill';$text.ReadOnly=$true;$text.BackColor=[Drawing.Color]::White
    $text.LoadFile((Join-Path $PSScriptRoot 'LICENSE.rtf'))
    $top=[Windows.Forms.Label]::new();$top.Dock='Top';$top.Height=64
    $top.Padding=[Windows.Forms.Padding]::new(16);$top.Font=[Drawing.Font]::new('Segoe UI',11)
    $top.Text='whispr VPN desktop 1.0.1 | TCP/DNS via Tor; UDP via your selected VPS.'+[Environment]::NewLine+'Bundled third-party components retain their original licence notices.'
    $close=[Windows.Forms.Button]::new();$close.Text='Close';$close.Dock='Bottom';$close.Height=38;$close.DialogResult='OK'
    $dialog.Controls.Add($text);$dialog.Controls.Add($top);$dialog.Controls.Add($close);$dialog.AcceptButton=$close
    try{[void]$dialog.ShowDialog($script:main)}finally{$dialog.Dispose()}
}
try{
    try{$script:locked=$script:mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$script:locked=$true}
    if(-not $script:locked){throw 'The whispr VPN control centre is already open.'}
    Assert-SuiteManifest $PSScriptRoot
    $script:work=Initialize-SuiteWorkspace
    [void](Sync-SuiteGroupTools $PSScriptRoot)
    [void](Update-SuiteRuntimeLease $PSScriptRoot)
    $script:art=[Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'assets/splash.png'))
    $script:icon=[Drawing.Icon]::new((Join-Path $PSScriptRoot 'assets/whispr-vpn.ico'))
    $script:main=[Windows.Forms.Form]::new();$script:main.Text='whispr VPN';$script:main.Icon=$script:icon
    $script:main.ClientSize=[Drawing.Size]::new(900,690);$script:main.MinimumSize=[Drawing.Size]::new(790,680)
    $script:main.AutoScaleMode='Dpi';$script:main.AutoScaleDimensions=[Drawing.SizeF]::new(96,96);$script:main.StartPosition='CenterScreen'
    $script:main.BackColor=[Drawing.ColorTranslator]::FromHtml('#0C1420');$script:main.ForeColor=[Drawing.Color]::White
    $script:main.Font=[Drawing.Font]::new('Segoe UI',10)
    $hero=[Windows.Forms.PictureBox]::new();$hero.Dock='Top';$hero.Height=220;$hero.SizeMode='Zoom';$hero.Image=$script:art
    $script:main.Controls.Add($hero)
    $body=[Windows.Forms.TableLayoutPanel]::new();$body.Dock='Fill';$body.Padding=[Windows.Forms.Padding]::new(22,12,22,8)
    $body.ColumnCount=2;$body.RowCount=6
    [void]$body.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,50))
    [void]$body.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,50))
    [void]$body.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,64))
    foreach($row in 1..4){[void]$body.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,25))}
    [void]$body.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,12))
    $script:status=[Windows.Forms.Label]::new();$script:status.Dock='Fill';$script:status.AutoEllipsis=$true
    $script:status.Padding=[Windows.Forms.Padding]::new(2,6,2,4);$script:status.ForeColor=[Drawing.ColorTranslator]::FromHtml('#BED0E0')
    $body.Controls.Add($script:status,0,0);$body.SetColumnSpan($script:status,2)
    $rows=@(@('Tray','Open VPN tray'),@('Setup','Set up this PC'),@('Import','Import group / access file'),@('Tools','Group & endpoint tools'),@('Export','Export public request'),@('Create','Create my own group'),@('Update','Update group support / flags'),@('Recover','Disconnect / Recover'))
    for($i=0;$i -lt $rows.Count;$i++){
        $button=[Windows.Forms.Button]::new();$button.Text=$rows[$i][1];$button.Tag=$rows[$i][0];$button.Dock='Fill'
        $button.Margin=[Windows.Forms.Padding]::new(5,5,5,5);$button.FlatStyle='Flat';$button.FlatAppearance.BorderSize=0
        $button.BackColor=[Drawing.ColorTranslator]::FromHtml($(if($i -eq 0){'#F2AD24'}elseif($i -eq 1){'#167A98'}else{'#1B2B3C'}))
        $button.ForeColor=if($i -eq 0){[Drawing.Color]::Black}else{[Drawing.Color]::White}
        $button.add_Click({param($sender,$eventArgs)
            try{
                switch([string]$sender.Tag){
                    'Tray' {
                        [void](Assert-SuiteCore)
                        $p=[Diagnostics.ProcessStartInfo]::new((Get-SuiteCoreHost $PSScriptRoot));$p.UseShellExecute=$true
                        $p.Arguments='-NoLogo -NoProfile -STA -WindowStyle Hidden -File "'+(Join-Path (Get-SuiteCoreRoot) 'Open-Tray.ps1')+'"'
                        $p.WindowStyle='Hidden';$child=[Diagnostics.Process]::Start($p);$child.Dispose()
                        [void](Update-SuiteRuntimeLease $PSScriptRoot)
                        $script:status.Text='Opening the existing VPN tray. Its verified green status is the connection check.'
                    }
                    'Setup' {Start-SuiteOperation 'Setup'}
                    'Import' {
                        $pick=[Windows.Forms.OpenFileDialog]::new();$pick.Filter='whispr JSON files (*.json)|*.json';$pick.Title='Choose group.json or friend-access.json';$pick.CheckFileExists=$true
                        try{if($pick.ShowDialog($script:main) -eq 'OK'){Start-SuiteOperation 'Import' @('-InputFile',$pick.FileName)}}finally{$pick.Dispose()}
                    }
                    'Export' {Start-SuiteOperation 'Export'}
                    'Create' {
                        $answer=[Windows.Forms.MessageBox]::Show($script:main,'Create a separate group that you own? If you are joining your friend, use Import instead. An existing group catalogue will not be replaced.','Create my own group','YesNo','Question')
                        if($answer -eq 'Yes'){Start-SuiteOperation 'CreateGroup'}
                    }
                    'Update' {Start-SuiteOperation 'InstallGroup'}
                    'Recover' {Start-SuiteOperation 'Recover'}
                    'Tools' {
                        $group=Sync-SuiteGroupTools $PSScriptRoot
                        $p=Start-SuiteProcess (Get-SuiteCoreHost $PSScriptRoot) (Join-Path $group 'Group.ps1') -Visible
                        $p.Dispose()
                        Show-SuiteMessage 'Group tools opened. Importing or publishing needs the VPN disconnected and its tray closed. Publishing a VPS opens visible SSH/sudo prompts. Your group.json and my-vps.json live in the protected workspace, so MSI updates keep them.'
                    }
                }
            }catch{Show-SuiteMessage $_.Exception.Message 'whispr VPN - action stopped'}
        })
        $script:buttons[$rows[$i][0]]=$button;$body.Controls.Add($button,($i%2),([int][Math]::Floor($i/2)+1))
    }
    $script:progress=[Windows.Forms.ProgressBar]::new();$script:progress.Dock='Fill';$script:progress.Visible=$false
    $body.Controls.Add($script:progress,0,5);$body.SetColumnSpan($script:progress,2)
    $footer=[Windows.Forms.FlowLayoutPanel]::new();$footer.Dock='Bottom';$footer.Height=56;$footer.Padding=[Windows.Forms.Padding]::new(22,10,0,0)
    foreach($entry in @(@('About','About / licence'),@('Exports','Exports'),@('Logs','Setup logs'),@('RemoveClient','Remove VPN client'),@('Remove','Uninstall desktop'))){
        $link=[Windows.Forms.LinkLabel]::new();$link.Text=$entry[1];$link.Tag=$entry[0];$link.AutoSize=$true;$link.Margin=[Windows.Forms.Padding]::new(0,5,20,0);$link.LinkColor=[Drawing.ColorTranslator]::FromHtml('#60D5EE')
        $link.add_LinkClicked({param($sender,$eventArgs)
            try{
                switch([string]$sender.Tag){
                    'About' {Show-SuiteAbout}
                    'Exports' {Start-Process explorer.exe -ArgumentList ('"'+(Join-Path $script:work 'exports')+'"')}
                    'Logs' {Start-Process explorer.exe -ArgumentList ('"'+(Join-Path $script:work 'jobs')+'"')}
                    'RemoveClient' {
                        $answer=[Windows.Forms.MessageBox]::Show($script:main,'Remove the connection client and its own sign-in/background tasks, keeping local keys/settings? First Disconnect / Recover and close its tray. You can uninstall just the desktop package instead when your existing client uses its original PowerShell host.','Remove VPN client','YesNo','Warning')
                        if($answer -eq 'Yes'){Start-SuiteOperation 'RemoveClient'}
                    }
                    'Remove' {
                        if($script:job){Show-SuiteMessage 'Wait for the current operation to finish.';return}
                        if(Update-SuiteRuntimeLease $PSScriptRoot){Show-SuiteMessage 'The connection client still needs this bundled runtime. Use Remove VPN client first, keeping its keys/settings. Desktop removal was not started.';return}
                        Show-SuiteMessage 'The desktop package will be removed. Your pre-existing VPN client and protected keys/settings are retained. This control centre will close before Windows Installer opens.'
                        $reg=Get-ItemProperty -LiteralPath 'HKLM:\Software\whispr.dev\VPN Desktop' -Name ProductCode
                        $p=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/msiexec.exe'));$p.UseShellExecute=$true
                        $p.Arguments='/x '+[string]$reg.ProductCode
                        [void][Diagnostics.Process]::Start($p);$script:main.Close()
                    }
                }
            }catch{Show-SuiteMessage $_.Exception.Message}
        });$footer.Controls.Add($link)
    }
    $script:main.Controls.Add($body);$body.BringToFront();$script:main.Controls.Add($footer)
    # Dock layout is explicit: top artwork, bottom footer, fill controls.
    $hero.BringToFront();$footer.BringToFront()
    $script:timer=[Windows.Forms.Timer]::new();$script:timer.Interval=300
    $script:timer.add_Tick({
        if($script:job -and $script:job.Process.HasExited){
            $job=$script:job;$script:job=$null
            try{
                $output=$job.Out.GetAwaiter().GetResult()+[Environment]::NewLine+$job.Err.GetAwaiter().GetResult()
                $output=$output -replace '[A-Za-z0-9+/]{43}=','[key withheld]'
                $log=Join-Path $script:work ('jobs/'+$(if($job.Id){$job.Id}else{[guid]::NewGuid().ToString('N')})+'.log')
                [IO.File]::WriteAllText($log,$output,[Text.UTF8Encoding]::new($false))
                Refresh-SuiteControls;$script:progress.Visible=$false
                if($job.Id){
                    $reportPath=Join-Path $script:work "jobs/$($job.Id).json"
                    if(Test-Path -LiteralPath $reportPath){$report=Read-SuiteJson $reportPath;Show-SuiteMessage $report.Message $(if($report.Success){'whispr VPN'}else{'whispr VPN - action stopped'})}
                    else{Show-SuiteMessage ('The operation stopped before it could write a result. Open Setup logs.'+[Environment]::NewLine+$output.Substring(0,[Math]::Min(2000,$output.Length)))}
                }elseif($job.Process.ExitCode -ne 0){Show-SuiteMessage 'The tray launcher stopped. Open Setup logs; no connected status was granted by this window.'}
            }catch{Show-SuiteMessage $_.Exception.Message}
            finally{$job.Process.Dispose()}
        }
    })
    $script:main.add_FormClosing({param($sender,$eventArgs)
        if($script:job -and -not $script:job.Process.HasExited){$eventArgs.Cancel=$true;Show-SuiteMessage 'An operation is still running. Keep this window open until it finishes.'}
    })
    Refresh-SuiteControls;$script:timer.Start()
    $script:splash=[Windows.Forms.Form]::new();$script:splash.FormBorderStyle='None';$script:splash.StartPosition='CenterScreen'
    $script:splash.ClientSize=[Drawing.Size]::new(800,450);$script:splash.BackgroundImage=$script:art;$script:splash.BackgroundImageLayout='Zoom'
    $script:splash.BackColor=[Drawing.Color]::Black;$script:splash.ShowInTaskbar=$false
    $caption=[Windows.Forms.Label]::new();$caption.Text='Opening your VPN control centre...';$caption.Dock='Bottom';$caption.Height=32;$caption.TextAlign='MiddleCenter'
    $caption.BackColor=[Drawing.ColorTranslator]::FromHtml('#060D16');$caption.ForeColor=[Drawing.ColorTranslator]::FromHtml('#B5C8DB');$script:splash.Controls.Add($caption)
    $splashTimer=[Windows.Forms.Timer]::new();$splashTimer.Interval=900
    $splashTimer.add_Tick({$splashTimer.Stop();$script:splash.Hide();$script:main.Show();[void]$script:main.Activate()})
    $script:splash.Show();$splashTimer.Start()
    $context=[Windows.Forms.ApplicationContext]::new();$context.MainForm=$script:main
    [Windows.Forms.Application]::Run($context)
    $splashTimer.Dispose();$context.Dispose()
}catch{
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'whispr VPN could not open','OK','Error')
}finally{
    if($script:timer){$script:timer.Stop();$script:timer.Dispose()}
    if($script:splash){$script:splash.Dispose()};if($script:main){$script:main.Dispose()}
    if($script:art){$script:art.Dispose()};if($script:icon){$script:icon.Dispose()}
    if($script:locked){$script:mutex.ReleaseMutex()};$script:mutex.Dispose()
}
