#!/bin/bash
# setup_db.sh
# (Re)initializes PostgreSQL with a given schema and its seed data.
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
SCHEMA_FILE=""
if [ -f "templates/${SCHEMA_NAME}/database_schema/schema.sql" ]; then
    SCHEMA_FILE="templates/${SCHEMA_NAME}/database_schema/schema.sql"
elif [ -f "db_schemas/${SCHEMA_NAME}/schema.sql" ]; then
    SCHEMA_FILE="db_schemas/${SCHEMA_NAME}/schema.sql"
fi

if [ -n "$SCHEMA_FILE" ] && [ -s "$SCHEMA_FILE" ]; then
    echo "Applying schema from $SCHEMA_FILE..."
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB_NAME" -f "$SCHEMA_FILE"
else
    echo "Warning: No non-empty schema file found for $SCHEMA_NAME (checked templates/ and db_schemas/)."
fi

# Locate and apply seed data
SEED_DIR=""
if [ -d "templates/${SCHEMA_NAME}/seed_data" ]; then
    SEED_DIR="templates/${SCHEMA_NAME}/seed_data"
elif [ -d "db_schemas/${SCHEMA_NAME}/seed_data" ]; then
    SEED_DIR="db_schemas/${SCHEMA_NAME}/seed_data"
fi

if [ -n "$SEED_DIR" ]; then
    echo "Loading seed data from $SEED_DIR..."
    for sql_file in "$SEED_DIR"/*.sql; do
        if [ -f "$sql_file" ]; then
            echo "  Executing $sql_file..."
            psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB_NAME" -f "$sql_file"
        fi
    done
fi

# Attempt to load telemetry extension if compiled
echo "Ensuring pg_telemetry extension is enabled if available..."
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pg_telemetry;" 2>/dev/null || true

echo "=========================================================="
echo "Database '$DB_NAME' initialized successfully."
echo "Tables in '$DB_NAME':"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB_NAME" -c "\dt" || true
echo "=========================================================="
