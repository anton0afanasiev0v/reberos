#!/bin/bash
# Проверки нативного «Узла А» на Astra Linux SE 1.7 (БЕЗ Docker):
# Kerberos (2 realm'а) + OpenLDAP (GSSAPI, изоляция организаций).
#
#   sudo ./scripts/astra-node-a-verify.sh
#   sudo ./scripts/astra-node-a-verify.sh --env deploy/astra-node-a.env
#
# Скрипт ничего не меняет: только читает состояние и делает аутентификации.
set -uo pipefail
cd "$(dirname "$0")/.."

ENV_FILE="deploy/astra-node-a.env"
while [ $# -gt 0 ]; do
    case "$1" in
        --env) ENV_FILE="$2"; shift 2 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
done

[ -f "$ENV_FILE" ] || { echo "НЕТ ФАЙЛА ПАРАМЕТРОВ: $ENV_FILE" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

DC_BASE="$(printf '%s' "$DOMAIN" | awk -F. '{printf "dc=%s", $1; for(i=2;i<=NF;i++) printf ",dc=%s", $i}')"

PASS=0; FAIL=0
ok()   { echo "  [OK]   $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $*"; }
step() { echo; echo "==> $*"; }

# Пароль пользователя из списка "логин=пароль ...".
pw_of() {
    local pair
    for pair in $ORG_USER_PASSWORDS; do
        case "$pair" in "$1"=*) echo "${pair#*=}"; return ;; esac
    done
    return 1
}

# kinit + ldapwhoami одним ccache. Печатает DN.
gssapi_dn() {
    # gssapi_dn <principal> <password>
    local ccache="/tmp/krb5cc_verify_$$"
    kinit -c "$ccache" "$1" <<< "$2" >/dev/null 2>&1 || { rm -f "$ccache"; return 1; }
    KRB5CCNAME="$ccache" ldapwhoami -Y GSSAPI -Q -H "ldap://$LDAP_HOST" 2>&1 | tr -d '\r'
    rm -f "$ccache"
}

step "Сервисы"
for svc in krb5-kdc krb5-admin-server "$SLAPD_UNIT"; do
    if systemctl is-active --quiet "$svc"; then ok "$svc active"; else bad "$svc НЕ active"; fi
done
# Если slapd не поднялся — сразу показываем журнал.
if ! systemctl is-active --quiet "$SLAPD_UNIT"; then
    echo "  журнал $SLAPD_UNIT:"
    journalctl -u "$SLAPD_UNIT" -n 30 --no-pager 2>&1 | sed 's/^/    /' || true
fi

step "Имена и окружение"
for h in "$KDC_A_HOST" "$KDC_B_HOST" "$LDAP_HOST"; do
    if getent hosts "$h" >/dev/null 2>&1; then ok "$h резолвится"; else bad "$h НЕ резолвится (нужна запись в /etc/hosts)"; fi
done
# GSSAPI-клиент берёт имя сервиса из ОБРАТНОГО резолва peer'а: у ldap-a
# должен быть отдельный адрес (не 127.0.0.1/localhost), иначе Cyrus SASL
# подставит имя машины и запросит ldap/<hostname>@realm.
ldap_ip="$(getent hosts "$LDAP_HOST" | awk 'NR==1{print $1}')"
ldap_rev="$(getent hosts "$ldap_ip" 2>/dev/null | awk 'NR==1{print $2}')"
if [ "$ldap_ip" = "127.0.0.1" ]; then
    bad "$LDAP_HOST -> 127.0.0.1: обратный резолв даст localhost, GSSAPI сломается (нужен 127.0.0.2 и т.п.)"
elif [ -n "$ldap_ip" ] && [ "$ldap_rev" = "$LDAP_HOST" ]; then
    ok "$LDAP_HOST -> $ldap_ip (обратный резолв = $ldap_rev)"
elif [ -n "$ldap_ip" ]; then
    bad "$LDAP_HOST -> $ldap_ip, но обратный резолв = '$ldap_rev' (ожидался $LDAP_HOST)"
fi
# Штатный slapd.service дистрибутива не должен занимать порт 389.
if systemctl list-unit-files 2>/dev/null | grep -q "^slapd\.service"; then
    if systemctl is-active --quiet slapd.service; then
        bad "штатный slapd.service активен — конфликт с $SLAPD_UNIT по порту 389"
    else
        ok "штатный slapd.service выключен"
    fi
else
    ok "штатного slapd.service нет"
fi

step "Порты KDC/LDAP"
port_listening() {
    # port_listening <port> <proto> — ss -lntu (1-я колонка: tcp/udp)
    ss -lntup 2>/dev/null | awk -v p=":$1\$" -v pr="$2" '$1 == pr && $5 ~ p {found=1} END{exit !found}'
}
if port_listening 88 udp; then ok "88/udp слушается"; else bad "88/udp НЕ слушается"; fi
if port_listening 88 tcp; then ok "88/tcp слушается"; else bad "88/tcp НЕ слушается"; fi
if port_listening 749 tcp; then ok "749/tcp (kadmind) слушается"; else bad "749/tcp НЕ слушается"; fi
if port_listening 389 tcp; then ok "389/tcp (slapd) слушается"; else bad "389/tcp НЕ слушается"; fi

step "Конфигурация KDC"
if grep -q "\[capaths\]" "$KRB5_CONF" 2>/dev/null; then ok "в $KRB5_CONF есть [capaths]"; else bad "в $KRB5_CONF нет [capaths]"; fi
if grep -q "^    $REALM_A = {" "$KRB5_CONF" 2>/dev/null && \
   grep -q "^    $REALM_B = {" "$KRB5_CONF" 2>/dev/null; then
    ok "в $KRB5_CONF описаны оба realm'а ($REALM_A, $REALM_B)"
else
    bad "в $KRB5_CONF нет одного из realm'ов"
fi
if [ -f "$KDC_DB_DIR_A/principal" ]; then ok "БД $REALM_A на месте ($KDC_DB_DIR_A/principal)"; else bad "нет БД $REALM_A"; fi
if [ -f "$KDC_DB_DIR_B/principal" ]; then ok "БД $REALM_B на месте ($KDC_DB_DIR_B/principal)"; else bad "нет БД $REALM_B"; fi

step "Принципалы (kadmin.local)"
kadm() { kadmin.local -r "$1" -q "$2" 2>&1; }
has_princ() {
    local realm="$1" p="$2"
    case "$p" in *@*) ;; *) p="$p@$realm" ;; esac
    kadm "$realm" "getprinc $p" | grep -q "^Principal:"
}
for p in "admin/admin" "alice" "admin" "$LDAP_SPN"; do
    if has_princ "$REALM_A" "$p"; then ok "$p@$REALM_A есть"; else bad "$p@$REALM_A НЕТ"; fi
done
for p in "admin/admin" "alice" "admin" "org1user1" "org2user1"; do
    if has_princ "$REALM_B" "$p"; then ok "$p@$REALM_B есть"; else bad "$p@$REALM_B НЕТ"; fi
done
# Для доверия нужно КАЖДОЕ из двух имён в ОБЕИХ базах: выдающий realm
# шифрует TGT именем krbtgt/<куда>@<кто выдал>, принимающий — расшифровывает
# тем же именем из своей базы.
for trust in "krbtgt/$REALM_B@$REALM_A" "krbtgt/$REALM_A@$REALM_B"; do
    for trust_realm in "$REALM_A" "$REALM_B"; do
        if has_princ "$trust_realm" "$trust"; then
            ok "$trust есть в $trust_realm"
        else
            bad "нет $trust в $trust_realm (TGT не расшифруется/не выдастся)"
        fi
    done
done
# Негатив: сервисный SPN каталога НЕ должен существовать во втором realm'е.
if has_princ "$REALM_B" "$LDAP_SPN"; then
    bad "$LDAP_SPN есть в $REALM_B — сервис зарегистрирован лишний раз"
else
    ok "$LDAP_SPN в $REALM_B отсутствует (паритет с kdc-a2 лаборатории)"
fi

step "kinit (аутентификация)"
KINIT_ERR=""
KINIT_FAILS=0
kinit_bad() { KINIT_FAILS=$((KINIT_FAILS+1)); bad "$*"; }
kinit_ok() {
    # kinit_ok <principal> <password>
    local ccache="/tmp/krb5cc_verify_$$" err
    err="$(kinit -c "$ccache" "$1" <<< "$2" 2>&1)" && { rm -f "$ccache"; return 0; }
    KINIT_ERR="$(printf '%s' "$err" | tr '\n' ' ')"
    rm -f "$ccache"; return 1
}
for pr in "admin/admin@$REALM_A" "alice@$REALM_A" "admin@$REALM_A"; do
    case "$pr" in
        admin/admin@*) p="$ADMIN_PASSWORD" ;;
        alice@*)       p="$ALICE_PASSWORD" ;;
        *)             p="$NODE_ADMIN_PASSWORD" ;;
    esac
    if kinit_ok "$pr" "$p"; then ok "kinit $pr"; else kinit_bad "kinit $pr НЕ прошёл: $KINIT_ERR"; fi
done
for u in org1user1 org2user1; do
    if pw_of "$u" >/dev/null 2>&1; then
        p="$(pw_of "$u")"
        if kinit_ok "$u@$REALM_A" "$p"; then ok "kinit $u@$REALM_A"; else kinit_bad "kinit $u@$REALM_A НЕ прошёл: $KINIT_ERR"; fi
    fi
done
if pw_of org2user1 >/dev/null 2>&1; then
    p="$(pw_of org2user1)"
    if kinit_ok "org2user1@$REALM_B" "$p"; then ok "kinit org2user1@$REALM_B (второй realm)"; else kinit_bad "kinit org2user1@$REALM_B НЕ прошёл: $KINIT_ERR"; fi
fi
if [ "$KINIT_FAILS" -gt 0 ]; then
    echo "  журнал KDC (последние строки):"
    if [ -r /var/log/krb5kdc.log ]; then
        tail -n 15 /var/log/krb5kdc.log 2>/dev/null | sed 's/^/    /' || true
    else
        journalctl -u krb5-kdc -n 15 --no-pager 2>&1 | sed 's/^/    /' || true
    fi
fi

step "GSSAPI-аутентификация в LDAP"
GSS_FAILS=0
gss_check() {
    # gss_check <principal> <password> <ожидаемый фрагмент DN> <подпись>
    local out d
    out="$(gssapi_dn "$1" "$2")"
    d="$(printf '%s' "$out" | grep -o 'dn:[^ ]*' | head -1 | sed 's/^dn://')"
    case "$d" in
        *"$3"*) ok "$4 -> $d" ;;
        *) GSS_FAILS=$((GSS_FAILS+1)); bad "$4: ожидался $3, получено '${d:-${out:-нет}}'" ;;
    esac
}
if pw_of org1user1 >/dev/null 2>&1; then
    p="$(pw_of org1user1)"
    gss_check "org1user1@$REALM_A" "$p" "uid=org1user1,ou=$LDAP_OU_PRIMARY" "org1user1"
fi
if pw_of org2user1 >/dev/null 2>&1; then
    p="$(pw_of org2user1)"
    gss_check "org2user1@$REALM_B" "$p" "uid=org2user1,ou=$LDAP_OU_SECONDARY" "cross-realm org2user1@$REALM_B"
fi
gss_check "admin@$REALM_A" "$NODE_ADMIN_PASSWORD" "uid=admin,ou=$LDAP_OU_ADMINS" "admin"
gss_check "alice@$REALM_A" "$ALICE_PASSWORD" "uid=alice,ou=$LDAP_OU_PRIMARY" "alice"
if [ "$GSS_FAILS" -gt 0 ]; then
    echo "  журнал $SLAPD_UNIT (SASL/GSSAPI):"
    journalctl -u "$SLAPD_UNIT" -n 25 --no-pager 2>&1 | sed 's/^/    /' || true
fi

step "Изоляция организаций"
search_has_entries() {
    # search_has_entries <principal> <password> <base-dn> — 0, если видны записи
    local ccache="/tmp/krb5cc_verify_$$" out
    kinit -c "$ccache" "$1" <<< "$2" >/dev/null 2>&1 || { rm -f "$ccache"; return 2; }
    out="$(KRB5CCNAME="$ccache" ldapsearch -Y GSSAPI -Q -H "ldap://$LDAP_HOST" -b "$3" -s sub 2>&1)"
    rm -f "$ccache"
    echo "$out" | grep -q "^uid:" && return 0 || return 1
}
if pw_of org1user1 >/dev/null 2>&1; then
    p="$(pw_of org1user1)"
    search_has_entries "org1user1@$REALM_A" "$p" "ou=$LDAP_OU_SECONDARY,ou=people,$DC_BASE"
    case $? in
        0) bad "org1user1 ВИДИТ ветку ou=$LDAP_OU_SECONDARY — изоляция нарушена" ;;
        2) bad "org1user1: kinit не прошёл — изоляцию проверить нельзя" ;;
        *) ok "org1user1 не видит ou=$LDAP_OU_SECONDARY" ;;
    esac
fi
if pw_of org2user1 >/dev/null 2>&1; then
    p="$(pw_of org2user1)"
    search_has_entries "org2user1@$REALM_B" "$p" "ou=$LDAP_OU_PRIMARY,ou=people,$DC_BASE"
    case $? in
        0) bad "org2user1 ВИДИТ ветку ou=$LDAP_OU_PRIMARY — изоляция нарушена" ;;
        2) bad "org2user1: kinit не прошёл — изоляцию проверить нельзя" ;;
        *) ok "org2user1 не видит ветку ou=$LDAP_OU_PRIMARY" ;;
    esac
fi

step "Негатив: знание SPN не даёт билет"
KCCACHE="/tmp/krb5cc_verify_kvno_$$"
if kinit -c "$KCCACHE" "alice@$REALM_A" <<< "$ALICE_PASSWORD" >/dev/null 2>&1; then
    export KRB5CCNAME="$KCCACHE"
else
    bad "kinit alice для негативных проверок не прошёл"
fi
out="$(kvno "$LDAP_SPN@$REALM_B" 2>&1)"
case "$out" in
    *"not found in Kerberos database"*|*"GET_LOCAL_TGT"*)
        ok "kvno $LDAP_SPN@$REALM_B отклонён (билет не выдан)" ;;
    *) bad "kvno $LDAP_SPN@$REALM_B: ожидался отказ, получено: $out" ;;
esac
out="$(kvno "$LDAP_SPN@ORG3.TEST" 2>&1)"
rm -f "$KCCACHE"; unset KRB5CCNAME
case "$out" in
    *"krbtgt/ORG3.TEST@$REALM_A not found"*) ok "kvno $LDAP_SPN@ORG3.TEST отклонён (нет доверия к ORG3.TEST)" ;;
    *) bad "kvno $LDAP_SPN@ORG3.TEST: ожидался отказ, получено: $out" ;;
esac

step "Конфигурация slapd"
if [ -r "$SLAPD_CONF" ]; then
    # Акцептор GSSAPI обязан называть себя так же, как его просит клиент.
    # Без sasl-host Cyrus SASL берёт gethostname() и ищет в keytab
    # ldap/<hostname> вместо ldap/$LDAP_HOST.
    sh_line="$(grep -E '^[[:space:]]*sasl-host' "$SLAPD_CONF" | awk '{print $2}' | head -1)"
    if [ "$sh_line" = "$LDAP_HOST" ]; then
        ok "sasl-host = $sh_line"
    elif [ -z "$sh_line" ]; then
        bad "sasl-host не задан — акцептор возьмёт gethostname() и не найдёт ldap/$LDAP_HOST в keytab"
    else
        bad "sasl-host = $sh_line, а клиент запросит $LDAP_HOST — стороны разойдутся"
    fi
else
    bad "нет $SLAPD_CONF"
fi

step "keytab каталога"
if klist -k "$KEYTAB" 2>/dev/null | grep -q "$LDAP_SPN"; then
    ok "keytab $KEYTAB содержит $LDAP_SPN"
else
    bad "keytab $KEYTAB НЕ содержит $LDAP_SPN"
fi
perm="$(stat -c '%U:%G %a' "$KEYTAB" 2>/dev/null || echo 'нет файла')"
case "$perm" in
    "root:openldap 640"|"root:openldap 0640") ok "права keytab: $perm" ;;
    *) bad "права keytab: $perm (ожидалось root:openldap 640)" ;;
esac

step "Время"
if command -v timedatectl >/dev/null 2>&1; then
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
        ok "время синхронизировано (NTP)"
    elif command -v chronyc >/dev/null 2>&1 && \
         ! chronyc sources 2>/dev/null | awk 'NR>2 && $2 != "" {found=1} END {exit !found}'; then
        warn "NTP-источники недоступны (изолированная сеть) — синхронизации нет;"
        warn "Kerberos допускает расхождение часов до ~5 мин: проверьте, что часы"
        warn "клиента и узла совпадают (date -u). Для лаборатории этого достаточно."
    else
        bad "время НЕ синхронизировано — Kerberos-билеты будут отвергаться"
    fi
else
    bad "timedatectl недоступен — нельзя проверить синхронизацию времени"
fi

echo
echo "ИТОГО: OK=$PASS  FAIL=$FAIL"
[ "$FAIL" = "0" ] || exit 1
