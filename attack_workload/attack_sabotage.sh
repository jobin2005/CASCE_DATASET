#!/bin/bash
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./_identity_lib.sh
casce_new_identity
echo "  identity=${CASCE_USER}@${CASCE_IP}"
echo "Simulating Sabotage Attack (Attack 2)..."

/dataset_workspace/logger.sh mark_attack "attack_sabotage" start

# Drop critical operational tables
psql -U postgres -d casce_tpcb -c "$(casce_sql_prelude)DROP TABLE IF EXISTS pgbench_history CASCADE;"

/dataset_workspace/logger.sh mark_attack "attack_sabotage" end

echo "Sabotage attempted."
