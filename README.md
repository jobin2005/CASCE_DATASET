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

## 2. Step A — Build & launch the environment

```bash
chmod +x build_env.sh
./build_env.sh
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

## 3. Step B — Compile the extension, then create a database

Compile `pg_telemetry` once (needed after any fresh build or after editing
`pg_telemetry.c`):

```bash
cd pg_telemetry_extension
make clean && make && make install
cd ..
```

Then create a database using **one** of these two paths:

**Option 1 — TPC-B benchmark schema** (feeds `normal_workload.sh`'s
pgbench-based traffic):
```bash
chmod +x setup_db.sh
./setup_db.sh
psql -U postgres -d casce_tpcb -c "CREATE EXTENSION pg_telemetry;"
psql -U postgres -d casce_tpcb -c "ALTER DATABASE casce_tpcb SET session_preload_libraries = 'pg_telemetry';"
```

**Option 2 — your own schema + seed data** (generic, arbitrary shape):
```bash
chmod +x setup_sample_db.sh load_seed.py
./setup_sample_db.sh sample_data/schema.sql sample_data/seed_commands.json casce_sample
psql -U postgres -d casce_sample -c "CREATE EXTENSION pg_telemetry;"
psql -U postgres -d casce_sample -c "ALTER DATABASE casce_sample SET session_preload_libraries = 'pg_telemetry';"
```

Swap in your own `schema.sql` / `seed_commands.json` (a flat JSON list of
SQL strings) to use a different dataset shape.

---

## 4. Step C — Start logging (start/stop at will)

```bash
chmod +x logger.sh
./logger.sh start
./logger.sh status
```

This is the toggleable dual-plane logger: it launches the eBPF kernel
tracer as a background process and flips a flag file that
`pg_telemetry.c` checks on every query, so both sides can be started and
stopped independently of any one session.

Once it's running, log in and interact with the database like any normal
user — everything gets captured automatically, no per-session setup
needed:

```bash
psql -U postgres -d casce_sample
```

Stop whenever you're done:

```bash
./logger.sh stop
```

---

## 5. Step D (optional) — Generate workload

Either replay a timestamped benign/malicious schedule:

```bash
chmod +x run_schedule.py
./logger.sh start
./run_schedule.py sample_data/schedule.json casce_sample
./logger.sh stop
```

...or run the original deterministic scripts:

```bash
./logger.sh start
./normal_workload.sh
./attack_workload/attack_exfiltration.sh
./attack_workload/attack_sabotage.sh
./attack_workload/attack_privilege_abuse.sh
./attack_workload/attack_reverse_shell.sh
./logger.sh stop
```

Both run in real wall-clock time by design, so the Postgres and eBPF
timestamps stay on the same clock (see the note at the bottom of
`run_schedule.py` if you want to explore `faketime`-based compression
instead).

---

## 6. Step E — Label, validate, freeze

```bash
./generate_labels.py
./dataset_validator.py
./freeze_dataset.sh
```

A clean, compressed dataset directory (`dataset/`) is produced, containing
`postgres_events.json`, `kernel_events.json`, `labels.csv`, the attack
scripts used, and a generated `README.md` describing the artifacts —
ready for machine learning use.

---

## Troubleshooting quick reference

| Symptom | Likely cause |
|---|---|
| `logger.sh start` exits immediately, kernel tracer fails | Check `/dataset_workspace/.kernel_tracer.log`; usually a missing BTF/capability issue — confirm `/sys/kernel/btf/vmlinux` exists on the host |
| `postgres_events.json` stays empty while logging is active | Extension not rebuilt after pulling the flag-file change — re-run `make clean && make && make install` |
| `dataset_validator.py` reports zero PID overlap | The kernel tracer wasn't running during the workload — check `logger.sh status` before generating traffic |
| Permission denied running `docker` commands | You need to log out/in after `usermod -aG docker $USER`, or run with `sudo` in the meantime |