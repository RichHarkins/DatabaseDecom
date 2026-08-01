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
Get-DbaDbFile -SqlInstance $inst -Database $db |
    Select-Object LogicalName, PhysicalName, @{ Name = 'SizeMB'; Expression = { $_.Size.Megabyte } } |
    Format-Table -AutoSize | Out-String | ForEach-Object { Write-DecomLog $log $_ }

# --- Prepare tracking + contact BEFORE any changes ------------------------------
Confirm-DecomTables
if ([string]::IsNullOrWhiteSpace($Global:DecomConfig.EmailContact)) {
    $Global:DecomConfig | Add-Member -NotePropertyName EmailContact `
        -NotePropertyValue (Read-Host "EmailContact is not set in 00-Decom-Config.ps1. Enter the email contact for this decom") -Force
}
Write-DecomLog $log "Email contact: $($Global:DecomConfig.EmailContact)"

# --- Disable referencing jobs and exclusive logins BEFORE going offline ---------
# Jobs are disabled now so they don't fail against the offline DB for 14 days.
# Logins must be enumerated while the DB is still ONLINE.
Write-DecomLog $log ""
Write-DecomLog $log "--- DISABLING AGENT JOBS REFERENCING [$db] ---"
Disable-DecomAgentJobs -LogFile $log -Execute $true

Write-DecomLog $log ""
Write-DecomLog $log "--- DISABLING LOGINS EXCLUSIVE TO [$db] ---"
Disable-DecomLogins -LogFile $log -Execute $true

# --- Take offline ---------------------------------------------------------------
Write-DecomLog $log ""
Write-DecomLog $log "Killing open connections and setting OFFLINE..."
try {
    Set-DbaDbState -SqlInstance $inst -Database $db -Offline -Force -Confirm:$false |
        Out-String | ForEach-Object { Write-DecomLog $log $_ }

    $after = Get-DbaDbState -SqlInstance $inst -Database $db
    Write-DecomLog $log "State after: $($after.Status)"

    # --- Record in DBA tracking table -----------------------------------------
    $dropCmd = "ALTER DATABASE [$($db.Replace(']',']]'))] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$($db.Replace(']',']]'))];"
    Invoke-DbaQuery -SqlInstance $inst -Database $Global:DecomConfig.DbaDatabase `
        -Query "INSERT INTO dbo.Decom_OfflineDatabases (DatabaseName, DateOffline, DropCommand, EmailContact) VALUES (@DatabaseName, GETDATE(), @DropCommand, @EmailContact);" `
        -SqlParameter @{ DatabaseName = $db; DropCommand = $dropCmd; EmailContact = $Global:DecomConfig.EmailContact }
    Write-DecomLog $log "Recorded in [$($Global:DecomConfig.DbaDatabase)].dbo.Decom_OfflineDatabases with drop command and contact $($Global:DecomConfig.EmailContact)."

    Write-DecomLog $log "SUCCESS: [$db] is offline under change $($Global:DecomConfig.ChangeTicket)."
    Write-DecomLog $log "Referencing jobs and exclusive logins were disabled and tracked."
    Write-DecomLog $log "Next: run 03-Copy-ToSpecialServer.ps1, then wait 14 days."
}
catch {
    Write-DecomLog $log "ERROR taking database offline: $($_.Exception.Message)"
    throw
}
Write-Host "`nOutput written to: $log" -ForegroundColor Cyan
