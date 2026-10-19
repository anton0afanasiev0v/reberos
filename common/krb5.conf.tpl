# Общий клиентский/серверный конфигурационный файл Kerberos.
# Плейсхолдеры ${REALM}, ${DOMAIN}, ${KDC_HOST} подставляются
# entrypoint-скриптами контейнеров при старте.

[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = false
    rdns = false
    dns_canonicalize_hostname = false
    forwardable = true
    ticket_lifetime = 10h
    renew_lifetime = 7d

[realms]
    ${REALM} = {
        kdc = ${KDC_HOST}
        admin_server = ${KDC_HOST}
    }

[domain_realm]
    .${DOMAIN} = ${REALM}
    ${DOMAIN} = ${REALM}

[logging]
    default = FILE:/var/log/krb5libs.log
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmind.log
