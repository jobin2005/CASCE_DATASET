#!/bin/bash
set -euo pipefail

DEV_RUNS=3
TEST_RUNS=3

run_pipeline() {
    local dataset_dir=$1
    local run_id=$2
    
    echo "=========================================="
    echo "Starting $dataset_dir - Run $run_id"
    echo "=========================================="
    
    # 1. Reset Database State
    docker exec -u root casce_environment bash -c "cd /dataset_workspace && ./setup_db.sh > /dev/null"
    docker exec -u postgres casce_environment psql -d casce_tpcb -c "CREATE EXTENSION IF NOT EXISTS pg_telemetry;" > /dev/null 2>&1 || true
    docker exec -u postgres casce_environment psql -d casce_tpcb -c "ALTER DATABASE casce_tpcb SET session_preload_libraries = 'pg_telemetry';" > /dev/null 2>&1 || true
    
    # 2. Reset and Secure Logs -> Start Telemetry
    docker exec -u root casce_environment bash -c "cd /dataset_workspace && ./logger.sh stop 2>/dev/null || true && rm -f postgres_events.json kernel_events.json && touch postgres_events.json kernel_events.json && chmod 666 postgres_events.json kernel_events.json && ./logger.sh start > /dev/null"
    
    # 3. Simulate Normal & Attack Traffic (CONCURRENT)
    # Background normal workload — runs pgbench concurrently with everything else
    docker exec -u root casce_environment bash -c "cd /dataset_workspace && ./normal_workload.sh > /dev/null" &
    NORMAL_PID=$!

    # Background benign edge cases — hard-negative DBA traffic
    docker exec -u root casce_environment bash -c "cd /dataset_workspace && chmod +x benign_edge_cases.sh && ./benign_edge_cases.sh > /dev/null 2>&1 || true" &
    BENIGN_PID=$!

    # Run attack scripts — first two (exfiltration + sabotage) concurrently,
    # then remaining scripts sequentially to produce genuine interleaved sessions
    docker exec -u root casce_environment bash -c "cd /dataset_workspace && \
        bash attack_workload/attack_exfiltration.sh > /dev/null 2>&1 & \
        bash attack_workload/attack_sabotage.sh > /dev/null 2>&1 & \
        wait; \
        for script in \
            attack_workload/attack_privilege_abuse.sh \
            attack_workload/attack_reverse_shell.sh \
            attack_workload/attack_os_priv_escalation.sh \
            attack_workload/attack_db_unauthorized_read.sh \
            attack_workload/attack_multi_stage_apt.sh \
            attack_workload/attack_exfiltration_delayed_2s.sh \
            attack_workload/attack_exfiltration_delayed_30s.sh \
            attack_workload/attack_exfiltration_alt_process.sh; do \
            bash \$script > /dev/null 2>&1 || true; \
        done"

    # Wait for background normal + benign workloads to finish
    wait $NORMAL_PID || true
    wait $BENIGN_PID || true
    
    # 4. Stop Telemetry, Process Labels, Validate, Freeze
    docker exec -u root casce_environment bash -c "cd /dataset_workspace && ./logger.sh stop > /dev/null && python3 ./generate_labels.py && python3 ./dataset_validator.py && ./freeze_dataset.sh > /dev/null"
    
    # 5. Extract to Isolated Run Folder
    mkdir -p "${dataset_dir}/run_${run_id}"
    cp -r dataset/* "${dataset_dir}/run_${run_id}/" 2>/dev/null || true
    rm -rf dataset/* 2>/dev/null || true
    
    echo "Completed $dataset_dir - Run $run_id"
}

# Clean existing datasets
rm -rf dataset_dev dataset_test

echo "Generating Development Dataset ($DEV_RUNS iterations)..."
for i in $(seq 1 $DEV_RUNS); do
    run_pipeline "dataset_dev" $i
done

echo "Generating Held-out Test Dataset ($TEST_RUNS iterations)..."
for i in $(seq 1 $TEST_RUNS); do
    run_pipeline "dataset_test" $i
done

echo "=========================================="
echo "All experimental datasets generated safely!"
echo "Outputs are located at ./dataset_dev/ and ./dataset_test/"
