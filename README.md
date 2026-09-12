# CASCE Dataset Generator Pipeline

This repository hosts the raw dataset generator for the Context-Aware Semantic
Correlation Engine (CASCE). It cross-correlates high-level PostgreSQL
database semantics with low-level Linux kernel eBPF traces to build a
labeled dataset for training threat-detection models.

## Features
- **PostgreSQL Extension (`pg_telemetry`)** — hooks into the query executor
  (`ExecutorStart/Run/Finish/End`, `ProcessUtility`) to capture session,
  query, and timing data.
- **eBPF Kernel Collector (`kernel_telemetry.py`)** — BCC-based tracing of
  syscalls (`execve`, `openat`, `connect`, etc.).
- **Toggleable dual-plane logger (`logger.sh`)** — start/stop logging on
  both planes at will, independent of any single session.
- **Simulated workloads** — pgbench/TPC-B traffic, a generic
  schema-and-seed loader, deterministic attack scripts, and a
  timestamp-driven benign/malicious replay script.
- **Labeling & validation** — deterministic attack timing maps to ground
  truth labels; a validator cross-checks PID alignment between streams.

---

## 0. Prerequisites (fresh Ubuntu install)

This assumes you've just installed Ubuntu (22.04/24.04) and have a
terminal open. You need Docker + Docker Compose, and nothing else on the
host — everything else (Postgres, the eBPF toolchain, etc.) lives inside
the container.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git

# Install Docker Engine + Compose plugin (official Docker repo)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Let your user run docker without sudo (log out/in afterward for this to apply)
sudo usermod -aG docker "$USER"
```

Log out and back in (or run `newgrp docker`) so the group change takes
effect, then confirm Docker works:

```bash
docker run hello-world
```

**eBPF check (host kernel, not the container):** the container's eBPF
tracer needs BTF info from the *host* kernel it's running on. Confirm it
exists before going further:

```bash
ls /sys/kernel/btf/vmlinux
```

If that file is missing, eBPF tracing won't load correctly — most stock
Ubuntu 22.04+ kernels have this by default, but it's worth checking once
up front rather than debugging it later.

---

## 1. Clone the repository

```bash
git clone <your-repo-url> CASCE_DATASET
cd CASCE_DATASET
```

---

## 2. Build & Launch the Environment

```bash
docker compose up -d
```

This builds the Ubuntu 24.04 + PostgreSQL 17 + eBPF-toolchain image and
starts the container (`privileged: true`, `pid: host` so kernel PIDs line
up with Postgres backend PIDs), then waits until Postgres reports ready.

Enter the container for everything from here on:

```bash
docker exec -it --user root casce_environment bash
cd /dataset_workspace
```

---

## 3. Compile the eBPF Telemetry Extension
Before generating datasets, you must compile the C-based PostgreSQL hooking extension locally inside the container so it matches your exact kernel architecture.

```bash
cd pg_telemetry_extension
make USE_PGXS=1 clean && make USE_PGXS=1 && make USE_PGXS=1 install
cd ..
```

---

## 4. Run the Automated Master Orchestrator
You **do not** need to manually build databases, configure schemas, or start the trackers. We built a master orchestrator (`generate_eval_datasets.sh`) that automates the entire lifecycle!

```bash
chmod +x generate_eval_datasets.sh
./generate_eval_datasets.sh
```

This single script will autonomously:
1. Initialize the TPC-B Banking Benchmarks.
2. Arm the eBPF Telemetry modules.
3. Simulate thousands of background transactions mixed directly with 10+ polymorphic attack patterns.
4. Seamlessly tear down and repackage the environment iteratively for mathematically independent Dev & Test variants.

---

## 5. The Outputs Obtained

Running the generation script will create two rigorous Dataset artifacts that satisfy strict academic baselines:

- **`dataset_dev/`** (Contains `run_1`, `run_2`, `run_3`) — Dedicated purely for model tuning, threshold adjusting (e.g., configuring optimal $D_{max}$ depth), and running internal Ablation testing across the 4 CASCE Methodology algorithms. 
- **`dataset_test/`** (Contains `run_1`, `run_2`, `run_3`) — The strictly held-out testing partitions. You must only evaluate Sreedeep's final GAT ML detection on this folder once everything is locked.

Inside each `run_X/` folder, the 3 Golden Artifacts are generated:
- `postgres_events.json`: High-level Semantics.
- `kernel_events.json`: Low-level eBPF traces (with dynamically resolved string `syscall` types linked at the C boundary).
- `labels.csv`: The ground truth bounds.

## Simulated attacker identities & timing

Every script under `attack_workload/` is now a small template rather than a
fixed one-shot command:

- `attack_workload/_identity_lib.sh` hands each attack run a random
  synthetic username and a random private-range IP (`10.x.x.x`,
  `172.16-31.x.x`, `192.168.x.x`), and guarantees — via a persistent,
  `flock`-protected registry file (`.casce_identity_registry.tsv`) — that no
  two attack instances in the whole dataset-generation run ever share a
  username or an IP, even when scripts run concurrently in the background.
- That identity is threaded into the actual telemetry: each `psql` call is
  prefixed with `SET casce.sim_user = '...'; SET casce.sim_ip = '...';`,
  which the `pg_telemetry` extension now reads (see the `casce.sim_user` /
  `casce.sim_ip` custom GUCs in `pg_telemetry.c`) and writes into
  `postgres_events.json` in place of the old PID-derived spoof. **You must
  rebuild the extension** (`make clean && make USE_PGXS=1 && make USE_PGXS=1 install`)
  after pulling this change for the new fields to take effect.
- Multi-statement attacks (`attack_sqli_time.sh`, `attack_multi_stage_apt.sh`,
  `attack_multi_session_apt.sh`, etc.) no longer sleep a fixed number of
  seconds between commands — `casce_random_delay MIN MAX` picks a random
  float in that range each time, so inter-command timing varies run to run.
- To add more SQL commands to a template, just extend its `SQL_COMMANDS`
  array; each will run under the same session identity with a randomized
  delay after it.

## Troubleshooting quick reference

| Symptom | Likely cause |
|---|---|
| `logger.sh start` exits immediately, kernel tracer fails | Check `/dataset_workspace/.kernel_tracer.log`; usually a missing BTF/capability issue — confirm `/sys/kernel/btf/vmlinux` exists on the host |
| `postgres_events.json` stays empty while logging is active | Extension not rebuilt after pulling the flag-file change — re-run `make clean && make && make install` |
| `dataset_validator.py` reports zero PID overlap | The kernel tracer wasn't running during the workload — check `logger.sh status` before generating traffic |
| Permission denied running `docker` commands | You need to log out/in after `usermod -aG docker $USER`, or run with `sudo` in the meantime |