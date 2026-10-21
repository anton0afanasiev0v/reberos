#!/bin/bash
set -euo pipefail

REALM="${REALM:?}"
DOMAIN="${DOMAIN:?}"
KDC_HOST="${KDC_HOST:?}"
LDAP_HOST="${LDAP_HOST:?}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:?}"
ALICE_PASSWORD="${ALICE_PASSWORD:?}"
# Изоляция организаций: первая/вторая организация узла (realm <-> ou=orgN).
LDAP_REALM_PRIMARY="${LDAP_REALM_PRIMARY:?}"
LDAP_OU_PRIMARY="${LDAP_OU_PRIMARY:?}"
LDAP_REALM_SECONDARY="${LDAP_REALM_SECONDARY:?}"
LDAP_OU_SECONDARY="${LDAP_OU_SECONDARY:?}"
# Рабочие пользователи (логины orgNuserM) и «админ узла» (короткое admin).
ORG_USER_PASSWORDS="${ORG_USER_PASSWORDS:-}"
NODE_ADMIN_PASSWORD="${NODE_ADMIN_PASSWORD:-}"
# Организации узла (список ou=orgN через пробел) — для раскладки логинов.
ORG_OUS="${ORG_OUS:-}"
# Файл keytab домашнего KDC узла: /keytabs/<prefix>-ldap.keytab
KEYTAB_FILE="${KEYTAB_FILE:-/keytabs/ldap.keytab}"

log() { echo "[ldap] $*"; }

DC_FIRST="${DOMAIN%%.*}"
DC_BASE="$(printf '%s' "$DOMAIN" | awk -F. '{printf "dc=%s", $1; for(i=2;i<=NF;i++) printf ",dc=%s", $i}')"

# realm -> regex для authz-regexp: точка экранируется ([.]), каждая буква
# раскрывается в [Xx] (POSIX ERE в slapd НЕ поддерживает(?i) inline-флаг,
# а cross-realm realm приходит в нижнем регистре: org2.test).
re_ci_realm() {
    printf '%s' "$1" | sed 's/\./[.]/g' | \
        sed 's/[A-Za-z]/[&]/g' | \
        sed 'y/abcdefghijklmnopqrstuvwxyz/ABCDEFGHIJKLMNOPQRSTUVWXYZ/' | \
        sed 's/\[\([A-Z]\)\]/[\1\L\1]/g'
}
REALM_PRI_RE="$(re_ci_realm "$LDAP_REALM_PRIMARY")"
REALM_SEC_RE="$(re_ci_realm "$LDAP_REALM_SECONDARY")"

render() {
    local src="$1" dst="$2"
    sed -e "s|\${REALM}|$REALM|g" \
        -e "s|\${DOMAIN}|$DOMAIN|g" \
        -e "s|\${KDC_HOST}|$KDC_HOST|g" \
        -e "s|\${DC_BASE}|$DC_BASE|g" \
        -e "s|\${DC_FIRST}|$DC_FIRST|g" \
        -e "s|\${LDAP_REALM_PRIMARY}|$LDAP_REALM_PRIMARY|g" \
        -e "s|\${LDAP_OU_PRIMARY}|$LDAP_OU_PRIMARY|g" \
        -e "s|\${LDAP_REALM_SECONDARY}|$LDAP_REALM_SECONDARY|g" \
        -e "s|\${LDAP_OU_SECONDARY}|$LDAP_OU_SECONDARY|g" \
        -e "s|\${REALM_PRI_RE}|$REALM_PRI_RE|g" \
        -e "s|\${REALM_SEC_RE}|$REALM_SEC_RE|g" \
        -e "s|\${ROOTPW_HASH}|$(slappasswd -s "$LDAP_ADMIN_PASSWORD")|g" \
        -e "s|\${ALICE_HASH}|$(slappasswd -s "$ALICE_PASSWORD")|g" \
        "$src" > "$dst"
}

# Дополнительные записи: orgNuserM (в свою org-ветку узла) + админ узла.
# Логин уникален в деревне (org-префикс), поэтому Keycloak видит обе org.
render_extra_entries() {
    local dst="$1" pair u p o ou hash
    [ -n "$ORG_USER_PASSWORDS" ] || return 0
    for pair in $ORG_USER_PASSWORDS; do
        u="${pair%%=*}"
        p="${pair#*=}"
        [ -n "$u" ] && [ "$u" != "$p" ] || { log "ОШИБКА: плохая пара логин=пароль: '$pair'"; exit 1; }
        ou=""
        for o in $ORG_OUS; do
            case "$u" in "$o"*) ou="$o"; break ;; esac
        done
        if [ -z "$ou" ]; then
            log "ОШИБКА: логин '$u' не начинается ни с одной org ($ORG_OUS)"
            exit 1
        fi
        hash="$(slappasswd -s "$p")"
        cat >> "$dst" <<EOF

dn: uid=$u,ou=$ou,ou=people,${DC_BASE}
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: $u
cn: $u
sn: $u
userPassword: $hash
EOF
    done
    if [ -n "$NODE_ADMIN_PASSWORD" ]; then
        cat >> "$dst" <<EOF

dn: uid=admin,ou=admins,${DC_BASE}
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: admin
cn: Admin Node
sn: Admin
userPassword: $(slappasswd -s "$NODE_ADMIN_PASSWORD")
EOF
    fi
}

render /templates/krb5.conf.tpl /etc/krb5.conf
render /templates/slapd.conf.tpl /etc/ldap/slapd.conf
render /templates/seed.ldif.tpl /tmp/seed.ldif
render_extra_entries /tmp/seed.ldif
log "конфигурации отрендерены (suffix: $DC_BASE, org: $LDAP_OU_PRIMARY/$LDAP_OU_SECONDARY)"

# --- ждём keytab от домашнего KDC узла ---
for _ in $(seq 1 60); do
    [ -f "$KEYTAB_FILE" ] && break
    sleep 1
done
if [ ! -f "$KEYTAB_FILE" ]; then
    log "ОШИБКА: $KEYTAB_FILE не появился за 60 c"
    exit 1
fi
log "keytab: $(ls -l "$KEYTAB_FILE" | awk '{print $1, $3, $4, $5}')"

# --- каталоги данных ---
mkdir -p /run/slapd /var/lib/ldap
chown openldap:openldap /run/slapd /var/lib/ldap

# --- запуск slapd (slapd.conf напрямую; с отладкой — логи видны в docker logs) ---
slapd -f /etc/ldap/slapd.conf -h "ldap:/// ldapi:///" -u openldap -g openldap -d stats &
SLAPD_PID=$!
log "slapd запущен (pid $SLAPD_PID)"

for _ in $(seq 1 30); do
    ldapsearch -x -H ldap://127.0.0.1 -b "" -s base 1.1 >/dev/null 2>&1 && break
    sleep 1
done
if ! ldapsearch -x -H ldap://127.0.0.1 -b "" -s base 1.1 >/dev/null 2>&1; then
    log "ОШИБКА: slapd не отвечает"
    exit 1
fi
log "slapd отвечает на ldap://127.0.0.1"

# --- наполнение каталога (идемпотентно) ---
# Проверку делаем под admin: анониму ACL скрывает базу (возвращается noSuchObject).
if ldapsearch -x -H ldap://127.0.0.1 -D "cn=admin,${DC_BASE}" -w "$LDAP_ADMIN_PASSWORD" \
    -b "uid=alice,ou=people,${DC_BASE}" -s base 1.1 >/dev/null 2>&1; then
    log "база $DC_BASE уже наполнена"
else
    log "база $DC_BASE пуста — загружаю seed.ldif"
    ldapadd -x -H ldap://127.0.0.1 -D "cn=admin,${DC_BASE}" -w "$LDAP_ADMIN_PASSWORD" -f /tmp/seed.ldif
fi

wait $SLAPD_PID
