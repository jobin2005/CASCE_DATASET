#!/bin/bash
set -euo pipefail

echo "Building and starting casce_environment..."
docker compose up -d --build

echo "Waiting for the container to report healthy..."
for i in $(seq 1 30); do
    if docker exec casce_environment pg_isready -U postgres >/dev/null 2>&1; then
        echo "PostgreSQL is up."
        break
    fi
    sleep 1
done

echo "Environment ready. Enter it with:"
echo "  docker exec -it --user root casce_environment bash"