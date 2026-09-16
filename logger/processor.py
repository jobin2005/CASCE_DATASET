#!/usr/bin/env python3
"""
processor.py -- CASCE live Algorithm 1 + Algorithm 2 runner.

Listens on the same Unix socket sensor.py tries to connect to. For every
event received: runs it through Algorithm 1's existing online correlation
function (process_event_with_retry, unmodified, imported directly) to
resolve a session_key, then feeds the resulting attributed event into
Algorithm 2's existing per-session graph builder (process_event,
unmodified, imported directly).

A session's graph is only written to disk when:
  - a Postgres "Disconnect" event closes that session (real client
    disconnect -- see the on_proc_exit hook added to pg_telemetry.c), or
  - this process itself is shutting down (SIGINT/SIGTERM), in which case
    every still-open session is flushed so nothing in progress is lost.

All shared state (active_sessions/parent_map/pending for Algorithm 1,
active_graphs for Algorithm 2) is only ever touched by one worker thread,
even though multiple sensor connections can be accepted concurrently --
each connection's reader thread just decodes lines and pushes them onto a
queue; the single worker thread drains it and does all the real work, so
there's no need for locks around the algorithm state itself.
"""

from __future__ import annotations

import json
import os
import queue
import signal
import socket
import socketserver
import sys
import threading
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict


from casce_ipc import SOCKET_PATH, iter_lines

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "algorithms"))

from algorithm_1 import LogEvent, process_event_with_retry, PENDING_RETRY_WINDOW_SECONDS
from algorithm_2 import process_event as alg2_process_event
import networkx as nx

OUT_DIR = Path("/dataset_workspace/live_graphs")
DISCONNECT_EVENT_TYPES = {"Disconnect"}  # emitted by pg_telemetry.c's on_proc_exit hook

RUN_ID = f"live_{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}"

_event_queue: "queue.Queue[dict]" = queue.Queue()
_stop = threading.Event()


# --------------------------------------------------------------------------
# Socket server: accept connections, decode lines, hand off to the queue
# --------------------------------------------------------------------------

class _Handler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        peer = self.client_address or "sensor"
        print(f"[processor] sensor connected ({peer})", flush=True)
        try:
            for event in iter_lines(self.request):
                _event_queue.put(event)
        except OSError:
            pass
        print(f"[processor] sensor disconnected ({peer})", flush=True)


class _Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


def start_server(socket_path: str) -> _Server:
    sock_file = Path(socket_path)
    sock_file.parent.mkdir(parents=True, exist_ok=True)
    if sock_file.exists():
        sock_file.unlink()  # stale socket from a previous, uncleanly-killed run

    server = _Server(socket_path, _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    print(f"[processor] listening on {socket_path}", flush=True)
    return server


# --------------------------------------------------------------------------
# Worker: Algorithm 1 + Algorithm 2, single-threaded over the shared state
# --------------------------------------------------------------------------

class Worker:
    def __init__(self) -> None:
        # Algorithm 1 state (same shapes algorithm_1.run_one() keeps)
        self.active_sessions: Dict[int, float] = {}
        self.parent_map: Dict[int, int] = {}
        self.pending: deque[LogEvent] = deque()

        # Algorithm 2 state
        self.active_graphs: Dict[int, nx.MultiDiGraph] = {}

        # event_id -> LogEvent, for turning a resolved (session_key, event_id)
        # back into the full event Algorithm 2 needs. Pruned on every
        # Postgres event (see _prune_lookup) using the same expiry window
        # Algorithm 1 itself uses to give up on a pending kernel event, so
        # this never grows unbounded.
        self._lookup: Dict[int, LogEvent] = {}
        self._next_event_id = 0

        OUT_DIR.mkdir(parents=True, exist_ok=True)

    # -- ingestion -----------------------------------------------------

    def handle_raw_event(self, event: dict) -> None:
        source = event.get("source")
        if source not in ("kernel", "postgres"):
            return

        pid = event.get("backend_pid") if source == "postgres" else event.get("pid")
        try:
            ts = float(event["timestamp_unix"])
            pid = int(pid)
        except (KeyError, TypeError, ValueError):
            return  # malformed event -- drop rather than crash the pipeline

        log_event = LogEvent(event_id=self._next_event_id, source=source, timestamp=ts, pid=pid, raw=event)
        self._next_event_id += 1
        self._lookup[log_event.event_id] = log_event

        resolved = process_event_with_retry(log_event, self.active_sessions, self.parent_map, self.pending)
        for session_key, event_id in resolved:
            self._apply_to_graph(session_key, event_id)

        if source == "postgres":
            self._prune_lookup(ts)
            if event.get("event_type") in DISCONNECT_EVENT_TYPES:
                self._close_session(pid, reason="disconnect")

    def _apply_to_graph(self, session_key: int, event_id: int) -> None:
        log_event = self._lookup.pop(event_id, None)
        if log_event is None:
            return
        attributed = {
            **log_event.raw,
            "session_key": session_key,
            "event_id": log_event.event_id,
            "source": log_event.source,
            "timestamp_unix": log_event.timestamp,
            "timestamp": log_event.timestamp,
        }
        alg2_process_event(session_key, attributed, self.active_graphs)

    def _prune_lookup(self, now_ts: float) -> None:
        # Anything older than Algorithm 1's own retry window will never
        # resolve (algorithm_1 has already dropped it from `pending` at
        # this point) -- safe to drop from our lookup too.
        cutoff = now_ts - PENDING_RETRY_WINDOW_SECONDS
        stale = [eid for eid, ev in self._lookup.items() if ev.timestamp < cutoff]
        for eid in stale:
            self._lookup.pop(eid, None)

    # -- session close / shutdown ---------------------------------------

    def _close_session(self, session_key: int, reason: str) -> None:
        G = self.active_graphs.pop(session_key, None)
        if G is None:
            return  # session produced no graph-worthy activity before disconnecting
        self._save_graph(session_key, G, reason)

    def flush_all(self, reason: str) -> None:
        for session_key in list(self.active_graphs.keys()):
            self._close_session(session_key, reason)

    def _save_graph(self, session_key: int, G: nx.MultiDiGraph, reason: str) -> None:
        fname = f"{RUN_ID}_session_{session_key}.json"
        (OUT_DIR / fname).write_text(json.dumps(nx.node_link_data(G), default=str))

        manifest_row = {
            "run_id": RUN_ID,
            "session_key": session_key,
            "reason": reason,
            "saved_at": time.time(),
            "graph_file": fname,
            "node_count": G.number_of_nodes(),
            "edge_count": G.number_of_edges(),
        }
        with (OUT_DIR / "manifest.jsonl").open("a") as manifest:
            manifest.write(json.dumps(manifest_row) + "\n")

        print(f"[processor] saved session {session_key} -> {fname} "
              f"({manifest_row['node_count']} nodes, {manifest_row['edge_count']} edges, reason={reason})",
              flush=True)


def run_worker(worker: Worker) -> None:
    while not _stop.is_set():
        try:
            event = _event_queue.get(timeout=0.5)
        except queue.Empty:
            continue
        worker.handle_raw_event(event)


# --------------------------------------------------------------------------
# Entrypoint
# --------------------------------------------------------------------------

def main() -> None:
    server = start_server(SOCKET_PATH)
    worker = Worker()

    def handle_signal(signum, frame):
        print(f"[processor] received signal {signum}, flushing open sessions and shutting down...", flush=True)
        _stop.set()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    worker_thread = threading.Thread(target=run_worker, args=(worker,), daemon=True)
    worker_thread.start()

    while not _stop.is_set():
        time.sleep(0.5)

    worker_thread.join(timeout=5.0)
    worker.flush_all(reason="processor_shutdown")

    server.shutdown()
    server.server_close()
    try:
        Path(SOCKET_PATH).unlink(missing_ok=True)
    except OSError:
        pass
    print("[processor] stopped.", flush=True)


if __name__ == "__main__":
    main()
