#!/bin/bash
set -euo pipefail

REALM="${REALM:?REALM is required}"
DOMAIN="${DOMAIN:?DOMAIN is required}"
KDC_HOST="${KDC_HOST:?KDC_HOST is required}"
KDC_MASTER_KEY="${KDC_MASTER_KEY:?KDC_MASTER_KEY is required}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"
ALICE_PASSWORD="${ALICE_PASSWORD:?ALICE_PASSWORD is required}"
# Префикс keytab-файлов: общий том /keytabs на узел, файлы с именем
# <prefix>-<role>.keytab (a1-ldap.keytab, b3-http.keytab и т.п.)
KEYTAB_PREFIX="${KEYTAB_PREFIX:-${REALM,,}}"
KEYTAB_PREFIX="${KEYTAB_PREFIX//./-}"
# Сервисные принципалы (ldap/HTTP) создаёт только домашний KDC узла
CREATE_SERVICES="${CREATE_SERVICES:-0}"
LDAP_HOST="${LDAP_HOST:-}"
WEB_HOST="${WEB_HOST:-}"
# Cross-realm доверие внутри узла: krbtgt/ЧУЖОЙ@СВОЙ с общим ключом
CROSS_REALM_REALM="${CROSS_REALM_REALM:-}"
CROSS_REALM_KEY="${CROSS_REALM_KEY:-}"

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

mkdir -p /keytabs
chmod 755 /keytabs

if [ ! -f /var/lib/krb5kdc/principal ]; then
    log "создаю базу данных принципалов realm ${REALM}"
    # Чистим только свои keytab-файлы: том /keytabs общий на узел
    rm -f "/keytabs/${KEYTAB_PREFIX}"-*.keytab
    kdb5_util -r "$REALM" create -s -P "$KDC_MASTER_KEY"
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

if [ "$CREATE_SERVICES" = "1" ]; then
    [ -n "$LDAP_HOST" ] || { log "ОШИБКА: CREATE_SERVICES=1 требует LDAP_HOST"; exit 1; }
    [ -n "$WEB_HOST" ]  || { log "ОШИБКА: CREATE_SERVICES=1 требует WEB_HOST"; exit 1; }
    # HTTP — заглавными: так mod_auth_gssapi запрашивает сервисный тикет
    # (регистр значим: http/... и HTTP/... — разные принципалы)
    ensure_service_principal "ldap/${LDAP_HOST}" "/keytabs/${KEYTAB_PREFIX}-ldap.keytab"
    ensure_service_principal "HTTP/${WEB_HOST}"  "/keytabs/${KEYTAB_PREFIX}-http.keytab"
fi

if [ -n "$CROSS_REALM_REALM" ]; then
    [ -n "$CROSS_REALM_KEY" ] || { log "ОШИБКА: CROSS_REALM_REALM задан без CROSS_REALM_KEY"; exit 1; }
    # Взаимное cross-realm доверие внутри узла (прямые пути ORG1<->ORG2).
    # Один и тот же принципал krbtgt/ЧУЖОЙ@СВОЙ обязан существовать на ОБОИХ
    # KDC с одинаковым паролем/kvno/etype (MIT: "In both databases, there must
    # be krbtgt service principals... same passwords, key version numbers").
    # Направления: клиент A -> сервис B требует krbtgt/B@A в обеих базах,
    # поэтому создаём оба направления на каждом KDC.
    ensure_user_principal "krbtgt/${CROSS_REALM_REALM}@${REALM}" "$CROSS_REALM_KEY"
    ensure_user_principal "krbtgt/${REALM}@${CROSS_REALM_REALM}" "$CROSS_REALM_KEY"
    # MIT рекомендует не требовать preauth на cross-realm ключах:
    # иначе preauth нельзя отключить по-сервисно.
    kq "modprinc -requires_preauth krbtgt/${CROSS_REALM_REALM}@${REALM}" >/dev/null || true
    kq "modprinc -requires_preauth krbtgt/${REALM}@${CROSS_REALM_REALM}" >/dev/null || true
    log "cross-realm доверие: ${REALM} <-> ${CROSS_REALM_REALM} (общий ключ)"
fi

chmod 644 "/keytabs/${KEYTAB_PREFIX}"-*.keytab 2>/dev/null || true

log "список принципалов:"
kq "listprincs" || true

krb5kdc
kadmind
log "krb5kdc запущен (88/tcp+udp), kadmind запущен (749/tcp)"

exec tail -F /var/log/krb5kdc.log /var/log/kadmind.log /var/log/krb5libs.log
