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
./scripts/verify.sh      # поднимает 3 compose-проекта и гоняет 19 проверок
./scripts/reset.sh       # остановить все проекты и удалить данные
```

Поднять вручную (порядок важен: Узел А создаёт сеть `kerberos`):

```bash
docker compose -f compose-node-a.yml   up -d --build   # Узел А (создаёт сеть)
docker compose -f compose-node-b.yml   up -d --build   # Узел Б
docker compose -f compose-client.yml   up -d --build   # клиент
```

Полная проверка закрывает: `kinit` во все 4 realm, GSSAPI в LDAP обоих
узлов (домашний + cross-realm), отказ межузлового доступа, HTTP 401/200
через SPNEGO (домашний + cross-realm + межузловой отказ), доступность
realm Keycloak через Apache `/auth` без SPNEGO, полный OIDC-флоу через
портал (SPNEGO → логин-форма → `id_token`) и отказ `/me` без сессии.

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
- [docs/kerberos-two-nodes.drawio](docs/kerberos-two-nodes.drawio) —
  диаграмма целевой архитектуры (два узла, два уровня авторизации).
- [docs/astra-1.7-kerberos.md](docs/astra-1.7-kerberos.md) — нативное
  развёртывание Kerberos + OpenLDAP GSSAPI + Apache на Astra Linux SE 1.7.

## Структура

```
├── .env                     # параметры: 4 realm, хосты, IP, пароли
├── compose-node-a.yml       # Узел А: 2 KDC, LDAP, Apache, Keycloak, portal
├── compose-node-b.yml       # Узел Б: зеркало Узла А
├── compose-client.yml       # клиентская вагонка
├── compose-host-kdc-a.yml   # override: публикует KDC Узла А на 127.0.0.1:88
├── compose-host-kdc-b.yml   # override: публикует KDC Узла Б на 127.0.0.1:88
├── common/krb5.conf.tpl     # шаблон krb5.conf (один realm; серверы)
├── client/krb5.conf.tpl     # клиентский krb5.conf: 4 realm + capaths
├── kdc/                     # образ и entrypoint KDC (+ cross-realm)
├── ldap/                    # slapd + authz-regexp + seed-каталог
├── apache/                  # Apache: SPNEGO на portal, /auth без SPNEGO
├── keycloak/                # Keycloak: OIDC-only realm + LDAP-федерация
├── portal/                  # портал выбора организации (Python, stdlib)
├── docs/
    ├── host-krb5-node-a.conf.example   # krb5.conf для kinit с локального ПК (А)
    ├── host-krb5-node-b.conf.example   # krb5.conf для kinit с локального ПК (Б)
    └── docker-lab.md
└── scripts/
    ├── verify.sh            # сквозная проверка (19 тестов)
    └── reset.sh             # остановка с удалением данных
```

`kinit` с локального ПК: подними узел с override (`-f compose-host-kdc-a.yml`),
скопируй `docs/host-krb5-node-a.conf.example` в `/etc/krb5.conf` и выполни
`kinit alice@ORG1.TEST` — см. [docs/docker-lab.md](docs/docker-lab.md).
