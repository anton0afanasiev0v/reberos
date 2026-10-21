# Клиентский krb5.conf лаборатории: 4 realm, два узла.
# Плейсхолдеры подставляет client/entrypoint.sh.
#
# Cross-realm: ORG1<->ORG2 (узел А) и ORG3<->ORG4 (узел Б) — прямое
# взаимное доверие (общие krbtgt-ключи на KDC узла). Пути прописаны в
# [capaths] значением "." (share keys directly, без посредников).
# Между узлами доверия нет — ORG1->ORG3 и т.п. отклоняются KDC.

[libdefaults]
    default_realm = ${ORG1_REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = false
    rdns = false
    dns_canonicalize_hostname = false
    forwardable = true
    ticket_lifetime = 10h
    renew_lifetime = 7d

[realms]
    ${ORG1_REALM} = {
        kdc = ${KDC_A1_HOST}
        admin_server = ${KDC_A1_HOST}
    }
    ${ORG2_REALM} = {
        kdc = ${KDC_A2_HOST}
        admin_server = ${KDC_A2_HOST}
    }
    ${ORG3_REALM} = {
        kdc = ${KDC_B3_HOST}
        admin_server = ${KDC_B3_HOST}
    }
    ${ORG4_REALM} = {
        kdc = ${KDC_B4_HOST}
        admin_server = ${KDC_B4_HOST}
    }

[domain_realm]
    ${WEB_A_HOST} = ${ORG1_REALM}
    ${LDAP_A_HOST} = ${ORG1_REALM}
    ${WEB_B_HOST} = ${ORG3_REALM}
    ${LDAP_B_HOST} = ${ORG3_REALM}
    .${DOMAIN} = ${ORG1_REALM}
    ${DOMAIN} = ${ORG1_REALM}

[capaths]
    ${ORG1_REALM} = {
        ${ORG2_REALM} = .
    }
    ${ORG2_REALM} = {
        ${ORG1_REALM} = .
    }
    ${ORG3_REALM} = {
        ${ORG4_REALM} = .
    }
    ${ORG4_REALM} = {
        ${ORG3_REALM} = .
    }

[logging]
    default = FILE:/var/log/krb5libs.log
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmind.log
