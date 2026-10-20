#!/bin/bash
# Полная остановка лаборатории с удалением данных (БД KDC, LDAP, keytab).
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose --profile apache --profile keycloak down -v --remove-orphans
echo "Лаборатория остановлена, тома удалены."
