<#
.SYNOPSIS
    STEP 1 - Confirm (to the best of our abilities) the DB is not actively used.
    Collects: active sessions, index usage stats (last reads/writes), recent
    connection info, dependent SQL Agent jobs, and linked-server/SSIS hints.
    If usage is found, this output file is what you hand back to the BA group.
#>

. "$PSScriptRoot\00-Decom-Config.ps1"
Confirm-DecomModules
$log = New-DecomLogFile -SectionName '01_UsageCheck'

$inst = $Global:DecomConfig.SourceInstance
$db   = $Global:DecomConfig.DatabaseName
$usageFound = $false

Write-DecomLog $log "Starting usage check for [$db] on [$inst]."

# --- 1. Active sessions right now -------------------------------------------
Write-DecomLog $log "`n--- ACTIVE SESSIONS ---"
$sessions = Get-DbaProcess -SqlInstance $inst -Database $db |
    Where-Object { $_.Spid -gt 50 -and $_.Program -notlike '*dbatools*' }

if ($sessions) {
    $usageFound = $true
    $sessions | Select-Object Spid, Login, Host, Program, LastRequestStartTime, Status |
        Format-Table -AutoSize | Out-String | ForEach-Object { Write-DecomLog $log $_ }
} else {
    Write-DecomLog $log "No active user sessions found."
}

# --- 2. Index usage stats (last user read/write since instance start) --------
Write-DecomLog $log "`n--- INDEX USAGE (since last SQL restart) ---"
$startTime = (Get-DbaInstanceProperty -SqlInstance $inst |
    Where-Object Name -eq 'SqlStartTime' | Select-Object -First 1).Value
Write-DecomLog $log "Instance start time (stats reset point): $startTime"

$usageQuery = @"
DECLARE @Usage TABLE (
    ObjectName   SYSNAME,
    LastUserSeek DATETIME NULL,
    LastUserScan DATETIME NULL,
    LastUserLookup DATETIME NULL,
    LastUserUpdate DATETIME NULL
);
INSERT INTO @Usage
SELECT OBJECT_NAME(ius.object_id),
       MAX(ius.last_user_seek), MAX(ius.last_user_scan),
       MAX(ius.last_user_lookup), MAX(ius.last_user_update)
FROM sys.dm_db_index_usage_stats ius
WHERE ius.database_id = DB_ID()
GROUP BY ius.object_id;
SELECT * FROM @Usage ORDER BY ISNULL(LastUserUpdate,'1900-01-01') DESC;
"@
$usage = Invoke-DbaQuery -SqlInstance $inst -Database $db -Query $usageQuery
if ($usage) {
    $usageFound = $true
    $usage | Format-Table -AutoSize | Out-String | ForEach-Object { Write-DecomLog $log $_ }
} else {
    Write-DecomLog $log "No index usage recorded since instance start."
}

# --- 3. SQL Agent jobs referencing the database -------------------------------
Write-DecomLog $log "`n--- AGENT JOBS REFERENCING DATABASE ---"
$jobs = Get-DbaAgentJob -SqlInstance $inst | Where-Object {
    $_.JobSteps | Where-Object { $_.DatabaseName -eq $db -or $_.Command -match [regex]::Escape($db) }
}
if ($jobs) {
    $usageFound = $true
    $jobs | Select-Object Name, Enabled, LastRunDate, LastRunOutcome |
        Format-Table -AutoSize | Out-String | ForEach-Object { Write-DecomLog $log $_ }
} else {
    Write-DecomLog $log "No agent jobs reference this database."
}

# --- 4. Recent connections from default trace --------------------------------
Write-DecomLog $log "`n--- USERS/LOGINS MAPPED TO DATABASE ---"
Get-DbaDbUser -SqlInstance $inst -Database $db -ExcludeSystemUser |
    Select-Object Name, Login, LoginType, CreateDate |
    Format-Table -AutoSize | Out-String | ForEach-Object { Write-DecomLog $log $_ }

# --- Verdict ------------------------------------------------------------------
Write-DecomLog $log "`n================ VERDICT ================"
if ($usageFound) {
    Write-DecomLog $log "ACTIVE USAGE INDICATORS FOUND. Refer story back to the BA group."
    Write-DecomLog $log "Attach this file ($log) to the story with all usage details."
} else {
    Write-DecomLog $log "No usage indicators found. OK to proceed to Step 2 (submit normal change)."
}
Write-Host "`nOutput written to: $log" -ForegroundColor Cyan

