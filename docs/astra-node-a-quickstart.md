# Узел А с нуля: установка, клиент, пользование

Краткая инструкция «от чистого листа»: один сервер на Astra Linux SE 1.7
(Kerberos с двумя организациями + OpenLDAP) и локальный ПК как клиент
(`kinit`, GSSAPI). Подробности устройства — в
[astra-node-a.md](astra-node-a.md).

---

## Что получится

```
                    сервер 172.16.138.25 (Astra 1.7)
   ┌─────────────────────────────────────────────────────────────┐
   │  krb5kdc (один процесс, -r ORG1.TEST -r ORG2.TEST)          │
   │    ORG1.TEST ── БД /var/lib/krb5kdc          kdc-a1:88      │
   │    ORG2.TEST ── БД /var/lib/krb5kdc-ORG2     kdc-a2:88      │
   │         └──── кросс-реалмовое доверие ────┘                 │
   │  slapd 389: GSSAPI, изоляция ou=org1 / ou=org2   ldap-a     │
   └─────────────────────────────────────────────────────────────┘
                                ▲
                                │ 88/tcp, 389/tcp
                                │ (имена lab.test — через /etc/hosts)
                        локальный ПК (клиент)
```

| Сервис | Имя | Порт |
|---|---|---|
| KDC (оба realm'а) | `kdc-a1.lab.test`, `kdc-a2.lab.test` | 88/tcp+udp, 749/tcp (kadmind) |
| OpenLDAP | `ldap-a.lab.test` | 389/tcp |

Логины (если не меняли `deploy/astra-node-a.env`):

| Логин | Пароль | Где |
|---|---|---|
| `alice` | `Alice_Secret_2024` | Kerberos (оба realm'а), LDAP |
| `org1user1`…`org1user5` | `Org1UserN_2024` | то же |
| `org2user1`…`org2user5` | `Org2UserN_2024` | то же |
| `admin` | `NodeAdmin_Secret_2024` | Kerberos (админ узла), `uid=admin,ou=admins` |
| `admin/admin` | `Admin_Secret_2024` | Kerberos-администратор (`kadmin`) |

---

## Часть 1. Сервер (Astra Linux SE 1.7)

### 1.1 Что нужно

* Astra Linux SE 1.7 с root и подключёнными репозиториями (или DVD).
* Каталоги `scripts/` и `deploy/` из репозитория на узле.
* Свободны порты 88, 749, 389.

### 1.2 Установка

```bash
# на узле, в каталоге репозитория
sudo chmod 600 deploy/astra-node-a.env      # в нём пароли
chmod 700 scripts/*.sh

sudo ./scripts/astra-node-a.sh --dry-run     # посмотреть план
sudo ./scripts/astra-node-a.sh               # установить (идемпотентно)
sudo ./scripts/astra-node-a-verify.sh        # проверить
```

Ожидаемый итог установки — строка `готово. Проверки: sudo ./scripts/astra-node-a-verify.sh`.
Итог проверки — `ИТОГО: OK=47  FAIL=0` (в изолированной сети будет 3 `[WARN]`
про отсутствие NTP — это нормально, см. п. 1.4).

Если пакеты не ставятся (режимы защиты Astra), скрипт напомнит:

```bash
sudo astra-modeswitch set 0     # затем ПЕРЕЗАГРУЗКА
sudo astra-mic-control disable  # при необходимости, тоже перезагрузка
```

### 1.3 Что скрипт делает с `/etc/hosts`

На сервере каждому сервису — свой loopback-адрес (нужно для GSSAPI):

```
# BEGIN reberos astra-node-a
127.0.0.2  ldap-a.lab.test
127.0.0.3  kdc-a1.lab.test
127.0.0.4  kdc-a2.lab.test
# END reberos astra-node-a
```

Не нужно править вручную — скрипт переписывает блок; `--no-hosts` отключает.

### 1.4 Время

Kerberos отвергает билеты при расхождении часов больше ~5 минут. В
изолированной сети NTP-источников может не быть — тогда `verify` покажет
`[WARN]`, а не `[FAIL]`. Просто сверьте часы сервера и клиента:

```bash
date -u    # на сервере и на ПК — разница должна быть < 5 минут
```

---

## Часть 2. Клиент (локальный ПК)

Подходит Debian/Ubuntu/Astra. Нужны пакеты:

```bash
sudo apt install krb5-user ldap-utils libsasl2-modules-gssapi-mit
```

Затем из каталога репозитория:

```bash
./scripts/astra-node-a-client.sh --check                  # без sudo: только проверки
sudo ./scripts/astra-node-a-client.sh --server 172.16.138.25
```

Если на ПК есть `deploy/astra-node-a.env`, адрес и имена берутся оттуда, и
`--server` можно не указывать.

### 2.1 Что меняет клиентский скрипт

1. **`/etc/hosts`** — управляемый блок (идемпотентно):

   ```
   # BEGIN reberos astra-client
   172.16.138.25 ldap-a.lab.test kdc-a1.lab.test kdc-a2.lab.test
   # END reberos astra-client
   ```

2. **`/etc/krb5.conf`** — бэкап `krb5.conf.reberos-backup-<дата>` и новый
   конфиг: `default_realm = ORG1.TEST`, `rdns = false`,
   `dns_canonicalize_hostname = false`, оба realm'а, `[domain_realm]` и
   `[capaths]` для кросс-реалма.

3. **Сквозная проверка**: `kinit alice@ORG1.TEST` → `kvno
   ldap/ldap-a.lab.test` → `ldapwhoami -Y GSSAPI`, затем кросс-реалм
   `org2user1@ORG2.TEST`. Пароли берутся из env-файла, иначе `kinit` спросит.

Откат:

```bash
sudo ./scripts/astra-node-a-client.sh --uninstall
```

Скрипт вернёт `/etc/hosts` и предыдущий `/etc/krb5.conf` из бэкапа. Пакеты не
удаляются.

---

## Часть 3. Как пользоваться

Все команды — на локальном ПК после настройки клиента.

### 3.1 Билет и проверка

```bash
kinit alice@ORG1.TEST        # пароль Alice_Secret_2024
klist                        # TGT krbtgt/ORG1.TEST@ORG1.TEST
```

Второй realm (кросс-реалм):

```bash
kinit org2user1@ORG2.TEST    # пароль Org2User1_2024
klist
```

Выход:

```bash
kdestroy
```

### 3.2 LDAP через GSSAPI

```bash
kinit alice@ORG1.TEST
ldapwhoami -Y GSSAPI -H ldap://ldap-a.lab.test
# dn:uid=alice,ou=org1,ou=people,dc=lab,dc=test

kinit org2user1@ORG2.TEST
ldapwhoami -Y GSSAPI -H ldap://ldap-a.lab.test
# dn:uid=org2user1,ou=org2,ou=people,dc=lab,dc=test
```

Организации изолированы: `org1user*` не видит `ou=org2`, и наоборот.

### 3.3 Билет на сервис (без LDAP)

```bash
kinit alice@ORG1.TEST
kvno ldap/ldap-a.lab.test            # ldap/ldap-a.lab.test@ORG1.TEST: kvno = …
```

---

## Часть 4. Эксплуатация

```bash
# статус и логи (на сервере)
systemctl status krb5-kdc krb5-admin-server slapd-lab
journalctl -u krb5-kdc -n 50 --no-pager
sudo tail -f /var/log/krb5kdc.log
journalctl -u slapd-lab -n 50 --no-pager

# повторная установка/проверка — безопасны (идемпотентно)
sudo ./scripts/astra-node-a.sh
sudo ./scripts/astra-node-a-verify.sh

# пароли существующих принципалов — привести к env-файлу
sudo ./scripts/astra-node-a.sh --sync-passwords --only kdc

# управление принципалами (локально на сервере)
sudo kadmin.local -r ORG1.TEST -q "listprincs"
sudo kadmin.local -r ORG2.TEST -q "getprinc org2user1"
```

### Полное удаление

```bash
# сервер: остановить сервисы, снять пакеты/конфиги/юниты (спросит подтверждение)
sudo ./scripts/astra-node-a-remove.sh
# клиент: вернуть /etc/hosts и /etc/krb5.conf
sudo ./scripts/astra-node-a-client.sh --uninstall
```

---

## Часть 5. Если что-то не работает

| Симптом | Причина | Что делать |
|---|---|---|
| `kinit: Cannot contact any KDC for realm` | нет имён в `/etc/hosts`, неверный IP, порт 88 закрыт | `getent hosts kdc-a1.lab.test`, `./scripts/astra-node-a-client.sh --check`; проверьте firewall |
| `kinit: Clock skew too great` | часы ПК и сервера разошлись > 5 мин | `date -u` на обоих; включите NTP или подведите часы |
| `kinit: Preauthentication failed` | пароль не совпадает с БД | `sudo ./scripts/astra-node-a.sh --sync-passwords --only kdc` |
| `Client 'user@ORG2.TEST' not found` (на сервере) | KDC не обслуживает второй realm | в `/etc/default/krb5-kdc` должно быть `DAEMON_ARGS="-r ORG1.TEST -r ORG2.TEST"`; перезапустите `krb5-kdc` |
| `No key table entry found matching ldap/<hostname>` | у slapd нет `sasl-host`/keytab не тот | в `/etc/ldap/slapd.conf` строка `sasl-host ldap-a.lab.test`; `sudo ./scripts/astra-node-a.sh --rewrite-keytab --only ldap` |
| `Server ldap/...@ORG1.TEST not found` при кросс-реалме | в базах нет обоих `krbtgt`-имён | `sudo ./scripts/astra-node-a.sh --only kdc` (создаст оба имени в обеих БД) |
| `ldapwhoami: Can't contact LDAP server` | нет `-H` или LDAP не слушает | `ldapwhoami -x -H ldap://ldap-a.lab.test`; `systemctl status slapd-lab` |
| `ldapwhoami` вернул `...,cn=gssapi,cn=auth` без OU | не сработал `sasl-regexp` | проверьте `/etc/ldap/slapd.conf` (OpenLDAP 2.4 — `sasl-regexp`, не `authz-regexp`) |
| `verify`: `[WARN] NTP-источники недоступны` | изолированная сеть | не ошибка; сверьте часы вручную (< 5 мин) |
| `verify`: `[FAIL] время НЕ синхронизировано` | NTP есть, но не синхронизирован | `timedatectl`, `chronyc tracking`, перезапустите chrony |

Диагностика на сервере: `sudo ./scripts/astra-node-a-verify.sh` печатает хвост
журнала KDC и slapd при ошибках GSSAPI.

---

## Часть 6. Ограничения

* DNS в лаборатории нет: имена `*.lab.test` работают только через
  `/etc/hosts` (скрипты добавляют их сами).
* Один узел = один процесс `krb5kdc` с двумя realm'ами (`-r` для каждого);
  порты у обоих realm'ов общие (88).
* `kadmind` обслуживает только `ORG1.TEST` (администрирование `ORG2.TEST` —
  локально через `kadmin.local -r ORG2.TEST`).
* Keycloak в нативный узел не входит: только Kerberos и LDAP (+ Keycloak
  остаётся в Docker-лаборатории).
