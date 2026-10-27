#!/bin/bash
# ==========================================
# Módulo: Actualizador del Panel Principal
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}        ACTUALIZADOR DE PANEL VPS MANAGER       ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

echo -e "${C_YELLOW}[+] Buscando actualizaciones en GitHub...${C_NC}"
wget -qO /tmp/menu.sh "https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main/update/menu"

if [ -s /tmp/menu.sh ]; then
    echo -e "${C_YELLOW}[+] Descarga Exitosa. Aplicando actualización...${C_NC}"
    mv /tmp/menu.sh /usr/local/bin/menu
    chmod +x /usr/local/bin/menu
    
    echo -e "${C_GREEN}[✔] ¡Panel actualizado con éxito! Reiniciando...${C_NC}"
    sleep 2
    exec menu
else
    echo -e "${C_RED}[!] Error al descargar la actualización.${C_NC}"
    echo -e "${C_YELLOW}Verifica tu conexión a internet o asegúrate de que el archivo menu existe en el repositorio.${C_NC}"
    sleep 3
fi
