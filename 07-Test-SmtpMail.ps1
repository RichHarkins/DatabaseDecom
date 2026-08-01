<#
.SYNOPSIS
    STEP 7 (diagnostic) - Test SMTP mail delivery for the DECOM Notices job.
    Run this ON THE TARGET SERVER (e.g. phx00514), ideally as the SQL Agent
    service account, since that is the identity the job sends mail as.

    Performs, in order:
      1. DNS resolution of the SMTP server
      2. TCP connectivity test to the SMTP port
      3. Reads the SMTP banner (proves an SMTP service is answering)
      4. Sends a test message exactly the way the DECOM Notices job does,
         printing the FULL exception chain on failure

    Works on down-level hosts (Windows 2008R2 / PowerShell 2.0): no modules,
    no Test-NetConnection, .NET types only.

.EXAMPLE
    .\07-Test-SmtpMail.ps1 -To rich@yourcompany.com
#>
param(
    [Parameter(Mandatory)][string]$To,
    [string]$SmtpServer,
    [int]$SmtpPort,
    [string]$From
)

. "$PSScriptRoot\00-Decom-Config.ps1"

if (-not $SmtpServer) { $SmtpServer = $Global:DecomConfig.SmtpServer }
if (-not $SmtpPort)   { $SmtpPort   = $Global:DecomConfig.SmtpPort }
if (-not $From)       { $From       = $Global:DecomConfig.SmtpFrom }

Write-Host "SMTP diagnostic: $SmtpServer`:$SmtpPort | From: $From | To: $To" -ForegroundColor Cyan
Write-Host "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host ""

# Enable TLS 1.2 if this .NET build supports it (harmless if unused)
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Write-Host "[OK]   TLS 1.2 enabled for this session."
} catch {
    Write-Host "[WARN] This .NET build does not support TLS 1.2. Plain port-25 relay will still work;" 
    Write-Host "       STARTTLS-required relays will NOT. (.NET 4.5+ and SchUseStrongCrypto fix this.)"
}

# --- 1. DNS ---------------------------------------------------------------------
try {
    $ips = [System.Net.Dns]::GetHostAddresses($SmtpServer) | ForEach-Object { $_.IPAddressToString }
    Write-Host "[OK]   DNS: $SmtpServer -> $($ips -join ', ')"
}
catch {
    Write-Host "[FAIL] DNS resolution failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "       Check the SmtpServer name in 00-Decom-Config.ps1."
    return
}

# --- 2. TCP connect -------------------------------------------------------------
$tcp = New-Object System.Net.Sockets.TcpClient
try {
    $async = $tcp.BeginConnect($SmtpServer, $SmtpPort, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne(5000)) { throw "Connection timed out after 5 seconds." }
    $tcp.EndConnect($async)
    Write-Host "[OK]   TCP: connected to $SmtpServer`:$SmtpPort"
}
catch {
    Write-Host "[FAIL] TCP connect failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "       Likely a firewall block between this server and the relay, or wrong port."
    $tcp.Close()
    return
}

# --- 3. SMTP banner -------------------------------------------------------------
try {
    $stream = $tcp.GetStream()
    $stream.ReadTimeout = 5000
    $buf = New-Object byte[] 1024
    $n = $stream.Read($buf, 0, $buf.Length)
    $banner = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim()
    Write-Host "[OK]   Banner: $banner"
    if ($banner -notmatch '^220') {
        Write-Host "[WARN] Expected a 220 greeting; the service on this port may not be SMTP."
    }
}
catch {
    Write-Host "[WARN] Connected but could not read an SMTP banner: $($_.Exception.Message)"
}
finally { $tcp.Close() }

# --- 4. Test send ---------------------------------------------------------------
Write-Host ""
Write-Host "Sending test message..."
$msg = New-Object System.Net.Mail.MailMessage
$msg.From = $From
$msg.To.Add($To)
$msg.Subject = "DECOM Notices SMTP test from $env:COMPUTERNAME"
$msg.Body = "<p>Test message from <b>$env:COMPUTERNAME</b> at $(Get-Date). If you received this, the DECOM Notices job can send mail from this server.</p>"
$msg.IsBodyHtml = $true
$smtp = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)

try {
    $smtp.Send($msg)
    Write-Host "[OK]   Test message sent successfully to $To." -ForegroundColor Green
    Write-Host "       The DECOM Notices job should work as configured."
}
catch {
    Write-Host "[FAIL] Send failed. Full exception chain:" -ForegroundColor Red
    $ex = $_.Exception
    $i = 0
    while ($ex -ne $null) {
        Write-Host ("       [{0}] {1}: {2}" -f $i, $ex.GetType().Name, $ex.Message) -ForegroundColor Red
        $ex = $ex.InnerException
        $i++
    }
    Write-Host ""
    Write-Host "Common causes by inner exception:"
    Write-Host " - 'Unable to connect' / SocketException     : firewall or wrong server/port"
    Write-Host " - '5.7.1 ... unable to relay'               : relay not permitted for this host/IP -"
    Write-Host "                                               ask the mail team to allow relay from this"
    Write-Host "                                               server's IP (and the From address)"
    Write-Host " - 'must issue a STARTTLS command first'     : relay requires TLS; on 2008R2 this needs"
    Write-Host "                                               .NET 4.5+ with TLS 1.2 enabled, or use a"
    Write-Host "                                               relay/port that accepts plain SMTP"
    Write-Host " - '5.7.60 ... sender address'               : From address rejected - adjust SmtpFrom"
}
finally { $msg.Dispose() }

