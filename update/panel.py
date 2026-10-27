from flask import Flask, request, Response, redirect, url_for, g, session
from datetime import datetime, timedelta
from functools import wraps
from html import escape
from urllib.parse import quote
import subprocess
import shutil
import pwd
import os
import re
import json
import time
import hmac
import hashlib
import secrets
import uuid
import base64

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 16 * 1024  # los formularios son pequeños

# ──────────────────────────────────────────────────────────────
#  CONFIGURACIÓN  (se recomienda definir PANEL_USER / PANEL_PASS
#  como variables de entorno en vez de dejarlos en el código)
# ──────────────────────────────────────────────────────────────
# Valores iniciales solo si aún no hay archivo de auth hasheado
_DEFAULT_USER = os.environ.get("PANEL_USER", "CHADGT")
_DEFAULT_PASS = os.environ.get("PANEL_PASS", "123456")
HOST = os.environ.get("PANEL_HOST", "0.0.0.0")   # usa 127.0.0.1 si pones Nginx delante
PORT = int(os.environ.get("PANEL_PORT", "8181"))

BASE_DIR = "/etc/vps-manager"
BOT_DIR = os.path.join(BASE_DIR, "telegram_bot")
V2_FILE = os.path.join(BASE_DIR, "v2ray_users.json")
AUDIT_FILE = os.path.join(BASE_DIR, "panel_audit.log")
AUTH_FILE = os.path.join(BASE_DIR, "panel_auth.json")
SSHD_CONFIG = "/etc/ssh/sshd_config"

# Compatibilidad: código antiguo referenciaba USER/PASS
USER = _DEFAULT_USER
PASS = _DEFAULT_PASS

# ── Auth hasheada (PBKDF2-SHA256) ─────────────────────────────
_PBKDF2_ITERS = 200_000


def _hash_password(password: str) -> str:
    """Devuelve 'pbkdf2_sha256$iters$salt_b64$hash_b64' (nunca texto plano)."""
    salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, _PBKDF2_ITERS)
    return "pbkdf2_sha256$%d$%s$%s" % (
        _PBKDF2_ITERS,
        base64.b64encode(salt).decode("ascii"),
        base64.b64encode(dk).decode("ascii"),
    )


def _verify_password(password: str, stored: str) -> bool:
    """Compara contraseña con hash PBKDF2 o, en legado, con texto plano."""
    if not stored:
        return False
    if stored.startswith("pbkdf2_sha256$"):
        try:
            _, iters_s, salt_b64, hash_b64 = stored.split("$", 3)
            iters = int(iters_s)
            salt = base64.b64decode(salt_b64.encode("ascii"))
            expected = base64.b64decode(hash_b64.encode("ascii"))
            dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iters)
            return hmac.compare_digest(dk, expected)
        except Exception:
            return False
    # Legado: texto plano (solo hasta migrar)
    return hmac.compare_digest(password.encode("utf-8"), stored.encode("utf-8"))


def _load_auth_file():
    """Lee {user, hash} desde AUTH_FILE. None si no existe o es inválido."""
    try:
        with open(AUTH_FILE) as f:
            data = json.load(f)
        if isinstance(data, dict) and data.get("user") and data.get("hash"):
            return str(data["user"]), str(data["hash"])
    except Exception:
        pass
    return None


def _save_auth_file(username: str, password: str):
    """Guarda usuario + hash PBKDF2 (modo 0600)."""
    os.makedirs(BASE_DIR, exist_ok=True)
    payload = {
        "user": username,
        "hash": _hash_password(password),
        "updated": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }
    tmp = AUTH_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    os.replace(tmp, AUTH_FILE)
    try:
        os.chmod(AUTH_FILE, 0o600)
    except Exception:
        pass


def get_panel_user() -> str:
    auth = _load_auth_file()
    if auth:
        return auth[0]
    return _DEFAULT_USER


def get_panel_secret_material():
    """(username, stored_secret) — stored_secret es hash o pass legado."""
    auth = _load_auth_file()
    if auth:
        return auth
    return _DEFAULT_USER, _DEFAULT_PASS

# Sesión (cookie firmada). Si defines PANEL_SECRET las sesiones sobreviven a reinicios.
app.secret_key = os.environ.get("PANEL_SECRET") or secrets.token_hex(32)
app.config.update(
    SESSION_COOKIE_NAME="gp_session",
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=os.environ.get("PANEL_HTTPS") == "1",  # pon PANEL_HTTPS=1 si usas HTTPS
    PERMANENT_SESSION_LIFETIME=timedelta(hours=8),
)
IDLE_SECS = 7200  # cierra la sesión tras 2 h sin actividad

def csrf_token():
    if "csrf" not in session:
        session["csrf"] = secrets.token_hex(16)
    return session["csrf"]

def csrf_input():
    return f'<input type="hidden" name="csrf" value="{csrf_token()}">'

# Validaciones estrictas de entrada
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{2,31}$")
NAME_RE = re.compile(r"^[A-Za-z0-9 ._-]{1,40}$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
HOST_RE = re.compile(r"^[A-Za-z0-9.\-:]{1,253}$")

# ──────────────────────────────────────────────────────────────
#  UTILIDADES SEGURAS (sin shell: nada de f-strings en comandos)
# ──────────────────────────────────────────────────────────────
def run(args, stdin=None, timeout=15):
    """Ejecuta un comando como lista de argumentos (sin shell)."""
    try:
        r = subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=timeout)
        return r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()
    except Exception as e:
        return 1, str(e)

def audit(msg):
    """Registro de auditoría (nunca guarda contraseñas)."""
    try:
        with open(AUDIT_FILE, "a") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {request.remote_addr} {msg}\n")
        os.chmod(AUDIT_FILE, 0o600)
    except Exception:
        pass

# ──────────────────────────────────────────────────────────────
#  SISTEMA DE TOASTS (flash messages sin Flask flash)
# ──────────────────────────────────────────────────────────────
def toast(kind, msg):
    """Encola un toast para mostrarlo en la próxima página."""
    try:
        pending = session.get("toasts", [])
        pending.append({"k": kind, "m": msg})
        session["toasts"] = pending[-5:]  # máximo 5 en cola
    except Exception:
        pass

def render_toasts():
    """Renderiza los toasts pendientes y limpia la cola."""
    pending = session.pop("toasts", []) or []
    if not pending:
        return ""
    icons = {
        "ok": "✅",
        "err": "❌",
        "warn": "⚠️",
        "info": "ℹ️",
    }
    items = []
    for t in pending:
        k = t.get("k", "info")
        m = escape(str(t.get("m", "")))
        ic = icons.get(k, "ℹ️")
        items.append(f'<div class="toast toast-{k}" role="status">{ic} <span>{m}</span></div>')
    return f'<div class="toast-container" id="toastContainer">{"".join(items)}</div>'

# ──────────────────────────────────────────────────────────────
#  AUTENTICACIÓN + ANTI FUERZA BRUTA + CSRF + CABECERAS
# ──────────────────────────────────────────────────────────────
MAX_FAILS = 5
LOCK_SECS = 600
FAILS = {}  # ip -> (intentos, primer_intento)

def check_auth(username, password):
    stored_user, stored_secret = get_panel_secret_material()
    ok_u = hmac.compare_digest(username.encode("utf-8"), stored_user.encode("utf-8"))
    ok_p = _verify_password(password, stored_secret)
    if ok_u and ok_p:
        # Migración automática: si aún era texto plano (env), guardar hash
        if not stored_secret.startswith("pbkdf2_sha256$"):
            try:
                _save_auth_file(stored_user, password)
                audit("AUTH_MIGRATED_TO_HASH")
            except Exception:
                pass
        return True
    return False

def is_locked_out(ip):
    entry = FAILS.get(ip)
    if not entry:
        return False
    count, first = entry
    if time.time() - first > LOCK_SECS:
        FAILS.pop(ip, None)
        return False
    return count >= MAX_FAILS

def register_fail(ip):
    count, first = FAILS.get(ip, (0, time.time()))
    if time.time() - first > LOCK_SECS:
        count, first = 0, time.time()
    FAILS[ip] = (count + 1, first)

def too_many():
    body = ('<div class="empty" style="margin-top:60px"><h2>Demasiados intentos</h2>'
            '<p>Acceso bloqueado temporalmente. Inténtalo de nuevo en unos minutos.</p></div>')
    return Response(page("Bloqueado", body, minimal=True), 429, {"Retry-After": str(LOCK_SECS)})

def requires_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("auth"):
            return redirect(url_for("login"))
        now = time.time()
        if now - session.get("t", 0) > IDLE_SECS:
            session.clear()
            return redirect(url_for("login", expired=1))
        session["t"] = now
        return f(*args, **kwargs)
    return decorated

def csrf_protect(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        token = request.form.get("csrf", "")
        if not hmac.compare_digest(token.encode(), csrf_token().encode()):
            audit("CSRF_INVALIDO")
            toast("err", "Sesión inválida. Recarga el panel e inténtalo de nuevo.")
            return redirect(url_for("index"))
        return f(*args, **kwargs)
    return wrapper

@app.before_request
def _set_nonce():
    g.nonce = secrets.token_urlsafe(16)

@app.after_request
def _security_headers(resp):
    n = getattr(g, "nonce", "")
    resp.headers["Content-Security-Policy"] = (
        f"default-src 'none'; script-src 'nonce-{n}'; style-src 'unsafe-inline'; "
        "img-src data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
    )
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["Referrer-Policy"] = "no-referrer"
    resp.headers["Cache-Control"] = "no-store"
    return resp

def error_page(msg, code=400, redirect_home=True):
    """Muestra error con toast y opción de volver al panel."""
    toast("err", msg)
    if redirect_home:
        return redirect(url_for("index"))
    body = (
        '<div class="card" style="max-width:520px;margin:30px auto">'
        '<h3 style="color:var(--danger)">No se pudo completar</h3>'
        f'<p>{escape(msg)}</p><a href="/" class="btn btn-ghost">Volver al panel</a></div>'
    )
    return Response(page("Error", body), code)

# ──────────────────────────────────────────────────────────────
#  DISEÑO: ICONOS, CSS, JS, LAYOUT
# ──────────────────────────────────────────────────────────────
def _svg(path, size=20):
    return (f'<svg viewBox="0 0 24 24" width="{size}" height="{size}" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" '
            f'stroke-linejoin="round" aria-hidden="true">{path}</svg>')

I_SHIELD  = _svg('<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6l8-3z"/><path d="M9 12l2 2 4-4"/>', 24)
I_PALETTE = _svg('<circle cx="13.5" cy="6.5" r="1"/><circle cx="17.5" cy="10.5" r="1"/><circle cx="8.5" cy="7.5" r="1"/><circle cx="6.5" cy="12.5" r="1"/><path d="M12 3a9 9 0 100 18c1.1 0 1.8-.9 1.8-1.8 0-.5-.2-.9-.5-1.2-.3-.3-.5-.7-.5-1.2 0-1 .8-1.8 1.8-1.8H17a4 4 0 004-4c0-4.4-4-8-9-8z"/>')
I_CHEVRON = _svg('<path d="M6 9l6 6 6-6"/>', 16)
I_ONLINE  = _svg('<path d="M5 12.5a10 10 0 0114 0"/><path d="M8.5 16a5 5 0 017 0"/><circle cx="12" cy="19" r="1"/>', 22)
I_CLOCK   = _svg('<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>', 22)
I_BAN     = _svg('<circle cx="12" cy="12" r="9"/><path d="M5.6 5.6l12.8 12.8"/>', 22)
I_USERS   = _svg('<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.5-3.5 3-5.5 6.5-5.5s6 2 6.5 5.5"/><path d="M16 4.5a3.5 3.5 0 010 7"/><path d="M18 14.8c2 .6 3.3 2.3 3.5 5.2"/>', 22)
I_MENU    = _svg('<path d="M4 6h16M4 12h16M4 18h16"/>', 22)
I_LOGOUT  = _svg('<path d="M9 21H5a2 2 0 01-2-2V5a2 2 0 012-2h4"/><path d="M16 17l5-5-5-5"/><path d="M21 12H9"/>', 20)
I_SERVER  = _svg('<rect x="3" y="4" width="18" height="6" rx="1.5"/><rect x="3" y="14" width="18" height="6" rx="1.5"/><path d="M7 7h.01M7 17h.01"/>', 18)
I_BOLT22  = _svg('<path d="M13 2L4 14h7l-1 8 9-12h-7l1-8z"/>', 22)
I_CAL     = _svg('<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>', 22)
I_GRID    = _svg('<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>', 18)
I_TERM    = _svg('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9l3 3-3 3"/><path d="M13 15h4"/>', 18)
I_BOLT    = _svg('<path d="M13 2L4 14h7l-1 8 9-12h-7l1-8z"/>', 18)
I_RESELL  = _svg('<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.5-3.5 3-5.5 6.5-5.5s6 2 6.5 5.5"/><path d="M16 4.5a3.5 3.5 0 010 7"/><path d="M18 14.8c2 .6 3.3 2.3 3.5 5.2"/>', 18)
I_SEARCH  = _svg('<circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/>', 18)

# Aplica el tema antes de pintar (evita parpadeo)
THEME_INIT = """<script>(function(){var t='dark';try{t=localStorage.getItem('gp-theme')||(window.matchMedia&&matchMedia('(prefers-color-scheme: light)').matches?'light':'dark');}catch(e){}document.documentElement.setAttribute('data-theme',t);})();</script>"""

CSS = """
:root{--radius:14px;--font:'Inter','Segoe UI',system-ui,-apple-system,Roboto,sans-serif;--head-font:var(--font);--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;--on-accent:#fff;}

/* ───── TEMA CLARO ───── */
:root[data-theme="light"]{color-scheme:light;
  --bg:#f3f5f9;--surface:#ffffff;--surface-2:#f7f9fc;--border:#e3e8f0;--text:#0f172a;--muted:#64748b;
  --accent:#2563eb;--ok:#16a34a;--warn:#d97706;--danger:#dc2626;--shadow:0 1px 2px rgba(15,23,42,.05),0 8px 24px rgba(15,23,42,.06);}

/* ───── TEMA OSCURO ───── */
:root[data-theme="dark"]{color-scheme:dark;
  --bg:#0b1220;--surface:#121a2c;--surface-2:#0e1626;--border:#1f2a44;--text:#e6ebf5;--muted:#8a98b3;
  --accent:#4f8cff;--ok:#22c55e;--warn:#f59e0b;--danger:#ef4444;--shadow:0 8px 30px rgba(0,0,0,.35);}

/* ───── TEMA PAPEL ───── */
:root[data-theme="paper"]{color-scheme:light;
  --bg:#efe5d0;--surface:#fbf6ea;--surface-2:#f4ead3;--border:#d8c7a3;--text:#3b2f20;--muted:#7a6a52;
  --accent:#8b4a2b;--ok:#4d7c3a;--warn:#b7791f;--danger:#a63a2f;--radius:6px;
  --font:Georgia,'Palatino Linotype','Book Antiqua',serif;--head-font:Georgia,'Palatino Linotype',serif;
  --shadow:2px 3px 0 rgba(120,90,50,.18);}

/* ───── TEMA GAMING ───── */
:root[data-theme="gaming"]{color-scheme:dark;
  --bg:#07050f;--surface:#110c24;--surface-2:#0b0818;--border:#3a1d6e;--text:#eaf6ff;--muted:#8f86b8;
  --accent:#00f0ff;--accent-2:#ff2bd6;--ok:#39ff88;--warn:#ffb800;--danger:#ff3860;--on-accent:#00161a;--radius:4px;
  --font:'Rajdhani','Segoe UI',system-ui,sans-serif;--head-font:'Orbitron','Rajdhani',system-ui,sans-serif;
  --shadow:0 0 0 1px rgba(0,240,255,.08),0 0 28px rgba(255,43,214,.08);}

*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{margin:0;min-height:100vh;display:flex;flex-direction:column;background:var(--bg);color:var(--text);
  font-family:var(--font);line-height:1.5;transition:background .25s,color .25s;-webkit-font-smoothing:antialiased}
:root[data-theme="paper"] body{background-image:repeating-linear-gradient(0deg,transparent 0 31px,rgba(139,100,50,.08) 31px 32px)}
:root[data-theme="gaming"] body{background-image:radial-gradient(900px 400px at 85% -10%,rgba(255,43,214,.16),transparent 60%),radial-gradient(800px 400px at -10% 0%,rgba(0,240,255,.12),transparent 60%)}
a{color:inherit}

/* ───── TOPBAR ───── */
.topbar{position:sticky;top:0;z-index:50;background:var(--surface);border-bottom:1px solid var(--border);box-shadow:var(--shadow)}
.topbar-in{max-width:1100px;margin:0 auto;padding:12px 16px;display:flex;align-items:center;justify-content:space-between;gap:12px}
.brand{display:flex;align-items:center;gap:10px;text-decoration:none}
.brand-ic{width:40px;height:40px;border-radius:10px;display:grid;place-items:center;background:var(--accent);color:var(--on-accent)}
.brand-t{font-family:var(--head-font);font-weight:700;font-size:17px;letter-spacing:.3px;line-height:1.1}
.brand-s{font-size:12px;color:var(--muted)}
:root[data-theme="gaming"] .brand-t{text-transform:uppercase;letter-spacing:2px;color:var(--accent);text-shadow:0 0 12px rgba(0,240,255,.55)}
:root[data-theme="gaming"] .brand-ic{box-shadow:0 0 18px rgba(0,240,255,.6)}

/* ───── DROPDOWN DE TEMAS ───── */
.dd{position:relative}
.dd-btn{display:flex;align-items:center;gap:8px;padding:8px 12px;border-radius:10px;border:1px solid var(--border);
  background:var(--surface-2);color:var(--text);font:inherit;font-size:14px;font-weight:600;cursor:pointer;transition:.15s}
.dd-btn:hover{border-color:var(--accent);color:var(--accent)}
.dd-btn:focus-visible,.btn:focus-visible,input:focus-visible,.dd-item:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.dd-menu{display:none;position:absolute;right:0;top:calc(100% + 8px);min-width:200px;padding:6px;border-radius:12px;
  background:var(--surface);border:1px solid var(--border);box-shadow:var(--shadow)}
.dd-menu.open{display:block;animation:pop .14s ease-out}
@keyframes pop{from{opacity:0;transform:translateY(-4px)}to{opacity:1;transform:none}}
.dd-title{padding:6px 10px 4px;font-size:11px;font-weight:700;letter-spacing:.8px;text-transform:uppercase;color:var(--muted)}
.dd-item{display:flex;align-items:center;gap:10px;width:100%;padding:9px 10px;border:0;border-radius:8px;background:none;
  color:var(--text);font:inherit;font-size:14px;text-align:left;cursor:pointer}
.dd-item:hover{background:var(--surface-2)}
.dd-item[aria-checked="true"]{background:var(--surface-2);font-weight:700;color:var(--accent)}
.dd-item[aria-checked="true"]::after{content:"✓";margin-left:auto}
.sw{width:18px;height:18px;border-radius:50%;border:1px solid rgba(128,128,128,.4);flex:none}
.sw-light{background:linear-gradient(135deg,#fff 50%,#2563eb 50%)}
.sw-dark{background:linear-gradient(135deg,#121a2c 50%,#4f8cff 50%)}
.sw-paper{background:linear-gradient(135deg,#f4ead3 50%,#8b4a2b 50%)}
.sw-gaming{background:linear-gradient(135deg,#ff2bd6 50%,#00f0ff 50%)}

/* ───── CONTENEDOR ───── */
.container{flex:1;width:100%;max-width:1100px;margin:0 auto;padding:22px 16px 10px}
.section-head{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;margin:30px 0 14px}
.section-title{margin:0;font-family:var(--head-font);font-size:18px;font-weight:700;display:flex;align-items:center;gap:10px}
:root[data-theme="gaming"] .section-title{text-transform:uppercase;letter-spacing:1.5px;color:var(--accent)}
.count{font-size:12px;font-weight:700;padding:2px 9px;border-radius:999px;background:var(--surface-2);border:1px solid var(--border);color:var(--muted)}

/* ───── ESTADÍSTICAS ───── */
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
.stat{display:flex;align-items:center;gap:14px;padding:16px;background:var(--surface);border:1px solid var(--border);
  border-radius:var(--radius);box-shadow:var(--shadow)}
.stat-ic{width:44px;height:44px;border-radius:12px;display:grid;place-items:center;flex:none;color:var(--c);
  background:color-mix(in srgb,var(--c) 14%,transparent)}
.stat.ok{--c:var(--ok)}.stat.warn{--c:var(--warn)}.stat.danger{--c:var(--danger)}.stat.accent{--c:var(--accent)}
.stat-num{font-family:var(--head-font);font-size:26px;font-weight:800;line-height:1}
.stat-lbl{font-size:13px;color:var(--muted);margin-top:4px}
:root[data-theme="gaming"] .stat{border-color:color-mix(in srgb,var(--c) 45%,transparent)}
:root[data-theme="gaming"] .stat-num{color:var(--c);text-shadow:0 0 12px var(--c)}

/* ───── FORMULARIOS ───── */
.forms{display:grid;grid-template-columns:1.2fr 1fr;gap:14px;align-items:start}
.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:18px;box-shadow:var(--shadow);transition:border-color .15s,transform .15s}
.card h3{margin:0 0 14px;font-family:var(--head-font);font-size:16px}
.fields{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.fields .full{grid-column:1/-1}
label{display:block;font-size:12px;font-weight:600;color:var(--muted);margin-bottom:5px}
input[type="text"],input[type="password"],input[type="number"]{width:100%;padding:11px 12px;border-radius:10px;
  border:1px solid var(--border);background:var(--surface-2);color:var(--text);font:inherit;font-size:14px;transition:.15s}
input::placeholder{color:var(--muted);opacity:.7}
input:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 22%,transparent)}
:root[data-theme="gaming"] input:focus{box-shadow:0 0 12px rgba(0,240,255,.5)}

/* ───── BOTONES ───── */
.btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;padding:10px 14px;border-radius:10px;border:1px solid transparent;
  font:inherit;font-size:13px;font-weight:700;text-decoration:none;cursor:pointer;transition:.15s;white-space:nowrap}
.btn:hover{filter:brightness(1.08);transform:translateY(-1px)}
.btn-block{width:100%;padding:12px;font-size:14px}
.btn-primary{background:var(--accent);color:var(--on-accent)}
.btn-success{background:var(--ok);color:#fff}
:root[data-theme="gaming"] .btn-success{color:#04200f}
.btn-warn{background:color-mix(in srgb,var(--warn) 15%,transparent);color:var(--warn);border-color:color-mix(in srgb,var(--warn) 40%,transparent)}
.btn-danger{background:color-mix(in srgb,var(--danger) 13%,transparent);color:var(--danger);border-color:color-mix(in srgb,var(--danger) 40%,transparent)}
.btn-ghost{background:var(--surface-2);color:var(--text);border-color:var(--border)}
:root[data-theme="gaming"] .btn{text-transform:uppercase;letter-spacing:1px;clip-path:polygon(8px 0,100% 0,100% calc(100% - 8px),calc(100% - 8px) 100%,0 100%,0 8px)}
:root[data-theme="gaming"] .btn-primary{box-shadow:0 0 16px rgba(0,240,255,.45)}

/* ───── TARJETAS DE USUARIO ───── */
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:14px}
.card:hover{border-color:var(--accent)}
:root[data-theme="gaming"] .card:hover{box-shadow:0 0 22px rgba(0,240,255,.25)}
.u-head{display:flex;align-items:center;gap:12px;margin-bottom:14px}
.avatar{width:42px;height:42px;border-radius:50%;display:grid;place-items:center;flex:none;font-weight:800;font-size:17px;
  color:var(--on-accent);background:var(--accent)}
.u-name{margin:0;font-size:17px;font-weight:700;word-break:break-all;line-height:1.2}
.u-sub{font-size:12px;color:var(--muted)}
.tag{margin-left:auto;font-size:11px;font-weight:800;letter-spacing:.6px;padding:3px 9px;border-radius:999px;
  color:var(--c);background:color-mix(in srgb,var(--c) 14%,transparent);border:1px solid color-mix(in srgb,var(--c) 35%,transparent)}
.c-ok{--c:var(--ok)}.c-warn{--c:var(--warn)}.c-danger{--c:var(--danger)}.c-muted{--c:var(--muted)}.c-accent{--c:var(--accent)}
.row{display:flex;justify-content:space-between;align-items:center;padding:8px 0;border-top:1px dashed var(--border);font-size:14px}
.row span:first-child{color:var(--muted)}
.dot{display:inline-flex;align-items:center;gap:7px;font-weight:700;color:var(--c)}
.dot::before{content:"";width:8px;height:8px;border-radius:50%;background:var(--c);box-shadow:0 0 0 3px color-mix(in srgb,var(--c) 22%,transparent)}
.actions{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-top:14px}
.actions .btn{padding:9px 6px;font-size:12px}
.credits{font-family:var(--head-font);font-size:22px;font-weight:800;color:var(--accent)}

/* ───── MODALES ───── */
.create-bar{display:flex;gap:10px;flex-wrap:wrap}
.modal{position:fixed;inset:0;z-index:100;display:none;align-items:center;justify-content:center;padding:16px;
  background:rgba(0,0,0,.55);backdrop-filter:blur(3px);-webkit-backdrop-filter:blur(3px)}
.modal.open{display:flex;animation:fade .15s ease-out}
@keyframes fade{from{opacity:0}to{opacity:1}}
.modal-box{width:100%;max-width:460px;max-height:92vh;overflow:auto;padding:20px;background:var(--surface);
  border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow);animation:pop .18s ease-out}
:root[data-theme="gaming"] .modal-box{border-color:var(--accent);box-shadow:0 0 30px rgba(0,240,255,.25),0 0 60px rgba(255,43,214,.12)}
.modal-head{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:16px}
.modal-head h3{margin:0;font-family:var(--head-font);font-size:18px}
.modal-x{width:32px;height:32px;border:0;border-radius:8px;background:var(--surface-2);color:var(--muted);font-size:20px;line-height:1;cursor:pointer}
.modal-x:hover{color:var(--text)}
.modal-foot{display:flex;gap:10px;justify-content:flex-end;margin-top:4px}
.modal-foot .btn{flex:1}

/* ───── CONEXIONES ───── */
.meter{height:6px;margin:0 0 6px;border-radius:999px;background:var(--surface-2);border:1px solid var(--border);overflow:hidden}
.meter i{display:block;height:100%;width:var(--w);background:var(--c);border-radius:999px;transition:width .3s}
.conn{font-weight:800;color:var(--c)}

.actions form{margin:0;display:flex}.actions form .btn,.actions>.btn{width:100%}
.actions.two{grid-template-columns:1fr 1fr}
.actions.four{grid-template-columns:repeat(auto-fit,minmax(90px,1fr))}
.mon-row{display:flex;justify-content:space-between;align-items:center;padding:8px 0;font-size:14px}
.mon-row span{color:var(--muted)}
.share-card{margin-bottom:18px;border-color:var(--accent)}
.share-card textarea{color:var(--text);min-height:180px}
.mono{font-family:var(--mono);font-size:13px}

/* ───── MENÚ LATERAL DESPLEGABLE ───── */
[hidden]{display:none!important}
.top-left{display:flex;align-items:center;gap:12px;min-width:0}
.icon-btn{width:40px;height:40px;flex:none;display:grid;place-items:center;border:1px solid var(--border);border-radius:10px;
  background:var(--surface-2);color:var(--text);cursor:pointer;transition:.15s}
.icon-btn:hover{border-color:var(--accent);color:var(--accent)}
.icon-btn:focus-visible,.nav-item:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.drawer-overlay{position:fixed;inset:0;z-index:90;background:rgba(0,0,0,.5);opacity:0;pointer-events:none;transition:opacity .22s}
.drawer-overlay.open{opacity:1;pointer-events:auto}
.drawer{position:fixed;top:0;left:0;bottom:0;z-index:95;width:290px;max-width:85vw;display:flex;flex-direction:column;gap:4px;
  padding:14px;background:var(--surface);border-right:1px solid var(--border);box-shadow:var(--shadow);overflow-y:auto;
  transform:translateX(-105%);visibility:hidden;transition:transform .25s ease,visibility 0s linear .25s}
.drawer.open{transform:none;visibility:visible;transition:transform .25s ease,visibility 0s}
:root[data-theme="gaming"] .drawer{border-right-color:var(--accent);box-shadow:0 0 34px rgba(0,240,255,.28)}
.drawer-head{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:2px 4px 12px;margin-bottom:6px;border-bottom:1px solid var(--border)}
.drawer-brand{display:flex;align-items:center;gap:10px;font-family:var(--head-font);font-weight:700;font-size:16px}
.drawer-brand .brand-ic{width:34px;height:34px}
.side-title{padding:6px 10px;font-size:11px;font-weight:700;letter-spacing:.8px;text-transform:uppercase;color:var(--muted)}
.nav-item{display:flex;align-items:center;gap:12px;width:100%;padding:12px;border:0;border-radius:10px;background:none;
  color:var(--muted);font:inherit;font-size:15px;font-weight:600;text-align:left;cursor:pointer;transition:.15s}
.nav-item:hover{background:var(--surface-2);color:var(--text)}
.nav-item[aria-current="page"]{background:color-mix(in srgb,var(--accent) 14%,transparent);color:var(--accent)}
.nav-item .n{margin-left:auto;min-width:24px;text-align:center;font-size:11px;font-weight:800;padding:2px 8px;border-radius:999px;
  background:var(--surface-2);border:1px solid var(--border);color:var(--muted)}
.nav-item[aria-current="page"] .n{color:var(--accent);border-color:color-mix(in srgb,var(--accent) 40%,transparent)}
:root[data-theme="gaming"] .nav-item[aria-current="page"]{box-shadow:inset 3px 0 0 var(--accent),0 0 16px rgba(0,240,255,.2)}
.drawer-foot{margin-top:auto;padding:12px 6px 2px;border-top:1px solid var(--border);font-size:12px;color:var(--muted)}
.searchbar{margin-top:20px}.searchbar .search{max-width:440px}
.view .section-head:first-child{margin-top:22px}

/* ───── ESTADÍSTICAS POR SECCIÓN ───── */
.stats.three{grid-template-columns:repeat(3,1fr)}
.stats:not([hidden]) ~ .stats:not([hidden]){margin-top:12px}
@media(max-width:860px){.stats.three{grid-template-columns:repeat(2,1fr)}.stats.three .stat:last-child{grid-column:1/-1}}

/* ───── LOGIN / SALIR / SERVICIOS ───── */
.top-right{display:flex;align-items:center;gap:8px}
.logout-form{margin:0}
.icon-btn.danger:hover{border-color:var(--danger);color:var(--danger)}
.svc-grid{grid-template-columns:repeat(auto-fill,minmax(260px,1fr))}
.svc{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:14px 16px}
.svc-name{font-weight:700;font-size:15px}
.login-wrap{min-height:58vh;display:grid;place-items:center;padding:20px 0}
.login-card{width:100%;max-width:400px;padding:28px}
.login-ic{width:48px;height:48px;margin-bottom:14px}
.login-card h2{margin:0;font-family:var(--head-font)}
.muted{color:var(--muted);margin:4px 0 0}
.login-card label{margin-top:16px}
.alert{padding:10px 12px;margin-top:14px;border-radius:10px;font-size:14px;color:var(--c);
  background:color-mix(in srgb,var(--c) 12%,transparent);border:1px solid color-mix(in srgb,var(--c) 35%,transparent)}
.alert-err{--c:var(--danger)}.alert-ok{--c:var(--ok)}
.pw{position:relative}.pw input{padding-right:84px}
.pw-toggle{position:absolute;right:6px;top:50%;transform:translateY(-50%);border:0;background:none;color:var(--accent);
  font:inherit;font-size:12px;font-weight:700;cursor:pointer;padding:6px 8px}
.drawer-foot form{margin:0}

/* ───── BÚSQUEDA ───── */
.search{position:relative;min-width:230px}
.search svg{position:absolute;left:11px;top:50%;transform:translateY(-50%);color:var(--muted)}
.search input{padding-left:36px}

/* ───── VACÍO / RESULTADO ───── */
.empty{padding:26px;text-align:center;color:var(--muted);background:var(--surface);border:1px dashed var(--border);border-radius:var(--radius)}
.empty h2{color:var(--text);margin:0 0 6px}
textarea{width:100%;min-height:120px;padding:12px;border-radius:10px;border:1px solid var(--border);background:var(--surface-2);
  color:var(--accent);font-family:var(--mono);font-size:13px;resize:vertical}
.kv{display:grid;gap:4px;margin:12px 0 16px;font-size:14px}.kv b{color:var(--muted);font-weight:600}
.result-actions{display:flex;gap:10px;margin-top:14px;flex-wrap:wrap}

/* ───── FOOTER ───── */
.footer{margin-top:40px;background:var(--surface);border-top:1px solid var(--border)}
.footer-in{max-width:1100px;margin:0 auto;padding:18px 16px;display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;font-size:13px;color:var(--muted)}
.footer-brand{display:flex;align-items:center;gap:8px;font-weight:700;color:var(--text)}
.footer-brand svg{color:var(--accent)}
.footer-live{display:inline-flex;align-items:center;gap:7px}
.footer-live::before{content:"";width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 0 3px color-mix(in srgb,var(--ok) 25%,transparent)}
:root[data-theme="gaming"] .footer{border-top:1px solid var(--accent-2);box-shadow:0 -6px 24px rgba(255,43,214,.12)}

/* ───── RESPONSIVE ───── */
@media(max-width:860px){.stats{grid-template-columns:repeat(2,1fr)}.forms{grid-template-columns:1fr}}
@media(max-width:520px){.brand-s{display:none}.fields{grid-template-columns:1fr}.grid{grid-template-columns:1fr}
  .dd-label{display:none}.search{width:100%}.footer-in{justify-content:center;text-align:center}}

/* ───── LOGIN MINIMALISTA ───── */
.topbar-minimal .brand-s{opacity:.85}
.topbar-minimal .top-left{min-width:0}
.login-wrap{min-height:calc(100vh - 260px)}

/* ───── TOASTS ───── */
.toast-container{position:fixed;top:78px;right:18px;z-index:200;display:flex;flex-direction:column;gap:10px;
  max-width:min(92vw,380px);pointer-events:none}
.toast{display:flex;align-items:flex-start;gap:10px;padding:12px 14px;border-radius:12px;font-size:14px;font-weight:600;
  background:var(--surface);color:var(--text);border:1px solid var(--border);box-shadow:var(--shadow);
  pointer-events:auto;opacity:0;transform:translateX(20px);animation:toastIn .22s ease-out forwards;line-height:1.35}
.toast span{flex:1;word-break:break-word}
@keyframes toastIn{to{opacity:1;transform:none}}
.toast.out{animation:toastOut .22s ease-in forwards}
@keyframes toastOut{to{opacity:0;transform:translateX(20px)}}
.toast-ok{border-color:color-mix(in srgb,var(--ok) 45%,var(--border));box-shadow:0 8px 24px color-mix(in srgb,var(--ok) 22%,transparent)}
.toast-err{border-color:color-mix(in srgb,var(--danger) 45%,var(--border));box-shadow:0 8px 24px color-mix(in srgb,var(--danger) 22%,transparent)}
.toast-warn{border-color:color-mix(in srgb,var(--warn) 45%,var(--border));box-shadow:0 8px 24px color-mix(in srgb,var(--warn) 22%,transparent)}
.toast-info{border-color:color-mix(in srgb,var(--accent) 45%,var(--border));box-shadow:0 8px 24px color-mix(in srgb,var(--accent) 22%,transparent)}
:root[data-theme="gaming"] .toast-ok{box-shadow:0 0 22px rgba(57,255,136,.45)}
:root[data-theme="gaming"] .toast-err{box-shadow:0 0 22px rgba(255,56,96,.45)}
:root[data-theme="gaming"] .toast-warn{box-shadow:0 0 22px rgba(255,184,0,.45)}
:root[data-theme="gaming"] .toast-info{box-shadow:0 0 22px rgba(0,240,255,.45)}
"""

JS = """
(function(){
  var root=document.documentElement,
      btn=document.getElementById('themeBtn'),
      menu=document.getElementById('themeMenu'),
      label=document.getElementById('themeLabel'),
      names={light:'Claro',dark:'Oscuro',paper:'Papel',gaming:'Gaming'};
  function mark(t){
    menu.querySelectorAll('[data-t]').forEach(function(b){b.setAttribute('aria-checked', b.dataset.t===t);});
    if(label) label.textContent=names[t]||'Tema';
  }
  function closeMenu(){menu.classList.remove('open');btn.setAttribute('aria-expanded','false');}
  function setTheme(t){
    root.setAttribute('data-theme',t);
    try{localStorage.setItem('gp-theme',t);}catch(e){}
    mark(t);
  }
  mark(root.getAttribute('data-theme'));
  btn.addEventListener('click',function(e){
    e.stopPropagation();
    var open=menu.classList.toggle('open');
    btn.setAttribute('aria-expanded',open);
  });
  menu.addEventListener('click',function(e){
    var b=e.target.closest('[data-t]');
    if(b){setTheme(b.dataset.t);closeMenu();}
  });
  document.addEventListener('click',function(e){if(!menu.contains(e.target))closeMenu();});
  document.addEventListener('keydown',function(e){if(e.key==='Escape'){closeMenu();closeModals();setDrawer(false);}});

  function openModal(id){
    var m=document.getElementById(id); if(!m) return;
    m.classList.add('open'); document.body.style.overflow='hidden';
    var i=m.querySelector('input'); if(i) setTimeout(function(){i.focus();},50);
  }
  function closeModals(){
    document.querySelectorAll('.modal.open').forEach(function(m){m.classList.remove('open');});
    document.body.style.overflow='';
  }
  document.querySelectorAll('[data-open]').forEach(function(b){
    b.addEventListener('click',function(){closeMenu();openModal(b.dataset.open);});
  });
  document.querySelectorAll('[data-close]').forEach(function(b){b.addEventListener('click',closeModals);});
  document.querySelectorAll('.modal').forEach(function(m){
    m.addEventListener('mousedown',function(e){if(e.target===m)closeModals();});
  });

  var q=document.getElementById('search');
  if(q){q.addEventListener('input',function(){
    var v=q.value.trim().toLowerCase();
    document.querySelectorAll('[data-name]').forEach(function(c){
      c.style.display=c.dataset.name.indexOf(v)>-1?'':'none';
    });
  });}

  var menuBtn=document.getElementById('menuBtn'),
      drawer=document.getElementById('drawer'),
      drawerOv=document.getElementById('drawerOv');
  function setDrawer(open){
    if(!drawer||!menuBtn) return;
    var was=drawer.classList.contains('open');
    drawer.classList.toggle('open',open);
    drawerOv.classList.toggle('open',open);
    drawer.setAttribute('aria-hidden',open?'false':'true');
    menuBtn.setAttribute('aria-expanded',open?'true':'false');
    document.body.style.overflow=open?'hidden':'';
    if(open){var a=drawer.querySelector('[aria-current]')||drawer.querySelector('.nav-item');if(a)a.focus();}
    else if(was){menuBtn.focus();}
  }
  if(menuBtn){
    menuBtn.addEventListener('click',function(){closeMenu();setDrawer(!drawer.classList.contains('open'));});
    drawerOv.addEventListener('click',function(){setDrawer(false);});
    document.getElementById('drawerClose').addEventListener('click',function(){setDrawer(false);});
  }

  var navBtns=document.querySelectorAll('[data-nav]'), views=document.querySelectorAll('.view');
  function showView(v){
    if(!document.querySelector('[data-nav="'+v+'"]')) v='all';
    views.forEach(function(s){
      if(v==='all') s.hidden = (s.dataset.view==='services' || s.dataset.view==='monitor');
      else s.hidden = (s.dataset.view !== v);
    });
    navBtns.forEach(function(b){
      if(b.dataset.nav===v) b.setAttribute('aria-current','page'); else b.removeAttribute('aria-current');
    });
    document.querySelectorAll('[data-stats]').forEach(function(s){s.hidden=!(v==='all'||s.dataset.stats===v);});
    var sw=document.getElementById('searchWrap'); if(sw) sw.style.display=(v==='resellers'||v==='services'||v==='monitor')?'none':'';
    try{localStorage.setItem('gp-view',v);}catch(e){}
    if(window.history&&history.replaceState) history.replaceState(null,'','#'+v);
    if(v==='monitor') startStats(); else stopStats();
  }
  if(navBtns.length){
    navBtns.forEach(function(b){b.addEventListener('click',function(){showView(b.dataset.nav);setDrawer(false);window.scrollTo(0,0);});});
    var start=(location.hash||'').replace('#','');
    if(!start){try{start=localStorage.getItem('gp-view')||'all';}catch(e){start='all';}}
    showView(start);
  }
  document.querySelectorAll('[data-copy]').forEach(function(b){
    b.addEventListener('click',function(){
      var txt=b.dataset.copy, old=b.textContent;
      function done(){b.textContent='¡Copiado!';setTimeout(function(){b.textContent=old;},1800);}
      if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(txt).then(done);}
      else{var t=document.createElement('textarea');t.value=txt;document.body.appendChild(t);t.select();
        try{document.execCommand('copy');}catch(e){} document.body.removeChild(t);done();}
    });
  });
  document.querySelectorAll('[data-reload]').forEach(function(b){b.addEventListener('click',function(){location.reload();});});
  document.querySelectorAll('[data-toggle-pw]').forEach(function(b){
    b.addEventListener('click',function(){
      var i=b.parentNode.querySelector('input'), show=i.type==='password';
      i.type=show?'text':'password'; b.textContent=show?'Ocultar':'Mostrar';
    });
  });
  document.querySelectorAll('form[data-confirm]').forEach(function(f){
    f.addEventListener('submit',function(e){if(!confirm(f.dataset.confirm))e.preventDefault();});
  });

  // ── Editar SSH ──
  document.querySelectorAll('[data-open-edit]').forEach(function(b){
    b.addEventListener('click',function(){
      var u=b.dataset.user, form=document.getElementById('formEdit');
      if(!form) return;
      form.action='/edit_ssh/'+encodeURIComponent(u);
      document.getElementById('editUserLabel').value=u;
      document.getElementById('eDays').value=b.dataset.days||'30';
      document.getElementById('eLimit').value=b.dataset.limit||'1';
      document.getElementById('ePass').value='';
      openModal('modalEdit');
    });
  });

  // ── TOASTS: auto-cierre ──
  var tc=document.getElementById('toastContainer');
  if(tc){
    tc.querySelectorAll('.toast').forEach(function(t){
      setTimeout(function(){
        t.classList.add('out');
        t.addEventListener('animationend',function(){t.remove();});
      },4200);
    });
  }

  // ── Monitor VPS (poll + gráfica simple de red) ──
  var statsTimer=null, netHist=[], lastNet=null;
  function hb(n){
    n=Number(n)||0; var u=['B','KB','MB','GB','TB'];
    for(var i=0;i<u.length;i++){ if(n<1024||i===u.length-1) return (i?n.toFixed(1):Math.round(n))+' '+u[i]; n/=1024; }
  }
  function barColor(pct){
    if(pct>=90) return 'var(--danger)';
    if(pct>=70) return 'var(--warn)';
    return 'var(--ok)';
  }
  function paintNetChart(){
    var c=document.getElementById('netChart'); if(!c||!netHist.length) return;
    var ctx=c.getContext('2d'), w=c.width, h=c.height, max=1;
    netHist.forEach(function(p){ if(p.rx>max)max=p.rx; if(p.tx>max)max=p.tx; });
    ctx.clearRect(0,0,w,h);
    function line(key,color){
      ctx.beginPath(); ctx.strokeStyle=color; ctx.lineWidth=2;
      netHist.forEach(function(p,i){
        var x=i/(Math.max(netHist.length-1,1))*(w-8)+4;
        var y=h-4-(p[key]/max)*(h-12);
        if(i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
      });
      ctx.stroke();
    }
    line('rx','#22c55e'); line('tx','#4f8cff');
  }
  function applyStats(s){
    var set=function(id,v){ var el=document.getElementById(id); if(el) el.textContent=v; };
    set('mCpu', s.cpu+'%'); set('mCpu2', s.cpu+'%');
    set('mRam', s.ram_pct+'%'); set('mRam2', s.ram_pct+'%');
    set('mRamTxt', hb(s.ram_used)+' / '+hb(s.ram_total));
    set('mDisk', s.disk_pct+'%'); set('mDisk2', s.disk_pct+'%');
    set('mDiskTxt', hb(s.disk_used)+' / '+hb(s.disk_total));
    set('mUp', s.uptime_human);
    set('mLoad', s.load1.toFixed(2)+' · '+s.load5.toFixed(2)+' · '+s.load15.toFixed(2));
    set('mRx', hb(s.net_rx)); set('mTx', hb(s.net_tx)); set('mNet', hb(s.net_rx+s.net_tx));
    [['bCpu',s.cpu],['bRam',s.ram_pct],['bDisk',s.disk_pct]].forEach(function(x){
      var el=document.getElementById(x[0]); if(!el) return;
      el.style.setProperty('--w', x[1]+'%');
      el.style.background=barColor(x[1]);
    });
    var rateRx=0, rateTx=0;
    if(lastNet && s.ts>lastNet.ts){
      var dt=Math.max(1, s.ts-lastNet.ts);
      rateRx=Math.max(0,(s.net_rx-lastNet.rx)/dt);
      rateTx=Math.max(0,(s.net_tx-lastNet.tx)/dt);
    }
    lastNet={rx:s.net_rx, tx:s.net_tx, ts:s.ts};
    netHist.push({rx:rateRx, tx:rateTx});
    if(netHist.length>40) netHist.shift();
    paintNetChart();
  }
  function fetchStats(){
    fetch('/api/stats',{credentials:'same-origin'}).then(function(r){return r.json();}).then(applyStats).catch(function(){});
  }
  function startStats(){
    if(statsTimer) return;
    fetchStats();
    statsTimer=setInterval(fetchStats, 5000);
  }
  function stopStats(){ if(statsTimer){ clearInterval(statsTimer); statsTimer=null; } }
  var btnR=document.getElementById('statsRefresh');
  if(btnR) btnR.addEventListener('click', fetchStats);

})();

"""

TOPBAR = f"""
<header class="topbar"><div class="topbar-in">
  <div class="top-left">%%MENU%%<a class="brand" href="/">
    <span class="brand-ic">{I_SHIELD}</span>
    <span><div class="brand-t">PANEL MANAGER</div><div class="brand-s">Administración VPS</div></span>
  </a></div>
  <div class="top-right">%%LOGOUT%%
  <div class="dd">
    <button class="dd-btn" id="themeBtn" aria-haspopup="true" aria-expanded="false" aria-label="Cambiar tema" title="Cambiar tema">
      {I_PALETTE}<span class="dd-label" id="themeLabel">Tema</span>{I_CHEVRON}
    </button>
    <div class="dd-menu" id="themeMenu" role="menu">
      <div class="dd-title">Apariencia</div>
      <button class="dd-item" role="menuitemradio" data-t="light"><span class="sw sw-light"></span>Claro</button>
      <button class="dd-item" role="menuitemradio" data-t="dark"><span class="sw sw-dark"></span>Oscuro</button>
      <button class="dd-item" role="menuitemradio" data-t="paper"><span class="sw sw-paper"></span>Papel</button>
      <button class="dd-item" role="menuitemradio" data-t="gaming"><span class="sw sw-gaming"></span>Gaming</button>
    </div>
  </div>
  </div>
</div></header>
"""

FOOTER = f"""
<footer class="footer"><div class="footer-in">
  <div class="footer-brand">{_svg('<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6l8-3z"/>', 18)} VPS MANAGER</div>
  <div class="footer-live">v2.1</div>
  <div>© %%YEAR%% Todos los derechos reservados</div>
</div></footer>
"""

def page(title, body, nav="", minimal=False):
    n = getattr(g, "nonce", "")
    logout_btn = (f'<form method="POST" action="/logout" class="logout-form">{csrf_input()}'
                  f'<button type="submit" class="icon-btn danger" aria-label="Cerrar sesión" title="Cerrar sesión">{I_LOGOUT}</button></form>'
                  ) if session.get("auth") else ""
    menu_btn = (f'<button type="button" class="icon-btn" id="menuBtn" aria-label="Abrir menú" '
                f'aria-controls="drawer" aria-expanded="false">{I_MENU}</button>') if nav else ""
    init = THEME_INIT.replace("<script>", f'<script nonce="{n}">')

    if minimal:
        topbar = f"""
<header class="topbar topbar-minimal"><div class="topbar-in">
  <a class="brand" href="/">
    <span class="brand-ic">{I_SHIELD}</span>
    <span><div class="brand-t">MANAGER PANEL</div><div class="brand-s">Administración VPS</div></span>
  </a>
  <div class="top-right">
    <div class="dd">
      <button class="dd-btn" id="themeBtn" aria-haspopup="true" aria-expanded="false" aria-label="Cambiar tema" title="Cambiar tema">
        {I_PALETTE}<span class="dd-label" id="themeLabel">Tema</span>{I_CHEVRON}
      </button>
      <div class="dd-menu" id="themeMenu" role="menu">
        <div class="dd-title">Apariencia</div>
        <button class="dd-item" role="menuitemradio" data-t="light"><span class="sw sw-light"></span>Claro</button>
        <button class="dd-item" role="menuitemradio" data-t="dark"><span class="sw sw-dark"></span>Oscuro</button>
        <button class="dd-item" role="menuitemradio" data-t="paper"><span class="sw sw-paper"></span>Papel</button>
        <button class="dd-item" role="menuitemradio" data-t="gaming"><span class="sw sw-gaming"></span>Gaming</button>
      </div>
    </div>
  </div>
</div></header>
"""
    else:
        topbar = TOPBAR.replace("%%MENU%%", menu_btn).replace("%%LOGOUT%%", logout_btn)

    return (
        "<!DOCTYPE html><html lang='es'><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        "<meta name='robots' content='noindex,nofollow'>"
        f"<title>{escape(title)} · MANAGER PANEL</title>"
        + init +
        f"<style>{CSS}</style></head><body>"
        + topbar + nav + render_toasts() +
        f"<main class='container'>{body}</main>"
        + FOOTER.replace("%%YEAR%%", str(datetime.now().year)) +
        f'<script nonce="{n}">{JS}</script></body></html>'
    )

# ──────────────────────────────────────────────────────────────
#  HELPERS DEL SISTEMA
# ──────────────────────────────────────────────────────────────
def managed_users():
    """Solo cuentas de usuario normales (uid >= 1000). Nunca root ni de sistema."""
    users = []
    try:
        with open("/etc/passwd") as f:
            for line in f:
                p = line.strip().split(":")
                if len(p) >= 3 and p[2].isdigit() and int(p[2]) >= 1000 and p[0] != "nobody":
                    users.append(p[0])
    except Exception:
        pass
    return users

def shadow_info():
    """usuario -> (hash, días_de_expiración_desde_1970)."""
    info = {}
    try:
        with open("/etc/shadow") as f:
            for line in f:
                p = line.rstrip("\n").split(":")
                if len(p) >= 8:
                    info[p[0]] = (p[1], p[7])
    except Exception:
        pass
    return info

def connections_by_user():
    """Conexiones SSH activas por usuario (una sola lectura de procesos)."""
    counts = {}
    _, out = run(["ps", "-eo", "user:32=,args="])
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].startswith("sshd:") and parts[0] != "root":
            counts[parts[0]] = counts.get(parts[0], 0) + 1
    return counts

def read_limit(u):
    try:
        with open(os.path.join(BASE_DIR, f"limite_{u}")) as f:
            return int(f.read().strip() or 0)
    except Exception:
        return 0

def strip_match(text, u):
    """Quita el bloque 'Match User <u>' exacto (no afecta a usuarios con nombre parecido)."""
    lines = text.split("\n")
    out, i = [], 0
    while i < len(lines):
        if lines[i].strip() == f"Match User {u}":
            i += 1
            if i < len(lines) and lines[i].strip().startswith("Banner "):
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return "\n".join(out)

def edit_sshd_config(modify):
    """Modifica sshd_config, valida con 'sshd -t' y restaura si queda inválido."""
    try:
        with open(SSHD_CONFIG) as f:
            original = f.read()
    except Exception as e:
        return False, f"No se pudo leer sshd_config: {e}"
    try:
        with open(SSHD_CONFIG, "w") as f:
            f.write(modify(original))
        sshd_bin = shutil.which("sshd") or ("/usr/sbin/sshd" if os.path.exists("/usr/sbin/sshd") else None)
        if sshd_bin:
            code, _ = run([sshd_bin, "-t"])
            if code != 0:
                with open(SSHD_CONFIG, "w") as f:
                    f.write(original)
                return False, "La configuración SSH quedó inválida; se restauró la anterior."
        if run(["systemctl", "reload", "ssh"])[0] != 0:
            run(["systemctl", "restart", "ssh"])
        return True, ""
    except Exception as e:
        try:
            with open(SSHD_CONFIG, "w") as f:
                f.write(original)
        except Exception:
            pass
        return False, f"Error editando sshd_config: {e}"

def write_banner(u, exp_date, days, limit):
    path = os.path.join(BASE_DIR, f"banner_{u}.net")
    try:
        with open("/etc/issue.net") as f:
            base = f.read()
    except Exception:
        base = ""
    extra = (
        "<br><font color='cyan'>=======================</font><br>"
        f"<font color='yellow'>👤 Usuario:</font> <font color='white'>{u}</font><br>"
        f"<font color='yellow'>📅 Expira:</font> <font color='white'>{exp_date} ({days} Días)</font><br>"
        f"<font color='yellow'>🔒 Límite:</font> <font color='white'>{limit} Conexiones</font><br>"
        "<font color='cyan'>=======================</font><br>\n"
    )
    with open(path, "w") as f:
        f.write(base + extra)
    return path

# ── Cuentas V2Ray guardadas por el panel ─────────────────────
def load_v2():
    try:
        with open(V2_FILE) as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:
        return []

def save_v2(items):
    tmp = V2_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(items, f, ensure_ascii=False, indent=2)
    os.replace(tmp, V2_FILE)

def get_domain():
    try:
        with open(os.path.join(BASE_DIR, "dominio")) as f:
            d = f.read().strip()
        if d and HOST_RE.match(d):
            return d
    except Exception:
        pass
    _, ip = run(["curl", "-s", "--max-time", "5", "ipv4.icanhazip.com"])
    ip = ip.strip()
    return ip if HOST_RE.match(ip) else ""

def _read_port(filename, default):
    """Lee un puerto configurado por el menú (/etc/vps-manager/<archivo>)."""
    try:
        with open(os.path.join(BASE_DIR, filename)) as f:
            v = f.read().strip()
        return int(v) if v.isdigit() else default
    except Exception:
        return default

def services_list():
    """Misma lista que menu_puertos() del menu.sh (incluye los puertos dinámicos)."""
    items = [
        (22, "SSH (OpenSSH)"), (80, "HTTP / Xray WS"), (443, "Xray SSL/VLESS"), (53, "DNS (SlowDNS)"),
        (1194, "OpenVPN TCP"), (2081, "OpenVPN Web"), (2083, "Trojan TLS"),
        (_read_port("bhttp_port", 8080), "BHTTP Custom"),
        (_read_port("hcr_port", 8880), "HCR Proxy PRO"),
        (_read_port("ssl_port", 444), "SSL / TLS Proxy"),
        (8181, "Web Panel UI"),
        (7100, "BadVPN (Game 7100)"), (7200, "BadVPN (Game 7200)"), (7300, "BadVPN (Game 7300)"),
        (25000, "UDP Custom"), (5432, "CheckUser API"), (8888, "Online App"),
    ]
    try:
        with open("/etc/autostart") as f:
            txt = f.read()
        m_std = re.search(r"(?<!4g)check\.py (\d+)", txt)
        m_4g = re.search(r"4gcheck\.py (\d+)", txt)
        if m_std:
            items.append((int(m_std.group(1)), "CheckUser Estándar"))
        if m_4g:
            items.append((int(m_4g.group(1)), "CheckUser Conecta4G"))
    except Exception:
        pass
    return items



def services_status():
    """Estado de puertos y servicios, igual que el Monitor de Puertos del menu.sh."""
    listening = set()
    udp = set()
    _, out = run(["ss", "-lntuH"])
    for line in out.splitlines():
        cols = line.split()
        if len(cols) >= 5:
            port = cols[4].rsplit(":", 1)[-1]
            if port.isdigit():
                listening.add(int(port))
                if cols[0].startswith("udp"):
                    udp.add(int(port))
    items = [{"port": str(p), "name": n, "active": p in listening} for p, n in services_list()]

    zivpn = run(["systemctl", "is-active", "--quiet", "zivpn.service"])[0] == 0 or 5667 in udp
    _, udp_procs = run(["ss", "-lnup"])
    hysteria = run(["systemctl", "is-active", "--quiet", "hysteria.service"])[0] == 0 or "hysteria" in udp_procs
    items.append({"port": "6000-19999", "name": "Zivpn UDP", "active": zivpn})
    items.append({"port": "Hysteria v1", "name": "Hysteria QUIC", "active": hysteria})
    return items

def post_btn(action_url, label, cls, confirm=None):
    c = f' data-confirm="{escape(confirm)}"' if confirm else ""
    return (f'<form method="POST" action="{escape(action_url)}"{c}>{csrf_input()}'
            f'<button type="submit" class="btn {cls}">{label}</button></form>')


# ──────────────────────────────────────────────────────────────
#  MONITOR DEL SISTEMA (CPU, RAM, disco, uptime, red)
# ──────────────────────────────────────────────────────────────
def _read_cpu_times():
    try:
        with open("/proc/stat") as f:
            parts = f.readline().split()
        nums = [int(x) for x in parts[1:9]]
        idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
        total = sum(nums)
        return idle, total
    except Exception:
        return 0, 0


def system_stats():
    """Métricas actuales del VPS para el dashboard."""
    stats = {
        "cpu": 0.0,
        "ram_used": 0, "ram_total": 0, "ram_pct": 0.0,
        "disk_used": 0, "disk_total": 0, "disk_pct": 0.0,
        "uptime_secs": 0, "uptime_human": "—",
        "net_rx": 0, "net_tx": 0,
        "load1": 0.0, "load5": 0.0, "load15": 0.0,
        "ts": int(time.time()),
    }
    try:
        idle1, total1 = _read_cpu_times()
        time.sleep(0.12)
        idle2, total2 = _read_cpu_times()
        dt = total2 - total1
        di = idle2 - idle1
        if dt > 0:
            stats["cpu"] = round(max(0.0, min(100.0, 100.0 * (1.0 - di / dt))), 1)
    except Exception:
        pass
    try:
        mem = {}
        with open("/proc/meminfo") as f:
            for line in f:
                if ":" in line:
                    k, v = line.split(":", 1)
                    mem[k.strip()] = int(v.strip().split()[0])
        total = mem.get("MemTotal", 0)
        avail = mem.get("MemAvailable", mem.get("MemFree", 0))
        used = max(0, total - avail)
        stats["ram_total"] = total * 1024
        stats["ram_used"] = used * 1024
        stats["ram_pct"] = round(100.0 * used / total, 1) if total else 0.0
    except Exception:
        pass
    try:
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        used = total - free
        stats["disk_total"] = total
        stats["disk_used"] = used
        stats["disk_pct"] = round(100.0 * used / total, 1) if total else 0.0
    except Exception:
        pass
    try:
        with open("/proc/uptime") as f:
            secs = float(f.read().split()[0])
        stats["uptime_secs"] = int(secs)
        d = int(secs // 86400)
        h = int((secs % 86400) // 3600)
        m = int((secs % 3600) // 60)
        if d > 0:
            stats["uptime_human"] = f"{d}d {h}h {m}m"
        elif h > 0:
            stats["uptime_human"] = f"{h}h {m}m"
        else:
            stats["uptime_human"] = f"{m}m"
    except Exception:
        pass
    try:
        with open("/proc/loadavg") as f:
            a, b, c = f.read().split()[:3]
            stats["load1"] = float(a)
            stats["load5"] = float(b)
            stats["load15"] = float(c)
    except Exception:
        pass
    try:
        rx = tx = 0
        with open("/proc/net/dev") as f:
            for line in f:
                if ":" not in line:
                    continue
                name, rest = line.split(":", 1)
                if name.strip() == "lo":
                    continue
                cols = rest.split()
                if len(cols) >= 9:
                    rx += int(cols[0])
                    tx += int(cols[8])
        stats["net_rx"] = rx
        stats["net_tx"] = tx
    except Exception:
        pass
    return stats


def human_bytes(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024
    return f"{n:.1f} TB"


def user_exp_info(u, shadow, today):
    """(días_str, badge, badge_cls, dias_int_or_None, exp_date_str)."""
    pw_hash, exp_field = shadow.get(u, ("", ""))
    if not exp_field.strip().lstrip("-").isdigit():
        return "Ilimitado", "CLIENTE", "c-ok", None, "Ilimitado"
    dias = int(exp_field) - today
    exp_date = (datetime.fromtimestamp(0) + timedelta(days=int(exp_field))).strftime("%Y-%m-%d")
    if dias <= 0:
        return "Expirado", "EXPIRADO", "c-danger", dias, exp_date
    if dias <= 2:
        return f"{dias} Días", "DEMO", "c-warn", dias, exp_date
    return f"{dias} Días", "CLIENTE", "c-ok", dias, exp_date


def build_client_text(u, password, days_str, limit, exp_date):
    """Texto listo para enviar al cliente (SSH)."""
    dom = get_domain() or "TU_IP_O_DOMINIO"
    pass_line = password if password else "(la contraseña que configuraste)"
    return (
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"  DATOS DE ACCESO SSH\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"Host / IP : {dom}\n"
        f"Puerto    : 22\n"
        f"Usuario   : {u}\n"
        f"Clave     : {pass_line}\n"
        f"Límite    : {limit} conexión(es)\n"
        f"Vence     : {exp_date} ({days_str})\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"Apps: HTTP Injector · Stickies · NapsternetV · v2rayNG\n"
    )


# ──────────────────────────────────────────────────────────────
#  RUTAS
# ──────────────────────────────────────────────────────────────
@app.route('/')
@requires_auth
def index():
    users = managed_users()
    shadow = shadow_info()
    conn_map = connections_by_user()
    today = int(time.time() // 86400)

    total_users = 0
    online_count = 0
    blocked_count = 0
    expirados_count = 0
    user_cards = ""

    for u in users:
        total_users += 1
        pw_hash, _ = shadow.get(u, ("", ""))
        dias_restantes, badge, badge_cls, dias_int, exp_date = user_exp_info(u, shadow, today)
        if badge == "EXPIRADO":
            expirados_count += 1

        is_locked = pw_hash.startswith("!")
        conns = conn_map.get(u, 0)
        limit = read_limit(u)

        if limit > 0:
            conn_txt = f"{conns} / {limit}"
            pct = min(100, int(conns * 100 / limit))
            conn_cls = "c-danger" if conns > limit else ("c-warn" if conns == limit else "c-ok")
        else:
            conn_txt = f"{conns} / ∞"
            pct = 0
            conn_cls = "c-ok" if conns > 0 else "c-muted"

        uq = quote(u, safe="")
        if is_locked:
            status_text = "BLOQUEADO"; status_cls = "c-danger"; blocked_count += 1
            action_btn = post_btn(f"/action/unlock/{uq}", "Desbloquear", "btn-warn")
        else:
            if conns > 0:
                status_text = "EN LÍNEA"; status_cls = "c-ok"; online_count += 1
            else:
                status_text = "DESCONECTADO"; status_cls = "c-muted"
            action_btn = post_btn(f"/action/lock/{uq}", "Bloquear", "btn-danger")

        renew_btn = post_btn(f"/action/renew/{uq}", "+30 días", "btn-primary")
        delete_btn = post_btn(f"/action/delete/{uq}", "Eliminar", "btn-ghost", "¿Eliminar este usuario?")
        name = escape(u)
        days_val = max(1, dias_int) if dias_int is not None and dias_int > 0 else 30
        limit_val = limit if limit > 0 else 1
        client_txt = escape(build_client_text(u, "", dias_restantes, limit if limit > 0 else "∞", exp_date), quote=True)
        user_cards += f"""
        <div class="card" data-name="{name.lower()}">
            <div class="u-head">
                <div class="avatar">{name[:1].upper()}</div>
                <div><h4 class="u-name">{name}</h4><div class="u-sub">Cuenta SSH</div></div>
                <span class="tag {badge_cls}">{badge}</span>
            </div>
            <div class="row"><span>Estado</span><span class="dot {status_cls}">{status_text}</span></div>
            <div class="row"><span>Conexiones</span><span class="conn {conn_cls}">{conn_txt}</span></div>
            <div class="meter {conn_cls}"><i style="--w:{pct}%"></i></div>
            <div class="row"><span>Tiempo restante</span><strong>{dias_restantes}</strong></div>
            <div class="actions four">
                <button type="button" class="btn btn-ghost" data-open-edit
                    data-user="{name}" data-days="{days_val}" data-limit="{limit_val}">Editar</button>
                <button type="button" class="btn btn-primary" data-copy="{client_txt}">Datos</button>
                {renew_btn}{action_btn}{delete_btn}
            </div>
        </div>
        """

    # Revendedores
    reseller_cards = ""
    reseller_count = 0
    res_file = os.path.join(BOT_DIR, "resellers.txt")
    if os.path.exists(res_file):
        with open(res_file, "r") as f:
            for line in f:
                if ":" in line:
                    r_id, creds = line.strip().split(":", 1)
                    reseller_count += 1
                    reseller_cards += f"""
                    <div class="card">
                        <div class="u-head">
                            <div class="avatar" style="background:var(--warn)">R</div>
                            <div><h4 class="u-name">ID: {escape(r_id)}</h4><div class="u-sub">Bot Telegram</div></div>
                            <span class="tag c-warn">RESELLER</span>
                        </div>
                        <div class="row"><span>Créditos disponibles</span><span class="credits">{escape(creds)}</span></div>
                    </div>
                    """

    # Cuentas V2Ray / VMess
    v2_cards = ""
    v2_items = [it for it in load_v2() if isinstance(it, dict) and UUID_RE.match(str(it.get("uuid", "")))]
    for it in reversed(v2_items):
        nm = escape(str(it.get("name", "")))
        uid = str(it["uuid"])
        link = escape(str(it.get("link", "")), quote=True)
        created = escape(str(it.get("created", "")))
        v2_del = post_btn(f"/v2ray/delete/{uid}", "Eliminar", "btn-ghost", "¿Eliminar esta cuenta V2Ray del panel?")
        v2_cards += f"""
        <div class="card" data-name="{nm.lower()}">
            <div class="u-head">
                <div class="avatar">V</div>
                <div><h4 class="u-name">{nm}</h4><div class="u-sub">VMess · WS + TLS</div></div>
                <span class="tag c-accent">V2RAY</span>
            </div>
            <div class="row"><span>UUID</span><span class="mono">{uid[:8]}…{uid[-4:]}</span></div>
            <div class="row"><span>Creada</span><strong>{created}</strong></div>
            <div class="actions two">
                <button type="button" class="btn btn-primary" data-copy="{link}">Copiar enlace</button>
                {v2_del}
            </div>
        </div>
        """

    # Estadísticas propias de V2Ray
    now_dt = datetime.now()
    v2_today = v2_week = 0
    for it in v2_items:
        try:
            ts = datetime.strptime(str(it.get("created", "")), "%Y-%m-%d %H:%M")
        except ValueError:
            continue
        if ts.date() == now_dt.date():
            v2_today += 1
        if now_dt - ts <= timedelta(days=7):
            v2_week += 1

    # Servicios activos (monitor de puertos)
    svc_items = services_status()
    svc_active = sum(1 for x in svc_items if x["active"])
    svc_cards = ""
    for sv in svc_items:
        svc_cls = "c-ok" if sv["active"] else "c-danger"
        svc_txt = "ACTIVO" if sv["active"] else "INACTIVO"
        svc_sub = escape(("Puerto " if str(sv["port"])[:1].isdigit() else "") + str(sv["port"]))
        svc_cards += (f'<div class="card svc"><div><div class="svc-name">{escape(sv["name"])}</div>'
                      f'<div class="u-sub">{svc_sub}</div></div>'
                      f'<span class="dot {svc_cls}">{svc_txt}</span></div>')

    empty_res = '<div class="empty">No hay revendedores registrados.</div>'
    empty_usr = '<div class="empty">No hay usuarios creados.</div>'
    empty_v2 = '<div class="empty">Aún no hay cuentas V2Ray creadas desde el panel.</div>'
    res_html = reseller_cards if reseller_cards else empty_res
    usr_html = user_cards if user_cards else empty_usr
    v2_html = v2_cards if v2_cards else empty_v2

    drawer = f"""
        <div class="drawer-overlay" id="drawerOv"></div>
        <aside class="drawer" id="drawer" aria-label="Navegación" aria-hidden="true">
            <div class="drawer-head">
                <div class="drawer-brand"><span class="brand-ic">{I_SHIELD}</span>Menú</div>
                <button type="button" class="modal-x" id="drawerClose" aria-label="Cerrar menú">×</button>
            </div>
            <div class="side-title">Cuentas</div>
            <button type="button" class="nav-item" data-nav="all">{I_GRID}<span>Todas las cuentas</span></button>
            <button type="button" class="nav-item" data-nav="ssh">{I_TERM}<span>Cuentas SSH</span><span class="n">{total_users}</span></button>
            <button type="button" class="nav-item" data-nav="v2ray">{I_BOLT}<span>Cuentas V2Ray</span><span class="n">{len(v2_items)}</span></button>
            <button type="button" class="nav-item" data-nav="resellers">{I_RESELL}<span>Revendedores</span></button>
            <div class="side-title" style="margin-top:10px">Sistema</div>
            <button type="button" class="nav-item" data-nav="monitor">{I_ONLINE}<span>Monitor VPS</span></button>
            <button type="button" class="nav-item" data-nav="services">{I_SERVER}<span>Servicios activos</span></button>
            <div class="drawer-foot">
                <div style="margin-bottom:10px">Sesión: <strong>{escape(get_panel_user())}</strong></div>
                <button type="button" class="btn btn-ghost btn-block" data-open="modalPass" style="margin-bottom:8px">Cambiar contraseña</button>
                <form method="POST" action="/logout">{csrf_input()}<button type="submit" class="btn btn-danger btn-block">{I_LOGOUT} Cerrar sesión</button></form>
            </div>
        </aside>
    """

    # Datos listos para el cliente (tras crear/editar)
    share_html = ""
    share_txt = session.pop("share_text", None)
    share_user = session.pop("share_user", None)
    if share_txt:
        share_esc = escape(share_txt)
        share_attr = escape(share_txt, quote=True)
        share_html = f"""
        <div class="card share-card" id="shareCard">
            <div class="modal-head" style="margin-bottom:10px">
                <h3>Datos para el cliente{(' · ' + escape(str(share_user))) if share_user else ''}</h3>
                <button type="button" class="modal-x" onclick="document.getElementById('shareCard').remove()" aria-label="Cerrar">×</button>
            </div>
            <textarea readonly id="shareBox" rows="12">{share_esc}</textarea>
            <div class="result-actions">
                <button type="button" class="btn btn-primary" data-copy="{share_attr}">Copiar texto</button>
                <button type="button" class="btn btn-ghost" onclick="document.getElementById('shareCard').remove()">Cerrar</button>
            </div>
        </div>
        """

    # Stats iniciales del monitor
    st = system_stats()
    def bar_cls(pct):
        if pct >= 90:
            return "c-danger"
        if pct >= 70:
            return "c-warn"
        return "c-ok"

    body = f"""
        {share_html}
        <section class="stats" data-stats="ssh">
            <div class="stat ok"><div class="stat-ic">{I_ONLINE}</div><div><div class="stat-num">{online_count}</div><div class="stat-lbl">En línea</div></div></div>
            <div class="stat warn"><div class="stat-ic">{I_CLOCK}</div><div><div class="stat-num">{expirados_count}</div><div class="stat-lbl">Expirados</div></div></div>
            <div class="stat danger"><div class="stat-ic">{I_BAN}</div><div><div class="stat-num">{blocked_count}</div><div class="stat-lbl">Bloqueados</div></div></div>
            <div class="stat accent"><div class="stat-ic">{I_USERS}</div><div><div class="stat-num">{total_users}</div><div class="stat-lbl">Usuarios SSH</div></div></div>
        </section>
        <section class="stats three" data-stats="v2ray">
            <div class="stat accent"><div class="stat-ic">{I_BOLT22}</div><div><div class="stat-num">{len(v2_items)}</div><div class="stat-lbl">Cuentas V2Ray</div></div></div>
            <div class="stat ok"><div class="stat-ic">{I_CAL}</div><div><div class="stat-num">{v2_today}</div><div class="stat-lbl">Creadas hoy</div></div></div>
            <div class="stat warn"><div class="stat-ic">{I_CLOCK}</div><div><div class="stat-num">{v2_week}</div><div class="stat-lbl">Últimos 7 días</div></div></div>
        </section>

        <div class="searchbar" id="searchWrap"><div class="search">{I_SEARCH}<input type="text" id="search" placeholder="Buscar usuario o cuenta..." autocomplete="off"></div></div>

        <div class="modal" id="modalSsh" role="dialog" aria-modal="true" aria-labelledby="tSsh">
            <form class="modal-box" action="/create_ssh" method="POST" autocomplete="off">
                {csrf_input()}
                <div class="modal-head"><h3 id="tSsh">Crear cuenta SSH</h3><button type="button" class="modal-x" data-close aria-label="Cerrar">×</button></div>
                <div class="fields">
                    <div><label for="u1">Usuario</label><input id="u1" type="text" name="user" placeholder="usuario" maxlength="32" pattern="[a-z_][a-z0-9_\\-]{{2,31}}" title="3 a 32 caracteres: minúsculas, números, _ o -" required></div>
                    <div><label for="p1">Contraseña</label><input id="p1" type="password" name="pass" placeholder="Contraseña" minlength="4" maxlength="64" required></div>
                    <div><label for="d1">Días de duración</label><input id="d1" type="number" name="days" placeholder="30" min="1" max="3650" required></div>
                    <div><label for="l1">Límite de conexiones</label><input id="l1" type="number" name="limit" placeholder="1" min="1" max="1000" required></div>
                    <div class="full modal-foot">
                        <button type="button" class="btn btn-ghost" data-close>Cancelar</button>
                        <button type="submit" class="btn btn-success">Crear SSH</button>
                    </div>
                </div>
            </form>
        </div>

        <div class="modal" id="modalEdit" role="dialog" aria-modal="true" aria-labelledby="tEdit">
            <form class="modal-box" id="formEdit" method="POST" autocomplete="off">
                {csrf_input()}
                <div class="modal-head"><h3 id="tEdit">Editar cuenta SSH</h3><button type="button" class="modal-x" data-close aria-label="Cerrar">×</button></div>
                <div class="fields">
                    <div class="full"><label>Usuario</label><input type="text" id="editUserLabel" disabled></div>
                    <div class="full"><label for="ePass">Nueva contraseña <span class="muted">(dejar vacío = no cambiar)</span></label>
                        <input id="ePass" type="password" name="pass" placeholder="Opcional" minlength="4" maxlength="64"></div>
                    <div><label for="eDays">Días restantes (exactos)</label>
                        <input id="eDays" type="number" name="days" min="1" max="3650" required></div>
                    <div><label for="eLimit">Límite de conexiones</label>
                        <input id="eLimit" type="number" name="limit" min="1" max="1000" required></div>
                    <div class="full modal-foot">
                        <button type="button" class="btn btn-ghost" data-close>Cancelar</button>
                        <button type="submit" class="btn btn-primary">Guardar cambios</button>
                    </div>
                </div>
            </form>
        </div>

        <div class="modal" id="modalPass" role="dialog" aria-modal="true" aria-labelledby="tPass">
            <form class="modal-box" action="/change_password" method="POST" autocomplete="off">
                {csrf_input()}
                <div class="modal-head"><h3 id="tPass">Cambiar contraseña del panel</h3><button type="button" class="modal-x" data-close aria-label="Cerrar">×</button></div>
                <div class="fields">
                    <div class="full"><label for="curPass">Contraseña actual</label>
                        <input id="curPass" type="password" name="current" required autocomplete="current-password"></div>
                    <div class="full"><label for="newPass">Nueva contraseña</label>
                        <input id="newPass" type="password" name="new" minlength="8" maxlength="64" required autocomplete="new-password"
                               placeholder="Mínimo 8 caracteres"></div>
                    <div class="full"><label for="newPass2">Repetir nueva contraseña</label>
                        <input id="newPass2" type="password" name="confirm" minlength="8" maxlength="64" required autocomplete="new-password"></div>
                    <p class="muted" style="margin:0;font-size:12px;grid-column:1/-1">Se guarda con hash PBKDF2-SHA256 en el servidor (nunca en texto plano).</p>
                    <div class="full modal-foot">
                        <button type="button" class="btn btn-ghost" data-close>Cancelar</button>
                        <button type="submit" class="btn btn-primary">Guardar</button>
                    </div>
                </div>
            </form>
        </div>

        <div class="modal" id="modalV2" role="dialog" aria-modal="true" aria-labelledby="tV2">
            <form class="modal-box" action="/create_v2ray" method="POST" autocomplete="off">
                {csrf_input()}
                <div class="modal-head"><h3 id="tV2">Crear V2Ray (VMess)</h3><button type="button" class="modal-x" data-close aria-label="Cerrar">×</button></div>
                <div class="fields">
                    <div class="full"><label for="u2">Nombre descriptivo</label><input id="u2" type="text" name="user" placeholder="ej: carlos" maxlength="40" required></div>
                    <div class="full modal-foot">
                        <button type="button" class="btn btn-ghost" data-close>Cancelar</button>
                        <button type="submit" class="btn btn-primary">Generar enlace VMess</button>
                    </div>
                </div>
            </form>
        </div>

        <div class="view" data-view="ssh">
            <div class="section-head">
                <h2 class="section-title">Cuentas SSH <span class="count">{total_users}</span></h2>
                <button type="button" class="btn btn-success" data-open="modalSsh">＋ Crear SSH</button>
            </div>
            <section class="grid" id="userGrid">{usr_html}</section>
        </div>

        <div class="view" data-view="v2ray">
            <div class="section-head">
                <h2 class="section-title">Cuentas V2Ray <span class="count">{len(v2_items)}</span></h2>
                <button type="button" class="btn btn-primary" data-open="modalV2">＋ Crear V2Ray</button>
            </div>
            <section class="grid" id="v2Grid">{v2_html}</section>
        </div>

        <div class="view" data-view="resellers">
            <div class="section-head"><h2 class="section-title">Revendedores</h2></div>
            <section class="grid">{res_html}</section>
        </div>

        <div class="view" data-view="monitor">
            <div class="section-head">
                <h2 class="section-title">Monitor del VPS</h2>
                <button type="button" class="btn btn-ghost" id="statsRefresh">Actualizar</button>
            </div>
            <div class="stats" id="monStats">
                <div class="stat accent"><div class="stat-ic">{I_BOLT22}</div><div>
                    <div class="stat-num" id="mCpu">{st['cpu']}%</div>
                    <div class="stat-lbl">CPU · load {st['load1']:.2f}</div>
                </div></div>
                <div class="stat ok"><div class="stat-ic">{I_SERVER}</div><div>
                    <div class="stat-num" id="mRam">{st['ram_pct']}%</div>
                    <div class="stat-lbl">RAM · <span id="mRamTxt">{human_bytes(st['ram_used'])} / {human_bytes(st['ram_total'])}</span></div>
                </div></div>
                <div class="stat warn"><div class="stat-ic">{I_GRID}</div><div>
                    <div class="stat-num" id="mDisk">{st['disk_pct']}%</div>
                    <div class="stat-lbl">Disco · <span id="mDiskTxt">{human_bytes(st['disk_used'])} / {human_bytes(st['disk_total'])}</span></div>
                </div></div>
                <div class="stat ok"><div class="stat-ic">{I_CLOCK}</div><div>
                    <div class="stat-num" id="mUp" style="font-size:20px">{st['uptime_human']}</div>
                    <div class="stat-lbl">Uptime</div>
                </div></div>
            </div>
            <div class="grid" style="margin-top:14px">
                <div class="card">
                    <h3>Uso de recursos</h3>
                    <div class="mon-row"><span>CPU</span><strong id="mCpu2">{st['cpu']}%</strong></div>
                    <div class="meter {bar_cls(st['cpu'])}"><i id="bCpu" style="--w:{st['cpu']}%"></i></div>
                    <div class="mon-row"><span>RAM</span><strong id="mRam2">{st['ram_pct']}%</strong></div>
                    <div class="meter {bar_cls(st['ram_pct'])}"><i id="bRam" style="--w:{st['ram_pct']}%"></i></div>
                    <div class="mon-row"><span>Disco</span><strong id="mDisk2">{st['disk_pct']}%</strong></div>
                    <div class="meter {bar_cls(st['disk_pct'])}"><i id="bDisk" style="--w:{st['disk_pct']}%"></i></div>
                    <div class="mon-row" style="margin-top:12px"><span>Load average</span>
                        <strong id="mLoad">{st['load1']:.2f} · {st['load5']:.2f} · {st['load15']:.2f}</strong></div>
                </div>
                <div class="card">
                    <h3>Tráfico de red (total)</h3>
                    <div class="mon-row"><span>Recibido (RX)</span><strong id="mRx">{human_bytes(st['net_rx'])}</strong></div>
                    <div class="mon-row"><span>Enviado (TX)</span><strong id="mTx">{human_bytes(st['net_tx'])}</strong></div>
                    <div class="mon-row"><span>Total</span><strong id="mNet">{human_bytes(st['net_rx'] + st['net_tx'])}</strong></div>
                    <p class="muted" style="margin:14px 0 0;font-size:13px">Los contadores son acumulados desde el arranque del sistema. La vista se actualiza sola cada 5 s.</p>
                    <canvas id="netChart" width="400" height="120" style="width:100%;margin-top:12px;border-radius:8px;background:var(--surface-2)"></canvas>
                </div>
            </div>
        </div>

        <div class="view" data-view="services">
            <div class="section-head">
                <h2 class="section-title">Servicios activos</h2>
                <button type="button" class="btn btn-ghost" data-reload>Actualizar</button>
            </div>
            <section class="grid svc-grid">{svc_cards}</section>
        </div>
    """
    return page("Panel", body, nav=drawer)

@app.route('/create_ssh', methods=['POST'])
@requires_auth
@csrf_protect
def create_ssh():
    u = (request.form.get('user') or "").strip()
    p = (request.form.get('pass') or "").strip()
    d = (request.form.get('days') or "").strip()
    l = (request.form.get('limit') or "").strip()

    if not USER_RE.match(u):
        toast("err", "Usuario inválido: usa 3 a 32 caracteres en minúsculas, números, _ o -.")
        return redirect(url_for('index'))
    if not (4 <= len(p) <= 64) or any(ord(c) < 32 or ord(c) == 127 for c in p):
        toast("err", "La contraseña debe tener entre 4 y 64 caracteres, sin saltos de línea.")
        return redirect(url_for('index'))
    if not (d.isdigit() and 1 <= int(d) <= 3650):
        toast("err", "Los días deben ser un número entre 1 y 3650.")
        return redirect(url_for('index'))
    if not (l.isdigit() and 1 <= int(l) <= 1000):
        toast("err", "El límite de conexiones debe ser un número entre 1 y 1000.")
        return redirect(url_for('index'))
    try:
        pwd.getpwnam(u)
        toast("err", f"El usuario '{u}' ya existe en el sistema.")
        return redirect(url_for('index'))
    except KeyError:
        pass

    exp_date = (datetime.now() + timedelta(days=int(d))).strftime("%Y-%m-%d")
    code, out = run(["useradd", "-e", exp_date, "-s", "/bin/false", "-M", u])
    if code != 0:
        toast("err", f"No se pudo crear el usuario: {out}")
        return redirect(url_for('index'))
    code, out = run(["chpasswd"], stdin=f"{u}:{p}\n")
    if code != 0:
        run(["userdel", "-f", u])
        toast("err", f"No se pudo asignar la contraseña: {out}")
        return redirect(url_for('index'))

    banner_warn = ""
    try:
        with open(os.path.join(BASE_DIR, f"limite_{u}"), "w") as f:
            f.write(l + "\n")
        banner = write_banner(u, exp_date, d, l)
        ok, msg = edit_sshd_config(
            lambda txt: strip_match(txt, u).rstrip("\n") + f"\n\nMatch User {u}\nBanner {banner}\n")
        if not ok:
            audit(f"CREATE_SSH {u} (banner no aplicado: {msg})")
            banner_warn = " (banner no aplicado)"
    except Exception as e:
        audit(f"CREATE_SSH {u} (aviso: {e})")
        banner_warn = " (aviso en banner)"

    audit(f"CREATE_SSH {u} dias={d} limite={l}")
    session["share_user"] = u
    session["share_text"] = build_client_text(u, p, f"{d} Días", l, exp_date)
    toast("ok", f"Usuario SSH '{u}' creado con éxito{banner_warn}. Copia los datos abajo.")
    return redirect(url_for('index'))

@app.route('/create_v2ray', methods=['POST'])
@requires_auth
@csrf_protect
def create_v2ray():
    name = (request.form.get('user') or "").strip()
    if not NAME_RE.match(name):
        toast("err", "Nombre inválido: usa hasta 40 caracteres (letras, números, espacio, . _ -).")
        return redirect(url_for('index'))

    dom = get_domain()
    if not dom:
        toast("err", "No se pudo obtener el dominio o la IP del servidor.")
        return redirect(url_for('index'))

    v_uuid = str(uuid.uuid4())
    vmess = {"v": "2", "ps": name, "add": dom, "port": "443", "id": v_uuid, "aid": "0", "scy": "auto",
             "net": "ws", "type": "none", "host": dom, "path": "/vmess", "tls": "tls", "sni": dom, "alpn": ""}
    raw = json.dumps(vmess, separators=(",", ":"), ensure_ascii=False)
    vmess_link = "vmess://" + base64.b64encode(raw.encode("utf-8")).decode("utf-8")

    items = load_v2()
    items.append({"name": name, "uuid": v_uuid, "link": vmess_link,
                  "created": datetime.now().strftime("%Y-%m-%d %H:%M")})
    try:
        save_v2(items)
    except Exception as e:
        toast("err", f"No se pudo guardar la cuenta V2Ray: {e}")
        return redirect(url_for('index'))
    audit(f"CREATE_V2RAY {name} {v_uuid}")
    toast("ok", f"Cuenta V2Ray '{name}' creada con éxito.")
    return redirect(url_for('index'))

@app.route('/v2ray/delete/<vid>', methods=['POST'])
@requires_auth
@csrf_protect
def v2ray_delete(vid):
    if UUID_RE.match(vid):
        items = [it for it in load_v2() if isinstance(it, dict) and it.get("uuid") != vid]
        save_v2(items)
        audit(f"DELETE_V2RAY {vid}")
        toast("ok", "Cuenta V2Ray eliminada.")
    else:
        toast("err", "UUID inválido.")
    return redirect(url_for('index'))

@app.route('/action/<cmd>/<user>', methods=['POST'])
@requires_auth
@csrf_protect
def action(cmd, user):
    # Solo cuentas normales: jamás root ni usuarios del sistema
    if cmd not in ("lock", "unlock", "delete", "renew") or user not in managed_users():
        toast("err", "Acción no permitida o usuario inexistente.")
        return redirect(url_for('index'))

    if cmd == "lock":
        run(["usermod", "-L", user]); run(["pkill", "-u", user])
        toast("warn", f"Usuario '{user}' bloqueado.")
    elif cmd == "unlock":
        run(["usermod", "-U", user])
        toast("ok", f"Usuario '{user}' desbloqueado.")
    elif cmd == "delete":
        run(["userdel", "-f", user])
        for fn in (f"banner_{user}.net", f"limite_{user}"):
            try:
                os.remove(os.path.join(BASE_DIR, fn))
            except OSError:
                pass
        edit_sshd_config(lambda txt: strip_match(txt, user))
        toast("ok", f"Usuario '{user}' eliminado.")
    elif cmd == "renew":
        # Suma 30 días al tiempo restante (no reinicia desde hoy)
        today = int(time.time() // 86400)
        shadow = shadow_info()
        _, exp_field = shadow.get(user, ("", ""))
        if exp_field.strip().lstrip("-").isdigit():
            current_exp = int(exp_field)
            base = max(current_exp, today)  # si ya expiró, parte de hoy
            new_days_epoch = base + 30
        else:
            new_days_epoch = today + 30
        new_exp = (datetime.fromtimestamp(0) + timedelta(days=new_days_epoch)).strftime("%Y-%m-%d")
        run(["chage", "-E", new_exp, user])
        # Actualizar banner si existe
        try:
            limit = read_limit(user)
            dias_left = new_days_epoch - today
            banner = write_banner(user, new_exp, str(dias_left), limit)
            edit_sshd_config(lambda txt: strip_match(txt, user).rstrip("\n") + f"\n\nMatch User {user}\nBanner {banner}\n")
        except Exception:
            pass
        toast("ok", f"Usuario '{user}' renovado: +30 días (vence {new_exp}).")

    audit(f"{cmd.upper()} {user}")
    return redirect(url_for('index'))


@app.route('/edit_ssh/<user>', methods=['POST'])
@requires_auth
@csrf_protect
def edit_ssh(user):
    if user not in managed_users():
        toast("err", "Usuario inexistente o no gestionable.")
        return redirect(url_for('index'))

    p = (request.form.get("pass") or "").strip()
    d = (request.form.get("days") or "").strip()
    l = (request.form.get("limit") or "").strip()
    changed = []

    # Contraseña (opcional)
    if p:
        if not (4 <= len(p) <= 64) or any(ord(c) < 32 or ord(c) == 127 for c in p):
            toast("err", "La contraseña debe tener entre 4 y 64 caracteres, sin saltos de línea.")
            return redirect(url_for('index'))
        code, out = run(["chpasswd"], stdin=f"{user}:{p}\n")
        if code != 0:
            toast("err", f"No se pudo cambiar la contraseña: {out}")
            return redirect(url_for('index'))
        changed.append("contraseña")
        session["share_pass"] = p  # solo para el texto de datos de esta sesión

    # Días exactos restantes (desde hoy)
    if d:
        if not (d.isdigit() and 1 <= int(d) <= 3650):
            toast("err", "Los días deben ser un número entre 1 y 3650.")
            return redirect(url_for('index'))
        exp_date = (datetime.now() + timedelta(days=int(d))).strftime("%Y-%m-%d")
        code, out = run(["chage", "-E", exp_date, user])
        if code != 0:
            toast("err", f"No se pudo cambiar la expiración: {out}")
            return redirect(url_for('index'))
        changed.append(f"vencimiento ({d} días → {exp_date})")
    else:
        # conservar fecha actual para el banner
        today = int(time.time() // 86400)
        _, _, _, dias_int, exp_date = user_exp_info(user, shadow_info(), today)
        d = str(max(1, dias_int) if dias_int is not None else 30)
        if exp_date == "Ilimitado":
            exp_date = (datetime.now() + timedelta(days=int(d))).strftime("%Y-%m-%d")

    # Límite de conexiones
    if l:
        if not (l.isdigit() and 1 <= int(l) <= 1000):
            toast("err", "El límite de conexiones debe ser un número entre 1 y 1000.")
            return redirect(url_for('index'))
        try:
            with open(os.path.join(BASE_DIR, f"limite_{user}"), "w") as f:
                f.write(l + "\n")
            changed.append(f"límite={l}")
        except Exception as e:
            toast("err", f"No se pudo guardar el límite: {e}")
            return redirect(url_for('index'))
    else:
        l = str(read_limit(user) or 1)

    # Banner actualizado
    try:
        banner = write_banner(user, exp_date, d, l)
        edit_sshd_config(lambda txt: strip_match(txt, user).rstrip("\n") + f"\n\nMatch User {user}\nBanner {banner}\n")
    except Exception:
        pass

    if not changed:
        toast("info", "No se modificó ningún campo.")
    else:
        audit(f"EDIT_SSH {user} {', '.join(changed)}")
        toast("ok", f"Usuario '{user}' actualizado: {', '.join(changed)}.")
        # Guardar texto de cliente en sesión para mostrar/copiar
        session["share_user"] = user
        session["share_text"] = build_client_text(
            user, session.get("share_pass", ""), f"{d} Días", l, exp_date
        )
        session.pop("share_pass", None)

    return redirect(url_for('index'))

@app.route('/api/stats')
@requires_auth
def api_stats():
    return Response(json.dumps(system_stats()), mimetype="application/json",
                    headers={"Cache-Control": "no-store"})


@app.route('/login', methods=['GET', 'POST'])
def login():
    if session.get("auth"):
        return redirect(url_for('index'))
    ip = request.remote_addr or "?"
    msg, kind = "", "err"
    if request.method == "POST":
        if is_locked_out(ip):
            return too_many()
        u = (request.form.get("username") or "").strip()
        p = request.form.get("password") or ""
        if check_auth(u, p):
            FAILS.pop(ip, None)
            session.clear()
            session.permanent = True
            session["auth"] = True
            session["t"] = time.time()
            session["csrf"] = secrets.token_hex(16)
            audit("LOGIN_OK")
            toast("ok", "Bienvenido al panel.")
            return redirect(url_for('index'))
        register_fail(ip)
        audit(f"LOGIN_FALLIDO usuario={u[:32]!r}")
        time.sleep(0.6)
        msg = "Usuario o contraseña incorrectos."
    elif request.args.get("expired"):
        msg = "Tu sesión expiró. Inicia sesión de nuevo."
    elif request.args.get("bye"):
        msg, kind = "Sesión cerrada correctamente.", "ok"

    alert = f'<div class="alert alert-{kind}" role="alert">{escape(msg)}</div>' if msg else ""
    body = f"""
        <div class="login-wrap">
            <form class="card login-card" method="POST" action="/login">
                <div class="brand-ic login-ic">{I_SHIELD}</div>
                <h2>Iniciar sesión</h2>
                <p class="muted">Panel de administración VPS</p>
                {alert}
                <label for="lu">Usuario</label>
                <input id="lu" name="username" type="text" autocomplete="username" autocapitalize="off" required autofocus>
                <label for="lp">Contraseña</label>
                <div class="pw">
                    <input id="lp" name="password" type="password" autocomplete="current-password" required>
                    <button type="button" class="pw-toggle" data-toggle-pw>Mostrar</button>
                </div>
                <button type="submit" class="btn btn-primary btn-block" style="margin-top:20px">Entrar</button>
            </form>
        </div>
    """
    return page("Iniciar sesión", body, minimal=True)

@app.route('/logout', methods=['POST'])
@requires_auth
@csrf_protect
def logout():
    audit("LOGOUT")
    session.clear()
    toast("ok", "Sesión cerrada correctamente.")
    return redirect(url_for('login'))


@app.route('/change_password', methods=['POST'])
@requires_auth
@csrf_protect
def change_password():
    current = request.form.get("current") or ""
    new = request.form.get("new") or ""
    confirm = request.form.get("confirm") or ""

    stored_user, stored_secret = get_panel_secret_material()
    if not _verify_password(current, stored_secret):
        time.sleep(0.6)
        audit("CHANGE_PASS_FAIL current_invalid")
        toast("err", "La contraseña actual no es correcta.")
        return redirect(url_for("index"))

    if len(new) < 8 or len(new) > 64:
        toast("err", "La nueva contraseña debe tener entre 8 y 64 caracteres.")
        return redirect(url_for("index"))
    if any(ord(c) < 32 or ord(c) == 127 for c in new):
        toast("err", "La nueva contraseña contiene caracteres no válidos.")
        return redirect(url_for("index"))
    if new != confirm:
        toast("err", "La nueva contraseña y la confirmación no coinciden.")
        return redirect(url_for("index"))
    if hmac.compare_digest(new.encode("utf-8"), current.encode("utf-8")):
        toast("err", "La nueva contraseña debe ser distinta a la actual.")
        return redirect(url_for("index"))

    try:
        _save_auth_file(stored_user, new)
    except Exception as e:
        toast("err", f"No se pudo guardar la nueva contraseña: {e}")
        return redirect(url_for("index"))

    audit("CHANGE_PASS_OK")
    toast("ok", "Contraseña del panel actualizada (guardada con hash).")
    return redirect(url_for("index"))


if __name__ == '__main__':
    auth = _load_auth_file()
    if not auth:
        if "PANEL_PASS" not in os.environ or len(_DEFAULT_PASS) < 8:
            print("⚠️  ADVERTENCIA: no hay panel_auth.json y la contraseña por defecto/env es débil.")
            print("    Entra al panel y usa «Cambiar contraseña» o define PANEL_USER / PANEL_PASS (mín. 8).")
    else:
        print(f"✓ Auth hasheada cargada para usuario «{auth[0]}» desde {AUTH_FILE}")
    app.run(host=HOST, port=PORT)
