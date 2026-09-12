#!/bin/bash
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./_identity_lib.sh
casce_new_identity
echo "  identity=${CASCE_USER}@${CASCE_IP}"
echo "Simulating DB-only Unauthorized Query (Category 2)..."

/dataset_workspace/logger.sh mark_attack "attack_db_unauthorized_read" start

# An attacker queries a sensitive table inside the DB layer but doesn't write to disk or network.
# Thus, no anomalous kernels traces are produced. Relying exclusively on DB detection.
psql -U postgres -d casce_tpcb -c "$(casce_sql_prelude)SELECT aid, abalance FROM pgbench_accounts ORDER BY abalance DESC LIMIT 5000;" > /dev/null

/dataset_workspace/logger.sh mark_attack "attack_db_unauthorized_read" end

echo "DB-only unauthorized query simulated."
