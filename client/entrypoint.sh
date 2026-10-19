#!/bin/bash
set -euo pipefail

REALM="${REALM:?}"
DOMAIN="${DOMAIN:?}"
KDC_HOST="${KDC_HOST:?}"
LDAP_HOST="${LDAP_HOST:-ldap.lab.test}"
KDC_IP="${KDC_IP:-}"
LDAP_IP="${LDAP_IP:-}"
WEB_IP="${WEB_IP:-}"

sed -e "s|\${REALM}|$REALM|g" \
    -e "s|\${DOMAIN}|$DOMAIN|g" \
    -e "s|\${KDC_HOST}|$KDC_HOST|g" \
    /templates/krb5.conf.tpl > /etc/krb5.conf

# Дефолтный LDAP-сервер и мех для клиентских утилит (ldapsearch и т.п.)
mkdir -p /etc/ldap
printf 'URI ldap://%s\nSASL_MECH GSSAPI\n' "$LDAP_HOST" > /etc/ldap/ldap.conf

# Фиксируем обратные имена хостов лаборатории: Docker DNS отдаёт PTR вида
# ldap.lab.test.reberos_lab, из-за чего OpenLDAP-клиент строит принципал
# ldap/ldap.lab.test.reberos_lab и GSSAPI-привязка падает.
pin() {
    local ip="$1" name="$2"
    [ -z "$ip" ] || [ -z "$name" ] && return 0
    grep -qE "^[^#]*[[:space:]]$name([[:space:]]|$)" /etc/hosts \
        || echo "$ip $name" >> /etc/hosts
}
pin "$KDC_IP" "${KDC_HOST:-kdc.lab.test}"
pin "$LDAP_IP" "${LDAP_HOST:-ldap.lab.test}"
pin "$WEB_IP" "${WEB_HOST:-web.lab.test}"

exec "$@"
