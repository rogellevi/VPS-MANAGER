#!/bin/bash
# ==========================================
# Módulo: BadVPN Nativo (Puertos 7300 y 7200)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}       INSTALANDO BADVPN (7300 y 7200)          ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

apt update -y >/dev/null 2>&1
apt install -y cmake g++ make git screen >/dev/null 2>&1

cd /tmp
rm -rf badvpn
git clone https://github.com/ambrop72/badvpn.git >/dev/null 2>&1
mkdir -p badvpn-build
cd badvpn-build
cmake ../badvpn -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null 2>&1
make install >/dev/null 2>&1

# Crear servicio Systemd para el puerto 7300
cat << EOF > /etc/systemd/system/badvpn-7300.service
[Unit]
Description=BadVPN UDPGW Port 7300
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500 --max-connections-for-client 20
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Crear servicio Systemd para el puerto 7200
cat << EOF > /etc/systemd/system/badvpn-7200.service
[Unit]
Description=BadVPN UDPGW Port 7200
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7200 --max-clients 500 --max-connections-for-client 20
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable badvpn-7300 badvpn-7200 >/dev/null 2>&1
systemctl restart badvpn-7300 badvpn-7200

echo -e "${C_GREEN}[✔] ¡BadVPN configurado y activo en puertos 7300 y 7200!${C_NC}"
read -p "Presione Enter para regresar..."
