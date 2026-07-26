#!/bin/bash
echo "Starting normal workload simulation using pgbench..."

# Run 10 simulated users doing 100 transactions each (1k total transactions)
# The default pgbench TPC-B like transaction hits multiple tables, simulating realistic traffic
pgbench -c 10 -j 4 -t 100 -U postgres -d casce_tpcb

echo "Normal workload simulation completed."
