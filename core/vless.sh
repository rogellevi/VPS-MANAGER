#!/bin/bash
# ==========================================
# Módulo Unificado: VLESS (XRAY)
# Puertos: 80 (NTLS) y 443 (TLS)
# Compatible en simultáneo con VMess
# Cuentas con vencimiento real (registro compartido con el panel web)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
XRAY_DIR="/usr/local/etc/xray"
CONF_FILE="$XRAY_DIR/config.json"
DOM_FILE="/etc/vps-manager/dominio"
LIMIT_FILE="/etc/vps-manager/limites_vless"
FLAG_FILE="/etc/vps-manager/xray_dual_ok"

instalar_xray_dual() {
    clear
    echo -e "${C_CYAN}================================================${C_NC}"
    echo -e "${C_GREEN}   INSTALACIÓN DUAL XRAY (80 NTLS + 443 TLS)    ${C_NC}"
    echo -e "${C_CYAN}================================================${C_NC}"
    
    read -p "Ingresa tu dominio (Ej: centrix.golbertvps.online): " DOMINIO
    if [ -z "$DOMINIO" ]; then echo -e "${C_RED}[!] Dominio inválido.${C_NC}"; sleep 2; return; fi
    mkdir -p /etc/vps-manager
    echo "$DOMINIO" > $DOM_FILE

    echo -e "${C_YELLOW}[+] Instalando dependencias y núcleo Xray...${C_NC}"
    apt update -y >/dev/null 2>&1
    apt install -y certbot jq uuid-runtime curl iptables ufw psmisc openssl python3 qrencode >/dev/null 2>&1
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1

    echo -e "${C_YELLOW}[+] Liberando puertos 80 y 443...${C_NC}"
    systemctl stop nginx apache2 haproxy xray 2>/dev/null
    fuser -k 80/tcp 2>/dev/null
    fuser -k 443/tcp 2>/dev/null

    mkdir -p $XRAY_DIR
    echo -e "${C_YELLOW}[+] Configurando Certificado SSL para puerto 443...${C_NC}"
    if [ ! -f "/etc/letsencrypt/live/$DOMINIO/fullchain.pem" ]; then
        certbot certonly --standalone -d "$DOMINIO" --non-interactive --agree-tos -m "admin@$DOMINIO" >/dev/null 2>&1
    fi

    if [ -f "/etc/letsencrypt/live/$DOMINIO/fullchain.pem" ]; then
        cp /etc/letsencrypt/live/$DOMINIO/fullchain.pem $XRAY_DIR/server.crt
        cp /etc/letsencrypt/live/$DOMINIO/privkey.pem $XRAY_DIR/server.key
    else
        echo -e "${C_YELLOW}[!] Generando certificado SSL autofirmado de respaldo...${C_NC}"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout $XRAY_DIR/server.key -out $XRAY_DIR/server.crt \
            -subj "/C=PE/ST=Lima/L=Lima/O=VPS/CN=$DOMINIO" >/dev/null 2>&1
    fi
    chmod 644 $XRAY_DIR/server.crt $XRAY_DIR/server.key

    echo -e "${C_YELLOW}[+] Aplicando permisos root y estructura dual (80 y 443)...${C_NC}"
    sed -i 's/User=nobody/User=root/g' /etc/systemd/system/xray.service 2>/dev/null
    systemctl daemon-reload

    cat << 'EOF' > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none",
        "fallbacks": [
          { "path": "/vless", "dest": 10001 },
          { "path": "/vmess", "dest": 10002 }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "certificates": [
            {
              "certificateFile": "/usr/local/etc/xray/server.crt",
              "keyFile": "/usr/local/etc/xray/server.key"
            }
          ]
        }
      }
    },
    {
      "port": 80,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none",
        "fallbacks": [
          { "path": "/vless", "dest": 10001 },
          { "path": "/vmess", "dest": 10002 }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      }
    },
    {
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/vless"
        }
      }
    },
    {
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": []
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/vmess"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

    iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    iptables-save > /etc/iptables.up.rules 2>/dev/null
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1

    # Reponer en Xray las cuentas activas del registro (la config nueva viene con clientes vacíos)
    python3 /etc/vps-manager/v2ray_ctl.py restore
    systemctl restart xray
    touch $FLAG_FILE
    echo -e "${C_GREEN}[✔] ¡Puertos 80 (NTLS) y 443 (TLS) activos para VLESS y VMess!${C_NC}"
    sleep 2
}

# ── Motor compartido (registro + Xray), mismo que usa el panel web ──
CTL="/etc/vps-manager/v2ray_ctl.py"
PROTO="vless"

instalar_ctl() {
    mkdir -p /etc/vps-manager
    cat > "$CTL" << 'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2ray_ctl: registro compartido (v2ray_users.json) + config de Xray.
Lo usan vmess.sh, vless.sh y el panel web (mismo archivo y mismo bloqueo)."""
import sys, os, json, re, uuid as _uuid, base64, subprocess, tempfile, fcntl, time, shutil
from datetime import date, datetime, timedelta
from urllib.parse import quote

BASE = os.environ.get("VPS_BASE", "/etc/vps-manager")
REG_FILE = os.path.join(BASE, "v2ray_users.json")
LOCK_FILE = os.path.join(BASE, ".v2ray.lock")
XCONF = os.environ.get("XRAY_CONFIG", "/usr/local/etc/xray/config.json")
XBIN = os.environ.get("XRAY_BIN") or shutil.which("xray") or "/usr/local/bin/xray"
SVC = os.environ.get("XRAY_SERVICE", "xray")
NAME_RE = re.compile(r"^[A-Za-z0-9 ._-]{1,40}$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
G, Y, C, R, N = "\033[1;32m", "\033[1;33m", "\033[1;36m", "\033[1;31m", "\033[0m"
LINE = Y + "─" * 47 + N


class Err(Exception):
    pass


class lock:
    def __enter__(self):
        os.makedirs(BASE, exist_ok=True)
        self.fd = open(LOCK_FILE, "a")
        fcntl.flock(self.fd, fcntl.LOCK_EX)
    def __exit__(self, *a):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        self.fd.close()


# ── registro ────────────────────────────────────────────────
def load_reg():
    try:
        with open(REG_FILE, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return []
    except ValueError as e:
        raise Err(f"El registro {REG_FILE} está dañado ({e}). Revísalo antes de continuar.")
    return data if isinstance(data, list) else []

def save_reg(items):
    os.makedirs(BASE, exist_ok=True)
    tmp = REG_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=2)
    os.replace(tmp, REG_FILE)

def proto_of(it):
    return "vless" if str(it.get("protocol", "")).lower() == "vless" else "vmess"

def find(items, proto, name):
    for it in items:
        if isinstance(it, dict) and proto_of(it) == proto and str(it.get("name", "")).lower() == name.lower():
            return it
    return None

def days_left(it):
    try:
        return (datetime.strptime(str(it.get("expires", "")), "%Y-%m-%d").date() - date.today()).days
    except ValueError:
        return None

def status(it):
    if it.get("blocked"):
        return "BLOQUEADA"
    if not it.get("expires"):
        return "SIN XRAY"
    left = days_left(it)
    if not it.get("active", True) or (left is not None and left < 0):
        return "VENCIDA"
    return "ACTIVA"


# ── Xray ────────────────────────────────────────────────────
def restart():
    try:
        r = subprocess.run(["systemctl", "restart", SVC], capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return False, (r.stdout + r.stderr).strip()
        time.sleep(0.8)
        r = subprocess.run(["systemctl", "is-active", SVC], capture_output=True, text=True, timeout=10)
        return (r.returncode == 0 and r.stdout.strip() == "active"), (r.stdout + r.stderr).strip()
    except Exception as e:
        return False, str(e)

def xray_mutate(fn):
    """Aplica fn(cfg)->bool sobre config.json: valida con xray -test, escribe atómico, reinicia y revierte si falla."""
    try:
        with open(XCONF, encoding="utf-8") as f:
            original = f.read()
        cfg = json.loads(original)
    except FileNotFoundError:
        raise Err("No existe la config de Xray. Instala el motor desde el menú.")
    except ValueError as e:
        raise Err(f"config.json de Xray no es JSON válido: {e}")
    if not fn(cfg):
        return False
    new_text = json.dumps(cfg, indent=2, ensure_ascii=False) + "\n"
    mode = os.stat(XCONF).st_mode & 0o777
    fd, chk = tempfile.mkstemp(prefix="xray_check_", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(new_text)
        r = subprocess.run([XBIN, "run", "-test", "-config", chk], capture_output=True, text=True, timeout=20)
    except OSError as e:
        raise Err(f"No se pudo ejecutar xray: {e}")
    finally:
        try: os.remove(chk)
        except OSError: pass
    if r.returncode != 0:
        raise Err("Xray rechazó la configuración: " + (r.stdout + r.stderr).strip()[-300:])
    tmp = XCONF + ".panel.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new_text)
    try:
        with open(XCONF + ".panel.bak", "w", encoding="utf-8") as f:
            f.write(original)
        os.chmod(XCONF + ".panel.bak", 0o600)
    except OSError:
        pass
    os.replace(tmp, XCONF)
    ok, out = restart()
    if not ok:
        with open(XCONF, "w", encoding="utf-8") as f:
            f.write(original)
        restart()
        raise Err("Xray no arrancó con el cambio (se restauró la config anterior): " + out[-200:])
    return True

def targets(cfg, proto):
    out = []
    for ib in cfg.get("inbounds", []):
        if not isinstance(ib, dict) or ib.get("protocol") != proto:
            continue
        if proto == "vless" and (ib.get("streamSettings") or {}).get("network") != "ws":
            continue
        out.append(ib)
    return out

def client_obj(proto, uid, email):
    return {"id": uid, "alterId": 0, "email": email} if proto == "vmess" else {"id": uid, "email": email}

def x_add(proto, uid, email):
    def m(cfg):
        ibs = targets(cfg, proto)
        if not ibs:
            raise Err(f"No hay inbound {proto.upper()} (WS) en config.json. Usa 'Reinstalar / Reparar Motor Xray'.")
        ch = False
        for ib in ibs:
            cl = ib.setdefault("settings", {}).setdefault("clients", [])
            if not any(isinstance(c, dict) and c.get("id") == uid for c in cl):
                cl.append(client_obj(proto, uid, email))
                ch = True
        return ch
    return xray_mutate(m)

def x_remove(ids):
    ids = set(ids)
    def m(cfg):
        ch = False
        for ib in cfg.get("inbounds", []):
            st = ib.get("settings") if isinstance(ib, dict) else None
            cl = st.get("clients") if isinstance(st, dict) else None
            if not isinstance(cl, list):
                continue
            keep = [c for c in cl if not (isinstance(c, dict) and c.get("id") in ids)]
            if len(keep) != len(cl):
                st["clients"] = keep
                ch = True
        return ch
    return xray_mutate(m)

def x_ids_by_email(proto, email):
    try:
        with open(XCONF, encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        return []
    return [c["id"] for ib in targets(cfg, proto) for c in ib.get("settings", {}).get("clients", [])
            if isinstance(c, dict) and c.get("email") == email and c.get("id")]


# ── enlaces ─────────────────────────────────────────────────
def get_domain():
    try:
        with open(os.path.join(BASE, "dominio"), encoding="utf-8") as f:
            d = f.read().strip()
        if d:
            return d
    except OSError:
        pass
    try:
        r = subprocess.run(["curl", "-s", "--max-time", "5", "ipv4.icanhazip.com"], capture_output=True, text=True, timeout=8)
        if r.stdout.strip():
            return r.stdout.strip()
    except Exception:
        pass
    raise Err("No hay dominio configurado (/etc/vps-manager/dominio) ni se pudo obtener la IP.")

def vmess_link(alias, dom, uid, tls):
    d = {"v": "2", "ps": alias, "add": dom, "port": "443" if tls else "80", "id": uid, "aid": "0", "scy": "auto",
         "net": "ws", "type": "none", "host": dom, "path": "/vmess", "tls": "tls" if tls else "none"}
    if tls:
        d["sni"] = dom; d["alpn"] = ""
    return "vmess://" + base64.b64encode(json.dumps(d, separators=(",", ":"), ensure_ascii=False).encode()).decode()

def vless_link(alias, dom, uid, tls):
    q = (f"path=%2Fvless&security=tls&encryption=none&type=ws&host={dom}&sni={dom}" if tls
         else "path=%2Fvless&security=none&encryption=none&type=ws")
    return f"vless://{uid}@{dom}:{443 if tls else 80}?{q}#{quote(alias)}"

def links(proto, name, dom, uid):
    mk = vless_link if proto == "vless" else vmess_link
    return mk(f"{name}-TLS", dom, uid, True), mk(f"{name}-NTLS", dom, uid, False)


# ── comandos ────────────────────────────────────────────────
def parse_days(v):
    if not str(v).isdigit() or not (1 <= int(v) <= 3650):
        raise Err("Los días deben ser un número entre 1 y 3650.")
    return int(v)

def check_name(name):
    if not NAME_RE.match(name or ""):
        raise Err("Nombre inválido: hasta 40 caracteres (letras, números, espacio, . _ -).")

def cmd_add(proto, name, days):
    check_name(name); days = parse_days(days)
    with lock():
        items = load_reg()
        if find(items, proto, name):
            raise Err(f"Ya existe una cuenta {proto.upper()} llamada '{name}'.")
        dom = get_domain()
        uid = str(_uuid.uuid4())
        exp = (date.today() + timedelta(days=days)).isoformat()
        x_add(proto, uid, name.replace(" ", "_"))
        tls, ntls = links(proto, name, dom, uid)
        it = {"name": name, "uuid": uid, "protocol": proto, "link": tls, "link_ntls": ntls,
              "created": datetime.now().strftime("%Y-%m-%d %H:%M"), "days": days, "expires": exp, "active": True}
        items.append(it)
        try:
            save_reg(items)
        except Exception as e:
            try: x_remove([uid])
            except Err: pass
            raise Err(f"No se pudo guardar el registro: {e}")
    path = "/vless" if proto == "vless" else "/vmess"
    print(f"{Y}    CUENTA {proto.upper()} CREADA EXITOSAMENTE    {N}\n{LINE}")
    print(f" Alias       : {C}{name}{N}\n Dominio     : {C}{dom}{N}\n UUID        : {C}{uid}{N}")
    print(f" Puertos     : {C}443 (TLS) / 80 (NTLS){N}\n Ruta (Path) : {C}{path}{N}\n Expira      : {C}{exp}{N}\n{LINE}")
    print(f"\n {G}LINK TLS (443) :{N}\n{tls}\n\n {G}LINK NTLS (80) :{N}\n{ntls}\n\n{LINE}")

def cmd_del(proto, name):
    with lock():
        items = load_reg()
        it = find(items, proto, name)
        if it:
            x_remove([it["uuid"]])           # primero Xray: si falla, la cuenta se conserva
            items.remove(it)
            save_reg(items)
            print(f"{G}[✔] Cuenta {name} eliminada del panel y de Xray.{N}")
            return
        ids = x_ids_by_email(proto, name.replace(" ", "_"))
        if not ids:
            raise Err(f"No existe la cuenta {proto.upper()} '{name}'.")
        x_remove(ids)
        print(f"{G}[✔] Cuenta {name} (sin registro) eliminada de Xray.{N}")

def cmd_renew(proto, name, days):
    days = parse_days(days)
    with lock():
        items = load_reg()
        it = find(items, proto, name)
        if not it:
            raise Err(f"No existe la cuenta {proto.upper()} '{name}' en el registro.")
        base = date.today()
        try:
            cur = datetime.strptime(str(it.get("expires", "")), "%Y-%m-%d").date()
            if cur > base:
                base = cur
        except ValueError:
            pass
        new_exp = (base + timedelta(days=days)).isoformat()
        if not it.get("blocked"):
            x_add(proto, it["uuid"], str(it["name"]).replace(" ", "_"))   # reactiva si había vencido
            it["active"] = True
        it["expires"] = new_exp
        save_reg(items)
    extra = f" {Y}(sigue BLOQUEADA: desbloquéala para que conecte){N}" if it.get("blocked") else ""
    print(f"{G}[✔] Cuenta {name} renovada. Nuevo vencimiento: {new_exp}{N}{extra}")

def cmd_block(proto, name):
    with lock():
        items = load_reg()
        it = find(items, proto, name)
        if not it:
            raise Err(f"No existe la cuenta {proto.upper()} '{name}' en el registro.")
        if not it.get("blocked"):
            x_remove([it["uuid"]])
            it["blocked"] = True; it["active"] = False
            save_reg(items)
            print(f"{G}[✔] Cuenta {name} BLOQUEADA: ya no puede conectar.{N}")
            return
        left = days_left(it)
        if left is not None and left < 0:
            it["blocked"] = False; it["active"] = False
            save_reg(items)
            print(f"{Y}[!] {name} desbloqueada pero está VENCIDA; renuévala para activarla.{N}")
            return
        x_add(proto, it["uuid"], str(it["name"]).replace(" ", "_"))
        it["blocked"] = False; it["active"] = True
        save_reg(items)
        print(f"{G}[✔] Cuenta {name} DESBLOQUEADA y activa.{N}")

def cmd_list(proto):
    items = [it for it in load_reg() if isinstance(it, dict) and proto_of(it) == proto]
    if not items:
        print("  (no hay cuentas)"); return
    col = {"ACTIVA": G, "VENCIDA": R, "BLOQUEADA": Y, "SIN XRAY": Y}
    print(f"  {'USUARIO':<20}{'VENCE':<13}ESTADO")
    for it in items:
        st = status(it); left = days_left(it)
        extra = f" ({left} d)" if st == "ACTIVA" and left is not None else ""
        print(f"  {str(it.get('name',''))[:19]:<20}{str(it.get('expires') or '—'):<13}{col.get(st,'')}{st}{N}{extra}")

def cmd_purge():
    with lock():
        items = load_reg()
        hoy = date.today().isoformat()
        exp = [it for it in items if isinstance(it, dict) and it.get("active", True) and not it.get("blocked")
               and UUID_RE.match(str(it.get("uuid", ""))) and it.get("expires") and str(it["expires"]) < hoy]
        if not exp:
            return
        x_remove([it["uuid"] for it in exp])
        for it in exp:
            it["active"] = False
        save_reg(items)
        print(f"{Y}[i] {len(exp)} cuenta(s) vencida(s) retirada(s) de Xray.{N}")

def cmd_restore():
    """Tras reinstalar el motor: vuelve a poner en Xray todas las cuentas activas del registro."""
    with lock():
        hoy = date.today().isoformat()
        acts = [it for it in load_reg() if isinstance(it, dict) and it.get("expires") and str(it["expires"]) >= hoy
                and it.get("active", True) and not it.get("blocked") and UUID_RE.match(str(it.get("uuid", "")))]
        if not acts:
            return
        def m(cfg):
            ch = False
            for proto in ("vmess", "vless"):
                for ib in targets(cfg, proto):
                    cl = ib.setdefault("settings", {}).setdefault("clients", [])
                    have = {c.get("id") for c in cl if isinstance(c, dict)}
                    for it in acts:
                        if proto_of(it) == proto and it["uuid"] not in have:
                            cl.append(client_obj(proto, it["uuid"], str(it["name"]).replace(" ", "_")))
                            ch = True
            return ch
        if xray_mutate(m):
            print(f"{G}[✔] Cuentas activas restauradas en Xray.{N}")

def cmd_qr(proto, name, which):
    it = find(load_reg(), proto, name)
    if not it:
        raise Err(f"No existe la cuenta {proto.upper()} '{name}'.")
    link = it.get("link_ntls" if which == "ntls" else "link")
    if not link:
        raise Err("La cuenta no tiene ese enlace.")
    if not shutil.which("qrencode"):
        raise Err("Falta qrencode. Instálalo con: apt install -y qrencode")
    subprocess.run(["qrencode", "-t", "ANSIUTF8", link])

USAGE = {"add": (3, cmd_add), "del": (2, cmd_del), "renew": (3, cmd_renew), "block": (2, cmd_block),
         "list": (1, cmd_list), "purge": (0, cmd_purge), "restore": (0, cmd_restore), "qr": (3, cmd_qr)}

def main(argv):
    if not argv or argv[0] not in USAGE:
        print("uso: v2ray_ctl.py {add|del|renew|block|list|purge|restore|qr} ..."); return 2
    n, fn = USAGE[argv[0]]
    args = argv[1:]
    if len(args) != n:
        print(f"argumentos incorrectos para '{argv[0]}'"); return 2
    if n and args[0] not in ("vmess", "vless"):
        print("el protocolo debe ser vmess o vless"); return 2
    try:
        fn(*args)
        return 0
    except Err as e:
        print(f"{R}[✘] {e}{N}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF
    chmod 700 "$CTL"
}

ctl() { python3 "$CTL" "$@"; }

asegurar_cron() {
    # Retira las cuentas vencidas aunque el panel web no esté corriendo (cada 5 min)
    local cf="/etc/cron.d/vps-manager-v2ray"
    if [ ! -f "$cf" ]; then
        echo "*/5 * * * * root /usr/bin/python3 $CTL purge >/dev/null 2>&1" > "$cf"
        chmod 644 "$cf"
    fi
}

mostrar_cuentas() {
    echo -e "${C_CYAN} Cuentas actuales:${C_NC}"
    ctl list "$PROTO"
    echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
}

menu_vless() {
    if [ ! -f "$FLAG_FILE" ]; then instalar_xray_dual; fi

    while true; do
        ctl purge >/dev/null 2>&1
        clear
        echo -e "${C_YELLOW}        GESTION DE VLESS (80 / 443)        ${C_NC}"
        echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
        echo -e "${C_CYAN}[1] >${C_NC} Crear Cuenta Vless"
        echo -e "${C_CYAN}[2] >${C_NC} Eliminar Cuenta Vless"
        echo -e "${C_CYAN}[3] >${C_NC} Renovar Días de Cuenta"
        echo -e "${C_CYAN}[4] >${C_NC} Bloquear / Desbloquear Cuenta"
        echo -e "${C_CYAN}[5] >${C_NC} Configurar Límite de Dispositivos"
        echo -e "${C_CYAN}[6] >${C_NC} Reinstalar / Reparar Motor Xray"
        echo -e "${C_CYAN}[x] >${C_NC} Salir del Gestor"
        echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
        read -p "Digite su opción: " opc

        case $opc in
            1)
                clear
                echo -e "${C_YELLOW}      CREAR USUARIO XRAY VLESS      ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "Nombre de usuario: " user
                [ -z "$user" ] && continue
                read -p "Duración (días): " dias
                clear
                if ctl add "$PROTO" "$user" "$dias"; then
                    read -p "¿Mostrar código QR (TLS) en pantalla? [s/N]: " q
                    if [[ "$q" =~ ^[sS]$ ]]; then ctl qr "$PROTO" "$user" tls; fi
                fi
                read -p "Presiona ENTER para volver al menú " foo
                ;;
            2)
                clear
                echo -e "${C_YELLOW}     ELIMINAR USUARIO XRAY VLESS     ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                mostrar_cuentas
                read -p "Usuario a eliminar: " user
                [ -z "$user" ] && continue
                ctl del "$PROTO" "$user"
                read -p "Presiona ENTER para continuar..." foo
                ;;
            3)
                clear
                echo -e "${C_YELLOW}      RENOVAR CUENTA XRAY VLESS      ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                mostrar_cuentas
                read -p "Nombre del usuario a renovar: " user
                read -p "Días a sumar: " dias_extras
                { [ -z "$user" ] || [ -z "$dias_extras" ]; } && continue
                ctl renew "$PROTO" "$user" "$dias_extras"
                read -p "Presiona ENTER para continuar..." foo
                ;;
            4)
                clear
                echo -e "${C_YELLOW}     BLOQUEAR / DESBLOQUEAR USUARIO     ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                mostrar_cuentas
                read -p "Nombre del usuario: " user
                [ -z "$user" ] && continue
                ctl block "$PROTO" "$user"
                read -p "Presiona ENTER para continuar..." foo
                ;;
            5)
                clear
                echo -e "${C_YELLOW}      LÍMITE DE DISPOSITIVOS (IPs)      ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "Nombre del usuario: " user
                read -p "Máximo de dispositivos permitidos: " max_disp
                { [ -z "$user" ] || [ -z "$max_disp" ]; } && continue
                if ! [[ "$user" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || ! [[ "$max_disp" =~ ^[0-9]+$ ]]; then
                    echo -e "${C_RED}[!] Datos inválidos.${C_NC}"; read -p "ENTER..." foo; continue
                fi
                mkdir -p /etc/vps-manager
                [ -f "$LIMIT_FILE" ] && sed -i "/^$user /d" "$LIMIT_FILE"
                echo "$user $max_disp" >> "$LIMIT_FILE"
                echo -e "${C_GREEN}[✔] Límite de $max_disp dispositivos registrado para $user.${C_NC}"
                echo -e "${C_YELLOW}[i] Xray no aplica este límite por sí solo: solo queda anotado.${C_NC}"
                read -p "Presiona ENTER para continuar..." foo
                ;;
            6)
                instalar_xray_dual
                ;;
            x|X|"") break ;;
        esac
    done
}

instalar_ctl
asegurar_cron
if [ "$1" = "--purge" ]; then ctl purge; exit 0; fi
menu_vless
