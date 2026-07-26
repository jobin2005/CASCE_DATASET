#!/usr/bin/env python3
import subprocess
import time
import os

print("Starting CASCE Telemetry Collector...")

# Ensure JSON files exist
open("/dataset_workspace/postgres_events.json", "a").close()
open("/dataset_workspace/kernel_events.json", "a").close()

# Start the kernel eBPF tracer
kernel_tracer = subprocess.Popen(["/dataset_workspace/ebpf_telemetry/kernel_telemetry.py"])

print("Collector active. Postgres extension logs direct, collector handles eBPF.")
print("Logging to postgres_events.json and kernel_events.json")

try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    print("Shutting down collector...")
    kernel_tracer.terminate()
