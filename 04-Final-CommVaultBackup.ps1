<#
.SYNOPSIS
    STEP 4 - At the end of 14 days, take a final FULL backup via CommVault.
    Uses the CommVault qcommand CLI (qlogin/qoperation backup) if installed.
    If the CLI is not present, the script logs manual instructions instead so
    the step is still documented in the output file.

    EDIT the CommVault section variables below for your CommServe environment.
#>

. "$PSScriptRoot\00-Decom-Config.ps1"
Confirm-DecomModules
$log = New-DecomLogFile -SectionName '04_FinalCommVaultBackup'

$inst = $Global:DecomConfig.SourceInstance
$db   = $Global:DecomConfig.DatabaseName

#region --- CommVault environment settings (EDIT) ------------------------------
$CommServe   = 'COMMSERVE01'
$CvClient    = $inst.Split('\')[0]          # CommVault client = SQL host
$CvAgent     = 'SQL Server'
$CvInstance  = $inst                        # CommVault instance name for SQL
$CvSubclient = 'default'
$QCommandDir = 'C:\Program Files\Commvault\ContentStore\Base'
#endregion ----------------------------------------------------------------------

Write-DecomLog $log "Final full CommVault backup for [$db] on client [$CvClient]."

# The DB must be ONLINE for CommVault SQL agent to back it up.
$state = Get-DbaDbState -SqlInstance $inst -Database $db
Write-DecomLog $log "Current DB status: $($state.Status)"
$broughtOnline = $false
if ($state.Status -match 'OFFLINE') {
    Write-DecomLog $log "Bringing DB online temporarily for the CommVault backup..."
    Set-DbaDbState -SqlInstance $inst -Database $db -Online -Force -Confirm:$false | Out-Null
    $broughtOnline = $true
}

$qoperation = Join-Path $QCommandDir 'qoperation.exe'
$qlogin     = Join-Path $QCommandDir 'qlogin.exe'

if (Test-Path $qoperation) {
    try {
        Write-DecomLog $log "CommVault CLI found. Logging in to $CommServe..."
        & $qlogin -cs $CommServe | ForEach-Object { Write-DecomLog $log $_ }

        Write-DecomLog $log "Submitting FULL backup job for subclient [$CvSubclient]..."
        $result = & $qoperation backup -c $CvClient -a $CvAgent -i $CvInstance -s $CvSubclient -t Q_FULL
        $result | ForEach-Object { Write-DecomLog $log $_ }
        Write-DecomLog $log "Backup job submitted. Monitor the job ID above in the CommCell console until it completes."
    }
    catch {
        Write-DecomLog $log "ERROR submitting CommVault job: $($_.Exception.Message)"
    }
}
else {
    Write-DecomLog $log "CommVault CLI not found at '$QCommandDir'."
    Write-DecomLog $log "MANUAL STEP: In the CommCell console, run an on-demand FULL backup of:"
    Write-DecomLog $log "  Client    : $CvClient"
    Write-DecomLog $log "  Agent     : $CvAgent"
    Write-DecomLog $log "  Instance  : $CvInstance"
    Write-DecomLog $log "  Database  : $db"
    Write-DecomLog $log "Record the CommVault job ID and completion time in this file."
}

if ($broughtOnline) {
    Write-DecomLog $log "Setting DB back OFFLINE after backup..."
    Set-DbaDbState -SqlInstance $inst -Database $db -Offline -Force -Confirm:$false | Out-Null
}

Write-DecomLog $log "STEP 4 COMPLETE (verify job success before Step 5)."
Write-Host "`nOutput written to: $log" -ForegroundColor Cyan
