#!/bin/bash
# Сквозная проверка в схеме «два хоста»: Узел А и клиент — локально,
# Узел Б — на соседней машине (канал между узлами ограничен).
#
#   ./scripts/verify-remote.sh
#
# Требования:
#   * на Узле А: /etc/hosts содержит имена обоих узлов
#     (./scripts/install-hosts.sh a <ip-узла-Б> | sudo tee -a /etc/hosts);
#   * Узел Б поднят: docker compose --env-file .env --env-file deploy/env-b.env
#       -f compose-node-b.yml -f compose-node-b.host.yml up -d
#   * образы на Узле Б уже загружены (scripts/sync-node-b.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

LAB_REMOTE_B=1
LAB_HOST_NET=1
export LAB_REMOTE_B LAB_HOST_NET

exec ./scripts/verify.sh "$@"
