#!/bin/bash
# Сквозная проверка лаборатории: kinit, GSSAPI в LDAP, негативные тесты.
# Запуск: ./scripts/verify.sh [--with-apache]
set -euo pipefail
cd "$(dirname "$0")/.."

WITH_APACHE=0
[ "${1:-}" = "--with-apache" ] && WITH_APACHE=1

set -a; source ./.env; set +a

COMPOSE=(docker compose)
[ "$WITH_APACHE" = 1 ] && COMPOSE=(docker compose --profile apache)

PASS=0; FAIL=0
ok()   { echo "  [OK]   $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
step() { echo; echo "==> $*"; }

exec_c() { "${COMPOSE[@]}" exec -T client bash -c "$1"; }

step "Поднимаю лабораторию (build + up)"
"${COMPOSE[@]}" up -d --build

wait_healthy() {
    local name=$1 st=""
    for _ in $(seq 1 60); do
        st=$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || echo missing)
        [ "$st" = "healthy" ] && return 0
        sleep 2
    done
    echo "контейнер $name не стал healthy (status=$st), последние логи:"
    "${COMPOSE[@]}" logs --tail 40 "$name" || true
    return 1
}

step "Жду healthcheck kdc и ldap"
wait_healthy "${KDC_HOST}" && ok "kdc healthy" || { bad "kdc unhealthy"; exit 1; }
wait_healthy "${LDAP_HOST}" && ok "ldap healthy" || { bad "ldap unhealthy"; exit 1; }

step "1. kinit alice (по паролю)"
if exec_c "echo '$ALICE_PASSWORD' | kinit alice" >/dev/null 2>&1; then
    ok "alice получила TGT"
else
    bad "kinit alice не прошёл"
fi

step "2. klist: билет krbtgt на месте"
if exec_c "klist -s" >/dev/null 2>&1; then
    ok "билет есть: $(exec_c 'klist | sed -n 4p' || true)"
else
    bad "билета нет"
fi

step "3. ldapwhoami -Y GSSAPI (маппинг principal -> LDAP DN)"
WHO="$(exec_c 'ldapwhoami -Y GSSAPI -Q' 2>/dev/null || true)"
if echo "$WHO" | grep -q "uid=alice,ou=people"; then
    ok "authz: $WHO"
else
    bad "неожиданная authz-идентичность: '$WHO'"
fi

step "4. ldapsearch -Y GSSAPI: поиск alice по каталогу"
S4="$(exec_c "ldapsearch -Y GSSAPI -Q -b dc=lab,dc=test '(uid=alice)' dn" 2>&1 || true)"
if echo "$S4" | grep -q "uid=alice"; then
    ok "GSSAPI-поиск вернул запись alice"
else
    bad "GSSAPI-поиск не нашёл alice; вывод: $(echo "$S4" | tr '\n' ' ')"
fi

step "5. негатив: после kdestroy GSSAPI-поиск должен падать"
exec_c "kdestroy" >/dev/null 2>&1 || true
if exec_c "ldapsearch -Y GSSAPI -Q -b dc=lab,dc=test '(uid=alice)' dn" >/dev/null 2>&1; then
    bad "GSSAPI сработал без билета!"
else
    ok "без билета — отказ в доступе"
fi

step "6. анонимный simple-поиск не видит записи людей"
if exec_c "ldapsearch -x -b dc=lab,dc=test '(uid=alice)' dn" 2>/dev/null | grep -q "uid=alice"; then
    bad "анонимный клиент увидел alice"
else
    ok "аноним не видит данные"
fi

if [ "$WITH_APACHE" = 1 ]; then
    step "Жду healthcheck web"
    wait_healthy "${WEB_HOST}" && ok "web healthy" || bad "web unhealthy"

    step "7. Apache: 401 без билета"
    CODE="$(exec_c "curl -s -o /dev/null -w '%{http_code}' http://${WEB_HOST}/" || true)"
    if [ "$CODE" = "401" ]; then
        ok "HTTP 401 без аутентификации"
    else
        bad "ожидался 401, получен '$CODE'"
    fi

    step "8. Apache: /public без билета (HTTP 200, с хоста)"
    PUB="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/public/ || true)"
    if [ "$PUB" = "200" ]; then
        ok "публичная страница открыта без аутентификации"
    else
        bad "ожидался 200 для /public, получен '$PUB'"
    fi

    step "9. Apache: 200 по GSSAPI-билету (SPNEGO)"
    exec_c "echo '$ALICE_PASSWORD' | kinit alice" >/dev/null 2>&1 || true
    S8="$(exec_c "spnego-check http://${WEB_HOST}/" 2>&1 || true)"
    if echo "$S8" | grep -q "Kerberos"; then
        ok "SPNEGO-запрос прошёл аутентификацию"
    else
        bad "SPNEGO не прошёл; вывод: $(echo "$S8" | tr '\n' ' ')"
    fi
else
    echo
    echo "(профиль apache не включён — тесты 7-9 пропущены; запуск: ./scripts/verify.sh --with-apache)"
fi

echo
echo "================ ИТОГ: OK=$PASS, FAIL=$FAIL ================"
[ "$FAIL" = "0" ]
