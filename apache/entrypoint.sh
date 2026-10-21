#!/bin/bash
set -euo pipefail

REALM="${REALM:?}"
DOMAIN="${DOMAIN:?}"
KDC_HOST="${KDC_HOST:?}"
WEB_HOST="${WEB_HOST:?}"
KEYTAB_FILE="${KEYTAB_FILE:-/keytabs/http.keytab}"
PORTAL_HOST="${PORTAL_HOST:?}"
KEYCLOAK_HOST="${KEYCLOAK_HOST:?}"

log() { echo "[web] $*"; }

sed -e "s|\${REALM}|$REALM|g" \
    -e "s|\${DOMAIN}|$DOMAIN|g" \
    -e "s|\${KDC_HOST}|$KDC_HOST|g" \
    /templates/krb5.conf.tpl > /etc/krb5.conf

# Ждём keytab домашнего KDC узла
for _ in $(seq 1 60); do
    [ -f "$KEYTAB_FILE" ] && break
    sleep 1
done
if [ ! -f "$KEYTAB_FILE" ]; then
    log "ОШИБКА: $KEYTAB_FILE не появился за 60 c"
    exit 1
fi

sed -e "s|\${REALM}|$REALM|g" \
    -e "s|\${WEB_HOST}|$WEB_HOST|g" \
    -e "s|\${KEYTAB_FILE}|$KEYTAB_FILE|g" \
    -e "s|\${PORTAL_HOST}|$PORTAL_HOST|g" \
    -e "s|\${KEYCLOAK_HOST}|$KEYCLOAK_HOST|g" \
    /templates/kerberos.conf.tpl > /etc/apache2/sites-available/kerberos.conf
a2ensite kerberos.conf >/dev/null

log "запускаю Apache (SPNEGO principal: HTTP/${WEB_HOST}@${REALM}, portal: ${PORTAL_HOST}, auth: ${KEYCLOAK_HOST})"
exec apache2ctl -D FOREGROUND
