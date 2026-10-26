#!/bin/bash
# ==========================================
# Módulo: Panel Web Ultra PRO (Admin + Creador)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
WEB_DIR="/etc/vps-manager/webpanel"

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}    INSTALADOR WEB PANEL PRO (DARK UI)          ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

read -p "Crea un Usuario Admin para el Web: " WEB_USER
read -p "Crea una Contraseña Admin para el Web: " WEB_PASS

apt update -y >/dev/null 2>&1
apt install -y python3 python3-pip python3-venv uuid-runtime >/dev/null 2>&1

mkdir -p "$WEB_DIR"
cd "$WEB_DIR"
rm -rf venv
python3 -m venv venv
source venv/bin/activate
pip install Flask >/dev/null 2>&1

# ==========================================
# CÓDIGO PYTHON / FLASK Y DISEÑO HTML
# ==========================================
cat << 'EOF' > "$WEB_DIR/app.py"
from flask import Flask, render_template_string, request, Response, redirect, url_for
import subprocess
import os
import uuid
import base64

app = Flask(__name__)

USER = "REPLACE_USER"
PASS = "REPLACE_PASS"
BOT_DIR = "/etc/vps-manager/telegram_bot"

def check_auth(username, password):
    return username == USER and password == PASS

def authenticate():
    return Response(
    '<html><body style="background:#0a0e17;color:white;text-align:center;font-family:sans-serif;margin-top:50px;">'
    '<h2>Acceso Denegado</h2><p>Debes iniciar sesión con las credenciales de Admin.</p></body></html>', 401,
    {'WWW-Authenticate': 'Basic realm="GOLBERT VPS PANEL"'})

def requires_auth(f):
    def decorated(*args, **kwargs):
        auth = request.authorization
        if not auth or not check_auth(auth.username, auth.password):
            return authenticate()
        return f(*args, **kwargs)
    decorated.__name__ = f.__name__
    return decorated

@app.route('/')
@requires_auth
def index():
    # Obtener usuarios SSH
    users_raw = subprocess.getoutput("awk -F: '$3 >= 1000 && $1 != \"nobody\" {print $1}' /etc/passwd").split('\n')
    total_users = 0
    online_count = 0
    blocked_count = 0
    expirados_count = 0
    user_cards = ""
    
    for u in users_raw:
        if not u.strip(): continue
        total_users += 1
        exp_date = subprocess.getoutput(f"chage -l {u} | grep 'Account expires' | awk -F': ' '{{print $2}}'")
        if "never" in exp_date.lower() or not exp_date.strip():
            dias_restantes = "Ilimitado"; badge = "CLIENTE"; badge_color = "#28a745"
        else:
            sec_exp = int(subprocess.getoutput(f"date -d '{exp_date}' +%s 2>/dev/null || echo 0"))
            sec_now = int(subprocess.getoutput("date +%s"))
            dias = int((sec_exp - sec_now) / 86400)
            if dias <= 0:
                dias_restantes = "Expirado"; expirados_count += 1; badge = "EXPIRADO"; badge_color = "#dc3545"
            elif dias <= 2:
                dias_restantes = f"{dias} Días"; badge = "DEMO"; badge_color = "#fd7e14"
            else:
                dias_restantes = f"{dias} Días"; badge = "CLIENTE"; badge_color = "#28a745"

        is_locked = "!" in subprocess.getoutput(f"grep '^{u}:' /etc/shadow | cut -d: -f2")
        if is_locked:
            status_text = "BLOCKED"; status_color = "#dc3545"; blocked_count += 1
            action_btn = f'<a href="/action/unlock/{u}" class="btn btn-warning">🔓 Desbloq.</a>'
        else:
            conns = int(subprocess.getoutput(f"ps -ef | grep sshd | grep '{u}' | grep -v root | grep -v grep | wc -l"))
            if conns > 0: status_text = "ONLINE"; status_color = "#28a745"; online_count += 1
            else: status_text = "OFFLINE"; status_color = "#6c757d"
            action_btn = f'<a href="/action/lock/{u}" class="btn btn-danger">🚫 Bloquear</a>'

        user_cards += f"""
        <div class="user-card">
            <div class="user-header"><h2>{u}</h2><span class="badge" style="color: {badge_color}">{badge}</span></div>
            <p>Estado: <strong style="color:{status_color}">{status_text}</strong></p>
            <p>Tiempo restante: <strong>{dias_restantes}</strong></p>
            <div class="card-actions">
                <a href="/action/renew/{u}" class="btn btn-primary">⏱ +30d</a>
                {action_btn}
                <a href="/action/delete/{u}" class="btn btn-dark" onclick="return confirm('¿Eliminar?')">🗑 Eliminar</a>
            </div>
        </div>
        """

    # Obtener Revendedores
    reseller_cards = ""
    res_file = os.path.join(BOT_DIR, "resellers.txt")
    if os.path.exists(res_file):
        with open(res_file, "r") as f:
            for line in f:
                if ":" in line:
                    r_id, creds = line.strip().split(":")
                    reseller_cards += f"""
                    <div class="user-card" style="border: 1px solid #fd7e14;">
                        <div class="user-header"><h2>ID: {r_id}</h2><span class="badge" style="color: #fd7e14">RESELLER</span></div>
                        <p>Créditos Disponibles: <strong style="font-size: 18px; color: #60efff;">{creds}</strong></p>
                    </div>
                    """

    html = f"""
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>GOLBERT PANEL PRO</title>
        <style>
            body {{ background-color: #0a0e17; color: #ffffff; font-family: 'Segoe UI', Tahoma, sans-serif; margin: 0; padding: 15px; }}
            .header-top {{ display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }}
            .logo-title {{ font-size: 20px; font-weight: bold; color: #4facfe; }}
            .dashboard-grid {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin-bottom: 20px; }}
            .stat-box {{ background: #131b2f; padding: 15px 10px; border-radius: 12px; text-align: center; border: 1px solid #1f2d4a; }}
            .stat-box h4 {{ margin: 0; font-size: 12px; color: #8c9baf; }}
            .stat-box h2 {{ margin: 5px 0 0 0; font-size: 22px; }}
            .section-title {{ font-size: 18px; margin-top: 25px; margin-bottom: 15px; border-bottom: 1px solid #1f2d4a; padding-bottom: 5px; color: #60efff; }}
            .user-card {{ background: #131b2f; border-radius: 15px; padding: 20px; margin-bottom: 15px; border: 1px solid #1f2d4a; }}
            .user-header {{ display: flex; justify-content: space-between; align-items: center; margin-bottom: 5px; }}
            .user-header h2 {{ margin: 0; font-size: 20px; }}
            .badge {{ font-weight: bold; font-size: 13px; }}
            .user-card p {{ margin: 5px 0; font-size: 14px; color: #d0d7e1; }}
            .card-actions {{ display: flex; gap: 8px; margin-top: 15px; }}
            .btn {{ flex: 1; text-align: center; padding: 10px 5px; border-radius: 8px; text-decoration: none; font-size: 13px; font-weight: bold; color: white; border:none; cursor: pointer; }}
            .btn-primary {{ background: #0047b3; }} .btn-danger {{ background: #900a22; }} .btn-warning {{ background: #b07d00; }} .btn-dark {{ background: #2c313c; }} .btn-success {{ background: #28a745; }}
            input[type="text"], input[type="password"], input[type="number"] {{ width: 100%; padding: 10px; margin: 5px 0 15px 0; border-radius: 5px; border: 1px solid #1f2d4a; background: #0a0e17; color: white; box-sizing: border-box; }}
            .form-container {{ background: #131b2f; padding: 15px; border-radius: 15px; border: 1px solid #1f2d4a; margin-bottom: 15px; }}
        </style>
    </head>
    <body>
        <div class="header-top"><div class="logo-title">🛡️ GOLBERT PANEL ADMIN</div></div>

        <div class="dashboard-grid">
            <div class="stat-box" style="border-top: 3px solid #28a745;"><h4>🟢 En línea</h4><h2>{online_count}</h2></div>
            <div class="stat-box" style="border-top: 3px solid #fd7e14;"><h4>⏳ Expirados</h4><h2>{expirados_count}</h2></div>
            <div class="stat-box" style="border-top: 3px solid #dc3545;"><h4>🚫 Bloqueados</h4><h2>{blocked_count}</h2></div>
        </div>

        <div class="section-title">➕ Crear Cuentas</div>
        <div class="form-container">
            <form action="/create_ssh" method="POST">
                <h3 style="margin-top:0;">👤 Crear SSH</h3>
                <input type="text" name="user" placeholder="Usuario" required>
                <input type="password" name="pass" placeholder="Contraseña" required>
                <input type="number" name="days" placeholder="Días de duración" required>
                <input type="number" name="limit" placeholder="Límite de Conexiones (ej: 1)" required>
                <button type="submit" class="btn btn-success" style="width:100%; font-size:15px;">Crear SSH</button>
            </form>
        </div>

        <div class="form-container">
            <form action="/create_v2ray" method="POST">
                <h3 style="margin-top:0;">🛡️ Crear V2Ray (VMess)</h3>
                <input type="text" name="user" placeholder="Nombre descriptivo (ej: carlos)" required>
                <button type="submit" class="btn btn-primary" style="width:100%; font-size:15px;">Generar Enlace Vmess</button>
            </form>
        </div>

        <div class="section-title">👥 Revendedores (Bot Telegram)</div>
        {reseller_cards if reseller_cards else '<p style="color:#8c9baf;">No hay revendedores registrados.</p>'}

        <div class="section-title">📋 Usuarios SSH ({total_users})</div>
        {user_cards if user_cards else '<p style="color:#8c9baf;">No hay usuarios creados.</p>'}
    </body>
    </html>
    """
    return html

@app.route('/create_ssh', methods=['POST'])
@requires_auth
def create_ssh():
    u = request.form.get('user').strip()
    p = request.form.get('pass').strip()
    d = request.form.get('days').strip()
    l = request.form.get('limit').strip()
    
    exp_date = subprocess.getoutput(f"date -d '+{d} days' +'%Y-%m-%d'")
    subprocess.getoutput(f"useradd -e {exp_date} -s /bin/false -M {u} && echo '{u}:{p}' | chpasswd")
    subprocess.getoutput(f"echo '{l}' > /etc/vps-manager/limite_{u}")
    
    # Inyectar Banner
    subprocess.getoutput(f"cat /etc/issue.net > /etc/vps-manager/banner_{u}.net && echo \"<br><font color='cyan'>=======================</font><br><font color='yellow'>👤 Usuario:</font> <font color='white'>{u}</font><br><font color='yellow'>📅 Expira:</font> <font color='white'>{exp_date} ({d} Días)</font><br><font color='yellow'>🔒 Límite:</font> <font color='white'>{l} Conexiones</font><br><font color='cyan'>=======================</font><br>\" >> /etc/vps-manager/banner_{u}.net && sed -i '/Match User {u}/d' /etc/ssh/sshd_config && echo -e '\\nMatch User {u}\\nBanner /etc/vps-manager/banner_{u}.net' >> /etc/ssh/sshd_config && systemctl restart ssh")
    
    return redirect(url_for('index'))

@app.route('/create_v2ray', methods=['POST'])
@requires_auth
def create_v2ray():
    u = request.form.get('user').strip()
    v_uuid = str(uuid.uuid4())
    ip = subprocess.getoutput("curl -s ipv4.icanhazip.com")
    dom = subprocess.getoutput("[ -f /etc/vps-manager/dominio ] && cat /etc/vps-manager/dominio || echo '" + ip + "'")
    
    vmess_json = f'{{"v":"2","ps":"{u}","add":"{dom}","port":"443","id":"{v_uuid}","aid":"0","scy":"auto","net":"ws","type":"none","host":"{dom}","path":"/vmess","tls":"tls","sni":"{dom}","alpn":""}}'
    vmess_base64 = base64.b64encode(vmess_json.encode('utf-8')).decode('utf-8')
    vmess_link = f"vmess://{vmess_base64}"
    
    return f"<html><body style='background:#0a0e17;color:white;padding:20px;font-family:sans-serif;'><h2>✅ V2Ray Creado</h2><p>Usuario: {u}</p><p>UUID: {v_uuid}</p><textarea style='width:100%;height:100px;background:#131b2f;color:#60efff;border:1px solid #1f2d4a;padding:10px;'>{vmess_link}</textarea><br><br><a href='/' style='color:white;text-decoration:none;background:#0047b3;padding:10px;border-radius:5px;'>Volver al Panel</a></body></html>"

@app.route('/action/<cmd>/<user>')
@requires_auth
def action(cmd, user):
    if not subprocess.getoutput(f"id -u {user} 2>/dev/null"): return redirect(url_for('index'))
    if cmd == "lock":
        subprocess.getoutput(f"usermod -L {user}"); subprocess.getoutput(f"pkill -u {user}")
    elif cmd == "unlock":
        subprocess.getoutput(f"usermod -U {user}")
    elif cmd == "delete":
        subprocess.getoutput(f"userdel -f {user}"); subprocess.getoutput(f"rm -f /etc/vps-manager/banner_{user}.net /etc/vps-manager/limite_{user}"); subprocess.getoutput(f"sed -i '/Match User {user}/,+1d' /etc/ssh/sshd_config"); subprocess.getoutput("systemctl restart ssh")
    elif cmd == "renew":
        subprocess.getoutput(f"chage -E $(date -d '+30 days' +'%Y-%m-%d') {user}")
    return redirect(url_for('index'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8181)
EOF

sed -i "s/REPLACE_USER/$WEB_USER/g" "$WEB_DIR/app.py"
sed -i "s/REPLACE_PASS/$WEB_PASS/g" "$WEB_DIR/app.py"

iptables -I INPUT -p tcp --dport 8181 -j ACCEPT
iptables-save > /etc/iptables.up.rules 2>/dev/null

cat << EOF > /etc/systemd/system/vps-webpanel.service
[Unit]
Description=Golbert VPS Web Panel PRO
After=network.target

[Service]
User=root
WorkingDirectory=$WEB_DIR
ExecStart=$WEB_DIR/venv/bin/python $WEB_DIR/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vps-webpanel >/dev/null 2>&1
systemctl restart vps-webpanel

IP_VPS=$(curl -s ipv4.icanhazip.com)
clear
echo -e "${C_GREEN}[✔] ¡Panel Web PRO Instalado!${C_NC}\nURL: ${C_YELLOW}http://$IP_VPS:8181${C_NC}"
read -p "Presione Enter para regresar..."
