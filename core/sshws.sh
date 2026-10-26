#!/bin/bash
# ==========================================
# Módulo: SSH WebSocket + SSL (Proxy para Payloads)
# ==========================================

clear
echo -e "\033[1;36m[+] Instalando Python y Stunnel4...\033[0m"
apt update -y && apt install -y python3 stunnel4 >/dev/null 2>&1

mkdir -p /etc/vps-manager/core

# 1. Crear el Proxy Python (Escucha en puerto 80)
cat << 'EOF' > /etc/vps-manager/core/proxy.py
import socket, threading, sys

def handle_client(client_socket):
    try:
        request = client_socket.recv(1024).decode('utf-8', errors='ignore')
        if not request:
            client_socket.close()
            return

        # Responder al Payload (GET, CONNECT, POST, etc.)
        response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        client_socket.send(response.encode())

        # Conectar al SSH local (puerto 22)
        ssh_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ssh_socket.connect(('127.0.0.1', 22))

        # Hilos para transferir datos
        threading.Thread(target=transfer, args=(client_socket, ssh_socket)).start()
        threading.Thread(target=transfer, args=(ssh_socket, client_socket)).start()
    except:
        client_socket.close()

def transfer(src, dst):
    try:
        while True:
            data = src.recv(4096)
            if not data: break
            dst.send(data)
    except:
        pass
    finally:
        src.close()
        dst.close()

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', 80))
server.listen(100)
print("Proxy WebSocket escuchando en el puerto 80...")

while True:
    client, addr = server.accept()
    threading.Thread(target=handle_client, args=(client,)).start()
EOF

# 2. Crear certificado SSL para Stunnel4
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/C=PE/ST=Lima/L=Lima/O=Golbert/CN=golbertvps.online" \
    -keyout /etc/stunnel/stunnel.pem -out /etc/stunnel/stunnel.pem >/dev/null 2>&1

# 3. Configurar Stunnel4 (Escucha en 443 y redirige al 80)
cat << 'EOF' > /etc/stunnel/stunnel.conf
pid = /var/run/stunnel.pid
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ws-ssl]
accept = 443
connect = 127.0.0.1:80
EOF

sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4

# 4. Crear Servicio Systemd para el Proxy Python
cat << 'EOF' > /etc/systemd/system/ws-python.service
[Unit]
Description=Proxy Python WebSocket (Golbert VPS)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /etc/vps-manager/core/proxy.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 5. Reiniciar Servicios
systemctl daemon-reload
systemctl enable ws-python
systemctl restart ws-python
systemctl restart stunnel4

echo -e "\n\033[1;32m[✔] SSH WebSocket (Puerto 80) y SSL (Puerto 443) instalados correctamente.\033[0m"
sleep 2
