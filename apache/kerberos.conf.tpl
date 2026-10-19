# Сайт с аутентификацией Kerberos (шаблон).
# ${WEB_HOST} подставляется entrypoint'ом.

<VirtualHost *:80>
    ServerName ${WEB_HOST}
    DocumentRoot /var/www/html

    <Location />
        AuthType GSSAPI
        AuthName "LAB.TEST Kerberos"
        GssapiCredStore keytab:/keytabs/http.keytab
        Require valid-user
    </Location>

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
