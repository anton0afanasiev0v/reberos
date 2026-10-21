# Сайт узла (шаблон). Уровень 1 — SPNEGO за Apache, портал проксируется
# под SPNEGO; уровень 2 — Keycloak (/auth) без SPNEGO, чтобы не было
# петли SSO. ${WEB_HOST}, ${REALM}, ${KEYTAB_FILE}, ${PORTAL_HOST},
# ${KEYCLOAK_HOST} подставляются entrypoint'ом.

<VirtualHost *:80>
    ServerName ${WEB_HOST}
    ProxyPreserveHost On

    # Уровень 2 — OIDC: Keycloak без SPNEGO (браузер ходит по логин-форме)
    <Location /auth>
        Require all granted
    </Location>
    ProxyPass        /auth http://${KEYCLOAK_HOST}:8080/auth
    ProxyPassReverse /auth http://${KEYCLOAK_HOST}:8080/auth

    # Уровень 1 — SPNEGO на весь остальной сайт (портал).
    # Личность передаётся порталу в X-Remote-User. Именно "expr=%{REMOTE_USER}"
    # (фаза fixup после auth): %{REMOTE_USER}e пуст для проксируемых запросов.
    # LocationMatch исключает /auth, иначе SPNEGO-401 на логине Keycloak
    # складывается в SSO-петлю.
    <LocationMatch "^(?!/auth(?:/|$))">
        AuthType GSSAPI
        AuthName "${REALM}"
        GssapiCredStore keytab:${KEYTAB_FILE}
        Require valid-user
        RequestHeader set X-Remote-User "expr=%{REMOTE_USER}"
    </LocationMatch>

    ProxyPass        / http://${PORTAL_HOST}:8000/
    ProxyPassReverse / http://${PORTAL_HOST}:8000/

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
