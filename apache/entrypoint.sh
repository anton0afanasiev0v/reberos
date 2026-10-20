#!/bin/bash
set -euo pipefail

REALM="${REALM:?}"
DOMAIN="${DOMAIN:?}"
KDC_HOST="${KDC_HOST:?}"
WEB_HOST="${WEB_HOST:?}"
GRAFANA_HOST="${GRAFANA_HOST:?}"

log() { echo "[web] $*"; }

sed -e "s|\${REALM}|$REALM|g" \
    -e "s|\${DOMAIN}|$DOMAIN|g" \
    -e "s|\${KDC_HOST}|$KDC_HOST|g" \
    /templates/krb5.conf.tpl > /etc/krb5.conf

for _ in $(seq 1 60); do
    [ -f /keytabs/http.keytab ] && break
    sleep 1
done
if [ ! -f /keytabs/http.keytab ]; then
    log "ОШИБКА: /keytabs/http.keytab не появился за 60 c"
    exit 1
fi

sed -e "s|\${WEB_HOST}|$WEB_HOST|g" \
    -e "s|\${GRAFANA_HOST}|$GRAFANA_HOST|g" \
    /templates/kerberos.conf.tpl > /etc/apache2/sites-available/kerberos.conf
a2ensite kerberos.conf >/dev/null

# Публичная страница (без аутентификации) для наглядной проверки
mkdir -p /var/www/html/public
cp /templates/public.html /var/www/html/public/index.html

log "запускаю Apache (principal: HTTP/${WEB_HOST}@${REALM})"
exec apache2ctl -D FOREGROUND
