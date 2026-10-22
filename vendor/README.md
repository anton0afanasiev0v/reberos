# vendor/ — офлайн-дистрибутивы для нативного узла Astra

Здесь лежат большие файлы, которые нужны узлу **без интернета** (на Astra
устанавливать софт можно только с DVD-репозитория или из подготовленного
каталога). В git они **не коммится** (см. `.gitignore`) — при переносе на узел
их нужно скопировать отдельно.

| Файл | Что это | Нужен, когда |
|---|---|---|
| `keycloak-26.8.1.tar.gz` | Keycloak 26.8.1 (та же версия, что в Docker-лаборатории) | ставится Keycloak на узле |
| `temurin17-jre-x64-linux.tar.gz` | Eclipse Temurin 17 JRE (x64 linux) — фолбэк, если в репозиториях Astra нет `openjdk-17` | Keycloak 26 требует Java 17+ |

Контрольные суммы:

```
4e2740b181faa2ea623a1c2ecf00855935311e546046e2f857615a47ed24cbe8  keycloak-26.8.1.tar.gz
```

(для JRE сумму посчитайте локально: `sha256sum vendor/temurin17-jre-x64-linux.tar.gz`)

## Как развернуть на узле

```bash
# с машины-разработчика
scp vendor/keycloak-26.8.1.tar.gz  astra:/opt/reberos/vendor/
scp vendor/temurin17-jre-x64-linux.tar.gz astra:/opt/reberos/vendor/   # опционально

# на узле
cd /opt/reberos
sudo ./scripts/astra-node-a.sh --dry-run
sudo ./scripts/astra-node-a.sh
```

Скрипт сам выберет источник:

* Java — сначала `openjdk-17` из репозитория Astra; если такого пакета нет,
  берётся JRE из `vendor/temurin17-jre-x64-linux.tar.gz` (если файл есть);
* Keycloak — только из `vendor/keycloak-<версия>.tar.gz` (на узле нет сети).

## Если нужно перекачать вручную

```bash
cd vendor
curl -sSLO https://github.com/keycloak/keycloak/releases/download/26.8.1/keycloak-26.8.1.tar.gz
curl -sSL -o temurin17-jre-x64-linux.tar.gz \
  "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jre/hotspot/normal/eclipse"
sha256sum *.tar.gz
```
