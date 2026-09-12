#!/bin/bash
# Template: SQLi UNION attack. Each run is tagged with a fresh, unique
# synthetic username/IP (via _identity_lib.sh) and separates its SQL
# commands with a randomized delay instead of firing back-to-back.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./_identity_lib.sh
casce_new_identity

echo "Simulating SQL Injection Attack (attack_sqli_union)... identity=${CASCE_USER}@${CASCE_IP}"
/dataset_workspace/logger.sh mark_attack "attack_sqli_union" start

# The commands array is the "template" -- add/reorder/remove statements here
# and each will run under the same synthetic identity, spaced out randomly.
SQL_COMMANDS=(
  "SELECT * FROM pgbench_accounts WHERE aid = 1 UNION ALL SELECT 1, 2, 3;"
)

for sql in "${SQL_COMMANDS[@]}"; do
  psql -U postgres -d casce_tpcb -c "$(casce_sql_prelude)${sql}"
  casce_random_delay 0.3 2.5
done

/dataset_workspace/logger.sh mark_attack "attack_sqli_union" end
