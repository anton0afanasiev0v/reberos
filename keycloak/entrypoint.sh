#!/bin/bash
set -euo pipefail

REALM="${REALM:?}"
DOMAIN="${DOMAIN:?}"
KDC_HOST="${KDC_HOST:?}"
LDAP_HOST="${LDAP_HOST:?}"
KEYCLOAK_HOST="${KEYCLOAK_HOST:?}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:?}"

log() { echo "[keycloak] $*"; }

# krb5.conf для Java (JAAS Krb5LoginModule, SPNEGO): Java читает его по
# системному свойству java.security.krb5.conf, kc.sh передаёт JVM
# JAVA_OPTS_APPEND.
sed -e "s|\${REALM}|$REALM|g" \
    -e "s|\${DOMAIN}|$DOMAIN|g" \
    -e "s|\${KDC_HOST}|$KDC_HOST|g" \
    /templates/krb5.conf.tpl > /tmp/krb5.conf
export JAVA_OPTS_APPEND="${JAVA_OPTS_APPEND:-} -Djava.security.krb5.conf=/tmp/krb5.conf"

# Ждём keytab от KDC
for _ in $(seq 1 60); do
    [ -f /keytabs/keycloak.keytab ] && break
    sleep 1
done
if [ ! -f /keytabs/keycloak.keytab ]; then
    log "ОШИБКА: /keytabs/keycloak.keytab не появился за 60 c"
    exit 1
fi

# Realm импортируется kc.sh при старте (--import-realm).
# dc=lab,dc=test из DOMAIN=lab.test — как в ldap/entrypoint.sh.
DC_BASE="dc=${DOMAIN//./,dc=}"
mkdir -p /opt/keycloak/data/import
sed -e "s|\${REALM}|$REALM|g" \
    -e "s|\${LDAP_HOST}|$LDAP_HOST|g" \
    -e "s|\${KEYCLOAK_HOST}|$KEYCLOAK_HOST|g" \
    -e "s|\${LDAP_ADMIN_PASSWORD}|$LDAP_ADMIN_PASSWORD|g" \
    -e "s|\${DC_BASE}|$DC_BASE|g" \
    /templates/realm-lab.json.tpl > /opt/keycloak/data/import/realm-lab.json

log "запускаю Keycloak (SPNEGO principal: HTTP/${KEYCLOAK_HOST}@${REALM})"
exec /opt/keycloak/bin/kc.sh "$@"
