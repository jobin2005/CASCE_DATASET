# CASCE Dataset Generator Pipeline

This repository hosts the official raw dataset generator for the Context-Aware Semantic Correlation Engine (CASCE). The pipeline is designed to cross-correlate high-level PostgreSQL database semantics with low-level Linux Kernel eBPF traces to capture advanced threat heuristics.

## Features
- **PostgreSQL Extension (`pg_telemetry`)**: A raw hook injection capturing comprehensive query and session data (Executor Start, Run, Finish, End).
- **eBPF Kernel Collector (`kernel_telemetry.py`)**: BCC-enabled tracing over specific syscall execution paths (`execve`, `openat`, `socket`).
- **Simulated Workloads**: Pre-built native attack signatures using TPC-B to ensure standard benchmark integration without outside dependencies.
- **Dataset Validator**: Algorithmic pipeline to cross-verify and merge the PID namespace contexts between the container application framework and global OS kernel namespaces.

## Getting Started

### 1. Environment Build
Launch the system with docker-compose. Due to kernel tracing, it must be run with `privileged=true` and `pid=host` to merge process namespaces.

```bash
docker-compose up -d --build
docker exec -it --user root casce_environment bash
```

### 2. Dependency Initialization
Inside the container, compile the native PostgreSQL C extension:

```bash
cd pg_telemetry_extension
make clean && make && make install
cd ..
./setup_db.sh
psql -U postgres -d casce_tpcb -c "CREATE EXTENSION pg_telemetry;"
psql -U postgres -d casce_tpcb -c "ALTER DATABASE casce_tpcb SET session_preload_libraries = 'pg_telemetry';"
```

### 3. Generate Dataset
```bash
# 1. Start the Background dual-logger
./collector.py &

# 2. Run the deterministic testing profiles
./normal_workload.sh
./attack_workload/attack_exfiltration.sh
./attack_workload/attack_sabotage.sh
./attack_workload/attack_privilege_abuse.sh
./attack_workload/attack_reverse_shell.sh

# 3. Pull logger to foreground and cancel
fg 
# -> Press Ctrl+C

# 4. Generate the final validation labels
./generate_labels.py
./dataset_validator.py
./freeze_dataset.sh
```

A clean, compressed dataset tarball will be produced safely packaged for machine learning evaluation.
