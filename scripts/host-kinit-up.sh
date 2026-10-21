#!/bin/bash
# Публикует KDC узла на 127.0.0.1:88 (хост-порт), чтобы kinit с локального ПК
# видел KDC. Обычный `docker compose up` (и verify.sh) пересоздают kdc-a1 без
# override, и порт 88 пропадает — этот скрипт возвращает его.
#
# Использование:
#   ./scripts/host-kinit-up.sh        # узел А (ORG1.TEST), порт 88
#   ./scripts/host-kinit-up.sh b      # узел Б (ORG3.TEST), порт 88
#
# На хосте нужен krb5.conf из docs/host-krb5-node-{a,b}.conf.example (kdc=127.0.0.1).
set -euo pipefail
cd "$(dirname "$0")/.."

node="${1:-a}"
case "$node" in
    a|A) comp="compose-node-a.yml"; over="compose-host-kdc-a.yml"; kdc="kdc-a1"; realm="ORG1.TEST" ;;
    b|B) comp="compose-node-b.yml"; over="compose-host-kdc-b.yml"; kdc="kdc-b3"; realm="ORG3.TEST" ;;
    *) echo "использование: $0 [a|b]" >&2; exit 2 ;;
esac

docker compose -f "$comp" -f "$over" up -d "$kdc"

echo -n "ждём 127.0.0.1:88 ... "
for _ in $(seq 1 30); do
    if ss -lnt 2>/dev/null | grep -q '127.0.0.1:88'; then
        echo "OK"
        echo "realm=$realm — можно: kinit <логин>@$realm"
        exit 0
    fi
    sleep 1
done
echo "не дождались порта 88" >&2
exit 1
