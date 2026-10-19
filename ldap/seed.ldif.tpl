# Начальное наполнение каталога (шаблон).
# ${DC_BASE} → dc=lab,dc=test; ${DC_FIRST} → lab (вычисляется из DOMAIN в entrypoint).

dn: ${DC_BASE}
objectClass: top
objectClass: domain
dc: ${DC_FIRST}

dn: ou=people,${DC_BASE}
objectClass: organizationalUnit
ou: people

dn: uid=alice,ou=people,${DC_BASE}
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: alice
cn: Alice Example
sn: Example
userPassword: ${ALICE_HASH}
