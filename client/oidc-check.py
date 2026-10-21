#!/usr/bin/env python3
"""Сквозная проверка двух уровней авторизации: SPNEGO + OIDC.

Использование: oidc-check <base-url> <org> <user> <password>
  base-url — http://web-a.lab.test (внутри Docker-сети, порт 80;
             в браузерном сценарии порт 8081).
Шаги: SPNEGO-GET / (уровень 1) -> /login?org=... (302 в Keycloak) ->
POST логин-формы (уровень 2) -> редирект на /callback -> GET /me (JSON).
"""
import json
import re
import sys

import requests
from requests_kerberos import HTTPKerberosAuth, OPTIONAL

base = sys.argv[1].rstrip("/")
org = sys.argv[2]
user = sys.argv[3]
password = sys.argv[4]

s = requests.Session()
s.auth = HTTPKerberosAuth(mutual_authentication=OPTIONAL)

r = s.get(base + "/", allow_redirects=True)
if r.status_code != 200 or "Портал" not in r.text:
    sys.exit(f"[oidc-check] SPNEGO-GET / не прошёл: HTTP {r.status_code}")
print("[oidc-check] уровень 1 (SPNEGO): OK")

r = s.get(base + "/login", params={"org": org}, allow_redirects=True)
m = re.search(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', r.text)
if not m:
    m = re.search(r'<form[^>]+action="([^"]+)"[^>]*id="kc-form-login"', r.text)
if not m:
    sys.exit(f"[oidc-check] логин-форма Keycloak не найдена "
             f"(HTTP {r.status_code})")
action = m.group(1).replace("&amp;", "&")
print(f"[oidc-check] логин-форма Keycloak: {action[:80]}...")

r = s.post(action,
           data={"username": user, "password": password, "credentialId": ""},
           allow_redirects=True)

payload = None
if r.headers.get("Content-Type", "").startswith("application/json"):
    try:
        payload = r.json()
    except ValueError:
        payload = None
if payload is None:
    r = s.get(base + "/me")
    try:
        payload = r.json()
    except ValueError:
        sys.exit(f"[oidc-check] /me не вернул JSON: HTTP {r.status_code} "
                 f"{r.text[:200]}")

print(json.dumps(payload, ensure_ascii=False, indent=2))
if not payload.get("id_token"):
    sys.exit("[oidc-check] в сессии нет id_token")
if not payload.get("spnego"):
    sys.exit("[oidc-check] в сессии нет SPNEGO-принципала")
if payload.get("org") != org:
    sys.exit(f"[oidc-check] ожидалась организация {org}, "
             f"получена {payload.get('org')}")
print("[oidc-check] уровень 2 (OIDC): OK")
