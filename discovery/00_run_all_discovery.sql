/*******************************************************************************
 * Phase 1 — Master Runner: Execute All Discovery Scripts
 *
 * Usage   : Run this script from SSMS or sqlcmd to execute all 6 discovery
 *           scripts in order. Update the path below to match where you placed
 *           the discovery folder.
 *
 *   sqlcmd:
 *     sqlcmd -S YourServer -E -i "C:\discovery\00_run_all_discovery.sql" -o "C:\discovery\output\discovery_report.txt"
 *
 *   SSMS:
 *     Enable SQLCMD Mode (Query menu → SQLCMD Mode), then execute this file.
 *
 * Target  : SQL Server 2025 Enterprise Edition
 * Run As  : sysadmin (recommended for full visibility)
 ******************************************************************************/

-- !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
-- UPDATE THIS PATH to the folder containing the discovery scripts
-- !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
:setvar ScriptPath "C:\discovery"

PRINT '╔══════════════════════════════════════════════════════════════════╗';
PRINT '║  DACPAC Discovery — Phase 1: Full Instance Scan                ║';
PRINT '║  Server: ' + @@SERVERNAME;
PRINT '║  Date  : ' + CONVERT(VARCHAR(30), GETDATE(), 121);
PRINT '╚══════════════════════════════════════════════════════════════════╝';
PRINT '';

PRINT '▶ Running 01_database_inventory.sql ...';
:r $(ScriptPath)\01_database_inventory.sql
PRINT '';

PRINT '▶ Running 02_cross_database_references.sql ...';
:r $(ScriptPath)\02_cross_database_references.sql
PRINT '';

PRINT '▶ Running 03_linked_server_references.sql ...';
:r $(ScriptPath)\03_linked_server_references.sql
PRINT '';

PRINT '▶ Running 04_instance_level_objects.sql ...';
:r $(ScriptPath)\04_instance_level_objects.sql
PRINT '';

PRINT '▶ Running 05_special_features.sql ...';
:r $(ScriptPath)\05_special_features.sql
PRINT '';

PRINT '▶ Running 06_dependency_graph.sql ...';
:r $(ScriptPath)\06_dependency_graph.sql
PRINT '';

PRINT '╔══════════════════════════════════════════════════════════════════╗';
PRINT '║  Discovery complete. Review output above.                      ║';
PRINT '╚══════════════════════════════════════════════════════════════════╝';
GO
