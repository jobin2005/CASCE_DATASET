# Dataset Generation Pipeline Plan

This plan aims to automate the dataset generation pipeline for the CASCE (Context-Aware Semantic Correlation Engine) research project, following the explicit steps provided.

## Proposed Changes

We will create a set of scripts and C/eBPF code inside `/home/jobin/Desktop/Mini Project_Reserach/Dataset/`.

### Phase 1: Environment Build & Database Import
#### [NEW] `docker-compose.yml`
Setup PostgreSQL 18.4 database along with necessary dependencies (LLVM, Clang, libbpf, bpftool) on Ubuntu 24.04.

#### [NEW] `setup_db.sh`
Import a realistic relational database (e.g., DVD Rental or TPC-C/TPC-H). This operational database will serve as the foundation for the dataset.

### Phase 2: Telemetry Framework
#### [NEW] `pg_telemetry_extension/`
A custom PostgreSQL C extension utilizing hooks (`ExecutorStart_hook`, `ExecutorRun_hook`, `ExecutorFinish_hook`, `ExecutorEnd_hook`, `ProcessUtility_hook`) to capture: Session ID, Backend PID, Database, Username, SQL Query, Command Type, Relations Accessed, Transaction ID, and Timestamp. This will output the pure PostgreSQL Event Stream.

#### [NEW] `ebpf_telemetry/`
Advanced eBPF C programs (using libbpf/BCC) attaching to tracepoints, kprobes, and optionally LSM hooks to capture: PID, Parent PID, and syscalls (`execve`, `fork`, `clone`, `open`, `read`, `write`, `rename`, `unlink`, `connect`, `accept`, `send`, `recv`). This outputs the Kernel Event Stream. *This will demonstrate complex eBPF programming.*

#### [NEW] `collector.py`
A central collector script that receives events from both the PostgreSQL Extension and eBPF programs, storing them separately as `postgres_events.json` and `kernel_events.json`. (Note: No correlation, no graphs, no AI at this stage).

### Phase 3: Normal Workload
#### [NEW] `normal_workload.sh`
Simulate a realistic normal workload using `pgbench` or Python clients over the imported DB schema, generating 100,000+ queries across ~100 virtual users (SELECT, INSERT, UPDATE, DELETE, JOINs). 

### Phase 4: Attack Workload
#### [NEW] `attack_workload/`
Standardized attack simulation scripts, backed by standard attack documentation:
1. **Data Exfiltration**: Sensitive SELECT -> COPY TO PROGRAM -> gzip -> curl
2. **Sabotage**: DROP TABLE
3. **Privilege Escalation**: CREATE ROLE hacker; 
4. **Privilege Abuse**: Using excessive privileges.
5. **Reverse Shell**: Shell spawned from DB context.

*Note: Future additional scenarios will be added once these core attacks are stable.*

### Phase 5 & 6: Labeling & Validation
#### [NEW] `dataset_validator.py`
Validate that `postgres_events.json` has PID, Session, Query; `kernel_events.json` has PID and Timestamp; and Backend PIDs exist in both streams. 

#### [NEW] `generate_labels.py`
Since attacks are executed predictably by our scripts, this script maps the known malicious Sessions to generate `labels.csv` (e.g., Session 61 -> Data Exfiltration).

### Phase 7: Dataset Freeze
#### [NEW] `freeze_dataset.sh`
Pack all artifacts into a final frozen dataset directory. 
**Expected Final Output**:
A frozen `dataset/` directory containing:
* `postgres_events.json` (Postgres query context)
* `kernel_events.json` (Kernel OS events)
* `labels.csv` (Mapping of Session -> Attack/Normal)
* `attack_scripts/` (The scripts used to generate the dataset)
* `README.md` (Detailed usage and description)

## Verification Plan

### Manual Verification
* The user will run the setup scripts and workload drivers. The resulting `dataset/` directory will be manually reviewed to confirm it meets the standard dataset requirements without containing any correlation/graph AI logic (which belongs to a later AI phase).
