#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "#############################################"
echo "Installing Moodle"
echo "#############################################"

docker compose \
    --env-file .env \
    --env-file .env.install \
    -f docker-compose.yml \
    -f docker-compose-install.yml \
    up -d

echo ""
echo "View status of installation:"
echo "  docker compose logs moodle -f"
echo ""
echo "Normal future startup:"
echo "  docker compose up -d"
