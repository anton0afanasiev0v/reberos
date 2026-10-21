# Docker-лаборатория: два узла, два уровня авторизации

Лаборатория собрана по диаграмме [reberos-two-nodes.drawio](reberos-two-nodes.drawio)
и состоит из **трёх compose-проектов**:

- `compose-node-a.yml` — **Узел А** (ORG1, ORG2), создаёт сеть `reberos`;
- `compose-node-b.yml` — **Узел Б** (ORG3, ORG4), сеть `external`;
- `compose-client.yml` — **клиент** (kinit/ldap/SPNEGO/OIDC), сеть `external`.

Всё «из коробки»: на каждом узле — два KDC (по организации), OpenLDAP с
GSSAPI-привязкой, Apache с SPNEGO, Keycloak (OIDC, федерация LDAP) и
портал. Мониторинга в этой версии нет. Решения ниже проверены запуском
(`./scripts/verify.sh`, 19 проверок).

## Запуск

```bash
./scripts/verify.sh     # поднимет 3 проекта (А → Б → клиент) и проверит
./scripts/reset.sh      # остановить всё и удалить тома

# или вручную (порядок важен — Узел А создаёт сеть):
docker compose -f compose-node-a.yml up -d --build
docker compose -f compose-node-b.yml up -d --build
docker compose -f compose-client.yml up -d --build
```

Все параметры — в `.env` (4 realm, имена, IP, пароли). Пароли — **только
для лаборатории**.

## Два уровня авторизации

Запрос пользователя проходит цепочку:

1. **Уровень 1 — SPNEGO.** Apache узла (`HTTP/web-x.lab.test`,
   keytab `a1-http.keytab`/`b3-http.keytab`) требует валидный
   Kerberos-билет на всё, кроме `/auth`. Личность кладётся в
   `X-Remote-User` и уходит порталу.
2. **Уровень 2 — OIDC.** Портал (`portal/app.py`, Python stdlib) показывает
   организации узла; выбор → `302` на Keycloak `/auth/realms/<realm>/...`
   (web-форма логин/пароль, **без SPNEGO** — иначе SSO-петля) → Keycloak
   проверяет пользователя по **LDAP-федерации** (simple bind,
   `cn=admin,dc=lab,dc=test`) → authorization code → портал меняет код на
   `id_token` внутренним адресом `keycloak-x:8080/auth` → `/me` отдаёт JSON
   с `id_token` и claims.

Зачем `/auth` без SPNEGO: Keycloak на `/auth/...` отвечал бы `401 Negotiate`,
Apache добавлял бы свой SPNEGO-вызов, и браузер уходил бы в петлю. Поэтому
`<Location /auth>` открыт, а SPNEGO включён через `<LocationMatch "^(?!/auth...)">`.

## Cross-realm (внутри узла)

- На **обоих** KDC узла создаются принципалы `krbtgt/ЧУЖОЙ@СВОЙ` и
  `krbtgt/СВОЙ@ЧУЖОЙ` **с одним паролем** (`CROSS_REALM_KEY`) — как требует
  MIT («In both databases … same passwords, key version numbers»). Ключи
  создаются без `requires_preauth` (рекомендация MIT).
- Клиент знает прямые пути через `[capaths]` (`ORG1 = { ORG2 = . }` и
  наоборот) — см. `client/krb5.conf.tpl`.
- Сервисные принципалы (`ldap/ldap-x`, `HTTP/web-x`) выписывает **домашний**
  KDC узла (`CREATE_SERVICES=1` только у `kdc-a1`/`kdc-b3`), поэтому Apache
  принимает билеты **обеих** организаций узла (cross-realm приход).
- **Между узлами доверия нет**: билет `ORG1` не даёт доступа к `ldap-b`/`web-b`
  (негативные тесты 7 и 15).

Keytabs: общий том на узел (`keytabs-a`/`keytabs-b`), имена с префиксом KDC —
`<prefix>-ldap.keytab`, `<prefix>-http.keytab` (например `a1-http.keytab`).
KDC выписывает только свои файлы; слушатели ждут ровно свой.

## Проверка вручную

```bash
# любые из трёх проектов: exec в клиента
docker compose -f compose-client.yml exec client bash

echo "$ALICE_PASSWORD" | kinit alice@ORG1.TEST
ldapwhoami -Y GSSAPI -Q -H ldap://ldap-a.lab.test      # uid=alice,ou=people,...
ldapwhoami -Y GSSAPI -Q -H ldap://ldap-a.lab.test      # после kinit ORG2 — cross-realm
ldapwhoami -Y GSSAPI -Q -H ldap://ldap-b.lab.test      # ОТКАЗ (нет доверия между узлами)

# уровень 1 + уровень 2 целиком:
spnego-check http://web-a.lab.test/
oidc-check http://web-a.lab.test ORG1.TEST alice "$ALICE_PASSWORD"
```

С хоста видны только порты Apache (на `127.0.0.1`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/     # 401 (нет билета)
```

## Кто куда имеет доступ

Пользователь в лаборатории один — **`alice`**; пароль `ALICE_PASSWORD`
(`Alice_Secret_2024`) одинаков во всех 4 realm. Отличается только realm,
которому принадлежит билет, и это определяет доступ:

| Билет (`kinit`) | `ldap-a` (Узел А) | `ldap-b` (Узел Б) | `web-a` (SPNEGO) | `web-b` (SPNEGO) |
|---|---|---|---|---|
| `alice@ORG1.TEST` | ✅ | ❌ | ✅ | ❌ |
| `alice@ORG2.TEST` | ✅ (cross-realm) | ❌ | ✅ (cross-realm) | ❌ |
| `alice@ORG3.TEST` | ❌ | ✅ | ❌ | ✅ |
| `alice@ORG4.TEST` | ❌ | ✅ (cross-realm) | ❌ | ✅ (cross-realm) |

- **Внутри узла доверие есть**: билет ORG1 и ORG2 одинаково открывают
  `ldap-a`/`web-a` (ORG3/ORG4 — `ldap-b`/`web-b`).
- **Между узлами доверия нет**: билет ORG1 не даёт доступа к `ldap-b`/`web-b`.
- После OIDC-входа портал `/me` отдаёт `id_token` и claims (организация +
  SPNEGO-личность).
- Админ-доступы (не для `alice`): Kerberos `admin/admin` (`ADMIN_PASSWORD`),
  LDAP rootdn `cn=admin,dc=lab,dc=test` (`LDAP_ADMIN_PASSWORD`),
  Keycloak `admin` (`KEYCLOAK_ADMIN_PASSWORD`).

## `kinit` на локальном ПК (пошагово)

**Требование времени:** часы ПК и KDC должны совпадать (±5 мин в Kerberos).
Проверь `date` до `kinit`, иначе `Clock skew too great`.

Важно: **KDC не опубликованы на хост-порты**. `kinit` — это сетевой клиент
KDC (порт 88/tcp+udp), и имя `kdc-a1.lab.test` резолвится только внутри
Docker-сети. Поэтому хост снаружи KDC не видит — нужен либо проброс порта
(шаг 2), либо `kinit` из клиентского контейнера (шаг 2b).

### Шаг 1 — имена хостов в `/etc/hosts`

Из хоста доступны только порты Apache (`127.0.0.1:8081`/`:8082`) и админки
Keycloak (`:8091`/`:8092`). Для браузерного SPNEGO:

```bash
sudo sh -c 'echo "127.0.0.1 web-a.lab.test web-b.lab.test" >> /etc/hosts'
```

### Шаг 2 — публикация KDC на хост (override-файл)

Готовый override лежит в репозитории и **не меняет базовый запуск**:
`compose-host-kdc-a.yml` (Узел А) и `compose-host-kdc-b.yml` (Узел Б).
Он публикует домашний KDC узла на `127.0.0.1:88`:

```bash
# Узел А: kdc-a1 (ORG1.TEST)
docker compose -f compose-node-a.yml -f compose-host-kdc-a.yml up -d

# Узел Б: kdc-b3 (ORG3.TEST)
docker compose -f compose-node-b.yml -f compose-host-kdc-b.yml up -d
```

Ограничение: порт `88` у Kerberos-клиента фиксирован, поэтому публикуй
**ровно один** узел за раз — иначе `port is already allocated`. Чтобы
вернуться к базовому составу (без хост-порта 88):

```bash
docker compose -f compose-node-a.yml up -d   # пересоздаст kdc-a1 без ports
```

### Шаг 2b (рекомендуется) — `kinit` из клиентского контейнера

```bash
docker compose -f compose-client.yml exec client bash
echo 'Alice_Secret_2024' | kinit alice@ORG1.TEST
klist
```

Так работают все проверки `verify.sh` — ничего публиковать не нужно.

### Шаг 3 — хостовый Kerberos (браузерный SPNEGO на `web-a`/`web-b`)

```bash
sudo apt install krb5-user
```

Готовый пример `krb5.conf` лежит в репозитории:

```bash
sudo cp docs/host-krb5-node-a.conf.example /etc/krb5.conf   # Узел А (ORG1/ORG2)
# или
sudo cp docs/host-krb5-node-b.conf.example /etc/krb5.conf   # Узел Б (ORG3/ORG4)
```

Ключевое в нём: `kdc = 127.0.0.1` (порт 88 из шага 2),
`dns_lookup_kdc = false`, кэш `FILE:/run/user/%{uid}/krb5cc_lab`
и `[domain_realm] .lab.test`.

Без публикации KDC (шаг 2) хостовый `kinit` вернёт
`Cannot contact any KDC for realm` — порт 88 на хост не опубликован, а
`kdc-a1.lab.test` резолвится только в Docker-сети.

### Шаг 4 — билет и браузер

```bash
kinit alice@ORG1.TEST      # пароль: Alice_Secret_2024
klist
```

Проверка, что KDC действительно виден с хоста:

```bash
kinit alice@ORG1.TEST && klist        # должно выдать TGT krbtgt/ORG1.TEST@ORG1.TEST
```

Firefox **.deb** (не snap — см. п. 9), в `about:config` →
`network.negotiate-auth.trusted-uris` = `web-a.lab.test, web-b.lab.test`,
затем открой <http://web-a.lab.test:8081/>. После `kdestroy` + перезагрузки
страницы снова будет 401.

## Подводные камни (проверенные решения)

1. **`authz-regexp`, а не `sasl-regexp`.** В OpenLDAP 2.5 (Debian 12)
   директива маппинга SASL-идентичности называется `authz-regexp`, стоит в
   глобальной секции — до `database`. Матчит
   `uid=<user>[@REALM],cn=gssapi,cn=auth` → `uid=$1,ou=people,dc=lab,dc=test`.
   Проверка: `ldapwhoami -Y GSSAPI` даёт `dn:uid=alice,ou=people,...`.
2. **Принципал Apache — заглавными `HTTP/host`.** `http/...` и `HTTP/...` —
   разные записи; SPNEGO-клиенты и `mod_auth_gssapi` используют `HTTP/...`.
3. **DNS Docker ломает канонизацию имён.** PTR вида
   `ldap-a.lab.test.reberos` строит принципал `ldap/ldap-a.lab.test.reberos`
   и GSSAPI падает. Лечение: `SASL_NOCANON on` в клиентском
   `/etc/ldap/ldap.conf` + `dns_canonicalize_hostname=false` в krb5.conf.
   Пиннинг `/etc/hosts` **не применять** — Docker перезаписывает файл.
4. **`sasl-secprops minssf=0,maxssf=0`** — без TLS; иначе slapd требует SSF.
5. **`master_key_type = aes256-cts`** (не `:normal`) — иначе `kdb5_util
   create` падает с «Program lacks support for key type».
6. **Debian curl без GSS-API** — `curl --negotiate` не работает; для SPNEGO
   в клиенте лежит `spnego-check` (requests-kerberos), для OIDC — `oidc-check`.
7. **Cross-realm: ключи на обоих KDC.** Один и тот же `krbtgt/ЧУЖОЙ@СВОЙ`
   (и обратный) с одинаковым паролем на обоих KDC узла; иначе
   `KDC can't fulfill requested option`/`Server not found`.
8. **`[capaths]` обязателен для прямого доверия.** Без
   `ORG1 = { ORG2 = . }` клиент может искать иерархический путь.
9. **Keycloak OIDC-only ≠ SPNEGO.** В realm нет `auth-spnego`/
   `allowKerberosAuthentication`; keytab не нужен. `/auth` держите вне
   SPNEGO, иначе SSO-петля (постоянный `401 Negotiate`).
10. **Keycloak realm-импорт идемпотентен, данные эфемерные.** H2 без тома;
    правки шаблона применяются через `up -d --force-recreate keycloak-x`.
11. **редирект-URI портала.** В клиенте зарегистрированы и
    `http://web-x.lab.test:8081/callback` (браузер), и
    `http://web-x.lab.test/callback` (из Docker-сети) — портал строит
    redirect из заголовка `Host`, поэтому нужны оба.
12. **Порядок запуска.** Сеть `reberos` создаёт Узел А; Узел Б и клиент
    объявляют её `external` и упадут, если А ещё не поднят.

## Диагностика

```bash
docker compose -f compose-node-a.yml ps
docker compose -f compose-node-a.yml logs -f kdc-a1     # AS_REQ/ISSUE, cross-realm
docker compose -f compose-node-a.yml logs -f ldap-a     # slapd -d stats: BIND/SEARCH
docker compose -f compose-node-a.yml logs -f web-a      # Apache; детали:
docker compose -f compose-node-a.yml exec web-a tail -20 /var/log/apache2/error.log
docker compose -f compose-node-a.yml logs -f portal-a   # SPNEGO-личность, OIDC-обмен
docker compose -f compose-node-a.yml logs -f keycloak-a # импорт realm, LDAP, вход
docker compose -f compose-node-a.yml exec kdc-a1 kadmin.local -q listprincs
```

Типовые симптомы:

- `ldapwhoami: Can't contact LDAP server` — нет `-H`; в клиенте задан
  `/etc/ldap/ldap.conf` с `URI ldap://ldap-a.lab.test`.
- `Server krbtgt/... not found` — канонизация DNS (п. 3) или отсутствует
  `[capaths]` (п. 8).
- `Server HTTP/web-a.lab.test not found` — регистр принципала (п. 2).
- `ldapwhoami` вернул `uid=alice,cn=gssapi,cn=auth` — не применился
  `authz-regexp` (п. 1).
- Портал зациклился на `401 Negotiate` — `/auth` попал под SPNEGO (п. 9).
- OIDC `redirect_uri` mismatch — не совпал Host/порт (п. 11).
- `kinit: Cannot contact any KDC for realm` с хоста — KDC не опубликован
  на хост-порт 88 (см. «kinit на локальном ПК», шаг 2) — используй шаг 2b.
- `kinit: Clock skew too great` — рассинхрон часов ПК и KDC (±5 мин).
