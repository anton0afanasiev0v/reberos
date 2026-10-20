# Keycloak (сервис федерации, профиль keycloak).
# Образ UBI-micro: без пакетного менеджера и curl — healthcheck в compose
# сделан через bash /dev/tcp на management-порт 9000.
FROM quay.io/keycloak/keycloak:26.8.1

COPY common/krb5.conf.tpl /templates/krb5.conf.tpl
COPY keycloak/realm-lab.json.tpl /templates/realm-lab.json.tpl
COPY keycloak/entrypoint.sh /entrypoint.sh

USER 0
RUN chmod +x /entrypoint.sh
USER 1000

ENTRYPOINT ["/entrypoint.sh"]
