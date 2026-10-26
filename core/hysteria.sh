#!/bin/bash
# ==========================================
# Módulo: Hysteria v1 Pro (Alineado a Puerto 20000 y Obfs)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'

HYS_DIR="/etc/vps-manager/hysteria"
HYS_PORT=20000

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}   INSTALADOR HYSTERIA v1 (PUERTO 20000)        ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

apt update -y >/dev/null 2>&1
apt install -y wget curl openssl iptables net-tools ufw >/dev/null 2>&1

systemctl stop hysteria.service >/dev/null 2>&1

mkdir -p "$HYS_DIR"
cd "$HYS_DIR"

wget -qO hysteria "https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64"
if [ ! -s "hysteria" ]; then
    wget -qO hysteria "https://github.com/tobyxdd/hysteria/releases/download/v1.3.5/hysteria-linux-amd64"
fi
chmod +x hysteria

# Certificados SSL para QUIC
openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -subj "/C=US/ST=California/L=Los Angeles/O=Hysteria/CN=bing.com" \
    -keyout "$HYS_DIR/server.key" -out "$HYS_DIR/server.crt" 2>/dev/null

echo -e "\n${C_CYAN}================================================${C_NC}"
echo -e " 🔑 ${C_GREEN}CONFIGURACIÓN DE CREDENCIALES Hysteria v1${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
read -p "Contraseña (la misma que pusiste en Autenticación 'grey:grey' o similar) [Enter para 'grey']: " HYS_PASS
[ -z "$HYS_PASS" ] && HYS_PASS="grey"

read -p "Puerto UDP [Por defecto 20000]: " INPUT_PORT
[ -n "$INPUT_PORT" ] && HYS_PORT="$INPUT_PORT"

# Archivo de configuración JSON completo con Obfs y Auth alineados a la app
cat << EOF > "$HYS_DIR/config.json"
{
  "listen": ":$HYS_PORT",
  "protocol": "udp",
  "cert": "$HYS_DIR/server.crt",
  "key": "$HYS_DIR/server.key",
  "up_mbps": 100,
  "down_mbps": 100,
  "obfs": "golbert",
  "auth": "$HYS_PASS"
}
EOF

# Abrir puertos en cortafuegos (UFW e IPTables)
iptables -D INPUT -p udp --dport $HYS_PORT -j ACCEPT 2>/dev/null
iptables -I INPUT -p udp --dport $HYS_PORT -j ACCEPT
iptables-save > /etc/iptables.up.rules 2>/dev/null
ufw allow ${HYS_PORT}/udp >/dev/null 2>&1

cat << EOF > /etc/systemd/system/hysteria.service
[Unit]
Description=Hysteria v1 Server Pro
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$HYS_DIR
ExecStart=$HYS_DIR/hysteria -c $HYS_DIR/config.json server
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria.service >/dev/null 2>&1
systemctl restart hysteria.service

IP_VPS=$(curl -s ipv4.icanhazip.com)
DOM=$( [ -f /etc/vps-manager/dominio ] && cat /etc/vps-manager/dominio || echo "$IP_VPS" )

clear
echo -e "${C_GREEN}[✔] ¡Hysteria v1 configurado perfectamente en el puerto $HYS_PORT!${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
echo -e " 🌐 Host / Servidor : ${C_YELLOW}$DOM${C_NC}"
echo -e " 🎯 Puerto UDP      : ${C_YELLOW}$HYS_PORT${C_NC}"
echo -e " 🔑 Autenticación   : ${C_YELLOW}$HYS_PASS${C_NC}"
echo -e " 🛡️ Obfuscación     : ${C_YELLOW}golbert${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
read -p "Presione Enter para regresar..."
