#!/bin/bash
# ==========================================
# Módulo: CheckUser Multi-App API (Puerto 5432)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
CHK_DIR="/etc/vps-manager/checkuser"
CHK_PORT=5432

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}      INSTALANDO CHECKUSER MULTI-APP (API)      ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

apt update -y >/dev/null 2>&1
apt install python3 jq iptables ufw -y >/dev/null 2>&1
mkdir -p $CHK_DIR

echo -e "${C_YELLOW}[+] Creando API de CheckUser en Python...${C_NC}"
cat << 'EOF' > $CHK_DIR/check.py
import socket, sys, os, subprocess, json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

class CheckUser(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        
        path = urlparse(self.path).path.strip('/')
        if not path:
            self.wfile.write(b'{"error": "No user provided"}')
            return
            
        user = path.split('/')[0]
        
        # Validar si el usuario SSH existe
        try:
            with open('/etc/passwd', 'r') as f:
                users = f.read()
            if f"{user}:" not in users:
                self.wfile.write(b'{"error": "User not found"}')
                return
        except:
            pass

        # Obtener Límite
        limite = "1"
        if os.path.exists(f"/etc/vps-manager/limite_{user}"):
            with open(f"/etc/vps-manager/limite_{user}", 'r') as f:
                limite = f.read().strip()
                
        # Obtener Expiración
        exp = "Ilimitado"
        try:
            chage = subprocess.check_output(f"chage -l {user}", shell=True).decode()
            for line in chage.split('\n'):
                if "Account expires" in line:
                    val = line.split(':')[1].strip()
                    if val != "never": exp = val
        except:
            pass

        # Conteo de conexiones
        count = 0
        try:
            ps = subprocess.check_output(f"ps -ef | grep sshd | grep {user} | grep -v grep | wc -l", shell=True).decode().strip()
            count = int(ps)
        except:
            pass

        data = {
            "username": user,
            "count_connection": count,
            "limit_connection": int(limite),
            "expiration_date": exp,
            "status": "online" if count > 0 else "offline"
        }
        
        self.wfile.write(json.dumps(data).encode('utf-8'))

def run(port=5432):
    server_address = ('', port)
    print(f"CheckUser activo en puerto {port}")
    httpd = HTTPServer(server_address, CheckUser)
    httpd.serve_forever()

if __name__ == '__main__':
    run()
EOF

# Reglas de Firewall para el puerto 5432
iptables -D INPUT -p tcp --dport $CHK_PORT -j ACCEPT 2>/dev/null
iptables -I INPUT -p tcp --dport $CHK_PORT -j ACCEPT
iptables-save > /etc/iptables.up.rules 2>/dev/null
ufw allow $CHK_PORT/tcp >/dev/null 2>&1

echo -e "${C_YELLOW}[+] Activando servicio Systemd...${C_NC}"
cat << EOF > /etc/systemd/system/checkuser.service
[Unit]
Description=CheckUser Multi-App API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CHK_DIR
ExecStart=/usr/bin/python3 $CHK_DIR/check.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable checkuser >/dev/null 2>&1
systemctl restart checkuser

IP_VPS=$(curl -s ipv4.icanhazip.com)
clear
echo -e "${C_GREEN}[✔] ¡CheckUser Multi-App Instalado Correctamente!${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
echo -e " 🌐 URL API   : ${C_YELLOW}http://$IP_VPS:$CHK_PORT/USUARIO${C_NC}"
echo -e " 🎯 Puerto    : ${C_YELLOW}$CHK_PORT${C_NC}"
echo -e " ⚙️ Soporte   : ${C_YELLOW}HTTP Custom, HTTP Injector, Paneles Web${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
read -p "Presione Enter para regresar al menú..."
