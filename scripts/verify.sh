#!/bin/bash
# Сквозная проверка лаборатории: kinit, GSSAPI в LDAP, негативные тесты.
# Запуск: ./scripts/verify.sh [--with-apache] [--with-keycloak]
set -euo pipefail
cd "$(dirname "$0")/.."

WITH_APACHE=0
WITH_KEYCLOAK=0
COMPOSE_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --with-apache)   WITH_APACHE=1;   COMPOSE_ARGS+=(--profile apache) ;;
        --with-keycloak) WITH_KEYCLOAK=1; COMPOSE_ARGS+=(--profile keycloak) ;;
        *) echo "неизвестный аргумент: $arg (допустимы --with-apache, --with-keycloak)"; exit 2 ;;
    esac
done

set -a; source ./.env; set +a

COMPOSE=(docker compose ${COMPOSE_ARGS[@]+"${COMPOSE_ARGS[@]}"})

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
    echo "(профиль apache не включён — тесты 7-9 и 13-14 пропущены; запуск: ./scripts/verify.sh --with-apache)"
fi

# --- Мониторинг (Prometheus + Grafana) — входит в базовый состав ---
step "Мониторинг: жду healthcheck prometheus и grafana"
wait_healthy "${PROMETHEUS_HOST}" && ok "prometheus healthy" || bad "prometheus unhealthy"
wait_healthy "${GRAFANA_HOST}" && ok "grafana healthy" || bad "grafana unhealthy"

promql() {
    curl -s "http://127.0.0.1:9090/api/v1/query" --data-urlencode "query=$1" 2>/dev/null
}

# Ждём, пока PromQL-выражение не вернёт ожидаемое значение (до 60 с).
wait_promql() {
    local q="$1" want="$2" out=""
    for _ in $(seq 1 30); do
        out="$(promql "$q")"
        echo "$out" | grep -q "\"value\":\[[^,]*,\"$want\"\]" && return 0
        sleep 2
    done
    echo "      запрос '$q' не вернул '$want': $(echo "$out" | head -c 300)"
    return 1
}

if [ "$WITH_APACHE" = 1 ]; then
    T_UP='min(up)'
    P_OK='min(probe_success)'
else
    # Без apache веб-цели недоступны — исключаем их задачи blackbox.
    T_UP='min(up{job!~"probe-http-web.*"})'
    P_OK='min(probe_success{job!~"probe-http-web.*"})'
fi
if [ "$WITH_KEYCLOAK" != 1 ]; then
    # Без профиля keycloak его scrape-цель недоступна — исключаем задачу.
    if [ "$WITH_APACHE" = 1 ]; then
        T_UP='min(up{job!="keycloak"})'
    else
        T_UP='min(up{job!~"probe-http-web.*|keycloak"})'
    fi
fi

step "10. Prometheus: все таргеты up"
wait_promql "$T_UP" 1 && ok "таргеты Prometheus up" || bad "есть таргеты не up"

step "11. Grafana: API health"
CODE=""
for _ in $(seq 1 30); do
    CODE="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/health || true)"
    [ "$CODE" = "200" ] && break
    sleep 2
done
if [ "$CODE" = "200" ]; then
    ok "Grafana /api/health = 200"
else
    bad "ожидался 200 для /api/health, получен '$CODE'"
fi

step "12. blackbox: все пробы успешны"
wait_promql "$P_OK" 1 && ok "probe_success = 1" || bad "есть неуспешные пробы"

if [ "$WITH_APACHE" = 1 ]; then
    step "13. Grafana через Apache: 401 без билета"
    CODE="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/grafana/ || true)"
    if [ "$CODE" = "401" ]; then
        ok "HTTP 401 для /grafana/ без аутентификации"
    else
        bad "ожидался 401 для /grafana/, получен '$CODE'"
    fi

    step "14. Grafana: 200 по GSSAPI-билету (SSO через REMOTE_USER)"
    exec_c "echo '$ALICE_PASSWORD' | kinit alice" >/dev/null 2>&1 || true
    if exec_c "spnego-check http://${WEB_HOST}/grafana/" >/dev/null 2>&1; then
        ok "SPNEGO-доступ к Grafana прошёл"
    else
        bad "SPNEGO-доступ к Grafana не прошёл"
    fi
fi

if [ "$WITH_KEYCLOAK" = 1 ]; then
    step "15. Keycloak: жду healthcheck"
    wait_healthy "${KEYCLOAK_HOST}" && ok "keycloak healthy" || bad "keycloak unhealthy"

    step "16. Keycloak: realm lab отвечает 200"
    CODE=""
    for _ in $(seq 1 30); do
        CODE="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/realms/lab || true)"
        [ "$CODE" = "200" ] && break
        sleep 2
    done
    if [ "$CODE" = "200" ]; then
        ok "realm lab существует (HTTP 200)"
    else
        bad "ожидался 200 для /realms/lab, получен '$CODE'"
    fi

    step "17. KVNO: сервисный тикет HTTP/keycloak"
    exec_c "echo '$ALICE_PASSWORD' | kinit alice" >/dev/null 2>&1 || true
    if exec_c "kvno HTTP/${KEYCLOAK_HOST}" >/dev/null 2>&1; then
        ok "kvno HTTP/${KEYCLOAK_HOST} выдал сервисный тикет"
    else
        bad "kvno HTTP/${KEYCLOAK_HOST} не прошёл (принципал/keytab?)"
    fi

    step "18. Keycloak: SPNEGO-вход alice (Kerberos flow + LDAP-федерация)"
    exec_c "echo '$ALICE_PASSWORD' | kinit alice" >/dev/null 2>&1 || true
    # account-console — публичный клиент: обязателен PKCE (code_challenge/method),
    # redirect_uri должен совпадать с зарегистрированным /realms/lab/account/*
    KC_AUTH_URL="http://${KEYCLOAK_HOST}:8080/realms/lab/protocol/openid-connect/auth?client_id=account-console&redirect_uri=http%3A%2F%2F${KEYCLOAK_HOST}%3A8080%2Frealms%2Flab%2Faccount%2F&response_type=code&scope=openid&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"
    S9="$(exec_c "spnego-check '$KC_AUTH_URL'" 2>&1 || true)"
    if echo "$S9" | grep -q "HTTP 200\|HTTP 301\|HTTP 302" && ! echo "$S9" | grep -q "error="; then
        ok "SPNEGO-вход в Keycloak прошёл (alice резолвится из LDAP)"
    else
        bad "SPNEGO-вход в Keycloak не прошёл; вывод: $(echo "$S9" | tr '\n' ' ')"
    fi
fi

echo
echo "================ ИТОГ: OK=$PASS, FAIL=$FAIL ================"
[ "$FAIL" = "0" ]
