#!/usr/bin/env python3
"""
run_schedule.py <schedule.json> [dbname]
Replays {t, type, label, cmd} steps at real wall-clock offsets.

Steps with a "parallel_group" field are launched concurrently via Popen()
and waited on as a batch before the next sequential step runs.
Steps without "parallel_group" run sequentially via subprocess.run().
"""
import sys
import json
import time
import subprocess
from collections import defaultdict


def _flush_pending(pending_groups):
    """Wait for all processes in all pending parallel groups."""
    for grp, procs in pending_groups.items():
        for p in procs:
            rc = p.wait()
            if rc != 0:
                print(f"  [parallel_group={grp}] process exited with code {rc}",
                      file=sys.stderr)
    pending_groups.clear()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    schedule_path = sys.argv[1]
    dbname = sys.argv[2] if len(sys.argv) > 2 else "casce_sample"

    with open(schedule_path) as f:
        schedule = json.load(f)

    t0 = time.time()
    pending_groups = defaultdict(list)   # group_name -> [Popen]

    for step in schedule:
        target = t0 + step["t"]
        delay = target - time.time()
        if delay > 0:
            time.sleep(delay)

        group = step.get("parallel_group")

        print(f"[t={step['t']:>4}s][{step['label']}] {step['cmd']}")
        if step["type"] == "sql":
            cmd = ["psql", "-U", "postgres", "-d", dbname, "-c", step["cmd"]]
            use_shell = False
        elif step["type"] == "shell":
            cmd = step["cmd"]
            use_shell = True
        else:
            print(f"  unknown step type '{step['type']}', skipping",
                  file=sys.stderr)
            continue

        if group:
            # Non-blocking: launch and track in the parallel group
            proc = subprocess.Popen(cmd, shell=use_shell)
            pending_groups[group].append(proc)
        else:
            # Sequential: flush any pending parallel groups first, then block
            _flush_pending(pending_groups)
            subprocess.run(cmd, shell=use_shell)

    # Wait for any remaining parallel groups
    _flush_pending(pending_groups)

    print("Schedule complete.")


if __name__ == "__main__":
    main()

# --- Note on "fast-forwarding" time ---
# Runs in real time on purpose. faketime can accelerate Postgres's wall
# clock, but eBPF's bpf_ktime_get_ns() timestamps aren't affected by it,
# so the two streams drift apart unless you record and reapply the
# clock offset in dataset_validator.py. See earlier discussion for detail.