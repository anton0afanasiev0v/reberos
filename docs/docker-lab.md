# Docker-лаборатория Kerberos + OpenLDAP (GSSAPI)

Лаборатория полностью работает «из коробки»: KDC, OpenLDAP с GSSAPI-привязкой
и маппингом принципалов в LDAP-DN, тестовый клиент, опционально — Apache с
SPNEGO. Все решения ниже проверены фактическим запуском (`./scripts/verify.sh`).

## Запуск

```bash
docker compose up -d --build        # базовый состав: kdc, ldap, client
./scripts/verify.sh                 # 8 проверок

docker compose --profile apache up -d --build   # + Apache
./scripts/verify.sh --with-apache   # 11 проверок

./scripts/reset.sh                  # остановить, удалить тома и данные
```

Все параметры — в `.env` (realm, имена, IP, пароли). Пароли — **только для
лаборатории**, в production их быть не должно.

## Как устроено

- **Сеть**: bridge `lab`, подсеть `172.30.10.0/24`, у каждого сервиса
  статический IP, `hostname` и `container_name` равны FQDN
  (`kdc.lab.test`, `ldap.lab.test`, ...), плюс network alias.
- **Том `keytabs`**: KDC выписывает `/keytabs/ldap.keytab` и
  `/keytabs/http.keytab`; slapd и Apache монтируют его `:ro`
  (права 644 — Apache/slapped работают под непривилегированными
  пользователями и не читают root-only keytab).
- **krb5.conf**: единый шаблон `common/krb5.conf.tpl`, рендерится
  entrypoint-ом каждого контейнера при старте
  (`dns_lookup_kdc=false`, `rdns=false`, `dns_canonicalize_hostname=false`).
- **KDC**: при первом старте создаёт realm, принципалы
  `admin/admin`, `alice`, `ldap/ldap.lab.test`, `HTTP/web.lab.test`,
  `krbtgt/LAB.TEST` и выписывает keytabs. Повторные старты идемпотентны.
- **slapd**: стартует напрямую со `slapd.conf` (`slapd -f ...`), БД — mdb;
  seed (`dc=lab,dc=test`, `ou=people`, `uid=alice`) грузится под
  rootdn при пустом каталоге (проверка идемпотентна — под admin).
- **Клиент**: `kinit`/`klist`/`ldapsearch`/`ldapwhoami`, а также
  `spnego-check` (python-скрипт на `requests-kerberos`) для проверки Apache.

## Проверка вручную

```bash
docker compose exec client bash
echo "$ALICE_PASSWORD" | kinit alice      # пароль из .env
klist
ldapwhoami -Y GSSAPI                      # dn:uid=alice,ou=people,dc=lab,dc=test
ldapsearch -Y GSSAPI -b dc=lab,dc=test '(uid=alice)' dn
kdestroy
ldapsearch -Y GSSAPI -b dc=lab,dc=test    # отказ: нет билета
```

С хоста видны опубликованные порты (только 127.0.0.1):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/   # 401
```

## Подводные камни (проверенные решения)

1. **`authz-regexp`, а не `sasl-regexp`.** В OpenLDAP 2.5 (Debian 12)
   директива маппинга SASL-идентичности в slapd.conf называется
   `authz-regexp`; `sasl-regexp` молча игнорируется. Она матчит
   authc-DN вида `uid=<user>[@REALM],cn=gssapi,cn=auth` и должна стоять
   в глобальной секции — **до** блока `database`:

   ```
   authz-regexp uid=([^,]+)@[^,]+,cn=gssapi,cn=auth uid=$1,ou=people,${DC_BASE}
   authz-regexp uid=([^,]+),cn=gssapi,cn=auth uid=$1,ou=people,${DC_BASE}
   ```

   Проверка: `ldapwhoami -Y GSSAPI` должен вернуть
   `dn:uid=alice,ou=people,dc=lab,dc=test`, а не `dn:uid=alice,cn=gssapi,cn=auth`.
2. **Принципал Apache — заглавными: `HTTP/host`.** SPNEGO-клиенты запрашивают
   `HTTP/...`; Kerberos-принципалы регистрозависимы, `http/...` и `HTTP/...` —
   разные записи. Keytab должен содержать `HTTP/web.lab.test@LAB.TEST`.
3. **DNS Docker ломает канонизацию имён.** Внутренний DNS Docker отдаёт PTR
   вида `ldap.lab.test.reberos_lab`, из-за чего клиент строит принципал
   `ldap/ldap.lab.test.reberos_lab` и GSSAPI падает с
   `Server krbtgt/REBEROS_LAB@LAB.TEST not found`. Лечение (в проекте сделано
   обоими способами):

   - `dns_canonicalize_hostname = false` в krb5.conf;
   - фиксация обратных имён в `/etc/hosts` контейнеров entrypoint-ами
     (`172.30.10.20 ldap.lab.test` и т.п.).
4. **`sasl-secprops minssf=0,maxssf=0`** — лаборатория без TLS; без этой
   директивы slapd требует слой шифрования (SSF) и GSSAPI-привязка падает.
5. **`master_key_type = aes256-cts`** (не `aes256-cts:normal`) в kdc.conf:
   с `:normal` `kdb5_util create` падает с
   `Program lacks support for key type`.
6. **Debian curl собран без GSS-API** — `curl --negotiate` не работает.
   Вместо него в клиенте лежит `spnego-check` (python3 + requests-kerberos).
7. **`slaptest -F` требует существующую директорию** и без ключа `-u`
   пытается открыть БД. В проекте конвертация в cn=config не используется —
   slapd стартует со `slapd.conf` напрямую, что проще и надёжнее.
8. **seed/ACL**: анонимный `ldapsearch` по базе из-за ACL возвращает
   `noSuchObject` — проверку «каталог наполнен» нужно делать под rootdn.

## Диагностика

```bash
docker compose ps                       # статус и healthcheck
docker compose logs -f kdc              # логи KDC (AS_REQ/ISSUE, ошибки)
docker compose logs -f ldap             # slapd -d stats: BIND, SEARCH, ACL
docker compose logs -f web              # stdout Apache; ошибки:
docker compose exec web tail -20 /var/log/apache2/error.log
docker compose exec ldap grep -n authz-regexp /etc/ldap/slapd.conf
kadmin.local -q listprincs              # внутри kdc.lab.test
```

Типовые симптомы:

- `ldapwhoami: Can't contact LDAP server` — нет `-H`/URI; в клиенте задан
  `/etc/ldap/ldap.conf` с `URI ldap://ldap.lab.test`.
- `SASL(-1): ... Server krbtgt/REBEROS_LAB@LAB.TEST not found` —
  канонизация DNS (пункт 3).
- `Server HTTP/web.lab.test@LAB.TEST not found` — регистр принципала
  (пункт 2).
- `ldapwhoami` возвращает `uid=alice,cn=gssapi,cn=auth` — не применился
  `authz-regexp` (пункт 1).
