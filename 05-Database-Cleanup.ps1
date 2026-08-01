<#
.SYNOPSIS
    STEP 5 - Database Cleanup (track-for-notice version).
    Nothing is dropped by this script.  Objects are DISABLED and recorded in
    the DBA database tracking tables; the "DECOM Notices" agent job (created by
    06-Create-DecomNoticesJob.ps1) emails the drop commands once records are
    14 days old.

      5.1 Remove database from CommVault (logged; manual/console step)
      5.2 DISABLE agent jobs referencing the DB -> dbo.Decom_DisabledJobs
          (DatabaseName, JobName, DateDisabled, DropCommand, EmailContact)
      5.3 SSIS packages referencing the DB -> dbo.Decom_SsisPackages
          (DatabaseName, PackagePath, DateInserted, EmailContact)
      5.4 DISABLE logins exclusive to the DB -> dbo.Decom_DisabledLogins
          (DatabaseName, LoginName, DateDisabled, DropCommand, EmailContact)

.PARAMETER Execute
    $false (default) = dry run, report only. $true = perform disables + inserts.
#>

param(
    [bool]$Execute = $false
)

. "$PSScriptRoot\00-Decom-Config.ps1"
Confirm-DecomModules

$inst    = $Global:DecomConfig.SourceInstance
$db      = $Global:DecomConfig.DatabaseName
$dbaDb   = $Global:DecomConfig.DbaDatabase
$contact = $Global:DecomConfig.EmailContact
$mode    = if ($Execute) { 'EXECUTE' } else { 'DRY RUN (report only)' }

if ($Execute) { Confirm-DecomTables }

#=================================================================================
# 5.1 Remove database from CommVault
#=================================================================================
$log1 = New-DecomLogFile -SectionName '05-1_RemoveFromCommVault'
Write-DecomLog $log1 "Mode: $mode"
Write-DecomLog $log1 "MANUAL/CONSOLE STEP: In CommCell console -> Client -> SQL Server agent -> subclient properties,"
Write-DecomLog $log1 "remove database [$db] from the content list (or disable auto-discovery for it)."
Write-DecomLog $log1 "Performed by: ____________   Date: ____________"

#=================================================================================
# 5.2 Catch-up sweep: DISABLE any agent jobs referencing the database that were
#     not already handled by Step 2 (e.g. jobs created during the 14-day wait)
#=================================================================================
$log2 = New-DecomLogFile -SectionName '05-2_DisableJobs'
Write-DecomLog $log2 "Mode: $mode | Contact: $contact"
Write-DecomLog $log2 "Jobs were disabled in Step 2 when the DB went offline; this is a catch-up sweep."
Disable-DecomAgentJobs -LogFile $log2 -Execute $Execute

#=================================================================================
# 5.3 SSIS packages referencing the database -> Decom_SsisPackages
#=================================================================================
$log3 = New-DecomLogFile -SectionName '05-3_SsisPackages'
Write-DecomLog $log3 "Mode: $mode | Contact: $contact"
$ssisCandidates = @()

# SSISDB catalog (project deployment) - full path recorded
try {
    $catalogPkgs = Invoke-DbaQuery -SqlInstance $inst -Database SSISDB -Query @"
DECLARE @Pkgs TABLE (FolderName SYSNAME, ProjectName SYSNAME, PackageName SYSNAME);
INSERT INTO @Pkgs
SELECT f.name, pr.name, pk.name
FROM catalog.packages pk
JOIN catalog.projects pr ON pk.project_id = pr.project_id
JOIN catalog.folders  f  ON pr.folder_id  = f.folder_id;
SELECT * FROM @Pkgs;
"@ -ErrorAction Stop
    Write-DecomLog $log3 "SSISDB catalog packages on instance (review each for [$db] references):"
    $catalogPkgs | Format-Table -AutoSize | Out-String | ForEach-Object { Write-DecomLog $log3 $_ }
    $ssisCandidates += $catalogPkgs | ForEach-Object { "SSISDB:\$($_.FolderName)\$($_.ProjectName)\$($_.PackageName)" }
}
catch { Write-DecomLog $log3 "No SSISDB catalog on this instance (or not accessible)." }

# Legacy MSDB package store
$msdbPkgs = Invoke-DbaQuery -SqlInstance $inst -Database msdb -Query @"
DECLARE @Pkgs TABLE (PackageName SYSNAME, FolderId UNIQUEIDENTIFIER);
INSERT INTO @Pkgs
SELECT name, folderid FROM msdb.dbo.sysssispackages;
SELECT PackageName FROM @Pkgs;
"@ -ErrorAction SilentlyContinue
if ($msdbPkgs) {
    Write-DecomLog $log3 "Legacy MSDB-stored packages (review for [$db] references):"
    $msdbPkgs | Format-Table -AutoSize | Out-String | ForEach-Object { Write-DecomLog $log3 $_ }
    $ssisCandidates += $msdbPkgs.PackageName | ForEach-Object { "MSDB:\$_" }
}

Write-DecomLog $log3 "`nConfirm which packages actually reference [$db]:"
$confirmedPkgs = @()
foreach ($pkg in ($ssisCandidates | Sort-Object -Unique)) {
    $ans = Read-Host "Mark SSIS package '$pkg' for deletion? (Y/N)"
    if ($ans -eq 'Y') { $confirmedPkgs += $pkg }
}

foreach ($pkg in $confirmedPkgs) {
    if ($Execute) {
        Invoke-DbaQuery -SqlInstance $inst -Database $dbaDb `
            -Query "INSERT INTO dbo.Decom_SsisPackages (DatabaseName, PackagePath, DateInserted, EmailContact) VALUES (@DatabaseName, @PackagePath, GETDATE(), @EmailContact);" `
            -SqlParameter @{ DatabaseName = $db; PackagePath = $pkg; EmailContact = $contact }
        Write-DecomLog $log3 "Recorded '$pkg' in [$dbaDb].dbo.Decom_SsisPackages."
    } else {
        Write-DecomLog $log3 "DRY RUN: would record SSIS package '$pkg'."
    }
}
if (-not $confirmedPkgs) { Write-DecomLog $log3 "No SSIS packages marked for deletion." }

#=================================================================================
# 5.4 Catch-up sweep: DISABLE logins exclusive to this DB not already handled
#     by Step 2. NOTE: if the DB is offline (normal at this point), users
#     cannot be enumerated and the function logs that logins were handled in
#     Step 2 (see Decom_DisabledLogins).
#=================================================================================
$log4 = New-DecomLogFile -SectionName '05-4_DisableLogins'
Write-DecomLog $log4 "Mode: $mode | Contact: $contact"
Disable-DecomLogins -LogFile $log4 -Execute $Execute

Write-DecomLog $log4 ""
Write-DecomLog $log4 "All objects tracked. Ensure the 'DECOM Notices' job exists on [$inst] (run 06-Create-DecomNoticesJob.ps1 once per server)."

Write-Host "`nOutput files:" -ForegroundColor Cyan
$log1, $log2, $log3, $log4 | ForEach-Object { Write-Host "  $_" }

