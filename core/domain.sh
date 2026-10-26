#!/bin/bash
# ==========================================
# Módulo: Gestor de Dominio y SSL (Actualizado)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
DOM_FILE="/etc/vps-manager/dominio"
mkdir -p /etc/vps-manager

tramitar_ssl() {
    local dom=$1
    echo -e "${C_YELLOW}[+] Deteniendo servicios para liberar el puerto 80...${C_NC}"
    systemctl stop nginx apache2 haproxy xray ws-python stunnel4 bhttp 2>/dev/null
    fuser -k 80/tcp 2>/dev/null
    
    echo -e "${C_YELLOW}[+] Solicitando Certificado SSL Let's Encrypt para: $dom${C_NC}"
    apt install -y certbot >/dev/null 2>&1
    certbot certonly --standalone -d "$dom" --non-interactive --agree-tos -m "admin@$dom"
    
    if [ -d "/etc/letsencrypt/live/$dom" ]; then
        echo -e "${C_GREEN}[✔] Certificado generado. Distribuyendo a Xray y Stunnel...${C_NC}"
        mkdir -p /usr/local/etc/xray /etc/stunnel
        cp /etc/letsencrypt/live/$dom/fullchain.pem /usr/local/etc/xray/server.crt 2>/dev/null
        cp /etc/letsencrypt/live/$dom/privkey.pem /usr/local/etc/xray/server.key 2>/dev/null
        chown nobody:nogroup /usr/local/etc/xray/server.crt /usr/local/etc/xray/server.key 2>/dev/null
        cat /etc/letsencrypt/live/$dom/fullchain.pem /etc/letsencrypt/live/$dom/privkey.pem > /etc/stunnel/stunnel.pem 2>/dev/null
        echo -e "${C_GREEN}[✔] ¡Dominio y Certificado 100% operativos!${C_NC}"
    else
        echo -e "${C_RED}[!] Error: No se pudo generar el SSL.${C_NC}"
        echo -e "${C_YELLOW}Verifica que el dominio apunte a tu IP en Cloudflare (Nube gris).${C_NC}"
    fi
    echo -e "${C_YELLOW}[+] Reiniciando servicios...${C_NC}"
    systemctl start xray ws-python stunnel4 bhttp 2>/dev/null
}

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}     GESTOR DE DOMINIO Y CERTIFICADO SSL        ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "  ${C_YELLOW}1.${C_NC} 🌐 Configurar Nuevo Subdominio y Certificar"
echo -e "  ${C_YELLOW}2.${C_NC} 🔄 Re-certificar Subdominio Actual (Solución Errores)"
echo -e "  ${C_RED}0.${C_NC} 🚪 Salir"
echo -e "${C_CYAN}================================================${C_NC}"
read -p "Seleccione una opción: " optdom

case $optdom in
    1)
        read -p "Ingresa tu nuevo Subdominio: " ndom
        if [ -n "$ndom" ]; then
            echo "$ndom" > $DOM_FILE
            tramitar_ssl "$ndom"
        fi
        ;;
    2)
        if [ -f "$DOM_FILE" ]; then
            adom=$(cat $DOM_FILE)
            echo -e "${C_YELLOW}[+] Re-certificando el dominio guardado: $adom${C_NC}"
            tramitar_ssl "$adom"
        else
            echo -e "${C_RED}[!] No hay dominio guardado en el VPS. Usa la opción 1.${C_NC}"
        fi
        ;;
esac
read -p "Presione Enter para regresar..."
