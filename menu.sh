#!/bin/bash
# ==========================================
# Golbert VPS Premium - Panel V5.0 LTS (Bilingüe / Multi-Ubuntu)
# ==========================================

C_RST='\033[0m'; C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'
C_NEON_BLUE='\033[38;5;39m'; C_NEON_GREEN='\033[38;5;46m'; C_NEON_PURPLE='\033[38;5;141m'; C_NEON_YELLOW='\033[38;5;226m'
mkdir -p /etc/vps-manager
[ ! -f /etc/vps-manager/lang ] && echo "es" > /etc/vps-manager/lang

if [ -f /etc/os-release ]; then . /etc/os-release; UBUNTU_VERSION=$VERSION_ID; else UBUNTU_VERSION="24.04"; fi

generar_banner_usuario() {
    local u=$1; local exp=$2; local dias=$3; local limit=$4
    local base=$(cat /etc/issue.net 2>/dev/null)
    local banner_file="/etc/vps-manager/banner_${u}.net"
    echo -e "${base}<br><font color='cyan'>=======================</font><br><font color='yellow'>👤 Usuario:</font> <font color='white'>${u}</font><br><font color='yellow'>📅 Expira:</font> <font color='white'>${exp} (${dias} Días)</font><br><font color='yellow'>🔒 Límite:</font> <font color='white'>${limit} Conexiones</font><br><font color='cyan'>=======================</font><br>" > "$banner_file"
    sed -i "/Match User $u/d" /etc/ssh/sshd_config
    sed -i "/Banner \/etc\/vps-manager\/banner_${u}.net/d" /etc/ssh/sshd_config
    echo -e "\nMatch User $u\nBanner $banner_file" >> /etc/ssh/sshd_config
}

menu_idioma() {
    clear
    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_NEON_BLUE}║${C_NEON_GREEN}       🌐 SELECCIONA TU IDIOMA / LANGUAGE     ${C_NEON_BLUE}║${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🇪🇸 Español (Spanish)"
    echo -e "  ${C_NEON_YELLOW}2.${C_RST} 🇺🇸 English (Inglés)"
    echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
    read -p " Opción / Option: " lang_opt
    case $lang_opt in
        1) echo "es" > /etc/vps-manager/lang; echo -e "${C_GREEN}[✔] Idioma cambiado a Español.${C_RST}"; sleep 2 ;;
        2) echo "en" > /etc/vps-manager/lang; echo -e "${C_GREEN}[✔] Language changed to English.${C_RST}"; sleep 2 ;;
        *) echo -e "${C_RED}[!] Opción inválida / Invalid option.${C_RST}"; sleep 2 ;;
    esac
}

menu_ssh() {
    while true; do
        clear
        echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
        echo -e "${C_NEON_BLUE}║${C_NEON_GREEN}         🛰️ GESTION DE SSH (USUARIOS)         ${C_NEON_BLUE}║${C_RST}"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_NEON_YELLOW}1${C_RST} ➔ Crear Cuenta SSH (Normal / HWID)"
        echo -e "  ${C_NEON_YELLOW}2${C_RST} ➔ Eliminar Cuenta SSH"
        echo -e "  ${C_NEON_YELLOW}3${C_RST} ➔ Renovar Cuenta SSH"
        echo -e "  ${C_NEON_YELLOW}4${C_RST} ➔ Lista de Miembros y Vencimiento"
        echo -e "  ${C_NEON_YELLOW}5${C_RST} ➔ Verificar Conectados en Vivo"
        echo -e "  ${C_NEON_YELLOW}6${C_RST} ➔ Cambiar Límite de IPs (Cuenta SSH)"
        echo -e "  ${C_NEON_YELLOW}7${C_RST} ➔ Bloquear Cuenta SSH"
        echo -e "  ${C_NEON_YELLOW}8${C_RST} ➔ Desbloquear Cuenta SSH"
        echo -e "  ${C_NEON_YELLOW}9${C_RST} ➔ AutoKill (Desconectar multi-logins)"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_RED}0${C_RST} ➔ Volver al Menú Principal"
        echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
        read -p "Seleccione una opción: " opt
        case $opt in
            1) 
                clear; echo -e "${C_CYAN}================================================${C_RST}\n${C_YELLOW}      CREAR USUARIO SSH / HWID PROTECTION       ${C_RST}\n${C_CYAN}================================================${C_RST}"
                echo -e " [${C_GREEN}1${C_RST}] Cuenta Normal\n [${C_GREEN}2${C_RST}] Cuenta HWID"; read -p "Opción: " tipo_creacion
                read -p "Usuario: " user; read -p "Contraseña: " pass; read -p "Días: " dias; read -p "Límite Conexiones: " limite
                [ -z "$limite" ] && limite=1
                EXP_DATE=$(date -d "+$dias days" +"%Y-%m-%d")
                useradd -e $EXP_DATE -s /bin/false -M $user; echo "$user:$pass" | chpasswd
                echo "$limite" > "/etc/vps-manager/limite_${user}"
                if [ "$tipo_creacion" == "2" ]; then touch "/etc/vps-manager/hwid_${user}"; HWID_MSG="✅ (Bloqueado al Login)"; else rm -f "/etc/vps-manager/hwid_${user}"; HWID_MSG="❌ (Libre)"; fi
                generar_banner_usuario "$user" "$EXP_DATE" "$dias" "$limite"
                systemctl restart ssh 2>/dev/null
                
                IP_V=$(curl -s ipv4.icanhazip.com); DOM=$( [ -f /etc/vps-manager/dominio ] && cat /etc/vps-manager/dominio || echo "$IP_V" )
                NS_DOM=$( [ -f /etc/vps-manager/nsdomain ] && cat /etc/vps-manager/nsdomain || echo "No configurado" )
                PUB_KEY=$( [ -f /etc/vps-manager/slowdns/server.pub ] && cat /etc/vps-manager/slowdns/server.pub | tr -d '\r\n' || echo "No instalada" )
                OPENVPN_LINK="http://$DOM:2081"
                PORT_BHTTP=$(cat /etc/vps-manager/bhttp_port 2>/dev/null || echo "8080")
                PORT_HCR=$(cat /etc/vps-manager/hcr_port 2>/dev/null || echo "8880")
                PORT_SSL=$(cat /etc/vps-manager/ssl_port 2>/dev/null || echo "444")
                
                if [ -f /etc/zivpn/config.json ]; then
                    if ! grep -q "\"$pass\"" /etc/zivpn/config.json; then
                        sed -i -E "s/(\"config\": ?\[)/\1\"$pass\", /" /etc/zivpn/config.json
                        systemctl restart zivpn.service >/dev/null 2>&1
                    fi
                    ZIVPN_PASS="$pass"
                else
                    ZIVPN_PASS="No instalado"
                fi

                clear; echo -e "${C_CYAN}================================================${C_RST}\n${C_GREEN}        ✅ CUENTA CREADA EXITOSAMENTE ✅        ${C_RST}\n${C_CYAN}================================================${C_RST}"
                echo -e " 👤 Usuario       : ${C_YELLOW}$user${C_RST}"
                echo -e " 🔑 Clave         : ${C_YELLOW}$pass${C_RST}"
                echo -e " 📅 Vence         : ${C_YELLOW}$EXP_DATE ($dias días)${C_RST}"
                echo -e " 🔒 Límite IPs    : ${C_YELLOW}$limite${C_RST}"
                echo -e " 🛡️ Protecc. HWID : ${C_YELLOW}$HWID_MSG${C_RST}"
                echo -e "${C_CYAN}------------------------------------------------${C_RST}"
                echo -e " 🌐 Host/IP       : ${C_YELLOW}$DOM${C_RST}"
                echo -e " 🌍 NS Domain     : ${C_YELLOW}$NS_DOM${C_RST}"
                echo -e " 🗝️ Pub Key (DNS) : ${C_YELLOW}$PUB_KEY${C_RST}"
                echo -e " 🔗 OpenVPN       : ${C_YELLOW}$OPENVPN_LINK${C_RST}"
                echo -e " ⚡ Zivpn Pass    : ${C_YELLOW}$ZIVPN_PASS${C_RST}"
                echo -e " 🎯 Puertos       : ${C_YELLOW}SSH(22) Xray/TLS(443)${C_RST}"
                echo -e "                     ${C_YELLOW}SSL Stunnel($PORT_SSL)${C_RST}"
                echo -e "                     ${C_YELLOW}BHTTP($PORT_BHTTP) HCR($PORT_HCR)${C_RST}"
                echo -e "                     ${C_YELLOW}UDP Custom(25000)${C_RST}"
                echo -e "                     ${C_YELLOW}Zivpn(6000-19999) DNSTT(53)${C_RST}"
                echo -e "${C_CYAN}================================================${C_RST}"; read -p "Copia los datos y presiona Enter..." ;;
            2) read -p "Usuario a eliminar: " user; userdel -f $user 2>/dev/null; rm -f /etc/vps-manager/banner_${user}.net /etc/vps-manager/limite_${user} /etc/vps-manager/hwid_${user}; sed -i "/Match User $user/,+1d" /etc/ssh/sshd_config; systemctl restart ssh 2>/dev/null; echo -e "${C_GREEN}[✔] Eliminado.${C_RST}"; sleep 2 ;;
            3) read -p "Usuario a renovar: " user; read -p "Nuevos días: " dias; EXP_DATE=$(date -d "+$dias days" +"%Y-%m-%d"); chage -E $EXP_DATE $user; limite=$(cat /etc/vps-manager/limite_${user} 2>/dev/null || echo "1"); generar_banner_usuario "$user" "$EXP_DATE" "$dias" "$limite"; systemctl restart ssh 2>/dev/null; echo -e "${C_GREEN}[✔] Renovado.${C_RST}"; sleep 2 ;;
            4) clear; echo -e "${C_CYAN}╔══════════════════════════════════════════════╗\n║${C_GREEN}       📋 LISTA DE USUARIOS Y VENCIMIENTO     ${C_CYAN}║\n╚══════════════════════════════════════════════╝${C_RST}"; printf "${C_YELLOW}%-15s %-15s %-15s${C_RST}\n" "USUARIO" "EXPIRA" "DÍAS RESTANTES"; echo -e "${C_CYAN}────────────────────────────────────────────────${C_RST}"; for user in $(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd); do exp_date=$(chage -l $user | grep "Account expires" | awk -F": " '{print $2}'); if [[ "$exp_date" != "never" && -n "$exp_date" ]]; then exp_fmt=$(date -d "$exp_date" "+%Y-%m-%d" 2>/dev/null); sec_exp=$(date -d "$exp_date" +%s 2>/dev/null); sec_now=$(date +%s); dias=$(( (sec_exp - sec_now) / 86400 )); [ $dias -lt 0 ] && dias=0; printf "%-15s %-15s %-15s\n" "$user" "$exp_fmt" "$dias Días"; else printf "%-15s %-15s %-15s\n" "$user" "Ilimitado" "∞"; fi; done; read -p "Enter..." ;;
            5) clear; echo -e "${C_YELLOW}      VERIFICAR CONEXIONES EN VIVO      ${C_RST}"; ps -ef | grep -E "sshd|dropbear" | grep -v root | grep -v grep | awk '{print $1}' | sort | uniq -c | awk '{print " 👤 "$2" -> "$1" conexión(es)"}'; read -p "Enter..." ;;
            6) read -p "Usuario: " user; read -p "Nuevo Límite de IPs: " n_limite; echo "$n_limite" > "/etc/vps-manager/limite_${user}"; echo -e "${C_GREEN}[✔] Actualizado.${C_RST}"; sleep 2 ;;
            7) read -p "Usuario a Bloquear: " user; usermod -L $user; pkill -u $user; echo -e "${C_RED}[✔] BLOQUEADO.${C_RST}"; sleep 2 ;;
            8) read -p "Usuario a Desbloquear: " user; usermod -U $user; echo -e "${C_GREEN}[✔] DESBLOQUEADO.${C_RST}"; sleep 2 ;;
            9) clear; echo -e "${C_YELLOW}[+] AutoKill (Buscando Multilogins)...${C_RST}"; for user in $(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd); do limite=$(cat /etc/vps-manager/limite_${user} 2>/dev/null || echo "999"); conexiones=$(ps -ef | grep sshd | grep "$user" | grep -v root | grep -v grep | wc -l); if [ "$conexiones" -gt "$limite" ]; then echo -e "${C_RED} ➔ $user excedió el límite. Desconectando...${C_RST}"; pkill -u "$user"; fi; done; echo -e "${C_GREEN}[✔] Listo.${C_RST}"; read -p "Enter..." ;;
            0) break ;;
            *) sleep 1 ;;
        esac
    done
}

menu_revendedores() {
    while true; do
        clear
        echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
        echo -e "${C_NEON_BLUE}║${C_NEON_GREEN}         🤝 GESTIÓN DE REVENDEDORES (BOT)     ${C_NEON_BLUE}║${C_RST}"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_NEON_YELLOW}1${C_RST} ➔ Agregar Revendedor / Recargar Créditos"
        echo -e "  ${C_NEON_YELLOW}2${C_RST} ➔ Eliminar Revendedor"
        echo -e "  ${C_NEON_YELLOW}3${C_RST} ➔ Lista de Revendedores Activos"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_RED}0${C_RST} ➔ Volver al Menú Principal"
        echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
        read -p "Opción: " ropt
        RES_FILE="/etc/vps-manager/telegram_bot/resellers.txt"
        case $ropt in
            1) read -p "ID de Telegram del Revendedor: " r_id; read -p "Cantidad de Créditos: " r_cred; mkdir -p /etc/vps-manager/telegram_bot; touch $RES_FILE; sed -i "/^$r_id:/d" $RES_FILE; echo "$r_id:$r_cred" >> $RES_FILE; echo -e "${C_GREEN}[✔] Revendedor guardado.${C_RST}"; sleep 2 ;;
            2) read -p "ID de Telegram a eliminar: " r_id; sed -i "/^$r_id:/d" $RES_FILE; echo -e "${C_RED}[✔] Revendedor eliminado.${C_RST}"; sleep 2 ;;
            3) clear; echo -e "${C_YELLOW}📋 LISTA DE REVENDEDORES:${C_RST}"; if [ -f "$RES_FILE" ]; then cat "$RES_FILE" | awk -F: '{print " 👤 ID: "$1" -> 💰 Créditos: "$2}'; else echo "No hay revendedores."; fi; read -p "Enter..." ;;
            0) break ;;
            *) sleep 1 ;;
        esac
    done
}

menu_instaladores() {
    while true; do
        clear
        echo -e "${C_NEON_PURPLE}╔══════════════════════════════════════════════╗${C_RST}"
        echo -e "${C_NEON_PURPLE}║${C_NEON_GREEN}    🛠️ GESTOR DE INSTALACIONES Y PROTOCOLOS   ${C_NEON_PURPLE}║${C_RST}"
        echo -e "${C_NEON_PURPLE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🛡️ Menú Xray (VMess)"
        echo -e "  ${C_NEON_YELLOW}2.${C_RST} 🛡️ Menú Xray (VLESS)"
        echo -e "  ${C_NEON_YELLOW}3.${C_RST} 🛡️ Menú Xray (Trojan)"
        echo -e "  ${C_NEON_YELLOW}4.${C_RST} 🌐 Instalar OpenVPN (Web Perfiles)"
        echo -e "  ${C_NEON_YELLOW}5.${C_RST} 🚀 Instalar HCR Nativo (Puerto Dinámico)"
        echo -e "  ${C_NEON_YELLOW}6.${C_RST} 🎮 Instalar UDP Custom (Puerto 25000)"
        echo -e "  ${C_NEON_YELLOW}7.${C_RST} 🛸 Instalar SlowDNS (DNSTT)"
        echo -e "  ${C_NEON_YELLOW}8.${C_RST} 🌐 Instalar BHTTP Proxy (Puerto Dinámico)"
        echo -e "  ${C_NEON_YELLOW}9.${C_RST} 🔗 Instalar SSHWS / Websocket"
        echo -e "  ${C_NEON_YELLOW}10.${C_RST}🎮 Instalar BadVPN (Puertos 7300 y 7200)"
        echo -e "  ${C_NEON_YELLOW}11.${C_RST}🐘 Instalador PHP 8.5.12"
        echo -e "  ${C_NEON_YELLOW}12.${C_RST}🚀 Instalar Acelerador BBR"
        echo -e "  ${C_NEON_YELLOW}13.${C_RST}🛡️ Instalar Zivpn UDP (App Zivpn)"
        echo -e "  ${C_NEON_YELLOW}14.${C_RST}⚡ Instalar Hysteria v1 (QUIC Proxy)"
        echo -e "  ${C_NEON_YELLOW}15.${C_RST}🔒 Instalar SSL / TLS (Puerto Dinámico)"
        echo -e "${C_NEON_PURPLE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Principal"
        echo -e "${C_NEON_PURPLE}╚══════════════════════════════════════════════╝${C_RST}"
        read -p "Seleccione una opción: " hopt
        case $hopt in
            1) clear; wget -qO /tmp/vmess.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/vmess.sh && chmod +x /tmp/vmess.sh && bash /tmp/vmess.sh ;;
            2) clear; wget -qO /tmp/vless.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/vless.sh && chmod +x /tmp/vless.sh && bash /tmp/vless.sh ;;
            3) clear; wget -qO /tmp/trojan.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/trojan.sh && chmod +x /tmp/trojan.sh && bash /tmp/trojan.sh ;;
            4) clear; wget -qO /tmp/setup_openvpn.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/setup_openvpn.sh && chmod +x /tmp/setup_openvpn.sh && bash /tmp/setup_openvpn.sh; read -p "Enter..." ;;
            5) clear; wget -qO /tmp/hcr.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/hcr.sh && chmod +x /tmp/hcr.sh && bash /tmp/hcr.sh ;;
            6) clear; wget -qO /tmp/udp_custom.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/udp_custom.sh && chmod +x /tmp/udp_custom.sh && bash /tmp/udp_custom.sh ;;
            7) clear; wget -qO /tmp/Slowdns.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/Slowdns.sh && chmod +x /tmp/Slowdns.sh && bash /tmp/Slowdns.sh ;;
            8) clear; wget -qO /tmp/bhttp.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/bhttp.sh && chmod +x /tmp/bhttp.sh && bash /tmp/bhttp.sh ;;
            9) clear; wget -qO /tmp/sshws.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/sshws.sh && chmod +x /tmp/sshws.sh && bash /tmp/sshws.sh; read -p "Enter..." ;;
            10) clear; wget -qO /tmp/badvpn.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/badvpn.sh && chmod +x /tmp/badvpn.sh && bash /tmp/badvpn.sh ;;
            11) clear; curl -sSL "https://raw.githubusercontent.com/golbert19/php-8.5.12-vps/main/install.sh?t=$(date +%s)" | sed '59s/[()]//g' | bash; read -p "Enter..." ;;
            12) clear; wget -qO /tmp/Bbr.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/Bbr.sh && chmod +x /tmp/Bbr.sh && bash /tmp/Bbr.sh; read -p "Enter..." ;;
            13) clear; wget -qO /tmp/zivpn.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/zivpn.sh && chmod +x /tmp/zivpn.sh && bash /tmp/zivpn.sh ;;
            14) clear; wget -qO /tmp/hysteria.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/hysteria.sh && chmod +x /tmp/hysteria.sh && bash /tmp/hysteria.sh ;;
            15) clear; wget -qO /tmp/ssl.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/ssl.sh && chmod +x /tmp/ssl.sh && bash /tmp/ssl.sh ;;
            0) break ;;
            *) sleep 1 ;;
        esac
    done
}

menu_webpanel() { clear; echo -e "${C_YELLOW}[+] Preparando Panel Web...${C_RST}"; wget -qO /tmp/webpanel.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/webpanel.sh && chmod +x /tmp/webpanel.sh && bash /tmp/webpanel.sh; }

menu_puertos() { 
    clear
    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗\n║${C_NEON_GREEN}         🔍 ESTADO DE PUERTOS Y SERVICIOS     ${C_NEON_BLUE}║\n╚══════════════════════════════════════════════╝${C_RST}"
    PORT_BHTTP=$(cat /etc/vps-manager/bhttp_port 2>/dev/null || echo "8080")
    PORT_HCR=$(cat /etc/vps-manager/hcr_port 2>/dev/null || echo "8880")
    PORT_SSL=$(cat /etc/vps-manager/ssl_port 2>/dev/null || echo "444")
    
    puertos=(22 80 443 53 1194 2081 2083 $PORT_BHTTP $PORT_HCR $PORT_SSL 8181 7300 7200 25000 5432)
    nombres=("SSH (OpenSSH)" "HTTP / Xray WS" "Xray SSL/VLESS" "DNS (SlowDNS)" "OpenVPN TCP" "OpenVPN Web" "Trojan TLS" "BHTTP Custom" "HCR Proxy PRO" "SSL / TLS Proxy" "Web Panel UI" "BadVPN (Game 7300)" "BadVPN (Game 7200)" "UDP Custom" "CheckUser API")
    
    for i in "${!puertos[@]}"; do 
        p=${puertos[$i]}; n=${nombres[$i]}
        if ss -lntp 2>/dev/null | grep -q ":$p " || ss -lnup 2>/dev/null | grep -q ":$p " || netstat -tuln 2>/dev/null | grep -q ":$p "; then 
            echo -e "  🔹 [${C_NEON_GREEN}ACTIVO   ${C_RST}] Puerto ${C_NEON_YELLOW}$p${C_RST} ➔ $n"
        else 
            echo -e "  🔸 [${C_RED}INACTIVO ${C_RST}] Puerto ${C_NEON_YELLOW}$p${C_RST} ➔ $n"
        fi
    done

    if ss -lnup 2>/dev/null | grep -q ":5667 " || systemctl is-active --quiet zivpn.service; then
        echo -e "  🔹 [${C_NEON_GREEN}ACTIVO   ${C_RST}] Puerto ${C_NEON_YELLOW}6000-19999${C_RST} ➔ Zivpn UDP"
    else
        echo -e "  🔸 [${C_RED}INACTIVO ${C_RST}] Puerto ${C_NEON_YELLOW}6000-19999${C_RST} ➔ Zivpn UDP"
    fi

    if systemctl is-active --quiet hysteria.service || ss -lnup 2>/dev/null | grep -q "hysteria"; then
        echo -e "  🔹 [${C_NEON_GREEN}ACTIVO   ${C_RST}] Hysteria v1   ➔ Hysteria QUIC"
    else
        echo -e "  🔸 [${C_RED}INACTIVO ${C_RST}] Hysteria v1   ➔ Hysteria QUIC"
    fi
    echo -e "${C_NEON_BLUE}────────────────────────────────────────────────${C_RST}"
    read -p "Presione Enter para regresar..."
}

menu_bot() { clear; echo -e "${C_YELLOW}[+] Configurando Bot...${C_RST}"; wget -qO /tmp/bot.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/bot.sh && chmod +x /tmp/bot.sh && bash /tmp/bot.sh; read -p "Enter..." ;}
menu_dominio() { clear; echo -e "${C_YELLOW}[+] Iniciando Gestor SSL...${C_RST}"; wget -qO /tmp/domain.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/domain.sh && chmod +x /tmp/domain.sh && bash /tmp/domain.sh; }
menu_update() { clear; echo -e "${C_YELLOW}[+] Actualizando Panel...${C_RST}"; wget -qO /tmp/update.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/update.sh && chmod +x /tmp/update.sh && bash /tmp/update.sh; }
menu_firewall() { clear; echo -e "${C_YELLOW}[+] Iniciando Firewall...${C_RST}"; wget -qO /tmp/firewall.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/firewall.sh && chmod +x /tmp/firewall.sh && bash /tmp/firewall.sh; }
menu_checkuser() { clear; echo -e "${C_YELLOW}[+] Iniciando CheckUser API...${C_RST}"; wget -qO /tmp/checkuser.sh https://raw.githubusercontent.com/golbert19/vps-script/main/core/checkuser.sh && chmod +x /tmp/checkuser.sh && bash /tmp/checkuser.sh; }
menu_autostart() { clear; grep -q "menu" /root/.bashrc && echo -e "${C_GREEN}[✔] Ya activo.${C_RST}" || (echo -e "\nmenu" >> /root/.bashrc; echo -e "${C_GREEN}[✔] Activado.${C_RST}"); read -p "Enter..." ;}
menu_banner() { clear; echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗\n║${C_NEON_GREEN}         GESTOR DE BANNER BASE HTML           ${C_NEON_BLUE}║\n╚══════════════════════════════════════════════╝${C_RST}\n  ${C_NEON_YELLOW}1.${C_RST} Banner por Defecto\n  ${C_NEON_YELLOW}2.${C_RST} Personalizado HTML\n"; read -p "Opción: " opt_ban; case $opt_ban in 1) TEXTO="<br><font color='cyan'><b>🌟 BIENVENIDO A GOLBERT VPS 🌟</b></font><br>" ;; 2) echo -e "Pega HTML: "; read -r TEXTO ;; *) TEXTO="Bienvenido" ;; esac; echo "$TEXTO" > /etc/issue.net; echo -e "${C_GREEN}[✔] Banner Global guardado.${C_RST}"; read -p "Presione Enter..." ; }

menu_info() {
    clear
    echo -e "${C_CYAN}[+] Recopilando información del sistema, por favor espere...${C_RST}"
    
    DEV="@golbert19 (https://t.me/golbertperuvps)"
    VER="v5.0 LTS"
    
    CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | awk -F: '{print $2}' | sed 's/^[ \t]*//')
    CPU_CORES=$(nproc)
    CPU_FREQ=$(grep -m1 'cpu MHz' /proc/cpuinfo | awk -F: '{print $2}' | sed 's/^[ \t]*//')
    CPU_CACHE=$(grep -m1 'cache size' /proc/cpuinfo | awk -F: '{print $2}' | sed 's/^[ \t]*//')
    
    grep -q -m1 -i 'aes' /proc/cpuinfo && AES="✔ Enabled" || AES="x Disabled"
    grep -q -m1 -i -E '(vmx|svm)' /proc/cpuinfo && VIRT_HW="✔ Enabled" || VIRT_HW="x Disabled"
    
    DISK_T=$(df -h / | awk 'NR==2 {print $2}')
    DISK_U=$(df -h / | awk 'NR==2 {print $3}')
    RAM_T=$(free -m | awk 'NR==2 {print $2}')
    RAM_U=$(free -m | awk 'NR==2 {print $3}')
    SWAP_T=$(free -m | awk 'NR==3 {print $2}')
    SWAP_U=$(free -m | awk 'NR==3 {print $3}')
    [ -z "$SWAP_T" ] && SWAP_T="0" && SWAP_U="0"
    
    UPTIME=$(uptime -p | sed 's/up //')
    LOAD=$(cat /proc/loadavg | awk '{print $1", "$2", "$3}')
    
    OS=$(cat /etc/os-release | grep -w PRETTY_NAME | cut -d= -f2 | tr -d '"')
    ARCH=$(uname -m)
    [ "$ARCH" = "x86_64" ] && ARCH="$ARCH (64 Bit)"
    KERNEL=$(uname -r)
    
    TCP_C=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    [ -z "$TCP_C" ] && TCP_C="cubic"
    VIRT=$(systemd-detect-virt 2>/dev/null || echo "Desconocido")
    
    curl -s4 -m 3 ipinfo.io/ip >/dev/null && IPV4="✔ Online" || IPV4="x Offline"
    curl -s6 -m 3 ipinfo.io/ip >/dev/null && IPV6="✔ Online" || IPV6="x Offline"
    
    ORG=$(curl -s -m 3 ipinfo.io/org || echo "Desconocido")
    CITY=$(curl -s -m 3 ipinfo.io/city || echo "Desconocido")
    COUNTRY=$(curl -s -m 3 ipinfo.io/country || echo "Desconocido")
    REGION=$(curl -s -m 3 ipinfo.io/region || echo "Desconocido")

    clear
    C_T='\033[38;5;111m'
    C_V='\033[38;5;114m'
    C_L='\033[38;5;239m'

    print_line() {
        printf "${C_T}%-22s${C_RST} : ${C_V}%s${C_RST}\n" "$1" "$2"
    }

    print_line "Developer" "$DEV"
    print_line "Version" "$VER"
    echo -e "${C_L}---------------------------------------------------------${C_RST}"
    print_line "CPU Model" "$CPU_MODEL"
    print_line "CPU Cores" "$CPU_CORES @ $CPU_FREQ MHz"
    print_line "CPU Cache" "$CPU_CACHE"
    print_line "AES-NI" "$AES"
    print_line "VM-x/AMD-V" "$VIRT_HW"
    print_line "Total Disk" "$DISK_T ($DISK_U Used)"
    print_line "Total RAM" "${RAM_T} MB (${RAM_U} MB Used)"
    print_line "Total Swap" "${SWAP_T} MB (${SWAP_U} MB Used)"
    print_line "System Uptime" "$UPTIME"
    print_line "Load Average" "$LOAD"
    print_line "OS" "$OS"
    print_line "Arch" "$ARCH"
    print_line "Kernel" "$KERNEL"
    print_line "TCP Congestion Ctrl" "$TCP_C"
    print_line "Virtualization" "${VIRT^^}"
    print_line "IPv4/IPv6" "$IPV4 / $IPV6"
    print_line "Organization" "$ORG"
    print_line "Location" "$CITY / $COUNTRY"
    print_line "Region" "$REGION"
    echo -e "${C_L}---------------------------------------------------------${C_RST}"
    
    echo -e "${C_T}Calculando I/O Speed...${C_RST}"
    IO_RES=$(dd if=/dev/zero of=test_$$ bs=64k count=16k conv=fdatasync 2>&1 | awk -F, '{print $3}' | tr -d ' ')
    rm -f test_$$
    echo -e "\033[1A\033[K\c"
    print_line "I/O Speed (average)" "$IO_RES"
    
    echo -e "${C_L}---------------------------------------------------------${C_RST}"
    echo -e ""
    read -p "Press any key to back..."
}

uninstall_script() { clear; read -p "⚠️ ¿Desinstalar todo? (s/n): " conf; if [[ "$conf" == "s" || "$conf" == "S" ]]; then rm -rf /etc/vps-manager; rm -f /usr/local/bin/menu; echo -e "${C_GREEN}Eliminado.${C_RST}"; exit 0; fi; }

draw_bar() { 
    local perc=$1; local filled=$((perc / 10)); local empty=$((10 - filled)); local bar=""
    for ((i=0; i<filled; i++)); do bar="${bar}█"; done
    for ((i=0; i<empty; i++)); do bar="${bar}░"; done
    echo -e "[$bar] ${perc}%" 
}

# ==========================================
# BUCLE PRINCIPAL (SOPORTE BILINGÜE)
# ==========================================
while true; do
    clear
    SYS_LANG=$(cat /etc/vps-manager/lang 2>/dev/null || echo "es")
    
    if [ "$SYS_LANG" == "en" ]; then
        M_TITLE="🌟 GOLBERT VPS PREMIUM - V5.0 LTS PANEL 🌟"
        M_OS="💻 OS        "
        M_IP="🌐 IP        "
        M_DOM="🎯 Domain    "
        M_CPU="🧠 CPU Usage "
        M_RAM="⚡ RAM Usage "
        M_CON="👥 Connected "
        M_ACT="active users"
        M_CAT1="[ ACCOUNT MANAGEMENT ]"
        M_OPT1="👤 SSH Management (Users, Limit, HWID)"
        M_OPT2="🤝 Reseller Management (Credits)"
        M_CAT2="[ TOOLS & SYSTEM ]"
        M_OPT3="🛠️ Installers & Protocols Manager"
        M_OPT4="🎨 Configure HTML Welcome Banner"
        M_OPT5="🔍 Ports Monitor (Active / Inactive)"
        M_OPT6="⚙️ Domain Manager & SSL Certificates"
        M_OPT7="🤖 Link Telegram Bot"
        M_OPT8="🌐 Generate Web Panel (Dashboard UI)"
        M_OPT9="🔄 Update Panel (From GitHub)"
        M_OPT10="🤖 Enable Auto-Start on Login"
        M_OPT11="🖥️ VPS Specifications & Capacity"
        M_OPT12="🛡️ Firewall Manager (Rules & Security)"
        M_OPT13="👥 Install CheckUser (Multi-App Monitor)"
        M_OPT14="🌍 Change Language (ES/EN)"
        M_OPT88="❌ Uninstall Script"
        M_OPT0="🚪 Exit"
        M_SEL="Select an option: "
        M_ERR="Invalid option."
    else
        M_TITLE="🌟 GOLBERT VPS PREMIUM - PANEL V5.0 LTS 🌟"
        M_OS="💻 SO        "
        M_IP="🌐 IP        "
        M_DOM="🎯 Dominio   "
        M_CPU="🧠 CPU Uso   "
        M_RAM="⚡ RAM Uso   "
        M_CON="👥 Conectados"
        M_ACT="usuarios activos"
        M_CAT1="[ GESTIÓN DE CUENTAS ]"
        M_OPT1="👤 Gestión de SSH (Usuarios, Límite, HWID)"
        M_OPT2="🤝 Gestión de Revendedores (Créditos)"
        M_CAT2="[ HERRAMIENTAS Y SISTEMA ]"
        M_OPT3="🛠️ Gestor de Instalaciones y Protocolos"
        M_OPT4="🎨 Configurar Banner HTML de Bienvenida"
        M_OPT5="🔍 Monitor de Puertos (Activos / Inactivos)"
        M_OPT6="⚙️ Gestor de Dominio y Certificados SSL"
        M_OPT7="🤖 Vincular Bot de Telegram"
        M_OPT8="🌐 Generar Panel Web (Dashboard UI)"
        M_OPT9="🔄 Actualizar Panel (Desde GitHub)"
        M_OPT10="🤖 Activar Auto-Inicio al Loguearse"
        M_OPT11="🖥️ Especificaciones y Capacidad del VPS"
        M_OPT12="🛡️ Gestor de Firewall (Reglas y Seguridad)"
        M_OPT13="👥 Instalar CheckUser (Monitor Multi-App)"
        M_OPT14="🌍 Cambiar Idioma (ES/EN)"
        M_OPT88="❌ Desinstalar Script"
        M_OPT0="🚪 Salir"
        M_SEL="Seleccione una opción: "
        M_ERR="Opción inválida."
    fi

    OS=$(cat /etc/os-release | grep -w PRETTY_NAME | head -n 1 | cut -d "=" -f 2 | sed 's/"//g')
    IP=$(curl -s --max-time 3 ipv4.icanhazip.com || hostname -I | awk '{print $1}')
    RAM_TOTAL=$(free -m | awk 'NR==2{print $2}'); RAM_USED=$(free -m | awk 'NR==2{print $3}')
    RAM_PER=$((RAM_USED * 100 / RAM_TOTAL)); RAM_STR=$(free -m | awk 'NR==2{printf "%s / %s MB", $3,$2}')
    RAM_BAR=$(draw_bar $RAM_PER)
    CPU_PER=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}' | cut -d'.' -f1); [ -z "$CPU_PER" ] && CPU_PER=0
    CPU_BAR=$(draw_bar $CPU_PER)
    CONECTADOS=$(ps -ef | grep -E "sshd|dropbear" | grep -v root | grep -v grep | wc -l)
    SUBDOMINIO=$( [ -f /etc/vps-manager/dominio ] && cat /etc/vps-manager/dominio || echo "No Configurado" )

    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_NEON_BLUE}║ ${C_NEON_YELLOW}${M_TITLE}   ${C_NEON_BLUE}║${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "${C_NEON_BLUE}║ ${C_NEON_GREEN}${M_OS}:${C_RST} $OS"
    echo -e "${C_NEON_BLUE}║ ${C_NEON_GREEN}${M_IP}:${C_RST} $IP"
    echo -e "${C_NEON_BLUE}║ ${C_NEON_GREEN}${M_DOM}:${C_RST} $SUBDOMINIO"
    echo -e "${C_NEON_BLUE}║ ${C_NEON_GREEN}${M_CPU}:${C_RST} $CPU_BAR"
    echo -e "${C_NEON_BLUE}║ ${C_NEON_GREEN}${M_RAM}:${C_RST} $RAM_BAR ($RAM_STR)"
    echo -e "${C_NEON_BLUE}║ ${C_NEON_GREEN}${M_CON}:${C_RST} $CONECTADOS $M_ACT"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "${C_NEON_PURPLE}  ${M_CAT1}${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} ${M_OPT1}"
    echo -e "  ${C_NEON_YELLOW}2.${C_RST} ${M_OPT2}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "${C_NEON_PURPLE}  ${M_CAT2}${C_RST}"
    echo -e "  ${C_NEON_YELLOW}3.${C_RST} ${M_OPT3}"
    echo -e "  ${C_NEON_YELLOW}4.${C_RST} ${M_OPT4}"
    echo -e "  ${C_NEON_YELLOW}5.${C_RST} ${M_OPT5}"
    echo -e "  ${C_NEON_YELLOW}6.${C_RST} ${M_OPT6}"
    echo -e "  ${C_NEON_YELLOW}7.${C_RST} ${M_OPT7}"
    echo -e "  ${C_NEON_YELLOW}8.${C_RST} ${M_OPT8}"
    echo -e "  ${C_NEON_YELLOW}9.${C_RST} ${M_OPT9}"
    echo -e "  ${C_NEON_YELLOW}10.${C_RST}${M_OPT10}"
    echo -e "  ${C_NEON_YELLOW}11.${C_RST}${M_OPT11}"
    echo -e "  ${C_NEON_YELLOW}12.${C_RST}${M_OPT12}"
    echo -e "  ${C_NEON_YELLOW}13.${C_RST}${M_OPT13}"
    echo -e "  ${C_NEON_YELLOW}14.${C_RST}${M_OPT14}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_RED}88.${C_RST} ${M_OPT88}   |   ${C_RED}0.${C_RST} ${M_OPT0}"
    echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
    echo -n -e "${C_YELLOW}${M_SEL}${C_RST} "
    read opcion

    case $opcion in
        1) menu_ssh ;; 2) menu_revendedores ;; 3) menu_instaladores ;; 4) menu_banner ;; 5) menu_puertos ;; 
        6) menu_dominio ;; 7) menu_bot ;; 8) menu_webpanel ;; 9) menu_update ;; 10) menu_autostart ;; 11) menu_info ;;
        12) menu_firewall ;; 13) menu_checkuser ;; 14) menu_idioma ;; 88) uninstall_script ;; 0) clear; exit 0 ;;
        *) echo -e "\n${C_RED}[!] ${M_ERR}${C_RST}"; sleep 1 ;;
    esac
done
