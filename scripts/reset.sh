#!/bin/bash
# Полная остановка лаборатории с удалением данных (БД KDC, LDAP, keytabs).
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose -f compose-client.yml down -v --remove-orphans
docker compose -f compose-node-b.yml down -v --remove-orphans
docker compose -f compose-node-a.yml down -v --remove-orphans
echo "Лаборатория остановлена, тома удалены."
