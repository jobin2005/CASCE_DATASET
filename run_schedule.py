#!/usr/bin/env python3
"""
run_schedule.py <schedule.json> [dbname]
Replays {t, type, label, cmd} steps at real wall-clock offsets.
"""
import sys
import json
import time
import subprocess

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    schedule_path = sys.argv[1]
    dbname = sys.argv[2] if len(sys.argv) > 2 else "casce_sample"

    with open(schedule_path) as f:
        schedule = json.load(f)

    t0 = time.time()
    for step in schedule:
        target = t0 + step["t"]
        delay = target - time.time()
        if delay > 0:
            time.sleep(delay)

        print(f"[t={step['t']:>4}s][{step['label']}] {step['cmd']}")
        if step["type"] == "sql":
            subprocess.run(["psql", "-U", "postgres", "-d", dbname, "-c", step["cmd"]])
        elif step["type"] == "shell":
            subprocess.run(step["cmd"], shell=True)
        else:
            print(f"  unknown step type '{step['type']}', skipping", file=sys.stderr)

    print("Schedule complete.")

if __name__ == "__main__":
    main()

# --- Note on "fast-forwarding" time ---
# Runs in real time on purpose. faketime can accelerate Postgres's wall
# clock, but eBPF's bpf_ktime_get_ns() timestamps aren't affected by it,
# so the two streams drift apart unless you record and reapply the
# clock offset in dataset_validator.py. See earlier discussion for detail.