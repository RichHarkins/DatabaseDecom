<#
.SYNOPSIS
    STEP 2 - After the normal change is approved, take the database offline.
    Records DB state before/after and kills existing connections.
    Prompts for the change ticket number as a safety gate.
#>

. "$PSScriptRoot\00-Decom-Config.ps1"
Confirm-DecomModules
$log = New-DecomLogFile -SectionName '02_TakeOffline'

$inst = $Global:DecomConfig.SourceInstance
$db   = $Global:DecomConfig.DatabaseName

# --- Safety gate: require a change ticket -------------------------------------
if ([string]::IsNullOrWhiteSpace($Global:DecomConfig.ChangeTicket) -or
    $Global:DecomConfig.ChangeTicket -eq 'CHG0000000') {
    $Global:DecomConfig.ChangeTicket = Read-Host "Enter the approved normal change ticket number"
}
Write-DecomLog $log "Change ticket: $($Global:DecomConfig.ChangeTicket)"

$confirm = Read-Host "Take [$db] on [$inst] OFFLINE now? (Y/N)"
if ($confirm -ne 'Y') {
    Write-DecomLog $log "Operation cancelled by operator. Database untouched."
    return
}

# --- Record current state ------------------------------------------------------
$before = Get-DbaDatabase -SqlInstance $inst -Database $db
Write-DecomLog $log "State before: Status=$($before.Status), Size=$($before.SizeMB)MB, Owner=$($before.Owner)"
Write-DecomLog $log "Files:"
$before.FileGroups.Files + (Get-DbaDbFile -SqlInstance $inst -Database $db) |
    Select-Object -Unique LogicalName, PhysicalName, Size |
    Format-Table -AutoSize | Out-String | ForEach-Object { Write-DecomLog $log $_ }

# --- Take offline ---------------------------------------------------------------
Write-DecomLog $log "Killing open connections and setting OFFLINE..."
try {
    Set-DbaDbState -SqlInstance $inst -Database $db -Offline -Force -Confirm:$false |
        Out-String | ForEach-Object { Write-DecomLog $log $_ }

    $after = Get-DbaDbState -SqlInstance $inst -Database $db
    Write-DecomLog $log "State after: $($after.Status)"
    Write-DecomLog $log "SUCCESS: [$db] is offline under change $($Global:DecomConfig.ChangeTicket)."
    Write-DecomLog $log "Next: run 03-Backup-ToSpecialServer.ps1, then wait 14 days."
}
catch {
    Write-DecomLog $log "ERROR taking database offline: $($_.Exception.Message)"
    throw
}
Write-Host "`nOutput written to: $log" -ForegroundColor Cyan
