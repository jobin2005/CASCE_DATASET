#!/bin/bash
# _identity_lib.sh
#
# Shared helpers sourced by every attack_workload/attack_*.sh template.
# Responsible for:
#   1. Handing each attack invocation a random synthetic username + IP,
#      guaranteed never to repeat across the whole dataset-generation run
#      (tracked in a persistent registry file, safe for concurrent scripts).
#   2. Emitting the `SET casce.sim_user / casce.sim_ip` prelude that gets
#      injected into a psql call so pg_telemetry.c logs that identity
#      instead of the real (always "postgres"/local) one.
#   3. Randomized delays between successive SQL commands inside a single
#      attack script, instead of a fixed sleep.
#
# This file makes no network connections and touches no real systems -- it
# only randomizes labels that get written into a local synthetic dataset.

CASCE_WORKDIR="${CASCE_WORKDIR:-/dataset_workspace}"
CASCE_IDENTITY_REGISTRY="${CASCE_IDENTITY_REGISTRY:-${CASCE_WORKDIR}/.casce_identity_registry.tsv}"
CASCE_IDENTITY_LOCK="${CASCE_IDENTITY_REGISTRY}.lock"

_CASCE_USER_POOL=(db_admin analyst_bob service_alice dev_charlie ops_dana
  qa_edgar backup_frank audit_grace intern_hank vendor_ivy
  support_jack replica_kim etl_liam metrics_mona sre_noah
  billing_opal reports_paul svc_quinn contractor_rosa temp_sam)

# Pick N unique random octets in [lo, hi] without needing external tools.
_casce_rand_int() { # lo hi
  local lo=$1 hi=$2
  echo $(( lo + (RANDOM % (hi - lo + 1)) ))
}

_casce_rand_username() {
  local base=${_CASCE_USER_POOL[$((RANDOM % ${#_CASCE_USER_POOL[@]}))]}
  printf '%s_%03d' "$base" "$(_casce_rand_int 0 999)"
}

_casce_rand_ip() {
  # Private / documentation ranges only (RFC1918 + TEST-NET), never a
  # routable address -- these are synthetic labels for the dataset, not
  # real endpoints.
  local ranges=("10.$(_casce_rand_int 0 255).$(_casce_rand_int 0 255)"
                "192.168.$(_casce_rand_int 0 255)"
                "172.$(_casce_rand_int 16 31).$(_casce_rand_int 0 255)")
  printf '%s.%d' "${ranges[$((RANDOM % ${#ranges[@]}))]}" "$(_casce_rand_int 1 254)"
}

# casce_new_identity: populate CASCE_USER / CASCE_IP with a pair that has
# never been handed out before in this dataset-generation run. Safe to call
# from multiple concurrently-running attack scripts (flock-guarded).
casce_new_identity() {
  touch "$CASCE_IDENTITY_REGISTRY" 2>/dev/null || CASCE_IDENTITY_REGISTRY="/tmp/.casce_identity_registry.tsv"
  touch "$CASCE_IDENTITY_REGISTRY"

  local user ip attempt=0
  (
    flock -x 200
    while :; do
      user="$(_casce_rand_username)"
      ip="$(_casce_rand_ip)"
      attempt=$((attempt + 1))
      # Reject if this username OR this IP has been used before -- every
      # generated attack instance gets a wholly unique identity pair.
      if ! grep -qE "(^|\t)${user}(\t|$)" "$CASCE_IDENTITY_REGISTRY" 2>/dev/null \
         && ! grep -qE "(\t)${ip}(\t|$)" "$CASCE_IDENTITY_REGISTRY" 2>/dev/null; then
        printf '%s\t%s\n' "$user" "$ip" >> "$CASCE_IDENTITY_REGISTRY"
        printf '%s\t%s\n' "$user" "$ip" > "${CASCE_IDENTITY_REGISTRY}.last"
        break
      fi
      # Pool is large relative to expected run sizes; this bails out rather
      # than looping forever if it's ever exhausted.
      if [ "$attempt" -ge 500 ]; then
        printf '%s_%s\t%s\n' "$user" "$RANDOM" "$ip" > "${CASCE_IDENTITY_REGISTRY}.last"
        break
      fi
    done
  ) 200>"$CASCE_IDENTITY_LOCK"

  IFS=$'\t' read -r CASCE_USER CASCE_IP < "${CASCE_IDENTITY_REGISTRY}.last"
  export CASCE_USER CASCE_IP
}

# casce_sql_prelude: the `SET ...;` string to splice in front of any SQL
# sent to psql so the session gets tagged with the identity picked above.
# Requires casce_new_identity to have been called first.
casce_sql_prelude() {
  printf "SET casce.sim_user = '%s'; SET casce.sim_ip = '%s'; " "$CASCE_USER" "$CASCE_IP"
}

# casce_random_delay MIN MAX: sleep a random duration in [MIN, MAX] seconds
# (floats allowed), used between successive SQL commands within an attack
# script instead of a fixed sleep so timing varies run to run.
casce_random_delay() {
  local min=${1:-0.5} max=${2:-2.0}
  awk -v mn="$min" -v mx="$max" 'BEGIN { srand(); printf "%.3f\n", mn + rand() * (mx - mn) }' | {
    read -r secs
    echo "  (waiting ${secs}s before next command, identity=${CASCE_USER:-unset}@${CASCE_IP:-unset})"
    sleep "$secs"
  }
}
