# reberos — лаборатория Kerberos + OpenLDAP (GSSAPI)

Лаборатория аутентификации Kerberos (MIT, realm `LAB.TEST`) с интеграцией
OpenLDAP через SASL/GSSAPI и опциональным веб-сервером Apache
(`mod_auth_gssapi`, SPNEGO). Всё разворачивается в Docker Compose;
есть руководство для нативного развёртывания на Astra Linux SE 1.7 (ALSE).

## Быстрый старт

```bash
docker compose up -d --build          # kdc + ldap + client
./scripts/verify.sh                   # 8 автоматических проверок

# с опциональным веб-сервером (Apache + SPNEGO):
./scripts/verify.sh --with-apache     # 11 проверок

# остановить и удалить данные:
./scripts/reset.sh
```

Полная автоматическая проверка закрывает: `kinit`, получение TGT,
GSSAPI-привязку к LDAP с маппингом в `uid=alice,ou=people,dc=lab,dc=test`,
негативные сценарии (без билета, анонимный доступ), HTTP 401/200 через SPNEGO.

## Состав

| Сервис | Адрес | Роль |
|---|---|---|
| `kdc.lab.test` | 172.30.10.10 | KDC + kadmin (krb5kdc, kadmind) |
| `ldap.lab.test` | 172.30.10.20 | OpenLDAP slapd, префикс `dc=lab,dc=test` |
| `client.lab.test` | 172.30.10.30 | клиент: krb5, ldap-utils, python-SPNEGO |
| `web.lab.test` | 172.30.10.40 | Apache + mod_auth_gssapi (профиль `apache`) |

Порты опубликованы только на localhost хоста: `88` (KDC), `749` (kadmin),
`464` (changepw), `389` (LDAP), `8080` (HTTP).

Учётные данные (только лаборатория!): пользователь `alice` /
пароль из `.env` (`ALICE_PASSWORD`); администратор Kerberos `admin/admin`;
LDAP rootdn `cn=admin,dc=lab,dc=test` / `LDAP_ADMIN_PASSWORD`.

## Документация

- [docs/docker-lab.md](docs/docker-lab.md) — устройство Docker-лаборатории,
  как работает, «подводные камни» (authz-regexp, HTTP-принципал, Docker DNS).
- [docs/astra-1.7-kerberos.md](docs/astra-1.7-kerberos.md) — нативное
  развёртывание Kerberos + OpenLDAP GSSAPI + Apache на Astra Linux SE 1.7
  (по материалам wiki.astralinux.ru).

## Структура

```
├── .env                     # параметры лаборатории (realm, хосты, IP, пароли)
├── docker-compose.yml       # сеть 172.30.10.0/24, сервисы, healthcheck
├── common/krb5.conf.tpl     # единый шаблон krb5.conf
├── kdc/                     # образ и entrypoint KDC
├── ldap/                    # slapd + authz-regexp + seed-каталог
├── client/                  # клиентская утилитарная среда
├── apache/                  # Apache + mod_auth_gssapi (профиль apache)
└── scripts/
    ├── verify.sh            # сквозная проверка лаборатории
    └── reset.sh             # остановка с удалением данных
```
