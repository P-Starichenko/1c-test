/*******************************************************************************
 * Phase 1 — Script 2: Cross-Database References
 *
 * Purpose : Find every object that uses three-part naming ([OtherDB].[schema].[object])
 *           to identify inter-database dependencies.  This is critical for setting up
 *           DACPAC project references correctly.
 *
 * Method  : Scans sys.sql_expression_dependencies (compile-time) and supplements
 *           with a text search of module definitions for patterns the dependency
 *           tracker may miss (dynamic SQL, comments, etc.).
 *
 * Target  : SQL Server 2025 Enterprise Edition
 * Run As  : sysadmin or db_owner in each database
 ******************************************************************************/

SET NOCOUNT ON;

PRINT '================================================================';
PRINT '  Script 2 — Cross-Database References';
PRINT '  Run at: ' + CONVERT(VARCHAR(30), GETDATE(), 121);
PRINT '  Server: ' + @@SERVERNAME;
PRINT '================================================================';
PRINT '';

/* ── Temp table to collect results across all databases ────────────────────── */
IF OBJECT_ID('tempdb..#CrossDbRefs') IS NOT NULL DROP TABLE #CrossDbRefs;
CREATE TABLE #CrossDbRefs (
    SourceDatabase      SYSNAME       NOT NULL,
    SourceSchema        SYSNAME       NOT NULL,
    SourceObject        SYSNAME       NOT NULL,
    SourceObjectType    NVARCHAR(60)  NOT NULL,
    ReferencedDatabase  SYSNAME       NULL,
    ReferencedSchema    SYSNAME       NULL,
    ReferencedObject    SYSNAME       NULL,
    ReferenceClass      NVARCHAR(60)  NULL,
    DetectionMethod     VARCHAR(30)   NOT NULL   -- 'sys_dependencies' or 'text_scan'
);

IF OBJECT_ID('tempdb..#TextScanRefs') IS NOT NULL DROP TABLE #TextScanRefs;
CREATE TABLE #TextScanRefs (
    SourceDatabase      SYSNAME       NOT NULL,
    SourceSchema        SYSNAME       NOT NULL,
    SourceObject        SYSNAME       NOT NULL,
    SourceObjectType    NVARCHAR(60)  NOT NULL,
    MatchedFragment     NVARCHAR(4000) NOT NULL
);

/* ── Iterate over every ONLINE user database ──────────────────────────────── */
DECLARE @dbName SYSNAME, @sql NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE state_desc = 'ONLINE'
      AND database_id > 4                       -- skip system dbs
      AND name NOT IN ('distribution','ReportServer','ReportServerTempDB')
    ORDER BY name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @dbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT '  Scanning: ' + @dbName;

    /* ── 2a. sys.sql_expression_dependencies (compile-time cross-db refs) ──── */
    SET @sql = N'
    USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #CrossDbRefs
        (SourceDatabase, SourceSchema, SourceObject, SourceObjectType,
         ReferencedDatabase, ReferencedSchema, ReferencedObject,
         ReferenceClass, DetectionMethod)
    SELECT
        DB_NAME()                              AS SourceDatabase,
        SCHEMA_NAME(o.schema_id)               AS SourceSchema,
        o.name                                 AS SourceObject,
        o.type_desc                            AS SourceObjectType,
        sed.referenced_database_name           AS ReferencedDatabase,
        sed.referenced_schema_name             AS ReferencedSchema,
        sed.referenced_entity_name             AS ReferencedObject,
        sed.referencing_class_desc             AS ReferenceClass,
        ''sys_dependencies''                   AS DetectionMethod
    FROM sys.sql_expression_dependencies sed
    JOIN sys.objects o ON o.object_id = sed.referencing_id
    WHERE sed.referenced_database_name IS NOT NULL
      AND sed.referenced_database_name <> DB_NAME();';

    BEGIN TRY
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        PRINT '    WARNING: Could not scan dependencies in ' + @dbName
              + ' — ' + ERROR_MESSAGE();
    END CATCH;

    /* ── 2b. Text-based scan for three-part names in module definitions ────── */
    SET @sql = N'
    USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #TextScanRefs
        (SourceDatabase, SourceSchema, SourceObject, SourceObjectType, MatchedFragment)
    SELECT
        DB_NAME()                              AS SourceDatabase,
        SCHEMA_NAME(o.schema_id)               AS SourceSchema,
        o.name                                 AS SourceObject,
        o.type_desc                            AS SourceObjectType,
        SUBSTRING(m.definition,
                  PATINDEX(''%[[]%].[[]%].[[]%]%'', m.definition),
                  120)                         AS MatchedFragment
    FROM sys.sql_modules m
    JOIN sys.objects o ON o.object_id = m.object_id
    WHERE m.definition LIKE ''%[[]%].[[]%].[[]%]%''
      -- Exclude self-references
      AND m.definition LIKE ''%[[]%'' + CHAR(93) + ''.[[]%'' + CHAR(93) + ''.[[]%''
    ;';

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

/* ── Output results ────────────────────────────────────────────────────────── */

PRINT '';
PRINT '── Cross-Database References (sys.sql_expression_dependencies) ──';

SELECT
    SourceDatabase,
    SourceSchema + '.' + SourceObject       AS SourceObject,
    SourceObjectType,
    ReferencedDatabase,
    ISNULL(ReferencedSchema,'') + '.' + ReferencedObject AS ReferencedObject,
    ReferenceClass,
    DetectionMethod
FROM #CrossDbRefs
ORDER BY SourceDatabase, ReferencedDatabase, SourceObject;

PRINT '';
PRINT '── Three-Part Name Matches (text scan) ──';

SELECT
    SourceDatabase,
    SourceSchema + '.' + SourceObject       AS SourceObject,
    SourceObjectType,
    MatchedFragment
FROM #TextScanRefs
ORDER BY SourceDatabase, SourceObject;

/* ── Summary: unique database-to-database edges ────────────────────────────── */
PRINT '';
PRINT '── Database Dependency Edges (unique) ──';

SELECT DISTINCT
    SourceDatabase,
    ReferencedDatabase,
    COUNT(*)                                AS ReferenceCount
FROM #CrossDbRefs
GROUP BY SourceDatabase, ReferencedDatabase
ORDER BY SourceDatabase, ReferencedDatabase;

/* ── Cleanup ──────────────────────────────────────────────────────────────── */
DROP TABLE #CrossDbRefs;
DROP TABLE #TextScanRefs;

PRINT '';
PRINT 'Script 2 complete.';
GO
