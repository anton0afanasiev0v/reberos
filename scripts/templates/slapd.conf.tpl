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
# документация, admin guide §15.2.6).
# Директива именно authz-regexp (sasl-regexp НЕ работает в slapd.conf);
# директивы глобальные — размещаются ДО блока database.
#
# Изоляция организаций: принципалы разных realm маппятся в РАЗНЫЕ ветки
# ou=orgN,ou=people.
# ВАЖНО (проверено эмпирически на OpenLDAP 2.5 + MIT GSSAPI):
#  - принципал ДОМАШНЕГО realm узла приходит БЕЗ realm: uid=<user>,cn=gssapi,...
#  - принципал ЧУЖОГО realm (cross-realm) приходит С realm в НИЖНЕМ регистре:
#    uid=<user>@org2.test,cn=gssapi,...
# Поэтому: cross-realm правила (с realm) идут ПЕРВЫМИ, а realmless-форма
# уходит в PRIMARY-ветку узла (домашний realm узла) — правило ПОСЛЕДНИМ.
# ${REALM_PRI_RE}/${REALM_SEC_RE}: точка->[.], буквы->[Xx] (POSIX ERE в slapd
# не знает (?i), а cross-realm realm приходит в нижнем регистре).

# alice — общий smoke-пользователь; живёт в домашней org-ветке узла.
authz-regexp    uid=alice@(${REALM_PRI_RE}|${REALM_SEC_RE}),cn=gssapi,cn=auth uid=alice,ou=${LDAP_OU_PRIMARY},ou=people,${DC_BASE}
authz-regexp    uid=alice,cn=gssapi,cn=auth uid=alice,ou=${LDAP_OU_PRIMARY},ou=people,${DC_BASE}
# «Админ узла» (короткое имя admin) -> uid=admin,ou=admins (домашний realm).
authz-regexp    uid=admin@${REALM_PRI_RE},cn=gssapi,cn=auth uid=admin,ou=admins,${DC_BASE}
authz-regexp    uid=admin,cn=gssapi,cn=auth uid=admin,ou=admins,${DC_BASE}
# Рабочие пользователи: cross-realm (с realm) — по своей ветке.
authz-regexp    uid=([^,]+)@${REALM_PRI_RE},cn=gssapi,cn=auth uid=$1,ou=${LDAP_OU_PRIMARY},ou=people,${DC_BASE}
authz-regexp    uid=([^,]+)@${REALM_SEC_RE},cn=gssapi,cn=auth uid=$1,ou=${LDAP_OU_SECONDARY},ou=people,${DC_BASE}
# Домашний realm узла (realmless) -> PRIMARY-ветка. ДОЛЖНО быть последним.
authz-regexp    uid=([^,]+),cn=gssapi,cn=auth uid=$1,ou=${LDAP_OU_PRIMARY},ou=people,${DC_BASE}

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

# Права доступа (порядок значим: первое совпавшее правило выигрывает).
# userPassword — ПЕРВЫМ, иначе dn.subtree-правила дадут read на хэш пароля.
access to attrs=userPassword
    by anonymous auth
    by self write
    by dn="cn=admin,${DC_BASE}" write
    by dn="uid=admin,ou=admins,${DC_BASE}" write
    by * none

# «Админ узла» — своя запись.
access to dn="uid=admin,ou=admins,${DC_BASE}"
    by dn="uid=admin,ou=admins,${DC_BASE}" write
    by * none

# ou=orgN: только своя организация читает свою ветку; admin — write.
access to dn.subtree="ou=${LDAP_OU_PRIMARY},ou=people,${DC_BASE}"
    by dn="uid=admin,ou=admins,${DC_BASE}" write
    by dn.subtree="ou=${LDAP_OU_PRIMARY},ou=people,${DC_BASE}" read
    by dn="uid=alice,ou=${LDAP_OU_PRIMARY},ou=people,${DC_BASE}" read
    by * none
access to dn.subtree="ou=${LDAP_OU_SECONDARY},ou=people,${DC_BASE}"
    by dn="uid=admin,ou=admins,${DC_BASE}" write
    by dn.subtree="ou=${LDAP_OU_SECONDARY},ou=people,${DC_BASE}" read
    by dn="uid=alice,ou=${LDAP_OU_PRIMARY},ou=people,${DC_BASE}" read
    by * none

# Служебные узлы и прочее: аноним видит только корень.
access to dn.base=""
    by * read
access to *
    by dn="cn=admin,${DC_BASE}" write
    by dn="uid=admin,ou=admins,${DC_BASE}" write
    by self write
    by dn="uid=alice,ou=${LDAP_OU_PRIMARY},ou=people,${DC_BASE}" read
    by * none

