/*******************************************************************************
 * Phase 1 — Script 5: Special Features & SQL Server 2025 Capabilities
 *
 * Purpose : Discover CLR assemblies, Service Broker objects, external data
 *           sources, external tables, Always Encrypted columns, temporal tables,
 *           graph tables, JSON columns, memory-optimized objects, and other
 *           features that require special DACPAC configuration or workarounds.
 *
 * Target  : SQL Server 2025 Enterprise Edition
 * Run As  : sysadmin or VIEW DEFINITION on all databases
 ******************************************************************************/

SET NOCOUNT ON;

PRINT '================================================================';
PRINT '  Script 5 — Special Features & SQL Server 2025 Capabilities';
PRINT '  Run at: ' + CONVERT(VARCHAR(30), GETDATE(), 121);
PRINT '  Server: ' + @@SERVERNAME;
PRINT '================================================================';
PRINT '';

/* ── Temp tables for cross-database collection ─────────────────────────────── */
IF OBJECT_ID('tempdb..#CLRAssemblies')     IS NOT NULL DROP TABLE #CLRAssemblies;
IF OBJECT_ID('tempdb..#ServiceBroker')     IS NOT NULL DROP TABLE #ServiceBroker;
IF OBJECT_ID('tempdb..#ExternalDS')        IS NOT NULL DROP TABLE #ExternalDS;
IF OBJECT_ID('tempdb..#ExternalTables')    IS NOT NULL DROP TABLE #ExternalTables;
IF OBJECT_ID('tempdb..#TemporalTables')    IS NOT NULL DROP TABLE #TemporalTables;
IF OBJECT_ID('tempdb..#MemOptTables')      IS NOT NULL DROP TABLE #MemOptTables;
IF OBJECT_ID('tempdb..#EncryptedCols')     IS NOT NULL DROP TABLE #EncryptedCols;
IF OBJECT_ID('tempdb..#GraphTables')       IS NOT NULL DROP TABLE #GraphTables;
IF OBJECT_ID('tempdb..#XMLSchemaCol')      IS NOT NULL DROP TABLE #XMLSchemaCol;
IF OBJECT_ID('tempdb..#PartitionedObjs')   IS NOT NULL DROP TABLE #PartitionedObjs;
IF OBJECT_ID('tempdb..#Synonyms')          IS NOT NULL DROP TABLE #Synonyms;
IF OBJECT_ID('tempdb..#Sequences')         IS NOT NULL DROP TABLE #Sequences;
IF OBJECT_ID('tempdb..#CDC')               IS NOT NULL DROP TABLE #CDC;

CREATE TABLE #CLRAssemblies (
    DatabaseName SYSNAME, AssemblyName SYSNAME, ClrName NVARCHAR(4000),
    PermissionSet NVARCHAR(60), IsVisible BIT, CreateDate DATETIME
);
CREATE TABLE #ServiceBroker (
    DatabaseName SYSNAME, ObjectType VARCHAR(30), ObjectName SYSNAME, Detail NVARCHAR(500)
);
CREATE TABLE #ExternalDS (
    DatabaseName SYSNAME, DataSourceName SYSNAME, TypeDesc NVARCHAR(256),
    Location NVARCHAR(4000), ResourceManagerLocation NVARCHAR(4000)
);
CREATE TABLE #ExternalTables (
    DatabaseName SYSNAME, SchemaName SYSNAME, TableName SYSNAME,
    DataSourceName SYSNAME
);
CREATE TABLE #TemporalTables (
    DatabaseName SYSNAME, SchemaName SYSNAME, TableName SYSNAME,
    HistorySchema SYSNAME NULL, HistoryTable SYSNAME NULL, RetentionPeriod NVARCHAR(100)
);
CREATE TABLE #MemOptTables (
    DatabaseName SYSNAME, SchemaName SYSNAME, TableName SYSNAME,
    DurabilityDesc NVARCHAR(60)
);
CREATE TABLE #EncryptedCols (
    DatabaseName SYSNAME, SchemaName SYSNAME, TableName SYSNAME,
    ColumnName SYSNAME, EncryptionType NVARCHAR(60)
);
CREATE TABLE #GraphTables (
    DatabaseName SYSNAME, SchemaName SYSNAME, TableName SYSNAME,
    GraphType VARCHAR(10)
);
CREATE TABLE #XMLSchemaCol (
    DatabaseName SYSNAME, SchemaName SYSNAME, TableName SYSNAME,
    ColumnName SYSNAME, XMLSchemaCollection SYSNAME
);
CREATE TABLE #PartitionedObjs (
    DatabaseName SYSNAME, SchemaName SYSNAME, ObjectName SYSNAME,
    ObjectType NVARCHAR(60), PartitionScheme SYSNAME, PartitionFunction SYSNAME
);
CREATE TABLE #Synonyms (
    DatabaseName SYSNAME, SchemaName SYSNAME, SynonymName SYSNAME,
    BaseObjectName NVARCHAR(1035)
);
CREATE TABLE #Sequences (
    DatabaseName SYSNAME, SchemaName SYSNAME, SequenceName SYSNAME,
    DataType SYSNAME, StartValue SQL_VARIANT, Increment SQL_VARIANT
);
CREATE TABLE #CDC (
    DatabaseName SYSNAME, SchemaName SYSNAME, TableName SYSNAME,
    CaptureInstance SYSNAME
);

/* ── Iterate every online user database ────────────────────────────────────── */
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

    /* ── CLR Assemblies ──────────────────────────────────────────────────── */
    SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #CLRAssemblies
    SELECT DB_NAME(), a.name, a.clr_name, a.permission_set_desc, a.is_visible, a.create_date
    FROM sys.assemblies a WHERE a.is_user_defined = 1;';
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '    CLR scan warning: ' + ERROR_MESSAGE(); END CATCH;

    /* ── Service Broker: queues, services, contracts, message types ───────── */
    SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #ServiceBroker
    SELECT DB_NAME(), ''Queue'', q.name, ''Activation: '' + ISNULL(q.activation_procedure,''none'')
    FROM sys.service_queues q WHERE q.is_ms_shipped = 0;
    INSERT INTO #ServiceBroker
    SELECT DB_NAME(), ''Service'', s.name, ''Queue: '' + sq.name
    FROM sys.services s JOIN sys.service_queues sq ON sq.object_id = s.service_queue_id
    WHERE s.is_ms_shipped = 0;
    INSERT INTO #ServiceBroker
    SELECT DB_NAME(), ''Contract'', sc.name, ''''
    FROM sys.service_contracts sc WHERE sc.is_ms_shipped = 0;
    INSERT INTO #ServiceBroker
    SELECT DB_NAME(), ''MessageType'', mt.name, ''Validation: '' + mt.validation_desc
    FROM sys.service_message_types mt WHERE mt.is_ms_shipped = 0;';
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '    SB scan warning: ' + ERROR_MESSAGE(); END CATCH;

    /* ── External Data Sources ───────────────────────────────────────────── */
    SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
    IF OBJECT_ID(''sys.external_data_sources'') IS NOT NULL
    BEGIN
        INSERT INTO #ExternalDS
        SELECT DB_NAME(), eds.name, eds.type_desc, eds.location,
               eds.resource_manager_location
        FROM sys.external_data_sources eds;
    END;';
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '    ExtDS scan warning: ' + ERROR_MESSAGE(); END CATCH;

    /* ── External Tables ─────────────────────────────────────────────────── */
    SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
    IF OBJECT_ID(''sys.external_tables'') IS NOT NULL
    BEGIN
        INSERT INTO #ExternalTables
        SELECT DB_NAME(), SCHEMA_NAME(et.schema_id), et.name, eds.name
        FROM sys.external_tables et
        JOIN sys.external_data_sources eds ON eds.data_source_id = et.data_source_id;
    END;';
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '    ExtTbl scan warning: ' + ERROR_MESSAGE(); END CATCH;

    /* ── Temporal (system-versioned) Tables ───────────────────────────────── */
    SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #TemporalTables
    SELECT
        DB_NAME(),
        SCHEMA_NAME(t.schema_id),
        t.name,
        SCHEMA_NAME(ht.schema_id),
        ht.name,
        CASE
            WHEN t.history_retention_period = -1 THEN ''INFINITE''
            ELSE CAST(t.history_retention_period AS VARCHAR(10)) + '' ''
                 + t.history_retention_period_unit_desc
        END
    FROM sys.tables t
    LEFT JOIN sys.tables ht ON ht.object_id = t.history_table_id
    WHERE t.temporal_type_desc = ''SYSTEM_VERSIONED_TEMPORAL_TABLE'';';
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '    Temporal scan warning: ' + ERROR_MESSAGE(); END CATCH;

    /* ── Memory-Optimized Tables ─────────────────────────────────────────── */
    SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #MemOptTables
    SELECT DB_NAME(), SCHEMA_NAME(t.schema_id), t.name, t.durability_desc
    FROM sys.tables t WHERE t.is_memory_optimized = 1;';
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '    MemOpt scan warning: ' + ERROR_MESSAGE(); END CATCH;

    /* ── Always Encrypted Columns ────────────────────────────────────────── */
    SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
    IF EXISTS (SELECT 1 FROM sys.columns WHERE encryption_type IS NOT NULL)
    BEGIN
        INSERT INTO #EncryptedCols
        SELECT DB_NAME(), SCHEMA_NAME(o.schema_id), o.name, c.name, c.encryption_type_desc
        FROM sys.columns c
        JOIN sys.objects o ON o.object_id = c.object_id
        WHERE c.encryption_type IS NOT NULL;
    END;';
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '    AE scan warning: ' + ERROR_MESSAGE(); END CATCH;

    /* ── Graph Tables ────────────────────────────────────────────────────── */
    SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #GraphTables
    SELECT DB_NAME(), SCHEMA_NAME(t.schema_id), t.name,
           CASE WHEN t.is_node = 1 THEN ''NODE'' ELSE ''EDGE'' END
    FROM sys.tables t WHERE t.is_node = 1 OR t.is_edge = 1;';
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '    Graph scan warning: ' + ERROR_MESSAGE(); END CATCH;

    /* ── XML Schema Collections ──────────────────────────────────────────── */
    SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #XMLSchemaCol
    SELECT DB_NAME(), SCHEMA_NAME(o.schema_id), o.name, c.name, xsc.name
    FROM sys.columns c
    JOIN sys.objects o ON o.object_id = c.object_id
    JOIN sys.xml_schema_collections xsc ON xsc.xml_collection_id = c.xml_collection_id
    WHERE c.xml_collection_id > 0;';
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '    XML scan warning: ' + ERROR_MESSAGE(); END CATCH;

    /* ── Partitioned Objects ─────────────────────────────────────────────── */
    SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #PartitionedObjs
    SELECT DB_NAME(), SCHEMA_NAME(o.schema_id), o.name, o.type_desc,
           ps.name, pf.name
    FROM sys.indexes i
    JOIN sys.objects o ON o.object_id = i.object_id
    JOIN sys.partition_schemes ps ON ps.data_space_id = i.data_space_id
    JOIN sys.partition_functions pf ON pf.function_id = ps.function_id
    WHERE i.index_id <= 1;';
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '    Partition scan warning: ' + ERROR_MESSAGE(); END CATCH;

    /* ── Synonyms (may point cross-database or linked server) ────────────── */
    SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #Synonyms
    SELECT DB_NAME(), SCHEMA_NAME(s.schema_id), s.name, s.base_object_name
    FROM sys.synonyms s;';
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '    Synonym scan warning: ' + ERROR_MESSAGE(); END CATCH;

    /* ── Sequences ───────────────────────────────────────────────────────── */
    SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
    INSERT INTO #Sequences
    SELECT DB_NAME(), SCHEMA_NAME(s.schema_id), s.name,
           TYPE_NAME(s.user_type_id), s.start_value, s.increment
    FROM sys.sequences s;';
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '    Sequence scan warning: ' + ERROR_MESSAGE(); END CATCH;

    /* ── Change Data Capture ─────────────────────────────────────────────── */
    SET @sql = N'USE ' + QUOTENAME(@dbName) + N';
    IF EXISTS (SELECT 1 FROM sys.tables WHERE name = ''change_tables'' AND schema_id = SCHEMA_ID(''cdc''))
    BEGIN
        INSERT INTO #CDC
        SELECT DB_NAME(), SCHEMA_NAME(st.schema_id), st.name, ct.capture_instance
        FROM cdc.change_tables ct
        JOIN sys.tables st ON st.object_id = ct.source_object_id;
    END;';
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH PRINT '    CDC scan warning: ' + ERROR_MESSAGE(); END CATCH;

    FETCH NEXT FROM db_cursor INTO @dbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

/* ══════════════════════════════════════════════════════════════════════════════
   OUTPUT ALL RESULTS
   ══════════════════════════════════════════════════════════════════════════════ */

PRINT '';
PRINT '════════════════════════════════════════════════════';
PRINT '  RESULTS';
PRINT '════════════════════════════════════════════════════';

PRINT ''; PRINT '── CLR Assemblies ──';
SELECT * FROM #CLRAssemblies ORDER BY DatabaseName, AssemblyName;

PRINT ''; PRINT '── Service Broker Objects ──';
SELECT * FROM #ServiceBroker ORDER BY DatabaseName, ObjectType, ObjectName;

PRINT ''; PRINT '── External Data Sources ──';
SELECT * FROM #ExternalDS ORDER BY DatabaseName, DataSourceName;

PRINT ''; PRINT '── External Tables ──';
SELECT * FROM #ExternalTables ORDER BY DatabaseName, SchemaName, TableName;

PRINT ''; PRINT '── Temporal (System-Versioned) Tables ──';
SELECT * FROM #TemporalTables ORDER BY DatabaseName, SchemaName, TableName;

PRINT ''; PRINT '── Memory-Optimized Tables ──';
SELECT * FROM #MemOptTables ORDER BY DatabaseName, SchemaName, TableName;

PRINT ''; PRINT '── Always Encrypted Columns ──';
SELECT * FROM #EncryptedCols ORDER BY DatabaseName, SchemaName, TableName, ColumnName;

PRINT ''; PRINT '── Graph Tables ──';
SELECT * FROM #GraphTables ORDER BY DatabaseName, SchemaName, TableName;

PRINT ''; PRINT '── XML Schema Collections on Columns ──';
SELECT * FROM #XMLSchemaCol ORDER BY DatabaseName, SchemaName, TableName, ColumnName;

PRINT ''; PRINT '── Partitioned Objects ──';
SELECT * FROM #PartitionedObjs ORDER BY DatabaseName, SchemaName, ObjectName;

PRINT ''; PRINT '── Synonyms ──';
SELECT * FROM #Synonyms ORDER BY DatabaseName, SchemaName, SynonymName;

PRINT ''; PRINT '── Sequences ──';
SELECT * FROM #Sequences ORDER BY DatabaseName, SchemaName, SequenceName;

PRINT ''; PRINT '── Change Data Capture (CDC) ──';
SELECT * FROM #CDC ORDER BY DatabaseName, SchemaName, TableName;

/* ── Feature summary per database ──────────────────────────────────────────── */
PRINT '';
PRINT '── Feature Summary Per Database ──';

SELECT
    sub.DatabaseName,
    sub.Feature,
    sub.ObjectCount
FROM (
    SELECT DatabaseName, 'CLR Assemblies'       AS Feature, COUNT(*) AS ObjectCount FROM #CLRAssemblies   GROUP BY DatabaseName
    UNION ALL
    SELECT DatabaseName, 'Service Broker'       AS Feature, COUNT(*) FROM #ServiceBroker    GROUP BY DatabaseName
    UNION ALL
    SELECT DatabaseName, 'External Data Sources' AS Feature, COUNT(*) FROM #ExternalDS      GROUP BY DatabaseName
    UNION ALL
    SELECT DatabaseName, 'External Tables'       AS Feature, COUNT(*) FROM #ExternalTables  GROUP BY DatabaseName
    UNION ALL
    SELECT DatabaseName, 'Temporal Tables'       AS Feature, COUNT(*) FROM #TemporalTables  GROUP BY DatabaseName
    UNION ALL
    SELECT DatabaseName, 'Memory-Optimized'      AS Feature, COUNT(*) FROM #MemOptTables    GROUP BY DatabaseName
    UNION ALL
    SELECT DatabaseName, 'Always Encrypted'      AS Feature, COUNT(*) FROM #EncryptedCols   GROUP BY DatabaseName
    UNION ALL
    SELECT DatabaseName, 'Graph Tables'          AS Feature, COUNT(*) FROM #GraphTables     GROUP BY DatabaseName
    UNION ALL
    SELECT DatabaseName, 'XML Schema Cols'       AS Feature, COUNT(*) FROM #XMLSchemaCol    GROUP BY DatabaseName
    UNION ALL
    SELECT DatabaseName, 'Partitioning'          AS Feature, COUNT(*) FROM #PartitionedObjs GROUP BY DatabaseName
    UNION ALL
    SELECT DatabaseName, 'Synonyms'              AS Feature, COUNT(*) FROM #Synonyms        GROUP BY DatabaseName
    UNION ALL
    SELECT DatabaseName, 'Sequences'             AS Feature, COUNT(*) FROM #Sequences       GROUP BY DatabaseName
    UNION ALL
    SELECT DatabaseName, 'CDC'                   AS Feature, COUNT(*) FROM #CDC             GROUP BY DatabaseName
) sub
ORDER BY sub.DatabaseName, sub.Feature;

/* ── Cleanup ──────────────────────────────────────────────────────────────── */
DROP TABLE #CLRAssemblies;
DROP TABLE #ServiceBroker;
DROP TABLE #ExternalDS;
DROP TABLE #ExternalTables;
DROP TABLE #TemporalTables;
DROP TABLE #MemOptTables;
DROP TABLE #EncryptedCols;
DROP TABLE #GraphTables;
DROP TABLE #XMLSchemaCol;
DROP TABLE #PartitionedObjs;
DROP TABLE #Synonyms;
DROP TABLE #Sequences;
DROP TABLE #CDC;

PRINT '';
PRINT 'Script 5 complete.';
GO
