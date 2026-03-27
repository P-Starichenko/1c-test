/*******************************************************************************
 * Phase 1 — Script 4: Instance-Level Objects
 *
 * Purpose : Document server-level objects that databases depend on but live
 *           outside any single database. These need separate handling during
 *           DACPAC deployment (pre-deployment scripts or a separate project).
 *
 * Covers  : Logins, server roles, credentials, linked servers (summary),
 *           endpoints, server triggers, server audit specs, mail profiles.
 *
 * Target  : SQL Server 2025 Enterprise Edition
 * Run As  : sysadmin or securityadmin + VIEW SERVER STATE + VIEW ANY DEFINITION
 ******************************************************************************/

SET NOCOUNT ON;

PRINT '================================================================';
PRINT '  Script 4 — Instance-Level Objects';
PRINT '  Run at: ' + CONVERT(VARCHAR(30), GETDATE(), 121);
PRINT '  Server: ' + @@SERVERNAME;
PRINT '================================================================';
PRINT '';

/* ── 4a. Server logins ─────────────────────────────────────────────────────── */
PRINT '── Server Logins ──';

SELECT
    sp.principal_id,
    sp.name                                 AS LoginName,
    sp.type_desc                            AS LoginType,
    sp.default_database_name                AS DefaultDatabase,
    sp.default_language_name                AS DefaultLanguage,
    sp.is_disabled                          AS IsDisabled,
    sp.create_date                          AS CreatedDate,
    sp.modify_date                          AS ModifiedDate,
    LOGINPROPERTY(sp.name, 'IsLocked')      AS IsLocked,
    LOGINPROPERTY(sp.name, 'IsExpired')     AS IsExpired,
    LOGINPROPERTY(sp.name, 'PasswordLastSetTime') AS PasswordLastSet
FROM sys.server_principals sp
WHERE sp.type IN ('S','U','G','C','K')     -- SQL, Windows user/group, certificate, asymmetric key
  AND sp.name NOT LIKE '##%'               -- exclude internal certs
ORDER BY sp.type_desc, sp.name;

/* ── 4b. Server role memberships ───────────────────────────────────────────── */
PRINT '';
PRINT '── Server Role Memberships ──';

SELECT
    r.name                                  AS ServerRole,
    m.name                                  AS MemberLogin,
    m.type_desc                             AS MemberType
FROM sys.server_role_members srm
JOIN sys.server_principals r ON r.principal_id = srm.role_principal_id
JOIN sys.server_principals m ON m.principal_id = srm.member_principal_id
ORDER BY r.name, m.name;

/* ── 4c. User-defined server roles (SQL 2012+) ────────────────────────────── */
PRINT '';
PRINT '── User-Defined Server Roles ──';

SELECT
    sp.name                                 AS RoleName,
    sp.create_date,
    sp.modify_date,
    sp.owning_principal_id,
    SUSER_SNAME(sp.owning_principal_id)     AS [Owner]
FROM sys.server_principals sp
WHERE sp.type = 'R'
  AND sp.is_fixed_role = 0
ORDER BY sp.name;

/* ── 4d. Credentials ──────────────────────────────────────────────────────── */
PRINT '';
PRINT '── Credentials ──';

SELECT
    credential_id,
    name                                    AS CredentialName,
    credential_identity                     AS CredentialIdentity,
    create_date,
    modify_date
FROM sys.credentials
ORDER BY name;

/* ── 4e. Server-level endpoints ────────────────────────────────────────────── */
PRINT '';
PRINT '── Endpoints ──';

SELECT
    endpoint_id,
    name                                    AS EndpointName,
    protocol_desc                           AS Protocol,
    type_desc                               AS EndpointType,
    state_desc                              AS [State],
    port                                    -- NULL for non-TCP
FROM sys.endpoints
WHERE endpoint_id >= 65536                   -- exclude system endpoints
ORDER BY name;

/* ── 4f. Server-level triggers ─────────────────────────────────────────────── */
PRINT '';
PRINT '── Server Triggers ──';

SELECT
    t.name                                  AS TriggerName,
    t.type_desc                             AS TriggerType,
    t.is_disabled,
    t.create_date,
    t.modify_date,
    te.type_desc                            AS EventType
FROM sys.server_triggers t
LEFT JOIN sys.server_trigger_events te ON te.object_id = t.object_id
ORDER BY t.name;

/* ── 4g. Server audits and audit specifications ────────────────────────────── */
PRINT '';
PRINT '── Server Audits ──';

SELECT
    a.audit_id,
    a.name                                  AS AuditName,
    a.status_desc                           AS [Status],
    a.type_desc                             AS AuditType,
    a.on_failure_desc                       AS OnFailure,
    a.queue_delay,
    a.create_date,
    a.modify_date
FROM sys.server_audits a
ORDER BY a.name;

PRINT '';
PRINT '── Server Audit Specifications ──';

SELECT
    sas.name                                AS SpecName,
    sa.name                                 AS AuditName,
    sas.is_state_enabled,
    sas.create_date,
    sas.modify_date
FROM sys.server_audit_specifications sas
JOIN sys.server_audits sa ON sa.audit_guid = sas.audit_guid
ORDER BY sas.name;

/* ── 4h. Database Mail profiles (via msdb) ─────────────────────────────────── */
PRINT '';
PRINT '── Database Mail Profiles ──';

IF EXISTS (SELECT 1 FROM msdb.sys.objects WHERE name = 'sysmail_profile' AND type = 'U')
BEGIN
    EXEC sp_executesql N'
    SELECT
        p.profile_id,
        p.name                              AS ProfileName,
        p.description,
        a.name                              AS AccountName,
        a.email_address,
        a.display_name,
        s.servername                         AS MailServer,
        s.port                               AS MailPort,
        s.enable_ssl
    FROM msdb.dbo.sysmail_profile p
    LEFT JOIN msdb.dbo.sysmail_profileaccount pa ON pa.profile_id = p.profile_id
    LEFT JOIN msdb.dbo.sysmail_account a ON a.account_id = pa.account_id
    LEFT JOIN msdb.dbo.sysmail_server s ON s.account_id = a.account_id
    ORDER BY p.name, pa.sequence_number;';
END
ELSE
    PRINT '  Database Mail not configured.';

/* ── 4i. SQL Agent jobs (summary) ──────────────────────────────────────────── */
PRINT '';
PRINT '── SQL Agent Jobs ──';

IF EXISTS (SELECT 1 FROM msdb.sys.objects WHERE name = 'sysjobs' AND type = 'U')
BEGIN
    EXEC sp_executesql N'
    SELECT
        j.job_id,
        j.name                              AS JobName,
        SUSER_SNAME(j.owner_sid)            AS [Owner],
        j.enabled,
        j.date_created,
        j.date_modified,
        c.name                              AS CategoryName
    FROM msdb.dbo.sysjobs j
    LEFT JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
    ORDER BY j.name;';
END
ELSE
    PRINT '  SQL Agent not available.';

/* ── 4j. Login-to-database user mapping ────────────────────────────────────── */
PRINT '';
PRINT '── Login to Database User Mapping ──';

IF OBJECT_ID('tempdb..#LoginMapping') IS NOT NULL DROP TABLE #LoginMapping;
CREATE TABLE #LoginMapping (
    LoginName       SYSNAME NOT NULL,
    DatabaseName    SYSNAME NOT NULL,
    DatabaseUser    SYSNAME NOT NULL,
    UserType        NVARCHAR(60) NOT NULL
);

DECLARE @dbName SYSNAME, @sql NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE state_desc = 'ONLINE'
      AND database_id > 4
    ORDER BY name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @dbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
    USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #LoginMapping (LoginName, DatabaseName, DatabaseUser, UserType)
    SELECT
        ISNULL(SUSER_SNAME(dp.sid), ''** orphaned **'') AS LoginName,
        DB_NAME()                                        AS DatabaseName,
        dp.name                                          AS DatabaseUser,
        dp.type_desc                                     AS UserType
    FROM sys.database_principals dp
    WHERE dp.type IN (''S'',''U'',''G'',''C'',''K'')
      AND dp.sid IS NOT NULL
      AND dp.name NOT IN (''dbo'',''guest'',''INFORMATION_SCHEMA'',''sys'');';

    BEGIN TRY
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        PRINT '    WARNING: ' + @dbName + ' — ' + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @dbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT * FROM #LoginMapping ORDER BY LoginName, DatabaseName;

/* ── Orphaned users (login missing at server level) ────────────────────────── */
PRINT '';
PRINT '── Orphaned Database Users (no matching server login) ──';

SELECT *
FROM #LoginMapping
WHERE LoginName = '** orphaned **'
ORDER BY DatabaseName, DatabaseUser;

DROP TABLE #LoginMapping;

PRINT '';
PRINT 'Script 4 complete.';
GO
