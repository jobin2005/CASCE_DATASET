"""
Shared constants + wire format for the sensor <-> processor pipeline.

Transport: a single Unix domain socket, local to the machine (no network
exposure, no port to manage). Framing: one JSON object per line
(newline-delimited JSON / "JSON Lines"), which is trivial to produce
incrementally on the sender side and to buffer/split on the receiver side.
"""

from __future__ import annotations

import json
import socket

SOCKET_PATH = "/dataset_workspace/.casce_pipeline.sock"

# How long a sensor waits before retrying a dead/absent processor socket.
# Kept short enough that the processor coming up mid-run is picked up
# quickly, long enough that a down processor doesn't turn into a
# connect()-syscall busy loop.
RECONNECT_INTERVAL_SECONDS = 2.0

_RECV_BUFSIZE = 65536


def send_line(sock: socket.socket, event: dict) -> None:
    """Send one event as a single JSON line. Raises OSError on any
    transport failure -- callers decide what a failed send means for them
    (sensor.py falls back to disk; nothing calls this expecting it to
    silently swallow errors)."""
    payload = json.dumps(event, default=str).encode("utf-8") + b"\n"
    sock.sendall(payload)


def iter_lines(sock: socket.socket):
    """Yield decoded JSON dicts from a connected stream socket, one per
    newline-delimited message, until the peer closes the connection.
    Malformed lines are skipped rather than killing the connection --
    one corrupted message from a sensor shouldn't take down the whole
    processing pipeline."""
    buf = b""
    while True:
        chunk = sock.recv(_RECV_BUFSIZE)
        if not chunk:
            return
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue
