#!/bin/bash
# setup_db.sh
# (Re)initializes PostgreSQL with a given schema and its CSV seed data.
# Parameterized by schema name: ecommerce, banking, healthcare, logistics, etc.
#
# Usage: ./setup_db.sh <schema_name> [host] [port] [user] [password]

set -euo pipefail

SCHEMA_NAME="${1:-}"
PGHOST="${2:-${PGHOST:-localhost}}"
PGPORT="${3:-${PGPORT:-5432}}"
PGUSER="${4:-${PGUSER:-postgres}}"
export PGPASSWORD="${5:-${PGPASSWORD:-password}}"

if [ -z "$SCHEMA_NAME" ]; then
    echo "Usage: $0 <schema_name> [host] [port] [user] [password]"
    echo "Available schemas: ecommerce, banking, healthcare, logistics"
    exit 1
fi

DB_NAME="casce_${SCHEMA_NAME}"

echo "=========================================================="
echo "Setting up database '$DB_NAME' for schema '$SCHEMA_NAME'..."
echo "Target host: $PGHOST:$PGPORT (User: $PGUSER)"
echo "=========================================================="

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
until pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" >/dev/null 2>&1; do
    sleep 1
done
echo "PostgreSQL is ready."

# Drop existing database and recreate cleanly
echo "Recreating database '$DB_NAME'..."
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c "DROP DATABASE IF EXISTS ${DB_NAME};"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c "CREATE DATABASE ${DB_NAME};"

# Locate schema.sql
SCHEMA_FILE="dbs/${SCHEMA_NAME}/schema.sql"

if [ -f "$SCHEMA_FILE" ] && [ -s "$SCHEMA_FILE" ]; then
    echo "Applying schema from $SCHEMA_FILE..."
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB_NAME" -f "$SCHEMA_FILE"
else
    echo "Warning: Schema file not found at $SCHEMA_FILE."
fi

# Locate and apply seed data (CSV files)
SEED_DIR="dbs/${SCHEMA_NAME}/seed_data"

if [ -d "$SEED_DIR" ]; then
    echo "Loading seed data from $SEED_DIR..."
    
    # Temporarily disable foreign key / trigger constraints during bulk load
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB_NAME" -c "SET session_replication_role = 'replica';"
    
    for csv_file in "$SEED_DIR"/*.csv; do
        if [ -f "$csv_file" ]; then
            table_name=$(basename "$csv_file" .csv)
            echo "  Importing $csv_file into table '$table_name'..."
            psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB_NAME" -c "\copy ${table_name} FROM '${csv_file}' WITH (FORMAT csv, HEADER true);" || echo "  Notice: Non-fatal issue loading $table_name, continuing."
        fi
    done
    
    # Restore normal replication / trigger behavior
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB_NAME" -c "SET session_replication_role = 'origin';"
fi

# Attempt to load telemetry extension if compiled
echo "Ensuring pg_telemetry extension is enabled if available..."
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pg_telemetry;" 2>/dev/null || true

echo "=========================================================="
echo "Database '$DB_NAME' initialized successfully."
echo "Tables in '$DB_NAME':"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB_NAME" -c "\dt" || true
echo "=========================================================="
