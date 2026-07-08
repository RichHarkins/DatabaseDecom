DATABASE DECOMMISSION SCRIPTS - RUN ORDER
==========================================

0. Edit 00-Decom-Config.ps1 first:
   - SourceInstance, DatabaseName, SpecialServer/SpecialSharePath,
     OutputFolder, ChangeTicket.
   All scripts dot-source this file, check for the SqlServer and dbatools
   modules, and install them (CurrentUser scope) if missing.
   Every step writes a timestamped .txt file to OutputFolder.

1. 01-Confirm-DatabaseUsage.ps1
   Checks active sessions, index usage stats, agent jobs, and DB users.
   If usage is found -> attach the output file to the story and refer
   back to the BA group.

2. 02-Take-DatabaseOffline.ps1
   Run only after the normal change is approved. Prompts for the ticket
   number, records DB state/files, kills connections, sets OFFLINE.

3. 03-Copy-ToSpecialServer.ps1 [-Mode FileCopy|Backup]
   FileCopy (default): copies MDF/NDF/LDF to the Special share with
   SHA256 verification (true "offline configuration").
   Backup: briefly brings DB online, full COPY_ONLY backup w/ checksum
   + verify to the Special share, sets offline again.
   Then wait 14 days.

4. 04-Final-CommVaultBackup.ps1
   Submits a full backup via CommVault qcommand CLI if installed;
   otherwise logs the exact manual CommCell steps. Edit the CommVault
   variables at the top for your CommServe.

5. 05-Database-Cleanup.ps1 [-Execute $true]
   Defaults to DRY RUN. Produces four output files:
     5-1 CommVault removal record
     5-2 Jobs/SSIS: scripts out every referencing agent job to .sql
         files BEFORE removal; inventories SSISDB and MSDB packages
     5-3 Accounts: finds logins exclusive to the DB and generates the
         SNOW request text; removes them only with -Execute $true
     5-4 Drop: requires typing the DB name as final confirmation;
         records physical file paths for post-drop disk cleanup
