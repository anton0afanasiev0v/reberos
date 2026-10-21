#!/bin/bash
# Единая сборка образов лаборатории с общими тегами lab/<svc>:1.
#
# Образы собираются ОДИН раз (на Узле А) и переносятся на Узел Б как
# есть — scripts/sync-node-b.sh. Пересборка на втором узле означала бы
# повторную закачку apt-пакетов и базовых образов (~400 МБ) по каналу
# между хостами.
#
#   ./scripts/build-images.sh
#   IMAGE_PREFIX=lab IMAGE_TAG=2 ./scripts/build-images.sh
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source ./.env; set +a
PREFIX="${IMAGE_PREFIX:-lab}"
TAG="${IMAGE_TAG:-1}"

# тег:Dockerfile — по одному образу на роль, а не на сервис:
# kdc-a1/kdc-a2/b3/b4 используют один и тот же образ.
IMAGES=(
    "kdc:kdc/Dockerfile"
    "ldap:ldap/Dockerfile"
    "apache:apache/Dockerfile"
    "keycloak:keycloak/Dockerfile"
    "portal:portal/Dockerfile"
    "client:client/Dockerfile"
)

echo "==> сборка образов ${PREFIX}/*:${TAG}"
for spec in "${IMAGES[@]}"; do
    name="${spec%%:*}"
    dockerfile="${spec#*:}"
    printf '  %-10s <- %s\n' "$name" "$dockerfile"
    docker build -t "${PREFIX}/${name}:${TAG}" -f "$dockerfile" .
done

echo
echo "==> готово:"
docker images --filter "reference=${PREFIX}/*" --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}'
