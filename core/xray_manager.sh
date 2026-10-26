#!/bin/bash
# ==========================================
# Módulo: Xray Manager Multi-Protocolo (VMess / VLESS / Trojan)
# Enrutamiento Unificado en Puertos 80 (NTLS) y 443 (TLS)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
XRAY_DIR="/usr/local/etc/xray"
CONF_FILE="$XRAY_DIR/config.json"
DOM_FILE="/etc/vps-manager/dominio"

# Detectar el protocolo enviado por el menu.sh (VMess, VLESS o Trojan)
PROTO=${1:-VMess}
LPROTO=$(echo "$PROTO" | tr '[:upper:]' '[:lower:]')

# 1. Instalador Core y Certificador SSL Unificado
instalar_xray_ssl() {
    clear
    echo -e "${C_CYAN}================================================${C_NC}"
    echo -e "${C_GREEN}     INSTALACIÓN MULTI-NÚCLEO XRAY Y SSL        ${C_NC}"
    echo -e "${C_CYAN}================================================${C_NC}"
    
    read -p "Ingresa tu dominio (Ej: centrix.golbertvps.online): " DOMINIO
    if [ -z "$DOMINIO" ]; then echo -e "${C_RED}[!] Dominio inválido.${C_NC}"; sleep 2; return; fi
    echo "$DOMINIO" > $DOM_FILE

    echo -e "${C_YELLOW}[+] Instalando dependencias y Certbot...${C_NC}"
    apt update -y >/dev/null 2>&1
    apt install -y certbot jq uuid-runtime curl >/dev/null 2>&1

    echo -e "${C_YELLOW}[+] Liberando puertos 80 y 443...${C_NC}"
    systemctl stop nginx apache2 haproxy xray 2>/dev/null
    fuser -k 80/tcp 2>/dev/null
    fuser -k 443/tcp 2>/dev/null

    echo -e "${C_YELLOW}[+] Generando Certificado SSL Oficial...${C_NC}"
    certbot certonly --standalone -d "$DOMINIO" --non-interactive --agree-tos -m "admin@$DOMINIO"
    
    if [ ! -f "/etc/letsencrypt/live/$DOMINIO/fullchain.pem" ]; then
        echo -e "${C_RED}[!] Error: No se pudo generar el SSL. Verifica los DNS de tu dominio.${C_NC}"
        read -p "Presiona Enter para salir..."
        exit 1
    fi

    echo -e "${C_YELLOW}[+] Instalando Xray-Core...${C_NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1

    mkdir -p $XRAY_DIR
    cp /etc/letsencrypt/live/$DOMINIO/fullchain.pem $XRAY_DIR/server.crt
    cp /etc/letsencrypt/live/$DOMINIO/privkey.pem $XRAY_DIR/server.key
    chown nobody:nogroup $XRAY_DIR/server.crt $XRAY_DIR/server.key

    # Configuración maestra: Multiplexa VMess, VLESS y Trojan en los mismos puertos 80 y 443
    cat << EOF > $CONF_FILE
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 443, "protocol": "vless",
      "settings": { "clients": [], "decryption": "none",
        "fallbacks": [
          {"path": "/vmess", "dest": 10001},
          {"path": "/vless", "dest": 10002},
          {"path": "/trojan", "dest": 10003}
        ]
      },
      "streamSettings": { "network": "tcp", "security": "tls", "tlsSettings": { "alpn": ["http/1.1"], "certificates": [ { "certificateFile": "$XRAY_DIR/server.crt", "keyFile": "$XRAY_DIR/server.key" } ] } }
    },
    {
      "port": 80, "protocol": "vless",
      "settings": { "clients": [], "decryption": "none",
        "fallbacks": [
          {"path": "/vmess", "dest": 10001},
          {"path": "/vless", "dest": 10002},
          {"path": "/trojan", "dest": 10003}
        ]
      },
      "streamSettings": { "network": "tcp", "security": "none" }
    },
    { "port": 10001, "listen": "127.0.0.1", "protocol": "vmess", "settings": {"clients": []}, "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": "/vmess"}} },
    { "port": 10002, "listen": "127.0.0.1", "protocol": "vless", "settings": {"clients": [], "decryption": "none"}, "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": "/vless"}} },
    { "port": 10003, "listen": "127.0.0.1", "protocol": "trojan", "settings": {"clients": []}, "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": "/trojan"}} }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

    systemctl restart xray
    echo -e "${C_GREEN}[✔] ¡Núcleo Xray Multi-Protocolo y SSL Activos!${C_NC}"
    sleep 2
}

# 2. Generador Dinámico de Enlaces
generar_enlace() {
    local alias=$1; local dom=$2; local uuid=$3; local port=$4; local net=$5; local tls=$6; local path=$7; local pr=$8
    if [ "$pr" == "vmess" ]; then
        local json="{\"v\":\"2\",\"ps\":\"$alias\",\"add\":\"$dom\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"$net\",\"type\":\"none\",\"host\":\"$dom\",\"path\":\"$path\",\"tls\":\"$tls\",\"sni\":\"$dom\",\"alpn\":\"\"}"
        echo "vmess://$(echo -n "$json" | base64 -w 0)"
    elif [ "$pr" == "vless" ]; then
        echo "vless://${uuid}@${dom}:${port}?type=${net}&security=${tls}&path=${path}&sni=${dom}#${alias}"
    elif [ "$pr" == "trojan" ]; then
        echo "trojan://${uuid}@${dom}:${port}?type=${net}&security=${tls}&path=${path}&sni=${dom}#${alias}"
    fi
}

# 3. Interfaz Principal Dinámica
menu_principal() {
    if [ ! -f "$CONF_FILE" ]; then instalar_xray_ssl; fi
    
    while true; do
        clear
        echo -e "${C_YELLOW}        GESTION DE $PROTO (XRAY)        ${C_NC}"
        echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
        echo -e "${C_CYAN}[1] >${C_NC} Crear Cuenta $PROTO"
        echo -e "${C_CYAN}[2] >${C_NC} Eliminar Cuenta $PROTO"
        echo -e "${C_CYAN}[3] >${C_NC} Renovar Cuenta $PROTO"
        echo -e "${C_CYAN}[4] >${C_NC} Verificar Conexión $PROTO"
        echo -e "${C_CYAN}[5] >${C_NC} Lista de Miembros $PROTO"
        echo -e "${C_CYAN}[6] >${C_NC} Cambiar Límite $PROTO"
        echo -e "${C_CYAN}[7] >${C_NC} Detalles Cuenta $PROTO"
        echo -e "${C_CYAN}[8] >${C_NC} Crear Prueba $PROTO"
        echo -e "${C_CYAN}[9] >${C_NC} Personalizar UUID $PROTO"
        echo -e "${C_CYAN}[10] >${C_NC} Recuperar config del usuario"
        echo -e "${C_CYAN}[x] >${C_NC} Salir del Gestor"
        echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
        echo -e "${C_RED}   ENTER SIN RESPUESTA REGRESA A MENU ANTERIOR ${C_NC}"
        echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
        read -p "Digite su opción: " opc

        case $opc in
            1)
                clear
                echo -e "${C_YELLOW}      CREAR USUARIO XRAY $PROTO      ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "Nombre de usuario: " user
                [ -z "$user" ] && continue
                read -p "Duración (días): " dias
                read -p "Cuota GB (0=Ilim): " cuota
                read -p "Límite IP (0=Ilim): " limite

                UUID=$(uuidgen)
                EXP_DATE=$(date -d "+$dias days" +"%Y-%m-%d")
                DOMINIO=$(cat $DOM_FILE)

                # Inyección Inteligente según el protocolo
                if [ "$LPROTO" == "vmess" ]; then
                    jq ".inbounds[2].settings.clients += [{\"id\": \"$UUID\", \"email\": \"$user\", \"alterId\": 0}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                elif [ "$LPROTO" == "vless" ]; then
                    jq ".inbounds[0].settings.clients += [{\"id\": \"$UUID\", \"email\": \"$user\"}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                    jq ".inbounds[1].settings.clients += [{\"id\": \"$UUID\", \"email\": \"$user\"}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                    jq ".inbounds[3].settings.clients += [{\"id\": \"$UUID\", \"email\": \"$user\"}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                elif [ "$LPROTO" == "trojan" ]; then
                    jq ".inbounds[4].settings.clients += [{\"password\": \"$UUID\", \"email\": \"$user\"}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                fi
                systemctl restart xray

                # Generación de Enlaces
                LINK_TLS=$(generar_enlace "$user" "$DOMINIO" "$UUID" "443" "ws" "tls" "/$LPROTO" "$LPROTO")
                LINK_NTLS=$(generar_enlace "$user" "$DOMINIO" "$UUID" "80" "ws" "" "/$LPROTO" "$LPROTO")

                clear
                echo -e "${C_YELLOW}    CUENTA $PROTO CREADA EXITOSAMENTE    ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                echo -e " Alias       : ${C_CYAN}$user${C_NC}"
                echo -e " Dominio     : ${C_CYAN}$DOMINIO${C_NC}"
                echo -e " UUID (Pass) : ${C_CYAN}$UUID${C_NC}"
                echo -e " Red         : ${C_CYAN}WS (TLS/NTLS)${C_NC}"
                echo -e " Expira      : ${C_CYAN}$EXP_DATE${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                echo -e " ${C_GREEN}LINK TLS (443) :${C_NC}\n $LINK_TLS\n"
                echo -e " ${C_GREEN}LINK NTLS (80) :${C_NC}\n $LINK_NTLS\n"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "Presiona ENTER para volver al menú " foo
                ;;
            2)
                read -p "Usuario a eliminar: " user
                jq ".inbounds[0].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[1].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[2].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[3].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[4].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                systemctl restart xray
                echo -e "${C_GREEN}[✔] Usuario $user eliminado.${C_NC}"; sleep 2
                ;;
            x|X|"") break ;;
            *) echo -e "${C_RED}Opción inválida${C_NC}"; sleep 1 ;;
        esac
    done
}

menu_principal
