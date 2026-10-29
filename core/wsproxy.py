#!/bin/bash
# ==========================================
# INSTALADOR WSPROXY - VPS MANAGER V5.2
# ==========================================

# Colores (idénticos al menú principal)
C_RST='\033[0m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'
C_NEON_BLUE='\033[38;5;39m'
C_NEON_GREEN='\033[38;5;46m'

# Verificar root
if [ "$EUID" -ne 0 ]; then
    echo -e "${C_RED}[!] Este script debe ejecutarse como root.${C_RST}"
    sleep 2
    exit 1
fi

clear
echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🌐 INSTALADOR WSPROXY (WebSocket)      ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"

# Verificar si ya está instalado
if [ -f /etc/vps-manager/wsproxy.py ] || systemctl is-active --quiet wsproxy.service 2>/dev/null; then
    echo -e "${C_YELLOW}[!] WSProxy ya parece estar instalado en el sistema.${C_RST}"
    read -p "¿Desea reconfigurar los parámetros (Puerto/Pass/Backend)? (s/n): " reconf
    if [[ "$reconf" != "s" && "$reconf" != "S" ]]; then
        echo -e "${C_GREEN}[✔] Operación cancelada. Volviendo al menú...${C_RST}"
        sleep 2
        exit 0
    fi
fi

# Solicitar puerto de escucha
while true; do
    echo -ne "${C_YELLOW}Ingrese el puerto de escucha para WSProxy (ej. 80, 8080, 8880): ${C_RST}"
    read WS_PORT
    
    if [[ ! "$WS_PORT" =~ ^[0-9]+$ ]] || [ "$WS_PORT" -lt 1 ] || [ "$WS_PORT" -gt 65535 ]; then
        echo -e "${C_RED}[!] Puerto no válido. Debe ser un número entre 1 y 65535.${C_RST}"
        continue
    fi
    
    if ss -lntp 2>/dev/null | grep -q ":$WS_PORT "; then
        local svc=$(ss -lntp 2>/dev/null | grep ":$WS_PORT " | awk '{print $NF}' | cut -d'"' -f2)
        echo -e "${C_RED}[!] El puerto $WS_PORT ya está en uso por: $svc${C_RST}"
        read -p "¿Desea usarlo de todos modos? (s/n): " usar
        if [[ "$usar" != "s" && "$usar" != "S" ]]; then
            continue
        fi
    fi
    break
done

# Solicitar contraseña
echo -ne "${C_YELLOW}Ingrese la contraseña de acceso (X-Pass) [Default: 101]: ${C_RST}"
read WS_PASS
[ -z "$WS_PASS" ] && WS_PASS="101"

# Solicitar backend
echo -ne "${C_YELLOW}Ingrese el backend de destino (IP:Puerto) [Default: 127.0.0.1:22]: ${C_RST}"
read WS_BACKEND
[ -z "$WS_BACKEND" ] && WS_BACKEND="127.0.0.1:22"

echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "${C_GREEN}[+] Configuración seleccionada:${C_RST}"
echo -e "  ➔ Puerto de Escucha: ${C_YELLOW}$WS_PORT${C_RST}"
echo -e "  ➔ Contraseña (X-Pass): ${C_YELLOW}$WS_PASS${C_RST}"
echo -e "  ➔ Backend Destino: ${C_YELLOW}$WS_BACKEND${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"

read -p "¿Proceder con la instalación/configuración? (s/n): " confirm
if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then
    echo -e "${C_RED}[!] Instalación cancelada. Volviendo al menú...${C_RST}"
    sleep 2
    exit 0
fi

echo -e "${C_YELLOW}[+] Instalando dependencias (Python3)...${C_RST}"
apt-get update -y > /dev/null 2>&1
apt-get install python3 -y > /dev/null 2>&1

echo -e "${C_YELLOW}[+] Descargando motor WSProxy...${C_RST}"
mkdir -p /etc/vps-manager
wget -qO /etc/vps-manager/wsproxy.py https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main/core/wsproxy.py

if [ ! -f /etc/vps-manager/wsproxy.py ]; then
    echo -e "${C_RED}[!] Error al descargar wsproxy.py. Verifique la URL en GitHub.${C_RST}"
    sleep 3
    exit 1
fi

echo -e "${C_YELLOW}[+] Aplicando configuración personalizada...${C_RST}"
# Usamos | como delimitador en sed para evitar conflictos con las barras del backend
sed -i "s|^PASS = '.*'|PASS = '$WS_PASS'|" /etc/vps-manager/wsproxy.py
sed -i "s|^DEFAULT_HOST = \".*\"|DEFAULT_HOST = \"$WS_BACKEND\"|" /etc/vps-manager/wsproxy.py

echo -e "${C_YELLOW}[+] Creando servicio systemd...${C_RST}"
cat > /etc/systemd/system/wsproxy.service << EOF
[Unit]
Description=VPS-Manager WSProxy (WebSocket Proxy)
After=network-online.target

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

# Configurar UFW si está activo
if command -v ufw > /dev/null && ufw status | grep -q "active"; then
    ufw allow "$WS_PORT/tcp" > /dev/null 2>&1
    ufw reload > /dev/null 2>&1
fi

clear
echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         ✅ WSPROXY INSTALADO CON ÉXITO         ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "  ${C_GREEN}Configuración activa:${C_RST}"
echo -e "  ➔ Puerto: ${C_YELLOW}$WS_PORT${C_RST}"
echo -e "  ➔ Pass: ${C_YELLOW}$WS_PASS${C_RST}"
echo -e "  ➔ Backend: ${C_YELLOW}$WS_BACKEND${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "  ${C_CYAN}Estado del servicio:${C_RST} $(systemctl is-active wsproxy.service | awk '{print ($1=="active" ? "🟢 ACTIVO" : "🔴 INACTIVO")}') "
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
echo -e "${C_GREEN}[✔] Volviendo al menú principal en 3 segundos...${C_RST}"
sleep 3