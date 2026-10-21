#!/bin/bash
# Сквозная проверка лаборатории (два узла + клиент):
# kinit во все realm, GSSAPI в LDAP (в т.ч. cross-realm), SPNEGO за
# Apache (в т.ч. cross-realm), OIDC-флоу через портал, негативные тесты.
# Запуск: ./scripts/verify.sh
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source ./.env; set +a

# Режимы развёртывания:
#   LAB_REMOTE_B=1  Узел Б поднят на ДРУГОМ хосте (канал между узлами):
#                   локально его не поднимаем, проверяем доступность
#                   по сети. Требует LAB_HOST_NET=1 (включается сам).
#   LAB_HOST_NET=1  контейнеры в network_mode: host (схема «два хоста»),
#                   имена сервисов резолвятся через /etc/hosts хоста.
REMOTE_B="${LAB_REMOTE_B:-0}"
HOST_NET="${LAB_HOST_NET:-0}"
[ "$REMOTE_B" = "1" ] && HOST_NET=1

CA=(docker compose -f compose-node-a.yml)
CB=(docker compose -f compose-node-b.yml)
CC=(docker compose -f compose-client.yml)
if [ "$HOST_NET" = "1" ]; then
    CA=(docker compose --env-file .env --env-file deploy/env-a.env
        -f compose-node-a.yml -f compose-node-a.host.yml)
    CB=(docker compose --env-file .env --env-file deploy/env-b.env
        -f compose-node-b.yml -f compose-node-b.host.yml)
    CC=(docker compose --env-file .env --env-file deploy/env-a.env
        -f compose-client.yml -f compose-client.host.yml)
fi

PASS=0; FAIL=0
ok()   { echo "  [OK]   $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
step() { echo; echo "==> $*"; }

exec_c() { "${CC[@]}" exec -T client bash -c "$1"; }

# Пароль конкретного логина из "логин=пароль ..." (узел A: org1/org2, Б: org3/org4).
pw_a() { for pair in $ORG_USER_PASSWORDS_A; do case "$pair" in "$1"=*) echo "${pair#*=}"; return;; esac; done; }
pw_b() { for pair in $ORG_USER_PASSWORDS_B; do case "$pair" in "$1"=*) echo "${pair#*=}"; return;; esac; done; }
pw() { case "$1" in org1*|org2*) pw_a "$1";; *) pw_b "$1";; esac; }

step "Поднимаю Узел А (build + up) — создаёт сеть kerberos"
"${CA[@]}" up -d --build

if [ "$REMOTE_B" = "1" ]; then
    step "Узел Б удалённый (канал между хостами) — локально не поднимаю"
else
    step "Поднимаю Узел Б (build + up)"
    "${CB[@]}" up -d --build
fi

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

# TCP-проба сервиса удалённого узла из контейнера клиента.
probe_tcp() {
    exec_c "timeout 3 bash -c 'exec 3<>/dev/tcp/$1/$2'" >/dev/null 2>&1
}

step "Жду healthcheck сервисов Узла А"
for c in "$KDC_A1_HOST" "$KDC_A2_HOST" "$LDAP_A_HOST" "$KEYCLOAK_A_HOST" \
         "$PORTAL_A_HOST" "$WEB_A_HOST"; do
    if wait_healthy "$c"; then ok "$c healthy"; else bad "$c unhealthy"; fi
done

if [ "$REMOTE_B" = "1" ]; then
    step "Проверяю доступность удалённого Узла Б по сети"
    for pair in "$KDC_B3_HOST:88" "$KDC_B4_HOST:88" "$LDAP_B_HOST:389" \
                "$KEYCLOAK_B_HOST:8080" "$PORTAL_B_HOST:8000" "$WEB_B_HOST:80"; do
        h="${pair%:*}"; p="${pair##*:}"
        if probe_tcp "$h" "$p"; then ok "$h:$p доступен"; else bad "$h:$p недоступен"; fi
    done
else
    step "Жду healthcheck сервисов Узла Б"
    for c in "$KDC_B3_HOST" "$KDC_B4_HOST" "$LDAP_B_HOST" "$KEYCLOAK_B_HOST" \
             "$PORTAL_B_HOST" "$WEB_B_HOST"; do
        if wait_healthy "$c"; then ok "$c healthy"; else bad "$c unhealthy"; fi
    done
fi
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
if echo "$WHO" | grep -q "uid=alice,ou=org1,ou=people"; then
    ok "authz: $WHO"
else
    bad "ожидался uid=alice, получено: '$WHO'"
fi

step "4. GSSAPI ldap-a с билетом ORG2 (cross-realm внутри узла)"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG2_REALM" >/dev/null 2>&1 || true
WHO="$(exec_c "ldapwhoami -Y GSSAPI -Q -H ldap://$LDAP_A_HOST" 2>/dev/null || true)"
if echo "$WHO" | grep -q "uid=alice,ou=org1,ou=people"; then
    ok "cross-realm authz: $WHO"
else
    bad "cross-realm GSSAPI не прошёл; получено: '$WHO'"
fi

step "5. GSSAPI ldap-b с билетом ORG3 (домашний realm узла Б)"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG3_REALM" >/dev/null 2>&1 || true
WHO="$(exec_c "ldapwhoami -Y GSSAPI -Q -H ldap://$LDAP_B_HOST" 2>/dev/null || true)"
if echo "$WHO" | grep -q "uid=alice,ou=org3,ou=people"; then
    ok "authz: $WHO"
else
    bad "ожидался uid=alice, получено: '$WHO'"
fi

step "6. GSSAPI ldap-b с билетом ORG4 (cross-realm внутри узла Б)"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG4_REALM" >/dev/null 2>&1 || true
WHO="$(exec_c "ldapwhoami -Y GSSAPI -Q -H ldap://$LDAP_B_HOST" 2>/dev/null || true)"
if echo "$WHO" | grep -q "uid=alice,ou=org3,ou=people"; then
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

step "20. orgNuserM: kinit в свой realm (индивидуальные пароли)"
# Логин привязан к организации: org1user1@ORG1, org2user1@ORG2 и т.д.
for U in org1user1 org2user1 org3user1 org4user1; do
    R="${U%%user*}"; R="$(echo "$R" | tr 'a-z' 'A-Z').TEST"
    P="$(pw "$U")"
    if exec_c "echo '$P' | kinit $U@$R" >/dev/null 2>&1; then
        ok "kinit $U@$R"
    else
        bad "kinit $U@$R не прошёл (пароль '$P')"
    fi
done

step "21. изоляция: org1user1@ORG1 -> uid=org1user1,ou=org1,ou=people..."
exec_c "echo '$(pw org1user1)' | kinit org1user1@$ORG1_REALM" >/dev/null 2>&1 || true
WHO="$(exec_c "ldapwhoami -Y GSSAPI -Q -H ldap://$LDAP_A_HOST" 2>/dev/null || true)"
if echo "$WHO" | grep -q "uid=org1user1,ou=org1,ou=people"; then
    ok "authz: $WHO"
else
    bad "ожидался uid=org1user1,ou=org1,ou=people; получено: '$WHO'"
fi

step "22. изоляция: org1user1@ORG1 видит ТОЛЬКО свою ветку (org1), не org2"
exec_c "echo '$(pw org1user1)' | kinit org1user1@$ORG1_REALM" >/dev/null 2>&1 || true
V1="$(exec_c "ldapsearch -Y GSSAPI -Q -H ldap://$LDAP_A_HOST -b ou=org1,ou=people,dc=lab,dc=test '(uid=org1user1)' dn" 2>/dev/null || true)"
if echo "$V1" | grep -q "uid=org1user1,ou=org1"; then
    ok "org1user1 видит свою ветку org1"
else
    bad "org1user1 не видит свою ветку; вывод: $(echo "$V1" | tr '\n' ' ' | head -c 200)"
fi
V2="$(exec_c "ldapsearch -Y GSSAPI -Q -H ldap://$LDAP_A_HOST -b ou=org2,ou=people,dc=lab,dc=test '(uid=org2user1)' dn" 2>/dev/null || true)"
if echo "$V2" | grep -q "uid=org2user1,ou=org2"; then
    bad "org1user1@ORG1 увидел ветку org2!"
else
    ok "org1user1 не видит ветку org2 (изоляция)"
fi

step "23. cross-realm: org2user1@ORG2 маппится в org2, org1 недоступна"
exec_c "echo '$(pw org2user1)' | kinit org2user1@$ORG2_REALM" >/dev/null 2>&1 || true
WHO="$(exec_c "ldapwhoami -Y GSSAPI -Q -H ldap://$LDAP_A_HOST" 2>/dev/null || true)"
if echo "$WHO" | grep -q "uid=org2user1,ou=org2,ou=people"; then
    ok "authz: $WHO"
else
    bad "ожидался uid=org2user1,ou=org2,ou=people; получено: '$WHO'"
fi
W1="$(exec_c "ldapsearch -Y GSSAPI -Q -H ldap://$LDAP_A_HOST -b ou=org1,ou=people,dc=lab,dc=test '(uid=org1user1)' dn" 2>/dev/null || true)"
if echo "$W1" | grep -q "uid=org1user1,ou=org1"; then
    bad "org2user1@ORG2 увидел ветку org1!"
else
    ok "org2user1@ORG2 не видит ветку org1 (cross-realm изоляция)"
fi

step "24. админ узла: admin@ORG1 видит org1 и org2"
exec_c "echo '$NODE_ADMIN_PASSWORD' | kinit admin@$ORG1_REALM" >/dev/null 2>&1 || true
WHO="$(exec_c "ldapwhoami -Y GSSAPI -Q -H ldap://$LDAP_A_HOST" 2>/dev/null || true)"
if echo "$WHO" | grep -q "uid=admin,ou=admins"; then
    ok "authz: $WHO"
else
    bad "ожидался uid=admin,ou=admins; получено: '$WHO'"
fi
A1="$(exec_c "ldapsearch -Y GSSAPI -Q -H ldap://$LDAP_A_HOST -b ou=org1,ou=people,dc=lab,dc=test '(uid=org1user1)' dn" 2>/dev/null || true)"
A2="$(exec_c "ldapsearch -Y GSSAPI -Q -H ldap://$LDAP_A_HOST -b ou=org2,ou=people,dc=lab,dc=test '(uid=org2user1)' dn" 2>/dev/null || true)"
if echo "$A1" | grep -q "uid=org1user1,ou=org1" && echo "$A2" | grep -q "uid=org2user1,ou=org2"; then
    ok "admin видит обе организации узла"
else
    bad "admin не видит обе ветки (org1:'$(echo "$A1" | tr '\n' ' ' | head -c 120)' org2:'$(echo "$A2" | tr '\n' ' ' | head -c 120)')"
fi

step "25. alice (smoke-исключение) читает обе ветки"
exec_c "echo '$ALICE_PASSWORD' | kinit alice@$ORG1_REALM" >/dev/null 2>&1 || true
S1="$(exec_c "ldapsearch -Y GSSAPI -Q -H ldap://$LDAP_A_HOST -b ou=org1,ou=people,dc=lab,dc=test '(uid=org1user1)' dn" 2>/dev/null || true)"
S2="$(exec_c "ldapsearch -Y GSSAPI -Q -H ldap://$LDAP_A_HOST -b ou=org2,ou=people,dc=lab,dc=test '(uid=org2user1)' dn" 2>/dev/null || true)"
if echo "$S1" | grep -q "uid=org1user1,ou=org1" && echo "$S2" | grep -q "uid=org2user1,ou=org2"; then
    ok "alice читает org1 и org2 (исключение)"
else
    bad "alice не видит обе ветки (org1:'$(echo "$S1" | tr '\n' ' ' | head -c 120)' org2:'$(echo "$S2" | tr '\n' ' ' | head -c 120)')"
fi

step "26. Keycloak: вход org1user1 — LDAP-федерация видит обе org (нет username_in_use)"
# SPNEGO-билет org1user1@ORG1 + логин-форма Keycloak как org1user1.
exec_c "echo '$(pw org1user1)' | kinit org1user1@$ORG1_REALM" >/dev/null 2>&1 || true
if exec_c "oidc-check http://$WEB_A_HOST $ORG1_REALM org1user1 '$(pw org1user1)'" >/tmp/oidc-u1.out 2>&1; then
    ok "org1user1: OIDC-вход прошёл (usersDn=ou=people)"
else
    bad "org1user1: OIDC-вход не прошёл; вывод: $(cat /tmp/oidc-u1.out | tr '\n' ' ' | head -c 500)"
fi
# org2user1 виден в Keycloak (уникальные логины — обе организации).
exec_c "echo '$(pw org2user1)' | kinit org2user1@$ORG2_REALM" >/dev/null 2>&1 || true
if exec_c "oidc-check http://$WEB_A_HOST $ORG2_REALM org2user1 '$(pw org2user1)'" >/tmp/oidc-u2.out 2>&1; then
    ok "org2user1: OIDC-вход прошёл (Keycloak видит и org2)"
else
    bad "org2user1: OIDC-вход не прошёл; вывод: $(cat /tmp/oidc-u2.out | tr '\n' ' ' | head -c 500)"
fi

step "27. портал: org-gate — org1user1@ORG1 не входит в чужую ORG2"
# Билет org1user1@ORG1: домашняя ORG1 -> 302, чужая ORG2 -> 403.
exec_c "echo '$(pw org1user1)' | kinit org1user1@$ORG1_REALM" >/dev/null 2>&1 || true
C_OWN="$(exec_c "curl -s -o /dev/null -w '%{http_code}' --negotiate -u : 'http://$WEB_A_HOST/login?org=$ORG1_REALM'" 2>/dev/null || true)"
C_OTHER="$(exec_c "curl -s -o /dev/null -w '%{http_code}' --negotiate -u : 'http://$WEB_A_HOST/login?org=$ORG2_REALM'" 2>/dev/null || true)"
if [ "$C_OWN" = "302" ] && [ "$C_OTHER" = "403" ]; then
    ok "домашняя ORG1=$C_OWN, чужая ORG2=$C_OTHER (org-gate)"
else
    bad "org-gate: ожидалось ORG1=302/ORG2=403, получено ORG1=$C_OWN/ORG2=$C_OTHER"
fi

step "28. негатив: знание SPN не даёт билет (чужой realm / другой узел)"
# Контроль: свой realm — билет есть (иначе негативы «проходят» из-за поломки).
exec_c "echo '$(pw org1user1)' | kinit org1user1@$ORG1_REALM" >/dev/null 2>&1 || true
P0="$(exec_c "kvno ldap/$LDAP_A_HOST@$ORG1_REALM" 2>&1 || true)"
if echo "$P0" | grep -qE "kvno = [0-9]+"; then
    ok "контроль: билет на свой realm есть (ldap/$LDAP_A_HOST@$ORG1_REALM)"
else
    bad "контроль не пройден: $(echo "$P0" | tr '\n' ' ' | head -c 200)"
fi
# (а) тот же узел, чужой realm: в базе ORG2 нет сервисных принципалов -> KDC отказывает.
P1="$(exec_c "kvno ldap/$LDAP_A_HOST@$ORG2_REALM" 2>&1 || true)"
if echo "$P1" | grep -q "not found in Kerberos database"; then
    ok "билет на SPN чужого realm ($ORG2_REALM) не выдан"
else
    bad "ожидался отказ KDC на SPN чужого realm; получено: $(echo "$P1" | tr '\n' ' ' | head -c 200)"
fi
# (б) другой узел: trust'а между ORG1 и ORG3 нет -> нет krbtgt/ORG3.TEST@ORG1.TEST.
P2="$(exec_c "kvno ldap/$LDAP_B_HOST@$ORG3_REALM" 2>&1 || true)"
if echo "$P2" | grep -q "krbtgt/$ORG3_REALM@$ORG1_REALM not found"; then
    ok "билет на сервис другого узла ($ORG3_REALM) не выдан (trust'а нет)"
else
    bad "ожидался отказ по отсутствию trust'а; получено: $(echo "$P2" | tr '\n' ' ' | head -c 200)"
fi

echo
echo "================ ИТОГ: OK=$PASS, FAIL=$FAIL ================"
[ "$FAIL" = "0" ]
