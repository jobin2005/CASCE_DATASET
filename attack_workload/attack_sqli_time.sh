#!/bin/bash
# Template: SQLi time-based blind-injection probe.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./_identity_lib.sh
casce_new_identity

echo "Simulating SQL Injection Attack (attack_sqli_time)... identity=${CASCE_USER}@${CASCE_IP}"
/dataset_workspace/logger.sh mark_attack "attack_sqli_time" start

# Real time-based blind SQLi probes vary the sleep length between probes to
# avoid a fixed fingerprint -- randomize the pg_sleep() argument itself as
# well as the gap between successive probes.
NUM_PROBES=$(( (RANDOM % 3) + 1 ))
for i in $(seq 1 "$NUM_PROBES"); do
  probe_seconds=$(awk -v mn=1 -v mx=3 'BEGIN{srand(); printf "%.1f", mn+rand()*(mx-mn)}')
  psql -U postgres -d casce_tpcb -c "$(casce_sql_prelude)SELECT pg_sleep(${probe_seconds});"
  casce_random_delay 0.5 3.0
done

/dataset_workspace/logger.sh mark_attack "attack_sqli_time" end
