#!/bin/bash
# Нативная настройка «Узла А» на Astra Linux SE 1.7 (БЕЗ Docker):
#   - MIT Kerberos: два realm'а (две организации) в одном процессе krb5kdc,
#     у каждого realm своя БД, свой stash и свой kadm5.acl;
#   - кросс-реалмовое доверие между realm'ами (общий ключ в обе стороны);
#   - OpenLDAP: GSSAPI-аутентификация + изоляция организаций
#     (sasl-regexp/authz-regexp по realm + ACL по ou=orgN);
#   - служебный принципал ldap/<host> и keytab для slapd;
#   - Keycloak (нативно, без Docker): Java + дистрибутив из vendor/, realm с
#     LDAP-федерацией на наш slapd, systemd-юнит.
#
# Идемпотентно: повторный запуск ничего не ломает; существующие БД, принципалы
# и записи каталога не пересоздаются.
#
#   sudo ./scripts/astra-node-a.sh                          # всё
#   sudo ./scripts/astra-node-a.sh --only kdc               # только KDC
#   sudo ./scripts/astra-node-a.sh --only ldap              # только каталог
#   sudo ./scripts/astra-node-a.sh --only keycloak          # только Keycloak
#   sudo ./scripts/astra-node-a.sh --dry-run                # печать, без изменений
#   sudo ./scripts/astra-node-a.sh --force                  # разрешить не-Astra
#   sudo ./scripts/astra-node-a.sh --switch-base-level      # astra-modeswitch set 0 (нужна перезагрузка)
#   sudo ./scripts/astra-node-a.sh --check-templates        # сверка шаблонов (ldap/ vs scripts/templates/)
#   sudo ./scripts/astra-node-a.sh --skip-keycloak          # без Keycloak
#   sudo ./scripts/astra-node-a.sh --no-hosts               # не править /etc/hosts
#   sudo ./scripts/astra-node-a.sh --sync-passwords         # выставить пароли по env-файлу
#
# На узле достаточно scripts/ + deploy/ + vendor/: шаблоны лежат в scripts/templates/,
# дистрибутивы Keycloak/JRE — в vendor/ (интернета на узле нет).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="deploy/astra-node-a.env"
ONLY="all"
DRY_RUN=0
FORCE=0
SKIP_PACKAGES=0
REWRITE_KEYTAB=0
SWITCH_BASE=0
CHECK_TEMPLATES=0
SKIP_KEYCLOAK=0
NO_HOSTS=0
SYNC_PASSWORDS=0

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --env)              ENV_FILE="$2"; shift 2 ;;
        --only)             ONLY="$2"; shift 2 ;;
        --dry-run)          DRY_RUN=1; shift ;;
        --force)            FORCE=1; shift ;;
        --skip-packages)    SKIP_PACKAGES=1; shift ;;
        --rewrite-keytab)   REWRITE_KEYTAB=1; shift ;;
        --switch-base-level) SWITCH_BASE=1; shift ;;
        --check-templates)  CHECK_TEMPLATES=1; shift ;;
        --skip-keycloak)    SKIP_KEYCLOAK=1; shift ;;
        --no-hosts)         NO_HOSTS=1; shift ;;
        --sync-passwords)   SYNC_PASSWORDS=1; shift ;;
        -h|--help)          usage 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; usage 1 ;;
    esac
done

[ -f "$ENV_FILE" ] || { echo "НЕТ ФАЙЛА ПАРАМЕТРОВ: $ENV_FILE" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

log()  { echo "[astra-node-a] $*"; }
warn() { echo "[astra-node-a] ВНИМАНИЕ: $*" >&2; }
die()  { echo "[astra-node-a] ОШИБКА: $*" >&2; exit 1; }

# Выполнить команду (или только напечатать её в --dry-run).
run() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "    \$ $*"
    else
        eval "$*"
    fi
}

need_root() {
    [ "$(id -u)" = "0" ] || die "нужны права root (запускайте через sudo)"
}

# --- проверка ОС: Astra Linux (иначе нужен --force) ---
check_os() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}${NAME:-}${PRETTY_NAME:-}" in
            *Astra*|*astra*) log "ОС: ${PRETTY_NAME:-$NAME}" ;;
            *) if [ "$FORCE" = "0" ]; then
                   die "это не Astra Linux (${PRETTY_NAME:-$NAME}); для проверки используйте --force"
               fi
               warn "ОС ${PRETTY_NAME:-$NAME} не Astra Linux — продолжаю из-за --force" ;;
        esac
    fi
}

# --- шаблоны каталога: репозиторий (если рядом) → встроенная копия ---
# На узле нужен только scripts/ (в нём scripts/templates/) + deploy/.
tpl_file() {
    # tpl_file <имя файла> — путь к шаблону или пустая строка
    local name="$1" p
    for p in "$SCRIPT_DIR/../ldap/$name" "$SCRIPT_DIR/templates/$name"; do
        if [ -f "$p" ]; then printf '%s' "$p"; return 0; fi
    done
    return 1
}

check_templates() {
    # Сверяем встроенные копии с шаблонами лаборатории (если репозиторий рядом).
    local rc=0 name a b
    for name in slapd.conf.tpl seed.ldif.tpl realm-node.json.tpl; do
        case "$name" in
            realm-node.json.tpl) a="$SCRIPT_DIR/../keycloak/$name" ;;
            *)                  a="$SCRIPT_DIR/../ldap/$name" ;;
        esac
        b="$SCRIPT_DIR/templates/$name"
        if [ ! -f "$a" ]; then
            echo "  $name: шаблона лаборатории нет — сверка пропущена"
            continue
        fi
        if [ ! -f "$b" ]; then
            echo "  $name: НЕТ встроенной копии (scripts/templates/$name)"
            rc=1
            continue
        fi
        if diff -q "$a" "$b" >/dev/null 2>&1; then
            echo "  $name: совпадает"
        else
            echo "  $name: РАСХОЖДЕНИЕ:"
            diff -u "$a" "$b" | sed 's/^/    /'
            rc=1
        fi
    done
    return $rc
}

# --- режимы защиты Astra (ЗПС/МКЦ) ---
# Интерфейс Astra 1.7: astra-modeswitch <list|get|getname|set> [<value>]
#   set 0 — переключить ОС на базовый уровень защищённости (ЗПС/МКЦ/МРД выкл.),
#           требуется ПЕРЕЗАГРУЗКА;
#   МКЦ отдельно: astra-mic-control disable (тоже перезагрузка).
astra_modes_state() {
    if command -v astra-modeswitch >/dev/null 2>&1; then
        local out
        out="$(astra-modeswitch list 2>&1 || true)"
        if [ -n "$out" ]; then
            echo "$out" | sed 's/^/    /'
        fi
    fi
    return 0
}

switch_base_level() {
    if [ "$SWITCH_BASE" != "1" ]; then
        log "режимы ЗПС/МКЦ не трогаю (текущее состояние):"
        astra_modes_state
        warn "если установка пакетов не проходит, выполните вручную:"
        warn "  sudo astra-modeswitch set 0        # базовый уровень защищённости, затем ПЕРЕЗАГРУЗИТЬ"
        warn "  sudo astra-mic-control disable     # только МКЦ, тоже нужна перезагрузка"
        return 0
    fi
    command -v astra-modeswitch >/dev/null 2>&1 || { warn "astra-modeswitch не найден"; return 0; }
    log "переключаю ОС на базовый уровень защищённости (astra-modeswitch set 0)"
    warn "после этого нужна ПЕРЕЗАГРУЗКА: sudo reboot"
    run "astra-modeswitch set 0 || true"
}

# --- пакеты ---
# Критичные: без них узел не работает.
PKG_CRITICAL="krb5-kdc krb5-admin-server krb5-user slapd ldap-utils libsasl2-modules-gssapi-mit libpam-krb5"
# Необязательные: их отсутствие не мешает работе.
PKG_OPTIONAL="sasl2-bin"

time_daemon_present() {
    local p
    for p in ntp chrony systemd-timesyncd openntpd; do
        if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed"; then
            return 0
        fi
    done
    return 1
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

apt_diagnostics() {
    log "диагностика apt:"
    echo "  --- репозитории ---"
    grep -rhsE '^(deb|cdrom)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
        | sed 's/^/    /' || true
    echo "  --- apt-get check ---"
    apt-get check 2>&1 | head -20 | sed 's/^/    /' || true
}

apt_install_one() {
    # apt_install_one <пакет> — ставит пакет; ошибка не роняет скрипт
    local p="$1" out st
    if [ "$DRY_RUN" = "1" ]; then
        echo "    \$ apt-get install -y --no-install-recommends $p"
        return 0
    fi
    out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$p" 2>&1)" && st=0 || st=$?
    if [ "$st" = "0" ]; then
        log "  $p — установлен"
        return 0
    fi
    warn "  $p — НЕ установлен (код $st)"
    echo "$out" | tail -6 | sed 's/^/      /' >&2
    return 1
}

ensure_time_daemon() {
    # chrony конфликтует с time-daemon (как и ntp). Если демон времени уже есть —
    # не трогаем (иначе apt удалит ntp).
    if time_daemon_present; then
        log "демон времени уже установлен — chrony не ставлю (конфликт с time-daemon)"
    else
        log "ставлю chrony (синхронизация времени)"
        apt_install_one chrony || warn "  chrony не установлен — проверьте время вручную (timedatectl)"
    fi
}

install_packages() {
    if [ "$SKIP_PACKAGES" = "1" ]; then
        log "пакеты пропущены (--skip-packages)"
        return 0
    fi

    # Что уже стоит? Если всё на месте — apt вообще не трогаем.
    local p missing="" missing_opt=""
    for p in $PKG_CRITICAL; do
        package_installed "$p" || missing="$missing $p"
    done
    for p in $PKG_OPTIONAL; do
        package_installed "$p" || missing_opt="$missing_opt $p"
    done

    if [ -z "$missing" ] && [ -z "$missing_opt" ]; then
        log "все нужные пакеты уже установлены — apt не трогаю"
        ensure_time_daemon
        return 0
    fi

    if [ -z "$missing" ]; then
        log "критичные пакеты на месте; ставлю необязательные:$missing_opt"
        for p in $missing_opt; do
            apt_install_one "$p" || warn "  необязательный пакет $p пропущен"
        done
        ensure_time_daemon
        return 0
    fi

    log "устанавливаю недостающие критичные пакеты:$missing"
    # Пресейд debconf: иначе postinst krb5-kdc/krb5-user задаст вопросы и
    # перезапишет /etc/krb5.conf (наши конфиги пишемся ПОСЛЕ установки).
    printf 'krb5-kdc shared/admin_realm string %s\nkrb5-user shared/default_realm string %s\n' \
        "$REALM_A" "$REALM_A" | debconf-set-selections || true

    log "обновляю индексы пакетов (apt-get update)"
    run "DEBIAN_FRONTEND=noninteractive apt-get update -qq || true"

    # Если состояние системы сломано (частая история на Astra) — чиним.
    if ! apt-get check >/dev/null 2>&1; then
        warn "apt-get check сообщает о проблемах — запускаю apt-get -f install"
        run "DEBIAN_FRONTEND=noninteractive apt-get -f install -y || true"
    fi

    local failed=""
    for p in $missing; do
        apt_install_one "$p" || failed="$failed $p"
    done
    if [ -n "$failed" ]; then
        apt_diagnostics
        die "не установлены критичные пакеты:$failed (см. диагностику выше — нужен репозиторий с этими библиотеками)"
    fi

    for p in $missing_opt; do
        apt_install_one "$p" || warn "  необязательный пакет $p пропущен"
    done

    ensure_time_daemon
}

# --- каталоги и права ---
make_dirs() {
    log "каталоги и права"
    run "mkdir -p '$KDC_CONF_DIR' '$KDC_DB_DIR_A' '$KDC_DB_DIR_B' '$SLAPD_DATA' '$SLAPD_RUN'"
    run "chown root:krb5kdc '$KDC_DB_DIR_A' '$KDC_DB_DIR_B' 2>/dev/null || chown root:root '$KDC_DB_DIR_A' '$KDC_DB_DIR_B'"
    run "chmod 0700 '$KDC_DB_DIR_A' '$KDC_DB_DIR_B'"
    run "chown openldap:openldap '$SLAPD_DATA' '$SLAPD_RUN'"
}

# --- /etc/krb5.conf (и сервер, и клиент на этом хосте) ---
write_krb5_conf() {
    log "пишу $KRB5_CONF"
    if [ "$DRY_RUN" = "1" ]; then
        echo "    (содержимое $KRB5_CONF: realm $REALM_A / $REALM_B, capaths через '.' )"
        return 0
    fi
    cat > "$KRB5_CONF" <<EOF
# Сгенерировано scripts/astra-node-a.sh (нативный Узел А, Astra Linux 1.7).
# Обслуживает и сам KDC, и локальные клиенты (ldapwhoami, kvno, kinit).
[libdefaults]
    default_realm = $REALM_A
    dns_lookup_realm = false
    dns_lookup_kdc = false
    rdns = false
    dns_canonicalize_hostname = false
    forwardable = true
    ticket_lifetime = 10h
    renew_lifetime = 7d

[realms]
    $REALM_A = {
        kdc = $KDC_A_HOST
        admin_server = $KDC_A_HOST
    }
    $REALM_B = {
        kdc = $KDC_B_HOST
        admin_server = $KDC_B_HOST
    }

[domain_realm]
    .$DOMAIN = $REALM_A
    $DOMAIN = $REALM_A

# Прямое доверие между двумя организациями узла (без посредников).
[capaths]
    $REALM_A = {
        $REALM_B = .
    }
    $REALM_B = {
        $REALM_A = .
    }

[logging]
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmind.log
EOF
    chmod 0644 "$KRB5_CONF"
}

# --- /etc/krb5kdc/kdc.conf: два realm'а с раздельными БД/stash/ACL ---
write_kdc_conf() {
    log "пишу $KDC_CONF_DIR/kdc.conf (два realm'а)"
    [ "$DRY_RUN" = "1" ] && return 0
    cat > "$KDC_CONF_DIR/kdc.conf" <<EOF
# Сгенерировано scripts/astra-node-a.sh.
# Два realm'а в одном процессе krb5kdc. ВАЖНО: у каждого realm своя БД
# (database_name) и свой stash — иначе realm'и слились бы в одну базу и
# кросс-реалмовое доверие стало бы не нужно.

[kdcdefaults]
    kdc_ports = 750,88
    kdc_tcp_ports = 88

[realms]
    $REALM_A = {
        database_name = $KDC_DB_DIR_A/principal
        key_stash_file = $KDC_CONF_DIR/stash
        acl_file = $KDC_CONF_DIR/kadm5.acl
        admin_keytab = FILE:$KDC_CONF_DIR/kadm5.keytab
        kdc_ports = 750,88
        kdc_tcp_ports = 88
        max_life = 10h 0m 0s
        max_renewable_life = 7d 0h 0m 0s
        # aes256-cts БЕЗ суффикса :normal — иначе kdb5_util create падает
        # с "Program lacks support for key type".
        master_key_type = aes256-cts
        default_principal_flags = +preauth
    }
    $REALM_B = {
        database_name = $KDC_DB_DIR_B/principal
        key_stash_file = $KDC_CONF_DIR/stash-$REALM_B
        acl_file = $KDC_CONF_DIR/kadm5-$REALM_B.acl
        admin_keytab = FILE:$KDC_CONF_DIR/kadm5-$REALM_B.keytab
        kdc_ports = 750,88
        kdc_tcp_ports = 88
        max_life = 10h 0m 0s
        max_renewable_life = 7d 0h 0m 0s
        master_key_type = aes256-cts
        default_principal_flags = +preauth
    }
EOF
    chmod 0644 "$KDC_CONF_DIR/kdc.conf"

    # ACL администрирования: полные права у */admin@REALM своего realm'а.
    printf '*/admin@%s *\n' "$REALM_A" > "$KDC_CONF_DIR/kadm5.acl"
    printf '*/admin@%s *\n' "$REALM_B" > "$KDC_CONF_DIR/kadm5-$REALM_B.acl"
    chmod 0644 "$KDC_CONF_DIR/kadm5.acl" "$KDC_CONF_DIR/kadm5-$REALM_B.acl"

    write_kdc_daemon_args
}

write_kdc_daemon_args() {
    # krb5kdc без -r обслуживает ТОЛЬКО default_realm из krb5.conf; realm'ы
    # надо перечислить явно (до 32). Иначе kinit во второй realm получает
    # "Client not found", хотя принципал есть в его БД.
    local f=/etc/default/krb5-kdc
    log "realm'ы KDC ($f): $REALM_A $REALM_B"
    if [ "$DRY_RUN" = "1" ]; then
        echo "    DAEMON_ARGS=\"-r $REALM_A -r $REALM_B\""
        return 0
    fi
    mkdir -p "$(dirname "$f")"
    printf '# Сгенерировано scripts/astra-node-a.sh.\n# krb5kdc без -r обслуживает только default_realm.\nDAEMON_ARGS="-r %s -r %s"\n' \
        "$REALM_A" "$REALM_B" > "$f"
}

# --- базы данных KDC (по одной на realm) ---
create_databases() {
    log "базы данных KDC"
    if [ ! -f "$KDC_DB_DIR_A/principal" ]; then
        log "создаю БД realm $REALM_A"
        run "kdb5_util -r '$REALM_A' create -s -P '$KDC_MASTER_KEY'"
    else
        log "БД $REALM_A уже есть — не трогаю"
    fi
    if [ ! -f "$KDC_DB_DIR_B/principal" ]; then
        log "создаю БД realm $REALM_B"
        run "kdb5_util -r '$REALM_B' create -s -P '$KDC_MASTER_KEY'"
    else
        log "БД $REALM_B уже есть — не трогаю"
    fi
}

# --- принципалы ---
kadm() {
    local realm="$1"; shift
    kadmin.local -r "$realm" -q "$*" 2>&1
}

princip_exists() {
    # Всегда полное имя: иначе kadmin может разрешить его в realm по умолчанию
    # (ORG1.TEST) и «найти» принципал не в той базе.
    local realm="$1" p="$2"
    case "$p" in *@*) ;; *) p="$p@$realm" ;; esac
    kadm "$realm" "getprinc $p" | grep -q "^Principal:"
}

ensure_princ_pw() {
    # ensure_princ_pw <realm> <principal> <password>
    local realm="$1" princ="$2" pw="$3" shown
    case "$princ" in *@*) shown="$princ" ;; *) shown="$princ@$realm"; princ="$princ@$realm" ;; esac
    if [ "$DRY_RUN" = "1" ]; then
        echo "    kadmin.local -r $realm -q \"addprinc -pw ... $princ\" (если нет)"
        return 0
    fi
    if princip_exists "$realm" "$princ"; then
        if [ "$SYNC_PASSWORDS" = "1" ]; then
            kadm "$realm" "cpw -pw $pw $princ" >/dev/null
            log "  $shown — пароль синхронизирован с env"
        else
            log "  $shown — уже есть"
        fi
    else
        kadm "$realm" "addprinc -pw $pw $princ" >/dev/null
        log "  создан $shown"
    fi
}

ensure_princ_randkey() {
    # ensure_princ_randkey <realm> <spn>
    local realm="$1" spn="$2" shown
    case "$spn" in *@*) shown="$spn" ;; *) shown="$spn@$realm"; spn="$spn@$realm" ;; esac
    if [ "$DRY_RUN" = "1" ]; then
        echo "    kadmin.local -r $realm -q \"addprinc -randkey $spn\" (если нет)"
        return 0
    fi
    if princip_exists "$realm" "$spn"; then
        log "  $shown — уже есть"
    else
        kadm "$realm" "addprinc -randkey $spn" >/dev/null
        log "  создан $shown"
    fi
}

create_principals() {
    log "принципалы realm $REALM_A"
    ensure_princ_pw "$REALM_A" "admin/admin" "$ADMIN_PASSWORD"
    ensure_princ_pw "$REALM_A" "alice" "$ALICE_PASSWORD"
    ensure_princ_pw "$REALM_A" "admin" "$NODE_ADMIN_PASSWORD"
    # Служебный принципал каталога — только в домашнем realm'е узла.
    ensure_princ_randkey "$REALM_A" "$LDAP_SPN"

    log "принципалы realm $REALM_B (сервисных нет — паритет с kdc-a2 в лаборатории)"
    ensure_princ_pw "$REALM_B" "admin/admin" "$ADMIN_PASSWORD"
    ensure_princ_pw "$REALM_B" "alice" "$ALICE_PASSWORD"
    ensure_princ_pw "$REALM_B" "admin" "$NODE_ADMIN_PASSWORD"

    log "пользователи организаций (список общий для обоих realm'ов)"
    local pair u p
    for pair in $ORG_USER_PASSWORDS; do
        u="${pair%%=*}"; p="${pair#*=}"
        [ -n "$u" ] && [ "$u" != "$p" ] || die "плохая пара логин=пароль: '$pair'"
        ensure_princ_pw "$REALM_A" "$u" "$p"
        ensure_princ_pw "$REALM_B" "$u" "$p"
    done
}

# --- кросс-реалмовое доверие (обе стороны, один и тот же ключ) ---
kvno_of() {
    # kvno_of <realm> <principal>
    kadm "$1" "getprinc $2" | awk '/^Key: vno/ {gsub(",", "", $3); print $3; exit}'
}

create_cross_realm() {
    log "кросс-реалмовое доверие $REALM_A <-> $REALM_B"
    # KDC ищет TGT по имени его сервера (krbtgt/<куда>@<кто выдал>) в СВОЕЙ
    # базе: выдавший realm хранит ключ, чтобы выпустить билет, принимающий —
    # чтобы расшифровать. Поэтому каждое из двух имён должно быть в ОБЕИХ
    # базах, с одинаковым ключом (одинаковый пароль + отсутствие соли у
    # krbtgt-принципалов дают одинаковый ключ).
    if [ "$DRY_RUN" = "1" ]; then
        echo "    addprinc krbtgt/$REALM_B@$REALM_A и krbtgt/$REALM_A@$REALM_B в $REALM_A и $REALM_B"
        echo "    modprinc -requires_preauth krbtgt/... (в обоих realm'ах)"
        return 0
    fi
    ensure_cross_pair "krbtgt/$REALM_B@$REALM_A"
    ensure_cross_pair "krbtgt/$REALM_A@$REALM_B"
    log "  preauth снят с кросс-реалмовых ключей (иначе их нельзя отключить по-сервисно)"
}

ensure_cross_pair() {
    # ensure_cross_pair <principal>: одно и то же имя в обеих базах.
    local name="$1" ka kb
    ka="$(kvno_of "$REALM_A" "$name")"
    kb="$(kvno_of "$REALM_B" "$name")"
    if [ -n "$ka" ] && [ -n "$kb" ] && [ "$ka" != "$kb" ]; then
        warn "kvno $name расходятся ($ka в $REALM_A vs $kb в $REALM_B) — пересоздаю"
        kadm "$REALM_A" "delprinc -force $name" >/dev/null || true
        kadm "$REALM_B" "delprinc -force $name" >/dev/null || true
    fi
    ensure_princ_pw "$REALM_A" "$name" "$CROSS_REALM_KEY"
    ensure_princ_pw "$REALM_B" "$name" "$CROSS_REALM_KEY"
    # -requires_preauth СНИМАЕТ требование preauth (man kadmin: "-requires_preauth
    # clears this flag") — для кросс-реалмовых ключей preauth не нужен.
    kadm "$REALM_A" "modprinc -requires_preauth $name" >/dev/null || true
    kadm "$REALM_B" "modprinc -requires_preauth $name" >/dev/null || true
}

# --- keytab для slapd ---
write_keytab() {
    log "keytab $KEYTAB"
    if [ "$DRY_RUN" = "1" ]; then
        echo "    ktadd -k $KEYTAB $LDAP_SPN"
        return 0
    fi
    local have=0
    if [ -f "$KEYTAB" ]; then
        klist -k "$KEYTAB" 2>/dev/null | grep -q "$LDAP_SPN" && have=1
    fi
    if [ "$have" = "1" ] && [ "$REWRITE_KEYTAB" = "0" ]; then
        log "  $LDAP_SPN в keytab уже есть — не перевыпускаю (--rewrite-keytab чтобы обновить)"
        return 0
    fi
    if [ "$have" = "1" ]; then
        log "  перевыпускаю keytab (--rewrite-keytab)"
        rm -f "$KEYTAB"
    fi
    kadm "$REALM_A" "ktadd -k $KEYTAB $LDAP_SPN" >/dev/null
    chown root:openldap "$KEYTAB"
    chmod 0640 "$KEYTAB"
    log "  состав: $(klist -k "$KEYTAB" | awk 'NR>2 {print $2}' | sort -u | tr '\n' ' ')"
}

# --- LDAP: конфиг из шаблона репозитория (единый источник правды) ---
dc_base_of() {
    # dc=lab,dc=test из DOMAIN=lab.test
    printf '%s' "$DOMAIN" | awk -F. '{printf "dc=%s", $1; for(i=2;i<=NF;i++) printf ",dc=%s", $i}'
}

re_ci_realm() {
    # Точка -> [.], буквы -> [Xx] (POSIX ERE в slapd не знает (?i), а
    # cross-realm приходит с realm в нижнем регистре).
    printf '%s' "$1" | sed 's/\./[.]/g' \
        | sed 's/[A-Za-z]/[&]/g' \
        | sed 'y/abcdefghijklmnopqrstuvwxyz/ABCDEFGHIJKLMNOPQRSTUVWXYZ/' \
        | sed 's/\[\([A-Z]\)\]/[\1\L\1]/g'
}

write_slapd_conf() {
    local tpl
    tpl="$(tpl_file slapd.conf.tpl)" || die "не найден шаблон slapd.conf.tpl (ищем ldap/ и scripts/templates/)"
    local root_hash alice_hash
    root_hash="$(hash_password_or_die "rootdn (LDAP_ADMIN_PASSWORD)" "$LDAP_ADMIN_PASSWORD")"
    alice_hash="$(hash_password_or_die "alice (ALICE_PASSWORD)" "$ALICE_PASSWORD")"
    log "пишу $SLAPD_CONF (шаблон: $tpl)"
    [ "$DRY_RUN" = "1" ] && return 0
    local pri_re sec_re
    pri_re="$(re_ci_realm "$REALM_A")"
    sec_re="$(re_ci_realm "$REALM_B")"
    local dc_base
    dc_base="$(dc_base_of)"
    # OpenLDAP 2.4 (Astra 1.7): директива называется sasl-regexp (в 2.5+ — authz-regexp).
    sed -e "s|\${DC_BASE}|$dc_base|g" \
        -e "s|\${LDAP_OU_PRIMARY}|$LDAP_OU_PRIMARY|g" \
        -e "s|\${LDAP_OU_SECONDARY}|$LDAP_OU_SECONDARY|g" \
        -e "s|\${REALM_PRI_RE}|$pri_re|g" \
        -e "s|\${REALM_SEC_RE}|$sec_re|g" \
        -e "s|\${ROOTPW_HASH}|$root_hash|g" \
        -e "s|\${ALICE_HASH}|$alice_hash|g" \
        -e "s|^authz-regexp|sasl-regexp|" \
        -e "s|^# Директива именно authz-regexp.*|# Директива sasl-regexp (OpenLDAP 2.4 / Astra 1.7); в 2.5+ — authz-regexp.|" \
        "$tpl" > "$SLAPD_CONF"
    # ou=admins в шаблоне задан литералом — подставим из параметров.
    sed -i "s|ou=admins|ou=$LDAP_OU_ADMINS|g" "$SLAPD_CONF"
    # Акцептору GSSAPI нужно ровно то имя, которое просит клиент. Без
    # sasl-host Cyrus SASL берёт gethostname() (a1710-...) и ищет в keytab
    # ldap/<hostname>, а клиент просит ldap/ldap-a.lab.test -> bind падает.
    awk -v host="$LDAP_HOST" '
        BEGIN { done = 0 }
        !done && /^[[:space:]]*(sasl-secprops|database)[[:space:]]/ {
            print "sasl-host       " host; done = 1
        }
        { print }
    ' "$SLAPD_CONF" > "$SLAPD_CONF.tmp" && mv "$SLAPD_CONF.tmp" "$SLAPD_CONF"
    chown root:openldap "$SLAPD_CONF"
    chmod 0640 "$SLAPD_CONF"
    # Проверка конфига: битый slapd.conf сразу роняет скрипт.
    local out st
    out="$(slaptest -f "$SLAPD_CONF" 2>&1)" && st=0 || st=$?
    log "  slaptest: $(echo "$out" | tail -3 | tr '\n' ' ')"
    [ "$st" = "0" ] || die "slapd.conf не проходит проверку slaptest — смотри вывод выше"
}

write_slapd_unit() {
    log "unit $SLAPD_UNIT (slapd -d 0 -f, как в лаборатории)"
    [ "$DRY_RUN" = "1" ] && return 0
    mkdir -p "$SYSTEMD_UNIT_DIR"
    cat > "$SYSTEMD_UNIT_DIR/$SLAPD_UNIT" <<EOF
[Unit]
Description=OpenLDAP (reberos, нативный Узел А)
After=network-online.target krb5-kdc.service
Wants=network-online.target

[Service]
Type=simple
# keytab каталога: ldap/$LDAP_HOST из realm $REALM_A
Environment=KRB5_KTNAME=FILE:$KEYTAB
# -d 0: не уходить в фон (иначе systemd теряет процесс, а KillMode убивает демона)
ExecStart=/usr/sbin/slapd -d 0 -f $SLAPD_CONF -h "ldap:/// ldapi:///" -u openldap -g openldap
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# --- наполнение каталога ---
write_seed() {
    local seed=/tmp/astra-seed.ldif dc_base tpl
    tpl="$(tpl_file seed.ldif.tpl)" || die "не найден шаблон seed.ldif.tpl (ищем ldap/ и scripts/templates/)"
    dc_base="$(dc_base_of)"
    log "наполнение каталога ($dc_base), шаблон: $tpl"
    [ "$DRY_RUN" = "1" ] && return 0
    local alice_hash
    alice_hash="$(hash_password_or_die "alice (ALICE_PASSWORD)" "$ALICE_PASSWORD")"
    sed -e "s|\${DC_BASE}|$dc_base|g" \
        -e "s|\${DC_FIRST}|${DOMAIN%%.*}|g" \
        -e "s|\${LDAP_OU_PRIMARY}|$LDAP_OU_PRIMARY|g" \
        -e "s|\${LDAP_OU_SECONDARY}|$LDAP_OU_SECONDARY|g" \
        -e "s|\${ALICE_HASH}|$alice_hash|g" \
        "$tpl" > "$seed"

    # Записи пользователей организаций: ветку задаёт префикс логина.
    local pair u p ou hash
    for pair in $ORG_USER_PASSWORDS; do
        u="${pair%%=*}"; p="${pair#*=}"
        ou=""
        local o
        for o in $ORG_OUS; do
            case "$u" in "$o"*) ou="$o"; break ;; esac
        done
        [ -n "$ou" ] || die "логин '$u' не начинается ни с одной org ($ORG_OUS)"
        hash="$(hash_password_or_die "пользователя $u" "$p")"
        cat >> "$seed" <<EOF

dn: uid=$u,ou=$ou,ou=people,$dc_base
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: $u
cn: $u
sn: $u
userPassword: $hash
EOF
    done
    # Админ узла.
    local admin_hash
    admin_hash="$(hash_password_or_die "админа узла (NODE_ADMIN_PASSWORD)" "$NODE_ADMIN_PASSWORD")"
    cat >> "$seed" <<EOF

dn: uid=admin,ou=$LDAP_OU_ADMINS,$dc_base
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: admin
cn: Admin Node
sn: Admin
userPassword: $admin_hash
EOF
    log "  seed готов: $seed"
}

seed_ldap() {
    local dc_base
    dc_base="$(dc_base_of)"
    if [ "$DRY_RUN" = "1" ]; then
        echo "    ldapadd -x -D cn=admin,$dc_base -f /tmp/astra-seed.ldif (если база пуста)"
        return 0
    fi
    # На 389 должен отвечать НАШ slapd (с $SLAPD_CONF), иначе bind пойдёт в чужой сервис.
    if ! slapd_is_ours; then
        report_port_389
        die "на 389 отвечает не наш slapd — seed пропущен, разберитесь с владельцем порта"
    fi
    if ! ldapwhoami -x -H ldap://127.0.0.1 -D "cn=admin,$dc_base" -w "$LDAP_ADMIN_PASSWORD" >/dev/null 2>&1; then
        die "bind rootdn не проходит: пароль в $SLAPD_CONF (rootpw) не совпадает с LDAP_ADMIN_PASSWORD в $ENV_FILE"
    fi
    if ldapsearch -x -H ldap://127.0.0.1 -D "cn=admin,$dc_base" -w "$LDAP_ADMIN_PASSWORD" \
        -b "uid=alice,ou=$LDAP_OU_PRIMARY,ou=people,$dc_base" -s base 1.1 >/dev/null 2>&1; then
        log "  база уже наполнена — не трогаю"
        return 0
    fi
    log "  загружаю seed"
    ldapadd -x -H ldap://127.0.0.1 -D "cn=admin,$dc_base" -w "$LDAP_ADMIN_PASSWORD" -f /tmp/astra-seed.ldif
}

# --- хеши паролей для slapd.conf ---
LAST_HASH_ERROR=""

hash_password() {
    # hash_password <пароль> — хеш {SSHA}.
    # На Astra 1.7 (OpenLDAP 2.4) slappasswd не всегда читает пароль из stdin,
    # поэтому пробуем: аргумент → stdin → собственный {SSHA} на python3.
    local pw="$1" h="" err=""
    LAST_HASH_ERROR=""
    [ -n "$pw" ] || { LAST_HASH_ERROR="пароль пуст"; return 1; }
    if command -v slappasswd >/dev/null 2>&1; then
        h="$(slappasswd -s "$pw" 2>/dev/null || true)"
        [ -n "$h" ] || h="$(printf '%s\n' "$pw" | slappasswd -s 2>/dev/null || true)"
        [ -n "$h" ] || err="slappasswd: $(slappasswd -s "$pw" 2>&1 >/dev/null | head -1)"
    else
        err="slappasswd не найден (пакет slapd)"
    fi
    if [ -z "$h" ] && command -v python3 >/dev/null 2>&1; then
        h="$(python3 - "$pw" <<'PY'
import base64, hashlib, os, sys
pw = sys.argv[1].encode()
salt = os.urandom(8)
print("{SSHA}" + base64.b64encode(hashlib.sha1(pw + salt).digest() + salt).decode())
PY
)"
        [ -n "$h" ] || err="$err; python3 не смог посчитать {SSHA}"
    fi
    if [ -z "$h" ]; then
        LAST_HASH_ERROR="${err:-нет ни slappasswd, ни python3}"
        return 1
    fi
    printf '%s' "$h"
}

hash_password_or_die() {
    # hash_password_or_die <кого> <пароль>
    local what="$1" pw="$2" h
    [ -n "$pw" ] || die "пустой пароль для $what — проверьте $ENV_FILE"
    h="$(hash_password "$pw")" || die "не удалось получить хеш для $what: $LAST_HASH_ERROR"
    printf '%s' "$h"
}

# --- диагностика порта 389 ---
is_foreign_slapd_cmd() {
    # is_foreign_slapd_cmd <cmdline> — штатный slapd (не наш и не ns-slapd/389-ds)
    case "$1" in
        /usr/sbin/slapd\ *|/usr/lib/slapd\ *|slapd\ *) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *"$SLAPD_CONF"*) return 1 ;;
    esac
    return 0
}

proc_cmdline() {
    # proc_cmdline <pid> — командная строка процесса; пусто, если процесс уже умер
    [ -r "/proc/$1/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || true
}

port_389_holders() {
    ss -lntpH 'sport = :389' 2>/dev/null || true
}

report_port_389() {
    local out pid
    out="$(port_389_holders)"
    if [ -n "$out" ]; then
        warn "порт 389 занят:"
        echo "$out" | sed 's/^/    /'
        for pid in $(echo "$out" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
            warn "  pid=$pid: $(proc_cmdline "$pid")"
        done
    else
        log "порт 389 свободен"
    fi
}

slapd_is_ours() {
    # Наш slapd запущен с -f $SLAPD_CONF и слушает 389?
    systemctl is-active --quiet "$SLAPD_UNIT" 2>/dev/null || return 1
    local out pid
    out="$(port_389_holders)"
    [ -n "$out" ] || return 1
    for pid in $(echo "$out" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
        if proc_cmdline "$pid" | grep -q -- "$SLAPD_CONF"; then
            return 0
        fi
    done
    return 1
}

# --- преflight: резолв имён и штатный slapd ---
check_names() {
    local h missing=""
    for h in "$KDC_A_HOST" "$KDC_B_HOST" "$LDAP_HOST"; do
        if ! getent hosts "$h" >/dev/null 2>&1; then missing="$missing $h"; fi
    done
    if [ -n "$missing" ]; then
        warn "имена не резолвятся:$missing — их пропишет fix_hosts (или добавьте вручную)"
    fi
}

hosts_block() {
    # Каждому сервису — свой loopback-адрес. Так обратный резолв peer'а даёт
    # ровно имя сервиса (ldap-a.lab.test), а не "localhost"/hostname машины.
    # Это нужно GSSAPI: Cyrus SASL иначе подставляет имя машины и клиент
    # просит билет ldap/<hostname>@realm.
    echo "# BEGIN reberos astra-node-a"
    echo "127.0.0.2  $LDAP_HOST"
    echo "127.0.0.3  $KDC_A_HOST"
    echo "127.0.0.4  $KDC_B_HOST"
    if [ "$SKIP_KEYCLOAK" != "1" ] && [ -n "${KEYCLOAK_HOST:-}" ]; then
        echo "127.0.0.5  $KEYCLOAK_HOST"
    fi
    echo "# END reberos astra-node-a"
}

fix_hosts() {
    # Идемпотентно заменяет управляемый блок в /etc/hosts.
    local block
    block="$(hosts_block)"
    if [ "$NO_HOSTS" = "1" ]; then
        warn "--no-hosts: в /etc/hosts должны быть строки:"
        printf '%s\n' "$block" | sed 's/^/[astra-node-a]   /' >&2
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log "обновил бы /etc/hosts:"
        printf '%s\n' "$block"
        return 0
    fi
    # Прошлый блок (и старая одиночная строка) удаляются, иначе имена
    # останутся привязанными к 127.0.0.1 и GSSAPI снова сломается.
    sed -i -E '/# BEGIN reberos astra-node-a/,/# END reberos astra-node-a/d' /etc/hosts
    sed -i -E '/# reberos astra-node-a$/d' /etc/hosts
    printf '%s\n' "$block" >> /etc/hosts
    log "прописал в /etc/hosts имена сервисов (loopback 127.0.0.2+)"
}

stop_distro_slapd() {
    # Штатный slapd дистрибутива (unit или SysV-скрипт) занимает порт 389 —
    # наш юнит не встанет. Гасим его и проверяем, что порт реально освободился:
    # SysV-процесс часто переживает `systemctl disable --now`.
    local found=0

    if [ "$DRY_RUN" != "1" ] && slapd_is_ours; then
        log "на 389 уже наш slapd ($SLAPD_UNIT) — штатный не трогаю"
        return 0
    fi

    if systemctl list-unit-files 2>/dev/null | grep -qE '^slapd\.service'; then found=1; fi
    if systemctl is-active --quiet slapd.service 2>/dev/null; then found=1; fi
    if [ -x /etc/init.d/slapd ]; then found=1; fi
    if [ "$found" = "1" ]; then
        log "штатный slapd найден — останавливаю и отключаю (он держит порт 389)"
        run "systemctl disable slapd.service || true"
        run "systemctl stop slapd.service || true"
        run "service slapd stop || true"
    else
        log "штатный slapd.service не обнаружен"
    fi

    if [ "$DRY_RUN" = "1" ]; then
        report_port_389
        return 0
    fi

    local i pid cmd
    for i in 1 2 3 4 5; do
        [ -n "$(port_389_holders)" ] || break
        sleep 1
    done

    # Если порт всё ещё держит slapd (не наш) — останавливаем его по PID.
    local killed=0
    for pid in $(port_389_holders | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
        cmd="$(proc_cmdline "$pid")"
        if is_foreign_slapd_cmd "$cmd"; then
            warn "останавливаю чужой slapd pid=$pid: $cmd"
            kill -TERM "$pid" 2>/dev/null || true
            killed=1
        fi
    done
    if [ "$killed" = "1" ]; then
        for i in 1 2 3; do
            [ -n "$(port_389_holders)" ] || break
            sleep 1
        done
        for pid in $(port_389_holders | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
            cmd="$(proc_cmdline "$pid")"
            if is_foreign_slapd_cmd "$cmd"; then
                warn "kill -9 pid=$pid"
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done
        sleep 1
    fi

    report_port_389
    if [ -n "$(port_389_holders)" ]; then
        die "порт 389 всё ещё занят — остановите владельца (pid/cmdline выше) и запустите снова"
    fi
}

# --- сервисы ---
restart_slapd_lab() {
    # Наш slapd: гасим осиротевшие процессы прошлых запусков (они держат 389),
    # сбрасываем счётчик рестартов и ждём, пока порт займёт именно наш slapd.
    local i
    run "systemctl stop $SLAPD_UNIT || true"
    if [ "$DRY_RUN" != "1" ]; then
        systemctl reset-failed "$SLAPD_UNIT" 2>/dev/null || true
        pkill -f "slapd.*-f $SLAPD_CONF" 2>/dev/null || true
        sleep 1
    fi
    run "systemctl start $SLAPD_UNIT || true"
    [ "$DRY_RUN" = "1" ] && return 0
    for i in $(seq 1 15); do
        slapd_is_ours && return 0
        sleep 1
    done
    return 1
}

# --- KDC действительно обслуживает ОБА realm'а (а не только первый из
# конфига, который был при прошлом старте) ---
check_kdc_realms() {
    [ "$DRY_RUN" = "1" ] && return 0
    local r cc i
    for r in "$REALM_A" "$REALM_B"; do
        cc="/tmp/astra-kinit-check.$$"
        i=0
        until kinit -c "$cc" "admin@$r" <<< "$NODE_ADMIN_PASSWORD" >/dev/null 2>&1; do
            i=$((i+1))
            if [ "$i" -ge 5 ]; then
                warn "kinit admin@$r не прошёл после перезапуска KDC — realm не обслуживается?"
                tail -n 10 /var/log/krb5kdc.log 2>/dev/null | sed 's/^/      /' >&2 || true
                break
            fi
            sleep 1
        done
        rm -f "$cc"
    done
}

# --- сандбокс systemd: юниты Astra держат / в ReadOnly и разрешают запись
# только в перечисленные каталоги. Вторую БД KDC (realm B) нужно добавить
# явно, иначе демон не может её открыть (BerkeleyDB требует запись) и realm
# молча не обслуживается: kinit -> "Client not found", kvno -> GET_LOCAL_TGT.
write_kdc_sandbox_override() {
    local unit="$1"
    case "$unit" in *.service) ;; *) unit="$unit.service" ;; esac
    local dir="/etc/systemd/system/$unit.d"
    local f="$dir/10-reberos-rw.conf"
    # Правим только если vendor-юнит действительно использует сандбокс.
    if ! systemctl cat "$unit" 2>/dev/null | grep -q '^ReadWriteDirectories='; then
        return 0
    fi
    log "drop-in для $unit: RW $KDC_DB_DIR_B (сандбокс systemd)"
    local content
    content="# Сгенерировано scripts/astra-node-a.sh.
# Пустой ReadWriteDirectories= сбрасывает список vendor-юнита; дальше — свой.
[Service]
ReadWriteDirectories=
ReadWriteDirectories=-/var/tmp /tmp $KDC_DB_DIR_A $KDC_DB_DIR_B -/var/run /run -/var/log"
    if [ "$DRY_RUN" = "1" ]; then
        echo "    $f:"
        printf '%s\n' "$content" | sed 's/^/      /'
        return 0
    fi
    mkdir -p "$dir"
    printf '%s\n' "$content" > "$f"
    systemctl daemon-reload
}

start_kdc() {
    # Drop-in'ы нужны до рестарта: иначе KDC не откроет БД realm B.
    local svc
    for svc in krb5-kdc krb5-admin-server; do
        write_kdc_sandbox_override "$svc"
    done
    for svc in krb5-kdc krb5-admin-server; do
        run "systemctl enable $svc || true"
        run "systemctl restart $svc || true"
        if [ "$DRY_RUN" != "1" ] && ! systemctl is-active --quiet "$svc"; then
            warn "служба $svc не поднялась — последние строки журнала:"
            journalctl -u "$svc" -n 30 --no-pager 2>&1 | sed 's/^/      /' >&2 || true
        fi
    done
    check_kdc_realms
}

enable_services() {
    log "включаю и перезапускаю slapd"
    run "systemctl enable $SLAPD_UNIT || true"
    if [ "$DRY_RUN" = "1" ]; then
        restart_slapd_lab
        return 0
    fi
    if ! restart_slapd_lab; then
        warn "служба $SLAPD_UNIT не поднялась — последние строки журнала:"
        journalctl -u "$SLAPD_UNIT" -n 30 --no-pager 2>&1 | sed 's/^/      /' >&2 || true
        report_port_389
        die "$SLAPD_UNIT не слушает 389 нашим конфигом ($SLAPD_CONF) — разберитесь с владельцем порта и запустите снова"
    fi
    log "slapd ($SLAPD_UNIT) слушает 389 с нашим конфигом ✓"
}

# ============================== Keycloak ==============================
# Нативная установка (без Docker): Java + дистрибутив из vendor/ + realm
# с LDAP-федерацией на наш slapd + systemd-юнит.
# На узле интернета нет, поэтому дистрибутивы берём из vendor/.

repo_path() {
    # repo_path <путь> — абсолютный путь (относительный — от корня репозитория)
    local p="$1"
    case "$p" in
        /*) printf '%s' "$p" ;;
        *)  printf '%s/%s' "$REPO_ROOT" "$p" ;;
    esac
}

java_major_version() {
    # java_major_version <путь к java> — мажорная версия или пусто
    local j="$1" v
    [ -x "$j" ] || return 0
    v="$("$j" -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')"
    printf '%s' "$v"
}

find_java_home() {
    # Ищем JAVA_HOME: сначала системный openjdk-17/21, потом JRE из vendor/
    local jh
    for jh in /usr/lib/jvm/java-17-openjdk-* /usr/lib/jvm/java-21-openjdk-* \
              /usr/lib/jvm/default-java /opt/keycloak-jre; do
        if [ -x "$jh/bin/java" ]; then printf '%s' "$jh"; return 0; fi
    done
    return 1
}

install_java() {
    # Keycloak 26 требует Java 17+. Сначала пробуем репозиторий Astra,
    # затем (если пакета нет) — офлайн-JRE из vendor/.
    local have major
    have="$(find_java_home)" || have=""
    if [ -n "$have" ]; then
        major="$(java_major_version "$have/bin/java")"
        if [ "${major:-0}" -ge 17 ] 2>/dev/null; then
            log "Java уже есть: $have (версия $major)"
            JAVA_HOME="$have"
            return 0
        fi
        warn "найдена Java $major в $have — Keycloak 26 требует 17+"
    fi

    log "ставлю Java 17 ($JAVA_PACKAGE)"
    if apt_install_one "$JAVA_PACKAGE"; then
        have="$(find_java_home)" || have=""
        if [ -n "$have" ]; then JAVA_HOME="$have"; log "  JAVA_HOME=$JAVA_HOME"; return 0; fi
    fi

    # Фолбэк: офлайн-JRE в vendor/
    local tarball
    tarball="$(repo_path "$JAVA_TARBALL")"
    if [ -f "$tarball" ]; then
        log "пакета $JAVA_PACKAGE нет — беру JRE из $JAVA_TARBALL"
        if [ "$DRY_RUN" = "1" ]; then
            echo "    tar xzf $tarball -C /opt && ln -sfn /opt/$(basename "$tarball" .tar.gz | sed 's/-jre$//') /opt/keycloak-jre"
            return 0
        fi
        mkdir -p /opt
        tar xzf "$tarball" -C /opt
        local d
        d="$(find /opt -maxdepth 1 -type d -name 'jdk-17*' | head -1)"
        [ -n "$d" ] || die "в $tarball не нашёл каталог jdk-17*"
        rm -rf /opt/keycloak-jre
        ln -sfn "$d" /opt/keycloak-jre
        JAVA_HOME=/opt/keycloak-jre
        log "  JAVA_HOME=$JAVA_HOME (оффлайн JRE)"
        return 0
    fi
    die "нет Java 17: пакет $JAVA_PACKAGE не устанавливается и нет офлайн-JRE $JAVA_TARBALL (положите temurin17-jre-x64-linux.tar.gz в vendor/)"
}

install_keycloak_dist() {
    # Дистрибутив Keycloak — только из vendor/ (на узле нет интернета).
    local tarball dir version_dir
    tarball="$(repo_path "$KEYCLOAK_TARBALL")"
    version_dir="$KEYCLOAK_HOME"
    [ -n "$KEYCLOAK_VERSION" ] && version_dir="$KEYCLOAK_HOME-$KEYCLOAK_VERSION"

    if [ -x "$KEYCLOAK_HOME/bin/kc.sh" ]; then
        log "Keycloak уже установлен: $KEYCLOAK_HOME"
        return 0
    fi
    if [ ! -f "$tarball" ]; then
        die "нет дистрибутива Keycloak: $tarball (интернет на узле нет — положите keycloak-$KEYCLOAK_VERSION.tar.gz в vendor/)"
    fi
    log "распаковываю Keycloak $KEYCLOAK_VERSION из $tarball"
    if [ "$DRY_RUN" = "1" ]; then
        echo "    tar xzf $tarball -C /opt && ln -sfn $version_dir $KEYCLOAK_HOME"
        return 0
    fi
    mkdir -p /opt
    rm -rf "$version_dir"
    tar xzf "$tarball" -C /opt
    [ -x "$version_dir/bin/kc.sh" ] || die "в $tarball нет keycloak-$KEYCLOAK_VERSION/bin/kc.sh"
    ln -sfn "$version_dir" "$KEYCLOAK_HOME"
    log "  $KEYCLOAK_HOME -> $version_dir"
}

fix_keycloak_ownership() {
    # kc.sh пишет в lib/quarkus и data/, а HOME=$KEYCLOAK_DATA_DIR может ещё не
    # существовать (useradd --home-dir его не создаёт). Иначе — AccessDenied на
    # transformed-bytecode.jar или отказ на $HOME.
    local ver_dir="$KEYCLOAK_HOME"
    [ -n "$KEYCLOAK_VERSION" ] && ver_dir="$KEYCLOAK_HOME-$KEYCLOAK_VERSION"
    run "install -d -m 0750 -o $KEYCLOAK_USER -g $KEYCLOAK_GROUP $KEYCLOAK_DATA_DIR"
    run "mkdir -p $KEYCLOAK_HOME/data && chown -R $KEYCLOAK_USER:$KEYCLOAK_GROUP $KEYCLOAK_HOME/data"
    run "chown -R $KEYCLOAK_USER:$KEYCLOAK_GROUP $ver_dir"
}

create_keycloak_user() {
    if id "$KEYCLOAK_USER" >/dev/null 2>&1; then
        log "пользователь $KEYCLOAK_USER уже есть"
        run "install -d -m 0750 -o $KEYCLOAK_USER -g $KEYCLOAK_GROUP $KEYCLOAK_DATA_DIR"
        return 0
    fi
    log "создаю системного пользователя $KEYCLOAK_USER"
    run "useradd --system --home-dir $KEYCLOAK_DATA_DIR --shell /usr/sbin/nologin $KEYCLOAK_USER"
    run "install -d -m 0750 -o $KEYCLOAK_USER -g $KEYCLOAK_GROUP $KEYCLOAK_DATA_DIR"
}

write_keycloak_env() {
    log "пишу $KEYCLOAK_ETC_DIR/keycloak.env"
    [ "$DRY_RUN" = "1" ] && return 0
    mkdir -p "$KEYCLOAK_ETC_DIR"
    cat > "$KEYCLOAK_ETC_DIR/keycloak.env" <<EOF
# Сгенерировано scripts/astra-node-a.sh (нативный Узел А, Astra Linux 1.7).
# Параметры Keycloak ${KEYCLOAK_VERSION} — как в Docker-лаборатории.
KC_BOOTSTRAP_ADMIN_USERNAME=$KEYCLOAK_ADMIN_USER
KC_BOOTSTRAP_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD"
KC_HTTP_ENABLED=true
# Keycloak 26 в dev-режиме по умолчанию слушает только localhost — для
# доступа с других ПК (браузер, Keycloak UI) нужен явный 0.0.0.0.
KC_HTTP_HOST=0.0.0.0
KC_HTTP_PORT=$KEYCLOAK_HTTP_PORT
KC_HTTP_RELATIVE_PATH=$KEYCLOAK_RELATIVE_PATH
KC_HOSTNAME_STRICT=false
KC_HEALTH_ENABLED=true
KC_METRICS_ENABLED=true
KC_METRICS_PORT=9000
KC_DB=dev-file
KC_HOME=$KEYCLOAK_HOME
JAVA_HOME=$JAVA_HOME
EOF
    chmod 0640 "$KEYCLOAK_ETC_DIR/keycloak.env"
    chown root:"$KEYCLOAK_GROUP" "$KEYCLOAK_ETC_DIR/keycloak.env" 2>/dev/null || true
}

write_keycloak_realm() {
    # Realm импортируется при старте из $KC_HOME/data/import/realm-node.json
    local tpl import_dir out
    tpl="$(tpl_file realm-node.json.tpl)" || die "не найден шаблон realm-node.json.tpl (ищем keycloak/ и scripts/templates/)"
    import_dir="$KEYCLOAK_HOME/data/import"
    out="$import_dir/realm-node.json"
    log "готовлю realm $KC_REALM ($out)"
    [ "$DRY_RUN" = "1" ] && return 0
    mkdir -p "$import_dir"
    sed -e "s|\${KC_REALM}|$KC_REALM|g" \
        -e "s|\${NODE_LABEL}|$KEYCLOAK_NODE_LABEL|g" \
        -e "s|\${DOMAIN}|$DOMAIN|g" \
        -e "s|\${WEB_HOST}|$WEB_HOST|g" \
        -e "s|\${PUBLIC_WEB_BASE}|$PUBLIC_WEB_BASE|g" \
        -e "s|\${LDAP_HOST}|$LDAP_HOST|g" \
        -e "s|\${LDAP_ADMIN_PASSWORD}|$LDAP_ADMIN_PASSWORD|g" \
        -e "s|\${DC_BASE}|$(dc_base_of)|g" \
        -e "s|\${CLIENT_SECRET}|$PORTAL_CLIENT_SECRET|g" \
        "$tpl" > "$out"
    chown -R "$KEYCLOAK_USER":"$KEYCLOAK_GROUP" "$KEYCLOAK_HOME/data" 2>/dev/null || true
    chmod 0750 "$out" 2>/dev/null || true
}

write_keycloak_unit() {
    log "пишу $SYSTEMD_UNIT_DIR/$KEYCLOAK_UNIT"
    [ "$DRY_RUN" = "1" ] && return 0
    mkdir -p "$SYSTEMD_UNIT_DIR"
    cat > "$SYSTEMD_UNIT_DIR/$KEYCLOAK_UNIT" <<EOF
[Unit]
Description=Keycloak (нативный Узел А, Astra Linux 1.7)
After=network-online.target slapd-lab.service
Wants=network-online.target

[Service]
Type=simple
User=$KEYCLOAK_USER
Group=$KEYCLOAK_GROUP
WorkingDirectory=$KEYCLOAK_HOME
EnvironmentFile=$KEYCLOAK_ETC_DIR/keycloak.env
Environment=HOME=$KEYCLOAK_DATA_DIR
ExecStart=$KEYCLOAK_HOME/bin/kc.sh start-dev --import-realm
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$SYSTEMD_UNIT_DIR/$KEYCLOAK_UNIT"
    run "systemctl daemon-reload"
}

wait_keycloak() {
    # Ждём порт и (если есть curl) — ответ realm'а.
    local port="$KEYCLOAK_HTTP_PORT" i n=$((KEYCLOAK_START_TIMEOUT / 2))
    log "жду Keycloak (до ${KEYCLOAK_START_TIMEOUT} с)"
    for ((i = 0; i < n; i++)); do
        if systemctl is-failed --quiet "$KEYCLOAK_UNIT" 2>/dev/null; then
            warn "  $KEYCLOAK_UNIT в состоянии failed — ждать бесполезно"
            return 1
        fi
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            if command -v curl >/dev/null 2>&1; then
                if curl -sf --max-time 5 "http://127.0.0.1:$port$KEYCLOAK_RELATIVE_PATH/realms/$KC_REALM" >/dev/null 2>&1; then
                    log "  realm $KC_REALM доступен"
                    return 0
                fi
            else
                log "  порт $port слушает"
                return 0
            fi
        fi
        sleep 2
    done
    return 1
}

enable_keycloak_service() {
    log "включаю и запускаю $KEYCLOAK_UNIT"
    run "systemctl enable $KEYCLOAK_UNIT || true"
    run "systemctl reset-failed $KEYCLOAK_UNIT 2>/dev/null || true"
    run "systemctl restart $KEYCLOAK_UNIT || true"
    if [ "$DRY_RUN" = "1" ]; then return 0; fi
    if ! wait_keycloak; then
        warn "$KEYCLOAK_UNIT не поднялся — последние строки журнала:"
        journalctl -u "$KEYCLOAK_UNIT" -n 50 --no-pager 2>&1 | sed 's/^/      /' >&2 || true
        die "Keycloak не отвечает на порту $KEYCLOAK_HTTP_PORT"
    fi
    log "Keycloak: http://$KEYCLOAK_HOST:$KEYCLOAK_HTTP_PORT$KEYCLOAK_RELATIVE_PATH/ (realm $KC_REALM, админ $KEYCLOAK_ADMIN_USER)"
}

install_keycloak() {
    if [ "$SKIP_KEYCLOAK" = "1" ]; then
        log "Keycloak пропущен (--skip-keycloak)"
        return 0
    fi
    install_java
    install_keycloak_dist
    create_keycloak_user
    fix_keycloak_ownership
    write_keycloak_env
    write_keycloak_realm
    write_keycloak_unit
    enable_keycloak_service
}

# ============================== основной ход ==============================
main() {
    if [ "$CHECK_TEMPLATES" = "1" ]; then
        log "сверка шаблонов: ldap/*.tpl vs scripts/templates/*.tpl"
        if check_templates; then
            log "шаблоны совпадают"
        else
            warn "есть расхождения — обновите scripts/templates/ из ldap/"
            exit 1
        fi
        exit 0
    fi

    need_root
    check_os

    log "параметры из $ENV_FILE"
    log "  скрипт: $SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
    # В env-файле лежат пароли; ключи добавляются через `kadmin.local -q ...`,
    # которые видны в ps на время выполнения — файл должен быть закрыт.
    perm_env="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '?')"
    if [ "$perm_env" != "600" ]; then
        warn "права $ENV_FILE = $perm_env (в нём пароли) — рекомендуется: chmod 600 $ENV_FILE"
    fi
    log "  домен=$DOMAIN  realm'ы: $REALM_A (primary, ou=$LDAP_OU_PRIMARY), $REALM_B (secondary, ou=$LDAP_OU_SECONDARY)"
    log "  KDC: $KDC_A_HOST / $KDC_B_HOST   LDAP: $LDAP_HOST ($LDAP_SPN)"

    check_names
    fix_hosts
    switch_base_level

    if [ "$ONLY" = "all" ] || [ "$ONLY" = "kdc" ]; then
        install_packages
        make_dirs
        write_krb5_conf
        write_kdc_conf
        create_databases
        create_principals
        create_cross_realm
        write_keytab
        start_kdc
    fi

    if [ "$ONLY" = "all" ] || [ "$ONLY" = "ldap" ]; then
        stop_distro_slapd
        write_slapd_conf
        write_slapd_unit
        write_seed
        enable_services
        seed_ldap
    fi

    if [ "$ONLY" = "all" ] || [ "$ONLY" = "keycloak" ]; then
        install_keycloak
    fi

    echo
    log "готово. Проверки: sudo ./scripts/astra-node-a-verify.sh"
    log "KDC: systemctl status krb5-kdc krb5-admin-server; slapd: systemctl status $SLAPD_UNIT"
    log "если slapd не стартовал: journalctl -u $SLAPD_UNIT -n 50"
}

# ASTRA_LIB_ONLY=1 — только подключить функции (для тестов рендеринга).
if [ "${ASTRA_LIB_ONLY:-0}" != "1" ]; then
    main
fi
