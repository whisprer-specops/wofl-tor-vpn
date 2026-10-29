param([string]$JsonBase64)
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\audit-common.ps1"
$a = Read-TorArgs $JsonBase64
switch ($a.Mode) {
    'start' {
        Write-TorStep $a 'fw-audit.ps1' 'Temporarily enabling blocked-connection evidence'
        Start-TorAudit $a $a.TorPath
    }
    'capture' {
        Write-TorStep $a 'fw-audit.ps1' 'Saving effective rules and Tor blocking-filter evidence before recovery'
        Save-TorFirewallEvidence $a
    }
    'restore' {
        Restore-TorAudit $a
    }
    default { throw "Unknown audit mode '$($a.Mode)'" }
}
