		

# Docker-лаборатория Kerberos + OpenLDAP (GSSAPI)

Лаборатория полностью работает «из коробки»: KDC, OpenLDAP с GSSAPI-привязкой
и маппингом принципалов в LDAP-DN, тестовый клиент, стек мониторинга
Prometheus/Grafana, опционально — Apache с SPNEGO и Keycloak (федерация
LDAP + вход по SPNEGO-билету). Все решения ниже проверены фактическим
запуском (`./scripts/verify.sh`).

## Запуск

```bash
docker compose up -d --build        # базовый состав: kdc, ldap, client + мониторинг
./scripts/verify.sh                 # 13 проверок

docker compose --profile apache up -d --build   # + Apache
./scripts/verify.sh --with-apache   # 19 проверок

docker compose --profile keycloak up -d --build  # + Keycloak
./scripts/verify.sh --with-keycloak # 17 проверок
./scripts/verify.sh --with-apache --with-keycloak  # 23 проверки (всё вместе)

./scripts/reset.sh                  # остановить, удалить тома и данные
```

Все параметры — в `.env` (realm, имена, IP, пароли). Пароли — **только для
лаборатории**, в production их быть не должно.

## Как устроено

- **Сеть**: bridge `lab`, подсеть `172.30.10.0/24`, у каждого сервиса
  статический IP, `hostname` и `container_name` равны FQDN
  (`kdc.lab.test`, `ldap.lab.test`, ...), плюс network alias.
- **Том `keytabs`**: KDC выписывает `/keytabs/ldap.keytab`,
  `/keytabs/http.keytab` и `/keytabs/keycloak.keytab`; slapd, Apache
  и Keycloak монтируют его `:ro` (права 644 — Apache/slapped работают
  под непривилегированными пользователями и не читают root-only keytab).
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
- **Keycloak** (профиль `keycloak`): официальный образ 26.8.1 в dev-режиме
  с `--import-realm`; realm `lab` импортируется из шаблона
  `keycloak/realm-lab.json.tpl` при каждом старте (данные эфемерные, H2
  без тома — импорт идемпотентен). Браузерный flow: Cookie → **SPNEGO
  (`auth-spnego`)** → формы (пароль). Пользователи — федерация из
  OpenLDAP (`ldap://ldap.lab.test:389`, READ_ONLY), аутентификация
  по тикету Kerberos через keytab `HTTP/keycloak.lab.test`.
- **Мониторинг** (базовый состав): Prometheus скрейпит метрики всех
  сервисов и ходит через blackbox-exporter TCP/HTTP-пробами (KDC, LDAP,
  Apache 200/401, health Grafana); Grafana с автопровижинингом датасource
  и дашборда; cAdvisor — метрики контейнеров. Grafana — второй закрытый
  сервис домена: за Apache (`/grafana/` по SPNEGO, `REMOTE_USER` →
  заголовок `X-WEBAUTH-USER`), админка — напрямую на localhost.

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

Имена `web.lab.test` (Apache) и `keycloak.lab.test` (Keycloak)
существуют **только внутри Docker-сети** — из браузера хоста по ним
зайти не получится, пока не добавить оба в `/etc/hosts`.
Порты опубликованы на `127.0.0.1`: Apache — `8080`, Keycloak — `8081`.

### 1. Публичная страница (без всего)

После добавления записи в `/etc/hosts` открой
[http://web.lab.test:8080/public/](http://web.lab.test:8080/public/) — эта страница доступна без
аутентификации (для наглядной проверки, что сервер работает).

### 2. Вход по билету Kerberos (SPNEGO)

**Шаг 1 — имя хоста** (нужны права root):

```bash
sudo sh -c 'echo "127.0.0.1 web.lab.test keycloak.lab.test" >> /etc/hosts'
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

- `network.negotiate-auth.trusted-uris` → `web.lab.test, keycloak.lab.test`

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

## Мониторинг (Prometheus + Grafana)

Входит в базовый состав: `prometheus` (.50), `grafana` (.60), `cadvisor`
(.70), `blackbox` (.80); порты `9090` и `3000` опубликованы только на
localhost хоста. Состав пром-задач: собственные метрики Prometheus,
метрики Grafana, метрики контейнеров cAdvisor, TCP-пробы KDC/LDAP,
HTTP-пробы (200 для `/public/` и health Grafana, 401 для `/`),
результаты — в PromQL `up` и `probe_success`.

Дашборд «Reberos — мониторинг лаборатории» и датасource Prometheus
прописываются автоматически (`monitoring/grafana/provisioning/`).

Два способа доступа:

1. **Админка** — <http://127.0.0.1:3000/grafana/>: логин `admin`,
   пароль — `GRAFANA_ADMIN_PASSWORD` из `.env` (без аутентификации
   редиректит на `/grafana/login`).
2. **SSO по билету** — <http://web.lab.test:8080/grafana/> через Apache:
   без билета 401; с билетом SPNEGO проходит, Apache подставляет
   `REMOTE_USER` в `X-WEBAUTH-USER`, Grafana сама создаёт пользователя
   (alice — Viewer, роль — `GF_USERS_AUTO_ASSIGN_ORG_ROLE`).

Проверка из клиентского контейнера:

```bash
docker compose exec client bash
echo "$ALICE_PASSWORD" | kinit alice
spnego-check http://web.lab.test/grafana/   # после SPNEGO: 200/301
```

## Keycloak (федерация LDAP + SPNEGO)

Опциональный профиль: сервис `keycloak.lab.test` (172.30.10.90), порт
`127.0.0.1:8081` (management-интерфейс с метриками — 9000, наружу не
публикуется). Keycloak выступает сервисом федерации: пользователи читаются
из OpenLDAP, вход можно делать по паролю **или** по SPNEGO-билету Kerberos.

```bash
docker compose --profile keycloak up -d --build
./scripts/verify.sh --with-keycloak   # 17 проверок (13 базовых + 4 Keycloak)
```

Как устроено:

- **Образ**: `quay.io/keycloak/keycloak:26.8.1` + свой entrypoint
  (`keycloak/entrypoint.sh`): рендерит krb5.conf и realm-шаблон в
  `/opt/keycloak/data/import/`, ждёт появления `/keytabs/keycloak.keytab`
  (KDC создаёт принципал `HTTP/keycloak.lab.test`) и запускает
  `kc.sh start-dev --import-realm`.
- **Realm `lab`**: `sslRequired: none` (лаборатория без TLS), браузерный
  flow `browser`: `auth-cookie` → **`auth-spnego`** (ALTERNATIVE,
  конфиг — keytab/принципал/.realm) → subflow `forms` с парольной формой.
  `allowKerberosAuthentication: true` у LDAP-федерации.
- **Федерация LDAP**: компонент `lab-ldap` (`ldap://${LDAP_HOST}:389`,
  bind `cn=admin,dc=lab,dc=test`, `usersDn=ou=people,...`, READ_ONLY,
  мапперы username/uid, firstName/cn, lastName/sn, email/mail).
  SPNEGO-принципал `alice@LAB.TEST` резолвится в LDAP-пользователя
  `uid=alice,ou=people,dc=lab,dc=test`.
- **Эфемерность**: тома под данные нет (H2 в контейнере) — при каждом
  старте контейнер заново импортирует realm из шаблона. Правки
  `keycloak/realm-lab.json.tpl` применяются через
  `docker compose --profile keycloak up -d --force-recreate keycloak`
  (шаблон монтируется в `/templates` bind-mount-ом, пересборка не нужна).

Доступы:

- Админка: <http://127.0.0.1:8081/> — `admin` /
  `KEYCLOAK_ADMIN_PASSWORD` из `.env`.
- Account console: <http://keycloak.lab.test:8081/realms/lab/account/>
  — SPNEGO-вход по билету. Из браузера хоста действуют те же шаги, что
  и для Apache: запись `keycloak.lab.test` в `/etc/hosts` (порт с хоста —
  **8081**, внутри Docker-сети 8080), `kinit alice`, в Firefox
  `network.negotiate-auth.trusted-uris` — `web.lab.test, keycloak.lab.test`.

Проверка из клиентского контейнера:

```bash
docker compose exec client bash
echo "$ALICE_PASSWORD" | kinit alice
# без билета — 401 + WWW-Authenticate: Negotiate:
curl -s -o /dev/null -D- 'http://keycloak.lab.test:8080/realms/lab/protocol/openid-connect/auth?client_id=account-console&redirect_uri=http%3A%2F%2Fkeycloak.lab.test%3A8080%2Frealms%2Flab%2Faccount%2F&response_type=code&scope=openid&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256' | head -3
# с билетом — 302 с OIDC-кодом (client_id account-console требует PKCE):
spnego-check 'http://keycloak.lab.test:8080/realms/lab/protocol/openid-connect/auth?client_id=account-console&redirect_uri=http%3A%2F%2Fkeycloak.lab.test%3A8080%2Frealms%2Flab%2Faccount%2F&response_type=code&scope=openid&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256'
```

Prometheus (при запущенном профиле) скрейпит Keycloak по management-интерфейсу
`keycloak.lab.test:9000` (задача `keycloak`); без профиля verify-скрипт
исключает её из проверки «все таргеты up».

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
10. **Grafana 13: парольный логин — `POST /login`, а не `/api/login`.**
    В Grafana 13.2.4 роут `/api/login` отсутствует (401
    `handler=notfound`), фронтенд шлёт `POST /login` — проверено на
    «чистом» образе, поведение штатное и не зависит от auth.proxy.
    Отсюда: админка работает на `127.0.0.1:3000/grafana/login`,
    пользовательский API — `/grafana/api/...` после сессионной куки.
11. **Grafana редиректит на canonical URL `root_url`.**
    `root_url=http://web.lab.test:8080/grafana/` обязателен, чтобы
    браузер с хоста ходил на 8080, но изнутри Docker-сети этот адрес
    не слушается. Поэтому Prometheus скрейпит Grafana по каноническому
    пути `/grafana/metrics` (путь `/metrics` отвечает 301), а
    `spnego-check` принимает 200/301/302 и не следует за редиректом.
12. **Keycloak 26: SPNEGO-аутентикатор называется `auth-spnego`.**
    Старые примеры/доки используют id `kerberos` — в 26.8 фабрика
    `SpnegoAuthenticatorFactory` имеет `PROVIDER_ID = "auth-spnego"`
    (сам feature `kerberos:v1` включён по умолчанию, отдельный
    `KC_FEATURES=kerberos` в compose — явная страховка). Execution
    неизвестного провайдера не падает при импорте, а ломает flow
    на runtime: `Unable to find factory for AuthenticatorFactory: ...`.
13. **Импорт realm: у subflow-execution обязательно `authenticatorFlow: true`.**
    Импорт (`DefaultExportImportManager.toModel`) читает одноимённое поле
    JSON; без него execution создаётся с `flowId`, но
    `authenticatorFlow=false` → на запросе NPE в
    `AuthenticationSelectionResolver` («Unexpected error when handling
    authentication request»). Аналогично у leaf-executions ставьте
    `authenticatorFlow: false`.
14. **Мапперы LDAP задаются через `subComponents`, не `parentId`.**
    В JSON realm мапперы (`user-attribute-ldap-mapper`) — дочерние
    компоненты storage-провайдера: вложенный объект `subComponents`
    внутри компонента `lab-ldap`. Поле `parentId` импорт не знает
    (`Unrecognized field "parentId"` — крэш старта). Без мапперов
    вовсе LDAP-поиск вернёт entry без атрибутов
    («User returned from LDAP has null username ... attributes: {}»).
15. **`krbPrincipalAttribute: ""` ломает SPNEGO-поиск.**
    Пустая строка ≠ null: код идёт по ветке поиска по атрибуту и строит
    фильтр `(&(=alice@LAB.TEST)...)` → `InvalidSearchFilterException`.
    Ключ нужно не задавать вовсе — тогда срабатывает штатный путь
    «principal minus realm → username → LDAP uid».
16. **account-console требует PKCE.** Auth-endpoint публичного клиента
    `account-console` без `code_challenge`/`code_challenge_method=S256`
    отвечает 400 «Missing parameter: code_challenge_method»; redirect_uri —
    только зарегистрированный `/realms/lab/account/*`.
17. **Keycloak и HTTP/2 + SPNEGO.** SPNEGO-обмен шлёт HTTP/1.1-запросы
    в моменты 401/Negotiate; Vert.x с включённым HTTP/2 отвечает 500
    (keycloak#45863) — в compose задано `KC_HTTP_HTTP2=false`.
18. **Java-krb5 в Keycloak — системным свойством.** UBI-micro-образ без
    оболочки: entrypoint рендерит `common/krb5.conf.tpl` в `/tmp/krb5.conf`
    и передаёт `JAVA_OPTS_APPEND=-Djava.security.krb5.conf=/tmp/krb5.conf`
    (проверить: `docker exec keycloak cat /proc/1/cmdline | tr '\0' '\n'`).
    Ключ отдельного принципала `HTTP/<host>` + keytab в контейнер —
    обязательное условие; после правки `kdc/entrypoint.sh` образ KDC
    нужно **пересобрать** (entrypoint запечён в образ).

## Диагностика

```bash
docker compose ps                       # статус и healthcheck
docker compose logs -f kdc              # логи KDC (AS_REQ/ISSUE, ошибки)
docker compose logs -f ldap             # slapd -d stats: BIND, SEARCH, ACL
docker compose logs -f web              # stdout Apache; ошибки:
docker compose exec web tail -20 /var/log/apache2/error.log
docker compose logs -f grafana          # аутентификация, редиректы, API
docker compose logs -f prometheus       # scrape и blackbox-пробы
docker compose --profile keycloak logs -f keycloak   # импорт realm, SPNEGO, LDAP
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
- Keycloak отдаёт 400 «Unexpected error when handling authentication
  request» — см. пункты 12–14 (id `auth-spnego`, `authenticatorFlow`,
  мапперы LDAP); «Missing parameter: code_challenge_method» —
  нужен PKCE (пункт 16).
