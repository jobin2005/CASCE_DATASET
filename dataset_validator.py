#!/usr/bin/env python3
import json

def validate_dataset():
    print("Validating dataset integrity across Phase 1-5 artifacts...")
    
    pg_valid = True
    pg_pids = set()
    
    # 1. Validate PostgreSQL events
    print("Checking postgres_events.json...")
    try:
        with open("/dataset_workspace/postgres_events.json", "r") as f:
            for i, line in enumerate(f):
                event = json.loads(line)
                if not all(k in event for k in ("session_id", "backend_pid", "query", "timestamp")):
                    print(f"Malformed PG event at line {i+1}")
                    pg_valid = False
                pg_pids.add(event.get("backend_pid"))
    except FileNotFoundError:
        print("postgres_events.json missing.")
        return
        
    print(f"-> postgres_events.json passed structural checks. Extracted {len(pg_pids)} backend PIDs.")

    kernel_valid = True
    kernel_pids = set()
    
    # 2. Validate Kernel events
    print("Checking kernel_events.json...")
    try:
        with open("/dataset_workspace/kernel_events.json", "r") as f:
            for i, line in enumerate(f):
                event = json.loads(line)
                if not all(k in event for k in ("pid", "timestamp")):
                    print(f"Malformed Kernel event at line {i+1}")
                    kernel_valid = False
                kernel_pids.add(event.get("pid"))
                kernel_pids.add(event.get("ppid"))
    except FileNotFoundError:
        print("kernel_events.json missing.")
        return
        
    print(f"-> kernel_events.json passed structural checks.")

    # 3. Correlate PID presence
    print("Verifying if Backend PIDs exist in kernel streams (Algorithm 1 prerequisite)...")
    overlap = pg_pids.intersection(kernel_pids)
    if not overlap:
        print("WARNING: Zero backend PIDs found in kernel events stream. Is eBPF tracer running?")
    else:
        print(f"SUCCESS: {len(overlap)} backend PIDs successfully traced in kernel logs!")

    if pg_valid and kernel_valid and len(overlap) > 0:
        print("VALIDATION SUCCESSFUL. Dataset is ready to freeze.")
    else:
        print("VALIDATION FAILED OR INCOMPLETE.")

if __name__ == '__main__':
    validate_dataset()
