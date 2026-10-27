#!/bin/bash
# ==========================================
# Módulo: SSL / TLS Proxy (Stunnel4)
# Puerto Dinámico con Prevención de Conflictos
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
SSL_DIR="/etc/stunnel"

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}     INSTALADOR SSL / TLS (STUNNEL4 - SSH)      ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

read -p "Ingresa el puerto para SSL/TLS [Por defecto 444]: " INPUT_PORT
SSL_PORT=${INPUT_PORT:-444}

# 1. Sistema Anti-Conflictos: Verificar si el puerto ya está en uso
if ss -lntp 2>/dev/null | grep -q ":$SSL_PORT "; then
    echo -e "\n${C_RED}[!] ERROR CRÍTICO: El puerto $SSL_PORT ya está en uso por otro servicio.${C_NC}"
    echo -e "${C_YELLOW}Por favor, elige un puerto diferente para evitar conflictos de red.${C_NC}"
    read -p "Presione Enter para regresar..."
    exit 1
fi

mkdir -p /etc/vps-manager
echo "$SSL_PORT" > /etc/vps-manager/ssl_port

echo -e "${C_YELLOW}[+] Instalando Stunnel4 y utilidades...${C_NC}"
apt update -y >/dev/null 2>&1
apt install -y stunnel4 iptables ufw openssl >/dev/null 2>&1

echo -e "${C_YELLOW}[+] Configurando Reglas de Enrutamiento (Stunnel)...${C_NC}"
cat << EOF > $SSL_DIR/stunnel.conf
pid = /var/run/stunnel.pid
cert = $SSL_DIR/stunnel.pem
client = no
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh-tls]
accept = $SSL_PORT
connect = 127.0.0.1:22
EOF

# Habilitar servicio en el arranque
sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4

# Si no hay un SSL generado por domain.sh, creamos uno provisional para que el servicio no falle
if [ ! -f "$SSL_DIR/stunnel.pem" ]; then
    echo -e "${C_YELLOW}[+] Generando Certificado SSL Local Provisional...${C_NC}"
    openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
        -subj "/C=US/ST=CA/L=LosAngeles/O=GolbertVPS/CN=golbert" \
        -keyout $SSL_DIR/stunnel.pem -out $SSL_DIR/stunnel.pem >/dev/null 2>&1
    chmod 600 $SSL_DIR/stunnel.pem
fi

echo -e "${C_YELLOW}[+] Abriendo puerto $SSL_PORT en el Firewall...${C_NC}"
iptables -D INPUT -p tcp --dport $SSL_PORT -j ACCEPT 2>/dev/null
iptables -I INPUT -p tcp --dport $SSL_PORT -j ACCEPT
iptables-save > /etc/iptables.up.rules 2>/dev/null
ufw allow ${SSL_PORT}/tcp >/dev/null 2>&1

echo -e "${C_YELLOW}[+] Iniciando Servicio SSL/TLS...${C_NC}"
systemctl restart stunnel4
systemctl enable stunnel4 >/dev/null 2>&1

IP_VPS=$(curl -s ipv4.icanhazip.com)
DOM=$( [ -f /etc/vps-manager/dominio ] && cat /etc/vps-manager/dominio || echo "$IP_VPS" )

clear
echo -e "${C_GREEN}[✔] ¡Conexión SSL/TLS instalada y asegurada sin conflictos!${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
echo -e " 🌐 Host / Dominio : ${C_YELLOW}$DOM${C_NC}"
echo -e " 🎯 Puerto SSL/TLS : ${C_YELLOW}$SSL_PORT${C_NC}"
echo -e " ⚡ Destino Proxy  : ${C_YELLOW}SSH Local (127.0.0.1:22)${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
read -p "Presione Enter para regresar al menú..."
