<#
.SYNOPSIS
    STEP 3 - While the database is offline, preserve it on the "Special" server.
    Two modes (per the decom process "Or"):
      FileCopy : Copy the physical MDF/NDF/LDF files (offline configuration)
                 to the Special server share.  DB stays offline the whole time.
      Backup   : Briefly bring the DB online, take a full COPY_ONLY backup with
                 CHECKSUM directly to the Special server share, verify it, then
                 set the DB offline again.
.PARAMETER Mode
    FileCopy (default) or Backup
.EXAMPLE
    .\03-Copy-ToSpecialServer.ps1 -Mode Backup
#>
param(
    [ValidateSet('FileCopy','Backup')]
    [string]$Mode = 'FileCopy'
)

. "$PSScriptRoot\00-Decom-Config.ps1"
Confirm-DecomModules
$log = New-DecomLogFile -SectionName '03_CopyToSpecial'

$inst  = $Global:DecomConfig.SourceInstance
$db    = $Global:DecomConfig.DatabaseName
$share = $Global:DecomConfig.SpecialSharePath
$dest  = Join-Path $share $db

Write-DecomLog $log "Mode: $Mode | Destination: $dest"

if (-not (Test-Path $share)) {
    Write-DecomLog $log "ERROR: Cannot reach Special server share '$share'. Aborting."
    throw "Special server share unreachable."
}
if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory -Force | Out-Null }

# Verify the DB is currently offline (this step runs while offline)
$state = Get-DbaDbState -SqlInstance $inst -Database $db
Write-DecomLog $log "Current DB status: $($state.Status)"
if ($state.Status -notmatch 'OFFLINE') {
    Write-DecomLog $log "WARNING: Database is not offline. Run 02-Take-DatabaseOffline.ps1 first."
    throw "Database must be offline before Step 3."
}

switch ($Mode) {

    'FileCopy' {
        # Physical file paths come from sys.master_files (readable while DB offline)
        $files = Invoke-DbaQuery -SqlInstance $inst -Database master -Query @"
DECLARE @Files TABLE (LogicalName SYSNAME, PhysicalName NVARCHAR(4000), TypeDesc NVARCHAR(60));
INSERT INTO @Files
SELECT name, physical_name, type_desc
FROM sys.master_files WHERE database_id = DB_ID(N'$db');
SELECT * FROM @Files;
"@
        Write-DecomLog $log "Files to copy:"
        $files | Format-Table -AutoSize | Out-String | ForEach-Object { Write-DecomLog $log $_ }

        foreach ($f in $files) {
            # Convert local path on the SQL host to an admin UNC path
            $uncSource = "\\$($inst.Split('\')[0])\$($f.PhysicalName -replace ':','$')"
            Write-DecomLog $log "Copying $uncSource -> $dest"
            Copy-Item -Path $uncSource -Destination $dest -Force
            $srcHash = (Get-FileHash $uncSource -Algorithm SHA256).Hash
            $dstHash = (Get-FileHash (Join-Path $dest (Split-Path $f.PhysicalName -Leaf)) -Algorithm SHA256).Hash
            $match = if ($srcHash -eq $dstHash) { 'VERIFIED' } else { 'HASH MISMATCH!' }
            Write-DecomLog $log "  SHA256 check: $match"
            if ($match -ne 'VERIFIED') { throw "Hash mismatch on $($f.PhysicalName)" }
        }
        Write-DecomLog $log "All physical files copied to Special server in offline configuration."
    }

    'Backup' {
        # The backup is written BY the SQL Server engine, so the SQL Server
        # SERVICE ACCOUNT (not the account running this script) must have
        # modify rights on the share. Log it for diagnostics:
        $svc = Invoke-DbaQuery -SqlInstance $inst -Database master -Query @"
DECLARE @Svc TABLE (ServiceName NVARCHAR(256), ServiceAccount NVARCHAR(256));
INSERT INTO @Svc
SELECT servicename, service_account FROM sys.dm_server_services;
SELECT * FROM @Svc WHERE ServiceName LIKE 'SQL Server (%';
"@
        Write-DecomLog $log "SQL Server service account (needs modify rights on $share): $($svc.ServiceAccount)"

        Write-DecomLog $log "Bringing [$db] ONLINE temporarily for backup..."
        Set-DbaDbState -SqlInstance $inst -Database $db -Online -Force -Confirm:$false | Out-Null

        try {
            # -IgnoreFileChecks skips the Test-DbaPath pre-flight (xp_fileexist),
            # which throws when the service account cannot probe the UNC path.
            # -BuildPath creates the destination folder if missing.
            # NOTE: -Verify is intentionally NOT used. It runs the verification
            # through Restore-DbaDatabase on a new connection, which gets
            # forcibly closed on long-running verifies over UNC paths. We run
            # RESTORE VERIFYONLY ourselves below with no query timeout instead.
            $bak = Backup-DbaDatabase -SqlInstance $inst -Database $db `
                    -Path $dest -Type Full -CopyOnly -Checksum `
                    -CompressBackup -IgnoreFileChecks -BuildPath `
                    -FilePath "$db`_Decom_Full_$(Get-Date -Format yyyyMMdd).bak" `
                    -EnableException
            Write-DecomLog $log "Backup file : $($bak.BackupPath)"
            Write-DecomLog $log "Size        : $($bak.TotalSize)"

            # --- Verify the backup directly (no timeout) ----------------------
            $bakPath = $bak.BackupPath
            Write-DecomLog $log "Running RESTORE VERIFYONLY (this can take a while on large backups)..."
            Invoke-DbaQuery -SqlInstance $inst -Database master -QueryTimeout 0 `
                -Query "RESTORE VERIFYONLY FROM DISK = N'$($bakPath.Replace("'","''"))' WITH CHECKSUM;" `
                -EnableException
            Write-DecomLog $log "Verified    : True (RESTORE VERIFYONLY WITH CHECKSUM completed successfully)"
        }
        catch {
            Write-DecomLog $log "ERROR during backup: $($_.Exception.Message)"
            Write-DecomLog $log "Most common cause: the SQL Server service account '$($svc.ServiceAccount)' lacks"
            Write-DecomLog $log "modify permissions (share AND NTFS) on '$share'. Grant access and re-run,"
            Write-DecomLog $log "or use -Mode FileCopy, which copies the files using YOUR account instead."
            throw
        }
        finally {
            Write-DecomLog $log "Setting [$db] back OFFLINE..."
            Set-DbaDbState -SqlInstance $inst -Database $db -Offline -Force -Confirm:$false | Out-Null
            Write-DecomLog $log "DB status now: $((Get-DbaDbState -SqlInstance $inst -Database $db).Status)"
        }
    }
}

Write-DecomLog $log "STEP 3 COMPLETE. Begin the 14-day waiting period. Record end date: $((Get-Date).AddDays(14).ToShortDateString())"
Write-Host "`nOutput written to: $log" -ForegroundColor Cyan

