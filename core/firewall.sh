#!/bin/bash
# ==========================================
# Módulo: Gestor de Firewall y Seguridad
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}        GESTOR DE FIREWALL (IPTABLES / UFW)${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "  ${C_YELLOW}1.${C_NC} 🔓 Abrir Todos los Puertos del Panel (Recomendado)"
echo -e "  ${C_YELLOW}2.${C_NC} 🚫 Bloquear Tráfico Torrent / P2P (Evitar Baneos)"
echo -e "  ${C_YELLOW}3.${C_NC} 🧹 Limpiar todas las reglas (Reset Firewall)"
echo -e "  ${C_RED}0.${C_NC} 🚪 Salir"
echo -e "${C_CYAN}================================================${C_NC}"
read -p "Seleccione una opción: " optfw

case $optfw in
    1)
        echo -e "${C_YELLOW}[+] Abriendo puertos TCP y UDP...${C_NC}"
        apt install iptables-persistent ufw -y >/dev/null 2>&1
        # Puertos TCP (SSH, Web, Xray, OpenVPN, BHTTP, CheckUser)
        for port in 22 80 443 2081 2083 8080 8880 8181 7300 7200 5432; do
            iptables -I INPUT -p tcp --dport $port -j ACCEPT
            ufw allow $port/tcp >/dev/null 2>&1
        done
        # Puertos UDP (DNS, UDP Custom, Hysteria)
        for port in 53 25000 20000 36712; do
            iptables -I INPUT -p udp --dport $port -j ACCEPT
            ufw allow $port/udp >/dev/null 2>&1
        done
        # Rango Zivpn
        iptables -I INPUT -p udp --dport 6000:19999 -j ACCEPT
        ufw allow 6000:19999/udp >/dev/null 2>&1
        iptables-save > /etc/iptables.up.rules
        echo -e "${C_GREEN}[✔] ¡Todos los puertos del panel están abiertos y seguros!${C_NC}"
        ;;
    2)
        echo -e "${C_YELLOW}[+] Aplicando reglas Anti-Torrent y P2P...${C_NC}"
        iptables -A FORWARD -m string --algo bm --string "BitTorrent" -j DROP
        iptables -A FORWARD -m string --algo bm --string "BitTorrent protocol" -j DROP
        iptables -A FORWARD -m string --algo bm --string "peer_id=" -j DROP
        iptables -A FORWARD -m string --algo bm --string ".torrent" -j DROP
        iptables -A FORWARD -m string --algo bm --string "announce.php?passkey=" -j DROP
        iptables-save > /etc/iptables.up.rules
        echo -e "${C_GREEN}[✔] ¡Tráfico Torrent y Spam bloqueado exitosamente!${C_NC}"
        ;;
    3)
        echo -e "${C_YELLOW}[+] Limpiando Firewall...${C_NC}"
        iptables -F
        iptables -X
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables-save > /etc/iptables.up.rules
        echo -e "${C_GREEN}[✔] ¡Firewall reseteado y libre!${C_NC}"
        ;;
esac
read -p "Presione Enter para regresar..."
