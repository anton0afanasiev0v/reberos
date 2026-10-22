# Узел А на Astra Linux SE 1.7 — Kerberos (2 организации) + OpenLDAP

Нативная (без Docker) установка MIT Kerberos и OpenLDAP на «Узле А» с двумя
организациями: один процесс `krb5kdc` обслуживает **два realm'а**
(`ORG1.TEST` и `ORG2.TEST`), каталог OpenLDAP изолирует организации по
веткам `ou=org1` / `ou=org2`.

Материалы репозитория:

| Файл | Назначение |
|---|---|
| `deploy/astra-node-a.env` | параметры (домен, realm'ы, пути, пароли) |
| `scripts/astra-node-a.sh` | идемпотентная настройка узла |
| `scripts/astra-node-a-verify.sh` | проверки после установки (56+) |
| `scripts/astra-node-a-client.sh` | настройка локального ПК как клиента |
| `scripts/astra-node-a-remove.sh` | полное удаление (откат) |
| `ldap/slapd.conf.tpl`, `ldap/seed.ldif.tpl` | шаблоны каталога (общие с лабораторией) |

Пошаговая инструкция «сервер + клиент + пользование» —
[astra-node-a-quickstart.md](astra-node-a-quickstart.md).

Связь с лабораторией Docker: конфигурация каталога берётся из тех же шаблонов
`ldap/slapd.conf.tpl` и `ldap/seed.ldif.tpl`, поэтому поведение (изоляция
организаций, маппинг принципалов, GSSAPI) совпадает с проверками
`scripts/verify.sh` в лаборатории.

---

## 1. Требования и подготовка

* Astra Linux SE 1.7 (Орёл), установленная система с доступом root.
* Подключённые репозитории Astra (без них `apt install` не найдёт
  `krb5-kdc`/`slapd`; порядок — по
  [wiki.astralinux.ru: интернет-репозитории](https://wiki.astralinux.ru/pages/viewpage.action?pageId=158598882)).
  Работает и DVD-репозиторий установочного диска (`cdrom://a1710_1`,
  `cdrom://a1710_2`) — с него ставятся `krb5-kdc`, `slapd`, `ldap-utils`.
* Открытые порты: `88/udp+tcp` (KDC), `749/tcp` (kadmind), `389/tcp` (LDAP).
* Время синхронизировано (Kerberos терпим к расхождению часов ~5 минут).
* Имена узлов — в `/etc/hosts` (или в DNS). Каждому сервису — **свой
  loopback-адрес** (это важно для GSSAPI, см. п. 10):

  ```
  127.0.0.2  ldap-a.lab.test
  127.0.0.3  kdc-a1.lab.test
  127.0.0.4  kdc-a2.lab.test
  ```

  Скрипт сам переписывает управляемый блок в `/etc/hosts` (маркеры
  `# BEGIN/END reberos astra-node-a`), заменяя в том числе старую запись
  `127.0.0.1 ... # reberos astra-node-a`. Отключить: `--no-hosts` — тогда
  только напечатает нужные строки.
* На узле достаточно каталогов `scripts/` и `deploy/`: шаблоны каталога лежат
  в `scripts/templates/`. Каталог `ldap/` (эталонные шаблоны лаборатории)
  не обязателен — при его наличии скрипт берёт шаблоны оттуда.

  ```bash
  git clone <репозиторий> /opt/reberos && cd /opt/reberos
  # или скопировать только scripts/ и deploy/
  ```

  Сверить встроенные шаблоны с эталонными: `./scripts/astra-node-a.sh --check-templates`.

### 1.1 Режимы защиты Astra (ЗПС/МКЦ)

В Astra 1.7 переключение режима делается **командой с числовым уровнем**,
а не отдельными флагами:

```bash
astra-modeswitch list          # 0 base(orel) / 1 advanced(voronezh) / 2 maximum(smolensk)
astra-modeswitch set 0         # базовый уровень: ЗПС/МКЦ/МРД выключены
```

После `set 0` **нужна перезагрузка**. МКЦ отдельно:
`sudo astra-mic-control disable` (тоже перезагрузка).

Скрипт **сам эти режимы не меняет** — только печатает текущее состояние и
напоминает команды (переключение требует перезагрузки, поэтому делать это
автоматически нельзя). Если установка пакетов не проходит, переключите
уровень вручную либо запустите скрипт с `--switch-base-level`
(сделает `astra-modeswitch set 0` и попросит перезагрузиться).

Вернуть уровень: `scripts/astra-node-a-remove.sh --restore-level 1`
(с последующей перезагрузкой).

---

## 2. Установка

На узле нужен каталог с `scripts/` и `deploy/` (шаблоны лежат в
`scripts/templates/`). Обновляем скрипты и ставим:

```bash
sudo chmod 600 deploy/astra-node-a.env      # там пароли
sudo ./scripts/astra-node-a.sh --dry-run     # посмотреть, что будет сделано
sudo ./scripts/astra-node-a.sh               # установить
sudo ./scripts/astra-node-a-verify.sh        # проверить
```

Скрипт идемпотентен: повторный запуск не пересоздаёт базы, принципалы и записи
каталога, а только догоняет изменения (в том числе после неудачного прогона —
например, если slapd не смог занять порт 389).

Полезные флаги:

| Флаг | Смысл |
|---|---|
| `--only kdc` | только Kerberos (KDC, БД, принципалы, keytab) |
| `--only ldap` | только каталог (slapd.conf, unit, seed) |
| `--dry-run` | печатать действия, ничего не менять |
| `--force` | разрешить работу не на Astra Linux |
| `--skip-packages` | не трогать пакеты (уже установлены) |
| `--rewrite-keytab` | перевыпустить keytab каталога |
| `--switch-base-level` | выполнить `astra-modeswitch set 0` (нужна перезагрузка) |
| `--check-templates` | сверить `ldap/*.tpl` и `scripts/templates/*.tpl` (root не нужен) |
| `--no-hosts` | не править `/etc/hosts` (напечатать нужные строки) |
| `--sync-passwords` | выставить пароли существующих принципалов по `deploy/astra-node-a.env` (полезно, если БД осталась от прошлых запусков: `kinit` падает с `Preauthentication failed`) |
| `--env FILE` | другой файл параметров |

### 2.1 Что делает скрипт

1. **Пакеты**: ставятся **только недостающие** (`krb5-kdc krb5-admin-server
   krb5-user slapd ldap-utils libsasl2-modules-gssapi-mit libpam-krb5`,
   необязательно `sasl2-bin`). Если всё уже установлено — `apt` вообще не
   трогается. Пресейд `debconf` задаёт `admin_realm`/`default_realm` =
   `ORG1.TEST`, чтобы `postinst` не перезаписал наш `/etc/krb5.conf`
   (мы пишем его ПОСЛЕ установки пакетов).
   Демон времени (`chrony`) не ставится, если уже есть `ntp`/`chrony`/
   `systemd-timesyncd` — `chrony` конфликтует с `time-daemon` (и apt удалил бы
   `ntp`). Вернуть `ntp` вручную: `apt-get install ntp`.

2. **Каталоги и права**: `/var/lib/krb5kdc` (realm A), `/var/lib/krb5kdc-ORG2`
   (realm B) — `root:krb5kdc`, `0700`; `/var/lib/ldap`, `/run/slapd` —
   `openldap:openldap`.
3. **`/etc/krb5.conf`**: `default_realm = ORG1.TEST`, оба realm'а в `[realms]`,
   `[capaths]` с прямым переходом `ORG1.TEST ⇄ ORG2.TEST` (точка), без DNS.
   Файл обслуживает и KDC, и локальных клиентов (`kinit`, `ldapwhoami`, `kvno`).
4. **`/etc/krb5kdc/kdc.conf`**: два realm'а в одном процессе. У каждого —
   **своя** `database_name`, `key_stash_file`, `acl_file`, `admin_keytab`.
   `krb5kdc` без `-r` обслуживает **только `default_realm`** из `krb5.conf`,
   поэтому скрипт пишет в `/etc/default/krb5-kdc`
   `DAEMON_ARGS="-r ORG1.TEST -r ORG2.TEST"` — иначе `kinit` во втором realm
   получает `Client not found`, хотя принципал есть в его базе.
   Дополнительно юнит `krb5-kdc` в Astra запускается с `ReadOnlyDirectories=/`
   и белым списком `ReadWriteDirectories`; скрипт добавляет drop-in
   `/etc/systemd/system/krb5-kdc.service.d/10-reberos-rw.conf` с каталогами
   обеих БД и `/var/log` (без него не пишется `/var/log/krb5kdc.log`) и делает
   `daemon-reload`.
5. **Базы**: `kdb5_util -r <realm> create -s -P <master>` — по одной на realm.
   `master_key_type = aes256-cts` (без суффикса `:normal`, иначе `create`
   падает с *«Program lacks support for key type»*).
6. **Принципалы**: `admin/admin`, `alice`, `admin` в каждом realm'е; пользователи
   организаций (список общий для обоих realm'ов); служебный SPN
   `ldap/ldap-a.lab.test` — **только** в `ORG1.TEST` (паритет с `kdc-a2`
   лаборатории: во втором realm'е сервисных принципалов нет).
7. **Кросс-реалмовое доверие**: оба имени — `krbtgt/ORG2.TEST@ORG1.TEST` и
   `krbtgt/ORG1.TEST@ORG2.TEST` — лежат в **обеих** базах с **общим** ключом
   (общий пароль; у `krbtgt`-принципалов нет соли, поэтому ключи совпадают).
   Это не «перестраховка»: KDC ищет TGT по имени его сервера
   (`krbtgt/<куда>@<кто выдал>`) в собственной базе — выдавший realm шифрует
   билет, принимающий расшифровывает тем же именем. Если положить только
   «своё» имя (как советуют примеры для двух отдельных KDC), принимающая
   сторона отвечает `UNKNOWN SERVER: server='krbtgt/A@B'` и `kinit`/`kvno` в
   чужой сервис падают с `Server not found`. Требование preauth снято
   (`modprinc -requires_preauth` в терминах man kadmin — флаг *очищается*).
   Если kvno ключей разошлись (базы пересоздавались по отдельности) — имя
   пересоздаётся автоматически.
8. **keytab каталога**: `ktadd -k /etc/krb5.keytab ldap/ldap-a.lab.test`,
   права `root:openldap 0640` (slapd работает от пользователя `openldap`).
   Второй принципал под именем машины не нужен: имя сервиса берётся из
   `/etc/hosts` (см. п. 10).
 9. **`/etc/ldap/slapd.conf`**: рендерится из шаблона `slapd.conf.tpl`
    (приоритет `ldap/slapd.conf.tpl`, иначе встроенная копия
    `scripts/templates/slapd.conf.tpl` — единый источник правды с лабораторией).
    Для OpenLDAP **2.4** (Astra 1.7) директива называется `sasl-regexp` —
    скрипт переписывает `authz-regexp` → `sasl-regexp`; в 2.5+ нужно оставить
    `authz-regexp`.
 10. **unit `slapd-lab.service`**: `slapd -d 0 -f /etc/ldap/slapd.conf` с
     `KRB5_KTNAME=FILE:/etc/krb5.keytab` (как в лаборатории — конфиг slapd.conf,
     а не cn=config). Перед стартом скрипт останавливает **штатный**
     `slapd.service` дистрибутива и проверяет, что порт 389 освободился: если
     процесс-владелец остался (SysV-скрипт часто переживает `systemctl stop`),
     он гасится по PID. Чужой не-slapd процесс на 389 скрипт не трогает —
     останавливает с понятной ошибкой и PID/командной строкой. Иначе наш slapd
     падает с `bind(7) failed errno=98`. GSSAPI на одном узле идёт по loopback,
     и Cyrus SASL подставляет в SPN имя, полученное **обратным резолвом**
     peer'а. Если все имена свалены на `127.0.0.1`, обратный резолв даёт
     `localhost`, SASL заменяет его `gethostname()` — и клиент просит билет на
     `ldap/<hostname>@realm`, которого нет. Поэтому `ldap-a.lab.test` получает
     отдельный адрес `127.0.0.2`: клиент и акцептор независимо приходят к SPN
     `ldap/ldap-a.lab.test`. В `slapd.conf` при этом обязателен
     `sasl-host ldap-a.lab.test`: без него **акцептор** (slapd) берёт
     `gethostname()` (`a1710-sofit-138025`), ищет в keytab
     `ldap/<hostname>` и роняет GSSAPI-bind с
     `No key table entry found matching ldap/a1710-...` — даже когда клиент
     просит правильный `ldap/ldap-a.lab.test`. Флаг `-d 0` обязателен: без него slapd
     уходит в фон, systemd теряет главный процесс, а `KillMode=control-group`
     убивает демона (симптом — «restart counter is at N» и `bind(7) errno=98`
     от осиротевших экземпляров).
 11. **Наполнение каталога**: `seed.ldif.tpl` + записи `uid=orgNuserM`
     (ветку задаёт префикс логина) и `uid=admin,ou=admins`.

### 2.2 Маппинг принципалов → ветки каталога

Правила в `slapd.conf` (порядок важен, realmless-форма — последняя):

```
sasl-regexp uid=([^,]+)@<ORG1>,cn=gssapi,cn=auth  uid=$1,ou=org1,ou=people,dc=lab,dc=test
sasl-regexp uid=([^,]+)@<ORG2>,cn=gssapi,cn=auth  uid=$1,ou=org2,ou=people,dc=lab,dc=test
sasl-regexp uid=([^,]+),cn=gssapi,cn=auth        uid=$1,ou=org1,ou=people,dc=lab,dc=test
```

* Realm задаёт **организацию** (ORG1 → `ou=org1`, ORG2 → `ou=org2`).
* Регистр realm'а в правилах неважен: `[Oo][Rr][Gg]2[.][Tt][Ee][Ss][Tt]` —
  POSIX ERE в slapd не знает `(?i)`, а cross-realm приходит с realm в нижнем
  регистре (`uid=user@org2.test`).
* Домашний realm приходит **без** realm (`uid=alice`), поэтому правило без
  realm стоит последним и ведёт в ветку домашнего realm'а.

---

## 3. Проверка

```bash
sudo ./scripts/astra-node-a-verify.sh
```

Скрипт ничего не меняет, только проверяет:

1. сервисы `krb5-kdc`, `krb5-admin-server`, `slapd-lab.service` активны;
2. слушают `88/udp`, `88/tcp`, `749/tcp`, `389/tcp`;
3. в `krb5.conf` есть оба realm'а и `[capaths]`, на месте обе БД KDC;
4. принципалы: `admin/admin`, `alice`, `admin`, `ldap/ldap-a.lab.test` в
   `ORG1.TEST`; `admin/admin`, `alice`, `admin` в `ORG2.TEST`; кросс-реалмовые
   `krbtgt` в обеих базах; **негатив** — SPN каталога отсутствует в `ORG2.TEST`;
5. `kinit`: `admin/admin@ORG1.TEST`, `alice@ORG1.TEST`, `admin@ORG1.TEST`,
   `org1user1@ORG1.TEST`, `org2user1@ORG2.TEST`;
6. GSSAPI в LDAP: `org1user1` → `ou=org1`, `org2user1@ORG2.TEST` (cross-realm) →
   `ou=org2`, `admin` → `ou=admins`, `alice` → `ou=org1`;
7. изоляция: `org1user1` не видит `ou=org2`, `org2user1` не видит `ou=org1`;
8. **негатив**: `kvno ldap/ldap-a.lab.test@ORG2.TEST` → *«not found in Kerberos
   database»* (сервиса нет во втором realm'е), `kvno ...@ORG3.TEST` → *«krbtgt/
   ORG3.TEST@ORG1.TEST not found»* (доверия к чужому realm нет) — знание SPN
   само по себе не даёт билет;
9. keytab: содержит SPN каталога, права `root:openldap 640`;
10. время синхронизировано (NTP).

Ручная проверка:

```bash
kinit alice@ORG1.TEST
ldapwhoami -Y GSSAPI -Q -H ldap://ldap-a.lab.test
kvno ldap/ldap-a.lab.test
klist -k /etc/krb5.keytab
```

### 3.1 Если проверки не проходят

| Симптом | Причина | Что делать |
|---|---|---|
| `daemon: bind(7) failed errno=98 (Address already in use)` | порт 389 держит чужой slapd (штатный `slapd.service`, часто SysV-процесс, переживающий `systemctl stop`) | скрипт останавливает штатный slapd и, если порт всё ещё занят его процессом, гасит по PID; если держит **не slapd** — `ss -lntp 'sport = :389'` и остановите владельца вручную |
| `не удалось получить хеш ... (slappasswd/python3)` | нет ни `slappasswd`, ни `python3` | установите `slapd` (в нём `slappasswd`) или `python3`; скрипт сам считает `{SSHA}` на python3, если `slappasswd` не читает пароль из stdin |
| `порт 389 всё ещё занят — остановите владельца` | на 389 слушает не slapd (например, 389-ds) | скрипт чужое не убивает: определите PID из вывода и остановите вручную |
| `restart counter is at N` + `bind(7) errno=98` | unit без `-d 0`: slapd демонизируется, systemd убивает форк, осиротевшие экземпляры держат порт | просто перезапустите скрипт — он перепишет unit с `-d 0`, сделает `reset-failed` и убьёт свои осиротевшие процессы |
| `Current command vanished from the unit file` | unit переписан при активном цикле рестартов | скрипт делает `systemctl stop` + `reset-failed` перед стартом; повторный запуск чинит |
| `kinit ... Preauthentication failed` | принципал уже был создан с другим паролем (env поменялся) | `sudo ./scripts/astra-node-a.sh --sync-passwords` |
| GSSAPI в LDAP не проходит, в журнале `Server ldap/<hostname>@realm not found in Kerberos database` | имена сервисов в `/etc/hosts` привязаны к `127.0.0.1`, обратный резолв даёт `localhost`, Cyrus SASL подставляет имя машины | перезапустите скрипт: он перепишет `/etc/hosts` на `127.0.0.2+` (проверка у verify — «Имена и окружение»); вручную: `getent hosts ldap-a.lab.test` не должен давать `127.0.0.1` |
| GSSAPI в LDAP не проходит, в выводе `Invalid credentials (49)` | `sasl-regexp` не совпал с authc-DN | verify печатает вывод `ldapwhoami` и журнал `slapd-lab` — смотрите их |
| `ldap_bind: Invalid credentials (49)` при `ldapadd` | на 389 отвечает не наш slapd (или не совпал `rootpw`) | `ss -lntp 'sport = :389'` — должен быть наш `slapd -f /etc/ldap/slapd.conf`; сверьте `LDAP_ADMIN_PASSWORD` в env с `rootpw` в `/etc/ldap/slapd.conf` |
| `sed: невозможно прочитать ldap/slapd.conf.tpl` | на узле нет каталога `ldap/` | скопируйте `scripts/templates/` (или весь `scripts/`), проверка: `./scripts/astra-node-a.sh --check-templates` |
| `apt-get install` падает на `chrony`/`time-daemon` | конфликт `chrony` и `ntp` | скрипт не ставит `chrony`, если демон времени уже есть; вручную `apt-get install ntp` для возврата `ntp` |
| `krb5-kdc.service` не стартует сразу после установки пакета | БД KDC ещё не созданы | `sudo ./scripts/astra-node-a.sh` (пересоздаст БД и перезапустит службу) |
| `Client not found in Kerberos database` / `GET_LOCAL_TGT` для `user@REALM_B`, хотя `getprinc` его показывает | `krb5kdc` не перечислен второй realm: без `-r` он обслуживает только `default_realm` (так же молча ведёт себя и без записи в каталог БД) | проверьте `DAEMON_ARGS` в `/etc/default/krb5-kdc` (`-r ORG1.TEST -r ORG2.TEST`) и drop-in с RW-каталогами; скрипт пишет и то и другое, затем `kinit` в оба realm'а |
| `No such object` в `ldapwhoami` | не сработал `sasl-regexp` (правило не совпало) | `journalctl -u slapd-lab -n 50`, проверить realm в правиле и регистр |
| `Clock skew too large` | рассинхрон времени | `chronyc makestep`, `timedatectl set-ntp true` |
| `Cannot find KDC for realm` | нет имени KDC в `/etc/hosts`/DNS | `getent hosts kdc-a1.lab.test` |
| `GSSAPI: No credentials were supplied` | не сделан `kinit` или ccache не тот | `klist` / `KRB5CCNAME=FILE:/tmp/krb5cc_0` |
| cross-realm не проходит | разошлись kvno кросс-реалмовых ключей | перезапустить `scripts/astra-node-a.sh` (пересоздаст пару) |

---

## 4. Клиент на локальном ПК

`scripts/astra-node-a-client.sh` настраивает **клиент** (ноутбук/ПК), а не
узел: прописывает имена в `/etc/hosts`, пишет `/etc/krb5.conf` с обоими
realm'ами и `[capaths]`, затем проверяет `kinit` → `kvno` → `ldapwhoami`
(включая кросс-реалм).

```bash
sudo apt install krb5-user ldap-utils libsasl2-modules-gssapi-mit

./scripts/astra-node-a-client.sh --check                  # без sudo, только проверки
sudo ./scripts/astra-node-a-client.sh --server 172.16.138.25
sudo ./scripts/astra-node-a-client.sh --dry-run           # показать, что будет записано
sudo ./scripts/astra-node-a-client.sh --uninstall         # откат
```

Что делает:

1. `/etc/hosts` — управляемый блок `# BEGIN/END reberos astra-client`:
   `172.16.138.25 ldap-a.lab.test kdc-a1.lab.test kdc-a2.lab.test`
   (имя узла — из `--server` или `NODE_IP` в `deploy/astra-node-a.env`).
2. `/etc/krb5.conf` — с бэкапом `krb5.conf.reberos-backup-<дата>`:
   `default_realm=ORG1.TEST`, `rdns=false`, `dns_canonicalize_hostname=false`,
   `kdc = kdc-a1.lab.test` / `kdc-a2.lab.test`, `[domain_realm]` и `[capaths]`.
3. Сквозная проверка: `alice@ORG1.TEST` (LDAP → `ou=org1`), затем
   `org2user1@ORG2.TEST` (кросс-реалм → `ou=org2`). Пароли берутся из
   env-файла, иначе `kinit` спросит интерактивно.

`--uninstall` убирает блок из `/etc/hosts` и возвращает прежний
`/etc/krb5.conf` из бэкапа (если бэкапа нет — переименовывает сгенерированный
в `krb5.conf.reberos-removed-<дата>`). Пакеты не удаляются.

Типичные клиентские ошибки:

| Симптом | Причина | Что делать |
|---|---|---|
| `Cannot contact any KDC` | нет имён в `/etc/hosts` или порт 88 закрыт | `getent hosts kdc-a1.lab.test`; `./scripts/astra-node-a-client.sh --check` |
| `Clock skew too great` | часы ПК и узла разошлись > 5 мин | сверьте `date -u`; на узле NTP может отсутствовать (WARN в verify) |
| `Server ldap/...@ORG1.TEST not found` | не настроен кросс-реалм | перезапустите на узле `./scripts/astra-node-a.sh --only kdc` (создаст оба `krbtgt`-имени в обеих БД) |
| `No key table entry found matching ldap/<hostname>` | у slapd нет `sasl-host` | на узле в `/etc/ldap/slapd.conf` нужна строка `sasl-host ldap-a.lab.test` |
| `Preauthentication failed` | пароль в env не совпадает с БД | на узле `./scripts/astra-node-a.sh --sync-passwords --only kdc` |

---

## 5. Удаление (откат)

```bash
sudo ./scripts/astra-node-a-remove.sh --dry-run   # посмотреть план
sudo ./scripts/astra-node-a-remove.sh             # с подтверждением
```

Скрипт останавливает и отключает сервисы, удаляет unit `slapd-lab.service`,
keytab, `/etc/krb5.conf`, `kdc.conf`, `kadm5*.acl`, stash'и, `slapd.conf`,
**обе базы KDC и данные каталога**. Заодно вычищаются остатки Keycloak от
прежних версий установщика (`/opt/keycloak*`, `/var/lib/keycloak`,
`/etc/keycloak`, пользователь `keycloak`). Перед удалением конфиги копируются
в `/root/astra-node-a-backup-<дата>`.

Флаги:

| Флаг | Смысл |
|---|---|
| `--keep-data` | не удалять базы KDC и данные LDAP |
| `--purge-packages` | дополнительно удалить пакеты (`apt-get purge`); `ntp` после этого возвращается вручную: `apt-get install ntp` |
| `--restore-level N` | вернуть уровень защищённости (`astra-modeswitch set N`) + перезагрузка |
| `--restore-modes` | показать текущий уровень и подсказать команду восстановления |
| `--yes` | без подтверждения (для автоматизации) |

Штатный `slapd.service` дистрибутива скрипт тоже отключает (наша установка
его останавливала) — вернуть: `systemctl enable --now slapd.service`.

Файлы репозитория (`deploy/astra-node-a.env`, `scripts/astra-node-a*.sh`,
`docs/astra-node-a.md`) скрипт не трогает.

---

## 6. Отличия от лаборатории (Docker)

| | Лаборатория | Нативный узел |
|---|---|---|
| KDC | контейнеры `kdc-a1`/`kdc-a2` (по realm'y) | один `krb5kdc` с двумя realm'ами |
| Базы | тома Docker | `/var/lib/krb5kdc`, `/var/lib/krb5kdc-ORG2` |
| Каталог | контейнер `ldap-a`, `slapd -f` | тот же конфиг, `slapd-lab.service` |
| keytab | `KV5_KTNAME` в контейнере | `KRB5_KTNAME` в unit-файле |
| Правила каталога | `authz-regexp` (OpenLDAP 2.5) | `sasl-regexp` (OpenLDAP 2.4) |
| Apache | есть (SPNEGO) | нет |
| Keycloak | контейнер `keycloak-a` | нет (в объёме узла только Kerberos + LDAP) |
