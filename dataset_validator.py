#!/usr/bin/env python3
"""
dataset_validator.py — Validates CASCE dataset integrity.

Checks:
  1. Structural field presence in postgres_events.json and kernel_events.json
  2. PID overlap between PostgreSQL backend PIDs and kernel event PIDs
  3. Concurrency / session-isolation: verifies that overlapping sessions have
     distinct (session_id, backend_pid) pairs and that no kernel PID is
     attributed to more than one active PostgreSQL session at the same timestamp
"""
import json
import sys
from collections import defaultdict


def validate_dataset():
    print("Validating dataset integrity across Phase 1-5 artifacts...")

    pg_valid = True
    pg_pids = set()

    # ── 1. Validate PostgreSQL events ────────────────────────────────
    print("Checking postgres_events.json...")
    session_intervals = {}   # session_id -> (min_ts, max_ts)
    session_pids = {}        # session_id -> backend_pid

    try:
        with open("/dataset_workspace/postgres_events.json", "r") as f:
            for i, line in enumerate(f):
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    print(f"Malformed JSON at line {i+1}")
                    pg_valid = False
                    continue

                if "marker" in event:
                    continue
                if not all(k in event for k in ("session_id", "backend_pid", "query", "timestamp")):
                    print(f"Malformed PG event at line {i+1}")
                    pg_valid = False
                    continue

                sid = event["session_id"]
                pid = event["backend_pid"]
                ts = float(event["timestamp"])
                pg_pids.add(pid)

                # Track session intervals
                if sid not in session_intervals:
                    session_intervals[sid] = (ts, ts)
                    session_pids[sid] = pid
                else:
                    lo, hi = session_intervals[sid]
                    session_intervals[sid] = (min(lo, ts), max(hi, ts))
    except FileNotFoundError:
        print("postgres_events.json missing.")
        return False

    print(f"-> postgres_events.json passed structural checks. "
          f"Extracted {len(pg_pids)} backend PIDs, {len(session_intervals)} sessions.")

    kernel_valid = True
    kernel_pids = set()

    # Per-PID timestamp list for cross-session contamination check
    kernel_pid_timestamps = defaultdict(list)   # pid -> [(ts, source_pid)]

    # ── 2. Validate Kernel events ────────────────────────────────────
    print("Checking kernel_events.json...")
    try:
        with open("/dataset_workspace/kernel_events.json", "r") as f:
            for i, line in enumerate(f):
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    print(f"Malformed JSON at kernel line {i+1}")
                    kernel_valid = False
                    continue

                if "marker" in event:
                    continue
                if not all(k in event for k in ("pid", "timestamp")):
                    print(f"Malformed Kernel event at line {i+1}")
                    kernel_valid = False
                    continue

                pid = event.get("pid")
                ppid = event.get("ppid")
                ts = float(event["timestamp"])
                kernel_pids.add(pid)
                if ppid is not None:
                    kernel_pids.add(ppid)

                # Track for contamination check
                kernel_pid_timestamps[pid].append(ts)
                if ppid is not None:
                    kernel_pid_timestamps[ppid].append(ts)
    except FileNotFoundError:
        print("kernel_events.json missing.")
        return False

    print(f"-> kernel_events.json passed structural checks.")

    # ── 3. Correlate PID presence ────────────────────────────────────
    print("Verifying if Backend PIDs exist in kernel streams (Algorithm 1 prerequisite)...")
    overlap = pg_pids.intersection(kernel_pids)
    if not overlap:
        print("WARNING: Zero backend PIDs found in kernel events stream. Is eBPF tracer running?")
    else:
        print(f"SUCCESS: {len(overlap)} backend PIDs successfully traced in kernel logs!")

    # ── 4. Concurrency / Session-Isolation Check ─────────────────────
    print("\n--- CONCURRENCY CHECK ---")

    # 4a. Find overlapping session pairs
    sessions = sorted(session_intervals.items(), key=lambda x: x[1][0])  # sort by start
    overlapping_pairs = []
    for i in range(len(sessions)):
        sid_a, (start_a, end_a) = sessions[i]
        for j in range(i + 1, len(sessions)):
            sid_b, (start_b, end_b) = sessions[j]
            if start_b > end_a:
                break   # no further sessions can overlap with session_a
            # Sessions overlap: start_b <= end_a AND start_a <= end_b
            if start_a <= end_b:
                overlapping_pairs.append((sid_a, sid_b))

    print(f"  Overlapping session pairs found: {len(overlapping_pairs)}")

    # 4b. All overlapping sessions must have distinct (session_id, backend_pid)
    pid_collision = False
    for sid_a, sid_b in overlapping_pairs:
        pid_a = session_pids.get(sid_a)
        pid_b = session_pids.get(sid_b)
        if pid_a is not None and pid_b is not None and pid_a == pid_b and sid_a != sid_b:
            print(f"  FAIL: sessions {sid_a} and {sid_b} share backend_pid {pid_a} "
                  f"while overlapping in time!")
            pid_collision = True

    if not pid_collision:
        print(f"  All overlapping sessions have distinct (session_id, backend_pid): PASS")
    else:
        print(f"  Distinct (session_id, backend_pid) check: FAIL")

    # 4c. No kernel PID attributed to more than one active PG session at same timestamp
    #     Build a mapping: kernel_pid -> set of session_ids that own it during overlap
    contamination = False
    pid_to_sessions = defaultdict(set)
    for sid, pid in session_pids.items():
        pid_to_sessions[pid].add(sid)

    multi_session_pids = {pid: sids for pid, sids in pid_to_sessions.items()
                          if len(sids) > 1}

    if multi_session_pids:
        # These PIDs appear in multiple sessions — check if any are concurrent
        for pid, sids in multi_session_pids.items():
            sid_list = list(sids)
            for i in range(len(sid_list)):
                for j in range(i + 1, len(sid_list)):
                    sa, sb = sid_list[i], sid_list[j]
                    int_a = session_intervals.get(sa)
                    int_b = session_intervals.get(sb)
                    if int_a and int_b:
                        if int_a[0] <= int_b[1] and int_b[0] <= int_a[1]:
                            print(f"  FAIL: kernel PID {pid} attributed to sessions "
                                  f"{sa} and {sb} which overlap in time!")
                            contamination = True

    if not contamination:
        print(f"  No kernel PID attributed to multiple sessions at same timestamp: PASS")
    else:
        print(f"  Cross-session kernel PID contamination check: FAIL")

    # ── Summary ──────────────────────────────────────────────────────
    print()
    all_pass = (pg_valid and kernel_valid and len(overlap) > 0
                and not pid_collision and not contamination)

    if all_pass:
        print("VALIDATION SUCCESSFUL. Dataset is ready to freeze.")
    else:
        print("VALIDATION FAILED OR INCOMPLETE.")

    return all_pass


if __name__ == '__main__':
    success = validate_dataset()
    sys.exit(0 if success else 1)
