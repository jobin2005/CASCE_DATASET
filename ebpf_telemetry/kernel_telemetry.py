#!/usr/bin/env python3
from bcc import BPF
import json
import time
import os

# eBPF C program mapping to required syscall tracepoints
bpf_text = """
#include <uapi/linux/ptrace.h>
#include <linux/sched.h>

BPF_PERF_OUTPUT(events);

struct data_t {
    u32 pid;
    u32 ppid;
    u64 ts;
    char comm[TASK_COMM_LEN];
    char syscall[16];
    char arg[128]; 
};

static inline void submit_event(void *ctx, const char *syscall, const char *arg) {
    struct data_t data = {};
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    
    data.pid = bpf_get_current_pid_tgid() >> 32;
    data.ppid = task->real_parent->tgid;
    data.ts = bpf_ktime_get_ns();
    bpf_get_current_comm(&data.comm, sizeof(data.comm));
    
    bpf_probe_read_kernel_str(&data.syscall, sizeof(data.syscall), syscall);
    if (arg) {
        bpf_probe_read_user_str(&data.arg, sizeof(data.arg), arg);
    }
    
    events.perf_submit(ctx, &data, sizeof(data));
}

TRACEPOINT_PROBE(syscalls, sys_enter_execve) {
    submit_event(args, "execve", (const char *)args->filename);
    return 0;
}

TRACEPOINT_PROBE(syscalls, sys_enter_clone) {
    submit_event(args, "clone", "");
    return 0;
}

TRACEPOINT_PROBE(syscalls, sys_enter_openat) {
    submit_event(args, "openat", (const char *)args->filename);
    return 0;
}



TRACEPOINT_PROBE(syscalls, sys_enter_rename) {
    submit_event(args, "rename", (const char *)args->oldname);
    return 0;
}

TRACEPOINT_PROBE(syscalls, sys_enter_unlink) {
    submit_event(args, "unlink", (const char *)args->pathname);
    return 0;
}

TRACEPOINT_PROBE(syscalls, sys_enter_connect) {
    submit_event(args, "connect", "");
    return 0;
}

TRACEPOINT_PROBE(syscalls, sys_enter_accept) {
    submit_event(args, "accept", "");
    return 0;
}

TRACEPOINT_PROBE(syscalls, sys_enter_sendto) {
    submit_event(args, "send", "");
    return 0;
}

TRACEPOINT_PROBE(syscalls, sys_enter_recvfrom) {
    submit_event(args, "recv", "");
    return 0;
}
"""

if __name__ == '__main__':
    b = BPF(text=bpf_text)
    output_file = "/dataset_workspace/kernel_events.json"
    print(f"Tracing kernel events... Writing to {output_file}")

    with open(output_file, "a") as f:
        def print_event(cpu, data, size):
            event = b["events"].event(data)
            
            # Very basic string cleanup
            try:
                comm = event.comm.decode('utf-8', 'ignore')
            except:
                comm = "unknown"
                
            try:
                arg = event.arg.decode('utf-8', 'ignore')
            except:
                arg = ""
                
            out = {
                "pid": event.pid,
                "ppid": event.ppid,
                "timestamp": event.ts,
                "comm": comm,
                "syscall": event.syscall.decode('utf-8', 'ignore'),
                "arg": arg
            }
            f.write(json.dumps(out) + "\n")
            f.flush()

        b["events"].open_perf_buffer(print_event)
        
        try:
            while True:
                b.perf_buffer_poll()
        except KeyboardInterrupt:
            print("Stopped tracing.")
            exit()
