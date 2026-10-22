#!/bin/bash
# Полное удаление нативного «Узла А» на Astra Linux SE 1.7 (БЕЗ Docker):
# останавливает сервисы, сносит unit slapd, keytab, базы KDC (оба realm'а),
# конфиги KDC/LDAP и данные каталога, при необходимости удаляет пакеты
# и возвращает режимы ЗПС/МКЦ.
#
#   sudo ./scripts/astra-node-a-remove.sh --dry-run     # показать, что будет удалено
#   sudo ./scripts/astra-node-a-remove.sh               # с подтверждением
#   sudo ./scripts/astra-node-a-remove.sh --yes         # без вопросов
#   sudo ./scripts/astra-node-a-remove.sh --yes --purge-packages --restore-modes
#
# Флаги:
#   --dry-run          только показать действия
#   --yes              без подтверждения
#   --keep-data        не удалять базы KDC и данные LDAP (только конфиги/сервисы)
#   --purge-packages   удалить и пакеты (krb5-*, slapd, sasl2-* и т.п.)
#   --restore-modes    вернуть ЗПС и МКЦ (astra-modeswitch --enable-...)
#   --keep-env         не трогать deploy/astra-node-a.env (по умолчанию не трогаем)
#   --restore-level N  вернуть уровень защищённости N (astra-modeswitch set N, нужна перезагрузка)
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

ENV_FILE="deploy/astra-node-a.env"
DRY_RUN=0
ASSUME_YES=0
KEEP_DATA=0
PURGE_PACKAGES=0
RESTORE_MODES=0
RESTORE_LEVEL=""

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --env)             ENV_FILE="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --yes|-y)          ASSUME_YES=1; shift ;;
        --keep-data)       KEEP_DATA=1; shift ;;
        --purge-packages)  PURGE_PACKAGES=1; shift ;;
        --restore-modes)   RESTORE_MODES=1; shift ;;
        --restore-level)   RESTORE_MODES=1; RESTORE_LEVEL="$2"; shift 2 ;;
        --keep-env)        shift ;;
        -h|--help)         usage 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; usage 1 ;;
    esac
done

[ -f "$ENV_FILE" ] || { echo "НЕТ ФАЙЛА ПАРАМЕТРОВ: $ENV_FILE" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

log()  { echo "[astra-node-a-remove] $*"; }
warn() { echo "[astra-node-a-remove] ВНИМАНИЕ: $*" >&2; }
die()  { echo "[astra-node-a-remove] ОШИБКА: $*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = "1" ]; then echo "    \$ $*"; else eval "$@"; fi; }
# Удаление с бэкапом (бэкап — в /root/astra-node-a-backup-<дата>).
BACKUP_DIR="/root/astra-node-a-backup-$(date +%Y%m%d-%H%M%S)"
BACKUP_MADE=0

backup_file() {
    # backup_file <путь> — если файл есть, копирует в BACKUP_DIR
    local f="$1"
    [ -e "$f" ] || return 0
    if [ "$DRY_RUN" = "1" ]; then
        echo "    backup $f -> $BACKUP_DIR/"
        return 0
    fi
    if [ "$BACKUP_MADE" = "0" ]; then
        mkdir -p "$BACKUP_DIR"
        BACKUP_MADE=1
    fi
    cp -a "$f" "$BACKUP_DIR/" 2>/dev/null || true
}

remove_path() {
    # remove_path <путь> — с бэкапом, затем удаление
    local p="$1" what="${2:-файл}"
    if [ ! -e "$p" ]; then
        log "  $what $p — отсутствует, пропускаю"
        return 0
    fi
    backup_file "$p"
    log "  удаляю $what $p"
    run "rm -rf '$p'"
}

[ "$(id -u)" = "0" ] || die "нужны права root (запускайте через sudo)"

echo "=== Что будет удалено ==="
echo "  сервисы:      krb5-kdc, krb5-admin-server, $SLAPD_UNIT, $KEYCLOAK_UNIT"
echo "  unit:         $SYSTEMD_UNIT_DIR/$SLAPD_UNIT, $SYSTEMD_UNIT_DIR/$KEYCLOAK_UNIT"
echo "  keytab:       $KEYTAB"
echo "  конфиги KDC:  $KRB5_CONF, $KDC_CONF_DIR/kdc.conf, $KDC_CONF_DIR/kadm5*.acl, $KDC_CONF_DIR/stash*"
echo "  конфиг LDAP:  $SLAPD_CONF"
echo "  Keycloak:     $KEYCLOAK_HOME (и $KEYCLOAK_HOME-*), $KEYCLOAK_DATA_DIR, $KEYCLOAK_ETC_DIR, пользователь $KEYCLOAK_USER"
if [ "$KEEP_DATA" = "0" ]; then
    echo "  данные:       $KDC_DB_DIR_A, $KDC_DB_DIR_B, $SLAPD_DATA"
else
    echo "  данные:       НЕ трогаю (--keep-data)"
fi
if [ "$PURGE_PACKAGES" = "1" ]; then
    echo "  пакеты:       $PACKAGES (apt-get purge)"
else
    echo "  пакеты:       не трогаю (--purge-packages чтобы удалить)"
fi
if [ "$RESTORE_MODES" = "1" ]; then
    if [ -n "$RESTORE_LEVEL" ]; then
        echo "  режимы Astra: верну уровень $RESTORE_LEVEL (нужна ПЕРЕЗАГРУЗКА)"
    else
        echo "  режимы Astra: покажу текущий уровень (--restore-level N чтобы вернуть)"
    fi
else
    echo "  режимы Astra: не трогаю (--restore-level N чтобы вернуть)"
fi
echo "  бэкап:        $BACKUP_DIR (файлы копируются перед удалением)"
echo

if [ "$ASSUME_YES" = "0" ] && [ "$DRY_RUN" = "0" ]; then
    printf "Удалить всё это? (yes/no): "
    read -r ans
    case "$ans" in
        yes|y|YES) : ;;
        *) log "отменено пользователем"; exit 1 ;;
    esac
fi

log "1. Останавливаю и отключаю сервисы"
run "systemctl disable --now $SLAPD_UNIT" || true
run "systemctl disable --now krb5-admin-server" || true
run "systemctl disable --now krb5-kdc" || true
run "systemctl disable --now $KEYCLOAK_UNIT" || true
# Штатный slapd.service дистрибутива мы отключали при установке (он держал 389).
if systemctl list-unit-files 2>/dev/null | grep -qE '^slapd\.service'; then
    log "   штатный slapd.service тоже отключаю (он был остановлен при установке)"
    run "systemctl disable --now slapd.service || true"
    warn "   вернуть штатный slapd (если нужен): systemctl enable --now slapd.service"
fi

# Скрипт прописывал сюда "-r REALM_A -r REALM_B": после удаления конфигурации
# такие аргументы не дадут KDC стартовать.
if [ -f /etc/default/krb5-kdc ] && grep -q 'Сгенерировано scripts/astra-node-a.sh' /etc/default/krb5-kdc; then
    run "printf '# krb5-kdc: DAEMON_ARGS очищен при удалении reberos\\nDAEMON_ARGS=\"\"\\n' > /etc/default/krb5-kdc"
fi

log "2. Удаляю unit $SLAPD_UNIT и $KEYCLOAK_UNIT"
remove_path "$SYSTEMD_UNIT_DIR/$SLAPD_UNIT" "unit"
remove_path "$SYSTEMD_UNIT_DIR/$KEYCLOAK_UNIT" "unit"
# Drop-in'ы с RW-каталогами для сандбокса Astra.
remove_path "/etc/systemd/system/krb5-kdc.service.d/10-reberos-rw.conf" "drop-in"
remove_path "/etc/systemd/system/krb5-admin-server.service.d/10-reberos-rw.conf" "drop-in"
run "systemctl daemon-reload"
run "systemctl reset-failed" || true

log "3. Удаляю keytab"
remove_path "$KEYTAB" "keytab"

log "4. Удаляю конфигурацию KDC"
remove_path "$KRB5_CONF" "конфиг"
remove_path "$KDC_CONF_DIR/kdc.conf" "конфиг"
for f in "$KDC_CONF_DIR/kadm5.acl" "$KDC_CONF_DIR/kadm5-$REALM_B.acl" \
         "$KDC_CONF_DIR/stash" "$KDC_CONF_DIR/stash-$REALM_B" \
         "$KDC_CONF_DIR/kadm5.keytab" "$KDC_CONF_DIR/kadm5-$REALM_B.keytab"; do
    remove_path "$f" "файл"
done

log "5. Удаляю конфигурацию и данные LDAP"
remove_path "$SLAPD_CONF" "конфиг"
if [ "$KEEP_DATA" = "0" ]; then
    remove_path "$SLAPD_DATA" "каталог данных"
    remove_path "$SLAPD_RUN" "каталог run"
else
    log "  данные LDAP оставляю (--keep-data)"
fi

log "6. Базы данных KDC"
if [ "$KEEP_DATA" = "0" ]; then
    remove_path "$KDC_DB_DIR_A" "каталог БД $REALM_A"
    remove_path "$KDC_DB_DIR_B" "каталог БД $REALM_B"
else
    log "  базы KDC оставляю (--keep-data)"
fi

log "6a. Keycloak"
remove_path "$KEYCLOAK_ETC_DIR" "каталог конфигурации Keycloak"
if [ "$KEEP_DATA" = "0" ]; then
    remove_path "$KEYCLOAK_DATA_DIR" "каталог данных Keycloak"
else
    log "  данные Keycloak оставляю (--keep-data)"
fi
# /opt/keycloak — симлинк на /opt/keycloak-<версия>; снимаем оба.
if [ -L "$KEYCLOAK_HOME" ]; then
    log "  удаляю симлинк $KEYCLOAK_HOME"
    run "rm -f '$KEYCLOAK_HOME'"
fi
remove_path "$KEYCLOAK_HOME" "каталог Keycloak"
remove_path "$KEYCLOAK_HOME-$KEYCLOAK_VERSION" "каталог Keycloak $KEYCLOAK_VERSION"
if id "$KEYCLOAK_USER" >/dev/null 2>&1; then
    log "  удаляю пользователя $KEYCLOAK_USER"
    run "userdel $KEYCLOAK_USER || true"
    run "rm -f /etc/passwd- || true"
fi
if [ -e /opt/keycloak-jre ]; then
    log "  удаляю оффлайн-JRE /opt/keycloak-jre"
    run "rm -rf /opt/keycloak-jre"
fi

if [ "$PURGE_PACKAGES" = "1" ]; then
    log "7. Удаляю пакеты"
    # postrm krb5-kdc может спросить — отвечаем заранее.
    run "printf 'krb5-kdc krb5-kdc/admin_server boolean false\\n' | debconf-set-selections"
    run "DEBIAN_FRONTEND=noninteractive apt-get purge -y $PACKAGES"
    run "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y"
    warn "ntp мог быть заменён на chrony (конфликт time-daemon) — если нужен ntp: apt-get install ntp"
else
    log "7. Пакеты оставляю (--purge-packages чтобы удалить)"
fi

if [ "$RESTORE_MODES" = "1" ]; then
    log "8. Режимы Astra (ЗПС/МКЦ)"
    if command -v astra-modeswitch >/dev/null 2>&1; then
        log "   текущие режимы:"
        run "astra-modeswitch list || true"
        if [ -n "$RESTORE_LEVEL" ]; then
            log "   возвращаю уровень $RESTORE_LEVEL"
            run "astra-modeswitch set $RESTORE_LEVEL || true"
            warn "   нужна ПЕРЕЗАГРУЗКА: sudo reboot"
        else
            warn "   уровень не указан — верните вручную: sudo astra-modeswitch set <уровень> (0=базовый, 1=Орёл, 2=Воронеж, 3=Смоленск)"
            warn "   затем sudo reboot"
        fi
    else
        warn "astra-modeswitch не найден — режимы не трогаю"
    fi
else
    log "8. Режимы Astra не трогаю (--restore-level N чтобы вернуть)"
fi

echo
if [ "$BACKUP_MADE" = "1" ]; then
    log "бэкап удалённых файлов: $BACKUP_DIR"
else
    log "бэкап не создавался (нечего было копировать)"
fi
log "готово. Проверить остатки: systemctl list-unit-files | grep -E 'krb5|slapd'"
log "файлы репозитория (deploy/astra-node-a.env, scripts/astra-node-a*.sh, docs/astra-node-a.md) не удалялись"
