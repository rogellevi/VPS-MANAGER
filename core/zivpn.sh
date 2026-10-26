#!/bin/bash
# ==========================================
# Módulo: Zivpn UDP Nativo (Para App Zivpn)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}       INSTALADOR ZIVPN UDP (APP ZIVPN)${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

echo -e "${C_YELLOW}[+] Actualizando sistema e instalando dependencias...${C_NC}"
apt-get update -y >/dev/null 2>&1
systemctl stop zivpn.service >/dev/null 2>&1
apt install -y wget openssl iptables net-tools ufw >/dev/null 2>&1

echo -e "${C_YELLOW}[+] Descargando binarios y configuración de Zivpn...${C_NC}"
wget -q "https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64" -O /usr/local/bin/zivpn
chmod +x /usr/local/bin/zivpn

mkdir -p /etc/zivpn
wget -q "https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json" -O /etc/zivpn/config.json

echo -e "${C_YELLOW}[+] Generando certificados SSL...${C_NC}"
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 -subj "/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=zivpn" -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" 2>/dev/null

# Optimizando el núcleo de red
sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1
sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1

# Crear servicio systemd
cat <<EOF > /etc/systemd/system/zivpn.service
[Unit]
Description=zivpn VPN Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=3
Environment=ZIVPN_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

echo -e "\n${C_CYAN}================================================${C_NC}"
echo -e " 🔑 ${C_GREEN}CONFIGURACIÓN DE CONTRASEÑA (ZIVPN)${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
read -p "Ingresa las contraseñas separadas por comas (Ej: pass1,pass2) [Enter para usar 'zi']: " input_config

if [ -n "$input_config" ]; then
    IFS=',' read -r -a config <<< "$input_config"
    if [ ${#config[@]} -eq 1 ]; then
        config+=(${config[0]})
    fi
else
    config=("zi")
    input_config="zi"
fi

new_config_str="\"config\": [$(printf "\"%s\"," "${config[@]}" \vert{} sed 's/,$//')]"
sed -i -E "s/\"config\": ?\[[[:space:]]*\"zi\"[[:space:]]*\]/${new_config_str}/g" /etc/zivpn/config.json

echo -e "${C_YELLOW}[+] Iniciando servicio y configurando Firewall...${C_NC}"
systemctl daemon-reload
systemctl enable zivpn.service >/dev/null 2>&1
systemctl start zivpn.service

# Configurar puertos en Iptables
interfaz=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
iptables -t nat -A PREROUTING -i $interfaz -p udp --dport 6000:19999 -j DNAT --to-destination :5667
iptables-save > /etc/iptables.up.rules 2>/dev/null

ufw allow 6000:19999/udp >/dev/null 2>&1
ufw allow 5667/udp >/dev/null 2>&1

IP_VPS=$(curl -s ipv4.icanhazip.com)
clear
echo -e "${C_GREEN}[✔] ¡Zivpn UDP instalado y activo con éxito!${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
echo -e " 🌐 Host / IP  : $IP_VPS"
echo -e " 🎯 Puertos    : 6000 al 19999 (Redirige a 5667)"
echo -e " 🔑 Passwords  : $input_config"
echo -e "${C_CYAN}================================================${C_NC}"
read -p "Presione Enter para regresar al menú..."
