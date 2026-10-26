#!/bin/bash
# ==========================================
# Módulo: BHTTP Pro (Núcleo Python 100% Compatible)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
BHTTP_DIR="/etc/vps-manager/bhttp"

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}   INSTALADOR BHTTP PRO (NÚCLEO PYTHON)         ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

read -p "Ingresa el puerto para BHTTP [Por defecto 8080]: " INPUT_PORT
BHTTP_PORT=${INPUT_PORT:-8080}
mkdir -p /etc/vps-manager
echo "$BHTTP_PORT" > /etc/vps-manager/bhttp_port

echo -e "${C_YELLOW}[+] Deteniendo servicios y preparando entorno...${C_NC}"
apt update -y >/dev/null 2>&1
apt install -y python3 iptables ufw >/dev/null 2>&1

systemctl stop bhttp.service >/dev/null 2>&1
fuser -k ${BHTTP_PORT}/tcp >/dev/null 2>&1
mkdir -p $BHTTP_DIR

cat << 'EOF' > $BHTTP_DIR/bhttp.py
import socket, threading, select
LISTEN_PORT = PORT_PLACEHOLDER

def handle_client(client_sock):
    client_sock.settimeout(10)
    try:
        request = client_sock.recv(65535)
        if not request: return
    except: return
    client_sock.settimeout(None)
    
    ssh_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try: ssh_sock.connect(('127.0.0.1', 22))
    except: return
    
    # Puente compatible con túneles BHTTP y Payload
    if b'SSH-' in request:
        ssh_sock.sendall(request[request.find(b'SSH-'):])
    else:
        client_sock.sendall(b"HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n\r\n")
        if b'\r\n\r\n' in request:
            body = request.split(b'\r\n\r\n', 1)[1]
            if body: ssh_sock.sendall(body)
        
    sockets = [client_sock, ssh_sock]
    while True:
        r, _, e = select.select(sockets, [], sockets, 300)
        if e or not r: break
        for s in r:
            try:
                data = s.recv(65535)
                if not data: return
                if s is client_sock: ssh_sock.sendall(data)
                else: client_sock.sendall(data)
            except: return

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', LISTEN_PORT))
server.listen(1024)
while True:
    try:
        client, _ = server.accept()
        threading.Thread(target=handle_client, args=(client,), daemon=True).start()
    except: continue
EOF

sed -i "s/PORT_PLACEHOLDER/$BHTTP_PORT/g" $BHTTP_DIR/bhttp.py

iptables -D INPUT -p tcp --dport $BHTTP_PORT -j ACCEPT 2>/dev/null
iptables -I INPUT -p tcp --dport $BHTTP_PORT -j ACCEPT
iptables-save > /etc/iptables.up.rules 2>/dev/null
ufw allow ${BHTTP_PORT}/tcp >/dev/null 2>&1

cat << EOF > /etc/systemd/system/bhttp.service
[Unit]
Description=BHTTP Core Python (Port $BHTTP_PORT)
After=network.target ssh.service

[Service]
Type=simple
User=root
WorkingDirectory=$BHTTP_DIR
ExecStart=/usr/bin/python3 $BHTTP_DIR/bhttp.py
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable bhttp >/dev/null 2>&1
systemctl restart bhttp

echo -e "${C_GREEN}[✔] ¡Motor BHTTP activo y estable en el puerto $BHTTP_PORT!${C_NC}"
read -p "Presione Enter para regresar..."
