<#
.SYNOPSIS
    Shared configuration for the Database Decommission process.
    Dot-source this at the top of every step script:
        . "$PSScriptRoot\00-Decom-Config.ps1"
#>

#region --- EDIT THESE VALUES PER DECOM ---------------------------------------
$Global:DecomConfig = [PSCustomObject]@{
    SourceInstance    = 'SQLPROD01'                      # Instance hosting the DB to decom
    DatabaseName      = 'MyDatabase'                     # DB being decommissioned
    SpecialServer     = 'SPECIALSVR01'                   # "Special" server instance name
    SpecialSharePath  = '\\SPECIALSVR01\DecomBackups'    # UNC path for backup files
    OutputFolder      = "C:\DecomOutput\MyDatabase"      # Where all section text files land
    ChangeTicket      = 'CHG0000000'                     # Normal change ticket number
    SnowRequest       = ''                               # SNOW request # for account removal
    DbaDatabase       = 'DBA'                            # DBA utility database (holds decom tracking tables)
    EmailContact      = 'dba-team@yourcompany.com'       # Email contact stored with each tracked object / notice recipient
    SmtpServer        = 'smtp.yourcompany.com'           # SMTP relay used by the DECOM Notices job
    SmtpPort          = 25                               # SMTP port (25 = standard internal relay)
    SmtpFrom          = 'sql-decom@yourcompany.com'      # From address for DECOM Notice emails
    PollServers       = @('PHX00514','SQLPROD01')        # Instances the central forwarder polls
                                                         # for undelivered notices (08 script)
    CommServe         = 'COMMSERVE01'                     # CommVault CommServe host (Step 4)
    CommVaultUser     = ''                                # CommVault login user for qlogin. Blank =
                                                         # use current Windows identity (-tokenfile).
                                                         # DOMAIN\user or CV local user, e.g. 'admin'.
    CommVaultAuth     = 'Windows'                         # 'Windows' (integrated) or 'CommVault' (CV
                                                         # user/pwd, prompted). Windows matches how
                                                         # the CommCell console usually authenticates.
}
#endregion --------------------------------------------------------------------

#region --- Config normalization ------------------------------------------------
# Backward compatibility: earlier versions of this config used 'ReminderEmail'.
# If EmailContact is missing/blank but ReminderEmail exists, carry it over.
$ecProp = $Global:DecomConfig.PSObject.Properties['EmailContact']
$reProp = $Global:DecomConfig.PSObject.Properties['ReminderEmail']
if ((-not $ecProp -or [string]::IsNullOrWhiteSpace($ecProp.Value)) -and
    $reProp -and -not [string]::IsNullOrWhiteSpace($reProp.Value)) {
    $Global:DecomConfig | Add-Member -NotePropertyName EmailContact `
        -NotePropertyValue $reProp.Value -Force
    Write-Host "Config note: mapped legacy 'ReminderEmail' to 'EmailContact'." -ForegroundColor Yellow
}
#endregion --------------------------------------------------------------------

#region --- Module check / install ---------------------------------------------
function Confirm-DecomModules {
    [CmdletBinding()]
    param(
        [string[]]$Modules = @('SqlServer', 'dbatools')
    )

    # Ensure NuGet provider + trusted PSGallery so installs are non-interactive
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Write-Host "Installing NuGet package provider..." -ForegroundColor Yellow
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    foreach ($m in $Modules) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Write-Host "Module '$m' not found. Installing..." -ForegroundColor Yellow
            Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber
        }
        Import-Module $m -ErrorAction Stop
        Write-Host "Module '$m' loaded (v$((Get-Module $m).Version))." -ForegroundColor Green
    }

    # --- Connection security: TrustServerCertificate=True; Encrypt=False -----
    # dbatools v2+ defaults to encrypted connections with certificate
    # validation, which fails against instances using self-signed certs.
    # These settings apply to every Dba* cmdlet in this session, so all
    # connections in the decom scripts use:
    #     TrustServerCertificate=True; Encrypt=False
    if (Get-Module -Name dbatools) {
        Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $true  | Out-Null
        Set-DbatoolsConfig -FullName 'sql.connection.encrypt'  -Value $false | Out-Null
        Write-Host "dbatools connections set to TrustServerCertificate=True; Encrypt=False." -ForegroundColor Green
    }
}
#endregion --------------------------------------------------------------------

#region --- DBA tracking tables -------------------------------------------------
function Confirm-DecomTables {
<#  Ensures the tracking tables exist in the DBA database on the configured
    SourceInstance. #>
    Confirm-DecomTablesOn -Instance $Global:DecomConfig.SourceInstance
}

function Confirm-DecomTablesOn {
<#  Same as Confirm-DecomTables but against an arbitrary instance - used by
    the central forwarder (08) when polling remote servers. #>
    param([Parameter(Mandatory)][string]$Instance)
    Invoke-DbaQuery -SqlInstance $Instance -Database $Global:DecomConfig.DbaDatabase -Query $Global:DecomTableDdl
}
#  Table DDL shared by Confirm-DecomTables / Confirm-DecomTablesOn.
$Global:DecomTableDdl = @"
IF OBJECT_ID(N'dbo.Decom_OfflineDatabases') IS NULL
    CREATE TABLE dbo.Decom_OfflineDatabases (
        DatabaseName SYSNAME        NOT NULL,
        DateOffline  DATETIME       NOT NULL,
        DropCommand  NVARCHAR(MAX)  NOT NULL,
        EmailContact NVARCHAR(256)  NOT NULL,
        DecomDate    DATE           NULL
    );
IF OBJECT_ID(N'dbo.Decom_DisabledJobs') IS NULL
    CREATE TABLE dbo.Decom_DisabledJobs (
        DatabaseName SYSNAME        NOT NULL,
        JobName      SYSNAME        NOT NULL,
        DateDisabled DATETIME       NOT NULL,
        DropCommand  NVARCHAR(MAX)  NOT NULL,
        EmailContact NVARCHAR(256)  NOT NULL,
        DecomDate    DATE           NULL
    );
IF OBJECT_ID(N'dbo.Decom_DisabledLogins') IS NULL
    CREATE TABLE dbo.Decom_DisabledLogins (
        DatabaseName SYSNAME        NOT NULL,
        LoginName    SYSNAME        NOT NULL,
        DateDisabled DATETIME       NOT NULL,
        DropCommand  NVARCHAR(MAX)  NOT NULL,
        EmailContact NVARCHAR(256)  NOT NULL,
        DecomDate    DATE           NULL
    );
IF OBJECT_ID(N'dbo.Decom_SsisPackages') IS NULL
    CREATE TABLE dbo.Decom_SsisPackages (
        DatabaseName SYSNAME        NOT NULL,
        PackagePath  NVARCHAR(1024) NOT NULL,
        DateInserted DATETIME       NOT NULL,
        EmailContact NVARCHAR(256)  NOT NULL,
        DecomDate    DATE           NULL
    );
IF OBJECT_ID(N'dbo.Decom_NotificationLog') IS NULL
    CREATE TABLE dbo.Decom_NotificationLog (
        NotificationId INT IDENTITY(1,1) PRIMARY KEY,
        AttemptDate    DATETIME       NOT NULL,
        ServerName     SYSNAME        NOT NULL,
        EmailContact   NVARCHAR(256)  NOT NULL,
        SmtpTarget     NVARCHAR(256)  NOT NULL,
        Status         NVARCHAR(50)   NOT NULL,   -- Sent | SmtpUnreachable | SendFailed
        StatusDetail   NVARCHAR(MAX)  NULL,
        NoticeBody     NVARCHAR(MAX)  NULL,       -- full HTML body, so an undelivered
        ForwardedDate  DATETIME       NULL,       -- notice is never lost
        ForwardedBy    SYSNAME        NULL        -- host that relayed it on our behalf
    );

-- Add forwarding columns to any pre-existing notification log
IF COL_LENGTH(N'dbo.Decom_NotificationLog', N'ForwardedDate') IS NULL
    ALTER TABLE dbo.Decom_NotificationLog ADD ForwardedDate DATETIME NULL;
IF COL_LENGTH(N'dbo.Decom_NotificationLog', N'ForwardedBy') IS NULL
    ALTER TABLE dbo.Decom_NotificationLog ADD ForwardedBy SYSNAME NULL;

-- Add DecomDate to any pre-existing tables that lack it
IF COL_LENGTH(N'dbo.Decom_OfflineDatabases', N'DecomDate') IS NULL
    ALTER TABLE dbo.Decom_OfflineDatabases ADD DecomDate DATE NULL;
IF COL_LENGTH(N'dbo.Decom_DisabledJobs', N'DecomDate') IS NULL
    ALTER TABLE dbo.Decom_DisabledJobs ADD DecomDate DATE NULL;
IF COL_LENGTH(N'dbo.Decom_DisabledLogins', N'DecomDate') IS NULL
    ALTER TABLE dbo.Decom_DisabledLogins ADD DecomDate DATE NULL;
IF COL_LENGTH(N'dbo.Decom_SsisPackages', N'DecomDate') IS NULL
    ALTER TABLE dbo.Decom_SsisPackages ADD DecomDate DATE NULL;
"@
#endregion --------------------------------------------------------------------

#region --- Shared disable-and-track operations ---------------------------------
function Disable-DecomAgentJobs {
<#  Disables agent jobs referencing the decom database and records them in
    Decom_DisabledJobs. Idempotent: jobs already tracked (DecomDate IS NULL)
    are skipped, so this can run in Step 2 and again as a sweep in Step 5. #>
    param(
        [Parameter(Mandatory)][string]$LogFile,
        [bool]$Execute = $true
    )
    $inst    = $Global:DecomConfig.SourceInstance
    $db      = $Global:DecomConfig.DatabaseName
    $dbaDb   = $Global:DecomConfig.DbaDatabase
    $contact = $Global:DecomConfig.EmailContact

    $scriptOutDir = Join-Path $Global:DecomConfig.OutputFolder 'ScriptedJobs'
    if (-not (Test-Path $scriptOutDir)) { New-Item $scriptOutDir -ItemType Directory -Force | Out-Null }

    $jobs = Get-DbaAgentJob -SqlInstance $inst | Where-Object {
        $_.JobSteps | Where-Object { $_.DatabaseName -eq $db -or $_.Command -match [regex]::Escape($db) }
    }
    if (-not $jobs) {
        Write-DecomLog $LogFile "No agent jobs reference [$db]."
        return
    }

    foreach ($job in $jobs) {
        $jobName = $job.Name
        $tracked = Invoke-DbaQuery -SqlInstance $inst -Database $dbaDb `
            -Query "SELECT COUNT(*) AS Cnt FROM dbo.Decom_DisabledJobs WHERE DatabaseName = @DatabaseName AND JobName = @JobName AND DecomDate IS NULL;" `
            -SqlParameter @{ DatabaseName = $db; JobName = $jobName }
        if ($tracked.Cnt -gt 0) {
            Write-DecomLog $LogFile "Job '$jobName' already disabled and tracked - skipping."
            continue
        }

        # Full recreate script saved to disk as a safety net
        $file = Join-Path $scriptOutDir ("Job_" + ($jobName -replace '[\\/:*?"<>|]','_') + '.sql')
        $job.Script() | Out-File -FilePath $file -Encoding UTF8
        Write-DecomLog $LogFile "Scripted out job '$jobName' -> $file"

        $dropCmd = "EXEC msdb.dbo.sp_delete_job @job_name = N'$($jobName.Replace("'","''"))', @delete_unused_schedule = 1;"

        if ($Execute) {
            Set-DbaAgentJob -SqlInstance $inst -Job $jobName -Disabled -Confirm:$false | Out-Null
            Invoke-DbaQuery -SqlInstance $inst -Database $dbaDb `
                -Query "INSERT INTO dbo.Decom_DisabledJobs (DatabaseName, JobName, DateDisabled, DropCommand, EmailContact) VALUES (@DatabaseName, @JobName, GETDATE(), @DropCommand, @EmailContact);" `
                -SqlParameter @{ DatabaseName = $db; JobName = $jobName; DropCommand = $dropCmd; EmailContact = $contact }
            Write-DecomLog $LogFile "DISABLED job '$jobName' and recorded in [$dbaDb].dbo.Decom_DisabledJobs."
        } else {
            Write-DecomLog $LogFile "DRY RUN: would disable '$jobName' and record drop command: $dropCmd"
        }
    }
}

function Disable-DecomLogins {
<#  Disables server logins mapped ONLY to the decom database and records them
    in Decom_DisabledLogins. Idempotent: logins already tracked (DecomDate IS
    NULL) are skipped, so this can run in Step 2 and again in Step 5. #>
    param(
        [Parameter(Mandatory)][string]$LogFile,
        [bool]$Execute = $true
    )
    $inst    = $Global:DecomConfig.SourceInstance
    $db      = $Global:DecomConfig.DatabaseName
    $dbaDb   = $Global:DecomConfig.DbaDatabase
    $contact = $Global:DecomConfig.EmailContact

    # Users cannot be enumerated while the DB is offline
    $state = Get-DbaDbState -SqlInstance $inst -Database $db
    if ($state.Status -match 'OFFLINE') {
        Write-DecomLog $LogFile "Database is OFFLINE - cannot enumerate users. Logins were disabled in Step 2 before the DB went offline; see Decom_DisabledLogins for the tracked list."
        return
    }

    $dbUsers = Get-DbaDbUser -SqlInstance $inst -Database $db -ExcludeSystemUser
    Write-DecomLog $LogFile "Users in [$db]:"
    $dbUsers | Select-Object Name, Login, LoginType |
        Format-Table -AutoSize | Out-String | ForEach-Object { Write-DecomLog $LogFile $_ }

    # Server logins whose ONLY mapping is this database = candidates
    $candidates = @()
    foreach ($u in ($dbUsers | Where-Object Login)) {
        $otherMaps = Get-DbaDbUser -SqlInstance $inst -ExcludeSystemUser |
            Where-Object { $_.Login -eq $u.Login -and $_.Database -ne $db }
        if (-not $otherMaps) { $candidates += $u.Login }
    }
    $candidates = $candidates | Sort-Object -Unique

    if (-not $candidates) {
        Write-DecomLog $LogFile "No logins are exclusive to this database."
        return
    }

    Write-DecomLog $LogFile "Logins mapped ONLY to [$db] (will be DISABLED, not dropped):"
    foreach ($l in $candidates) {
        $tracked = Invoke-DbaQuery -SqlInstance $inst -Database $dbaDb `
            -Query "SELECT COUNT(*) AS Cnt FROM dbo.Decom_DisabledLogins WHERE DatabaseName = @DatabaseName AND LoginName = @LoginName AND DecomDate IS NULL;" `
            -SqlParameter @{ DatabaseName = $db; LoginName = $l }
        if ($tracked.Cnt -gt 0) {
            Write-DecomLog $LogFile "Login '$l' already disabled and tracked - skipping."
            continue
        }

        $escaped     = $l.Replace(']', ']]')
        $disableStmt = "ALTER LOGIN [$escaped] DISABLE;"
        $dropCmd     = "DROP LOGIN [$escaped];"

        if ($Execute) {
            Invoke-DbaQuery -SqlInstance $inst -Database master -Query $disableStmt
            Invoke-DbaQuery -SqlInstance $inst -Database $dbaDb `
                -Query "INSERT INTO dbo.Decom_DisabledLogins (DatabaseName, LoginName, DateDisabled, DropCommand, EmailContact) VALUES (@DatabaseName, @LoginName, GETDATE(), @DropCommand, @EmailContact);" `
                -SqlParameter @{ DatabaseName = $db; LoginName = $l; DropCommand = $dropCmd; EmailContact = $contact }
            Write-DecomLog $LogFile "DISABLED login '$l' and recorded in [$dbaDb].dbo.Decom_DisabledLogins."
        } else {
            Write-DecomLog $LogFile "DRY RUN: would run '$disableStmt' and record drop command: $dropCmd"
        }
    }

    Write-DecomLog $LogFile "SNOW REQUEST TEMPLATE (AD/service accounts):"
    Write-DecomLog $LogFile "  Summary : Remove service accounts after decom of [$db] on [$inst]"
    $candidates | ForEach-Object { Write-DecomLog $LogFile "            - $_" }
    Write-DecomLog $LogFile "  SNOW Request #: $($Global:DecomConfig.SnowRequest)"
}
#endregion --------------------------------------------------------------------

#region --- Output helpers ------------------------------------------------------
function Initialize-DecomOutput {
    if (-not (Test-Path $Global:DecomConfig.OutputFolder)) {
        New-Item -Path $Global:DecomConfig.OutputFolder -ItemType Directory -Force | Out-Null
    }
}

function New-DecomLogFile {
    param([Parameter(Mandatory)][string]$SectionName)
    Initialize-DecomOutput
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path  = Join-Path $Global:DecomConfig.OutputFolder "$SectionName`_$($Global:DecomConfig.DatabaseName)_$stamp.txt"
    "==== $SectionName | DB: $($Global:DecomConfig.DatabaseName) | Instance: $($Global:DecomConfig.SourceInstance) | $(Get-Date) ====" |
        Out-File -FilePath $path -Encoding UTF8
    return $path
}

function Write-DecomLog {
    param(
        [Parameter(Mandatory)][string]$LogFile,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )
    # Trim trailing whitespace per line (Format-Table pads heavily) and
    # timestamp each line so multi-line blocks stay readable.
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $lines = ($Message -split "`r?`n") | ForEach-Object { "[{0}] {1}" -f $stamp, $_.TrimEnd() }
    # Add-Content with explicit UTF8 keeps the whole file in ONE encoding.
    # (Tee-Object appends UTF-16 in Windows PowerShell, which corrupts a
    # file that was created as UTF-8 and makes it unreadable in Notepad.)
    Add-Content -Path $LogFile -Value $lines -Encoding UTF8
    $lines | ForEach-Object { Write-Host $_ }
}
#endregion --------------------------------------------------------------------

