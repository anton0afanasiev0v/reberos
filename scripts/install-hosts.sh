#!/bin/bash
# Печать фрагмента /etc/hosts для хоста лаборатории с подстановкой
# IP соседней машины (канал между узлами).
#
#   ./scripts/install-hosts.sh a      10.0.0.2 | sudo tee -a /etc/hosts   # Узел А
#   ./scripts/install-hosts.sh b      10.0.0.1 | sudo tee -a /etc/hosts   # Узел Б
#   ./scripts/install-hosts.sh client 10.0.0.1 10.0.0.2 | sudo tee -a /etc/hosts
#
# Docker копирует /etc/hosts хоста внутрь контейнеров при network_mode:
# host — поэтому одного файла на хост достаточно.
set -euo pipefail
cd "$(dirname "$0")/.."

ROLE="${1:-}"
shift || true

A_NAMES="kdc-a1.lab.test kdc-a2.lab.test ldap-a.lab.test web-a.lab.test keycloak-a.lab.test portal-a.lab.test"
B_NAMES="kdc-b3.lab.test kdc-b4.lab.test ldap-b.lab.test web-b.lab.test keycloak-b.lab.test portal-b.lab.test"

case "$ROLE" in
a)
    peer="${1:?нужен IP хоста Узла Б}"
    cat <<EOF
# --- reberos: Узел А (собственные сервисы — на этом хосте) ---
127.0.1.1 $A_NAMES

# --- Узел Б (через канал между хостами) ---
$peer $B_NAMES
EOF
    ;;
b)
    peer="${1:?нужен IP хоста Узла А}"
    cat <<EOF
# --- reberos: Узел Б (собственные сервисы — на этом хосте) ---
127.0.1.1 $B_NAMES

# --- Узел А (через канал между хостами) ---
$peer $A_NAMES
EOF
    ;;
client)
    ip_a="${1:?нужен IP хоста Узла А}"
    ip_b="${2:?нужен IP хоста Узла Б}"
    cat <<EOF
# --- reberos: обе машины (для браузера и kinit с ПК) ---
$ip_a $A_NAMES
$ip_b $B_NAMES
EOF
    ;;
*)
    echo "Использование: $0 {a|b|client} <ip-узла-А> [ip-узла-Б]" >&2
    exit 1
    ;;
esac
