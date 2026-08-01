<#
.SYNOPSIS
    STEP 6 - Create the "DECOM Notices" SQL Agent job on the target server
    (run once per server; safe to re-run - it only creates the job if missing).

    SMTP VERSION - no Database Mail required. The job step runs under the
    SQL Agent POWERSHELL subsystem, reads the tracking tables via .NET
    SqlClient (no module dependencies), and sends email directly through
    the SMTP relay configured in 00-Decom-Config.ps1 (SmtpServer, SmtpPort,
    SmtpFrom). The SQL Agent service account must be permitted to relay
    through that SMTP server.

    The job runs every day at 7:00 AM. It scans the DBA tracking tables for
    offline databases, disabled jobs, disabled logins, and SSIS packages
    that are 14+ days old AND have a NULL DecomDate, then sends one HTML
    email per email contact with subject "DECOM Notice". Body order:
      1. Server name
      2. Logins to be dropped + drop commands
      3. SSIS packages to delete
      4. Disabled jobs to drop + drop commands
      5. Database(s) to drop + drop commands
      6. UPDATE commands to stamp DecomDate on the rows in this email
      7. BOLD reminder to take a final CommVault backup before dropping

    Re-sends daily until DecomDate is populated on the rows.
#>

param(
    [bool]$Execute = $false
)

. "$PSScriptRoot\00-Decom-Config.ps1"
Confirm-DecomModules
$log = New-DecomLogFile -SectionName '06_DecomNoticesJob'

$inst     = $Global:DecomConfig.SourceInstance
$dbaDb    = $Global:DecomConfig.DbaDatabase
$smtpSrv  = $Global:DecomConfig.SmtpServer
$smtpPort = $Global:DecomConfig.SmtpPort
$smtpFrom = $Global:DecomConfig.SmtpFrom
$mode     = if ($Execute) { 'EXECUTE' } else { 'DRY RUN (report only)' }
Write-DecomLog $log "Mode: $mode | Instance: $inst | DBA DB: $dbaDb"
Write-DecomLog $log "SMTP: $smtpSrv`:$smtpPort | From: $smtpFrom"

if ($Execute) { Confirm-DecomTables }

# ------------------------------------------------------------------ job step
# This PowerShell runs ON THE SERVER under the SQL Agent service account.
# It uses only .NET types (SqlClient + SmtpClient) - no modules needed.
$jobStepPs = @"
`$ErrorActionPreference = 'Stop'
`$SmtpServer = '$smtpSrv'
`$SmtpPort   = $smtpPort
`$From       = '$smtpFrom'
`$DbaDb      = '$dbaDb'

# Older Windows/.NET (e.g. 2008R2) defaults to SSL3/TLS1.0. Enable TLS 1.2
# if this .NET build supports it; ignore if not (plain port-25 relay is fine).
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
} catch { }

`$connStr = "Server=localhost;Database=`$DbaDb;Integrated Security=SSPI;TrustServerCertificate=True;Encrypt=False"
`$conn = New-Object System.Data.SqlClient.SqlConnection `$connStr
`$conn.Open()

function Get-Rows([string]`$sql) {
    `$cmd = `$conn.CreateCommand()
    `$cmd.CommandText = `$sql
    `$da = New-Object System.Data.SqlClient.SqlDataAdapter `$cmd
    `$dt = New-Object System.Data.DataTable
    [void]`$da.Fill(`$dt)
    return ,`$dt
}

function Write-NoticeLog {
    param([string]`$svr, [string]`$contact, [string]`$status, [string]`$detail, [string]`$noticeBody)
    `$c = `$conn.CreateCommand()
    `$c.CommandText = 'INSERT INTO dbo.Decom_NotificationLog (AttemptDate, ServerName, EmailContact, SmtpTarget, Status, StatusDetail, NoticeBody) VALUES (GETDATE(), @svr, @contact, @target, @status, @detail, @body)'
    [void]`$c.Parameters.AddWithValue('@svr',     `$svr)
    [void]`$c.Parameters.AddWithValue('@contact', `$contact)
    [void]`$c.Parameters.AddWithValue('@target',  `$SmtpServer + ':' + `$SmtpPort)
    [void]`$c.Parameters.AddWithValue('@status',  `$status)
    [void]`$c.Parameters.AddWithValue('@detail',  `$detail)
    [void]`$c.Parameters.AddWithValue('@body',    `$noticeBody)
    [void]`$c.ExecuteNonQuery()
}

# --- SMTP reachability pre-check ------------------------------------------------
# TCP connect + read the greeting. A relay that accepts the connection then
# resets without a 220 banner (common when the source IP is not allowed to
# relay) counts as UNREACHABLE, so no send is attempted.
function Test-SmtpReachable {
    `$tcp = New-Object System.Net.Sockets.TcpClient
    try {
        `$async = `$tcp.BeginConnect(`$SmtpServer, `$SmtpPort, `$null, `$null)
        if (-not `$async.AsyncWaitHandle.WaitOne(5000)) { return 'TCP connect timed out after 5s' }
        `$tcp.EndConnect(`$async)
        `$stream = `$tcp.GetStream()
        `$stream.ReadTimeout = 5000
        `$buf = New-Object byte[] 512
        `$n = `$stream.Read(`$buf, 0, `$buf.Length)
        `$banner = [System.Text.Encoding]::ASCII.GetString(`$buf, 0, `$n).Trim()
        if (`$banner -notmatch '^220') { return 'No 220 greeting. Banner: ' + `$banner }
        return `$null   # reachable
    }
    catch {
        `$d = ''
        `$e = `$_.Exception
        while (`$e -ne `$null) { `$d = `$d + ' | ' + `$e.GetType().Name + ': ' + `$e.Message; `$e = `$e.InnerException }
        return 'Connection failed' + `$d
    }
    finally { `$tcp.Close() }
}

`$serverName = (Get-Rows "SELECT @@SERVERNAME AS S").Rows[0].S
`$cutoff     = (Get-Date).AddDays(-14)
`$cutoffStr  = `$cutoff.ToString('yyyy-MM-dd HH:mm:ss')

`$smtpProblem = Test-SmtpReachable
`$smtpOk = (`$smtpProblem -eq `$null)

`$contacts = Get-Rows @'
SELECT EmailContact FROM dbo.Decom_DisabledLogins   WHERE DateDisabled <= DATEADD(DAY,-14,GETDATE()) AND DecomDate IS NULL
UNION
SELECT EmailContact FROM dbo.Decom_SsisPackages     WHERE DateInserted <= DATEADD(DAY,-14,GETDATE()) AND DecomDate IS NULL
UNION
SELECT EmailContact FROM dbo.Decom_DisabledJobs     WHERE DateDisabled <= DATEADD(DAY,-14,GETDATE()) AND DecomDate IS NULL
UNION
SELECT EmailContact FROM dbo.Decom_OfflineDatabases WHERE DateOffline  <= DATEADD(DAY,-14,GETDATE()) AND DecomDate IS NULL
'@

`$sent    = 0
`$skipped = 0
`$failed  = 0

foreach (`$c in `$contacts.Rows) {
    `$email    = `$c.EmailContact
    `$emailEsc = `$email.Replace("'", "''")
    `$updates  = @()

    `$body = "<p>Server: <b>`$serverName</b></p>"

    # ---- Logins to drop ----
    `$rows = Get-Rows "SELECT LoginName, DropCommand FROM dbo.Decom_DisabledLogins WHERE EmailContact = N'`$emailEsc' AND DateDisabled <= DATEADD(DAY,-14,GETDATE()) AND DecomDate IS NULL ORDER BY LoginName"
    if (`$rows.Rows.Count -gt 0) {
        `$list = (`$rows.Rows | ForEach-Object { 'Login: ' + `$_.LoginName + ' &nbsp;&mdash;&nbsp; ' + `$_.DropCommand }) -join '<br/>'
        `$updates += "UPDATE `$DbaDb.dbo.Decom_DisabledLogins SET DecomDate = CAST(GETDATE() AS DATE) WHERE EmailContact = N'`$emailEsc' AND DecomDate IS NULL AND DateDisabled &lt;= '`$cutoffStr';"
    } else { `$list = 'None' }
    `$body += "<p><u>Logins to be dropped:</u><br/>`$list</p>"

    # ---- SSIS packages to delete ----
    `$rows = Get-Rows "SELECT PackagePath FROM dbo.Decom_SsisPackages WHERE EmailContact = N'`$emailEsc' AND DateInserted <= DATEADD(DAY,-14,GETDATE()) AND DecomDate IS NULL ORDER BY PackagePath"
    if (`$rows.Rows.Count -gt 0) {
        `$list = (`$rows.Rows | ForEach-Object { `$_.PackagePath }) -join '<br/>'
        `$updates += "UPDATE `$DbaDb.dbo.Decom_SsisPackages SET DecomDate = CAST(GETDATE() AS DATE) WHERE EmailContact = N'`$emailEsc' AND DecomDate IS NULL AND DateInserted &lt;= '`$cutoffStr';"
    } else { `$list = 'None' }
    `$body += "<p><u>SSIS packages to delete:</u><br/>`$list</p>"

    # ---- Disabled jobs to drop ----
    `$rows = Get-Rows "SELECT JobName, DropCommand FROM dbo.Decom_DisabledJobs WHERE EmailContact = N'`$emailEsc' AND DateDisabled <= DATEADD(DAY,-14,GETDATE()) AND DecomDate IS NULL ORDER BY JobName"
    if (`$rows.Rows.Count -gt 0) {
        `$list = (`$rows.Rows | ForEach-Object { 'Job: ' + `$_.JobName + ' &nbsp;&mdash;&nbsp; ' + `$_.DropCommand }) -join '<br/>'
        `$updates += "UPDATE `$DbaDb.dbo.Decom_DisabledJobs SET DecomDate = CAST(GETDATE() AS DATE) WHERE EmailContact = N'`$emailEsc' AND DecomDate IS NULL AND DateDisabled &lt;= '`$cutoffStr';"
    } else { `$list = 'None' }
    `$body += "<p><u>Disabled jobs to drop:</u><br/>`$list</p>"

    # ---- Databases to drop ----
    `$rows = Get-Rows "SELECT DatabaseName, DropCommand FROM dbo.Decom_OfflineDatabases WHERE EmailContact = N'`$emailEsc' AND DateOffline <= DATEADD(DAY,-14,GETDATE()) AND DecomDate IS NULL ORDER BY DatabaseName"
    if (`$rows.Rows.Count -gt 0) {
        `$list = (`$rows.Rows | ForEach-Object { 'Database: ' + `$_.DatabaseName + ' &nbsp;&mdash;&nbsp; ' + `$_.DropCommand }) -join '<br/>'
        `$updates += "UPDATE `$DbaDb.dbo.Decom_OfflineDatabases SET DecomDate = CAST(GETDATE() AS DATE) WHERE EmailContact = N'`$emailEsc' AND DecomDate IS NULL AND DateOffline &lt;= '`$cutoffStr';"
    } else { `$list = 'None' }
    `$body += "<p><u>Database(s) to drop:</u><br/>`$list</p>"

    # ---- UPDATE commands to stamp DecomDate ----
    if (`$updates.Count -gt 0) { `$list = `$updates -join '<br/>' } else { `$list = 'None' }
    `$body += "<p><u>After completing the drops above, run these commands to record the decom date and stop these notices:</u><br/>`$list</p>"

    # ---- Final bold reminder ----
    `$body += "<p><b>Reminder: Take a final CommVault backup before dropping the database(s).</b></p>"
     $body += "<p><b>Initiate Server Decom Process:</b> Click the following link: <a ref= 'https://svcnowprod.service-now.com/sp?id=sc_cat_item&sys_id=1f9241411b1e7694e113ecea234bcb1f'>Service Catalog - Decom Server</a href></p>"

    if (-not `$smtpOk) {
        # SMTP is unreachable - do NOT attempt the send. Record the notice
        # (including the full body) so nothing is lost, and leave DecomDate
        # NULL so the notice re-fires once mail is working again.
        Write-NoticeLog `$serverName `$email 'SmtpUnreachable' `$smtpProblem `$body
        `$skipped = `$skipped + 1
        continue
    }

    `$msg = New-Object System.Net.Mail.MailMessage
    `$msg.From = `$From
    `$msg.To.Add(`$email)
    `$msg.Subject = 'DECOM Notice'
    `$msg.Body = `$body
    `$msg.IsBodyHtml = `$true
    `$smtp = New-Object System.Net.Mail.SmtpClient(`$SmtpServer, `$SmtpPort)
    try {
        `$smtp.Send(`$msg)
        Write-NoticeLog `$serverName `$email 'Sent' `$null `$body
        `$sent = `$sent + 1
    }
    catch {
        # Surface the WHOLE exception chain - the outer 'Failure sending mail'
        # hides the real SMTP/socket error in the inner exceptions.
        `$detail = ''
        `$ex = `$_.Exception
        while (`$ex -ne `$null) {
            `$detail = `$detail + ' | ' + `$ex.GetType().Name + ': ' + `$ex.Message
            `$ex = `$ex.InnerException
        }
        Write-NoticeLog `$serverName `$email 'SendFailed' `$detail `$body
        `$failed = `$failed + 1
    }
    finally {
        `$msg.Dispose()
    }
}
`$conn.Close()

Write-Output ('DECOM Notices summary: sent=' + `$sent + ' skipped(SMTP unreachable)=' + `$skipped + ' failed=' + `$failed)
if (`$skipped -gt 0) {
    Write-Output ('SMTP unreachable at ' + `$SmtpServer + ':' + `$SmtpPort + ' - ' + `$smtpProblem)
    Write-Output 'Notices were recorded in dbo.Decom_NotificationLog (Status = SmtpUnreachable) and will re-send automatically once SMTP works. No DecomDate was stamped.'
}
if (`$failed -gt 0) { throw ('One or more DECOM notices failed to send. See dbo.Decom_NotificationLog for details.') }
"@

# ------------------------------------------------------------------ job creation
$escapedStep = $jobStepPs.Replace("'", "''")
$createJobSql = @"
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DECOM Notices')
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name    = N'DECOM Notices',
        @enabled     = 1,
        @description = N'Daily 7AM scan of DBA decom tracking tables; emails drop lists for objects 14+ days old via SMTP (no Database Mail dependency).';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name      = N'DECOM Notices',
        @step_name     = N'Send DECOM notices via SMTP',
        @subsystem     = N'PowerShell',
        @command       = N'$escapedStep';

    EXEC msdb.dbo.sp_add_jobschedule
        @job_name          = N'DECOM Notices',
        @name              = N'Daily 7AM',
        @freq_type         = 4,        -- daily
        @freq_interval     = 1,        -- every 1 day
        @active_start_time = 070000;   -- 7:00 AM

    EXEC msdb.dbo.sp_add_jobserver @job_name = N'DECOM Notices';
    SELECT 'Created' AS Result;
END
ELSE
    SELECT 'Already exists - no changes made' AS Result;
"@

if ($Execute) {
    $result = Invoke-DbaQuery -SqlInstance $inst -Database msdb -Query $createJobSql
    Write-DecomLog $log "DECOM Notices job: $($result.Result)"
    Write-DecomLog $log "Schedule: daily at 7:00 AM | Subject: 'DECOM Notice' | One email per distinct EmailContact."
    Write-DecomLog $log "Step subsystem: PowerShell (uses .NET SqlClient + SmtpClient; NO Database Mail required)."
    Write-DecomLog $log "REQUIREMENT: SQL Agent service account must be allowed to relay via $smtpSrv`:$smtpPort."
    Write-DecomLog $log "TIP: To re-deploy after config changes, delete the 'DECOM Notices' job and re-run this script."
} else {
    Write-DecomLog $log "DRY RUN: would create the 'DECOM Notices' job (if missing) with a PowerShell step that:"
    Write-DecomLog $log " - queries the four tracking tables (14+ days old, DecomDate IS NULL)"
    Write-DecomLog $log " - sends one HTML email per contact via SMTP $smtpSrv`:$smtpPort from $smtpFrom"
    Write-DecomLog $log " - includes drop commands, DecomDate UPDATE commands, and the bold CommVault reminder"
}

Write-Host "`nOutput written to: $log" -ForegroundColor Cyan
