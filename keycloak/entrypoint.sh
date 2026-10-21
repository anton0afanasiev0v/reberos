#!/bin/bash
set -euo pipefail

KC_REALM="${KC_REALM:?}"
DOMAIN="${DOMAIN:?}"
NODE_LABEL="${NODE_LABEL:?}"
WEB_HOST="${WEB_HOST:?}"
PUBLIC_WEB_BASE="${PUBLIC_WEB_BASE:?}"
LDAP_HOST="${LDAP_HOST:?}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:?}"

log() { echo "[keycloak] $*"; }

# dc=lab,dc=test из DOMAIN=lab.test — как в ldap/entrypoint.sh
DC_BASE="dc=${DOMAIN//./,dc=}"
mkdir -p /opt/keycloak/data/import
sed -e "s|\${KC_REALM}|$KC_REALM|g" \
    -e "s|\${NODE_LABEL}|$NODE_LABEL|g" \
    -e "s|\${DOMAIN}|$DOMAIN|g" \
    -e "s|\${WEB_HOST}|$WEB_HOST|g" \
    -e "s|\${PUBLIC_WEB_BASE}|$PUBLIC_WEB_BASE|g" \
    -e "s|\${LDAP_HOST}|$LDAP_HOST|g" \
    -e "s|\${LDAP_ADMIN_PASSWORD}|$LDAP_ADMIN_PASSWORD|g" \
    -e "s|\${DC_BASE}|$DC_BASE|g" \
    /templates/realm-node.json.tpl > "/opt/keycloak/data/import/realm-node.json"

log "realm ${KC_REALM}: OIDC-only (web-форма), LDAP-федерация ${LDAP_HOST} (ou=people), portal -> ${PUBLIC_WEB_BASE}/callback"
exec /opt/keycloak/bin/kc.sh "$@"
