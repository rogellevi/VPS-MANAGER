#!/bin/bash
# ==========================================
# Módulo Unificado: VMess (XRAY)
# Puertos: 80 (NTLS) y 443 (TLS)
# Compatible en simultáneo con VLESS
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
XRAY_DIR="/usr/local/etc/xray"
CONF_FILE="$XRAY_DIR/config.json"
DOM_FILE="/etc/vps-manager/dominio"
LIMIT_FILE="/etc/vps-manager/limites_vmess"
FLAG_FILE="/etc/vps-manager/xray_dual_ok"

instalar_xray_dual() {
    clear
    echo -e "${C_CYAN}================================================${C_NC}"
    echo -e "${C_GREEN}   INSTALACIÓN DUAL XRAY (80 NTLS + 443 TLS)    ${C_NC}"
    echo -e "${C_CYAN}================================================${C_NC}"
    
    read -p "Ingresa tu dominio (Ej: centrix.golbertvps.online): " DOMINIO
    if [ -z "$DOMINIO" ]; then echo -e "${C_RED}[!] Dominio inválido.${C_NC}"; sleep 2; return; fi
    mkdir -p /etc/vps-manager
    echo "$DOMINIO" > $DOM_FILE

    echo -e "${C_YELLOW}[+] Instalando dependencias y núcleo Xray...${C_NC}"
    apt update -y >/dev/null 2>&1
    apt install -y certbot jq uuid-runtime curl iptables ufw psmisc openssl >/dev/null 2>&1
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1

    echo -e "${C_YELLOW}[+] Liberando puertos 80 y 443...${C_NC}"
    systemctl stop nginx apache2 haproxy xray 2>/dev/null
    fuser -k 80/tcp 2>/dev/null
    fuser -k 443/tcp 2>/dev/null

    mkdir -p $XRAY_DIR
    echo -e "${C_YELLOW}[+] Configurando Certificado SSL para puerto 443...${C_NC}"
    if [ ! -f "/etc/letsencrypt/live/$DOMINIO/fullchain.pem" ]; then
        certbot certonly --standalone -d "$DOMINIO" --non-interactive --agree-tos -m "admin@$DOMINIO" >/dev/null 2>&1
    fi

    if [ -f "/etc/letsencrypt/live/$DOMINIO/fullchain.pem" ]; then
        cp /etc/letsencrypt/live/$DOMINIO/fullchain.pem $XRAY_DIR/server.crt
        cp /etc/letsencrypt/live/$DOMINIO/privkey.pem $XRAY_DIR/server.key
    else
        echo -e "${C_YELLOW}[!] Generando certificado SSL autofirmado de respaldo...${C_NC}"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout $XRAY_DIR/server.key -out $XRAY_DIR/server.crt \
            -subj "/C=PE/ST=Lima/L=Lima/O=VPS/CN=$DOMINIO" >/dev/null 2>&1
    fi
    chmod 644 $XRAY_DIR/server.crt $XRAY_DIR/server.key

    echo -e "${C_YELLOW}[+] Aplicando permisos root y estructura dual (80 y 443)...${C_NC}"
    sed -i 's/User=nobody/User=root/g' /etc/systemd/system/xray.service 2>/dev/null
    systemctl daemon-reload

    cat << 'EOF' > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none",
        "fallbacks": [
          { "path": "/vless", "dest": 10001 },
          { "path": "/vmess", "dest": 10002 }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "certificates": [
            {
              "certificateFile": "/usr/local/etc/xray/server.crt",
              "keyFile": "/usr/local/etc/xray/server.key"
            }
          ]
        }
      }
    },
    {
      "port": 80,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none",
        "fallbacks": [
          { "path": "/vless", "dest": 10001 },
          { "path": "/vmess", "dest": 10002 }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      }
    },
    {
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/vless"
        }
      }
    },
    {
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": []
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/vmess"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

    iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    iptables-save > /etc/iptables.up.rules 2>/dev/null
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1

    systemctl restart xray
    touch $FLAG_FILE
    echo -e "${C_GREEN}[✔] ¡Puertos 80 (NTLS) y 443 (TLS) activos para VLESS y VMess!${C_NC}"
    sleep 2
}

generar_link_vmess_ntls() {
    local alias=$1 dom=$2 uuid=$3
    local json="{\"v\":\"2\",\"ps\":\"$alias\",\"add\":\"$dom\",\"port\":\"80\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$dom\",\"path\":\"/vmess\",\"tls\":\"none\"}"
    echo "vmess://$(echo -n "$json" | base64 -w 0)"
}

generar_link_vmess_tls() {
    local alias=$1 dom=$2 uuid=$3
    local json="{\"v\":\"2\",\"ps\":\"$alias\",\"add\":\"$dom\",\"port\":\"443\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$dom\",\"path\":\"/vmess\",\"tls\":\"tls\",\"sni\":\"$dom\"}"
    echo "vmess://$(echo -n "$json" | base64 -w 0)"
}

menu_vmess() {
    if [ ! -f "$FLAG_FILE" ]; then instalar_xray_dual; fi
    
    while true; do
        clear
        echo -e "${C_YELLOW}        GESTION DE VMESS (80 / 443)        ${C_NC}"
        echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
        echo -e "${C_CYAN}[1] >${C_NC} Crear Cuenta Vmess"
        echo -e "${C_CYAN}[2] >${C_NC} Eliminar Cuenta Vmess"
        echo -e "${C_CYAN}[3] >${C_NC} Renovar Días de Cuenta"
        echo -e "${C_CYAN}[4] >${C_NC} Bloquear / Suspender Cuenta"
        echo -e "${C_CYAN}[5] >${C_NC} Configurar Límite de Dispositivos"
        echo -e "${C_CYAN}[6] >${C_NC} Reinstalar / Reparar Motor Xray"
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
                DOM=$(cat $DOM_FILE 2>/dev/null)

                jq ".inbounds[3].settings.clients += [{\"id\": \"$UUID\", \"email\": \"$user\", \"alterId\": 0}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                systemctl restart xray

                LINK_TLS=$(generar_link_vmess_tls "$user-TLS" "$DOM" "$UUID")
                LINK_NTLS=$(generar_link_vmess_ntls "$user-NTLS" "$DOM" "$UUID")

                clear
                echo -e "${C_YELLOW}    CUENTA VMESS CREADA EXITOSAMENTE    ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                echo -e " Alias       : ${C_CYAN}$user${C_NC}"
                echo -e " Dominio     : ${C_CYAN}$DOM${C_NC}"
                echo -e " UUID        : ${C_CYAN}$UUID${C_NC}"
                echo -e " Puertos     : ${C_CYAN}443 (TLS) / 80 (NTLS)${C_NC}"
                echo -e " Ruta (Path) : ${C_CYAN}/vmess${C_NC}"
                echo -e " Expira      : ${C_CYAN}$EXP_DATE${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                echo -e "\n ${C_GREEN}LINK TLS (443) :${C_NC}\n$LINK_TLS\n"
                echo -e " ${C_GREEN}LINK NTLS (80) :${C_NC}\n$LINK_NTLS\n"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "Presiona ENTER para volver al menú " foo
                ;;
            2)
                clear
                echo -e "${C_YELLOW}     ELIMINAR USUARIO XRAY VMESS     ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "Usuario a eliminar: " user
                [ -z "$user" ] && continue
                
                jq ".inbounds[3].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                systemctl restart xray
                echo -e "${C_GREEN}[✔] Cuenta $user eliminada correctamente.${C_NC}"
                read -p "Presiona ENTER para continuar..." foo
                ;;
            3)
                clear
                echo -e "${C_YELLOW}      RENOVAR CUENTA XRAY VMESS      ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "Nombre del usuario a renovar: " user
                read -p "Días a sumar: " dias_extras
                [ -z "$user" ] || [ -z "$dias_extras" ] && continue
                
                NUEVA_EXP=$(date -d "+$dias_extras days" +"%Y-%m-%d")
                echo -e "${C_GREEN}[✔] Cuenta $user renovada. Nueva vigencia estimada hasta: $NUEVA_EXP${C_NC}"
                read -p "Presiona ENTER para continuar..." foo
                ;;
            4)
                clear
                echo -e "${C_YELLOW}     BLOQUEAR / SUSPENDER USUARIO     ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "Nombre del usuario a bloquear: " user
                [ -z "$user" ] && continue
                
                jq ".inbounds[3].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                systemctl restart xray
                
                echo -e "${C_GREEN}[✔] El usuario $user ha sido bloqueado del servidor.${C_NC}"
                read -p "Presiona ENTER para continuar..." foo
                ;;
            5)
                clear
                echo -e "${C_YELLOW}      LÍMITE DE DISPOSITIVOS (IPs)      ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "Nombre del usuario: " user
                read -p "Máximo de dispositivos permitidos: " max_disp
                [ -z "$user" ] || [ -z "$max_disp" ] && continue
                
                mkdir -p /etc/vps-manager
                echo "$user $max_disp" >> $LIMIT_FILE
                echo -e "${C_GREEN}[✔] Límite de $max_disp dispositivos configurado para $user.${C_NC}"
                read -p "Presiona ENTER para continuar..." foo
                ;;
            6)
                instalar_xray_dual
                ;;
            x|X|"") break ;;
        esac
    done
}

menu_vmess