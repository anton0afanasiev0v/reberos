#!/bin/bash
set -euo pipefail

DOMAIN="${DOMAIN:?}"
ORG1_REALM="${ORG1_REALM:?}"
ORG2_REALM="${ORG2_REALM:?}"
ORG3_REALM="${ORG3_REALM:?}"
ORG4_REALM="${ORG4_REALM:?}"
KDC_A1_HOST="${KDC_A1_HOST:?}"
KDC_A2_HOST="${KDC_A2_HOST:?}"
KDC_B3_HOST="${KDC_B3_HOST:?}"
KDC_B4_HOST="${KDC_B4_HOST:?}"
LDAP_A_HOST="${LDAP_A_HOST:?}"
LDAP_B_HOST="${LDAP_B_HOST:?}"
WEB_A_HOST="${WEB_A_HOST:?}"
WEB_B_HOST="${WEB_B_HOST:?}"
LDAP_HOST="${LDAP_HOST:-$LDAP_A_HOST}"

sed -e "s|\${DOMAIN}|$DOMAIN|g" \
    -e "s|\${ORG1_REALM}|$ORG1_REALM|g" \
    -e "s|\${ORG2_REALM}|$ORG2_REALM|g" \
    -e "s|\${ORG3_REALM}|$ORG3_REALM|g" \
    -e "s|\${ORG4_REALM}|$ORG4_REALM|g" \
    -e "s|\${KDC_A1_HOST}|$KDC_A1_HOST|g" \
    -e "s|\${KDC_A2_HOST}|$KDC_A2_HOST|g" \
    -e "s|\${KDC_B3_HOST}|$KDC_B3_HOST|g" \
    -e "s|\${KDC_B4_HOST}|$KDC_B4_HOST|g" \
    -e "s|\${LDAP_A_HOST}|$LDAP_A_HOST|g" \
    -e "s|\${LDAP_B_HOST}|$LDAP_B_HOST|g" \
    -e "s|\${WEB_A_HOST}|$WEB_A_HOST|g" \
    -e "s|\${WEB_B_HOST}|$WEB_B_HOST|g" \
    /templates/krb5.conf.tpl > /etc/krb5.conf

# SASL_NOCANON: не канонизировать имя сервера обратным DNS. Без этого
# OpenLDAP-клиент резолвит IP в PTR Docker DNS (ldap-a.lab.test.kerberos)
# и GSSAPI-привязка падает: Server krbtgt/... not found.
# Пиннинг в /etc/hosts не применяем: Docker перезаписывает этот файл
# при любых изменениях сети.
mkdir -p /etc/ldap
printf 'URI ldap://%s\nSASL_MECH GSSAPI\nSASL_NOCANON on\n' \
    "$LDAP_HOST" > /etc/ldap/ldap.conf

exec "$@"
