#!/bin/bash
# ==========================================
# INSTALADOR DROPBEAR - VPS MANAGER V5.2
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
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🐻 INSTALADOR DROPBEAR SSH           ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"

# Verificar si ya está instalado
if [ -f /etc/default/dropbear ] || systemctl is-active --quiet dropbear 2>/dev/null; then
    echo -e "${C_YELLOW}[!] Dropbear ya parece estar instalado en el sistema.${C_RST}"
    read -p "¿Desea reconfigurar los puertos de escucha? (s/n): " reconf
    if [[ "$reconf" != "s" && "$reconf" != "S" ]]; then
        echo -e "${C_GREEN}[✔] Operación cancelada. Volviendo al menú...${C_RST}"
        sleep 2
        exit 0
    fi
fi

# Solicitar puerto principal
while true; do
    echo -ne "${C_YELLOW}Ingrese el puerto principal para Dropbear (ej. 143, 80, 443): ${C_RST}"
    read PORT1
    
    if [[ ! "$PORT1" =~ ^[0-9]+$ ]] || [ "$PORT1" -lt 1 ] || [ "$PORT1" -gt 65535 ]; then
        echo -e "${C_RED}[!] Puerto no válido. Debe ser un número entre 1 y 65535.${C_RST}"
        continue
    fi
    
    # Verificar si el puerto está en uso
    if ss -lntp 2>/dev/null | grep -q ":$PORT1 " || netstat -tuln 2>/dev/null | grep -q ":$PORT1 "; then
        echo -e "${C_RED}[!] El puerto $PORT1 ya está en uso por otro servicio.${C_RST}"
        read -p "¿Desea usarlo de todos modos? (s/n): " usar
        if [[ "$usar" != "s" && "$usar" != "S" ]]; then
            continue
        fi
    fi
    break
done

# Solicitar puerto secundario (opcional)
echo -ne "${C_YELLOW}¿Desea agregar un segundo puerto de escucha? (s/n): ${C_RST}"
read add_port2
PORT2=""
if [[ "$add_port2" == "s" || "$add_port2" == "S" ]]; then
    while true; do
        echo -ne "${C_YELLOW}Ingrese el segundo puerto para Dropbear: ${C_RST}"
        read PORT2
        
        if [[ ! "$PORT2" =~ ^[0-9]+$ ]] || [ "$PORT2" -lt 1 ] || [ "$PORT2" -gt 65535 ]; then
            echo -e "${C_RED}[!] Puerto no válido.${C_RST}"
            continue
        fi
        
        if [ "$PORT2" == "$PORT1" ]; then
            echo -e "${C_RED}[!] El puerto debe ser diferente al principal.${C_RST}"
            continue
        fi
        break
    done
fi

echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "${C_GREEN}[+] Configuración seleccionada:${C_RST}"
echo -e "  ➔ Puerto Principal: ${C_YELLOW}$PORT1${C_RST}"
[ -n "$PORT2" ] && echo -e "  ➔ Puerto Secundario: ${C_YELLOW}$PORT2${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"

read -p "¿Proceder con la instalación/configuración? (s/n): " confirm
if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then
    echo -e "${C_RED}[!] Instalación cancelada. Volviendo al menú...${C_RST}"
    sleep 2
    exit 0
fi

echo -e "${C_YELLOW}[+] Actualizando repositorios e instalando Dropbear...${C_RST}"
apt-get update -y > /dev/null 2>&1
apt-get install dropbear -y > /dev/null 2>&1

echo -e "${C_YELLOW}[+] Configurando el sistema...${C_RST}"
# Asegurar que /bin/false esté en shells (requerido para usuarios SSH limitados)
if ! grep -q "/bin/false" /etc/shells; then
    echo "/bin/false" >> /etc/shells
fi

# Crear directorio y banner si no existen
mkdir -p /etc/dropbear
touch /etc/dropbear/banner

# Configurar /etc/default/dropbear
cat <<EOF > /etc/default/dropbear
# Configuración generada por VPS MANAGER
NO_START=0
DROPBEAR_BANNER="/etc/dropbear/banner"
DROPBEAR_RECEIVE_WINDOW=65536
EOF

# Construir argumentos de puerto
PORT_ARGS="-p $PORT1"
[ -n "$PORT2" ] && PORT_ARGS="$PORT_ARGS -p $PORT2"

echo "DROPBEAR_EXTRA_ARGS=\"$PORT_ARGS\"" >> /etc/default/dropbear

# Reiniciar servicios
echo -e "${C_YELLOW}[+] Reiniciando servicios de red...${C_RST}"
systemctl daemon-reload > /dev/null 2>&1
systemctl restart dropbear > /dev/null 2>&1
systemctl enable dropbear > /dev/null 2>&1

# Configurar UFW si está activo
if command -v ufw > /dev/null && ufw status | grep -q "active"; then
    ufw allow "$PORT1/tcp" > /dev/null 2>&1
    [ -n "$PORT2" ] && ufw allow "$PORT2/tcp" > /dev/null 2>&1
    ufw reload > /dev/null 2>&1
fi

clear
echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         ✅ DROPBEAR INSTALADO CON ÉXITO        ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "  ${C_GREEN}Puertos de escucha configurados:${C_RST}"
echo -e "  ${C_YELLOW}➔ $PORT1${C_RST}"
[ -n "$PORT2" ] && echo -e "  ${C_YELLOW}➔ $PORT2${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "  ${C_CYAN}Ejemplo de conexión:${C_RST}"
echo -e "  ${C_YELLOW}ssh usuario@$(hostname -I | awk '{print $1}') -p $PORT1${C_RST}"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
echo -e "${C_GREEN}[✔] Volviendo al menú principal en 3 segundos...${C_RST}"
sleep 3