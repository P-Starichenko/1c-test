# Phase 1 — Discovery & Inventory Scripts

SQL scripts to catalog your SQL Server 2025 EE instance before creating DACPAC projects.

## Scripts

| # | Script | Purpose |
|---|--------|---------|
| 00 | `00_run_all_discovery.sql` | Master runner — executes all scripts in order (SQLCMD mode) |
| 01 | `01_database_inventory.sql` | Instance info, database list, sizes, files, Always On status |
| 02 | `02_cross_database_references.sql` | Three-part name references (`[OtherDB].[schema].[object]`) |
| 03 | `03_linked_server_references.sql` | Linked servers config + four-part name references |
| 04 | `04_instance_level_objects.sql` | Logins, server roles, credentials, endpoints, triggers, audits, Agent jobs, mail profiles, orphaned users |
| 05 | `05_special_features.sql` | CLR assemblies, Service Broker, external data sources/tables, temporal tables, memory-optimized tables, Always Encrypted, graph tables, XML schemas, partitioning, synonyms, sequences, CDC |
| 06 | `06_dependency_graph.sql` | Cross-database dependency edges, build order suggestion, object counts per database |

## How to Run

### Option A — Run all at once (recommended)

Using `sqlcmd`:

```bash
sqlcmd -S YourServer -E -i "C:\discovery\00_run_all_discovery.sql" -o "C:\discovery\output\discovery_report.txt" -s"|" -w 300
```

> **Note:** Edit the `:setvar ScriptPath` line in `00_run_all_discovery.sql` to match the folder location.

### Option B — Run individually in SSMS

Open any script in SSMS and execute. No SQLCMD mode needed for individual scripts.

### Option C — Run all individually via sqlcmd

```bash
sqlcmd -S YourServer -E -i "01_database_inventory.sql"        -o "output\01_inventory.txt"   -s"|" -w 300
sqlcmd -S YourServer -E -i "02_cross_database_references.sql" -o "output\02_crossdb.txt"     -s"|" -w 300
sqlcmd -S YourServer -E -i "03_linked_server_references.sql"  -o "output\03_linkedsrv.txt"   -s"|" -w 300
sqlcmd -S YourServer -E -i "04_instance_level_objects.sql"    -o "output\04_instance.txt"    -s"|" -w 300
sqlcmd -S YourServer -E -i "05_special_features.sql"          -o "output\05_features.txt"    -s"|" -w 300
sqlcmd -S YourServer -E -i "06_dependency_graph.sql"          -o "output\06_depgraph.txt"    -s"|" -w 300
```

## Required Permissions

| Level | Minimum Permissions |
|-------|-------------------|
| Recommended | `sysadmin` (full visibility into all objects) |
| Alternative | `VIEW ANY DATABASE`, `VIEW SERVER STATE`, `VIEW ANY DEFINITION`, `db_owner` on each user database |

## What to Do with the Output

1. **Review Script 01** — confirm all databases are listed and note collation mismatches.
2. **Review Script 02 & 03** — these determine which DACPAC project references you need.
3. **Review Script 04** — identify logins/Agent jobs that need pre-deployment scripts.
4. **Review Script 05** — flag features requiring special DACPAC/SDK configuration.
5. **Review Script 06** — use the suggested build order when setting up `.sqlproj` references.

Feed the results into **Phase 2** (tooling setup) and **Phase 3** (solution structure).
