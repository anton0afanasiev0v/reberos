# Конфигурация slapd (шаблон slapd.conf).
# На старте контейнера подставляются плейсхолдеры ${DC_BASE}, ${ROOTPW_HASH}
# и запускается slapd -f (см. ldap/entrypoint.sh).

include         /etc/ldap/schema/core.schema
include         /etc/ldap/schema/cosine.schema
include         /etc/ldap/schema/inetorgperson.schema

pidfile         /run/slapd/slapd.pid
argsfile        /run/slapd/slapd.args

modulepath      /usr/lib/ldap
moduleload      back_mdb

# Маппинг Kerberos-принципала (SASL authc) в LDAP-запись.
# GSSAPI даёт authc-DN uid=<user>[@REALM],cn=gssapi,cn=auth (OpenLDAP 2.5
# документация, admin guide §15.2.6). Вариант с явным realm — первым.
# Директива именно authz-regexp (sasl-regexp НЕ работает в slapd.conf).
# Директивы глобальные — размещаются ДО блока database.
authz-regexp    uid=([^,]+)@[^,]+,cn=gssapi,cn=auth uid=$1,ou=people,${DC_BASE}
authz-regexp    uid=([^,]+),cn=gssapi,cn=auth uid=$1,ou=people,${DC_BASE}

# Лаборатория без TLS: допускаем SASL-аутентификацию без слоя шифрования
sasl-secprops    minssf=0,maxssf=0

database        mdb
maxsize         1073741824
suffix          "${DC_BASE}"
rootdn          "cn=admin,${DC_BASE}"
rootpw          ${ROOTPW_HASH}
directory       /var/lib/ldap

index           objectClass eq,pres
index           uid         eq,pres,sub

# Права доступа: анонимы видят только корень; данные — только аутентифицированным
access to attrs=userPassword
    by anonymous auth
    by self write
    by dn="cn=admin,${DC_BASE}" write
    by * none
access to dn.base=""
    by * read
access to *
    by dn="cn=admin,${DC_BASE}" write
    by self write
    by users read
    by anonymous none
