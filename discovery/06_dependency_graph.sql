/*******************************************************************************
 * Phase 1 — Script 6: Database Dependency Graph & Object Counts
 *
 * Purpose : Build a consolidated dependency map showing which databases
 *           reference which others, plus per-database object counts to help
 *           estimate DACPAC project size and complexity.
 *
 * Target  : SQL Server 2025 Enterprise Edition
 * Run As  : sysadmin or VIEW DEFINITION on all databases
 ******************************************************************************/

SET NOCOUNT ON;

PRINT '================================================================';
PRINT '  Script 6 — Database Dependency Graph & Object Counts';
PRINT '  Run at: ' + CONVERT(VARCHAR(30), GETDATE(), 121);
PRINT '  Server: ' + @@SERVERNAME;
PRINT '================================================================';
PRINT '';

/* ══════════════════════════════════════════════════════════════════════════════
   PART A: Cross-database dependency map (consolidated from scripts 2 & 3)
   ══════════════════════════════════════════════════════════════════════════════ */

IF OBJECT_ID('tempdb..#DepEdges') IS NOT NULL DROP TABLE #DepEdges;
CREATE TABLE #DepEdges (
    SourceDatabase      SYSNAME NOT NULL,
    ReferencedServer    SYSNAME NULL,       -- NULL = local server
    ReferencedDatabase  SYSNAME NOT NULL,
    ReferenceCount      INT     NOT NULL DEFAULT 0
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
    SET @sql = N'
    USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #DepEdges (SourceDatabase, ReferencedServer, ReferencedDatabase, ReferenceCount)
    SELECT
        DB_NAME(),
        sed.referenced_server_name,
        sed.referenced_database_name,
        COUNT(*)
    FROM sys.sql_expression_dependencies sed
    JOIN sys.objects o ON o.object_id = sed.referencing_id
    WHERE sed.referenced_database_name IS NOT NULL
      AND sed.referenced_database_name <> DB_NAME()
    GROUP BY sed.referenced_server_name, sed.referenced_database_name;';

    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '  WARNING: ' + @dbName + ' — ' + ERROR_MESSAGE(); END CATCH;

    /* Also pick up synonyms that target other databases */
    SET @sql = N'
    USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #DepEdges (SourceDatabase, ReferencedServer, ReferencedDatabase, ReferenceCount)
    SELECT
        DB_NAME(),
        NULL,
        PARSENAME(s.base_object_name, 3),
        COUNT(*)
    FROM sys.synonyms s
    WHERE PARSENAME(s.base_object_name, 3) IS NOT NULL
      AND PARSENAME(s.base_object_name, 3) <> DB_NAME()
    GROUP BY PARSENAME(s.base_object_name, 3);';

    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '  WARNING: Synonym scan ' + @dbName + ' — ' + ERROR_MESSAGE(); END CATCH;

    FETCH NEXT FROM db_cursor INTO @dbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

/* ── Dependency edges (aggregated) ─────────────────────────────────────────── */
PRINT '';
PRINT '── Database Dependency Edges ──';
PRINT '   (SourceDB) --[ref_count]--> (TargetDB)';
PRINT '   ReferencedServer = NULL means local server';
PRINT '';

SELECT
    SourceDatabase,
    ISNULL(ReferencedServer, '(local)')     AS ReferencedServer,
    ReferencedDatabase,
    SUM(ReferenceCount)                     AS TotalReferences
FROM #DepEdges
GROUP BY SourceDatabase, ReferencedServer, ReferencedDatabase
ORDER BY SourceDatabase, ReferencedServer, ReferencedDatabase;

/* ── Databases with NO external dependencies (leaf nodes) ──────────────────── */
PRINT '';
PRINT '── Isolated Databases (no cross-db references outgoing) ──';

SELECT d.name AS DatabaseName
FROM sys.databases d
WHERE d.state_desc = 'ONLINE'
  AND d.database_id > 4
  AND d.name NOT IN ('distribution','ReportServer','ReportServerTempDB')
  AND d.name NOT IN (SELECT DISTINCT SourceDatabase FROM #DepEdges)
ORDER BY d.name;

/* ── Databases referenced by others but never referencing others themselves ── */
PRINT '';
PRINT '── Databases Referenced By Others (pure targets / shared DBs) ──';

SELECT DISTINCT ReferencedDatabase
FROM #DepEdges
WHERE ReferencedServer IS NULL              -- local only
  AND ReferencedDatabase NOT IN (SELECT DISTINCT SourceDatabase FROM #DepEdges)
ORDER BY ReferencedDatabase;

/* ── Suggested DACPAC build order (dependencies first) ─────────────────────── */
PRINT '';
PRINT '── Suggested Build Order ──';
PRINT '   (databases with no outgoing refs first, then those that depend on them)';
PRINT '';

;WITH AllDbs AS (
    SELECT name AS DatabaseName
    FROM sys.databases
    WHERE state_desc = 'ONLINE'
      AND database_id > 4
      AND name NOT IN ('distribution','ReportServer','ReportServerTempDB')
),
OutDegree AS (
    SELECT SourceDatabase, COUNT(DISTINCT ReferencedDatabase) AS OutDeg
    FROM #DepEdges
    WHERE ReferencedServer IS NULL
    GROUP BY SourceDatabase
),
InDegree AS (
    SELECT ReferencedDatabase, COUNT(DISTINCT SourceDatabase) AS InDeg
    FROM #DepEdges
    WHERE ReferencedServer IS NULL
    GROUP BY ReferencedDatabase
)
SELECT
    a.DatabaseName,
    ISNULL(od.OutDeg, 0)    AS DependsOnOtherDBs,
    ISNULL(id.InDeg, 0)     AS ReferencedByOtherDBs,
    CASE
        WHEN ISNULL(od.OutDeg,0) = 0 AND ISNULL(id.InDeg,0) = 0 THEN 'Independent'
        WHEN ISNULL(od.OutDeg,0) = 0 AND ISNULL(id.InDeg,0) > 0 THEN 'Build FIRST (referenced by others)'
        WHEN ISNULL(od.OutDeg,0) > 0 AND ISNULL(id.InDeg,0) = 0 THEN 'Build LAST (depends on others)'
        ELSE 'Mutual dependency — review manually'
    END AS BuildOrderHint
FROM AllDbs a
LEFT JOIN OutDegree od ON od.SourceDatabase = a.DatabaseName
LEFT JOIN InDegree  id ON id.ReferencedDatabase = a.DatabaseName
ORDER BY ISNULL(od.OutDeg, 0), ISNULL(id.InDeg, 0) DESC, a.DatabaseName;

DROP TABLE #DepEdges;

/* ══════════════════════════════════════════════════════════════════════════════
   PART B: Object counts per database (for project sizing)
   ══════════════════════════════════════════════════════════════════════════════ */

PRINT '';
PRINT '── Object Counts Per Database ──';

IF OBJECT_ID('tempdb..#ObjCounts') IS NOT NULL DROP TABLE #ObjCounts;
CREATE TABLE #ObjCounts (
    DatabaseName    SYSNAME       NOT NULL,
    ObjectType      NVARCHAR(60)  NOT NULL,
    ObjectCount     INT           NOT NULL
);

DECLARE db_cursor2 CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE state_desc = 'ONLINE'
      AND database_id > 4
      AND name NOT IN ('distribution','ReportServer','ReportServerTempDB')
    ORDER BY name;

OPEN db_cursor2;
FETCH NEXT FROM db_cursor2 INTO @dbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
    USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #ObjCounts (DatabaseName, ObjectType, ObjectCount)
    SELECT
        DB_NAME(),
        type_desc,
        COUNT(*)
    FROM sys.objects
    WHERE is_ms_shipped = 0
    GROUP BY type_desc;';

    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '  WARNING: ' + @dbName + ' — ' + ERROR_MESSAGE(); END CATCH;

    FETCH NEXT FROM db_cursor2 INTO @dbName;
END

CLOSE db_cursor2;
DEALLOCATE db_cursor2;

/* Detail */
SELECT
    DatabaseName,
    ObjectType,
    ObjectCount
FROM #ObjCounts
ORDER BY DatabaseName, ObjectType;

/* Per-database totals */
PRINT '';
PRINT '── Total Objects Per Database ──';

SELECT
    DatabaseName,
    SUM(ObjectCount) AS TotalObjects
FROM #ObjCounts
GROUP BY DatabaseName
ORDER BY TotalObjects DESC;

/* Server-wide total by type */
PRINT '';
PRINT '── Server-Wide Object Totals By Type ──';

SELECT
    ObjectType,
    SUM(ObjectCount) AS TotalAcrossAllDBs
FROM #ObjCounts
GROUP BY ObjectType
ORDER BY TotalAcrossAllDBs DESC;

DROP TABLE #ObjCounts;

PRINT '';
PRINT 'Script 6 complete.';
GO
