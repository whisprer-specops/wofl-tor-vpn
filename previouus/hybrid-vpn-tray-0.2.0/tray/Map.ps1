#requires -Version 7.0
. "$PSScriptRoot/MapModel.ps1"
$script:hybridMap=$null
function Update-HybridMapImage {
    if(-not $script:hybridMap){return}
    $m=$script:hybridMap;$w=$m.Picture.ClientSize.Width;$h=$m.Picture.ClientSize.Height
    if($w -lt 1 -or $h -lt 1){return}
    $image=[Drawing.Bitmap]::new($w,$h);$g=[Drawing.Graphics]::FromImage($image)
    $font=[Drawing.Font]::new('Segoe UI',[single]10,[Drawing.FontStyle]::Bold)
    $border=[Drawing.Pen]::new([Drawing.Color]::White,[single]2)
    $textBrush=[Drawing.SolidBrush]::new([Drawing.Color]::White)
    try {
        $g.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.DrawImage($m.Base,[Drawing.Rectangle]::new(0,0,$w,$h))
        foreach($region in Get-HybridRegions){
            $p=Get-HybridMapPoint $region.Lon $region.Lat $w $h
            $ready=Test-Path -LiteralPath (Join-Path $m.StateRoot "profiles/$($region.Alias).json")
            $color=if($region.Alias -eq $m.Current){[Drawing.Color]::Gold}elseif($ready){[Drawing.Color]::Turquoise}else{[Drawing.Color]::SlateGray}
            $brush=[Drawing.SolidBrush]::new($color)
            try{$g.FillEllipse($brush,[single]($p.X-7),[single]($p.Y-7),[single]14,[single]14);$g.DrawEllipse($border,[single]($p.X-7),[single]($p.Y-7),[single]14,[single]14)}finally{$brush.Dispose()}
            $label=$region.Name+' ('+$region.Alias+')'
            $g.DrawString($label,$font,$textBrush,[single]($p.X+$region.Dx),[single]($p.Y+$region.Dy))
        }
    }finally{$font.Dispose();$border.Dispose();$textBrush.Dispose();$g.Dispose()}
    $old=$m.Picture.Image;$m.Picture.Image=$image;if($old){$old.Dispose()}
}
function Show-HybridExitMap {
    param([string]$InstallRoot,[string]$StateRoot,[string]$Current,[bool]$CanSelect)
    $form=[Windows.Forms.Form]::new();$base=$null;$tip=$null
    try {
        $form.Text='Choose your UDP / WireGuard exit';$form.StartPosition='CenterScreen'
        $form.ClientSize=[Drawing.Size]::new(1100,650);$form.MinimumSize=[Drawing.Size]::new(850,560)
        $form.BackColor=[Drawing.Color]::FromArgb(10,23,34);$form.ForeColor=[Drawing.Color]::White
        $form.Font=[Drawing.Font]::new('Segoe UI',[single]10)
        $header=[Windows.Forms.Label]::new();$header.Dock='Top';$header.Height=58
        $header.Padding=[Windows.Forms.Padding]::new(12)
        $header.Text=if($CanSelect){'Click a dot to select or prepare that VPS. Gold = selected; cyan = prepared; gray = not prepared. TCP/Tor exit remains automatic.'}else{'Your session is connected. Disconnect first to change exits. You can inspect regions here; TCP/Tor exit remains automatic.'}
        $footer=[Windows.Forms.Panel]::new();$footer.Dock='Bottom';$footer.Height=64
        $info=[Windows.Forms.Label]::new();$info.AutoSize=$false;$info.Location=[Drawing.Point]::new(12,8);$info.Size=[Drawing.Size]::new(700,48)
        $info.Text='Approximate VPS city centres. Offline map: Natural Earth (public domain).'
        $close=[Windows.Forms.Button]::new();$close.Text='Close';$close.Size=[Drawing.Size]::new(90,32);$close.Dock='Right';$close.DialogResult='Cancel'
        [void]$footer.Controls.Add($info);[void]$footer.Controls.Add($close)
        $picture=[Windows.Forms.PictureBox]::new();$picture.Dock='Fill';$picture.SizeMode='Normal';$picture.Cursor=[Windows.Forms.Cursors]::Hand
        $base=[Drawing.Bitmap]::new((Join-Path $InstallRoot 'tray/world-map.png'))
        $tip=[Windows.Forms.ToolTip]::new()
        $script:hybridMap=@{Form=$form;Picture=$picture;Base=$base;StateRoot=$StateRoot;Current=$Current;CanSelect=$CanSelect;Selected=$null;Info=$info;Tip=$tip}
        $picture.add_Resize({try{Update-HybridMapImage}catch{}})
        $picture.add_MouseMove({param($sender,$e)
            $m=$script:hybridMap;if(-not $m){return}
            $region=Find-HybridMapRegion $e.X $e.Y $sender.ClientSize.Width $sender.ClientSize.Height
            if($region){
                $ready=Test-Path -LiteralPath (Join-Path $m.StateRoot "profiles/$($region.Alias).json")
                $state=if($ready){'prepared; select then Connect'}else{'not prepared; selection opens SSH/sudo setup'}
                $m.Info.Text="$($region.Name) — $($region.Alias): $state."
                $m.Tip.SetToolTip($sender,$region.Name+' / '+$region.Alias)
            }else{$m.Info.Text='Approximate VPS city centres. Offline map: Natural Earth (public domain).';$m.Tip.SetToolTip($sender,'')}
        })
        $picture.add_MouseClick({param($sender,$e)
            $m=$script:hybridMap;if(-not $m -or -not $m.CanSelect){return}
            $region=Find-HybridMapRegion $e.X $e.Y $sender.ClientSize.Width $sender.ClientSize.Height
            if($region){$m.Selected=$region.Alias;$m.Form.DialogResult=[Windows.Forms.DialogResult]::OK;$m.Form.Close()}
        })
        [void]$form.Controls.Add($picture);[void]$form.Controls.Add($footer);[void]$form.Controls.Add($header)
        $form.CancelButton=$close
        $form.add_Shown({Update-HybridMapImage})
        [void]$form.ShowDialog()
        return $script:hybridMap.Selected
    }finally{
        if($script:hybridMap -and $script:hybridMap.Picture.Image){$script:hybridMap.Picture.Image.Dispose()}
        $script:hybridMap=$null;if($tip){$tip.Dispose()};if($base){$base.Dispose()};$form.Dispose()
    }
}
