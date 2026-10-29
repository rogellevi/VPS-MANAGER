#!/bin/bash
# ==========================================
# INSTALADOR WSPROXY - VPS MANAGER V5.2
# ==========================================
C_RST='\033[0m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'
C_NEON_BLUE='\033[38;5;39m'
C_NEON_GREEN='\033[38;5;46m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${C_RED}[!] Este script debe ejecutarse como root.${C_RST}"
    sleep 2
    exit 1
fi

clear
echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}      🌐 INSTALADOR WSPROXY (WebSocket)     ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"

# Verificar si ya está instalado
if [ -f /etc/vps-manager/wsproxy.py ] || systemctl is-active --quiet wsproxy.service 2>/dev/null; then
    echo -e "${C_YELLOW}[!] WSProxy ya está instalado en el sistema.${C_RST}"
    echo -e "${C_GREEN}[✔] Usa el submenú del panel para gestionarlo.${C_RST}"
    sleep 3
    exit 0
fi

# Solicitar puerto
while true; do
    echo -ne "${C_YELLOW}Ingrese el puerto de escucha (1024-65535): ${C_RST}"
    read WS_PORT
    if [[ ! "$WS_PORT" =~ ^[0-9]+$ ]] || [ "$WS_PORT" -lt 1024 ] || [ "$WS_PORT" -gt 65535 ]; then
        echo -e "${C_RED}[!] Puerto no válido.${C_RST}"
        continue
    fi
    if ss -lntp 2>/dev/null | grep -q ":$WS_PORT "; then
        local svc=$(ss -lntp 2>/dev/null | grep ":$WS_PORT " | awk '{print $NF}' | cut -d'"' -f2)
        echo -e "${C_RED}[!] Puerto $WS_PORT en uso por: $svc${C_RST}"
        read -p "¿Usarlo de todos modos? (s/n): " usar
        [[ "$usar" != "s" && "$usar" != "S" ]] && continue
    fi
    break
done

echo -e "${C_YELLOW}[+] Instalando Python3...${C_RST}"
apt-get update -y > /dev/null 2>&1
apt-get install python3 -y > /dev/null 2>&1

echo -e "${C_YELLOW}[+] Descargando motor WSProxy...${C_RST}"
mkdir -p /etc/vps-manager
wget -qO /etc/vps-manager/wsproxy.py https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main/core/wsproxy.py

if [ ! -f /etc/vps-manager/wsproxy.py ]; then
    echo -e "${C_RED}[!] Error al descargar wsproxy.py.${C_RST}"
    sleep 3
    exit 1
fi

# Guardar puerto
echo "$WS_PORT" > /etc/vps-manager/wsproxy_port

# Crear servicio systemd
cat > /etc/systemd/system/wsproxy.service << EOF
[Unit]
Description=VPS-Manager WSProxy (WebSocket Proxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vps-manager/wsproxy.py -b 0.0.0.0 -p $WS_PORT
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload > /dev/null 2>&1
systemctl enable wsproxy.service > /dev/null 2>&1
systemctl restart wsproxy.service > /dev/null 2>&1

# UFW
if command -v ufw > /dev/null && ufw status | grep -q "active"; then
    ufw allow "$WS_PORT/tcp" > /dev/null 2>&1
    ufw reload > /dev/null 2>&1
fi

clear
echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}        ✅ WSPROXY INSTALADO CON ÉXITO        ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "  ${C_GREEN}Puerto activo: ${C_YELLOW}$WS_PORT${C_RST}"
echo -e "  ${C_GREEN}Estado: ${C_YELLOW}$(systemctl is-active wsproxy.service)${C_RST}"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
echo -e "${C_GREEN}[✔] Volviendo al menú en 3 segundos...${C_RST}"
sleep 3