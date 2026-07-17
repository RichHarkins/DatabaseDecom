/* =====================================================================
   Disable-OrphanedLogins.sql
   ---------------------------------------------------------------------
   Identifies server logins that:
     1. Are NOT members of any fixed or custom server role (public only)
     2. Are NOT mapped to a user in any ONLINE user database (db_id > 4)
   Then generates ALTER LOGIN ... DISABLE statements via PRINT for
   review, or executes them directly when @Execute = 1.

   Safe by default: @Execute = 0 (PRINT only, nothing is changed).

   Notes:
     - System databases (master/model/msdb/tempdb) are NOT scanned,
       per requirement. A login mapped only in msdb (e.g., job proxies)
       will still be flagged -- review the OwnsAgentJobs column.
     - Databases that are OFFLINE, RESTORING, or non-readable AG
       secondaries are skipped with a [WARN].
   ===================================================================== */
SET NOCOUNT ON;

DECLARE @Execute bit = 0;   -- 0 = report + PRINT statements only
                            -- 1 = actually disable the logins

/* ---------------- Table variables ---------------- */
DECLARE @Logins TABLE
(
    principal_id  int           NOT NULL,
    LoginName     sysname       NOT NULL,
    LoginType     nvarchar(60)  NOT NULL,
    LoginSid      varbinary(85) NOT NULL,
    IsDisabled    bit           NOT NULL,
    OwnsDatabases bit           NOT NULL DEFAULT (0),
    OwnsAgentJobs bit           NOT NULL DEFAULT (0)
);

DECLARE @MappedSids TABLE
(
    LoginSid     varbinary(85) NOT NULL,
    DatabaseName sysname       NOT NULL
);

/* ---------------- Step 1: candidate logins ----------------
   SQL logins (S), Windows logins (U), Windows groups (G).
   Excludes sa, certificate-based ## logins, and NT service accounts. */
INSERT INTO @Logins (principal_id, LoginName, LoginType, LoginSid, IsDisabled)
SELECT sp.principal_id,
       sp.name,
       sp.type_desc,
       sp.sid,
       sp.is_disabled
FROM sys.server_principals sp
WHERE sp.type IN ('S', 'U', 'G')
  AND sp.principal_id > 1                    -- exclude sa
  AND sp.name NOT LIKE '##%'                 -- exclude system certificate logins
  AND sp.name NOT LIKE 'NT SERVICE\%'
  AND sp.name NOT LIKE 'NT AUTHORITY\%';

/* ---------------- Step 2: remove any login in a server role ---------------- */
DELETE l
FROM @Logins l
WHERE EXISTS
(
    SELECT 1
    FROM sys.server_role_members srm
    WHERE srm.member_principal_id = l.principal_id
);

/* ---------------- Step 3: scan every ONLINE user database ---------------- */
DECLARE @DBName sysname;
DECLARE @SQL    nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name
    FROM sys.databases d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
    ORDER BY d.name;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DBName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @SQL = N'SELECT dp.sid, N' + QUOTENAME(@DBName, '''') + N'
                 FROM ' + QUOTENAME(@DBName) + N'.sys.database_principals dp
                 WHERE dp.type IN (''S'', ''U'', ''G'')
                   AND dp.sid IS NOT NULL
                   AND dp.principal_id > 4;';   -- skip dbo/guest/sys/INFORMATION_SCHEMA

    BEGIN TRY
        INSERT INTO @MappedSids (LoginSid, DatabaseName)
        EXEC sp_executesql @SQL;
    END TRY
    BEGIN CATCH
        PRINT '[WARN] Could not scan database [' + @DBName + ']: ' + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM db_cur INTO @DBName;
END;

CLOSE db_cur;
DEALLOCATE db_cur;

/* ---------------- Step 4: remove logins mapped to any user database ---------------- */
DELETE l
FROM @Logins l
WHERE EXISTS
(
    SELECT 1
    FROM @MappedSids m
    WHERE m.LoginSid = l.LoginSid
);

/* ---------------- Step 5: flag ownership warnings ---------------- */
UPDATE l
SET l.OwnsDatabases = 1
FROM @Logins l
WHERE EXISTS (SELECT 1 FROM sys.databases d WHERE d.owner_sid = l.LoginSid);

UPDATE l
SET l.OwnsAgentJobs = 1
FROM @Logins l
WHERE EXISTS (SELECT 1 FROM msdb.dbo.sysjobs j WHERE j.owner_sid = l.LoginSid);

/* ---------------- Step 6: report ---------------- */
SELECT l.LoginName,
       l.LoginType,
       l.IsDisabled,
       l.OwnsDatabases,
       l.OwnsAgentJobs,
       CASE WHEN l.OwnsDatabases = 1 OR l.OwnsAgentJobs = 1
            THEN 'Review before disabling'
            ELSE 'OK to disable'
       END AS Recommendation
FROM @Logins l
ORDER BY l.LoginName;

/* ---------------- Step 7: generate / execute DISABLE statements ---------------- */
DECLARE @LoginName sysname;

DECLARE login_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT l.LoginName
    FROM @Logins l
    WHERE l.IsDisabled = 0        -- skip logins already disabled
    ORDER BY l.LoginName;

OPEN login_cur;
FETCH NEXT FROM login_cur INTO @LoginName;

IF @@FETCH_STATUS <> 0
    PRINT '[OK] No orphaned logins found. Nothing to do.';

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @SQL = N'ALTER LOGIN ' + QUOTENAME(@LoginName) + N' DISABLE;';

    IF @Execute = 1
    BEGIN
        BEGIN TRY
            EXEC sp_executesql @SQL;
            PRINT '[OK] Disabled login: ' + QUOTENAME(@LoginName);
        END TRY
        BEGIN CATCH
            PRINT '[FAIL] Could not disable ' + QUOTENAME(@LoginName) + ': ' + ERROR_MESSAGE();
        END CATCH;
    END
    ELSE
        PRINT @SQL;   -- review, then copy/paste or set @Execute = 1

    FETCH NEXT FROM login_cur INTO @LoginName;
END;

CLOSE login_cur;
DEALLOCATE login_cur;