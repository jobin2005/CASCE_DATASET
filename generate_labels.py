#!/usr/bin/env python3
import json
import csv

def generate_labels():
    print("Generating labels from postgres_events.json...")
    labels = {}
    
    # Attack signature keywords based on our scripts
    attack_signatures = {
        "COPY (SELECT * FROM pgbench_accounts": "Data Exfiltration",
        "DROP TABLE IF EXISTS pgbench_history": "Sabotage",
        "CREATE ROLE hacker": "Privilege Escalation",
        "UPDATE pgbench_tellers SET tbalance": "Privilege Abuse",
        "/dev/tcp/": "Reverse Shell"
    }

    try:
        with open("/dataset_workspace/postgres_events.json", "r") as f:
            for line in f:
                try:
                    event = json.loads(line)
                    session_id = event.get("session_id")
                    query = event.get("query", "")
                    
                    # If not already marked as an attack in our dictionary
                    if session_id not in labels or labels[session_id] == "Normal":
                        labels[session_id] = "Normal"
                        for sig, label in attack_signatures.items():
                            if sig in query:
                                labels[session_id] = label
                                break
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        print("postgres_events.json not found! Ensure Phase 3 & 4 ran successfully.")
        return

    with open("/dataset_workspace/labels.csv", "w", newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["session_id", "label"])
        for sid, label in labels.items():
            writer.writerow([sid, label])
            
    print(f"Generated labels.csv for {len(labels)} unique sessions.")

if __name__ == '__main__':
    generate_labels()
