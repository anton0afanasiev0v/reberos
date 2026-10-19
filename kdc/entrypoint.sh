#!/bin/bash
set -euo pipefail

REALM="${REALM:?REALM is required}"
DOMAIN="${DOMAIN:?DOMAIN is required}"
KDC_HOST="${KDC_HOST:?KDC_HOST is required}"
LDAP_HOST="${LDAP_HOST:?LDAP_HOST is required}"
WEB_HOST="${WEB_HOST:?WEB_HOST is required}"
KDC_MASTER_KEY="${KDC_MASTER_KEY:?KDC_MASTER_KEY is required}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"
ALICE_PASSWORD="${ALICE_PASSWORD:?ALICE_PASSWORD is required}"

log() { echo "[kdc] $*"; }

render() {
    local src="$1" dst="$2"
    sed -e "s/\${REALM}/${REALM}/g" \
        -e "s/\${DOMAIN}/${DOMAIN}/g" \
        -e "s/\${KDC_HOST}/${KDC_HOST}/g" \
        "$src" > "$dst"
}

render /templates/krb5.conf.tpl /etc/krb5.conf
render /templates/kdc.conf.tpl /etc/krb5kdc/kdc.conf
render /templates/kadm5.acl.tpl /etc/krb5kdc/kadm5.acl

if [ ! -f /var/lib/krb5kdc/principal ]; then
    log "создаю базу данных принципалов realm ${REALM}"
    kdb5_util -r "$REALM" create -s -P "$KDC_MASTER_KEY"
    rm -f /keytabs/*.keytab
fi

kq() { kadmin.local -q "$1" 2>&1; }

principal_exists() {
    kq "getprinc $1" | grep -q "^Principal:"
}

ensure_user_principal() {
    if principal_exists "$1"; then
        log "принципал $1 уже существует"
    else
        kq "addprinc -pw $2 $1" >/dev/null
        log "создан принципал $1"
    fi
}

ensure_service_principal() {
    if ! principal_exists "$1"; then
        kq "addprinc -randkey $1" >/dev/null
        log "создан сервисный принципал $1"
    fi
    if [ ! -f "$2" ]; then
        kq "ktadd -k $2 $1" >/dev/null
        log "выписан keytab: $2"
    fi
}

ensure_user_principal "admin/admin" "$ADMIN_PASSWORD"
ensure_user_principal "alice" "$ALICE_PASSWORD"

mkdir -p /keytabs
chmod 755 /keytabs
ensure_service_principal "ldap/${LDAP_HOST}" "/keytabs/ldap.keytab"
# HTTP — заглавными: так SPNEGO/мод_auth_gssapi запрашивает сервисный тикет
# (регистр значим: http/... и HTTP/... — разные принципалы)
ensure_service_principal "HTTP/${WEB_HOST}" "/keytabs/http.keytab"
chmod 644 /keytabs/*.keytab

log "список принципалов:"
kq "listprincs" || true

krb5kdc
kadmind
log "krb5kdc запущен (88/tcp+udp), kadmind запущен (749/tcp)"

exec tail -F /var/log/krb5kdc.log /var/log/kadmind.log /var/log/krb5libs.log
