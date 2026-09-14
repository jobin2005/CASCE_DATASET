"""
kernel_ebpf_tracer.py

BCC-based eBPF tracer for capturing Linux syscalls (execve, clone, openat,
connect, etc.) and publishing them directly to EventBus.
Ported from v1's ebpf_telemetry/kernel_telemetry.py.
"""

import os
import socket
import struct
import sys
import threading
import time
from typing import Optional

# Syscall mapping matching v1 eBPF C program
SYSCALL_MAP = {
    1: "execve", 2: "clone", 3: "openat", 4: "rename", 5: "unlink",
    6: "connect", 7: "accept", 8: "send", 9: "recv"
}

BPF_TEXT = """
#include <uapi/linux/ptrace.h>
#include <linux/sched.h>
#include <linux/socket.h>
#include <linux/in.h>

BPF_PERF_OUTPUT(events);

struct data_t {
    u32 pid;
    u32 ppid;
    u32 uid;
    u64 ts;
    u32 syscall_id;
    char comm[TASK_COMM_LEN];
    char arg[128]; 
    u32 dest_ip;
    u16 dest_port;
};

static inline void submit_event(void *ctx, u32 syscall_id, const char *arg) {
    struct data_t data = {};
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    
    data.pid = bpf_get_current_pid_tgid() >> 32;
    data.uid = bpf_get_current_uid_gid();
    data.ppid = task->real_parent->tgid;
    data.ts = bpf_ktime_get_ns();
    data.syscall_id = syscall_id;
    bpf_get_current_comm(&data.comm, sizeof(data.comm));
    
    if (arg) {
        bpf_probe_read_user_str(&data.arg, sizeof(data.arg), arg);
    }
    
    events.perf_submit(ctx, &data, sizeof(data));
}

TRACEPOINT_PROBE(syscalls, sys_enter_execve) { submit_event(args, 1, (const char *)args->filename); return 0; }
TRACEPOINT_PROBE(syscalls, sys_enter_clone) { submit_event(args, 2, ""); return 0; }
TRACEPOINT_PROBE(syscalls, sys_enter_openat) { submit_event(args, 3, (const char *)args->filename); return 0; }
TRACEPOINT_PROBE(syscalls, sys_enter_rename) { submit_event(args, 4, (const char *)args->oldname); return 0; }
TRACEPOINT_PROBE(syscalls, sys_enter_unlink) { submit_event(args, 5, (const char *)args->pathname); return 0; }
TRACEPOINT_PROBE(syscalls, sys_enter_connect) {
    struct data_t data = {};
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    data.pid = bpf_get_current_pid_tgid() >> 32;
    data.uid = bpf_get_current_uid_gid();
    data.ppid = task->real_parent->tgid;
    data.ts = bpf_ktime_get_ns();
    data.syscall_id = 6;
    bpf_get_current_comm(&data.comm, sizeof(data.comm));
    
    struct sockaddr *uservaddr = (struct sockaddr *)args->uservaddr;
    short family = 0;
    bpf_probe_read_user(&family, sizeof(family), &uservaddr->sa_family);
    
    if (family == 2) { /* AF_INET */
        struct sockaddr_in *sock = (struct sockaddr_in *)uservaddr;
        bpf_probe_read_user(&data.dest_ip, sizeof(data.dest_ip), &sock->sin_addr.s_addr);
        bpf_probe_read_user(&data.dest_port, sizeof(data.dest_port), &sock->sin_port);
    }
    
    events.perf_submit(args, &data, sizeof(data));
    return 0;
}
TRACEPOINT_PROBE(syscalls, sys_enter_accept) { submit_event(args, 7, ""); return 0; }
TRACEPOINT_PROBE(syscalls, sys_enter_sendto) { submit_event(args, 8, ""); return 0; }
TRACEPOINT_PROBE(syscalls, sys_enter_recvfrom) { submit_event(args, 9, ""); return 0; }
"""

_tracer_thread: Optional[threading.Thread] = None
_bpf_instance = None
_running = False


def start_tracer(event_bus, poll_timeout_ms: int = 100):
    """
    Attaches BCC probes and begins streaming events directly to event_bus.
    Falls back gracefully if BCC is not available in the execution environment.
    """
    global _tracer_thread, _bpf_instance, _running

    if _running:
        return

    _running = True

    try:
        from bcc import BPF
        _bpf_instance = BPF(text=BPF_TEXT)

        def _handle_event(cpu, data, size):
            if not _running:
                return
            event = _bpf_instance["events"].event(data)

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
                "source": "kernel",
                "pid": event.pid,
                "ppid": event.ppid,
                "uid": event.uid,
                "timestamp": event.ts,
                "comm": comm,
                "syscall": SYSCALL_MAP.get(event.syscall_id, "unknown"),
                "arg": arg,
            }
            if dest_ip_str:
                out["dest_ip"] = dest_ip_str
                out["dest_port"] = dest_port_int

            event_bus.publish(out)

        _bpf_instance["events"].open_perf_buffer(_handle_event)

        def _poll_loop():
            while _running and _bpf_instance:
                try:
                    _bpf_instance.perf_buffer_poll(poll_timeout_ms)
                except Exception:
                    break

        _tracer_thread = threading.Thread(target=_poll_loop, daemon=True)
        _tracer_thread.start()

    except ImportError:
        # Graceful fallback for non-Linux / development environments
        print("[kernel_ebpf_tracer] bcc module not available; running in stub mode", file=sys.stderr)
    except Exception as exc:
        print(f"[kernel_ebpf_tracer] eBPF initialization error: {exc}; running in stub mode", file=sys.stderr)


def stop_tracer():
    """Detaches probes and stops background tracer thread."""
    global _tracer_thread, _bpf_instance, _running
    _running = False
    if _tracer_thread and _tracer_thread.is_alive():
        _tracer_thread.join(timeout=1.0)
    _bpf_instance = None
    _tracer_thread = None


if __name__ == "__main__":
    try:
        from event_bus import EventBus
    except ImportError:
        from capture.event_bus import EventBus

    bus = EventBus()
    start_tracer(bus)
    print("Kernel tracer started. Press Ctrl+C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        stop_tracer()
        print("Kernel tracer stopped.")
