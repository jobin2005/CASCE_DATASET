# CASCE v2 — Cyberattack Session-level Causality Engine Dataset Generator

CASCE (Cyberattack Session-level Causality Engine) is a synthetic IDS dataset generator that correlates PostgreSQL query events with Linux kernel eBPF syscall events into **provenance graphs** for each database session. Each session graph is labelled benign or attack and stored as node-link JSON, ready for graph neural network training.

---

## Requirements

### Host (Docker) — Recommended
- Docker ≥ 24 and Docker Compose v2
- A Linux host kernel (eBPF tracepoints are Linux-only)

### Host (native Python) — Development / Dry-run Only
- Python 3.11+
- `pip install pyyaml psycopg2-binary networkx pglast`
- BCC/eBPF (`python3-bpfcc`) requires a Linux privileged environment; on Windows/macOS the tracer falls back to stub mode automatically.
- PostgreSQL 17 accessible at `localhost:5432` (or configure in `config.yaml`)

---

## Quick Start (Docker)

> **Run this inside a Linux host only.** eBPF requires kernel access.

```bash
# 1. Build and start the container (privileged + host PID namespace)
cd docker
docker compose up --build -d

# 2. Enter the container shell
docker exec -it casce_environment bash

# 3. Inside the container — initialize a database schema
./setup_db.sh ecommerce          # ecommerce | banking | healthcare | logistics

# 4. Run the full dataset generation pipeline
python orchestrator/run_all.py

# 5. Outputs land in:
#    output/dataset_dev/   (70% of runs)
#    output/dataset_test/  (30% of runs)
```

---

## Quick Start (Dry-run / Windows)

The pipeline degrades gracefully with no live PostgreSQL or eBPF available — it simulates query events through the graph construction logic and validates the output graphs locally.

```bash
# Run a single template session (no live Postgres needed)
python orchestrator/run_session.py \
  --schema ecommerce \
  --template templates/ecommerce/benign_templates/benign_checkout_flow.yaml \
  --out output/dataset_dev \
  --run_id ecommerce_checkout_run01

# Run the full pipeline (generates graphs for all 4 databases × all templates)
python orchestrator/run_all.py
```

---

## Configuration

All top-level settings are in [`config.yaml`](config.yaml):

```yaml
runs_per_template: 5          # how many session runs per template
dev_test_split: 0.7           # 70% → dataset_dev, 30% → dataset_test

databases:                    # schemas to generate data for
  - ecommerce
  - banking
  - healthcare
  - logistics

postgres:
  host: localhost
  port: 5432
  user: postgres
  password: password
```

---

## Database Setup (`setup_db.sh`)

Drops, recreates, and seeds a `casce_<schema>` PostgreSQL database.

```bash
# Usage
./setup_db.sh <schema_name> [host] [port] [user] [password]

# Examples
./setup_db.sh ecommerce
./setup_db.sh banking  localhost 5433 postgres mypassword
```

Schemas and seed data are loaded from `templates/<schema>/database_schema/schema.sql` and `templates/<schema>/seed_data/`.

---

## Templates Structure

```
templates/
├── ecommerce/
│   ├── database_schema/schema.sql       ← DDL (products, orders, payments, …)
│   ├── seed_data/01_ecommerce_seed.sql  ← INSERT seed rows
│   ├── benign_templates/                ← normal user workflow YAMLs
│   │   ├── benign_browse_catalog.yaml
│   │   ├── benign_checkout_flow.yaml
│   │   └── benign_order_history.yaml
│   └── attack_templates/               ← anomalous diagnostic query YAMLs
│       ├── attack_copy_program_audit.yaml
│       ├── attack_os_priv_escalation_audit.yaml
│       ├── attack_reverse_shell_audit.yaml
│       └── attack_sqli_audit.yaml
├── banking/   (same structure)
├── healthcare/ (same structure)
└── logistics/ (same structure)
```

### Template YAML Format

```yaml
name: ecommerce_checkout_flow
type: benign          # benign | attack
schema: ecommerce
description: >
  One-sentence description of what this session simulates.
delay_seconds:
  min: 0.1            # randomized per-command delay range (seconds)
  max: 0.4
commands:
  - "SELECT * FROM products WHERE product_id = 1;"
  - "INSERT INTO orders ..."
```

To add a new template: create a `.yaml` file in the correct `benign_templates/` or `attack_templates/` directory. `run_all.py` discovers all YAML files automatically.

---

## Architecture Overview

```
                  ┌──────────────┐    ┌─────────────────────────┐
 Linux kernel ──► │ kernel_ebpf  │──► │                         │
 (eBPF probes)    │ _tracer.py   │    │    EventBus              │
                  └──────────────┘    │  (capture/event_bus.py) │
                                      │                         │
 pg_telemetry.c ──► postgres_events ► │   (time-calibrated,     │
 (executor hooks)   .json tail        │    sorted queue)         │
                  └────────────────►  └──────────┬──────────────┘
                                                 │
                                         Algorithm 1 (SAC)
                                    algorithm_1.py  →  session_key
                                                 │
                                         Algorithm 2 (Graph Builder)
                                    algorithm2.py  →  nx.MultiDiGraph
                                                 │
                              ┌──────────────────┴─────────────────┐
                              │  graph_store/writer.py             │
                              │  labels/label_writer.py            │
                              │  validator/graph_validator.py      │
                              └────────────────────────────────────┘
                                    output/<partition>/<run_id>_graph.json
                                    output/<partition>/<run_id>_label.json
```

### Module Reference

| Module | Description |
|--------|-------------|
| `algorithms/algorithm_1.py` | Session-Anchored Correlation (SAC) — maps kernel PIDs to Postgres sessions |
| `algorithms/algorithm2.py` | Builds a `nx.MultiDiGraph` from correlated events |
| `algorithms/graphsops.py` | Node/edge helpers (`add_or_update_node`, `add_directed_edge`, `find_connection_rule`) |
| `algorithms/schema.py` | Node and edge type constants; `NODE_KEY` lambda dictionary |
| `algorithms/sqlfacts.py` | `pglast` SQL parser extracting table names, role changes, COPY…TO PROGRAM facts |
| `algorithms/loader.py` | Joins Algorithm 1 output files into a sorted attributed-event stream |
| `capture/time_sync.py` | Converts raw eBPF nanosecond timestamps to wall-clock unix seconds |
| `capture/event_bus.py` | Thread-safe, calibrated event queue merging kernel and Postgres streams |
| `capture/kernel_ebpf_tracer.py` | BCC eBPF probe attachment; falls back to stub mode if BCC unavailable |
| `capture/postgres_event_listener.py` | Tails `postgres_events.json`; publishes events to EventBus |
| `identity/identity_generator.py` | Generates unique synthetic username + RFC-1918 IP per session |
| `labels/label_writer.py` | Writes `<run_id>_label.json` ground-truth sidecar |
| `graph_store/writer.py` | Serialises session graph to node-link JSON + metadata sidecar |
| `validator/graph_validator.py` | Validates saved graphs: non-empty, single session root, no orphans, valid label |
| `orchestrator/run_session.py` | Runs one session end-to-end |
| `orchestrator/run_all.py` | Outer loop over all schemas × templates × runs; partitions dev/test |
| `setup_db.sh` | Parameterised database recreation and seeding |

---

## pg_telemetry PostgreSQL Extension

The C extension hooks into PostgreSQL's executor to log every query as a JSON line to `postgres_events.json`.

### Build (inside the Docker container)

```bash
cd pg_telemetry_extension
make && make install
```

### Enable in PostgreSQL

```sql
-- As superuser:
CREATE EXTENSION pg_telemetry;

-- Optionally set synthetic identity for a session:
SET casce.sim_user = 'analyst_bob_042';
SET casce.sim_ip   = '10.20.30.44';
```

Logging is gated by the presence of `/dataset_workspace/.casce_logging_active` — created/removed by `setup_db.sh` and `orchestrator/run_session.py` automatically.

---

## Output Format

For each session run two files are written:

### `<run_id>_graph.json`
Node-link JSON (NetworkX `node_link_data` format). Nodes carry `type` (`Session`, `Query`, `Table`, `Process`, `File`, `Endpoint`, `Role`) and attributes. Edges carry `rel` (`executes`, `accesses`, `spawns`, `opens`, `connects_to`), `count`, `first_seen`, `last_seen`.

### `<run_id>_label.json`
```json
{
  "run_id": "ecommerce_benign_checkout_flow_run01_dev",
  "schema_name": "ecommerce",
  "template_name": "ecommerce_checkout_flow",
  "type": "benign",
  "username": "svc_quinn_247",
  "client_ip": "192.168.42.111",
  "start_time": 1757774400.0,
  "end_time": 1757774402.3
}
```

### `<run_id>_metadata.json`
Companion sidecar with node/edge counts and node type distribution.

---

## Graph Validation

```bash
python validator/graph_validator.py \
  output/dataset_dev/ecommerce_run01_graph.json \
  output/dataset_dev/ecommerce_run01_label.json
```

Checks performed:
- Graph is non-empty
- Exactly one `Session` root node
- No disconnected subgraphs (orphan nodes)
- `label.json` exists and has a valid `type` field

---

## Adding a New Database

1. Create `templates/<name>/database_schema/schema.sql` with your DDL.
2. Create `templates/<name>/seed_data/01_<name>_seed.sql` with initial data.
3. Add benign workflow YAMLs to `templates/<name>/benign_templates/`.
4. Add `<name>` to the `databases:` list in `config.yaml`.
5. Run `./setup_db.sh <name>` and then `python orchestrator/run_all.py`.

---

## Project Layout

```
CASCE_DATASET/
├── algorithms/          # Core graph-building algorithms (1 & 2)
├── capture/             # Live telemetry pipeline (eBPF + Postgres)
├── config.yaml          # Global configuration
├── db_schemas/          # Mirror of templates/<schema>/database_schema + seed_data
├── docker/              # Dockerfile, docker-compose.yml, entrypoint.sh
├── graph_store/         # Graph serialisation
├── identity/            # Synthetic identity generator + registry
├── labels/              # Ground-truth label writer
├── orchestrator/        # Session runner and outer pipeline loop
├── output/
│   ├── dataset_dev/     # 70% of generated runs
│   └── dataset_test/    # 30% of generated runs
├── pg_telemetry_extension/  # PostgreSQL C extension (executor hooks)
├── requirements.txt
├── setup_db.sh
├── templates/           # Database schemas, seed data, and session templates
│   ├── ecommerce/
│   ├── banking/
│   ├── healthcare/
│   └── logistics/
└── validator/           # Graph integrity validation
```
