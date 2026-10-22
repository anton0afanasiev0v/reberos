# Kerberos — лаборатория двухузловой аутентификации (Kerberos + OpenLDAP + OIDC)

Лаборатория в спеке двух узлов (см. [docs/kerberos-two-nodes.drawio](docs/kerberos-two-nodes.drawio)):
каждый узел — домашний KDC + OpenLDAP + Apache (SPNEGO) + Keycloak (OIDC)
+ портал; на узел по две организации (realm). Пользователь проходит **два
уровня авторизации**:

1. **SPNEGO** (Kerberos) — Apache (`mod_auth_gssapi`) закрывает портал,
   личность передаётся в `X-Remote-User`;
2. **OIDC** (web-форма логин/пароль) — портал выбирает организацию,
   Keycloak выпускает `id_token`, пользователи читаются из OpenLDAP
   (LDAP-федерация, simple bind).

Ключевые связи: **cross-realm доверие внутри узла** (ORG1↔ORG2, ORG3↔ORG4 —
общие `krbtgt`-ключи на KDC узла), **между узлами доверия нет**
(негативный тест в verify). GSSAPI-привязка slapd сохранена; мониторинга
в новой лабе нет.

## Быстрый старт

```bash
./scripts/verify.sh      # поднимает 3 compose-проекта и гоняет 28 проверок
./scripts/reset.sh       # остановить все проекты и удалить данные
```

Поднять вручную (порядок важен: Узел А создаёт сеть `kerberos`):

```bash
docker compose -f compose-node-a.yml   up -d --build   # Узел А (создаёт сеть)
docker compose -f compose-node-b.yml   up -d --build   # Узел Б
docker compose -f compose-client.yml   up -d --build   # клиент
```

## Два физических хоста (канал между узлами 2 МБ/с)

Если Узел А и Узел Б — разные машины, общий docker-мост не работает:
схема с host-network, имена через `/etc/hosts`, образы собираются
**один раз** на Узле А и переносятся на Узел Б (≈450 МБ один раз,
повторный деплой — ≈0).

```bash
./scripts/build-images.sh                                  # на Узле А
./scripts/sync-node-b.sh --peer user@<IP-хоста-Б>           # перенос образов
./scripts/install-hosts.sh a <IP-хоста-Б> | sudo tee -a /etc/hosts
docker compose --env-file .env --env-file deploy/env-a.env \
    -f compose-node-a.yml -f compose-node-a.host.yml up -d   # Узел А
# на Узле Б:
docker compose --env-file .env --env-file deploy/env-b.env \
    -f compose-node-b.yml -f compose-node-b.host.yml up -d
```

Подробности, бюджет трафика и режимы переноса — в
[docs/two-hosts.md](docs/two-hosts.md).

Полная проверка закрывает: `kinit` во все 4 realm, GSSAPI в LDAP обоих
узлов (домашний + cross-realm), отказ межузлового доступа, HTTP 401/200
через SPNEGO (домашний + cross-realm + межузловой отказ), доступность
realm Keycloak через Apache `/auth` без SPNEGO, полный OIDC-флоу через
портал (SPNEGO → логин-форма → `id_token`) и отказ `/me` без сессии.

## Нативный узел на Astra Linux SE 1.7 (без Docker)

Один узел с двумя организациями: **один** `krb5kdc` с двумя realm'ами
(`ORG1.TEST` и `ORG2.TEST`, раздельные БД/stash/ACL), OpenLDAP с GSSAPI,
изоляция организаций по веткам `ou=org1` / `ou=org2` и **Keycloak 26.8.1**
(realm `lab-a`, LDAP-федерация на наш slapd — как в лаборатории).

```bash
# на узле (Astra)
sudo chmod 600 deploy/astra-node-a.env      # там пароли
chmod 700 scripts/*.sh
sudo ./scripts/astra-node-a.sh --dry-run     # план установки
sudo ./scripts/astra-node-a.sh               # установка (идемпотентно)
sudo ./scripts/astra-node-a-verify.sh        # проверки (ожидаемо FAIL=0)
sudo ./scripts/astra-node-a-remove.sh        # полное удаление (откат)

# на локальном ПК (клиент: kinit, GSSAPI, браузер)
sudo apt install krb5-user ldap-utils libsasl2-modules-gssapi-mit
./scripts/astra-node-a-client.sh --check
sudo ./scripts/astra-node-a-client.sh --server 172.16.138.25
```

После этого с ПК: `kinit alice@ORG1.TEST` (`Alice_Secret_2024`),
`ldapwhoami -Y GSSAPI -H ldap://ldap-a.lab.test`, Keycloak —
<http://keycloak-a.lab.test:8080/auth>. Пошагово «с нуля» (сервер, клиент,
пользование, откат, типовые ошибки) —
[docs/astra-node-a-quickstart.md](docs/astra-node-a-quickstart.md).

Интернета на узле нет, поэтому Keycloak и JRE берутся из `vendor/` — перед
переносом положите туда `keycloak-26.8.1.tar.gz` (и, если в репозиториях
Astra нет `openjdk-17`, `temurin17-jre-x64-linux.tar.gz`); см.
[vendor/README.md](vendor/README.md).

Подробности (пакеты, `kdc.conf` с двумя realm'ами, кросс-реалмовое доверие,
`slapd` как unit, `sasl-regexp` вместо `authz-regexp`, Keycloak, таблица
проблем) — в [docs/astra-node-a.md](docs/astra-node-a.md).

## Состав

| Проект | Сервис | Адрес | Роль |
|---|---|---|---|
| Узел А | `kdc-a1.lab.test` | 172.30.11.11 | KDC realm `ORG1.TEST` (домашний) |
| Узел А | `kdc-a2.lab.test` | 172.30.11.12 | KDC realm `ORG2.TEST` |
| Узел А | `ldap-a.lab.test` | 172.30.11.20 | OpenLDAP, GSSAPI, `dc=lab,dc=test` |
| Узел А | `web-a.lab.test` | 172.30.11.40 | Apache: SPNEGO + portal + `/auth` |
| Узел А | `keycloak-a.lab.test` | 172.30.11.41 | Keycloak realm `lab-a` (OIDC-only) |
| Узел А | `portal-a.lab.test` | 172.30.11.42 | Портал (Python, сессии) |
| Узел Б | `kdc-b3.lab.test` | 172.30.11.13 | KDC realm `ORG3.TEST` (домашний) |
| Узел Б | `kdc-b4.lab.test` | 172.30.11.14 | KDC realm `ORG4.TEST` |
| Узел Б | `ldap-b.lab.test` | 172.30.11.21 | OpenLDAP, GSSAPI |
| Узел Б | `web-b.lab.test` | 172.30.11.50 | Apache: SPNEGO + portal + `/auth` |
| Узел Б | `keycloak-b.lab.test` | 172.30.11.51 | Keycloak realm `lab-b` (OIDC-only) |
| Узел Б | `portal-b.lab.test` | 172.30.11.52 | Портал (Python, сессии) |
| клиент | `client.lab.test` | 172.30.11.30 | kinit/ldap/SPNEGO/OIDC-проверки |

Сеть `kerberos` (172.30.11.0/24) создаётся проектом Узла А; Узел Б и клиент
подключаются как `external`. Порты на localhost хоста: `8081` — web-a,
`8082` — web-b, `8091`/`8092` — админка Keycloak A/Б.

## Как работает (коротко)

```
kinit alice@ORGx.TEST
   │
   ▼
Уровень 1: браузер/клиент → Apache (SPNEGO, HTTP/web-x)
   │                       Apache → portal:8000  (X-Remote-User)
   ▼
Уровень 2: portal /login?org=ORGx.TEST → Keycloak /auth (web-форма)
   │        Keycloak → OpenLDAP (simple bind, federated user)
   ▼
authorization code → portal /callback → id_token в сессии → /me
```

- **Cross-realm**: на обоих KDC узла создаются `krbtgt/ЧУЖОЙ@СВОЙ` и
  `krbtgt/СВОЙ@ЧУЖОЙ` с общим ключом (`CROSS_REALM_KEY`); клиент знает
  прямые пути из `[capaths]`. Межузловых принципалов нет.
- **Keytabs**: общий том на узел, файлы с префиксом KDC
  (`a1-ldap.keytab`, `a1-http.keytab`, ...); слушатели ждут свой файл.
- **Keycloak — только OIDC**: без `auth-spnego` и keytab; realm
  импортируется при старте, confidential-клиент `portal` с redirect
  `http://web-x.lab.test[:port]/callback` и `http://web-x.lab.test/callback`.

- **Изоляция организаций (Kerberos + LDAP ACL)**: `dc=lab,dc=test` — одна
  база на узел, организации разведены по веткам `ou=orgN,ou=people`.
  `authz-regexp` маппит принципал в ветку по realm; пользователь читает
  только свою ветку. Логины уникальны (`orgNuserM`), поэтому Keycloak
  (уровень 2) видит **обе** организации узла (`usersDn=ou=people`).
  Тонкости realmless/cross-realm — в `docs/docker-lab.md`.

Учётные данные (только лаборатория!):
- `orgNuser1..5` (`org1user1`, `org2user1`, …) / `ORG_USER_PASSWORDS_A/B`
  (индивидуальный пароль каждому) — рабочие пользователи, realm ORG N,
  доступ только к своей организации; полный список — `SYSTEM_USERS` в `.env`
  (портал показывает его на главной);
- `alice` / `ALICE_PASSWORD` — smoke-пользователь (один пароль во всех
  4 realm, видит обе ветки узла);
- `admin` (админ узла) / `NODE_ADMIN_PASSWORD` — `ou=admins`, write на всю
  базу узла; Kerberos `admin/admin` / `ADMIN_PASSWORD` — для kadmin;
- LDAP rootdn `cn=admin,dc=lab,dc=test` / `LDAP_ADMIN_PASSWORD`, Keycloak
  `admin` / `KEYCLOAK_ADMIN_PASSWORD` (админка — `http://127.0.0.1:8091/`
и `:8092`).

## Документация

- [docs/docker-lab.md](docs/docker-lab.md) — устройство лаборатории,
  ручные проверки, доступ из браузера хоста, **`kinit` на локальном ПК**
  (пошагово) и **таблица доступов по realm**, «подводные камни».
- [docs/two-hosts.md](docs/two-hosts.md) — развёртывание на двух
  физических хостах через канал 2 МБ/с: схема сети, перенос образов,
  бюджет трафика.
- [docs/kerberos-two-nodes.drawio](docs/kerberos-two-nodes.drawio) —
  диаграмма целевой архитектуры (два узла, два уровня авторизации).
- [docs/astra-1.7-kerberos.md](docs/astra-1.7-kerberos.md) — нативное
  развёртывание Kerberos + OpenLDAP GSSAPI + Apache на Astra Linux SE 1.7.
- [docs/astra-node-a.md](docs/astra-node-a.md) — нативный «Узел А» на
  Astra Linux SE 1.7: один `krb5kdc` с двумя realm'ами (2 организации) +
  OpenLDAP GSSAPI; установка, проверки, клиент, полное удаление.
- [docs/astra-node-a-quickstart.md](docs/astra-node-a-quickstart.md) —
  «с нуля»: сервер, клиент, как пользоваться (`kinit`, GSSAPI, Keycloak),
  эксплуатация, типовые ошибки.

## Структура

```
├── .env                     # параметры: 4 realm, хосты, IP, пароли
├── compose-node-a.yml       # Узел А: 2 KDC, LDAP, Apache, Keycloak, portal
├── compose-node-b.yml       # Узел Б: зеркало Узла А
├── compose-client.yml       # клиентская вагонка
├── compose-host-kdc-a.yml   # override: публикует KDC Узла А на 127.0.0.1:88
├── compose-host-kdc-b.yml   # override: публикует KDC Узла Б на 127.0.0.1:88
├── compose-node-a.host.yml  # override: Узел А на отдельном хосте (host-network)
├── compose-node-b.host.yml  # override: Узел Б на отдельном хосте (host-network)
├── compose-client.host.yml  # override: клиент в host-network
├── deploy/                  # схема «два хоста»: env и /etc/hosts по узлам
│   ├── env-a.env
│   ├── env-b.env
│   └── astra-node-a.env     # параметры нативного узла на Astra 1.7
├── common/krb5.conf.tpl     # шаблон krb5.conf (один realm; серверы)
├── client/krb5.conf.tpl     # клиентский krb5.conf: 4 realm + capaths
├── kdc/                     # образ и entrypoint KDC (+ cross-realm)
├── ldap/                    # slapd + authz-regexp + seed-каталог
├── apache/                  # Apache: SPNEGO на portal, /auth без SPNEGO
├── keycloak/                # Keycloak: OIDC-only realm + LDAP-федерация
├── vendor/                  # офлайн-дистрибутивы для Astra (Keycloak, JRE) — в git не коммится
├── portal/                  # портал выбора организации (Python, stdlib)
├── docs/
│   ├── host-krb5-node-a.conf.example   # krb5.conf для kinit с локального ПК (А)
│   ├── host-krb5-node-b.conf.example   # krb5.conf для kinit с локального ПК (Б)
│   ├── two-hosts.md        # развёртывание на двух хостах через канал 2 МБ/с
│   ├── astra-node-a.md     # нативный узел на Astra 1.7 (2 организации)
│   ├── astra-node-a-quickstart.md  # сервер+клиент «с нуля», пользование
│   └── docker-lab.md
└── scripts/
    ├── verify.sh            # сквозная проверка (28 тестов)
    ├── verify-remote.sh     # то же, но Узел Б на удалённой машине
    ├── build-images.sh      # единая сборка образов lab/<svc>:1
    ├── sync-node-b.sh       # перенос образов на Узел Б (bundle|registry|build)
    ├── install-hosts.sh     # фрагмент /etc/hosts для хоста
    ├── astra-node-a.sh      # нативная установка KDC+LDAP+Keycloak на Astra 1.7
    ├── astra-node-a-verify.sh  # проверки нативного узла
    ├── astra-node-a-client.sh  # настройка локального ПК как клиента
    ├── astra-node-a-remove.sh  # полное удаление нативного узла
    ├── templates/           # встроенные шаблоны для узла (ldap/, keycloak/)
    └── reset.sh             # остановка с удалением данных
```

`kinit` с локального ПК: подними узел с override (`-f compose-host-kdc-a.yml`),
скопируй `docs/host-krb5-node-a.conf.example` в `/etc/krb5.conf` и выполни
`kinit alice@ORG1.TEST` — см. [docs/docker-lab.md](docs/docker-lab.md).
