#!/bin/bash
set -euo pipefail

SCHEMA_FILE="${1:?usage: $0 <schema.sql> <seed_commands.json> [dbname]}"
SEED_JSON="${2:?usage: $0 <schema.sql> <seed_commands.json> [dbname]}"
DB_NAME="${3:-casce_sample}"

echo "Waiting for PostgreSQL to be ready..."
until pg_isready -h localhost -p 5432 -U postgres >/dev/null 2>&1; do
    sleep 1
done

echo "Creating database '${DB_NAME}' (ignored if it already exists)..."
psql -U postgres -c "CREATE DATABASE ${DB_NAME};" || true

echo "Applying schema from ${SCHEMA_FILE}..."
psql -U postgres -d "${DB_NAME}" -f "${SCHEMA_FILE}"

echo "Loading seed data from ${SEED_JSON}..."
python3 "$(dirname "$0")/load_seed.py" "${SEED_JSON}" "${DB_NAME}"

echo "Done. Tables in ${DB_NAME}:"
psql -U postgres -d "${DB_NAME}" -c "\dt"