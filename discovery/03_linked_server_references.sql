/*******************************************************************************
 * Phase 1 — Script 3: Linked Server & Four-Part Name References
 *
 * Purpose : Discover all linked servers configured on the instance and find
 *           every module that uses four-part naming ([LinkedServer].[DB].[Schema].[Object]).
 *           These references require special handling in DACPAC projects.
 *
 * Target  : SQL Server 2025 Enterprise Edition
 * Run As  : sysadmin or setupadmin + VIEW DEFINITION on user databases
 ******************************************************************************/

SET NOCOUNT ON;

PRINT '================================================================';
PRINT '  Script 3 — Linked Server & Four-Part Name References';
PRINT '  Run at: ' + CONVERT(VARCHAR(30), GETDATE(), 121);
PRINT '  Server: ' + @@SERVERNAME;
PRINT '================================================================';
PRINT '';

/* ── 3a. Linked server configuration ──────────────────────────────────────── */
PRINT '── Linked Servers ──';

SELECT
    s.server_id,
    s.name                                   AS LinkedServerName,
    s.product,
    s.provider,
    s.data_source                            AS DataSource,
    s.catalog                                AS DefaultCatalog,
    s.provider_string,
    s.is_linked,
    s.is_remote_login_enabled,
    s.is_data_access_enabled,
    s.is_rpc_out_enabled,
    s.modify_date
FROM sys.servers s
WHERE s.server_id > 0   -- exclude local server (id = 0)
ORDER BY s.name;

/* ── 3b. Linked server login mappings ─────────────────────────────────────── */
PRINT '';
PRINT '── Linked Server Login Mappings ──';

SELECT
    s.name                                   AS LinkedServerName,
    ll.remote_name                           AS RemoteLogin,
    SUSER_SNAME(ll.local_principal_id)       AS LocalPrincipal,
    ll.uses_self_credential                  AS UsesSelf,
    ll.modify_date
FROM sys.linked_logins ll
JOIN sys.servers s ON s.server_id = ll.server_id
WHERE s.server_id > 0
ORDER BY s.name;

/* ── 3c. Four-part name references in all user databases ──────────────────── */
IF OBJECT_ID('tempdb..#FourPartRefs') IS NOT NULL DROP TABLE #FourPartRefs;
CREATE TABLE #FourPartRefs (
    SourceDatabase       SYSNAME       NOT NULL,
    SourceSchema         SYSNAME       NOT NULL,
    SourceObject         SYSNAME       NOT NULL,
    SourceObjectType     NVARCHAR(60)  NOT NULL,
    ReferencedServer     SYSNAME       NULL,
    ReferencedDatabase   SYSNAME       NULL,
    ReferencedSchema     SYSNAME       NULL,
    ReferencedObject     SYSNAME       NULL,
    DetectionMethod      VARCHAR(30)   NOT NULL
);

IF OBJECT_ID('tempdb..#FourPartText') IS NOT NULL DROP TABLE #FourPartText;
CREATE TABLE #FourPartText (
    SourceDatabase       SYSNAME       NOT NULL,
    SourceSchema         SYSNAME       NOT NULL,
    SourceObject         SYSNAME       NOT NULL,
    SourceObjectType     NVARCHAR(60)  NOT NULL,
    MatchedFragment      NVARCHAR(4000) NOT NULL
);

DECLARE @dbName SYSNAME, @sql NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE state_desc = 'ONLINE'
      AND database_id > 4
      AND name NOT IN ('distribution','ReportServer','ReportServerTempDB')
    ORDER BY name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @dbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT '  Scanning: ' + @dbName;

    /* ── sys.sql_expression_dependencies with referenced_server_name ────────── */
    SET @sql = N'
    USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #FourPartRefs
        (SourceDatabase, SourceSchema, SourceObject, SourceObjectType,
         ReferencedServer, ReferencedDatabase, ReferencedSchema, ReferencedObject,
         DetectionMethod)
    SELECT
        DB_NAME()                              AS SourceDatabase,
        SCHEMA_NAME(o.schema_id)               AS SourceSchema,
        o.name                                 AS SourceObject,
        o.type_desc                            AS SourceObjectType,
        sed.referenced_server_name             AS ReferencedServer,
        sed.referenced_database_name           AS ReferencedDatabase,
        sed.referenced_schema_name             AS ReferencedSchema,
        sed.referenced_entity_name             AS ReferencedObject,
        ''sys_dependencies''                   AS DetectionMethod
    FROM sys.sql_expression_dependencies sed
    JOIN sys.objects o ON o.object_id = sed.referencing_id
    WHERE sed.referenced_server_name IS NOT NULL;';

    BEGIN TRY
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        PRINT '    WARNING: Could not scan dependencies in ' + @dbName
              + ' — ' + ERROR_MESSAGE();
    END CATCH;

    /* ── Text scan: look for four-part patterns ────────────────────────────── */
    SET @sql = N'
    USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #FourPartText
        (SourceDatabase, SourceSchema, SourceObject, SourceObjectType, MatchedFragment)
    SELECT
        DB_NAME()                              AS SourceDatabase,
        SCHEMA_NAME(o.schema_id)               AS SourceSchema,
        o.name                                 AS SourceObject,
        o.type_desc                            AS SourceObjectType,
        SUBSTRING(m.definition,
                  PATINDEX(''%[[]%].[[]%].[[]%].[[]%]%'', m.definition),
                  160)                         AS MatchedFragment
    FROM sys.sql_modules m
    JOIN sys.objects o ON o.object_id = m.object_id
    WHERE m.definition LIKE ''%[[]%].[[]%].[[]%].[[]%]%'';';

    BEGIN TRY
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        PRINT '    WARNING: Could not text-scan modules in ' + @dbName
              + ' — ' + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @dbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

/* ── Output ────────────────────────────────────────────────────────────────── */

PRINT '';
PRINT '── Four-Part Name References (sys.sql_expression_dependencies) ──';

SELECT
    SourceDatabase,
    SourceSchema + '.' + SourceObject       AS SourceObject,
    SourceObjectType,
    ReferencedServer,
    ReferencedDatabase,
    ISNULL(ReferencedSchema,'') + '.' + ReferencedObject AS ReferencedObject,
    DetectionMethod
FROM #FourPartRefs
ORDER BY SourceDatabase, ReferencedServer, ReferencedDatabase;

PRINT '';
PRINT '── Four-Part Name Text Matches ──';

SELECT
    SourceDatabase,
    SourceSchema + '.' + SourceObject       AS SourceObject,
    SourceObjectType,
    MatchedFragment
FROM #FourPartText
ORDER BY SourceDatabase, SourceObject;

/* ── Summary ──────────────────────────────────────────────────────────────── */
PRINT '';
PRINT '── Linked Server Usage Summary ──';

SELECT
    ReferencedServer,
    ReferencedDatabase,
    COUNT(*) AS ReferenceCount
FROM #FourPartRefs
GROUP BY ReferencedServer, ReferencedDatabase
ORDER BY ReferencedServer, ReferencedDatabase;

DROP TABLE #FourPartRefs;
DROP TABLE #FourPartText;

PRINT '';
PRINT 'Script 3 complete.';
GO
