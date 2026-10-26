#!/bin/bash
# ==========================================
# Módulo: SlowDNS / DNSTT Oficial (Bind Universal 0.0.0.0:53)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
DNS_DIR="/etc/vps-manager/slowdns"
mkdir -p "$DNS_DIR"

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}   INSTALADOR OFICIAL SLOWDNS (PUERTO 53 -> 22)  ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

read -p "Ingresa tu subdominio NS (Ej: ns-centrix.golbertvps.online): " NS_DOMAIN
if [ -z "$NS_DOMAIN" ]; then
    echo -e "${C_RED}[!] Error: Debes ingresar un subdominio NS válido.${C_NC}"
    sleep 2
    exit 1
fi
echo "$NS_DOMAIN" > /etc/vps-manager/nsdomain

apt update -y >/dev/null 2>&1
apt install -y wget iptables net-tools coreutils >/dev/null 2>&1

cd "$DNS_DIR"
wget -qO dnstt-server "https://raw.githubusercontent.com/rudi9999/ADMRufu/main/Plugins/dnstt-server"
chmod +x dnstt-server

if [ ! -f "$DNS_DIR/server.key" ] || [ ! -f "$DNS_DIR/server.pub" ]; then
    rm -f server.key server.pub
    ./dnstt-server -gen-key -privkey-file server.key -pubkey-file server.pub >/dev/null 2>&1
fi

PUB_KEY=$(cat "$DNS_DIR/server.pub" | tr -d '\r\n')

systemctl stop systemd-resolved >/dev/null 2>&1
systemctl disable systemd-resolved >/dev/null 2>&1
killall -9 dnstt-server 2>/dev/null
killall -9 named 2>/dev/null
killall -9 bind9 2>/dev/null

iptables -D INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null
iptables -I INPUT -p udp --dport 53 -j ACCEPT
iptables-save > /etc/iptables.up.rules 2>/dev/null

cat << EOF > /etc/systemd/system/vps-slowdns.service
[Unit]
Description=DNSTT SlowDNS Official Server
After=network.target ssh.service

[Service]
Type=simple
User=root
WorkingDirectory=$DNS_DIR
ExecStart=$DNS_DIR/dnstt-server -udp 0.0.0.0:53 -privkey-file $DNS_DIR/server.key -mtu 1232 $NS_DOMAIN 127.0.0.1:22
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vps-slowdns >/dev/null 2>&1
systemctl restart vps-slowdns

clear
echo -e "${C_GREEN}[✔] ¡SlowDNS Oficial (DNSTT) instalado y activo!${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
echo -e " 🌐 NS Domain : ${C_YELLOW}$NS_DOMAIN${C_NC}"
echo -e " 🔑 Pub Key   : ${C_YELLOW}$PUB_KEY${C_NC}"
echo -e " 🎯 Túnel     : UDP 0.0.0.0:53 ➔ SSH 127.0.0.1:22"
echo -e "${C_CYAN}================================================${C_NC}"
read -p "Presione Enter para regresar..."
