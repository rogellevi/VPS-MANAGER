#!/bin/bash
# ==========================================
# INSTALADOR DROPBEAR COMPATIBLE CON APPS VPN
# VPS MANAGER V5.2
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
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}   🐻 INSTALADOR DROPBEAR (Compatible VPN)  ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"

# Verificar si ya está instalado
if systemctl is-active --quiet dropbear 2>/dev/null || netstat -tlpn 2>/dev/null | grep -q 'dropbear'; then
    echo -e "${C_YELLOW}[!] Dropbear ya está instalado.${C_RST}"
    read -p "¿Desea reinstalarlo con configuración compatible? (s/n): " reinst
    if [[ "$reinst" == "s" || "$reinst" == "S" ]]; then
        echo -e "${C_YELLOW}[+] Desinstalando Dropbear actual...${C_RST}"
        systemctl stop dropbear 2>/dev/null
        systemctl disable dropbear 2>/dev/null
        apt-get remove dropbear -y >/dev/null 2>&1
        apt-get purge dropbear -y >/dev/null 2>&1
        rm -rf /etc/default/dropbear
        rm -rf /etc/dropbear
    else
        echo -e "${C_GREEN}[✔] Instalación cancelada.${C_RST}"
        sleep 2
        exit 0
    fi
fi

# Solicitar puerto principal
echo -ne "${C_YELLOW}¿Qué puerto principal quieres usar? (1-65535): ${C_RST}"
read porta

if [[ ! "$porta" =~ ^[0-9]+$ ]] || [ "$porta" -lt 1 ] || [ "$porta" -gt 65535 ]; then
    echo -e "${C_RED}[!] Puerto no válido.${C_RST}"
    sleep 2
    exit 1
fi

if [ "$porta" = "22" ]; then
    echo -e "${C_RED}[!] ADVERTENCIA: El puerto 22 está en uso por OpenSSH.${C_RST}"
    echo -e "${C_YELLOW}Se recomienda usar otro puerto como 444, 445, 8080.${C_RST}"
    read -p "¿Continuar de todos modos? (s/n): " continuar
    [[ "$continuar" != "s" && "$continuar" != "S" ]] && exit 0
fi

if ss -lntp 2>/dev/null | grep -q ":$porta "; then
    local svc=$(ss -lntp 2>/dev/null | grep ":$porta " | awk '{print $NF}' | cut -d'"' -f2)
    echo -e "${C_RED}[!] El puerto $porta ya está en uso por: $svc${C_RST}"
    sleep 3
    exit 1
fi

echo -e "${C_YELLOW}[+] Instalando Dropbear...${C_RST}"
apt-get update -y >/dev/null 2>&1
apt-get install dropbear -y >/dev/null 2>&1

# Configurar shells
if ! grep -q "/bin/false" /etc/shells; then
    echo "/bin/false" >> /etc/shells
fi

# Configurar sshd_config
sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
sed -i '/^PermitTunnel/d' /etc/ssh/sshd_config
echo "PermitTunnel yes" >> /etc/ssh/sshd_config

# Crear directorio y banner
mkdir -p /etc/dropbear
echo "Bienvenido a VPS Manager" > /etc/dropbear/banner

# 🚨 GENERAR CLAVES CRIPTOGRÁFICAS (CRÍTICO PARA COMPATIBILIDAD)
echo -e "${C_YELLOW}[+] Generando claves criptográficas RSA y ECDSA...${C_RST}"
rm -f /etc/dropbear/dropbear_rsa_host_key
rm -f /etc/dropbear/dropbear_ecdsa_host_key
dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1
dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key >/dev/null 2>&1
chmod 600 /etc/dropbear/dropbear_*_host_key
chown root:root /etc/dropbear/dropbear_*_host_key

# 🚨 CONFIGURACIÓN COMPATIBLE CON TLS TÚNEL Y HTTP INJECTOR
# Usar DROPBEAR_EXTRA_ARGS para TODOS los puertos (systemd ignora DROPBEAR_PORT)
cat > /etc/default/dropbear << EOF
# Configuración generada por VPS Manager V5.2
# Compatible con TLS Túnel y HTTP Injector
NO_START=0
DROPBEAR_EXTRA_ARGS="-p $porta -p 110 -R -T 2"
DROPBEAR_BANNER="/etc/dropbear/banner"
DROPBEAR_RECEIVE_WINDOW=65536
EOF

# Limpiar procesos residuales
systemctl stop dropbear 2>/dev/null
pkill -9 dropbear 2>/dev/null
sleep 1

# Iniciar servicio nativo
systemctl daemon-reload
systemctl enable dropbear >/dev/null 2>&1
systemctl restart dropbear

# Configurar UFW si está activo
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
    ufw allow "$porta/tcp" >/dev/null 2>&1
    ufw allow "110/tcp" >/dev/null 2>&1
fi

systemctl restart ssh >/dev/null 2>&1

# Verificar que realmente esté corriendo
sleep 2
if systemctl is-active --quiet dropbear 2>/dev/null; then
    echo -e "${C_GREEN}[✔] Dropbear instalado y activo.${C_RST}"
    echo -e "${C_CYAN}Puertos: ${C_YELLOW}$porta${C_RST} (principal) y ${C_YELLOW}110${C_RST} (extra)${C_RST}"
    echo -e "${C_CYAN}Configuración compatible con TLS Túnel y HTTP Injector.${C_RST}"
    echo ""
    echo -e "${C_YELLOW}Si aún no conecta desde tu app VPN, ejecuta:${C_RST}"
    echo -e "${C_NEON_BLUE}dropbear -h 2>&1 | grep -A 5 'Available'${C_RST}"
    echo -e "${C_YELLOW}Y verifica que aparezcan estos algoritmos:${C_RST}"
    echo -e "  ${C_GREEN}• diffie-hellman-group14-sha1${C_RST}"
    echo -e "  ${C_GREEN}• aes128-cbc, aes256-cbc${C_RST}"
    echo -e "  ${C_GREEN}• hmac-sha1${C_RST}"
else
    echo -e "${C_RED}[!] Dropbear NO pudo iniciar.${C_RST}"
    echo -e "${C_YELLOW}Verifica con: systemctl status dropbear${C_RST}"
    echo -e "${C_YELLOW}O revisa los logs: journalctl -u dropbear -n 50${C_RST}"
fi

echo -e "${C_GREEN}[✔] Volviendo al menú en 3 segundos...${C_RST}"
sleep 3