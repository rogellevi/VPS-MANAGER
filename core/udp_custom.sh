#!/bin/bash
# ==========================================
# Módulo: UDP Custom (Oficial eProxy Devs)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
UDP_DIR="/etc/vps-manager/udp"
UDP_PORT=25000

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}   INSTALADOR UDP CUSTOM (OFICIAL ePROXY)       ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

systemctl stop udp-custom >/dev/null 2>&1
fuser -k ${UDP_PORT}/udp >/dev/null 2>&1
mkdir -p $UDP_DIR
cd $UDP_DIR
rm -f udp-custom

echo -e "${C_YELLOW}[+] Descargando binario oficial (hexpn/udp-custom)...${C_NC}"
# Repositorio fuente original de los creadores de UDP Custom
wget -qO udp-custom "https://raw.githubusercontent.com/hexpn/udp-custom/main/udp-custom-linux-amd64"
if [ ! -s "udp-custom" ]; then
    wget -qO udp-custom "https://raw.githubusercontent.com/rudi9999/ADMRufu/main/Plugins/udp-custom"
fi
chmod +x udp-custom

echo -e "${C_YELLOW}[+] Abriendo puerto $UDP_PORT en el Firewall...${C_NC}"
iptables -D INPUT -p udp --dport $UDP_PORT -j ACCEPT 2>/dev/null
iptables -I INPUT -p udp --dport $UDP_PORT -j ACCEPT
iptables-save > /etc/iptables.up.rules 2>/dev/null
ufw allow ${UDP_PORT}/udp >/dev/null 2>&1

echo -e "${C_YELLOW}[+] Configurando servicio Systemd...${C_NC}"
cat << EOF > /etc/systemd/system/udp-custom.service
[Unit]
Description=UDP Custom Official by eProxy
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$UDP_DIR
ExecStart=$UDP_DIR/udp-custom server -l 0.0.0.0:$UDP_PORT -exclude 53,5300,7300,7200
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable udp-custom >/dev/null 2>&1
systemctl restart udp-custom

echo -e "${C_GREEN}[✔] ¡UDP Custom oficial instalado y operando en el puerto $UDP_PORT!${C_NC}"
read -p "Presione Enter para regresar..."
