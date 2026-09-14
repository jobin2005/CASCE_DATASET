"""
event_bus.py

Merges live streams (kernel_ebpf_tracer, postgres_event_listener) into
one clock-calibrated, time-ordered feed for Algorithm 1 and Algorithm 2.
"""

import queue
import threading
import time
from typing import Iterator, List, Optional

try:
    from time_sync import calibrate
except ImportError:
    from .time_sync import calibrate


class EventBus:
    def __init__(self, buffer_window_seconds: float = 0.5):
        self.buffer_window_seconds = buffer_window_seconds
        self._events: List[dict] = []
        self._queue = queue.Queue()
        self._lock = threading.Lock()
        self._counter = 0
        self._closed = False

    def publish(self, event: dict):
        """
        Enqueues an event, applying time_sync calibration on raw kernel timestamps
        and ensuring required fields are set.
        """
        with self._lock:
            self._counter += 1
            event_id = event.get("event_id", self._counter)

            # Ensure event_id is recorded
            event["event_id"] = event_id

            # Determine source
            source = event.get("source")
            if not source:
                if "syscall" in event or "comm" in event:
                    source = "kernel"
                elif "session_id" in event or "query" in event:
                    source = "postgres"
                else:
                    source = "generic"
                event["source"] = source

            # Apply clock calibration
            raw_ts = event.get("timestamp") or event.get("ts") or time.time()
            if source == "kernel":
                calibrated_ts = calibrate(float(raw_ts))
            else:
                calibrated_ts = float(raw_ts)

            event["timestamp_unix"] = calibrated_ts
            event["timestamp"] = calibrated_ts

            # Keep track of raw event dictionary if not present
            if "raw" not in event:
                event["raw"] = dict(event)

            self._events.append(event)
            self._queue.put(event)

    def consume(self, timeout: float = 1.0) -> Iterator[dict]:
        """
        Yields events as they arrive. Stops when closed and empty.
        """
        while True:
            try:
                ev = self._queue.get(timeout=timeout)
                yield ev
            except queue.Empty:
                if self._closed:
                    break

    def close(self):
        """Signals no more events will be published."""
        with self._lock:
            self._closed = True

    def drain(self) -> List[dict]:
        """
        Flushes and returns all accumulated events sorted chronologically
        by their calibrated unix timestamp.
        """
        with self._lock:
            self._closed = True
            sorted_events = sorted(self._events, key=lambda e: e.get("timestamp_unix", 0))
            return sorted_events

    def clear(self):
        """Resets the event bus state for a fresh session."""
        with self._lock:
            self._events.clear()
            self._queue = queue.Queue()
            self._counter = 0
            self._closed = False
