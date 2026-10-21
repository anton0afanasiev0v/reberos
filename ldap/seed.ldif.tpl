# Начальное наполнение каталога (шаблон).
# ${DC_BASE} → dc=lab,dc=test; ${DC_FIRST} → lab (вычисляется из DOMAIN).
# Ветки изоляции: ou=${LDAP_OU_PRIMARY}/ou=${LDAP_OU_SECONDARY} под ou=people.
# Записи orgNuserM и uid=admin,ou=admins добавляются entrypoint'ом
# (из ORG_USER_PASSWORDS: логин уже с org-префиксом).

dn: ${DC_BASE}
objectClass: top
objectClass: domain
dc: ${DC_FIRST}

dn: ou=people,${DC_BASE}
objectClass: organizationalUnit
ou: people

# Ветки организаций (первая и вторая организация узла).
dn: ou=${LDAP_OU_PRIMARY},ou=people,${DC_BASE}
objectClass: organizationalUnit
ou: ${LDAP_OU_PRIMARY}

dn: ou=${LDAP_OU_SECONDARY},ou=people,${DC_BASE}
objectClass: organizationalUnit
ou: ${LDAP_OU_SECONDARY}

# Администраторы узла.
dn: ou=admins,${DC_BASE}
objectClass: organizationalUnit
ou: admins

# alice — общий smoke-пользователь; в домашней org-ветке узла (видна в Keycloak).
dn: uid=alice,ou=${LDAP_OU_PRIMARY},ou=people,${DC_BASE}
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: alice
cn: Alice Example
sn: Example
userPassword: ${ALICE_HASH}
