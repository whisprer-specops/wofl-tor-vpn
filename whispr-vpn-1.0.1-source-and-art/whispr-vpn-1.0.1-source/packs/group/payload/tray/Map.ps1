#requires -Version 7.0
. "$PSScriptRoot/MapModel.ps1"
$script:hybridMap=$null
function Draw-HybridMap {
    param($Graphics,[int]$Width,[int]$Height)
    if(-not $script:hybridMap -or $Width -lt 200 -or $Height -lt 160){return}
    $m=$script:hybridMap;$layout=Get-HybridMapLayout $Width $Height
    $scale=[single]$layout.Scale
    $font=[Drawing.Font]::new('Segoe UI',[single](10*$scale),[Drawing.FontStyle]::Bold)
    $border=[Drawing.Pen]::new([Drawing.Color]::White,[single](1.6*$scale))
    $outline=[Drawing.Pen]::new([Drawing.Color]::FromArgb(98,148,166),[single](1.4*$scale))
    $labelBrush=[Drawing.SolidBrush]::new([Drawing.Color]::White)
    $halo=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(230,10,23,34))
    $saved=$Graphics.Save()
    try {
        # Explicit source and destination pixel rectangles; never depend on bitmap DPI or old Resize state.
        $Graphics.PageUnit=[Drawing.GraphicsUnit]::Pixel
        $Graphics.PageScale=[single]1
        $Graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $Graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $Graphics.DrawImage($m.Base,[Drawing.RectangleF]::new(0,0,$Width,$Height),[Drawing.RectangleF]::new(0,0,$m.Base.Width,$m.Base.Height),[Drawing.GraphicsUnit]::Pixel)
        $box=$layout.Inset;$e=$layout.Europe
        $Graphics.FillRectangle($halo,[single]$box.X,[single]$box.Y,[single]$box.Width,[single]$box.Height)
        $Graphics.DrawRectangle($outline,[single]$box.X,[single]$box.Y,[single]$box.Width,[single]$box.Height)
        $Graphics.DrawString('EUROPE  /  shared exits',$font,$labelBrush,[single]($box.X+12*$scale),[single]($box.Y+7*$scale))
        $src=[Drawing.RectangleF]::new([single](($e.West+180)*$m.Base.Width/360),[single]((90-$e.North)*$m.Base.Height/180),[single](($e.East-$e.West)*$m.Base.Width/360),[single](($e.North-$e.South)*$m.Base.Height/180))
        $dest=[Drawing.RectangleF]::new([single]$e.X,[single]$e.Y,[single]$e.Width,[single]$e.Height)
        $Graphics.DrawImage($m.Base,$dest,$src,[Drawing.GraphicsUnit]::Pixel)
        $markers=@(Get-HybridMapMarkers $Width $Height)
        foreach($marker in $markers){
            $ready=$m.Ready.ContainsKey($marker.Alias)
            $color=if($marker.Alias -eq $m.Current){[Drawing.Color]::Gold}elseif($ready){[Drawing.Color]::Turquoise}else{[Drawing.Color]::SlateGray}
            $brush=[Drawing.SolidBrush]::new($color);$radius=[single]$(if($marker.Inset){7*$scale}else{5.5*$scale})
            try{
                $Graphics.FillEllipse($brush,[single]($marker.X-$radius),[single]($marker.Y-$radius),[single](2*$radius),[single](2*$radius))
                $Graphics.DrawEllipse($border,[single]($marker.X-$radius),[single]($marker.Y-$radius),[single](2*$radius),[single](2*$radius))
            }finally{$brush.Dispose()}
            $label=if($marker.Alias -like 'exit-*'){$marker.Name}else{$marker.Name+' ('+$marker.Alias+')'}
            $size=$Graphics.MeasureString($label,$font)
            $x=[Math]::Max(6,[Math]::Min($Width-$size.Width-6,$marker.X+$marker.Dx))
            $y=[Math]::Max(6,[Math]::Min($Height-$size.Height-6,$marker.Y+$marker.Dy))
            $Graphics.FillRectangle($halo,[single]($x-3),[single]($y-1),[single]($size.Width+6),[single]($size.Height+2))
            $Graphics.DrawString($label,$font,$labelBrush,[single]$x,[single]$y)
        }
        # Count badges make colocated VPSs visible; clicking opens the per-exit chooser.
        $clusters=@($markers|Group-Object -Property {([string]$_.Inset)+'|'+[Math]::Floor($_.X/(6*$scale))+'|'+[Math]::Floor($_.Y/(6*$scale))})
        $badge=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(25,90,130))
        try{
            foreach($cluster in $clusters|Where-Object Count -gt 1){
                $p=$cluster.Group[0];$r=[single](11*$scale)
                $Graphics.FillEllipse($badge,[single]($p.X-$r),[single]($p.Y-$r),[single](2*$r),[single](2*$r))
                $Graphics.DrawEllipse($border,[single]($p.X-$r),[single]($p.Y-$r),[single](2*$r),[single](2*$r))
                $text=[string]$cluster.Count;$measure=$Graphics.MeasureString($text,$font)
                $Graphics.DrawString($text,$font,$labelBrush,[single]($p.X-$measure.Width/2),[single]($p.Y-$measure.Height/2))
            }
        }finally{$badge.Dispose()}
    }finally{$Graphics.Restore($saved);$font.Dispose();$border.Dispose();$outline.Dispose();$labelBrush.Dispose();$halo.Dispose()}
}
function Show-HybridExitMap {
    param([string]$InstallRoot,[string]$StateRoot,[string]$Current,[bool]$CanSelect)
    $script:hybridDynamicRegions=@(Get-HybridGroupRegions $StateRoot)
    $form=[Windows.Forms.Form]::new();$base=$null;$tip=$null;$uiFont=$null
    try {
        $form.SuspendLayout()
        $form.Text='Choose your UDP / WireGuard exit — group map 1.0.0';$form.StartPosition='CenterScreen'
        $form.AutoScaleMode=[Windows.Forms.AutoScaleMode]::Dpi
        $form.AutoScaleDimensions=[Drawing.SizeF]::new(96,96)
        $form.ClientSize=[Drawing.Size]::new(1120,720);$form.MinimumSize=[Drawing.Size]::new(1000,640)
        $form.BackColor=[Drawing.Color]::FromArgb(10,23,34);$form.ForeColor=[Drawing.Color]::White
        $uiFont=[Drawing.Font]::new('Segoe UI',[single]10);$form.Font=$uiFont
        # A three-row layout reserves real space for the map before its first paint.
        $grid=[Windows.Forms.TableLayoutPanel]::new();$grid.Dock='Fill';$grid.ColumnCount=1;$grid.RowCount=3
        $grid.Margin=[Windows.Forms.Padding]::new(0);$grid.Padding=[Windows.Forms.Padding]::new(0)
        [void]$grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
        [void]$grid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,76))
        [void]$grid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100))
        [void]$grid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,72))
        $header=[Windows.Forms.Label]::new();$header.Dock='Fill';$header.Margin=[Windows.Forms.Padding]::new(0);$header.Padding=[Windows.Forms.Padding]::new(12)
        $header.Text=if($CanSelect){'Click a city dot to select an approved VPS. Nearby dots offer a city/exit chooser. Europe has an enlarged inset. Gold = selected; cyan = prepared; gray = needs owner approval. TCP/Tor exit remains automatic.'}else{'Disconnect first to change exits. Click close together dots to choose between shared exits. TCP/Tor exit remains automatic.'}
        $canvas=[Windows.Forms.Panel]::new();$canvas.Dock='Fill';$canvas.Margin=[Windows.Forms.Padding]::new(0);$canvas.Cursor=[Windows.Forms.Cursors]::Hand
        $prop=[Windows.Forms.Control].GetProperty('DoubleBuffered',[Reflection.BindingFlags]'NonPublic,Instance')
        $prop.SetValue($canvas,$true)
        $footer=[Windows.Forms.TableLayoutPanel]::new();$footer.Dock='Fill';$footer.RowCount=1;$footer.ColumnCount=2;$footer.Padding=[Windows.Forms.Padding]::new(10)
        [void]$footer.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
        [void]$footer.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute,100))
        $info=[Windows.Forms.Label]::new();$info.Dock='Fill';$info.Text='Approximate VPS city centres. Offline map: Natural Earth (public domain).'
        $close=[Windows.Forms.Button]::new();$close.Text='Close';$close.Dock='Fill';$close.DialogResult='Cancel'
        $footer.Controls.Add($info,0,0);$footer.Controls.Add($close,1,0)
        $base=[Drawing.Bitmap]::new((Join-Path $InstallRoot 'tray/world-map.png'));$tip=[Windows.Forms.ToolTip]::new()
        $ready=@{};foreach($region in Get-HybridRegions){if(Test-Path -LiteralPath (Join-Path $StateRoot "profiles/$($region.Alias).json")){$ready[$region.Alias]=$true}}
        $script:hybridMap=@{Form=$form;Canvas=$canvas;Base=$base;Current=$Current;CanSelect=$CanSelect;Selected=$null;Info=$info;Tip=$tip;Ready=$ready;DrawFailed=$false;Choosers=[Collections.Generic.List[object]]::new()}
        $canvas.add_Paint({param($sender,$e)
            try{Draw-HybridMap $e.Graphics $sender.ClientSize.Width $sender.ClientSize.Height}
            catch{$script:hybridMap.DrawFailed=$true;$script:hybridMap.Info.Text='Map drawing failed: '+$_.Exception.Message}
        })
        $canvas.add_Resize({param($sender,$e);$sender.Invalidate()})
        $canvas.add_MouseMove({param($sender,$e)
            $m=$script:hybridMap;if(-not $m -or $m.DrawFailed){return}
            $candidates=@(Find-HybridMapCandidates $e.X $e.Y $sender.ClientSize.Width $sender.ClientSize.Height)
            $region=$candidates|Select-Object -First 1
            if($candidates.Count -gt 1){$m.Info.Text="$($candidates.Count) exits here. Click the dot to choose a VPS.";$m.Tip.SetToolTip($sender,$m.Info.Text)}
            elseif($region){
                $state=if($m.Ready.ContainsKey($region.Alias)){'prepared; select then Connect'}else{'not approved; ask its owner to sync members, then import group.json'}
                $m.Info.Text="$($region.Name) — $($region.Alias): $state."
                $m.Tip.SetToolTip($sender,$region.Name+' / '+$region.Alias)
            }else{$m.Info.Text='Approximate VPS city centres. Offline map: Natural Earth (public domain).';$m.Tip.SetToolTip($sender,'')}
        })
        $canvas.add_MouseClick({param($sender,$e)
            $m=$script:hybridMap;if(-not $m -or -not $m.CanSelect -or $m.DrawFailed -or $e.Button -ne [Windows.Forms.MouseButtons]::Left){return}
            $candidates=@(Find-HybridMapCandidates $e.X $e.Y $sender.ClientSize.Width $sender.ClientSize.Height)
            if($candidates.Count -eq 1){$m.Selected=$candidates[0].Alias;$m.Form.DialogResult=[Windows.Forms.DialogResult]::OK;$m.Form.Close()}
            elseif($candidates.Count -gt 1){
                $chooser=[Windows.Forms.ContextMenuStrip]::new()
                foreach($candidate in $candidates){
                    $item=[Windows.Forms.ToolStripMenuItem]::new($candidate.Name+' / '+$candidate.Alias);$item.Tag=$candidate.Alias
                    $item.add_Click({param($choice,$eventArgs);$script:hybridMap.Selected=[string]$choice.Tag;$script:hybridMap.Form.DialogResult=[Windows.Forms.DialogResult]::OK;$script:hybridMap.Form.Close()})
                    [void]$chooser.Items.Add($item)
                }
                $m.Choosers.Add($chooser);$chooser.Show($sender,[Drawing.Point]::new($e.X,$e.Y))
            }
        })
        $grid.Controls.Add($header,0,0);$grid.Controls.Add($canvas,0,1);$grid.Controls.Add($footer,0,2)
        $form.Controls.Add($grid);$form.CancelButton=$close
        $form.ResumeLayout($true)
        $form.add_Shown({$script:hybridMap.Canvas.Invalidate()})
        [void]$form.ShowDialog()
        return $script:hybridMap.Selected
    }finally{if($script:hybridMap){foreach($chooser in $script:hybridMap.Choosers){$chooser.Dispose()}};$script:hybridMap=$null;if($tip){$tip.Dispose()};if($base){$base.Dispose()};$form.Dispose();if($uiFont){$uiFont.Dispose()}}
}
