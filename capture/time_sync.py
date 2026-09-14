"""
time_sync.py

Provides server boot time and clock calibration for kernel (monotonic ns)
and PostgreSQL (wall-clock epoch seconds) timestamps.
"""

import time
from pathlib import Path
from typing import Optional

_CACHED_BOOT_TIME: Optional[float] = None


def get_server_boot_unix_time() -> float:
    """
    Returns server boot time in unix epoch seconds.
    Ported from v1's logger.sh (NOW - UPTIME from /proc/uptime).
    Falls back gracefully if /proc/uptime is unavailable (e.g. non-Linux host).
    """
    global _CACHED_BOOT_TIME
    if _CACHED_BOOT_TIME is not None:
        return _CACHED_BOOT_TIME

    uptime_file = Path("/proc/uptime")
    if uptime_file.exists():
        try:
            with uptime_file.open("r", encoding="utf-8") as f:
                uptime_str = f.readline().split()[0]
                uptime_seconds = float(uptime_str)
                _CACHED_BOOT_TIME = time.time() - uptime_seconds
                return _CACHED_BOOT_TIME
        except Exception:
            pass

    # Fallback to psutil if available
    try:
        import psutil
        _CACHED_BOOT_TIME = float(psutil.boot_time())
        return _CACHED_BOOT_TIME
    except Exception:
        pass

    # Final fallback: current time (relative calibration)
    _CACHED_BOOT_TIME = time.time()
    return _CACHED_BOOT_TIME


def calibrate(raw_kernel_timestamp: float) -> float:
    """
    Converts a raw kernel timestamp (nanoseconds since boot from bpf_ktime_get_ns())
    to a wall-clock unix timestamp in seconds.
    If the timestamp already appears to be in unix seconds (e.g., > 1e9 and < 2e9),
    returns it directly.
    """
    if raw_kernel_timestamp is None:
        return time.time()

    # If it's already in seconds (e.g. ~1.7e9 in 2024-2026), return as is
    if 1e9 <= raw_kernel_timestamp <= 2e9:
        return float(raw_kernel_timestamp)

    boot_time = get_server_boot_unix_time()
    # Kernel timestamp from bpf_ktime_get_ns is in nanoseconds since boot
    return boot_time + (raw_kernel_timestamp / 1_000_000_000.0)


def reset_cache():
    """Reset cached boot time (useful for unit testing)."""
    global _CACHED_BOOT_TIME
    _CACHED_BOOT_TIME = None
