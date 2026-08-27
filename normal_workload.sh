#!/bin/bash
echo "Starting normal workload simulation using pgbench..."

# Run 10 simulated users doing 100 transactions each (1k total transactions)
# The default pgbench TPC-B like transaction hits multiple tables, simulating realistic traffic
pgbench -c 10 -j 4 -t 100 -U postgres -d casce_tpcb > /dev/null 2>&1

echo "Simulating Benign Administrative Tasks (False-Positive Stress Testing)..."

# 1. Benign Backup (File Write without Network)
# Looks like an exfiltration attack, but has no malicious network curl
psql -U postgres -d casce_tpcb -c "COPY (SELECT * FROM pgbench_accounts LIMIT 1000) TO '/tmp/legit_admin_backup.csv';" > /dev/null 2>&1

# 2. Benign Data Ingestion (File Read)
# Looks like malware reading /etc/passwd, but is just a DBA loading a regular CSV
echo "1,admin,setup" > /tmp/legit_seed_data.csv
psql -U postgres -d casce_tpcb -c "CREATE TABLE IF NOT EXISTS temp_load (id INT, role TEXT, note TEXT);" > /dev/null 2>&1
psql -U postgres -d casce_tpcb -c "COPY temp_load FROM '/tmp/legit_seed_data.csv' DELIMITER ',';" > /dev/null 2>&1

# 3. Benign System Sabotage (Resource Exhaustion)
# A VACUUM FULL locks the database and spikes CPU/Disk I/O wildly. 
# Tests the engine to not flag heavy system overhead as a Denial-of-Service attack.
psql -U postgres -d casce_tpcb -c "VACUUM FULL pgbench_accounts;" > /dev/null 2>&1

# 4. Benign Extension Load (Library linking)
# Creates a fake extension linking operation. This forces the OS to read .so shared object files.
# Malware often loads malicious .so objects, so the ML must learn that standard .so loads are perfectly legal.
psql -U postgres -d casce_tpcb -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;" > /dev/null 2>&1 || true

echo "Normal workload simulation completed."
