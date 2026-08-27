#!/bin/bash
# benign_edge_cases.sh — Legitimate DBA activities that look structurally similar
# to attack patterns but are entirely benign. These serve as "hard negatives" to
# prevent the classifier from learning trivially separable boundaries.
#
# NOT wrapped in attack markers → labeler correctly assigns "Normal".
set -euo pipefail

echo "Starting benign edge-case workload (hard negatives)..."

# ── 1. Legitimate backup via COPY TO PROGRAM ────────────────────────────
# Same COPY-TO-PROGRAM shape as attack_exfiltration.sh, but writing to a
# local backup path with no network call.
echo "  [1/4] Legitimate backup via COPY TO PROGRAM..."
mkdir -p /var/backups
psql -U postgres -d casce_tpcb -c \
  "COPY (SELECT aid, bid, abalance FROM pgbench_accounts LIMIT 100) TO PROGRAM 'gzip > /var/backups/accounts_backup.gz';"

# ── 2. DBA temp table create + drop ─────────────────────────────────────
# Structurally close to attack_sabotage.sh's DROP TABLE, but on a table the
# DBA just created (a genuinely temporary table).
echo "  [2/4] DBA temp table create and drop..."
psql -U postgres -d casce_tpcb <<'SQL'
CREATE TEMP TABLE dba_staging_report (
    id      SERIAL,
    metric  TEXT,
    value   NUMERIC
);
INSERT INTO dba_staging_report (metric, value) VALUES
    ('avg_balance', 500.00),
    ('max_balance', 99999.00),
    ('active_accounts', 100000);
SELECT * FROM dba_staging_report;
DROP TABLE dba_staging_report;
SQL

# ── 3. Authorized bulk read by a reporting role ─────────────────────────
# Similar shape to attack_db_unauthorized_read.sh's SELECT ... ORDER BY ...
# LIMIT, but from a role explicitly GRANTed SELECT.
echo "  [3/4] Authorized bulk read by reporting role..."
psql -U postgres -d casce_tpcb -c \
  "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='casce_reporter') THEN CREATE ROLE casce_reporter LOGIN PASSWORD 'rpt_secure_2024'; END IF; END \$\$;"
psql -U postgres -d casce_tpcb -c "GRANT SELECT ON pgbench_accounts TO casce_reporter;"
PGPASSWORD='rpt_secure_2024' psql -U casce_reporter -d casce_tpcb -c \
  "SELECT aid, abalance FROM pgbench_accounts ORDER BY abalance DESC LIMIT 5000;" > /dev/null
psql -U postgres -d casce_tpcb -c "REVOKE SELECT ON pgbench_accounts FROM casce_reporter;"
psql -U postgres -d casce_tpcb -c "DROP ROLE IF EXISTS casce_reporter;"

# ── 4. Routine superuser maintenance touching multiple tables ───────────
# VACUUM, ANALYZE, REINDEX across several tables in one session, so it
# isn't trivially separable by "how many tables did this session touch".
echo "  [4/4] Routine multi-table maintenance (VACUUM, ANALYZE, REINDEX)..."
psql -U postgres -d casce_tpcb <<'SQL'
VACUUM ANALYZE pgbench_accounts;
VACUUM ANALYZE pgbench_tellers;
VACUUM ANALYZE pgbench_branches;
REINDEX TABLE pgbench_accounts;
REINDEX TABLE pgbench_tellers;
ANALYZE pgbench_history;
SQL

echo "Benign edge-case workload completed."
