#!/bin/bash
# docker/entrypoint.sh
set -euo pipefail

DATA_DIR="/var/lib/postgresql/17/main"
CONF_DIR="/etc/postgresql/17/main"

echo "=== Starting CASCE Container Entrypoint ==="

# Start PostgreSQL service
service postgresql start

echo "Waiting for PostgreSQL service to accept connections..."
until pg_isready -h localhost -p 5432 -U postgres >/dev/null 2>&1; do
    sleep 1
done
echo "PostgreSQL is ready."

# Ensure pg_telemetry is compiled and installed
if [ -d "/dataset_workspace/pg_telemetry_extension" ]; then
    echo "Compiling and installing pg_telemetry extension..."
    cd /dataset_workspace/pg_telemetry_extension
    make clean >/dev/null 2>&1 || true
    make >/dev/null 2>&1 || true
    make install >/dev/null 2>&1 || true
fi

# Set default password for postgres user
su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD 'password';\""

# If arguments passed, execute them; otherwise open an interactive bash shell
if [ $# -gt 0 ]; then
    exec "$@"
else
    exec /bin/bash
fi
