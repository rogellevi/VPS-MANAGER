#!/bin/bash
# ==========================================
# Módulo: Gestor de Usuarios SSH / Dropbear
# ==========================================

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

while true; do
    clear
    echo -e "${CYAN}================================================${NC}"
    echo -e "${GREEN}             GESTOR DE SSH / DROPBEAR           ${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo -e "${GREEN}1) ${NC}Crear nuevo usuario SSH"
    echo -e "${GREEN}2) ${NC}Eliminar usuario SSH"
    echo -e "${GREEN}3) ${NC}Renovar usuario SSH"
    echo -e "${GREEN}4) ${NC}Lista de usuarios conectados"
    echo -e "${GREEN}0) ${NC}Volver al Menú Principal"
    echo -e "${CYAN}================================================${NC}"
    read -p "Seleccione una opción: " opt
    case $opt in
        1) 
            echo -e "\n${YELLOW}--- Crear Nuevo Usuario ---${NC}"
            read -p "Nombre de usuario: " user
            read -p "Contraseña: " pass
            read -p "Días de validez: " dias
            # Creación del usuario en Linux
            useradd -e $(date -d "+$dias days" +"%Y-%m-%d") -s /bin/false -M $user
            echo "$user:$pass" | chpasswd
            echo -e "${GREEN}[✔] Usuario $user creado con éxito por $dias días.${NC}"
            sleep 2
            ;;
        2)
            echo -e "\n${YELLOW}--- Eliminar Usuario ---${NC}"
            read -p "Nombre de usuario a eliminar: " user
            userdel -f $user 2>/dev/null
            echo -e "${GREEN}[✔] Usuario $user eliminado.${NC}"
            sleep 2
            ;;
        3)
            echo -e "\n${YELLOW}--- Renovar Usuario ---${NC}"
            read -p "Nombre de usuario a renovar: " user
            read -p "Nuevos días de validez: " dias
            chage -E $(date -d "+$dias days" +"%Y-%m-%d") $user
            echo -e "${GREEN}[✔] Usuario $user renovado por $dias días más.${NC}"
            sleep 2
            ;;
        4)
            clear
            echo -e "${CYAN}================================================${NC}"
            echo -e "${YELLOW}       Usuarios SSH/Dropbear conectados         ${NC}"
            echo -e "${CYAN}================================================${NC}"
            ps -ef | grep -E "sshd|dropbear" | grep -v root | grep -v grep | awk '{print $1}' | sort | uniq -c
            echo -e "\n"
            read -p "Presione Enter para continuar..."
            ;;
        0) 
            break 
            ;;
        *) 
            echo -e "${RED}[!] Opción inválida.${NC}"
            sleep 1 
            ;;
    esac
done
