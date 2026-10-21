#!/bin/bash
# Сквозная проверка лаборатории (два узла + клиент):
# kinit во все realm, GSSAPI в LDAP (в т.ч. cross-realm), SPNEGO за
# Apache (в т.ч. cross-realm), OIDC-флоу через портал, негативные тесты.
# Запуск: ./scripts/verify.sh
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source ./.env; set +a

CA=(docker compose -f compose-node-a.yml)
CB=(docker compose -f compose-node-b.yml)
CC=(docker compose -f compose-client.yml)

PASS=0; FAIL=0
ok()   { echo "  [OK]   $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
step() { echo; echo "==> $*"; }

exec_c() { "${CC[@]}" exec -T client bash -c "$1"; }

step "Поднимаю Узел А (build + up) — создаёт сеть reberos"
"${CA[@]}" up -d --build

step "Поднимаю Узел Б (build + up)"
"${CB[@]}" up -d --build

step "Поднимаю клиента (build + up)"
"${CC[@]}" up -d --build

wait_healthy() {
    local name=$1 st=""
    for _ in $(seq 1 90); do
        st=$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || echo missing)
        [ "$st" = "healthy" ] && return 0
        sleep 2
    done
    echo "контейнер $name не стал healthy (status=$st), последние логи:"
    docker logs --tail 40 "$name" 2>&1 || true
    return 1
}

step "Жду healthcheck всех сервисов"
for c in "$KDC_A1_HOST" "$KDC_A2_HOST" "$LDAP_A_HOST" "$KEYCLOAK_A_HOST" \
         "$PORTAL_A_HOST" "$WEB_A_HOST" \
         "$KDC_B3_HOST" "$KDC_B4_HOST" "$LDAP_B_HOST" "$KEYCLOAK_B_HOST" \
         "$PORTAL_B_HOST" "$WEB_B_HOST"; do
    if wait_healthy "$c"; then ok "$c healthy"; else bad "$c unhealthy"; fi
done
[ "$FAIL" = "0" ] || { bad "не все сервисы поднялись"; exit 1; }

step "1. kinit alice во все 4 realm (один пароль)"
for R in "$ORG1_REALM" "$ORG2_REALM" "$ORG3_REALM" "$ORG4_REALM"; do
    if exec_c "echo '$ALICE_PASSWORD' | kinit alice@$R" >/dev/null 2>&1; then
        ok "kinit alice@$R"
    else
        bad "kinit alice@$R не прошёл"
    fi
done

step "2. klist: билет на месте"
if exec_c "klist -s" >/dev/null 2>&1; then
    ok "билет есть: $(exec_c 'klist | sed -n 4p' || true)"
else
    bad "билета нет"
fi

step "3. GSSAPI ldap-a с билетом ORG1 (домашний realm)"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG1_REALM" >/dev/null 2>&1 || true
WHO="$(exec_c "ldapwhoami -Y GSSAPI -Q -H ldap://$LDAP_A_HOST" 2>/dev/null || true)"
if echo "$WHO" | grep -q "uid=alice,ou=people"; then
    ok "authz: $WHO"
else
    bad "ожидался uid=alice, получено: '$WHO'"
fi

step "4. GSSAPI ldap-a с билетом ORG2 (cross-realm внутри узла)"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG2_REALM" >/dev/null 2>&1 || true
WHO="$(exec_c "ldapwhoami -Y GSSAPI -Q -H ldap://$LDAP_A_HOST" 2>/dev/null || true)"
if echo "$WHO" | grep -q "uid=alice,ou=people"; then
    ok "cross-realm authz: $WHO"
else
    bad "cross-realm GSSAPI не прошёл; получено: '$WHO'"
fi

step "5. GSSAPI ldap-b с билетом ORG3 (домашний realm узла Б)"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG3_REALM" >/dev/null 2>&1 || true
WHO="$(exec_c "ldapwhoami -Y GSSAPI -Q -H ldap://$LDAP_B_HOST" 2>/dev/null || true)"
if echo "$WHO" | grep -q "uid=alice,ou=people"; then
    ok "authz: $WHO"
else
    bad "ожидался uid=alice, получено: '$WHO'"
fi

step "6. GSSAPI ldap-b с билетом ORG4 (cross-realm внутри узла Б)"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG4_REALM" >/dev/null 2>&1 || true
WHO="$(exec_c "ldapwhoami -Y GSSAPI -Q -H ldap://$LDAP_B_HOST" 2>/dev/null || true)"
if echo "$WHO" | grep -q "uid=alice,ou=people"; then
    ok "cross-realm authz: $WHO"
else
    bad "cross-realm GSSAPI не прошёл; получено: '$WHO'"
fi

step "7. негатив: билет ORG1 -> ldap-b (между узлами доверия нет)"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG1_REALM" >/dev/null 2>&1 || true
if exec_c "ldapwhoami -Y GSSAPI -Q -H ldap://$LDAP_B_HOST" >/dev/null 2>&1; then
    bad "межузловой GSSAPI сработал без доверия!"
else
    ok "межузловой доступ отклонён"
fi

step "8. негатив: после kdestroy GSSAPI-поиск падает"
exec_c "kdestroy" >/dev/null 2>&1 || true
if exec_c "ldapsearch -Y GSSAPI -Q -H ldap://$LDAP_A_HOST -b dc=lab,dc=test '(uid=alice)' dn" >/dev/null 2>&1; then
    bad "GSSAPI сработал без билета!"
else
    ok "без билета — отказ в доступе"
fi

step "9. негатив: анонимный simple-поиск не видит записи людей"
if exec_c "ldapsearch -x -H ldap://$LDAP_A_HOST -b dc=lab,dc=test '(uid=alice)' dn" 2>/dev/null | grep -q "uid=alice"; then
    bad "анонимный клиент увидел alice"
else
    ok "аноним не видит данные"
fi

step "10. web-a: 401 без аутентификации"
CODE="$(exec_c "curl -s -o /dev/null -w '%{http_code}' http://$WEB_A_HOST/" || true)"
if [ "$CODE" = "401" ]; then
    ok "HTTP 401"
else
    bad "ожидался 401, получен '$CODE'"
fi

step "11. web-a: 200 по SPNEGO с билетом ORG1"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG1_REALM" >/dev/null 2>&1 || true
S="$(exec_c "spnego-check http://$WEB_A_HOST/" 2>&1 || true)"
if echo "$S" | grep -q "Узел А" && echo "$S" | grep -q "$ORG1_REALM"; then
    ok "портал открылся, SPNEGO-личность представлена"
else
    bad "SPNEGO не прошёл или страница не та; вывод: $(echo "$S" | tr '\n' ' ')"
fi

step "12. web-a: 200 по SPNEGO с билетом ORG2 (cross-realm)"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG2_REALM" >/dev/null 2>&1 || true
S="$(exec_c "spnego-check http://$WEB_A_HOST/" 2>&1 || true)"
if echo "$S" | grep -q "Узел А"; then
    ok "cross-realm SPNEGO прошёл"
else
    bad "cross-realm SPNEGO не прошёл; вывод: $(echo "$S" | tr '\n' ' ')"
fi

step "13. web-b: 401 и 200 по SPNEGO с билетом ORG3"
CODE="$(exec_c "curl -s -o /dev/null -w '%{http_code}' http://$WEB_B_HOST/" || true)"
if [ "$CODE" = "401" ]; then ok "HTTP 401 без аутентификации"; else bad "ожидался 401, получен '$CODE'"; fi
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG3_REALM" >/dev/null 2>&1 || true
S="$(exec_c "spnego-check http://$WEB_B_HOST/" 2>&1 || true)"
if echo "$S" | grep -q "Узел Б"; then ok "SPNEGO-доступ прошёл"; else bad "SPNEGO не прошёл; $(echo "$S" | tr '\n' ' ')"; fi

step "14. web-b: 200 по SPNEGO с билетом ORG4 (cross-realm)"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG4_REALM" >/dev/null 2>&1 || true
S="$(exec_c "spnego-check http://$WEB_B_HOST/" 2>&1 || true)"
if echo "$S" | grep -q "Узел Б"; then ok "cross-realm SPNEGO прошёл"; else bad "cross-realm SPNEGO не прошёл; $(echo "$S" | tr '\n' ' ')"; fi

step "15. негатив: билет ORG1 -> web-b (между узлами доверия нет)"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG1_REALM" >/dev/null 2>&1 || true
if exec_c "spnego-check http://$WEB_B_HOST/" >/dev/null 2>&1; then
    bad "межузловой SPNEGO сработал без доверия!"
else
    ok "межузловой SPNEGO отклонён"
fi

step "16. Keycloak (уровень 2): realm через Apache /auth, без SPNEGO"
CODE=""
for _ in $(seq 1 30); do
    CODE="$(exec_c "curl -s -o /dev/null -w '%{http_code}' http://$WEB_A_HOST/auth/realms/$KC_A_REALM" || true)"
    [ "$CODE" = "200" ] && break
    sleep 2
done
if [ "$CODE" = "200" ]; then
    ok "realm $KC_A_REALM отвечает 200 через Apache"
else
    bad "ожидался 200 для /auth/realms/$KC_A_REALM, получен '$CODE'"
fi
CODE="$(exec_c "curl -s -o /dev/null -w '%{http_code}' http://$WEB_B_HOST/auth/realms/$KC_B_REALM" || true)"
if [ "$CODE" = "200" ]; then
    ok "realm $KC_B_REALM отвечает 200 через Apache"
else
    bad "ожидался 200 для /auth/realms/$KC_B_REALM, получен '$CODE'"
fi

step "17. OIDC: полный флоу через портал (SPNEGO + логин-форма Keycloak)"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG1_REALM" >/dev/null 2>&1 || true
if exec_c "oidc-check http://$WEB_A_HOST $ORG1_REALM alice '$ALICE_PASSWORD'" >/tmp/oidc.out 2>&1; then
    ok "id_token получен, организация $ORG1_REALM, SPNEGO-личность сохранена"
else
    bad "OIDC-флоу не прошёл; вывод: $(cat /tmp/oidc.out | tr '\n' ' ' | head -c 500)"
fi

step "18. OIDC на узле Б"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG4_REALM" >/dev/null 2>&1 || true
if exec_c "oidc-check http://$WEB_B_HOST $ORG4_REALM alice '$ALICE_PASSWORD'" >/tmp/oidc2.out 2>&1; then
    ok "id_token получен (ORG4, cross-realm SPNEGO + OIDC)"
else
    bad "OIDC-флоу не прошёл; вывод: $(cat /tmp/oidc2.out | tr '\n' ' ' | head -c 500)"
fi

step "19. негатив: /me без OIDC-сессии -> отказ даже при SPNEGO"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG1_REALM" >/dev/null 2>&1 || true
# spnego-check не шлёт cookie: SPNEGO проходит, но portal без sid -> 401.
if exec_c "spnego-check http://$WEB_A_HOST/me" >/dev/null 2>&1; then
    bad "/me открыл без OIDC-сессии"
else
    ok "/me без сессии отклонён (HTTP 401)"
fi

echo
echo "================ ИТОГ: OK=$PASS, FAIL=$FAIL ================"
[ "$FAIL" = "0" ]
