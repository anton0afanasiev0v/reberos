# Kerberos + OpenLDAP (SASL/GSSAPI) + Apache на Astra Linux SE 1.7 (ALSE)

Инструкция для нативного развёртывания на Astra Linux Special Edition 1.7
(РУСБ.10015-01 об. 1.7) без Docker: KDC на MIT Kerberos (входит в ALSE),
клиенты, OpenLDAP с аутентификацией через GSSAPI и опциональный Apache
с SPNEGO. Основа — официальная статья
[wiki.astralinux.ru: Kerberos](https://wiki.astralinux.ru/display/doc/Kerberos)
(применима к 1.7); решения по GSSAPI-интеграции проверены на лаборатории
проекта (см. `docs/docker-lab.md`).

В примерах: домен `lab.example.ru`, сервер KDC `kdc.lab.example.ru`,
realm `LAB.EXAMPLE.RU`. Realm — домен заглавными буквами.

## 0. Требования

- Для всех участников: FQDN, работающие прямое и обратное разрешение имён
  (проверка: `nslookup kdc.lab.example.ru` и `nslookup <IP>`; пакет
  `dnsutils`), синхронизация времени (NTP) — при рассинхронизации аутентификация
  невозможна.
- В `krb5.conf` клиентов при необходимости отключается обратный поиск:
  `rdns = false`.
- Для лаборатории/домена без TLS-каталога потребуется
  `sasl-secprops minssf=0,maxssf=0` (см. раздел 3) — иначе slapd будет
  требовать слой шифрования.

## 1. Установка KDC

На сервере `kdc.lab.example.ru` (MIT Kerberos входит в состав ALSE):

```bash
sudo apt install krb5-kdc krb5-admin-server krb5-user
```

При установке предупреждение «пакет не настроен» можно проигнорировать —
настроим вручную.

### 1.1. Конфигурация `/etc/krb5kdc/kdc.conf`

```ini
[kdcdefaults]
    kdc_ports = 88,750

[realms]
    LAB.EXAMPLE.RU = {
        database_name = /var/lib/krb5kdc/principal
        admin_keytab = FILE:/etc/krb5kdc/kadm5.keytab
        acl_file = /etc/krb5kdc/kadm5.acl
        key_stash_file = /etc/krb5kdc/stash
        kdc_ports = 88,750
        max_life = 10h 0m 0s
        max_renewable_life = 7d 0h 0m 0s
        # aes256-cts (без суффикса :normal — с ним kdb5_util create падает
        # с "Program lacks support for key type")
        master_key_type = aes256-cts
        default_principal_flags = +preauth
    }
```

### 1.2. ACL администрирования `/etc/krb5kdc/kadm5.acl`

```
*/admin@LAB.EXAMPLE.RU *
```

### 1.3. Создание realm и администратора

```bash
sudo krb5_newrealm          # ввести и подтвердить мастер-пароль (stash)
sudo kadmin.local
kadmin.local: addprinc admin/admin
kadmin.local: quit
```

`kadmin.local` работает локально без пароля (защищённый сервер KDC);
для удалённого администрирования — `kadmin -p admin/admin` (порт 749).

Проверка:

```bash
sudo systemctl enable --now krb5-kdc kadmind
sudo kadmin.local -q listprincs
```

### 1.4. Сервисные принципалы и keytabs

Имена сервисных принципалов **регистрозависимы**. Конвенция SPNEGO/Apache —
заглавный `HTTP`; для OpenLDAP — строчный `ldap`:

```bash
sudo kadmin.local
# для slapd (на сервере каталога):
kadmin.local: addprinc -randkey ldap/ldap.lab.example.ru
kadmin.local: ktadd -k /etc/krb5.keytab ldap/ldap.lab.example.ru
# для Apache (на веб-сервере):
kadmin.local: addprinc -randkey HTTP/web.lab.example.ru
kadmin.local: ktadd -k /etc/krb5.keytab HTTP/web.lab.example.ru
```

Keytab выписывается на нужном сервере (или переносится осторожно:
`scp`, права 640, владелец — пользователь сервиса).

## 2. Клиенты Kerberos

На клиентских рабочих станциях:

```bash
sudo apt install krb5-user
sudo dpkg-reconfigure krb5-config   # домен (lab.example.ru), realm, серверы KDC
```

Если DNS настроен со SRV-записями, можно отвечать «нет» на предложение
вписать серверы вручную. Результат `/etc/krb5.conf` — секции `[realms]`
с `kdc = kdc.lab.example.ru` и `[domain_realm]` для `.lab.example.ru`.

Проверка:

```bash
kinit alice          # или kinit admin/admin
klist
kdestroy
```

Для аутентификации пользователей в ОС через Kerberos дополнительно:
`sudo apt install libpam-krb5` (модули добавятся в PAM автоматически).

## 3. OpenLDAP с аутентификацией через GSSAPI

На сервере каталога `ldap.lab.example.ru`:

```bash
sudo apt install slapd ldap-utils sasl2-bin libsasl2-modules-gssapi-mit
```

Ответ на вопрос о настройке slapd при установке можно пока пропустить —
далее используется классический `slapd.conf` (в Astra 1.7 / OpenLDAP 2.4
он поддерживается напрямую; для cn=config конвертируется командой
`slaptest -f /etc/ldap/slapd.conf -F /etc/ldap/slapd.d`).

### 3.1. Базовые секции `/etc/ldap/slapd.conf`

```
include         /etc/ldap/schema/core.schema
include         /etc/ldap/schema/cosine.schema
include         /etc/ldap/schema/inetorgperson.schema

pidfile         /run/slapd/slapd.pid
argsfile        /run/slapd/slapd.args

modulepath      /usr/lib/ldap
moduleload      back_mdb        # в OpenLDAP 2.4 модуль может называться back-bdb/back-mdb

# Лаборатория без TLS: иначе GSSAPI-привязка падает требованием SSF
sasl-secprops   minssf=0,maxssf=0

# Маппинг Kerberos-принципала в LDAP-DN (ГЛОБАЛЬНАЯ секция — до database).
# GSSAPI даёт authc-DN uid=<user>[@REALM],cn=gssapi,cn=auth.
# В OpenLDAP 2.5+ (Debian 12) директива называется authz-regexp;
# в 2.4 используется имя sasl-regexp (тот же синтаксис). Проверять фактом:
#   ldapwhoami -Y GSSAPI  должен вернуть dn:uid=alice,ou=people,dc=lab,dc=example,ru
sasl-regexp     uid=([^,]+)@[^,]+,cn=gssapi,cn=auth uid=$1,ou=people,dc=lab,dc=example,ru
sasl-regexp     uid=([^,]+),cn=gssapi,cn=auth uid=$1,ou=people,dc=lab,dc=example,ru

database        mdb
suffix          "dc=lab,dc=example,ru"
rootdn          "cn=admin,dc=lab,dc=example,ru"
rootpw          <хеш: slappasswd -s 'пароль'>
directory       /var/lib/ldap

index           objectClass eq,pres
index           uid         eq,pres,sub

access to attrs=userPassword
    by anonymous auth
    by self write
    by dn="cn=admin,dc=lab,dc=example,ru" write
    by * none
access to dn.base=""
    by * read
access to *
    by dn="cn=admin,dc=lab,dc=example,ru" write
    by self write
    by users read
    by anonymous none
```

### 3.2. Keytab и запуск

Keytab `ldap/ldap.lab.example.ru` должен лежать там, куда смотрит slapd.
Проще всего — `/etc/krb5.keytab` и переменная окружения сервиса
(`/etc/default/slapd`):

```
SLAPD_SERVICES="ldap:/// ldapi:///"
SLAPD_URLS="ldap:/// ldapi:///"
export KRB5_KTNAME=FILE:/etc/krb5.keytab
```

(в файле `/etc/default/slapd` добавить строку `KRB5_KTNAME=...`;
владелец keytab — `openldap:openldap`, права 640).

```bash
sudo systemctl enable --now slapd
sudo systemctl restart slapd
```

### 3.3. Наполнение и проверка

```bash
sudo ldapadd -x -D "cn=admin,dc=lab,dc=example,ru" -W -f seed.ldif   # база ou=people + alice
kinit alice
ldapwhoami -Y GSSAPI -H ldap://ldap.lab.example.ru
# ожидается: dn:uid=alice,ou=people,dc=lab,dc=example,ru
ldapsearch -Y GSSAPI -H ldap://ldap.lab.example.ru -b dc=lab,dc=example,ru '(uid=alice)' dn
kdestroy
ldapsearch -Y GSSAPI -H ldap://ldap.lab.example.ru -b dc=lab,dc=example,ru
# ожидается отказ: нет Kerberos-билета
```

Если `ldapwhoami` возвращает `dn:uid=alice,cn=gssapi,cn=auth` —
`authz-regexp`/`sasl-regexp` не сработал (см. примечания в разделе 3.1).

## 4. Apache с SPNEGO (опционально)

На веб-сервере `web.lab.example.ru`:

```bash
sudo apt install apache2 libapache2-mod-auth-gssapi
sudo a2enmod auth_gssapi    # обычно включается пакетом автоматически
```

`/etc/apache2/sites-available/kerberos.conf`:

```apache
<VirtualHost *:80>
    ServerName web.lab.example.ru

    AuthType GSSAPI
    AuthName "LAB.EXAMPLE.RU"
    GssapiCredStore keytab:/etc/krb5.keytab
    Require valid-user

    DocumentRoot /var/www/html
</VirtualHost>
```

```bash
sudo a2ensite kerberos.conf && sudo systemctl reload apache2
```

Проверка с клиента (нужен билет `kinit alice`):

```bash
# в Debian/Ubuntu curl часто собран без GSS-API (без --negotiate);
# годится любой SPNEGO-клиент, например python3-requests-kerberos:
python3 -c "import requests; from requests_kerberos import HTTPKerberosAuth, OPTIONAL; \
r = requests.get('http://web.lab.example.ru/', auth=HTTPKerberosAuth(mutual_authentication=OPTIONAL)); \
print(r.status_code)"
```

Без билета — HTTP 401, с билетом — 200.

## 5. Диагностика

```bash
sudo journalctl -u krb5-kdc -u kadmind        # логи KDC
sudo journalctl -u slapd                       # логи slapd
grep -n "sasl-regexp\|authz-regexp" /etc/ldap/slapd.conf
sudo kadmin.local -q listprincs
sudo klist -k /etc/krb5.keytab                 # состав keytab
```

Частые причины сбоев (проверены на лаборатории):

- маппинг не применяется → в 2.5+ нужна `authz-regexp`, в 2.4 —
  `sasl-regexp`, обе — до блока `database`;
- `Server HTTP/... not found in Kerberos database` → проверить регистр
  принципала в keytab (`HTTP` vs `http`);
- отказ GSSAPI «как будто нет KDC» → в krb5.conf
  `dns_lookup_kdc = false` + явные `kdc =` в `[realms]`, либо SRV-записи;
- падение `kdb5_util create` с `lacks support for key type` → убрать
  суффикс `:normal` у `master_key_type`;
- рассинхронизация часов → аутентификация «не валидный билет».

## Ссылки

- [docs/astra-node-a.md](astra-node-a.md) — готовый «Узел А» на Astra 1.7:
  один `krb5kdc` с **двумя** realm'ами (две организации, кросс-реалмовое
  доверие) + OpenLDAP GSSAPI с изоляцией `ou=orgN`; скрипты установки,
  проверки и полного удаления.
- [Kerberos (wiki.astralinux.ru)](https://wiki.astralinux.ru/display/doc/Kerberos) —
  установка и базовая настройка Kerberos в Astra Linux (статья применима
  к SE 1.7 и 1.8).
- [Интернет-репозитории SE](https://wiki.astralinux.ru/pages/viewpage.action?pageId=158598882) —
  подключение репозиториев для `apt install`.
- [Логи Kerberos](https://wiki.astralinux.ru/pages/viewpage.action?pageId=48763491).
- [Apache2 и GSSAPI](https://wiki.astralinux.ru/pages/viewpage.action?pageId=1212514).
- OpenLDAP Admin Guide, §15 «Using SASL» (mapping identities, authz-regexp).
