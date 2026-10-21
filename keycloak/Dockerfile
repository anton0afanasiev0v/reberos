# Keycloak (уровень 2 — только OIDC, web-форма логин/пароль; без Kerberos).
# Образ UBI-micro: без пакетного менеджера и curl — healthcheck в compose
# сделан через bash /dev/tcp на management-порт 9000.
FROM quay.io/keycloak/keycloak:26.8.1

COPY keycloak/realm-node.json.tpl /templates/realm-node.json.tpl
COPY keycloak/entrypoint.sh /entrypoint.sh

USER 0
RUN chmod +x /entrypoint.sh
USER 1000

ENTRYPOINT ["/entrypoint.sh"]
