#!/usr/bin/env python3
"""
sensor.py -- CASCE live telemetry sensor.

Replaces kernel_telemetry.py as the process logger.sh's `start` launches.
Two jobs, run concurrently:

  1. Kernel side: attaches the same eBPF program kernel_telemetry.py used
     (imported from it directly, so the tracepoints stay in exactly one
     place), and for every captured syscall event either:
        - forwards it live to processor.py over a Unix socket, or
        - if the processor is unreachable, appends it to kernel_events.json
          in the exact same shape kernel_telemetry.py always wrote, so the
          existing offline pipeline (algorithm_1.load_master_log) still
          works unmodified on whatever this run produced.

  2. Postgres side: tails postgres_events.json, which pg_telemetry.c
     (the Postgres extension) already writes to unconditionally whenever
     logging is active -- that file *is* the fallback copy, produced by a
     completely different process (a Postgres backend) that this script
     has no control over and doesn't need one over. This script's only
     job on the Postgres side is to pick up new lines as they land and
     best-effort forward them live too. Nothing extra needs to be written
     to disk here since the extension already guarantees that part.

Both sides calibrate to the same wall-clock unix-epoch timestamp
(`timestamp_unix`) before sending live, so the processor never has to
reason about kernel-monotonic-vs-wall-clock time itself; it just reads
`timestamp_unix` off of whatever it receives.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import struct
import sys
import threading
import time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from casce_ipc import SOCKET_PATH, RECONNECT_INTERVAL_SECONDS, send_line

# Reuse the actual BPF program + syscall table from kernel_telemetry.py
# instead of forking a second copy of the tracepoint definitions.
from kernel_telemetry import bpf_text, SYSCALL_MAP

WORKDIR = Path("/dataset_workspace")
KERNEL_LOG = WORKDIR / "kernel_events.json"
PG_LOG = WORKDIR / "postgres_events.json"

_stop = threading.Event()


# --------------------------------------------------------------------------
# Best-effort link to the processor
# --------------------------------------------------------------------------

class ProcessorLink:
    """Owns (at most) one connection attempt at a time to the processor's
    Unix socket. try_send() never raises and never blocks the caller more
    than a short connect timeout; callers decide what "not sent" means for
    that particular event (fallback-to-file for kernel events, nothing
    further for Postgres events since those are already durable on disk)."""

    def __init__(self, socket_path: str = SOCKET_PATH):
        self.socket_path = socket_path
        self._sock: socket.socket | None = None
        self._last_attempt = 0.0
        self._lock = threading.Lock()

    def _connect_locked(self) -> None:
        now = time.monotonic()
        if now - self._last_attempt < RECONNECT_INTERVAL_SECONDS:
            return
        self._last_attempt = now
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(2.0)
            s.connect(self.socket_path)
            s.settimeout(None)
            self._sock = s
            print(f"[sensor] connected to processor at {self.socket_path}", flush=True)
        except OSError:
            self._sock = None

    def try_send(self, event: dict) -> bool:
        with self._lock:
            if self._sock is None:
                self._connect_locked()
            if self._sock is None:
                return False
            try:
                send_line(self._sock, event)
                return True
            except OSError:
                try:
                    self._sock.close()
                except OSError:
                    pass
                self._sock = None
                return False

    def close(self) -> None:
        with self._lock:
            if self._sock is not None:
                try:
                    self._sock.close()
                except OSError:
                    pass
                self._sock = None


def append_fallback(event: dict, path: Path) -> None:
    """Append one JSON line to the given fallback file. Used only for
    kernel events -- see module docstring for why Postgres events don't
    need this."""
    with path.open("a") as f:
        f.write(json.dumps(event) + "\n")


# --------------------------------------------------------------------------
# Kernel side (eBPF)
# --------------------------------------------------------------------------

def _boot_unix_time() -> float:
    """Same calculation logger.sh does for time_sync.json: wall-clock time
    of system boot, used to convert bpf_ktime_get_ns() (ns since boot) into
    a real unix-epoch timestamp at the point of capture."""
    with open("/proc/uptime") as f:
        uptime_seconds = float(f.read().split()[0])
    return time.time() - uptime_seconds


def run_kernel_sensor(link: ProcessorLink, boot_unix: float) -> None:
    from bcc import BPF  # imported lazily: only the kernel side needs root + bcc

    b = BPF(text=bpf_text)
    print("[sensor] kernel eBPF tracer attached", flush=True)

    def on_event(cpu, data, size):
        event = b["events"].event(data)

        dest_ip_str = ""
        dest_port_int = 0
        if event.syscall_id == 6 and event.dest_ip != 0:
            try:
                dest_ip_str = socket.inet_ntoa(struct.pack("<I", event.dest_ip))
                dest_port_int = socket.ntohs(event.dest_port)
            except Exception:
                pass

        try:
            comm = event.comm.decode("utf-8", "ignore")
        except Exception:
            comm = "unknown"
        try:
            arg = event.arg.decode("utf-8", "ignore")
        except Exception:
            arg = ""

        out = {
            "pid": event.pid,
            "ppid": event.ppid,
            "uid": event.uid,
            "timestamp": event.ts,  # raw ns-since-boot, kept as-is for fallback-file parity
            "comm": comm,
            "syscall": SYSCALL_MAP.get(event.syscall_id, "unknown"),
            "arg": arg,
        }
        if dest_ip_str:
            out["dest_ip"] = dest_ip_str
            out["dest_port"] = dest_port_int

        live_event = {
            **out,
            "source": "kernel",
            "timestamp_unix": boot_unix + event.ts / 1e9,
        }

        if not link.try_send(live_event):
            append_fallback(out, KERNEL_LOG)

    b["events"].open_perf_buffer(on_event)

    while not _stop.is_set():
        try:
            b.perf_buffer_poll(timeout=200)
        except Exception as exc:  # keep tracing alive through a transient bcc hiccup
            print(f"[sensor] perf_buffer_poll error: {exc}", file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# Postgres side (tail postgres_events.json)
# --------------------------------------------------------------------------

def run_postgres_sensor(link: ProcessorLink) -> None:
    while not PG_LOG.exists() and not _stop.is_set():
        time.sleep(0.2)
    if _stop.is_set():
        return

    print(f"[sensor] tailing {PG_LOG}", flush=True)
    with PG_LOG.open("r") as f:
        f.seek(0, os.SEEK_END)  # only forward events appended from now on;
                                 # anything already in the file belongs to a
                                 # previous run and is the offline pipeline's job
        while not _stop.is_set():
            line = f.readline()
            if not line:
                time.sleep(0.2)
                continue
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "marker" in rec:
                continue  # LOGGING_START/STOP/ATTACK_* control markers, not events

            live_event = {
                **rec,
                "source": "postgres",
                "timestamp_unix": float(rec["timestamp"]),
            }
            # Best-effort only: pg_telemetry.c already wrote `rec` to this
            # file durably, so there's no separate fallback write to do
            # here if the processor happens to be unreachable.
            link.try_send(live_event)


# --------------------------------------------------------------------------
# Entrypoint
# --------------------------------------------------------------------------

def main() -> None:
    WORKDIR.mkdir(parents=True, exist_ok=True)
    KERNEL_LOG.touch(exist_ok=True)

    link = ProcessorLink()
    boot_unix = _boot_unix_time()

    def handle_signal(signum, frame):
        print(f"[sensor] received signal {signum}, shutting down...", flush=True)
        _stop.set()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    pg_thread = threading.Thread(target=run_postgres_sensor, args=(link,), daemon=True)
    pg_thread.start()

    try:
        run_kernel_sensor(link, boot_unix)  # blocks in this thread until _stop is set
    finally:
        _stop.set()
        pg_thread.join(timeout=2.0)
        link.close()
        print("[sensor] stopped.", flush=True)


if __name__ == "__main__":
    main()
