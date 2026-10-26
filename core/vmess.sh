#!/bin/bash
# ==========================================
# Módulo Independiente: VMess (XRAY)
# Puertos: 80 (NTLS) y 443 (TLS)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
XRAY_DIR="/usr/local/etc/xray"
CONF_FILE="$XRAY_DIR/config.json"
DOM_FILE="/etc/vps-manager/dominio"

instalar_xray_vmess() {
    clear
    echo -e "${C_CYAN}================================================${C_NC}"
    echo -e "${C_GREEN}   INSTALACIÓN DE XRAY (VMESS) Y CERTIFICADO    ${C_NC}"
    echo -e "${C_CYAN}================================================${C_NC}"
    
    read -p "Ingresa tu dominio (Ej: centrix.golbertvps.online): " DOMINIO
    if [ -z "$DOMINIO" ]; then echo -e "${C_RED}[!] Dominio inválido.${C_NC}"; sleep 2; return; fi
    echo "$DOMINIO" > $DOM_FILE

    echo -e "${C_YELLOW}[+] Instalando dependencias...${C_NC}"
    apt update -y >/dev/null 2>&1
    apt install -y certbot jq uuid-runtime curl iptables ufw >/dev/null 2>&1

    echo -e "${C_YELLOW}[+] Liberando puertos 80 y 443...${C_NC}"
    systemctl stop nginx apache2 haproxy xray 2>/dev/null
    fuser -k 80/tcp 2>/dev/null
    fuser -k 443/tcp 2>/dev/null

    echo -e "${C_YELLOW}[+] Generando Certificado SSL...${C_NC}"
    certbot certonly --standalone -d "$DOMINIO" --non-interactive --agree-tos -m "admin@$DOMINIO"
    
    if [ ! -f "/etc/letsencrypt/live/$DOMINIO/fullchain.pem" ]; then
        echo -e "${C_RED}[!] Error SSL. Revisa que tu IP apunte al dominio en Cloudflare.${C_NC}"
        read -p "Presiona Enter..."
        exit 1
    fi

    echo -e "${C_YELLOW}[+] Instalando núcleo Xray...${C_NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    
    # IMPORTANTE: ¡Abrir el Firewall para que no dé Timeout!
    iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    iptables-save > /etc/iptables.up.rules 2>/dev/null
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1

    mkdir -p $XRAY_DIR
    cp /etc/letsencrypt/live/$DOMINIO/fullchain.pem $XRAY_DIR/server.crt
    cp /etc/letsencrypt/live/$DOMINIO/privkey.pem $XRAY_DIR/server.key

    # Configuración Avanzada Xray: Fallbacks para WS, GRPC y XHTTP en el mismo puerto 443
    cat << EOF > $CONF_FILE
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 443, "protocol": "vless",
      "settings": { "clients": [], "decryption": "none",
        "fallbacks": [
          {"path": "/vmess", "dest": 10001},
          {"path": "/vmess-grpc", "dest": 10002},
          {"path": "/xhttp", "dest": 10003}
        ]
      },
      "streamSettings": { "network": "tcp", "security": "tls", "tlsSettings": { "alpn": ["h2", "http/1.1"], "certificates": [ { "certificateFile": "$XRAY_DIR/server.crt", "keyFile": "$XRAY_DIR/server.key" } ] } }
    },
    {
      "port": 80, "protocol": "vless",
      "settings": { "clients": [], "decryption": "none",
        "fallbacks": [
          {"path": "/vmess", "dest": 10001},
          {"path": "/xhttp", "dest": 10003}
        ]
      },
      "streamSettings": { "network": "tcp", "security": "none" }
    },
    { "port": 10001, "listen": "127.0.0.1", "protocol": "vmess", "settings": {"clients": []}, "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": "/vmess"}} },
    { "port": 10002, "listen": "127.0.0.1", "protocol": "vmess", "settings": {"clients": []}, "streamSettings": {"network": "grpc", "security": "none", "grpcSettings": {"serviceName": "vmess-grpc"}} },
    { "port": 10003, "listen": "127.0.0.1", "protocol": "vmess", "settings": {"clients": []}, "streamSettings": {"network": "xhttp", "security": "none", "xhttpSettings": {"path": "/xhttp", "mode": "auto"}} }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
    systemctl restart xray
    echo -e "${C_GREEN}[✔] ¡Instalación completada!${C_NC}"; sleep 2
}

generar_link() {
    local alias=$1 dom=$2 uuid=$3 port=$4 net=$5 tls=$6 path=$7
    local json="{\"v\":\"2\",\"ps\":\"$alias\",\"add\":\"$dom\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"$net\",\"type\":\"none\",\"host\":\"$dom\",\"path\":\"$path\",\"tls\":\"$tls\",\"sni\":\"$dom\",\"alpn\":\"\"}"
    echo "vmess://$(echo -n "$json" | base64 -w 0)"
}

menu_vmess() {
    if [ ! -f "$CONF_FILE" ]; then instalar_xray_vmess; fi
    
    while true; do
        clear
        echo -e "${C_YELLOW}        GESTION DE VMESS (XRAY)        ${C_NC}"
        echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
        echo -e "${C_CYAN}[1] >${C_NC} Crear Cuenta Vmess"
        echo -e "${C_CYAN}[2] >${C_NC} Eliminar Cuenta Vmess"
        echo -e "${C_CYAN}[x] >${C_NC} Salir del Gestor"
        echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
        read -p "Digite su opción: " opc

        case $opc in
            1)
                clear
                echo -e "${C_YELLOW}      CREAR USUARIO XRAY VMESS      ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "Nombre de usuario: " user
                [ -z "$user" ] && continue
                read -p "Duración (días): " dias
                
                UUID=$(uuidgen)
                EXP_DATE=$(date -d "+$dias days" +"%Y-%m-%d")
                DOM=$(cat $DOM_FILE)

                # Inyectar usuario en los 3 nodos internos de VMess (WS, GRPC, XHTTP)
                jq ".inbounds[2].settings.clients += [{\"id\": \"$UUID\", \"email\": \"$user\", \"alterId\": 0}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[3].settings.clients += [{\"id\": \"$UUID\", \"email\": \"$user\", \"alterId\": 0}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[4].settings.clients += [{\"id\": \"$UUID\", \"email\": \"$user\", \"alterId\": 0}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                systemctl restart xray

                LINK_TLS=$(generar_link "$user" "$DOM" "$UUID" "443" "ws" "tls" "/vmess")
                LINK_NTLS=$(generar_link "$user" "$DOM" "$UUID" "80" "ws" "" "/vmess")
                LINK_GRPC=$(generar_link "$user-GRPC" "$DOM" "$UUID" "443" "grpc" "tls" "vmess-grpc")
                LINK_XHTTP=$(generar_link "$user-XHTTP" "$DOM" "$UUID" "443" "xhttp" "tls" "/xhttp")
                LINK_XHTTP80=$(generar_link "$user-XHTTP80" "$DOM" "$UUID" "80" "xhttp" "" "/xhttp")

                clear
                echo -e "${C_YELLOW}    CUENTA VMESS CREADA EXITOSAMENTE    ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                echo -e " Alias       : ${C_CYAN}$user${C_NC}"
                echo -e " Dominio     : ${C_CYAN}$DOM${C_NC}"
                echo -e " UUID (Pass) : ${C_CYAN}$UUID${C_NC}"
                echo -e " Red         : ${C_CYAN}WS / GRPC / XHTTP${C_NC}"
                echo -e " Expira      : ${C_CYAN}$EXP_DATE${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                echo -e "\n ${C_GREEN}LINK TLS (443) :${C_NC}\n$LINK_TLS\n"
                echo -e " ${C_GREEN}LINK NTLS (80) :${C_NC}\n$LINK_NTLS\n"
                echo -e " ${C_GREEN}LINK GRPC      :${C_NC}\n$LINK_GRPC\n"
                echo -e " ${C_GREEN}LINK XHTTP     :${C_NC}\n$LINK_XHTTP\n"
                echo -e " ${C_GREEN}LINK XHTTP80   :${C_NC}\n$LINK_XHTTP80\n"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "Presiona ENTER para volver al menú " foo
                ;;
            2)
                read -p "Usuario a eliminar: " user
                jq ".inbounds[2].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[3].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[4].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                systemctl restart xray
                echo -e "${C_GREEN}[✔] Eliminado.${C_NC}"; sleep 2
                ;;
            x|X|"") break ;;
        esac
    done
}

menu_vmess
