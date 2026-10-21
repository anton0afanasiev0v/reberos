#!/bin/bash
set -euo pipefail

REALM="${REALM:?}"
DOMAIN="${DOMAIN:?}"
KDC_HOST="${KDC_HOST:?}"
LDAP_HOST="${LDAP_HOST:?}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:?}"
ALICE_PASSWORD="${ALICE_PASSWORD:?}"
# Файл keytab домашнего KDC узла: /keytabs/<prefix>-ldap.keytab
KEYTAB_FILE="${KEYTAB_FILE:-/keytabs/ldap.keytab}"

log() { echo "[ldap] $*"; }

DC_FIRST="${DOMAIN%%.*}"
DC_BASE="$(printf '%s' "$DOMAIN" | awk -F. '{printf "dc=%s", $1; for(i=2;i<=NF;i++) printf ",dc=%s", $i}')"

render() {
    local src="$1" dst="$2"
    sed -e "s|\${REALM}|$REALM|g" \
        -e "s|\${DOMAIN}|$DOMAIN|g" \
        -e "s|\${KDC_HOST}|$KDC_HOST|g" \
        -e "s|\${DC_BASE}|$DC_BASE|g" \
        -e "s|\${DC_FIRST}|$DC_FIRST|g" \
        -e "s|\${ROOTPW_HASH}|$(slappasswd -s "$LDAP_ADMIN_PASSWORD")|g" \
        -e "s|\${ALICE_HASH}|$(slappasswd -s "$ALICE_PASSWORD")|g" \
        "$src" > "$dst"
}

render /templates/krb5.conf.tpl /etc/krb5.conf
render /templates/slapd.conf.tpl /etc/ldap/slapd.conf
render /templates/seed.ldif.tpl /tmp/seed.ldif
log "конфигурации отрендерены (suffix: $DC_BASE)"

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
