DATABASE DECOMMISSION SCRIPTS
==============================================================================
PowerShell automation for the standard database decommission process:
confirm no usage -> change ticket + offline -> preserve on Special server ->
14-day wait -> final CommVault backup -> disable & track objects -> daily
DECOM Notice emails with drop commands.

Nothing destructive happens automatically. Objects are DISABLED and recorded
in tracking tables in the DBA database; the actual drops are performed
manually using the commands delivered by the DECOM Notices email.

REQUIREMENTS
------------------------------------------------------------------------------
- Windows PowerShell 5.1+ on a workstation with network access to the
  target SQL instance and the Special server share
- Modules: SqlServer and dbatools - checked and auto-installed
  (CurrentUser scope) by every script via Confirm-DecomModules
- A "DBA" utility database on the target instance for the tracking tables
- An SMTP relay reachable from the target server; the SQL Agent service
  account must be permitted to relay through it (for DECOM Notices -
  Database Mail is NOT required)
- For Backup mode in Step 3: the SQL Server SERVICE ACCOUNT needs modify
  rights (share + NTFS) on the Special server share, because the engine
  writes the backup file, not the account running the script

CONNECTION SETTINGS
------------------------------------------------------------------------------
All database connections use dbatools cmdlets. Confirm-DecomModules sets
the session-wide dbatools configuration so every connection runs with:
    TrustServerCertificate = True
    Encrypt                = False
(Handles the dbatools v2+ default of enforced encryption, which fails
against instances using self-signed certificates.)

CONFIGURATION (00-Decom-Config.ps1)
------------------------------------------------------------------------------
Edit these values before each decom:
  SourceInstance    SQL instance hosting the database to decommission
  DatabaseName      Database being decommissioned
  SpecialServer     "Special" server name
  SpecialSharePath  UNC path on the Special server for archive files
  OutputFolder      Local folder for all section output .txt files
  ChangeTicket      Approved normal change ticket number
  SnowRequest       SNOW request # for service account removal (fill later)
  DbaDatabase       DBA utility database holding the tracking tables
  EmailContact      Email contact stored with tracked objects; receives
                    the DECOM Notice emails
  SmtpServer        SMTP relay for DECOM Notice emails
  SmtpPort          SMTP port (default 25)
  SmtpFrom          From address for DECOM Notice emails
  PollServers       Instances the central forwarder (08) polls for
                    undelivered notices

Backward compatibility: if a config still defines the legacy 'ReminderEmail'
setting instead of 'EmailContact', it is mapped over automatically.

The config also provides:
  Confirm-DecomModules  module check/install + connection settings
  Confirm-DecomTables   creates the four tracking tables if missing and
                        adds the DecomDate column to pre-existing tables
  Logging helpers       every step writes a timestamped .txt file to
                        OutputFolder; log output is UTF-8 throughout,
                        one timestamp per line, trailing padding trimmed

TRACKING TABLES (in the DBA database)
------------------------------------------------------------------------------
  Decom_OfflineDatabases (DatabaseName, DateOffline,  DropCommand,
                          EmailContact, DecomDate)
  Decom_DisabledJobs     (DatabaseName, JobName,      DateDisabled,
                          DropCommand,  EmailContact, DecomDate)
  Decom_DisabledLogins   (DatabaseName, LoginName,    DateDisabled,
                          DropCommand,  EmailContact, DecomDate)
  Decom_SsisPackages     (DatabaseName, PackagePath,  DateInserted,
                          EmailContact, DecomDate)
  Decom_NotificationLog  (NotificationId, AttemptDate, ServerName,
                          EmailContact, SmtpTarget, Status, StatusDetail,
                          NoticeBody, ForwardedDate, ForwardedBy)

Decom_NotificationLog records every notice attempt. When SMTP is
unreachable the DECOM Notices job does NOT send and does NOT stamp
DecomDate - it stores the full HTML body with Status =
'SmtpUnreachable' so the notice is never lost and re-fires once mail
works. Script 08 can relay those notices from a mail-capable server.

Find undelivered notices:
  SELECT AttemptDate, ServerName, EmailContact, StatusDetail, NoticeBody
  FROM DBA.dbo.Decom_NotificationLog
  WHERE Status NOT IN ('Sent','Superseded')
  ORDER BY AttemptDate DESC;

DecomDate is NULL until the decom is completed. Rows appear in DECOM
Notice emails only while DecomDate is NULL and the record is 14+ days
old. Stamping DecomDate (commands provided in the email) stops the
notices and preserves the rows as a permanent audit trail.

RUN ORDER
------------------------------------------------------------------------------
1. 01-Confirm-DatabaseUsage.ps1
   Checks active sessions, index usage stats (with instance start time
   noted, since those stats reset on restart), referencing agent jobs,
   and database users. Ends with a clear verdict: if usage indicators
   are found, attach the output file to the story and refer it back to
   the BA group; otherwise proceed.

2. 02-Take-DatabaseOffline.ps1
   Run only after the normal change is approved. Safety gates: prompts
   for the change ticket and a Y/N confirmation. In order:
     - Records DB state and file inventory
     - DISABLES agent jobs referencing the DB and records them in
       Decom_DisabledJobs (done now so jobs don't fail against the
       offline DB during the 14-day wait; recreate scripts saved to
       OutputFolder\ScriptedJobs\*.sql first)
     - DISABLES logins mapped ONLY to this DB and records them in
       Decom_DisabledLogins (must happen while the DB is still online,
       since users cannot be enumerated on an offline DB)
     - Kills connections and sets the DB OFFLINE
     - Inserts a row into Decom_OfflineDatabases with the drop command
       and email contact (prompts for the contact if blank)

3. 03-Copy-ToSpecialServer.ps1 [-Mode FileCopy|Backup]
   Preserves the database on the Special server while it is offline.
     FileCopy (default): copies the physical MDF/NDF/LDF files to the
       share via admin UNC paths, with SHA256 verification of every
       file. Uses the account running the script.
     Backup: brings the DB online briefly, takes a full COPY_ONLY
       compressed backup with CHECKSUM directly to the share, then
       runs RESTORE VERIFYONLY WITH CHECKSUM (unlimited query timeout)
       and sets the DB offline again. Logs the SQL Server service
       account so share permission issues are easy to diagnose.
   Then begin the 14-day waiting period (end date is logged).

4. 04-Final-CommVaultBackup.ps1
   At the end of the 14 days. Brings the DB online temporarily if
   needed, submits a FULL backup via the CommVault qcommand CLI if
   installed; otherwise logs the exact manual CommCell console steps.
   Edit the CommVault variables at the top of the script (CommServe,
   client, agent, instance, subclient, CLI path).

5. 05-Database-Cleanup.ps1 [-Execute $true]
   Defaults to DRY RUN (report only). With -Execute $true:
     5.1 CommVault removal - logged manual/console step with sign-off
     5.2 Agent jobs: CATCH-UP SWEEP for any referencing jobs created
         or missed since Step 2 (jobs already tracked are skipped);
         same script-out + disable + Decom_DisabledJobs recording
     5.3 SSIS packages: inventories the SSISDB catalog (recorded as
         SSISDB:\Folder\Project\Package) and legacy MSDB storage
         (MSDB:\Package); prompts Y/N per package; confirmed packages
         recorded in Decom_SsisPackages
     5.4 Logins: CATCH-UP SWEEP; if the DB is offline (normal at this
         point) users cannot be enumerated, and the log notes that
         logins were handled in Step 2
   The primary job/login disabling happens in Step 2 at offline time.
   The database itself is NOT dropped by this script.

6. 06-Create-DecomNoticesJob.ps1 [-Execute $true]
   Run ONCE per server (safe to re-run; creates the job only if it
   does not already exist). Creates the "DECOM Notices" SQL Agent job:
     - Runs daily at 7:00 AM
     - Job step uses the SQL Agent POWERSHELL subsystem with .NET
       SqlClient and SmtpClient - NO Database Mail required. Email is
       sent through the SMTP relay in the config (SmtpServer, SmtpPort,
       SmtpFrom); the SQL Agent service account must be allowed to
       relay through it.
     - Scans all four tracking tables for rows 14+ days old with a
       NULL DecomDate
     - Sends one HTML email per EmailContact, subject "DECOM Notice",
       body in this order:
         1. Server name
         2. Logins to be dropped + drop commands
         3. SSIS packages to delete
         4. Disabled jobs to drop + drop commands
         5. Database(s) to drop + drop commands
         6. UPDATE commands to stamp DecomDate on exactly the rows
            listed in this email
         7. BOLD reminder: take a final CommVault backup before
            dropping the database(s)
     - Re-sends daily until DecomDate is stamped
   The SMTP settings are baked into the job step at creation time; if
   they change in the config, delete the "DECOM Notices" job and
   re-run this script to redeploy it.

7. 07-Test-SmtpMail.ps1 -To <address>
   Diagnostic. Run ON THE TARGET SERVER, ideally as the SQL Agent
   service account. Tests DNS, TCP connectivity, reads the SMTP
   banner, and attempts a real send, printing the full exception
   chain plus likely causes. PowerShell 2.0 / 2008R2 safe.

8. 08-Forward-PendingNotices.ps1 [-Servers ...] [-WhatIfOnly]
   Run ON A SERVER WHERE SMTP WORKS (deploy as a daily agent job,
   e.g. 7:30 AM, after the DECOM Notices jobs have run).
   Polls the instances in PollServers for notices recorded as
   SmtpUnreachable/SendFailed and relays them from this host. The
   full HTML body was already stored by the originating server, so
   nothing is recomposed. Only the newest undelivered notice per
   contact is sent (a relay down for a week produces one email, not
   seven); older rows are marked Superseded. Delivered rows are
   stamped with ForwardedDate/ForwardedBy on the SOURCE server so
   the audit trail stays with the server the objects belong to.
   The forwarded email is prefixed with a note explaining which
   server it originated from and why it was relayed.
   Verifies its own SMTP reachability first and aborts if this host
   also cannot send.

COMPLETING A DECOM (manual, driven by the DECOM Notice email)
------------------------------------------------------------------------------
  1. Confirm the Step 4 CommVault final backup completed successfully
  2. Execute the drop commands from the email (logins, jobs, database)
  3. Delete the SSIS packages listed
  4. Confirm the SNOW request for service accounts was completed
  5. Run the UPDATE commands from the email to stamp DecomDate - this
     stops the notices and closes out the audit trail
  6. If the DB was dropped while OFFLINE, delete the orphaned MDF/LDF
     files from disk (paths were logged in Step 2)

TROUBLESHOOTING NOTES (fixes already baked in)
------------------------------------------------------------------------------
- Certificate/encryption connection failures: handled by the session
  TrustServerCertificate/Encrypt settings in Confirm-DecomModules
- Step 3 Backup mode "Test-DbaPath" exception: the pre-flight check is
  skipped (-IgnoreFileChecks); if the backup itself fails, grant the
  SQL Server service account (logged in the output) modify rights on
  the share, or use -Mode FileCopy
- Step 3 "connection forcibly closed" during verify: verification runs
  as a direct RESTORE VERIFYONLY with no query timeout instead of
  dbatools' -Verify
- Garbled log files in Notepad: logging appends UTF-8 consistently
  (older log files created before this fix remain mixed-encoding)

FILES
------------------------------------------------------------------------------
  00-Decom-Config.ps1            Shared config, modules, tables, logging
  01-Confirm-DatabaseUsage.ps1   Step 1 - usage check / BA referral
  02-Take-DatabaseOffline.ps1    Step 2 - offline + tracking insert
  03-Copy-ToSpecialServer.ps1    Step 3 - archive to Special server
  04-Final-CommVaultBackup.ps1   Step 4 - final CommVault full backup
  05-Database-Cleanup.ps1        Step 5 - disable & track objects
  06-Create-DecomNoticesJob.ps1  Step 6 - DECOM Notices agent job
  07-Test-SmtpMail.ps1           SMTP diagnostic (run on target server)
  08-Forward-PendingNotices.ps1  Central relay for undelivered notices
  README.txt                     This file

