# Сайт с аутентификацией Kerberos + обратный прокси на Grafana (шаблон).
# ${WEB_HOST}, ${GRAFANA_HOST} подставляются entrypoint'ом.

<VirtualHost *:80>
    ServerName ${WEB_HOST}
    DocumentRoot /var/www/html

    <Location />
        AuthType GSSAPI
        AuthName "LAB.TEST Kerberos"
        GssapiCredStore keytab:/keytabs/http.keytab
        Require valid-user
    </Location>

    # Публичная страница — без аутентификации (для наглядной проверки)
    <Location /public>
        Require all granted
    </Location>

    # Grafana — второй закрытый сервис домена: вход по Kerberos-билету,
    # личность (REMOTE_USER) передаётся в Grafana через auth proxy (SSO).
    # RequestHeader set затирает присланный клиентом заголовок.
    <Location /grafana>
        AuthType GSSAPI
        AuthName "LAB.TEST Kerberos"
        GssapiCredStore keytab:/keytabs/http.keytab
        Require valid-user
        RequestHeader set X-WEBAUTH-USER "%{REMOTE_USER}e"
    </Location>

    # Путь сохраняется: Grafana работает с serve_from_sub_path=true.
    ProxyPreserveHost On
    ProxyPass        /grafana http://${GRAFANA_HOST}:3000
    ProxyPassReverse /grafana http://${GRAFANA_HOST}:3000

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
