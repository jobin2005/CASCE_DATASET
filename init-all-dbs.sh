#!/bin/bash
# ==============================================================================
# 00-init-all-dbs.sh
#
# Runs automatically on first container start (via docker-entrypoint-initdb.d).
# For every domain folder found under /docker-entrypoint-initdb.d/dbs/<domain>/:
#   1. Creates a database named <domain>
#   2. Applies <domain>/schema.sql
#   3. Loads every <domain>/seed_data/<table>.csv into its matching table,
#      in the same order tables were CREATEd in schema.sql (keeps FK order safe)
#   4. Resets all SERIAL/IDENTITY sequences so future inserts don't collide
#      with the explicit ids that came in via the CSVs
#
# templates/attack/*.yaml and templates/benign/*.yaml are NOT loaded into the
# database - they are query scenario definitions for an external test harness,
# not table data - so they are simply left on disk (see README).
# ==============================================================================

set -euo pipefail

DBS_ROOT="/docker-entrypoint-initdb.d/dbs"

if [ ! -d "$DBS_ROOT" ]; then
  echo "[init-all-dbs] No $DBS_ROOT directory mounted - nothing to do."
  exit 0
fi

for domain_dir in "$DBS_ROOT"/*/; do
  domain="$(basename "$domain_dir")"
  schema_file="${domain_dir}schema.sql"
  seed_dir="${domain_dir}seed_data"

  if [ ! -f "$schema_file" ]; then
    echo "[init-all-dbs] Skipping '$domain' - no schema.sql found."
    continue
  fi

  echo "=============================================================="
  echo "[init-all-dbs] Setting up database: $domain"
  echo "=============================================================="

  # 1. Create the database (ignore error if it somehow already exists)
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
      SELECT 'CREATE DATABASE "${domain}"'
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${domain}')\gexec
EOSQL

  # 2. Apply the schema
  echo "[init-all-dbs] Applying schema.sql to '$domain'"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$domain" -f "$schema_file"

  # 3. Load seed CSVs, in the order tables were declared in schema.sql
  if [ -d "$seed_dir" ]; then
    table_order=$(grep -i '^CREATE TABLE' "$schema_file" | sed -E 's/CREATE TABLE ([A-Za-z_0-9]+).*/\1/I')

    for table in $table_order; do
      csv_file="${seed_dir}/${table}.csv"
      if [ -f "$csv_file" ]; then
        echo "[init-all-dbs] Loading ${table}.csv -> ${domain}.${table}"
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$domain" \
          -c "\\COPY ${table} FROM '${csv_file}' WITH (FORMAT csv, HEADER true)"
      else
        echo "[init-all-dbs] (no seed_data/${table}.csv found, skipping)"
      fi
    done

    # Any CSVs that didn't match a table name found in schema.sql (e.g. naming
    # mismatches) are reported so they don't silently fail to load.
    for csv_file in "$seed_dir"/*.csv; do
      [ -e "$csv_file" ] || continue
      base="$(basename "$csv_file" .csv)"
      if ! echo "$table_order" | grep -qx "$base"; then
        echo "[init-all-dbs] WARNING: ${csv_file} does not match any CREATE TABLE in schema.sql - not loaded."
      fi
    done
  else
    echo "[init-all-dbs] No seed_data directory for '$domain' - schema only, no data loaded."
  fi

  # 4. Fix sequences so nextval() continues after the max seeded id
  echo "[init-all-dbs] Resyncing sequences for '$domain'"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$domain" <<-'EOSQL'
      DO $$
      DECLARE
        rec RECORD;
      BEGIN
        FOR rec IN
          SELECT
            seq.relname   AS sequence_name,
            tab.relname   AS table_name,
            attr.attname  AS column_name
          FROM pg_class seq
          JOIN pg_depend dep      ON dep.objid = seq.oid
          JOIN pg_class tab       ON dep.refobjid = tab.oid
          JOIN pg_attribute attr  ON attr.attrelid = tab.oid
                                  AND attr.attnum = dep.refobjsubid
          WHERE seq.relkind = 'S'
        LOOP
          EXECUTE format(
            'SELECT setval(''%I'', COALESCE((SELECT MAX(%I) FROM %I), 1))',
            rec.sequence_name, rec.column_name, rec.table_name
          );
        END LOOP;
      END $$;
EOSQL

  echo "[init-all-dbs] Done with '$domain'."
  echo
done

echo "[init-all-dbs] All domains processed."
