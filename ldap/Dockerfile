FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d \
    && echo "slapd slapd/no_configuration boolean true" | debconf-set-selections \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        slapd \
        ldap-utils \
        libsasl2-modules-gssapi-mit \
        krb5-user \
        procps \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/sbin/policy-rc.d

COPY common/krb5.conf.tpl /templates/krb5.conf.tpl
COPY ldap/slapd.conf.tpl /templates/slapd.conf.tpl
COPY ldap/seed.ldif.tpl /templates/seed.ldif.tpl
COPY ldap/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 389/tcp

ENTRYPOINT ["/entrypoint.sh"]
