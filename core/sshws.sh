#!/bin/bash
# ==========================================
# INSTALADOR SSHWS (WebSocket Proxy) - VPS MANAGER V5.2
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

# Verificar estado
local is_running=0
systemctl is-active --quiet wsproxy.service 2>/dev/null && is_running=1

local WS_PORT="No configurado"
[ -f /etc/vps-manager/wsproxy_port ] && WS_PORT=$(cat /etc/vps-manager/wsproxy_port)

clear
echo -e "${C_NEON_BLUE}══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🌐 GESTIÓN DE SSHWS (WebSocket)      ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════${C_RST}"

if [ "$is_running" -gt 0 ]; then
    echo -e "  Estado: ${C_GREEN}✅ ACTIVO${C_RST}"
    echo -e "  Puerto: ${C_NEON_YELLOW}$WS_PORT${C_RST}"
    echo -e "  Backend: ${C_NEON_YELLOW}127.0.0.1:22 (OpenSSH)${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} ⏹️ Detener y Desinstalar SSHWS"
    echo -e "  ${C_NEON_YELLOW}2.${C_RST} 🔌 Cambiar Puerto"
    echo -e "  ${C_NEON_YELLOW}3.${C_RST} 🔄 Reiniciar Servicio"
else
    echo -e "  Estado: ${C_RED}❌ INACTIVO${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚀 Instalar e Iniciar SSHWS"
fi

echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
read -p "Seleccione una opción: " ws_opt

case $ws_opt in
1)
    if [ "$is_running" -gt 0 ]; then
        echo -e "${C_YELLOW}[+] Deteniendo y desinstalando SSHWS...${C_RST}"
        systemctl stop wsproxy.service 2>/dev/null
        systemctl disable wsproxy.service 2>/dev/null
        rm -f /etc/systemd/system/wsproxy.service
        rm -f /etc/vps-manager/wsproxy.py
        rm -f /etc/vps-manager/wsproxy_port
        systemctl daemon-reload 2>/dev/null
        echo -e "${C_GREEN}[✔] SSHWS desinstalado.${C_RST}"
    else
        clear
        echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
        echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         INSTALADOR SSHWS (WebSocket)       ${C_NEON_BLUE} ${C_RST}"
        echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
        
        echo -ne "${C_YELLOW}¿Qué puerto WebSocket quieres usar? (ej. 80, 8080, 8880): ${C_RST}"
        read ws_port
        
        if [[ ! "$ws_port" =~ ^[0-9]+$ ]] || [ "$ws_port" -lt 1 ] || [ "$ws_port" -gt 65535 ]; then
            echo -e "${C_RED}[!] Puerto no válido.${C_RST}"; sleep 2; exit 1
        fi
        
        if ss -lntp 2>/dev/null | grep -q ":$ws_port "; then
            local svc=$(ss -lntp 2>/dev/null | grep ":$ws_port " | awk '{print $NF}' | cut -d'"' -f2)
            echo -e "${C_RED}[!] El puerto $ws_port ya está en uso por: $svc${C_RST}"; sleep 3; exit 1
        fi
        
        echo -e "${C_YELLOW}[+] Instalando Python3...${C_RST}"
        apt-get update -y >/dev/null 2>&1
        apt-get install python3 -y >/dev/null 2>&1
        
        echo -e "${C_YELLOW}[+] Descargando motor SSHWS...${C_RST}"
        mkdir -p /etc/vps-manager
        wget -qO /etc/vps-manager/wsproxy.py https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main/core/wsproxy.py
        
        if [ ! -f /etc/vps-manager/wsproxy.py ]; then
            echo -e "${C_RED}[!] Error al descargar wsproxy.py.${C_RST}"; sleep 3; exit 1
        fi
        
        echo "$ws_port" > /etc/vps-manager/wsproxy_port
        
        cat > /etc/systemd/system/wsproxy.service << EOF
[Unit]
Description=VPS-Manager SSHWS (WebSocket Proxy)
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vps-manager/wsproxy.py -p $ws_port
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable wsproxy.service >/dev/null 2>&1
        systemctl restart wsproxy.service
        
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
            ufw allow "$ws_port/tcp" >/dev/null 2>&1
        fi
        
        local IP=$(curl -s --max-time 3 ipv4.icanhazip.com || hostname -I | awk '{print $1}')
        echo -e "${C_GREEN}[✔] SSHWS instalado y activo.${C_RST}"
        echo -e "${C_CYAN}Puerto: ${C_YELLOW}$ws_port${C_RST}"
        echo -e "${C_CYAN}URL: ${C_YELLOW}ws://$IP:$ws_port${C_RST}"
        echo -e "${C_YELLOW}Configura tu app (HTTP Injector) así:${C_RST}"
        echo -e "  ${C_GREEN}• Proxy Type: WebSocket / SSHWS${C_RST}"
        echo -e "  ${C_GREEN}• Host: $IP | Puerto: $ws_port${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
    ;;
2)
    if [ "$is_running" -gt 0 ]; then
        echo -ne "${C_YELLOW}Nuevo puerto (1-65535): ${C_RST}"
        read new_port
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
            if ss -lntp 2>/dev/null | grep -q ":$new_port "; then
                echo -e "${C_RED}[!] El puerto $new_port ya está en uso.${C_RST}"
            else
                sed -i "s|ExecStart=.*|ExecStart=/usr/bin/python3 /etc/vps-manager/wsproxy.py -p $new_port|" /etc/systemd/system/wsproxy.service
                echo "$new_port" > /etc/vps-manager/wsproxy_port
                systemctl daemon-reload
                systemctl restart wsproxy.service
                echo -e "${C_GREEN}[✔] Puerto cambiado a $new_port.${C_RST}"
            fi
        else
            echo -e "${C_RED}[!] Puerto inválido.${C_RST}"
        fi
    else
        echo -e "${C_RED}[!] SSHWS no está activo.${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
    ;;
3)
    if [ "$is_running" -gt 0 ]; then
        systemctl restart wsproxy.service
        echo -e "${C_GREEN}[✔] Servicio reiniciado.${C_RST}"
    else
        echo -e "${C_RED}[!] SSHWS no está activo.${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
    ;;
0) exit 0 ;;
*) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
esac