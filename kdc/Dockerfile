FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        krb5-kdc \
        krb5-admin-server \
        krb5-user \
        procps \
        bsdutils \
    && rm -rf /var/lib/apt/lists/* \
    && printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d || true

COPY common/krb5.conf.tpl /templates/krb5.conf.tpl
COPY kdc/kdc.conf.tpl /templates/kdc.conf.tpl
COPY kdc/kadm5.acl.tpl /templates/kadm5.acl.tpl
COPY kdc/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 88/tcp 88/udp 749/tcp 464/tcp

ENTRYPOINT ["/entrypoint.sh"]
