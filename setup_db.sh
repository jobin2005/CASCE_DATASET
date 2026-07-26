#!/bin/bash
set -e

echo "Starting DVD Rental database setup..."

# Wait for postgres to be ready
echo "Waiting for PostgreSQL to start..."
until pg_isready -h localhost -p 5432 -U postgres; do
  sleep 1
done

echo "Database is ready. Creating schema..."

# Create target database
echo "Creating casce_tpcb database..."
psql -U postgres -c "CREATE DATABASE casce_tpcb;" || echo "Database may already exist."

echo "Initializing TPC-B Benchmark (Banking Schema) natively via pgbench..."
pgbench -i -s 10 -U postgres -d casce_tpcb

echo "Phase 1 completion: Database initialized successfully."
echo "Tables in casce_tpcb:"
psql -U postgres -d casce_tpcb -c "\dt"

