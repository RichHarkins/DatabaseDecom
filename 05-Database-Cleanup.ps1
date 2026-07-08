<#
.SYNOPSIS
    STEP 5 - Database Cleanup (run only after Step 4 backup is verified).
      5.1 Remove database from CommVault (logged; CLI or manual)
      5.2 Script out, then remove, agent jobs and SSIS packages referencing the DB
      5.3 Identify DB-specific accounts; generate SNOW request detail; remove DB users
      5.4 Drop the database from the server
    Every sub-step writes to its own text file. Scripted-out jobs are saved
    before anything is removed so they can be recreated if needed.
#>

param(
    # Set to $true to actually delete/drop. Default is a dry run that only reports.
    [bool]$Execute = $false
)

. "$PSScriptRoot\00-Decom-Config.ps1"
Confirm-DecomModules

$inst = $Global:DecomConfig.SourceInstance
$db   = $Global:DecomConfig.DatabaseName
$mode = if ($Execute) { 'EXECUTE' } else { 'DRY RUN (report only)' }

#=================================================================================
# 5.1 Remove database from CommVault
#=================================================================================
$log1 = New-DecomLogFile -SectionName '05-1_RemoveFromCommVault'
Write-DecomLog $log1 "Mode: $mode"
Write-DecomLog $log1 "Remove [$db] content from the CommVault SQL subclient so it is no longer backed up."
Write-DecomLog $log1 "MANUAL/CONSOLE STEP: In CommCell console -> Client -> SQL Server agent -> subclient properties,"
Write-DecomLog $log1 "remove database [$db] from the content list (or disable auto-discovery for it)."
Write-DecomLog $log1 "Record who performed this and when, below this line:"
Write-DecomLog $log1 "Performed by: ____________   Date: ____________"

#=================================================================================
# 5.2 Script out then remove jobs / SSIS packages referencing the database
#=================================================================================
$log2 = New-DecomLogFile -SectionName '05-2_Jobs_SSIS'
Write-DecomLog $log2 "Mode: $mode"
$scriptOutDir = Join-Path $Global:DecomConfig.OutputFolder 'ScriptedJobs'
if (-not (Test-Path $scriptOutDir)) { New-Item $scriptOutDir -ItemType Directory -Force | Out-Null }

# -- Agent jobs
$jobs = Get-DbaAgentJob -SqlInstance $inst | Where-Object {
    $_.JobSteps | Where-Object { $_.DatabaseName -eq $db -or $_.Command -match [regex]::Escape($db) }
}
if ($jobs) {
    foreach ($job in $jobs) {
        $file = Join-Path $scriptOutDir ("Job_" + ($job.Name -replace '[\\/:*?"<>|]','_') + '.sql')
        $job.Script() | Out-File -FilePath $file -Encoding UTF8
        Write-DecomLog $log2 "Scripted out job '$($job.Name)' -> $file"
        if ($Execute) {
            Remove-DbaAgentJob -SqlInstance $inst -Job $job.Name -Confirm:$false
            Write-DecomLog $log2 "REMOVED job '$($job.Name)'."
        } else {
            Write-DecomLog $log2 "DRY RUN: job '$($job.Name)' would be removed."
        }
    }
} else {
    Write-DecomLog $log2 "No agent jobs reference [$db]."
}

# -- SSIS packages (SSISDB catalog + legacy MSDB storage)
Write-DecomLog $log2 "`n--- SSIS packages referencing [$db] ---"
$ssisHits = @()
try {
    $ssisHits += Invoke-DbaQuery -SqlInstance $inst -Database SSISDB -Query @"
DECLARE @Hits TABLE (FolderName SYSNAME, ProjectName SYSNAME, PackageName SYSNAME);
INSERT INTO @Hits
SELECT f.name, pr.name, pk.name
FROM catalog.packages pk
JOIN catalog.projects pr ON pk.project_id = pr.project_id
JOIN catalog.folders  f  ON pr.folder_id  = f.folder_id;
SELECT * FROM @Hits;
"@ -ErrorAction Stop
    Write-DecomLog $log2 "SSISDB catalog packages found (review each for references to [$db]):"
    $ssisHits | Format-Table -AutoSize | Out-String | ForEach-Object { Write-DecomLog $log2 $_ }
}
catch { Write-DecomLog $log2 "No SSISDB catalog on this instance (or not accessible)." }

$msdbPkgs = Invoke-DbaQuery -SqlInstance $inst -Database msdb -Query @"
DECLARE @Pkgs TABLE (PackageName SYSNAME, CreateDate DATETIME);
INSERT INTO @Pkgs
SELECT name, createdate FROM msdb.dbo.sysssispackages;
SELECT * FROM @Pkgs;
"@ -ErrorAction SilentlyContinue
if ($msdbPkgs) {
    Write-DecomLog $log2 "Legacy MSDB-stored packages (review for [$db] references):"
    $msdbPkgs | Format-Table -AutoSize | Out-String | ForEach-Object { Write-DecomLog $log2 $_ }
}
Write-DecomLog $log2 "NOTE: Export any affected SSIS project (.ispac) from SSISDB before deleting it."
if (-not $Execute) { Write-DecomLog $log2 "DRY RUN: no SSIS objects removed." }

#=================================================================================
# 5.3 Database-specific accounts + SNOW request detail
#=================================================================================
$log3 = New-DecomLogFile -SectionName '05-3_Accounts_SNOW'
Write-DecomLog $log3 "Mode: $mode"

$dbUsers = Get-DbaDbUser -SqlInstance $inst -Database $db -ExcludeSystemUser
Write-DecomLog $log3 "Users in [$db]:"
$dbUsers | Select-Object Name, Login, LoginType |
    Format-Table -AutoSize | Out-String | ForEach-Object { Write-DecomLog $log3 $_ }

# Server logins whose ONLY mapping is this database = candidates for removal
Write-DecomLog $log3 "`n--- Server logins mapped ONLY to [$db] (candidates for removal / SNOW request) ---"
$candidates = @()
foreach ($u in ($dbUsers | Where-Object Login)) {
    $otherMaps = Get-DbaDbUser -SqlInstance $inst -ExcludeSystemUser |
        Where-Object { $_.Login -eq $u.Login -and $_.Database -ne $db }
    if (-not $otherMaps) { $candidates += $u.Login }
}
if ($candidates) {
    $candidates | Sort-Object -Unique | ForEach-Object { Write-DecomLog $log3 "  $_" }
    Write-DecomLog $log3 "`nSNOW REQUEST TEMPLATE:"
    Write-DecomLog $log3 "  Summary : Remove service/database accounts after decom of [$db] on [$inst]"
    Write-DecomLog $log3 "  Details : The following accounts were used only by [$db] and should be removed:"
    $candidates | Sort-Object -Unique | ForEach-Object { Write-DecomLog $log3 "            - $_" }
    Write-DecomLog $log3 "  SNOW Request #: $($Global:DecomConfig.SnowRequest)  (fill in once submitted)"
} else {
    Write-DecomLog $log3 "No logins are exclusive to this database."
}

if ($Execute -and $candidates) {
    foreach ($l in ($candidates | Sort-Object -Unique)) {
        Remove-DbaLogin -SqlInstance $inst -Login $l -Confirm:$false
        Write-DecomLog $log3 "REMOVED server login '$l'."
    }
} elseif ($candidates) {
    Write-DecomLog $log3 "DRY RUN: logins above NOT removed. Submit SNOW request for AD/service accounts."
}

#=================================================================================
# 5.4 Drop the database
#=================================================================================
$log4 = New-DecomLogFile -SectionName '05-4_DropDatabase'
Write-DecomLog $log4 "Mode: $mode"

if ($Execute) {
    $confirm = Read-Host "FINAL CONFIRMATION - type the database name to DROP [$db] from [$inst]"
    if ($confirm -ceq $db) {
        # DB is offline; dropping an offline DB leaves files on disk - capture paths first
        $files = Invoke-DbaQuery -SqlInstance $inst -Database master -Query "SELECT physical_name FROM sys.master_files WHERE database_id = DB_ID(N'$db');"
        Write-DecomLog $log4 "Physical files (delete from disk after drop if DB was offline):"
        $files | ForEach-Object { Write-DecomLog $log4 "  $($_.physical_name)" }

        Remove-DbaDatabase -SqlInstance $inst -Database $db -Confirm:$false |
            Out-String | ForEach-Object { Write-DecomLog $log4 $_ }
        Write-DecomLog $log4 "DATABASE [$db] DROPPED from [$inst]. Decommission complete."
    } else {
        Write-DecomLog $log4 "Name mismatch - drop aborted."
    }
} else {
    Write-DecomLog $log4 "DRY RUN: database NOT dropped. Re-run with -Execute `$true to perform cleanup."
}

Write-Host "`nOutput files:" -ForegroundColor Cyan
$log1, $log2, $log3, $log4 | ForEach-Object { Write-Host "  $_" }
