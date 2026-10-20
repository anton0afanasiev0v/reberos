#!/usr/bin/env python3
"""Проверка HTTP-доступа по GSSAPI/SPNEGO (curl в Debian собран без GSS).

Использование: spnego-check <url>
Выводит тело ответа и статус; код выхода 0 при HTTP 200/301/302.
Редиректы не следуются: Grafana за прокси отвечает 301 на canonical URL
(root_url с портом 8080), который недоступен изнутри Docker-сети, —
сам факт 301/302 доказывает, что аутентификация прошла.
"""
import sys

import requests
from requests_kerberos import HTTPKerberosAuth, OPTIONAL

url = sys.argv[1]
r = requests.get(url, auth=HTTPKerberosAuth(mutual_authentication=OPTIONAL),
                 allow_redirects=False)
sys.stdout.write(r.text)
sys.stdout.write("\n[spnego-check] HTTP %s -> %s loc=%s\n"
                 % (r.status_code, url, r.headers.get("Location", "")))
sys.exit(0 if r.status_code in (200, 301, 302) else 1)
