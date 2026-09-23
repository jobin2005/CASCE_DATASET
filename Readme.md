# CASCE Dataset Pipeline -- Setup & Operation Guide

This covers the whole pipeline as it stands now: the multi-domain Postgres
databases, the Postgres telemetry extension, and the kernel+Postgres
logger/processor pair that turns live database activity into session graphs.

## 0. Project layout (what lives where)

```
.
├── Dockerfile, docker-compose.yml, init-all-dbs.sh   # the 4 sample databases (see step 1)
├── dbs/{banking,ecommerce,healthcare,logistics}/     # schema.sql + seed_data + query templates
├── algorithms/                                       # Algorithm 1 + 2, unmodified, imported by processor.py
│   ├── algorithm_1.py, algorithm_2.py, graphsops.py, loader.py, schema.py, sqlfacts.py
└── logger/
    ├── casce_ipc.py, processor.py, logger.sh
    ├── kernel/
    │   ├── kernel_telemetry.py      # eBPF program definition (imported by sensor.py)
    │   └── sensor.py                # what logger.sh actually launches
    └── postgres/
        ├── pg_telemetry.c           # the extension, with the Disconnect hook
        └── Makefile, pg_telemetry.control, pg_telemetry--1.0.sql   # added -- see note below
```

**Note on what changed in this delivery:** `logger/postgres/` had `pg_telemetry.c`
but no `Makefile`/`.control`/`--1.0.sql` next to it, so it couldn't build. I
added the three missing files there (identical to the extension's original
build files, just relocated). Nothing else changed from what you already had.

## 1. Important: two separate things need to be running, on different machines (or at least differently privileged)

- **The Postgres server(s)** you're going to generate traffic against —
  these come from `docker-compose.yml` at the project root (the
  `banking`/`ecommerce`/`healthcare`/`logistics` databases).
- **The logger + processor** — these need to run wherever the *actual*
  Postgres server process lives, with root/kernel access, because eBPF
  traces real kernel syscalls and the extension hooks into a real running
  `postgres` backend.

**This matters because of a real constraint:** the eBPF kernel tracer in
`sensor.py` cannot see inside an ordinary Docker container's isolated
kernel view, and `pg_telemetry.c` has to be installed into the exact
Postgres binary that's actually running. Concretely, you have two honest
options:

- **(A) Run Postgres natively on a Linux host** (not in Docker) for the
  machine you intend to trace, and run `logger/` there too. This is the
  simplest, most reliable setup for dataset generation, and is what the
  extension build steps below assume.
- **(B) Trace the Dockerized Postgres container** — only if you start that
  container with `--privileged`, `--pid=host`, and bind-mount
  `/sys/kernel/debug` and `/lib/modules` from the host into it (bcc/eBPF
  needs these). This is more fragile and generally not recommended unless
  you specifically need the containerized setup for other reasons.

Everything below assumes option (A): Postgres and `logger/` running on the
same real Linux host, as root (eBPF requires it).

## 2. One-time setup

```bash
# System dependencies (Debian/Ubuntu example)
sudo apt install postgresql-server-dev-16 python3-bpfcc bpfcc-tools
pip3 install networkx pglast

# Runtime workspace -- this is where all logs, sockets, and graphs live.
# It is NOT the Postgres data directory.
sudo mkdir -p /dataset_workspace
sudo chown "$USER" /dataset_workspace
```

## 3. Build & install the Postgres extension

```bash
cd logger/postgres
make clean && make && sudo make install
```

Then enable it. Easiest is via `shared_preload_libraries` (needed either
way, since the extension hooks executor/utility internals):

```
# in postgresql.conf
shared_preload_libraries = 'pg_telemetry'
```

Restart Postgres, then, once per database you want traced:

```sql
CREATE EXTENSION pg_telemetry;
```

**Rebuilding later** (e.g. if you change `pg_telemetry.c` again) always
needs `make && sudo make install` followed by a full Postgres restart —
the hooks (including the new `on_proc_exit` Disconnect hook) are registered
when the shared library loads, so a config reload alone isn't enough.

## 4. Creating the sample databases

This part is unrelated to the logger and can be done independently, on the
Postgres instance you're going to trace (native, per step 1) rather than
the separate `docker-compose.yml`-based container, *if* you're tracing a
native install. If you're only exploring the sample data without tracing
anything, the Docker route from `docker-compose.yml` works standalone:

```bash
docker compose up --build -d
```

This creates four databases -- `banking`, `ecommerce`, `healthcare`,
`logistics` -- each fully seeded from `dbs/<domain>/seed_data/*.csv`. See
"Which databases, which queries" below for what's actually available in
each.

If you're tracing a **native** Postgres install instead, run
`dbs/<domain>/schema.sql` and load the matching CSVs into that instance
directly (`psql -f schema.sql`, then `\copy <table> from '<csv>' csv
header` per table, in the order tables are declared in `schema.sql` so
foreign keys resolve).

## 5. Starting the pipeline

Order: **processor first**, then the logger. (Not strictly required --
`sensor.py` retries its connection to the processor every ~2 seconds -- but
starting the processor first means nothing goes to the disk fallback files
during that initial gap.)

```bash
# Terminal 1: the graph-building process (Algorithm 1 + 2)
cd logger
sudo python3 processor.py
```

You'll see:
```
[processor] listening on /dataset_workspace/.casce_pipeline.sock
```

```bash
# Terminal 2: start capturing
cd logger
sudo ./logger.sh start
```

You'll see:
```
Starting kernel eBPF tracer...
Logging ACTIVE.
  Kernel events   -> /dataset_workspace/kernel_events.json
  Postgres events -> /dataset_workspace/postgres_events.json
You can now psql in as any user and every action will be captured.
```

And in the processor's terminal:
```
[processor] sensor connected (...)
```

If that connected line **doesn't** appear, the processor isn't reachable
and `sensor.py` is silently falling back to disk for kernel events (this is
by design -- see the pipeline README for exactly what falls back and what
doesn't). Check `/dataset_workspace/.kernel_tracer.log` and the processor's
own terminal for errors.

## 6. Which databases, and which queries, actually get recorded

**Any database on the traced Postgres instance where you ran
`CREATE EXTENSION pg_telemetry;`** -- that's the only thing that gates
recording at the database level. If you created all four sample databases
and want all four traced, run `CREATE EXTENSION pg_telemetry;` in each one
individually (extensions are per-database in Postgres).

**Any query at all is recorded**, once logging is active (`logger.sh
start` has been run) and you're connected to a database with the extension
enabled -- there's no query allow-list. The extension hooks
`ExecutorStart`/`ExecutorEnd` (covers `SELECT`/`INSERT`/`UPDATE`/`DELETE`)
and `ProcessUtility` (covers `COPY`, `CREATE ROLE`, `DROP`, and other
utility statements), so ordinary application queries and the "attack"
template queries under `dbs/<domain>/templates/` are captured identically.

**When it's actually being recorded:** strictly between `logger.sh start`
and `logger.sh stop`. The extension checks for the
`/dataset_workspace/.casce_logging_active` flag file on every single query
(`log_casce_event`'s very first real check) -- if that flag file isn't
there, nothing is written, full stop, even if the extension is loaded and
enabled on that database. So:

```bash
./logger.sh status     # tells you if logging is currently active
./logger.sh start       # begin recording
# ... run your benign/attack query templates, psql sessions, app traffic ...
./logger.sh stop        # stop recording
```

**The `templates/attack/*.yaml` and `templates/benign/*.yaml` files** are
just lists of SQL statements under a `commands:` key -- they aren't run
automatically by anything in this pipeline. You (or a separate driver
script you write) execute those `commands:` entries against the relevant
database with `psql` while logging is active, the same as any other query.
Use `logger.sh mark_attack <name> start` / `... end` around a run of an
attack template if you want that window explicitly marked in the raw logs.

**A session's graph is only written to disk when that session actually
ends** -- i.e. when you disconnect that `psql` session (or your
application closes its connection), which fires the extension's
`on_proc_exit` hook and tells `processor.py` to finalize and save that
session's graph. Output lands in:

```
/dataset_workspace/live_graphs/
  live_<UTC timestamp>_session_<backend_pid>.json
  manifest.jsonl
```

If you kill `processor.py` (Ctrl-C or `SIGTERM`) while sessions are still
open, it flushes all of them before exiting, tagged
`"reason": "processor_shutdown"` in `manifest.jsonl` so you can tell those
apart from naturally-closed sessions later.

## 7. Stopping everything

```bash
./logger.sh stop              # stops the kernel tracer; extension goes quiet
                               # (flag file removed) even without a Postgres restart
# Ctrl-C (or `kill -TERM <pid>`) the processor.py terminal
```

`logger.sh stop` does **not** need Postgres to restart -- the logging flag
file is exactly what lets you toggle recording on/off without touching the
running server.

## 8. Quick end-to-end sanity check

```bash
# terminal 1
sudo python3 logger/processor.py

# terminal 2
sudo ./logger/logger.sh start
psql -h localhost -U admin -d banking -c "CREATE EXTENSION IF NOT EXISTS pg_telemetry;"
psql -h localhost -U admin -d banking -c "SELECT * FROM branches LIMIT 3;"
# exit that psql session (or run it non-interactively as above, which
# disconnects immediately after the query) to trigger the Disconnect hook
./logger/logger.sh stop
```

Check `/dataset_workspace/live_graphs/manifest.jsonl` -- you should see one
row for that session, with a nonzero `node_count`.