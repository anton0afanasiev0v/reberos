#!/bin/bash
set -euo pipefail

REALM="${REALM:?}"
DOMAIN="${DOMAIN:?}"
KDC_HOST="${KDC_HOST:?}"
LDAP_HOST="${LDAP_HOST:-ldap.lab.test}"

sed -e "s|\${REALM}|$REALM|g" \
    -e "s|\${DOMAIN}|$DOMAIN|g" \
    -e "s|\${KDC_HOST}|$KDC_HOST|g" \
    /templates/krb5.conf.tpl > /etc/krb5.conf

# SASL_NOCANON: не канонизировать имя сервера обратным DNS. Без этого
# OpenLDAP-клиент резолвит IP в PTR Docker DNS (ldap.lab.test.reberos_lab)
# и GSSAPI-привязка падает: Server krbtgt/LAB.TEST.REBEROS_LAB not found.
# Пиннинг в /etc/hosts не применяем: Docker перезаписывает этот файл
# при любых изменениях сети.
mkdir -p /etc/ldap
printf 'URI ldap://%s\nSASL_MECH GSSAPI\nSASL_NOCANON on\n' \
    "$LDAP_HOST" > /etc/ldap/ldap.conf

exec "$@"
