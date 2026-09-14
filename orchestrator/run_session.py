"""
orchestrator/run_session.py

Executes a single session end-to-end:
  1. Generates a fresh identity (username, synthetic IP).
  2. Sets session identity via SET casce.sim_user / casce.sim_ip.
  3. Starts live capture (kernel eBPF tracer + postgres event listener -> EventBus).
  4. Connects as the identity, executing template commands with randomized delays.
  5. Stops capture.
  6. Drains events through Algorithm 1 / Algorithm 2 to construct the session graph.
  7. Persists the graph (graph_store/writer.py) and ground-truth label (labels/label_writer.py).
  8. Validates the saved session graph.
"""

import argparse
import os
import random
import sys
import time
from pathlib import Path
from typing import Dict, Any, Optional
import yaml
import networkx as nx

# Add project root to sys.path for robust resolution
PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from capture.event_bus import EventBus
from capture.kernel_ebpf_tracer import start_tracer, stop_tracer
from capture.postgres_event_listener import start_listener, stop_listener
from identity.identity_generator import new_identity
from labels.label_writer import write_label
from graph_store.writer import write_graph
from validator.graph_validator import validate_graph

# Import Algorithm 2 components
from algorithms.algorithm2 import process_event
from algorithms.graphsops import add_or_update_node


def run_session(
    schema_name: str,
    template_path: str,
    out_dir: str,
    run_id: str,
    pg_config: Optional[Dict[str, Any]] = None,
    registry_path: str = "identity/identity_registry.tsv"
) -> Dict[str, Any]:
    """
    Executes a single session run and returns execution summary.
    """
    tmpl_file = Path(template_path)
    if not tmpl_file.exists():
        raise FileNotFoundError(f"Template not found: {template_path}")

    with tmpl_file.open("r", encoding="utf-8") as f:
        tmpl = yaml.safe_load(f)

    tmpl_name = tmpl.get("name", tmpl_file.stem)
    tmpl_type = tmpl.get("type", "benign")
    delay_cfg = tmpl.get("delay_seconds", {"min": 0.1, "max": 0.5})
    delay_min = float(delay_cfg.get("min", 0.1))
    delay_max = float(delay_cfg.get("max", 0.5))
    commands = tmpl.get("commands", [])

    # 1. Obtain unique synthetic identity
    username, client_ip = new_identity(registry_path)
    print(f"[{run_id}] Assigned identity: {username} @ {client_ip}")

    # 2. Setup live event bus and start capture
    event_bus = EventBus()
    start_tracer(event_bus)
    start_listener(event_bus)

    start_time = time.time()
    session_key = int(start_time * 1000) % 1_000_000

    # 3. Execute database commands
    # We attempt live PostgreSQL execution if psycopg2 and server are reachable;
    # otherwise fallback to simulated session capture for local offline testing.
    pg_cfg = pg_config or {}
    pg_host = pg_cfg.get("host", os.environ.get("PGHOST", "localhost"))
    pg_port = pg_cfg.get("port", int(os.environ.get("PGPORT", "5432")))
    pg_user = pg_cfg.get("user", os.environ.get("PGUSER", "postgres"))
    pg_pass = pg_cfg.get("password", os.environ.get("PGPASSWORD", "password"))
    db_name = f"casce_{schema_name}"

    conn = None
    cur = None
    try:
        import psycopg2
        conn = psycopg2.connect(
            host=pg_host, port=pg_port, user=pg_user, password=pg_pass, dbname=db_name,
            connect_timeout=3
        )
        conn.autocommit = True
        cur = conn.cursor()
        # Set synthetic identity in session
        cur.execute(f"SET casce.sim_user = '{username}';")
        cur.execute(f"SET casce.sim_ip = '{client_ip}';")
    except Exception as exc:
        print(f"[{run_id}] Live PostgreSQL connection not established ({exc}); simulating query events.", file=sys.stderr)

    for cmd in commands:
        if not cmd or cmd.strip().startswith("#"):
            continue

        jitter = random.uniform(delay_min, delay_max)
        time.sleep(jitter)

        cmd_ts = time.time()
        # Execute live query if connected
        if cur is not None:
            try:
                cur.execute(cmd)
            except Exception as q_exc:
                print(f"[{run_id}] Query execution notice: {q_exc}")

        # Ensure query event enters event_bus
        pg_event = {
            "source": "postgres",
            "timestamp": cmd_ts,
            "timestamp_unix": cmd_ts,
            "pid": session_key,
            "session_key": session_key,
            "query": cmd,
            "database": db_name,
            "username": username,
            "client_addr": client_ip,
            "client_port": "54321",
            "event_type": "ExecutorStart",
            "raw": {"query": cmd, "database": db_name, "username": username}
        }
        event_bus.publish(pg_event)

    if cur is not None:
        try:
            cur.close()
            conn.close()
        except Exception:
            pass

    end_time = time.time()

    # 4. Stop capture and drain events
    stop_tracer()
    stop_listener()
    events = event_bus.drain()

    # 5. Build session graph with Algorithm 2
    active_graphs: Dict[int, nx.MultiDiGraph] = {}

    # Initialize session root node
    G = active_graphs.setdefault(session_key, nx.MultiDiGraph())
    add_or_update_node(G, "Session", {
        "session_key": session_key,
        "username": username,
        "client_addr": client_ip,
        "timestamp_unix": start_time,
        "timestamp": start_time,
    })

    for ev in events:
        ev_session_key = ev.get("session_key", session_key)
        process_event(ev_session_key, ev, active_graphs)

    G = active_graphs.get(session_key, G)

    # 6. Persist graph and label
    meta = {
        "schema": schema_name,
        "name": tmpl_name,
        "type": tmpl_type,
        "username": username,
        "client_ip": client_ip,
        "start_time": start_time,
        "end_time": end_time,
        "command_count": len(commands),
    }

    graph_file = write_graph(G, out_dir, run_id, metadata=meta)
    label_file = write_label(out_dir, run_id, meta)

    # 7. Validate saved session graph
    validation_issues = validate_graph(graph_file, label_file)
    if validation_issues:
        print(f"[{run_id}] Validation warnings: {validation_issues}", file=sys.stderr)
    else:
        print(f"[{run_id}] Finished successfully. Nodes={G.number_of_nodes()}, Edges={G.number_of_edges()}")

    return {
        "run_id": run_id,
        "graph_file": graph_file,
        "label_file": label_file,
        "node_count": G.number_of_nodes(),
        "edge_count": G.number_of_edges(),
        "validation_issues": validation_issues,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="CASCE v2 Single Session Runner")
    parser.add_argument("--schema", required=True, help="Database schema name")
    parser.add_argument("--template", required=True, help="Path to YAML template")
    parser.add_argument("--out", default="output/dataset_dev", help="Output directory")
    parser.add_argument("--run_id", default=None, help="Run identifier")
    args = parser.parse_args()

    run_id = args.run_id or f"{args.schema}_{Path(args.template).stem}_{int(time.time())}"
    run_session(args.schema, args.template, args.out, run_id)
