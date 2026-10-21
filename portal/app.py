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
# Полный список логинов системы (все узлы/организации) — для отображения.
SYSTEM_USERS = [u.strip()
                for u in os.environ.get("SYSTEM_USERS", "").split() if u.strip()]

# sid -> {spnego, org, state, id_token, access_token}
SESSIONS = {}
# state -> sid
STATES = {}

COOKIE = "reberos_sid"

# Общий стиль портала (тёмная тема, карточки, адаптив). Только CSS, без CDN.
STYLE = """
:root {
  --bg: #0d1117; --panel: #161b22; --panel-2: #1c2333; --border: #30363d;
  --fg: #e6edf3; --muted: #8b949e; --accent: #2f81f7; --accent-2: #1f6feb;
  --ok: #3fb950; --warn: #d29922; --danger: #f85149; --radius: 12px;
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  background: radial-gradient(1200px 600px at 20% -10%, #1b2438 0%, var(--bg) 55%);
  color: var(--fg); min-height: 100vh;
  font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
        "Helvetica Neue", Arial, "Noto Sans", sans-serif;
  -webkit-font-smoothing: antialiased;
}
.wrap { max-width: 960px; margin: 0 auto; padding: 40px 22px 64px; }
header.top { display: flex; align-items: center; gap: 14px; margin-bottom: 28px; }
.logo {
  width: 42px; height: 42px; border-radius: 11px; flex: 0 0 auto;
  background: linear-gradient(135deg, var(--accent), #8957e5);
  display: grid; place-items: center; font-weight: 700; font-size: 20px;
  color: #fff; box-shadow: 0 6px 20px rgba(47,129,247,.35);
}
h1 { font-size: 22px; margin: 0; letter-spacing: -.01em; }
.sub { color: var(--muted); font-size: 13px; margin-top: 2px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
@media (max-width: 720px) { .grid { grid-template-columns: 1fr; } }
.card {
  background: linear-gradient(180deg, var(--panel), var(--panel-2));
  border: 1px solid var(--border); border-radius: var(--radius);
  padding: 20px; box-shadow: 0 8px 30px rgba(0,0,0,.35);
}
.card h2 {
  font-size: 13px; text-transform: uppercase; letter-spacing: .08em;
  color: var(--muted); margin: 0 0 14px; font-weight: 600;
  display: flex; justify-content: space-between; align-items: center;
}
.badge {
  background: rgba(47,129,247,.14); color: var(--accent);
  border: 1px solid rgba(47,129,247,.35); border-radius: 999px;
  padding: 2px 10px; font-size: 11px; letter-spacing: .04em;
}
.org-list { display: grid; gap: 10px; }
.org {
  display: flex; align-items: center; justify-content: space-between;
  padding: 14px 16px; border-radius: 10px; text-decoration: none;
  color: var(--fg); background: rgba(255,255,255,.02);
  border: 1px solid var(--border); transition: .15s ease;
}
.org:hover {
  border-color: var(--accent); background: rgba(47,129,247,.08);
  transform: translateY(-1px);
}
.org .name { font-weight: 600; }
.org .arrow { color: var(--accent); font-size: 18px; }
.people { display: flex; flex-wrap: wrap; gap: 8px; }
.group { margin-bottom: 16px; }
.group:last-child { margin-bottom: 0; }
.group-name {
  display: flex; align-items: center; gap: 8px; margin: 0 0 8px;
  font-size: 12px; font-weight: 600; text-transform: uppercase;
  letter-spacing: .06em; color: var(--accent);
}
.group-name .count {
  background: rgba(47,129,247,.14); color: var(--accent);
  border: 1px solid rgba(47,129,247,.35); border-radius: 999px;
  padding: 1px 8px; font-size: 11px; letter-spacing: .04em;
}
.chip {
  font: 12px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
  padding: 7px 11px; border-radius: 8px; color: var(--fg);
  background: rgba(255,255,255,.04); border: 1px solid var(--border);
}
.meta { display: flex; align-items: center; gap: 8px; color: var(--muted);
        font-size: 13px; margin: 0 0 4px; }
.dot { width: 8px; height: 8px; border-radius: 50%; background: var(--ok);
       box-shadow: 0 0 10px var(--ok); }
.dot.warn { background: var(--warn); box-shadow: 0 0 10px var(--warn); }
.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        color: var(--fg); }
footer.actions { margin-top: 28px; display: flex; gap: 12px; }
.btn {
  display: inline-flex; align-items: center; gap: 8px; text-decoration: none;
  padding: 10px 16px; border-radius: 10px; font-size: 14px; font-weight: 600;
  border: 1px solid var(--border); color: var(--fg); transition: .15s ease;
}
.btn:hover { border-color: var(--accent); color: var(--accent); }
.btn.primary { background: var(--accent-2); border-color: var(--accent-2);
               color: #fff; }
.btn.primary:hover { background: var(--accent); color: #fff; }
.denied { color: var(--danger); }
.note { color: var(--muted); font-size: 13px; margin-top: 14px; }
"""


def page(title, body):
    """Обёртка HTML-страницы (тёмная тема, карточки)."""
    return f"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>{STYLE}</style></head>
<body><div class="wrap">{body}</div></body></html>"""


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

    def _spnego_realm(self):
        # X-Remote-User = "user1@ORG1.TEST" -> realm принципала (верхний регистр).
        principal = self._spnego()
        if "@" not in principal:
            return ""
        return principal.rsplit("@", 1)[1].upper()

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
        elif path in ("/me", "/me.json"):
            self._handle_me()
        elif path == "/logout":
            self._handle_logout()
        else:
            self._send(404, "not found", "text/plain; charset=utf-8")

    def _handle_index(self):
        sid, sess = self._session()
        if sess is None:
            sid, sess = self._ensure_session()
        spnego_raw = sess.get("spnego") or ""
        spnego = html.escape(spnego_raw or "(нет)")
        realm = self._spnego_realm()
        allowed = [o for o in ORGS if not realm or o.upper() == realm]
        denied = [o for o in ORGS if o not in allowed]

        if allowed:
            org_html = "".join(
                f'<a class="org" href="/login?org={urllib.parse.quote(o)}">'
                f'<span class="name">{html.escape(o)}</span>'
                f'<span class="arrow">&rarr;</span></a>'
                for o in allowed
            )
        else:
            org_html = ('<p class="denied">Нет доступных организаций '
                        'для вашей личности.</p>')
        for o in denied:
            org_html += (
                f'<div class="org" style="opacity:.5;cursor:not-allowed">'
                f'<span class="name">{html.escape(o)}</span>'
                f'<span class="denied">нет доступа</span></div>'
            )

        # Пользователи сгруппированы по организации (префикс orgN: буквы+цифры).
        groups = {}
        for u in SYSTEM_USERS:
            key, seen_digit = "", False
            for ch in u:
                if ch.isdigit():
                    seen_digit = True
                    key += ch
                elif ch.isalpha() and not seen_digit:
                    key += ch
                else:
                    break
            groups.setdefault(key or u or "прочие", []).append(u)
        people_html = "".join(
            f'<div class="group"><div class="group-name">{html.escape(g)}'
            f'<span class="count">{len(us)}</span></div>'
            f'<div class="people">'
            + "".join(f'<span class="chip">{html.escape(x)}</span>'
                      for x in us)
            + "</div></div>"
            for g, us in groups.items()
        ) or '<p class="note">Список пуст.</p>'

        dot = "dot" if spnego_raw else "dot warn"
        who = spnego_raw or "личность не определена"
        body = f"""
<header class="top">
  <div class="logo">R</div>
  <div>
    <h1>{html.escape(NODE_LABEL or "Портал")}</h1>
    <div class="sub">Единый вход в организации узла</div>
  </div>
</header>

<div class="grid">
  <section class="card">
    <h2>Организации узла <span class="badge">{len(ORGS)}</span></h2>
    <div class="org-list">{org_html}</div>
    <p class="note">Выбор организации запускает вход через Keycloak (OIDC).</p>
  </section>

  <section class="card">
    <h2>Пользователи системы <span class="badge">{len(SYSTEM_USERS)}</span></h2>
    <div class="people">{people_html}</div>
  </section>
</div>

<section class="card" style="margin-top:20px">
  <h2>Сессия</h2>
  <p class="meta"><span class="{dot}"></span> Уровень 1 (SPNEGO):
    <span class="mono">{spnego}</span></p>
  <footer class="actions">
    <a class="btn primary" href="/me">OIDC-данные</a>
    <a class="btn" href="/logout">Выйти</a>
  </footer>
</section>"""
        self._send(200, page(f"Портал — {NODE_LABEL}", body), extra={
            "Set-Cookie": f"{COOKIE}={sid}; Path=/; HttpOnly; SameSite=Lax",
        })

    def _error_page(self, code, title, detail):
        body = f"""
<header class="top"><div class="logo">R</div>
  <div><h1>{html.escape(title)}</h1>
  <div class="sub">{html.escape(NODE_LABEL or "Портал")}</div></div></header>
<section class="card"><p class="meta"><span class="dot warn"></span>
  <span class="denied">{html.escape(detail)}</span></p>
  <footer class="actions"><a class="btn primary" href="/">На главную</a></footer>
</section>"""
        self._send(code, page(f"{title} — Портал", body))

    def _handle_login(self, qs):
        org = qs.get("org", [""])[0]
        if org not in ORGS:
            self._error_page(400, "Неизвестная организация", org)
            return
        realm = self._spnego_realm()
        if realm and realm != org.upper():
            self._error_page(
                403, "Доступ запрещён",
                f"нет доступа к организации {org}: realm личности {realm}")
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
        accept = self.headers.get("Accept", "")
        path = self.path.split("?", 1)[0].rstrip("/")
        # HTML — только если клиент явно предпочитает text/html (браузер).
        # Всё прочее (API, requests с Accept: */*) — JSON.
        want_json = True
        if path.endswith(".json"):
            want_json = True
        elif "text/html" in accept:
            want_json = False
        if sess is None:
            if want_json:
                self._send(401, json.dumps({"error": "нет сессии"}),
                           "application/json")
            else:
                body = """
<header class="top"><div class="logo">R</div>
  <div><h1>Нет сессии</h1>
  <div class="sub">Сначала выберите организацию на портале</div></div></header>
<section class="card"><p class="meta"><span class="dot warn"></span>
  OIDC-сессия не создана</p>
  <footer class="actions">
    <a class="btn primary" href="/">На главную</a></footer></section>"""
                self._send(401, page("Нет сессии — Портал", body))
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
        if want_json:
            self._send(200, json.dumps(out, ensure_ascii=False, indent=2),
                       "application/json")
            return
        org = html.escape(str(sess.get("org") or "(нет)"))
        spnego = html.escape(sess.get("spnego") or "(нет)")
        pref = html.escape(str(claims.get("preferred_username", "")))
        sub = html.escape(str(claims.get("sub", "")))
        tok = html.escape(sess.get("id_token") or "")
        body = f"""
<header class="top"><div class="logo">R</div>
  <div><h1>OIDC-данные</h1>
  <div class="sub">{html.escape(NODE_LABEL or "Портал")}</div></div></header>
<div class="grid">
  <section class="card">
    <h2>Идентификация</h2>
    <p class="meta"><span class="dot"></span> SPNEGO:
      <span class="mono">{spnego}</span></p>
    <p class="meta">Организация: <span class="mono">{org}</span></p>
    <p class="meta">Username (claim):
      <span class="mono">{pref}</span></p>
    <p class="meta">sub: <span class="mono">{sub}</span></p>
  </section>
  <section class="card">
    <h2>Claims ID-token</h2>
    <pre class="mono" style="max-height:320px;overflow:auto;margin:0">
{html.escape(json.dumps(claims, ensure_ascii=False, indent=2))}</pre>
  </section>
</div>
<section class="card" style="margin-top:20px">
  <h2>Токен</h2>
  <pre class="mono" style="max-height:200px;overflow:auto;margin:0;word-break:break-all">{tok}</pre>
</section>
<footer class="actions">
  <a class="btn primary" href="/">На главную</a>
  <a class="btn" href="/logout">Выйти</a>
</footer>"""
        self._send(200, page("OIDC-данные — Портал", body))

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
