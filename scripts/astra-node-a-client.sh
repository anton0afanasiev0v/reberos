#!/bin/bash
# Настройка ЛОКАЛЬНОГО ПК как клиента лабораторного «Узла А» (Astra, нативно):
#   - имена ldap-a / kdc-a1 / kdc-a2 -> IP узла в /etc/hosts;
#   - /etc/krb5.conf с двумя realm'ами (ORG1.TEST / ORG2.TEST) и кросс-доверием;
#   - проверка: kinit -> kvno -> ldapwhoami (GSSAPI), плюс кросс-реалм.
#
# Сервер настраивается ДРУГИМ скриптом (astra-node-a.sh) — здесь только клиент.
#
#   sudo ./scripts/astra-node-a-client.sh                     # узел из deploy/astra-node-a.env
#   sudo ./scripts/astra-node-a-client.sh --server 172.16.138.25
#   sudo ./scripts/astra-node-a-client.sh --dry-run           # показать, без изменений
#   ./scripts/astra-node-a-client.sh --check                  # только проверки (без sudo)
#   sudo ./scripts/astra-node-a-client.sh --uninstall         # вернуть hosts/krb5.conf
#   sudo ./scripts/astra-node-a-client.sh --no-hosts          # не трогать /etc/hosts
#
# Секреты в файл не пишутся. --check ничего не меняет; пароли для kinit берутся
# из env-файла (если он рядом), иначе kinit спросит их интерактивно.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="deploy/astra-node-a.env"
SERVER_IP=""
DRY_RUN=0
CHECK_ONLY=0
UNINSTALL=0
NO_HOSTS=0

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --env)        ENV_FILE="$2"; shift 2 ;;
        --server)     SERVER_IP="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --check)      CHECK_ONLY=1; shift ;;
        --uninstall)  UNINSTALL=1; shift ;;
        --no-hosts)   NO_HOSTS=1; shift ;;
        -h|--help)    usage 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; usage 1 ;;
    esac
done

# Параметры берём из env-файла узла (если он есть), иначе — значения по умолчанию.
if [ -f "$ENV_FILE" ]; then
    set -a; . "$ENV_FILE"; set +a
fi
DOMAIN="${DOMAIN:-lab.test}"
REALM_A="${REALM_A:-ORG1.TEST}"
REALM_B="${REALM_B:-ORG2.TEST}"
KDC_A_HOST="${KDC_A_HOST:-kdc-a1.$DOMAIN}"
KDC_B_HOST="${KDC_B_HOST:-kdc-a2.$DOMAIN}"
LDAP_HOST="${LDAP_HOST:-ldap-a.$DOMAIN}"
LDAP_SPN="${LDAP_SPN:-ldap/$LDAP_HOST}"
KRB5_CONF="${KRB5_CONF:-/etc/krb5.conf}"
SERVER_IP="${SERVER_IP:-${NODE_IP:-}}"

HOSTS_FILE=/etc/hosts
HOSTS_BEGIN="# BEGIN reberos astra-client"
HOSTS_END="# END reberos astra-client"
HOSTS_LABELS="$LDAP_HOST $KDC_A_HOST $KDC_B_HOST"
MARK="# Сгенерировано scripts/astra-node-a-client.sh"

log()  { echo "[astra-client] $*"; }
warn() { echo "[astra-client] ВНИМАНИЕ: $*" >&2; }
die()  { echo "[astra-client] ОШИБКА: $*" >&2; exit 1; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
FAIL=0

need_root() {
    [ "$(id -u)" = "0" ] || die "нужны права root (запускайте через sudo)"
}

krb5_conf_text() {
    cat <<EOF
$MARK (узел А: $REALM_A / $REALM_B).
# Правки вручную будут перезаписаны при повторном запуске скрипта.

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

# Прямое доверие между организациями узла (без посредников).
[capaths]
    $REALM_A = {
        $REALM_B = .
    }
    $REALM_B = {
        $REALM_A = .
    }

[logging]
    default = FILE:/var/log/krb5libs.log
    kdc = FILE:/var/log/krb5libs.log
    admin_server = FILE:/var/log/krb5libs.log
EOF
}

strip_hosts_block() {
    # strip_hosts_block <src> <dst> — убрать старый управляемый блок
    awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }
    ' "$1" > "$2"
}

write_hosts() {
    if [ "$NO_HOSTS" = "1" ]; then
        log "/etc/hosts: пропущено (--no-hosts)"
        return 0
    fi
    log "/etc/hosts: $SERVER_IP -> $HOSTS_LABELS"
    if [ "$DRY_RUN" = "1" ]; then
        echo "    $HOSTS_BEGIN"
        echo "    $SERVER_IP $HOSTS_LABELS"
        echo "    $HOSTS_END"
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    strip_hosts_block "$HOSTS_FILE" "$tmp"
    {
        printf '%s\n' "$HOSTS_BEGIN"
        printf '%s %s\n' "$SERVER_IP" "$HOSTS_LABELS"
        printf '%s\n' "$HOSTS_END"
    } >> "$tmp"
    cat "$tmp" > "$HOSTS_FILE"
    rm -f "$tmp"
}

write_krb5() {
    log "$KRB5_CONF: realm'ы $REALM_A (kdc $KDC_A_HOST), $REALM_B (kdc $KDC_B_HOST)"
    if [ "$DRY_RUN" = "1" ]; then
        krb5_conf_text | sed 's/^/    /'
        return 0
    fi
    if [ -f "$KRB5_CONF" ] && ! grep -qF "$MARK" "$KRB5_CONF"; then
        local b
        b="$KRB5_CONF.reberos-backup-$(date +%Y%m%d-%H%M%S)"
        cp -a "$KRB5_CONF" "$b"
        log "  бэкап прежнего конфига: $b"
    fi
    krb5_conf_text > "$KRB5_CONF"
    chmod 0644 "$KRB5_CONF"
}

tcp_open() {
    # tcp_open <host> <port>
    timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

check_deps() {
    echo "==> Зависимости"
    local missing=0 c
    for c in kinit kvno ldapwhoami klist; do
        if command -v "$c" >/dev/null 2>&1; then
            ok "$c: $(command -v "$c")"
        else
            bad "нет команды $c"
            missing=1
        fi
    done
    if [ "$missing" = "1" ]; then
        echo "  Установите: sudo apt install krb5-user ldap-utils libsasl2-modules-gssapi-mit"
    fi
    return 0
}

check_names() {
    echo
    echo "==> Имена в /etc/hosts"
    local n ip
    for n in $HOSTS_LABELS; do
        ip="$(getent ahostsv4 "$n" 2>/dev/null | awk 'NR==1{print $1}' || true)"
        if [ -z "$ip" ]; then
            bad "$n не резолвится (нужна строка в /etc/hosts)"
        elif [ -n "$SERVER_IP" ] && [ "$ip" != "$SERVER_IP" ]; then
            bad "$n -> $ip, ожидался $SERVER_IP"
        else
            ok "$n -> $ip"
        fi
    done
}

check_config() {
    echo
    echo "==> $KRB5_CONF"
    if [ ! -r "$KRB5_CONF" ]; then
        bad "нет $KRB5_CONF (запустите скрипт без --check)"
        return 0
    fi
    if grep -qE "^[[:space:]]*default_realm[[:space:]]*=[[:space:]]*$REALM_A" "$KRB5_CONF"; then
        ok "default_realm = $REALM_A"
    else
        bad "default_realm не $REALM_A"
    fi
    if grep -qE "^[[:space:]]*kdc[[:space:]]*=[[:space:]]*$KDC_A_HOST" "$KRB5_CONF"; then
        ok "KDC $REALM_A: $KDC_A_HOST"
    else
        bad "в $KRB5_CONF нет kdc = $KDC_A_HOST"
    fi
    if grep -qE "^[[:space:]]*kdc[[:space:]]*=[[:space:]]*$KDC_B_HOST" "$KRB5_CONF"; then
        ok "KDC $REALM_B: $KDC_B_HOST"
    else
        bad "в $KRB5_CONF нет kdc = $KDC_B_HOST"
    fi
    if grep -qE "^\[capaths\]" "$KRB5_CONF"; then
        ok "есть [capaths]"
    else
        bad "нет [capaths] — кросс-реалм не сработает"
    fi
    if grep -qE "^[[:space:]]*rdns[[:space:]]*=[[:space:]]*false" "$KRB5_CONF"; then
        ok "rdns = false"
    else
        bad "rdns не выключен (будет ldap/<hostname>)"
    fi
}

check_ports() {
    echo
    echo "==> Доступность узла $SERVER_IP"
    local p name
    for p in 88 389; do
        case "$p" in
            88)  name="KDC/TCP" ;;
            389) name="LDAP/TCP" ;;
        esac
        if tcp_open "$SERVER_IP" "$p"; then
            ok "$name: $SERVER_IP:$p"
        else
            bad "$name: $SERVER_IP:$p недоступен (firewall? узел не запущен?)"
        fi
    done
}

pw_of() {
    # pw_of <логин> — пароль из env-файла (если он есть)
    local pair
    case "$1" in
        alice) echo "${ALICE_PASSWORD:-}"; return ;;
        admin) echo "${NODE_ADMIN_PASSWORD:-}"; return ;;
    esac
    for pair in ${ORG_USER_PASSWORDS:-}; do
        case "$pair" in "$1"=*) echo "${pair#*=}"; return ;; esac
    done
}

kinit_test() {
    # kinit_test <ccache> <principal> <метка>
    local cc="$1" princ="$2" label="$3" pw
    pw="$(pw_of "${princ%%@*}")"
    if [ -n "$pw" ]; then
        printf '%s\n' "$pw" | kinit -c "$cc" "$princ" >/dev/null 2>&1
    else
        echo "  пароль для $princ:"
        kinit -c "$cc" "$princ" </dev/tty
    fi
}

run_tests() {
    echo
    echo "==> Сквозная проверка (kinit -> kvno -> ldapwhoami)"
    if ! command -v kinit >/dev/null 2>&1 || ! command -v ldapwhoami >/dev/null 2>&1; then
        warn "kinit/ldapwhoami не установлены — проверка пропущена"
        return 0
    fi
    local cc1 cc2
    cc1="$(mktemp -u /tmp/krb5cc_client_a.XXXXXX)"
    cc2="$(mktemp -u /tmp/krb5cc_client_b.XXXXXX)"

    echo "  -- $REALM_A (alice)"
    if kinit_test "$cc1" "alice@$REALM_A" "alice"; then
        ok "kinit alice@$REALM_A"
        if KRB5CCNAME="$cc1" kvno "$LDAP_SPN" >/dev/null 2>&1; then
            ok "kvno $LDAP_SPN"
        else
            bad "kvno $LDAP_SPN (KDC не выдал билет)"
        fi
        local dn
        dn="$(KRB5CCNAME="$cc1" ldapwhoami -Y GSSAPI -Q -H "ldap://$LDAP_HOST" 2>&1 | tr -d '\r')"
        if printf '%s' "$dn" | grep -q 'uid=alice,ou=org1'; then
            ok "ldapwhoami -> ${dn#dn:}"
        else
            bad "ldapwhoami: $dn"
        fi
    else
        bad "kinit alice@$REALM_A"
    fi

    echo "  -- кросс-реалм $REALM_B (org2user1)"
    if kinit_test "$cc2" "org2user1@$REALM_B" "org2user1"; then
        ok "kinit org2user1@$REALM_B"
        local dn
        dn="$(KRB5CCNAME="$cc2" ldapwhoami -Y GSSAPI -Q -H "ldap://$LDAP_HOST" 2>&1 | tr -d '\r')"
        if printf '%s' "$dn" | grep -q 'uid=org2user1,ou=org2'; then
            ok "ldapwhoami (cross-realm) -> ${dn#dn:}"
        else
            bad "ldapwhoami (cross-realm): $dn"
        fi
    else
        bad "kinit org2user1@$REALM_B"
    fi

    kdestroy -c "$cc1" 2>/dev/null || true
    kdestroy -c "$cc2" 2>/dev/null || true
    rm -f "$cc1" "$cc2"
}

uninstall() {
    need_root
    log "удаляю управляемый блок из $HOSTS_FILE"
    local tmp
    tmp="$(mktemp)"
    strip_hosts_block "$HOSTS_FILE" "$tmp"
    cat "$tmp" > "$HOSTS_FILE"
    rm -f "$tmp"

    local b
    b="$(ls -1t "$KRB5_CONF".reberos-backup-* 2>/dev/null | head -1 || true)"
    if [ -n "$b" ]; then
        log "восстанавливаю $KRB5_CONF из $b"
        cp -a "$b" "$KRB5_CONF"
    elif [ -f "$KRB5_CONF" ] && grep -qF "$MARK" "$KRB5_CONF"; then
        local moved="$KRB5_CONF.reberos-removed-$(date +%Y%m%d-%H%M%S)"
        log "бэкапа нет — убираю сгенерированный конфиг в $moved"
        mv "$KRB5_CONF" "$moved"
    fi
    log "готово. Пакеты (krb5-user и т.п.) не удалялись."
}

main() {
    if [ "$UNINSTALL" = "1" ]; then
        uninstall
        return 0
    fi
    [ -n "$SERVER_IP" ] || die "не задан адрес узла: --server <IP> или NODE_IP в $ENV_FILE"
    if [ "$DRY_RUN" = "0" ] && [ "$CHECK_ONLY" = "0" ]; then
        need_root
    fi

    if [ "$CHECK_ONLY" = "0" ]; then
        log "узел: $SERVER_IP; $REALM_A / $REALM_B"
        write_hosts
        write_krb5
        echo
    fi

    if [ "$DRY_RUN" = "1" ]; then
        log "dry-run: файлы не изменялись, проверки не выполняются"
        return 0
    fi

    check_deps
    check_names
    check_config
    check_ports

    if [ "$CHECK_ONLY" = "0" ] && [ "$DRY_RUN" = "0" ]; then
        run_tests
    fi

    echo
    if [ "$FAIL" != "0" ]; then
        warn "проблем: $FAIL (см. [FAIL] выше)"
    else
        log "всё в порядке"
    fi
    echo
    echo "Как пользоваться:"
    echo "  kinit alice@$REALM_A          # пароль: Alice_Secret_2024 (если не меняли)"
    echo "  klist"
    echo "  ldapwhoami -Y GSSAPI -H ldap://$LDAP_HOST"
    echo "  kinit org2user1@$REALM_B      # кросс-реалм (пароль Org2User1_2024)"
    [ "$FAIL" = "0" ] || return 1
}

main "$@"
