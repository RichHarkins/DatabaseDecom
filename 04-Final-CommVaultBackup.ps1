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

#region --- CommVault environment settings ------------------------------------
# CommServe and login come from 00-Decom-Config.ps1; the rest are per-agent.
$CommServe   = $Global:DecomConfig.CommServe
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
$qlogout    = Join-Path $QCommandDir 'qlogout.exe'

if (Test-Path $qoperation) {
    $loggedIn = $false
    try {
        Write-DecomLog $log "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

        # --- Login -------------------------------------------------------------
        # Bare 'qlogin -cs <cs>' does NOT reuse the CommCell console's cached
        # session and often fails auth even when the console works. Be explicit.
        $auth = $Global:DecomConfig.CommVaultAuth
        $user = $Global:DecomConfig.CommVaultUser

        if ($auth -eq 'Windows') {
            # Integrated auth: -tokenfile uses the current Windows identity,
            # the same way the console authenticates. No password needed.
            Write-DecomLog $log "Logging in to $CommServe with current Windows identity (-tokenfile)..."
            $loginOut = & $qlogin -cs $CommServe -tokenfile 2>&1
        }
        else {
            # CommVault-native auth: prompt for the password (never stored).
            if ([string]::IsNullOrWhiteSpace($user)) {
                $user = Read-Host "CommVault user for $CommServe"
            }
            Write-DecomLog $log "Logging in to $CommServe as CommVault user '$user' (password prompt)..."
            $sec = Read-Host "Password for CommVault user '$user'" -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            $loginOut = & $qlogin -cs $CommServe -u $user -clp $plain 2>&1
            $plain = $null
        }

        $loginOut | ForEach-Object { Write-DecomLog $log $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "qlogin failed (exit $LASTEXITCODE). See the qlogin output above."
        }
        $loggedIn = $true
        Write-DecomLog $log "Login succeeded."

        # --- Submit backup -----------------------------------------------------
        Write-DecomLog $log "Submitting FULL backup job for subclient [$CvSubclient]..."
        $result = & $qoperation backup -c $CvClient -a $CvAgent -i $CvInstance -s $CvSubclient -t Q_FULL 2>&1
        $result | ForEach-Object { Write-DecomLog $log $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "qoperation backup failed (exit $LASTEXITCODE). See the output above."
        }
        Write-DecomLog $log "Backup job submitted. Monitor the job ID above in the CommCell console until it completes."
    }
    catch {
        Write-DecomLog $log "ERROR: $($_.Exception.Message)"
        Write-DecomLog $log "Login troubleshooting:"
        Write-DecomLog $log " - The CommCell console caches a session, so it can work while a fresh"
        Write-DecomLog $log "   qlogin fails. This script logs in explicitly instead."
        Write-DecomLog $log " - If using Windows auth, confirm this account (logged above) is an"
        Write-DecomLog $log "   Active Directory user mapped in CommVault with backup rights on [$CvClient]."
        Write-DecomLog $log " - If your CommServe uses CommVault-native accounts, set CommVaultAuth ="
        Write-DecomLog $log "   'CommVault' and CommVaultUser in 00-Decom-Config.ps1, then re-run."
        Write-DecomLog $log " - As a fallback, submit the FULL backup manually in the CommCell console:"
        Write-DecomLog $log "     Client=$CvClient  Agent=$CvAgent  Instance=$CvInstance  Database=$db"
    }
    finally {
        if ($loggedIn -and (Test-Path $qlogout)) {
            & $qlogout 2>&1 | Out-Null
            Write-DecomLog $log "Logged out of CommServe session."
        }
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
