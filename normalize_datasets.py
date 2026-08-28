#!/usr/bin/env python3
"""
normalize_casce.py

Aligns a CASCE dataset run's kernel_events.json with postgres_events.json:

1. TIMESTAMPS
   kernel_events.json events use bpf_ktime_get_ns() -- nanoseconds since
   host boot, a monotonic clock with an arbitrary zero point.
   postgres_events.json events use time(NULL) -- Unix epoch seconds.
   These are NOT the same clock and cannot be compared directly.

   Fix: time_sync.json records server_boot_unix_time (the Unix epoch
   second at which the host booted). For every kernel event:
       timestamp_unix = server_boot_unix_time + (timestamp_ns / 1e9)
   This produces a Unix-epoch float timestamp directly comparable to
   postgres_events.json's timestamps (and to the LOGGING_START/STOP
   marker lines, which are already Unix epoch floats in BOTH files).

2. PIDs / SESSION CORRELATION
   A Postgres backend_pid only appears directly in kernel_events.json
   for actions the backend itself performs (openat, connect, etc).
   For `COPY ... TO PROGRAM '<shell command>'` attacks (exfiltration,
   reverse shell, sabotage-via-shell), Postgres forks a child process
   (sh -> curl/gzip/python3/bash) to run the command. That child gets
   its OWN pid; only its ppid chain traces back to the backend_pid.

   Fix: build a pid->ppid map from every kernel event seen, then for
   every kernel-event pid, walk the ppid chain upward until you hit a
   known Postgres backend_pid (or run out of ancestors). Tag the event
   with that resolved `correlated_session_id` so it can be joined
   against labels.csv / postgres_events.json by session, not just by
   raw pid equality.

USAGE
    python3 normalize_casce.py <run_dir>

    <run_dir> must contain: postgres_events.json, kernel_events.json,
    time_sync.json

    Writes: <run_dir>/kernel_events.normalized.json
    Each line is the original kernel event plus two new fields:
        "timestamp_unix": <float, seconds since epoch>
        "correlated_session_id": <int or null>
"""
import json
import sys
from pathlib import Path

# Process names confirmed (by inspecting real run data) to be unrelated
# host/desktop/Docker-daemon noise picked up only because `pid: host` +
# privileged eBPF traces the ENTIRE machine, not just the container.
# None of these appear anywhere in the CASCE repo's own scripts.
# IMPORTANT: this is an allow-listed removal, not "drop everything
# unresolved" -- things like pgbench, psql, bash, sh, root_bash, cp,
# whoami, python3 etc. are genuine workload/attack processes (e.g.
# attack_os_priv_escalation.sh never touches Postgres at all, so its
# `root_bash` process is correctly "unresolved" but must be kept) and
# are deliberately NOT in this list.
NOISE_COMMS = {
    # Desktop / browser
    "code", "Compositor", "VizCompositorTh", "Chrome_ChildIOT",
    "Chrome_IOThread", "Isolated Web Co", "Socket Thread", "LS Thread",
    "libuv-worker", "Indexed~IO #152", "StreamT~ns #145",
    "StreamT~ns #146",
    # OS services unrelated to the DB workload
    "mdns_service", "upowerd", "systemd-oomd", "systemd", "dbus-daemon",
    "thermald", "gvfsd-wsdd",
    "FSBroker23396", "FSBroker24284", "FSBroker28504",
    # Docker daemon / container runtime plumbing (orchestration mechanics,
    # not attack or workload semantics)
    "runc", "runc:[0:PARENT]", "runc:[1:CHILD]", "runc:[2:INIT]",
    "dockerd", "docker", "docker-debug", "containerd-shim",
    "Privileged Cont",
    # Confirmed not present anywhere in the CASCE_DATASET repo
    "cpuUsage.sh",
}


def load_pg_backend_pids(pg_events_path):
    pids = set()
    with open(pg_events_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "marker" in event:
                continue
            bp = event.get("backend_pid")
            if bp is not None:
                pids.add(bp)
    return pids


def build_ppid_map(kernel_events_path):
    ppid_map = {}
    with open(kernel_events_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "marker" in event:
                continue
            pid = event.get("pid")
            ppid = event.get("ppid")
            if pid is not None and pid not in ppid_map:
                ppid_map[pid] = ppid
    return ppid_map


def resolve_session(pid, pg_pids, ppid_map, max_depth=10):
    """Walk the ppid chain from `pid` until a known Postgres backend_pid
    is found. Returns that backend_pid, or None if no ancestor matches
    within max_depth hops (or the chain runs out)."""
    current = pid
    seen = set()
    for _ in range(max_depth):
        if current in pg_pids:
            return current
        if current in seen or current is None:
            return None
        seen.add(current)
        current = ppid_map.get(current)
    return None


def normalize(run_dir, drop_noise=False):
    run_dir = Path(run_dir)
    pg_path = run_dir / "postgres_events.json"
    kernel_path = run_dir / "kernel_events.json"
    sync_path = run_dir / "time_sync.json"
    out_path = run_dir / (
        "kernel_events.clean.json" if drop_noise
        else "kernel_events.normalized.json"
    )

    for p in (pg_path, kernel_path, sync_path):
        if not p.exists():
            print(f"ERROR: missing required file {p}", file=sys.stderr)
            sys.exit(1)

    with open(sync_path) as f:
        boot_unix = json.load(f)["server_boot_unix_time"]

    print(f"[1/3] Loading Postgres backend PIDs from {pg_path.name} ...")
    pg_pids = load_pg_backend_pids(pg_path)
    print(f"      -> {len(pg_pids)} distinct backend PIDs")

    print(f"[2/3] Building pid->ppid map from {kernel_path.name} ...")
    ppid_map = build_ppid_map(kernel_path)
    print(f"      -> {len(ppid_map)} distinct kernel PIDs observed")

    # Cache resolution per pid so we don't re-walk the chain per event.
    resolution_cache = {}

    def get_session(pid):
        if pid not in resolution_cache:
            resolution_cache[pid] = resolve_session(pid, pg_pids, ppid_map)
        return resolution_cache[pid]

    print(f"[3/3] Rewriting {kernel_path.name} -> {out_path.name} ...")
    total = 0
    direct = 0
    ancestry = 0
    unresolved_kept = 0
    dropped_noise = 0
    markers = 0

    with open(kernel_path) as fin, open(out_path, "w") as fout:
        for line in fin:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            if "marker" in event:
                # Marker lines are already Unix epoch floats -- pass through
                # unchanged, just note it for the summary.
                markers += 1
                fout.write(json.dumps(event) + "\n")
                continue

            total += 1
            ts_ns = event["timestamp"]
            event["timestamp_unix"] = boot_unix + (ts_ns / 1e9)

            pid = event.get("pid")
            session = get_session(pid)
            event["correlated_session_id"] = session

            if session is not None:
                if pid in pg_pids:
                    direct += 1
                else:
                    ancestry += 1
            elif drop_noise and event.get("comm") in NOISE_COMMS:
                dropped_noise += 1
                continue  # skip writing this row entirely
            else:
                unresolved_kept += 1

            fout.write(json.dumps(event) + "\n")

    print("\n--- Summary ---")
    print(f"Marker lines passed through:              {markers}")
    print(f"Kernel events processed:                  {total}")
    print(f"  matched a backend PID directly:         {direct}")
    print(f"  matched via ppid ancestry walk:         {ancestry}")
    print(f"  unresolved but kept (workload-related): {unresolved_kept}")
    if drop_noise:
        print(f"  dropped as confirmed host noise:        {dropped_noise}")
    print(f"\nWrote {out_path}")


if __name__ == "__main__":
    args = sys.argv[1:]
    drop_noise = "--drop-noise" in args
    args = [a for a in args if a != "--drop-noise"]
    if len(args) != 1:
        print(
            f"usage: {sys.argv[0]} <run_dir> [--drop-noise]",
            file=sys.stderr,
        )
        sys.exit(1)
    normalize(args[0], drop_noise=drop_noise)