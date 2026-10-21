FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        apache2 \
        libapache2-mod-auth-gssapi \
        krb5-user \
        procps \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/sbin/policy-rc.d \
    && a2enmod auth_gssapi proxy proxy_http headers >/dev/null \
    && a2dissite 000-default >/dev/null

COPY common/krb5.conf.tpl /templates/krb5.conf.tpl
COPY apache/kerberos.conf.tpl /templates/kerberos.conf.tpl
COPY apache/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80/tcp

ENTRYPOINT ["/entrypoint.sh"]
