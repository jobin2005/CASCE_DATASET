#!/bin/bash
echo "Freezing Dataset Artifacts..."

mkdir -p dataset/attack_scripts

# Centralize outputs
if [ -f "postgres_events.json" ]; then cp postgres_events.json dataset/; fi
if [ -f "kernel_events.json" ]; then cp kernel_events.json dataset/; fi
if [ -f "labels.csv" ]; then cp labels.csv dataset/; fi
cp attack_workload/*.sh dataset/attack_scripts/ 2>/dev/null || true

# Generate descriptive README
cat <<EOF > dataset/README.md
# CASCE Cross-Layer PostgreSQL Dataset

## Description
This dataset captures PostgreSQL 18.4 database queries mapped to underlying Linux OS Kernel events via eBPF. 
It contains 100,000+ normal pgbench workload transactions against standard schemas (simulating real-world scenarios), alongside explicit attack simulations.

**Artifacts Generated Without Pre-Correlation / Graph Fusion:**
- \`postgres_events.json\`: Contains Session ID, Backend PID, Database, SQL Query, Event Type, Timestamp.
- \`kernel_events.json\`: Contains PID, Parent PID, Timestamp, Syscall arguments (from eBPF libbpf/BCC).
- \`labels.csv\`: Maps PostgreSQL Session IDs to threat labels mapped from controlled attack timings.
- \`attack_scripts/\`: Shell scripts that were used to insert deterministic malicious sequences into the dataset.

_Algorithm 1 & AI pipeline processing are designed to ingest this frozen baseline._
EOF

echo "Phase 7 Complete! The final, frozen dataset is located in ./dataset/"
