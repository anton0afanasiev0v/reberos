#!/bin/bash
set -euo pipefail

REALM="${REALM:?}"
DOMAIN="${DOMAIN:?}"
KDC_HOST="${KDC_HOST:?}"
WEB_HOST="${WEB_HOST:?}"

log() { echo "[web] $*"; }

sed -e "s|\${REALM}|$REALM|g" \
    -e "s|\${DOMAIN}|$DOMAIN|g" \
    -e "s|\${KDC_HOST}|$KDC_HOST|g" \
    /templates/krb5.conf.tpl > /etc/krb5.conf

# Фиксируем обратные имена (см. client/entrypoint.sh — PTR Docker даёт
# имя вида ldap.lab.test.reberos_lab, что ломает канонизацию для GSSAPI).
pin() {
    local ip="$1" name="$2"
    [ -z "$ip" ] || [ -z "$name" ] && return 0
    grep -qE "^[^#]*[[:space:]]$name([[:space:]]|$)" /etc/hosts \
        || echo "$ip $name" >> /etc/hosts
}
pin "${KDC_IP:-}" "$KDC_HOST"
pin "${LDAP_IP:-}" "${LDAP_HOST:-ldap.lab.test}"
pin "${WEB_IP:-}" "$WEB_HOST"

for _ in $(seq 1 60); do
    [ -f /keytabs/http.keytab ] && break
    sleep 1
done
if [ ! -f /keytabs/http.keytab ]; then
    log "ОШИБКА: /keytabs/http.keytab не появился за 60 c"
    exit 1
fi

sed -e "s|\${WEB_HOST}|$WEB_HOST|g" \
    /templates/kerberos.conf.tpl > /etc/apache2/sites-available/kerberos.conf
a2ensite kerberos.conf >/dev/null

log "запускаю Apache (principal: HTTP/${WEB_HOST}@${REALM})"
exec apache2ctl -D FOREGROUND
