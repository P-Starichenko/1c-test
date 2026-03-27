/*******************************************************************************
 * Phase 1 — Script 1: Database Inventory
 *
 * Purpose : Catalog every database on the instance with key properties needed
 *           before creating DACPAC projects.
 *
 * Output  : One row per database with name, state, compatibility level,
 *           collation, recovery model, size, file layout, creation date,
 *           owner, and containment type.
 *
 * Target  : SQL Server 2025 Enterprise Edition
 * Run As  : sysadmin or a login with VIEW ANY DATABASE + VIEW SERVER STATE
 ******************************************************************************/

SET NOCOUNT ON;

PRINT '================================================================';
PRINT '  Script 1 — Database Inventory';
PRINT '  Run at: ' + CONVERT(VARCHAR(30), GETDATE(), 121);
PRINT '  Server: ' + @@SERVERNAME;
PRINT '  Version: ' + @@VERSION;
PRINT '================================================================';
PRINT '';

/* ── 1a. Instance-level summary ────────────────────────────────────────────── */
SELECT
    SERVERPROPERTY('MachineName')           AS MachineName,
    SERVERPROPERTY('ServerName')            AS ServerName,
    SERVERPROPERTY('InstanceName')          AS InstanceName,
    SERVERPROPERTY('Edition')               AS Edition,
    SERVERPROPERTY('ProductVersion')        AS ProductVersion,
    SERVERPROPERTY('ProductLevel')          AS ProductLevel,
    SERVERPROPERTY('ProductMajorVersion')   AS ProductMajorVersion,
    SERVERPROPERTY('Collation')             AS ServerCollation,
    SERVERPROPERTY('IsClustered')           AS IsClustered,
    SERVERPROPERTY('IsHadrEnabled')         AS IsAlwaysOnEnabled,
    SERVERPROPERTY('IsIntegratedSecurityOnly') AS WindowsAuthOnly;

/* ── 1b. Full database list with properties ────────────────────────────────── */
SELECT
    d.database_id,
    d.name                                  AS DatabaseName,
    d.state_desc                            AS [State],
    d.compatibility_level                   AS CompatibilityLevel,
    d.collation_name                        AS Collation,
    d.recovery_model_desc                   AS RecoveryModel,
    d.containment_desc                      AS Containment,
    d.is_read_only                          AS IsReadOnly,
    d.is_auto_close_on                      AS AutoClose,
    d.is_auto_shrink_on                     AS AutoShrink,
    d.page_verify_option_desc               AS PageVerify,
    d.snapshot_isolation_state_desc          AS SnapshotIsolation,
    d.is_read_committed_snapshot_on          AS RCSI,
    d.is_broker_enabled                     AS ServiceBrokerEnabled,
    d.is_cdc_enabled                        AS CDCEnabled,
    d.is_encrypted                          AS TDEEnabled,
    d.create_date                           AS CreatedDate,
    SUSER_SNAME(d.owner_sid)               AS [Owner],
    CASE
        WHEN d.name IN ('master','model','msdb','tempdb') THEN 'System'
        ELSE 'User'
    END                                     AS DatabaseType
FROM sys.databases d
ORDER BY d.name;

/* ── 1c. Database sizes (data + log) ───────────────────────────────────────── */
SELECT
    DB_NAME(mf.database_id)                AS DatabaseName,
    mf.name                                AS LogicalFileName,
    mf.type_desc                           AS FileType,
    mf.physical_name                       AS PhysicalPath,
    mf.state_desc                          AS FileState,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(18,2))          AS SizeMB,
    CASE mf.max_size
        WHEN -1 THEN 'Unlimited'
        WHEN  0 THEN 'No Growth'
        ELSE CAST(CAST(mf.max_size * 8.0 / 1024 AS DECIMAL(18,2)) AS VARCHAR(20))
    END                                    AS MaxSizeMB,
    CASE mf.is_percent_growth
        WHEN 1 THEN CAST(mf.growth AS VARCHAR(10)) + ' %'
        ELSE CAST(CAST(mf.growth * 8.0 / 1024 AS DECIMAL(18,2)) AS VARCHAR(20)) + ' MB'
    END                                    AS GrowthSetting
FROM sys.master_files mf
ORDER BY DB_NAME(mf.database_id), mf.type, mf.file_id;

/* ── 1d. Aggregated size per database ──────────────────────────────────────── */
SELECT
    DB_NAME(database_id)                   AS DatabaseName,
    CAST(SUM(CASE WHEN type = 0 THEN size * 8.0 / 1024 ELSE 0 END) AS DECIMAL(18,2)) AS DataSizeMB,
    CAST(SUM(CASE WHEN type = 1 THEN size * 8.0 / 1024 ELSE 0 END) AS DECIMAL(18,2)) AS LogSizeMB,
    CAST(SUM(size * 8.0 / 1024) AS DECIMAL(18,2))                                     AS TotalSizeMB
FROM sys.master_files
GROUP BY database_id
ORDER BY TotalSizeMB DESC;

/* ── 1e. Databases in Always On Availability Groups (if any) ───────────────── */
IF EXISTS (SELECT 1 FROM sys.all_objects WHERE name = 'dm_hadr_database_replica_states' AND type = 'V')
BEGIN
    EXEC sp_executesql N'
    SELECT
        ag.name                            AS AvailabilityGroup,
        ar.replica_server_name             AS ReplicaServer,
        drs.database_id,
        DB_NAME(drs.database_id)           AS DatabaseName,
        drs.synchronization_state_desc     AS SyncState,
        drs.synchronization_health_desc    AS SyncHealth,
        ar.availability_mode_desc          AS AvailabilityMode,
        ar.failover_mode_desc              AS FailoverMode
    FROM sys.dm_hadr_database_replica_states drs
    JOIN sys.availability_replicas ar
         ON ar.replica_id = drs.replica_id
    JOIN sys.availability_groups ag
         ON ag.group_id = ar.group_id
    ORDER BY ag.name, ar.replica_server_name;';
END
ELSE
    PRINT 'Always On Availability Groups not enabled or not available.';

PRINT '';
PRINT 'Script 1 complete.';
GO
