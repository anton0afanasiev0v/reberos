#!/bin/bash
# Перенос образов лаборатории на Узел Б по каналу между хостами.
#
# Канал между узлами ограничен (2 МБ/с), поэтому важно, чтобы по нему
# шёл ровно один перенос образов, а узел Б НИЧЕГО не докачивал сам.
#
# Режимы:
#   bundle  (по умолчанию) docker save -> zstd -> rsync -> docker load.
#            По одному файлу на образ: неизменившиеся rsync пропускает,
#            повторный деплой не передаёт почти ничего.
#   registry               локальный registry на Узле А (порт 5000),
#            узел Б делает docker pull (нужен insecure-registries в dockerd Б).
#   build                 узел Б собирает образы сам (нужен интернет у Б).
#
# Примеры:
#   ./scripts/sync-node-b.sh --peer anton@10.0.0.2
#   ./scripts/sync-node-b.sh --peer anton@10.0.0.2 --mode registry --registry 10.0.0.1:5000
#   ./scripts/sync-node-b.sh --peer anton@10.0.0.2 --mode build
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source ./.env; set +a
PREFIX="${IMAGE_PREFIX:-lab}"
TAG="${IMAGE_TAG:-1}"

PEER=""
MODE="bundle"
BUNDLE_DIR="${BUNDLE_DIR:-/var/tmp/reberos-bundle}"
REMOTE_DIR="${REMOTE_DIR:-/var/tmp/reberos-bundle}"
REGISTRY=""
SKIP_BUILD=0
PACK_ONLY=0
LINK_MBPS="${LINK_MBPS:-2}"

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --peer)     PEER="$2"; shift 2 ;;
        --mode)     MODE="$2"; shift 2 ;;
        --registry) REGISTRY="$2"; shift 2 ;;
        --bundle-dir) BUNDLE_DIR="$2"; shift 2 ;;
        --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
        --link-mbps) LINK_MBPS="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --pack-only) PACK_ONLY=1; shift ;;
        -h|--help)  usage 0 ;;
        *) echo "неизвестный аргумент: $1" >&2; usage 1 ;;
    esac
done

if [ "$PACK_ONLY" = "0" ]; then
    [ -n "$PEER" ] || { echo "ОШИБКА: нужен --peer user@host (ssh-цель Узла Б)" >&2; exit 1; }
fi

IMAGES=(kdc ldap apache keycloak portal)

# --- утилиты ---
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
have()  { command -v "$1" >/dev/null 2>&1; }

need() {
    have "$1" || { echo "ОШИБКА: не хватает утилиты '$1' (apt install $2)" >&2; exit 1; }
}

ssh_do() { ssh -o BatchMode=yes "$PEER" "$@"; }

echo "==> узел Б: $PEER, режим: $MODE"

if [ "$SKIP_BUILD" = "0" ] && [ "$MODE" != "build" ]; then
    echo "==> сборка образов на Узле А"
    ./scripts/build-images.sh
fi

case "$MODE" in

bundle)
    need rsync rsync
    need zstd zstd

    mkdir -p "$BUNDLE_DIR"
    echo "==> упаковка образов в $BUNDLE_DIR"
    for name in "${IMAGES[@]}"; do
        img="${PREFIX}/${name}:${TAG}"
        id="$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null || true)"
        [ -n "$id" ] || { echo "ОШИБКА: нет образа $img (соберите: ./scripts/build-images.sh)" >&2; exit 1; }
        out="${BUNDLE_DIR}/${name}-${TAG}.tar.zst"
        if [ -f "$out" ] && [ -f "${out}.id" ] && [ "$(cat "${out}.id")" = "$id" ]; then
            echo "  ${name}: без изменений ($(human "$(stat -c%s "$out")")) — повторно не упаковываем"
            continue
        fi
        docker save "$img" | zstd -T0 -3 -q -o "${out}.tmp"
        mv -f "${out}.tmp" "$out"
        printf '%s' "$id" > "${out}.id"
        echo "  ${name}: $(human "$(stat -c%s "$out")")"
    done

    total="$(du -cb "$BUNDLE_DIR"/*.tar.zst | tail -1 | cut -f1)"
    echo "==> итого к переносу: $(human "$total")"
    echo "    при ${LINK_MBPS} МБ/с это примерно $(( total / (LINK_MBPS * 1024 * 1024) + 1 )) c"

    if [ "$PACK_ONLY" = "1" ]; then
        echo "==> --pack-only: бандл собран в $BUNDLE_DIR, перенос не выполнялся"
        exit 0
    fi

    echo "==> rsync на узел Б ($REMOTE_DIR)"
    rsync -a --partial --stats --info=progress2 \
        -e "ssh -o BatchMode=yes" \
        "$BUNDLE_DIR/" "$PEER:$REMOTE_DIR/" | tail -12

    echo "==> загрузка образов на узле Б"
    ssh_do "set -e; mkdir -p '$REMOTE_DIR'; cd '$REMOTE_DIR'; for f in *.tar.zst; do [ -f \"\$f\" ] || continue; echo \"  загрузка \$f\"; zstd -dc \"\$f\" | docker load; done; docker images --filter 'reference=${PREFIX}/*' --format '  {{.Repository}}:{{.Tag}}  {{.Size}}'"
    ;;

registry)
    [ -n "$REGISTRY" ] || { echo "ОШИБКА: нужен --registry host:5000 (адрес registry на Узле А)" >&2; exit 1; }
    echo "==> поднимаю локальный registry на Узле А"
    docker compose -f compose-node-a.yml -f compose-node-a.host.yml --profile registry up -d registry
    sleep 2
    for name in "${IMAGES[@]}"; do
        img="${PREFIX}/${name}:${TAG}"
        docker tag "$img" "${REGISTRY}/${name}:${TAG}"
        echo "==> push ${REGISTRY}/${name}:${TAG}"
        docker push "${REGISTRY}/${name}:${TAG}"
    done
    echo "==> pull на узле Б"
    for name in "${IMAGES[@]}"; do
        ssh_do "docker pull '${REGISTRY}/${name}:${TAG}' && docker tag '${REGISTRY}/${name}:${TAG}' '${PREFIX}/${name}:${TAG}'"
    done
    echo "    ВНИМАНИЕ: на узле Б должен быть разрешён registry:"
    echo "    /etc/docker/daemon.json: {\"insecure-registries\": [\"$REGISTRY\"]} + systemctl restart docker"
    ;;

build)
    need rsync rsync
    echo "==> копирую исходники на узел Б (без .git/.vscode/.build)"
    rsync -az --delete --partial \
        --exclude '.git' --exclude '.vscode' --exclude '.build' --exclude '*.tar.zst' \
        -e "ssh -o BatchMode=yes" \
        ./ "$PEER:~/reberos/"
    echo "==> сборка на узле Б (нужен интернет у узла Б)"
    ssh_do "cd ~/reberos && ./scripts/build-images.sh"
    ;;

*)
    echo "ОШИБКА: неизвестный режим '$MODE' (bundle|registry|build)" >&2
    exit 1
    ;;
esac

echo
echo "==> готово. Подъём узла Б:"
echo "    docker compose --env-file .env --env-file deploy/env-b.env \\"
echo "        -f compose-node-b.yml -f compose-node-b.host.yml up -d"
