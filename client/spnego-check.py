#!/usr/bin/env python3
"""Проверка HTTP-доступа по GSSAPI/SPNEGO (curl в Debian собран без GSS).

Использование: spnego-check <url>
Выводит тело ответа; код выхода 0 при HTTP 200.
"""
import sys

import requests
from requests_kerberos import HTTPKerberosAuth, OPTIONAL

url = sys.argv[1]
r = requests.get(url, auth=HTTPKerberosAuth(mutual_authentication=OPTIONAL))
sys.stdout.write(r.text)
sys.exit(0 if r.status_code == 200 else 1)
