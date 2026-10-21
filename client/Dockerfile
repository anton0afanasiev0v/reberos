FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        krb5-user \
        ldap-utils \
        libsasl2-modules-gssapi-mit \
        curl \
        procps \
        python3 \
        python3-requests \
        python3-requests-kerberos \
    && rm -rf /var/lib/apt/lists/*

COPY client/krb5.conf.tpl /templates/krb5.conf.tpl
COPY client/entrypoint.sh /entrypoint.sh
COPY client/spnego-check.py /usr/local/bin/spnego-check
COPY client/oidc-check.py /usr/local/bin/oidc-check
RUN chmod +x /entrypoint.sh /usr/local/bin/spnego-check /usr/local/bin/oidc-check

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
