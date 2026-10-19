		

# Docker-лаборатория Kerberos + OpenLDAP (GSSAPI)

Лаборатория полностью работает «из коробки»: KDC, OpenLDAP с GSSAPI-привязкой
и маппингом принципалов в LDAP-DN, тестовый клиент, опционально — Apache с
SPNEGO. Все решения ниже проверены фактическим запуском (`./scripts/verify.sh`).

## Запуск

```bash
docker compose up -d --build        # базовый состав: kdc, ldap, client
./scripts/verify.sh                 # 8 проверок

docker compose --profile apache up -d --build   # + Apache
./scripts/verify.sh --with-apache   # 12 проверок

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
- **Apache**: `/` — только по GSSAPI-билету (SPNEGO, принципал
  `HTTP/web.lab.test`); `/public` — без аутентификации (для наглядности;
  описана в разделе «Доступ к сайту с хоста»).

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
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/           # 401 (без билета)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/public/    # 200 (без аутентификации)
```

## Доступ к сайту с хоста (Ubuntu и аналоги)

Имя `web.lab.test` существует **только внутри Docker-сети** — из браузера
хоста по нему зайти не получится, пока его не добавить в `/etc/hosts`.
Порт Apache опубликован на `127.0.0.1:8080`.

### 1. Публичная страница (без всего)

После добавления записи в `/etc/hosts` открой
[http://web.lab.test:8080/public/](http://web.lab.test:8080/public/) — эта страница доступна без
аутентификации (для наглядной проверки, что сервер работает).

### 2. Вход по билету Kerberos (SPNEGO)

**Шаг 1 — имя хоста** (нужны права root):

```bash
sudo sh -c 'echo "127.0.0.1 web.lab.test" >> /etc/hosts'
```

**Шаг 2 — Kerberos-клиент на хосте:**

```bash
sudo apt install krb5-user
```

Затем пропиши realm в `/etc/krb5.conf` хоста (фрагменты):

```ini
[libdefaults]
    default_realm = LAB.TEST
    default_ccache_name = FILE:/run/user/%{uid}/krb5cc_lab
    rdns = false
    dns_canonicalize_hostname = false

[realms]
    LAB.TEST = {
        kdc = 127.0.0.1
        admin_server = 127.0.0.1
    }

[domain_realm]
    .lab.test = LAB.TEST
    lab.test = LAB.TEST
```

`default_ccache_name = FILE:/run/user/%{uid}/krb5cc_lab` — путь, видимый
и хостовым утилитам, и браузером без snap-ограничений. Если планируешь
SPNEGO именно в браузере — см. шаг 4 и «Подводные камни», п. 9
(Firefox из snap не умеет читать кэши вне `hostfs/tmp`; рекомендуется
Firefox .deb).

**Шаг 3 — билет:**

```bash
kinit alice        # пароль — из .env лаборатории (ALICE_PASSWORD)
klist              # кэш FILE:/run/user/…/krb5cc_lab, есть TGT krbtgt/LAB.TEST@LAB.TEST
```

**Шаг 4 — браузер.** На Linux SPNEGO умеет **Firefox**
(Chromium/Chrome — не умеют). Для SSO **рекомендуется .deb-сборка**
из PPA `ppa:mozillateam/ppa` (с pin-файлом — см. п. 9): снап-версия
на Ubuntu не читает кэш билетов и всегда отдаёт 401. В `about:config`:

- `network.negotiate-auth.trusted-uris` → `web.lab.test`

После `kinit` открой
[http://web.lab.test:8080/](http://web.lab.test:8080/) — с действующим
билетом страница откроется сразу; после `kdestroy` + перезагрузки
страницы снова будет 401 (наглядно видно, что «пропуск» — это билет,
а не пароль в браузере).

Примечания:

- KDC опубликован на `127.0.0.1:88` — хост ходит в лабораторный realm
  через localhost, отдельная сеть не нужна.
- Если Firefox молча возвращает 401 — проверь `klist` (билет истёк?),
  `network.negotiate-auth.trusted-uris` и что это **.deb**-Firefox,
  а не snap (п. 9).

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
   вида `ldap.lab.test.reberos_lab`; OpenLDAP-клиент при канонизации имени
   сервера обратным DNS строит принципал `ldap/ldap.lab.test.reberos_lab`,
   и GSSAPI падает с `Server krbtgt/LAB.TEST.REBEROS_LAB@LAB.TEST not found`.
   Лечение (в проекте сделано):

   - `SASL_NOCANON on` в `/etc/ldap/ldap.conf` клиента — главный способ:
     клиент не канонизирует имя сервера и берёт `ldap/lab.test` из URI;
   - `dns_canonicalize_hostname = false` в krb5.conf (страховка).
     Пиннинг строк в `/etc/hosts` контейнеров **не применять**: Docker
     перезаписывает этот файл при любых изменениях сети (например, при
     пересоздании соседнего контейнера), и пиннинги молча исчезают.
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
9. **Firefox из snap не читает кэш билетов — SPNEGO всегда 401.**
   Проверено на факте (audit-логи AppArmor): профиль снапа Firefox
   разрешает чтение билетов ровно по одному пути —
   `owner /var/lib/snapd/hostfs/tmp/krb5cc* rkw` (хостовый `/tmp`
   через hostfs-монтирование снапа). Приватный `/tmp` снапа скрывает
   стандартный `FILE:/tmp/krb5cc_%{uid}`; для `/run/user/...` и
   `KEYRING:`-кэшей разрешений нет вовсе (отказы видны в
   `journalctl -k`). GSSAPI молча не находит билет, не шлёт
   `Negotiate` и отдаёт 401, хотя `klist` и `curl --negotiate`
   с хоста работают.

   **Рекомендуемое решение — Firefox .deb** из PPA mozillateam
   (без snap-джейла SSO штатное):

   ```bash
   sudo tee /etc/apt/preferences.d/mozilla-firefox >/dev/null <<'EOF'
   Package: firefox*
   Pin: release o=LP-PPA-mozillateam
   Pin-Priority: 1001
   EOF
   sudo add-apt-repository -y ppa:mozillateam/ppa
   sudo apt update && sudo apt install -y firefox
   sudo snap remove firefox    # опционально, чтобы не запустить снап случайно
   ```

   **Альтернатива (снап остаётся):** один кэш-файл для хоста и снапа —
   симлинк `sudo ln -sfn /tmp /var/lib/snapd/hostfs/tmp` + в хостовом
   `/etc/krb5.conf`:

   ```ini
   [libdefaults]
       default_ccache_name = FILE:/var/lib/snapd/hostfs/tmp/krb5cc_lab
   ```

   Хост резолвит путь через симлинк в `/tmp/krb5cc_lab`; снап — через
   hostfs-монтирование в тот же файл. Требования к файлу: имя начинается
   с `krb5cc` (маска `krb5cc*`), владелец — uid браузера (правило
   `owner`). После любой смены — `kdestroy && kinit …`; для snap-Firefox
   ещё и **полный** перезапуск браузера. Проверка без браузера:
   `curl -s -o /dev/null -w '%{http_code}' --negotiate -u : http://web.lab.test:8080/`
   (должен вернуть `200`).

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
- Firefox всегда 401, а `curl --negotiate` с хоста даёт 200 —
  почти наверняка snap-Firefox (AppArmor пропускает только
  `hostfs/tmp/krb5cc*`); ставь .deb (пункт 9).
