<#
.SYNOPSIS
    STEP 8 - Central notice forwarder. Run this ON A SERVER WHERE SMTP WORKS.

    Servers that cannot reach the SMTP relay (see the DECOM Notices job in
    06-Create-DecomNoticesJob.ps1) record their notices in
    DBA.dbo.Decom_NotificationLog with Status = 'SmtpUnreachable' instead of
    sending them. This script polls those servers, picks up the undelivered
    notices - the full HTML body is already stored, so nothing is recomposed -
    and relays them from a host that CAN send mail.

    Only the MOST RECENT undelivered notice per (server, contact) is sent, so
    a relay that has been down for a week produces one email, not seven. Older
    rows are marked superseded. Sent rows are stamped with ForwardedDate and
    ForwardedBy on the source server, so the audit trail stays with the server
    the objects belong to.

    Deploy as a daily SQL Agent job on the mail-capable server (a little after
    the 7AM DECOM Notices runs - 7:30AM works well), or run it on demand.

.PARAMETER Servers
    Instances to poll. Defaults to PollServers in 00-Decom-Config.ps1.

.PARAMETER WhatIfOnly
    Report what would be forwarded without sending or updating anything.

.EXAMPLE
    .\08-Forward-PendingNotices.ps1
    .\08-Forward-PendingNotices.ps1 -Servers 'PHX00514' -WhatIfOnly
#>
param(
    [string[]]$Servers,
    [switch]$WhatIfOnly
)

. "$PSScriptRoot\00-Decom-Config.ps1"
Confirm-DecomModules
$log = New-DecomLogFile -SectionName '08_ForwardPendingNotices'

if (-not $Servers) { $Servers = $Global:DecomConfig.PollServers }
$dbaDb    = $Global:DecomConfig.DbaDatabase
$smtpSrv  = $Global:DecomConfig.SmtpServer
$smtpPort = $Global:DecomConfig.SmtpPort
$smtpFrom = $Global:DecomConfig.SmtpFrom
$thisHost = $env:COMPUTERNAME

Write-DecomLog $log "Central forwarder running on $thisHost"
Write-DecomLog $log "SMTP: $smtpSrv`:$smtpPort | From: $smtpFrom"
Write-DecomLog $log "Polling: $($Servers -join ', ')"
if ($WhatIfOnly) { Write-DecomLog $log "MODE: WhatIfOnly - nothing will be sent or updated." }

# --- Confirm this host can actually send before touching anything --------------
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
} catch { }

$tcp = New-Object System.Net.Sockets.TcpClient
try {
    $async = $tcp.BeginConnect($smtpSrv, $smtpPort, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne(5000)) { throw "TCP connect timed out after 5s." }
    $tcp.EndConnect($async)
    $stream = $tcp.GetStream(); $stream.ReadTimeout = 5000
    $buf = New-Object byte[] 512
    $n = $stream.Read($buf, 0, $buf.Length)
    $banner = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim()
    if ($banner -notmatch '^220') { throw "No 220 greeting from relay. Banner: $banner" }
    Write-DecomLog $log "SMTP reachable from $thisHost. Banner: $banner"
}
catch {
    Write-DecomLog $log "ERROR: This host cannot reach $smtpSrv`:$smtpPort - $($_.Exception.Message)"
    Write-DecomLog $log "Run this script from a server where mail is known to work."
    throw
}
finally { $tcp.Close() }

$totalSent = 0; $totalSuperseded = 0

foreach ($srv in $Servers) {
    Write-DecomLog $log ""
    Write-DecomLog $log "--- $srv ---"

    try {
        Confirm-DecomTablesOn -Instance $srv   # ensures forwarding columns exist
    }
    catch {
        Write-DecomLog $log "SKIP: cannot prepare/reach [$dbaDb] on $srv - $($_.Exception.Message)"
        continue
    }

    # Newest undelivered notice per contact
    $pending = Invoke-DbaQuery -SqlInstance $srv -Database $dbaDb -Query @"
DECLARE @Latest TABLE (NotificationId INT, AttemptDate DATETIME, ServerName SYSNAME,
                       EmailContact NVARCHAR(256), NoticeBody NVARCHAR(MAX));
INSERT INTO @Latest
SELECT n.NotificationId, n.AttemptDate, n.ServerName, n.EmailContact, n.NoticeBody
FROM dbo.Decom_NotificationLog n
WHERE n.Status IN ('SmtpUnreachable','SendFailed')
  AND n.ForwardedDate IS NULL
  AND n.AttemptDate = (SELECT MAX(n2.AttemptDate)
                       FROM dbo.Decom_NotificationLog n2
                       WHERE n2.EmailContact = n.EmailContact
                         AND n2.Status IN ('SmtpUnreachable','SendFailed')
                         AND n2.ForwardedDate IS NULL);
SELECT * FROM @Latest ORDER BY EmailContact;
"@

    if (-not $pending) {
        Write-DecomLog $log "No undelivered notices pending."
        continue
    }

    foreach ($row in $pending) {
        $contact = $row.EmailContact
        Write-DecomLog $log "Pending notice for $contact (recorded $($row.AttemptDate) on $($row.ServerName))"

        if ($WhatIfOnly) { continue }

        $msg = New-Object System.Net.Mail.MailMessage
        $msg.From = $smtpFrom
        $msg.To.Add($contact)
        $msg.Subject = 'DECOM Notice'
        # Note at the top explaining why this arrived from a different host
        $msg.Body = "<p><i>Relayed by $thisHost because $($row.ServerName) cannot reach the mail relay. " +
                    "Notice generated $($row.AttemptDate).</i></p><hr/>" + $row.NoticeBody
        $msg.IsBodyHtml = $true
        $smtp = New-Object System.Net.Mail.SmtpClient($smtpSrv, $smtpPort)

        try {
            $smtp.Send($msg)
            Write-DecomLog $log "  SENT to $contact"
            $totalSent++

            # Stamp the delivered row, and supersede older undelivered rows
            # for the same contact so they are not re-sent later.
            $upd = Invoke-DbaQuery -SqlInstance $srv -Database $dbaDb -Query @"
UPDATE dbo.Decom_NotificationLog
SET Status = 'Sent',
    StatusDetail = ISNULL(StatusDetail, N'') + N' | Forwarded by @Host',
    ForwardedDate = GETDATE(),
    ForwardedBy = @Host
WHERE NotificationId = @Id;

UPDATE dbo.Decom_NotificationLog
SET Status = 'Superseded',
    ForwardedDate = GETDATE(),
    ForwardedBy = @Host
WHERE EmailContact = @Contact
  AND ForwardedDate IS NULL
  AND Status IN ('SmtpUnreachable','SendFailed');

SELECT @@ROWCOUNT AS Superseded;
"@ -SqlParameter @{ Id = $row.NotificationId; Host = $thisHost; Contact = $contact }
            Write-DecomLog $log "  Marked delivered; $($upd.Superseded) older notice(s) superseded."
            $totalSuperseded += [int]$upd.Superseded
        }
        catch {
            $detail = ''
            $ex = $_.Exception
            while ($ex -ne $null) { $detail += " | $($ex.GetType().Name): $($ex.Message)"; $ex = $ex.InnerException }
            Write-DecomLog $log "  FAILED to send to $contact$detail"
        }
        finally { $msg.Dispose() }
    }
}

Write-DecomLog $log ""
Write-DecomLog $log "Forwarder complete: $totalSent notice(s) sent, $totalSuperseded older notice(s) superseded."
Write-Host "`nOutput written to: $log" -ForegroundColor Cyan
