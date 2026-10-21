#!/usr/bin/env python3
"""Портал выбора организации (за Apache/SPNEGO).

Уровень 1 (SPNEGO) уже пройден Apache'ем: личность приходит в X-Remote-User.
Уровень 2 (OIDC): выбор организации -> Keycloak (web-форма логин/пароль) ->
authorization code flow -> сессия портала с id_token/claims.

Только stdlib: http.server + urllib. Base URL берётся из заголовка Host,
поэтому portal работает и из браузера (http://web-a.lab.test:8081), и из
внутренней Docker-сети (http://web-a.lab.test).
"""
import base64
import html
import json
import os
import secrets
import urllib.error
import urllib.parse
import urllib.request
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8000"))
NODE_LABEL = os.environ.get("NODE_LABEL", "")
ORGS = [o.strip() for o in os.environ.get("ORGS", "").split(",") if o.strip()]
KC_REALM = os.environ.get("KC_REALM", "")
CLIENT_ID = os.environ.get("CLIENT_ID", "portal")
CLIENT_SECRET = os.environ.get("CLIENT_SECRET", "")
KC_INTERNAL = os.environ.get("KC_INTERNAL", "").rstrip("/")

# sid -> {spnego, org, state, id_token, access_token}
SESSIONS = {}
# state -> sid
STATES = {}

COOKIE = "reberos_sid"


def post_form(url, data, headers=None):
    req = urllib.request.Request(
        url,
        data=urllib.parse.urlencode(data).encode(),
        headers=headers or {},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


def decode_jwt_payload(token):
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("[portal] %s - %s" % (self.address_string(), fmt % args))

    # --- helpers ---

    def _base(self):
        host = self.headers.get("Host", "localhost")
        return "http://" + host

    def _spnego(self):
        return self.headers.get("X-Remote-User", "")

    def _sid(self):
        raw = self.headers.get("Cookie", "")
        cookie = SimpleCookie()
        cookie.load(raw)
        morsel = cookie.get(COOKIE)
        return morsel.value if morsel else None

    def _session(self):
        sid = self._sid()
        if sid and sid in SESSIONS:
            return sid, SESSIONS[sid]
        return None, None

    def _ensure_session(self):
        sid, sess = self._session()
        if sess is None:
            sid = secrets.token_urlsafe(16)
            sess = {"spnego": self._spnego(), "org": None, "state": None,
                    "id_token": None, "access_token": None}
            SESSIONS[sid] = sess
        elif not sess.get("spnego") and self._spnego():
            sess["spnego"] = self._spnego()
        return sid, sess

    def _send(self, code, body, ctype="text/html; charset=utf-8", extra=None):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, location, sid=None):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        if sid:
            self.send_header(
                "Set-Cookie",
                f"{COOKIE}={sid}; Path=/; HttpOnly; SameSite=Lax",
            )
        self.end_headers()

    # --- routes ---

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        if path == "/health":
            self._send(200, json.dumps({"status": "ok"}),
                       "application/json")
        elif path == "/":
            self._handle_index()
        elif path == "/login":
            self._handle_login(qs)
        elif path == "/callback":
            self._handle_callback(qs)
        elif path == "/me":
            self._handle_me()
        elif path == "/logout":
            self._handle_logout()
        else:
            self._send(404, "not found", "text/plain; charset=utf-8")

    def _handle_index(self):
        sid, sess = self._session()
        if sess is None:
            sid, sess = self._ensure_session()
        spnego = html.escape(sess.get("spnego") or "(нет)")
        orgs_html = "".join(
            f'<li><a href="/login?org={urllib.parse.quote(o)}">{o}</a></li>'
            for o in ORGS
        )
        body = f"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<title>Портал — {html.escape(NODE_LABEL)}</title>
<style>
 body {{ font-family: sans-serif; max-width: 40rem; margin: 3rem auto; }}
 li {{ margin: .4rem 0; }}
 .meta {{ color: #555; }}
</style></head><body>
<h1>Портал выбора организации — {html.escape(NODE_LABEL)}</h1>
<p class="meta">Уровень 1 (SPNEGO): <b>{spnego}</b></p>
<p>Организации этого узла:</p>
<ul>{orgs_html}</ul>
<p>
 <a href="/me">OIDC-данные (JSON)</a> |
 <a href="/logout">Выйти</a>
</p>
</body></html>"""
        self._send(200, body, extra={
            "Set-Cookie": f"{COOKIE}={sid}; Path=/; HttpOnly; SameSite=Lax",
        })

    def _handle_login(self, qs):
        org = qs.get("org", [""])[0]
        if org not in ORGS:
            self._send(400, "неизвестная организация",
                       "text/plain; charset=utf-8")
            return
        sid, sess = self._ensure_session()
        sess["org"] = org
        state = secrets.token_urlsafe(16)
        sess["state"] = state
        STATES[state] = sid
        base = self._base()
        params = urllib.parse.urlencode({
            "client_id": CLIENT_ID,
            "redirect_uri": f"{base}/callback",
            "response_type": "code",
            "scope": "openid",
            "state": state,
        })
        url = (f"{base}/auth/realms/{KC_REALM}/protocol/openid-connect/auth"
               f"?{params}")
        self._redirect(url, sid=sid)

    def _handle_callback(self, qs):
        code = qs.get("code", [""])[0]
        state = qs.get("state", [""])[0]
        sid = STATES.pop(state, None)
        if not code or sid is None or sid not in SESSIONS:
            self._send(400, "некорректный state/code",
                       "text/plain; charset=utf-8")
            return
        sess = SESSIONS[sid]
        base = self._base()
        basic = base64.b64encode(
            f"{CLIENT_ID}:{CLIENT_SECRET}".encode()).decode()
        try:
            tokens = post_form(
                f"{KC_INTERNAL}/realms/{KC_REALM}"
                "/protocol/openid-connect/token",
                {
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": f"{base}/callback",
                },
                headers={"Authorization": "Basic " + basic},
            )
        except (urllib.error.URLError, OSError) as exc:
            self._send(502, f"обмен кода на токен не прошёл: {exc}",
                       "text/plain; charset=utf-8")
            return
        sess["id_token"] = tokens.get("id_token", "")
        sess["access_token"] = tokens.get("access_token", "")
        sess["state"] = None
        self._redirect("/me", sid=sid)

    def _handle_me(self):
        sid, sess = self._session()
        if sess is None:
            self._send(401, "нет сессии (сначала /login?org=...)",
                       "text/plain; charset=utf-8")
            return
        claims = {}
        if sess.get("id_token"):
            try:
                claims = decode_jwt_payload(sess["id_token"])
            except Exception:
                claims = {}
        out = {
            "node": NODE_LABEL,
            "spnego": sess.get("spnego", ""),
            "org": sess.get("org"),
            "id_token": sess.get("id_token"),
            "claims": claims,
        }
        self._send(200, json.dumps(out, ensure_ascii=False, indent=2),
                   "application/json")

    def _handle_logout(self):
        sid = self._sid()
        if sid:
            state = SESSIONS.get(sid, {}).get("state")
            if state:
                STATES.pop(state, None)
            SESSIONS.pop(sid, None)
        self.send_response(302)
        self.send_header("Location", "/")
        self.send_header("Content-Length", "0")
        self.send_header("Set-Cookie", f"{COOKIE}=; Path=/; Max-Age=0")
        self.end_headers()


def main():
    missing = [n for n, v in {
        "KC_REALM": KC_REALM,
        "CLIENT_SECRET": CLIENT_SECRET,
        "KC_INTERNAL": KC_INTERNAL,
    }.items() if not v]
    if missing:
        raise SystemExit("portal: не заданы переменные: " + ", ".join(missing))
    if not ORGS:
        raise SystemExit("portal: не задан ORGS")
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[portal] {NODE_LABEL}: {', '.join(ORGS)}, realm={KC_REALM}, "
          f"port={PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
