#!/bin/bash
# Módulo de Automatización Cloudflare para Golbert VPS (golbertvps.online)

CF_CONFIG="/etc/vps-manager/cloudflare.conf"

# Configurar credenciales si no existen
if [ ! -f "$CF_CONFIG" ]; then
    clear
    echo -e "\033[1;36m=== CONFIGURACIÓN DE CLOUDFLARE ===\033[0m"
    read -p "Ingrese su Correo de Cloudflare: " CF_EMAIL
    read -p "Ingrese su Global API Key o Token: " CF_API_KEY
    read -p "Ingrese el Zone ID de golbertvps.online: " ZONE_ID
    
    mkdir -p /etc/vps-manager
    cat <<EOF > "$CF_CONFIG"
CF_EMAIL="$CF_EMAIL"
CF_API_KEY="$CF_API_KEY"
ZONE_ID="$ZONE_ID"
DOMAIN="golbertvps.online"
EOF
    echo -e "\033[1;32m[✔] Credenciales guardadas correctamente.\033[0m"
    sleep 2
fi

# Función para registrar subdominio y NS del cliente
registrar_dns_cliente() {
    local CLIENTE=$1
    local IP_VPS=$2
    
    source "$CF_CONFIG"
    
    local SUB_CLIENTE="${CLIENTE}.${DOMAIN}"
    local NS_CLIENTE="ns${CLIENTE}.${DOMAIN}"

    # 1. Crear registro tipo A
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
         -H "X-Auth-Email: ${CF_EMAIL}" \
         -H "X-Auth-Key: ${CF_API_KEY}" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"A\",\"name\":\"${SUB_CLIENTE}\",\"content\":\"${IP_VPS}\",\"ttl\":120,\"proxied\":false}" > /dev/null

    # 2. Crear registro tipo NS para SlowDNS
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
         -H "X-Auth-Email: ${CF_API_KEY:+}" \
         -H "X-Auth-Email: ${CF_EMAIL}" \
         -H "X-Auth-Key: ${CF_API_KEY}" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"NS\",\"name\":\"${NS_CLIENTE}\",\"content\":\"${SUB_CLIENTE}\",\"ttl\":120}" > /dev/null
}

# Si se ejecuta directamente pasando argumentos desde la terminal o bot
if [ "$#" -eq 2 ]; then
    registrar_dns_cliente "$1" "$2"
fi
