#!/bin/bash
echo "Simulating Privilege Abuse (Attack 3 & 4)..."
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./_identity_lib.sh
casce_new_identity
echo "  identity=${CASCE_USER}@${CASCE_IP}"

/dataset_workspace/logger.sh mark_attack "attack_privilege_abuse" start

# Create a hacker role and escalate privileges. The role name is derived
# from this run's synthetic identity so repeated/concurrent runs never
# collide on an already-existing role.
HACKER_ROLE="hacker_${CASCE_USER}"
psql -U postgres -d casce_tpcb -c "$(casce_sql_prelude)CREATE ROLE ${HACKER_ROLE} WITH SUPERUSER LOGIN PASSWORD 'hacked';"
casce_random_delay 0.3 2.0

# Perform unauthorized operations with escalated privileges
export PGPASSWORD='hacked'
psql -U "${HACKER_ROLE}" -d casce_tpcb -c "$(casce_sql_prelude)SELECT set_config('log_statement', 'none', false);"
casce_random_delay 0.3 2.0
psql -U "${HACKER_ROLE}" -d casce_tpcb -c "$(casce_sql_prelude)UPDATE pgbench_tellers SET tbalance = 99999 WHERE tid = 1;"

/dataset_workspace/logger.sh mark_attack "attack_privilege_abuse" end

echo "Privilege abuse attempted."
