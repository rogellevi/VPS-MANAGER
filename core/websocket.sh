#!/bin/bash
# ==========================================
# Módulo: Websocket Service Manager
# ==========================================

clear
echo -e "\033[1;36m[+] Verificando servicios Websocket...\033[0m"

# Verificar si el servicio sshws está activo
if systemctl is-active --quiet sshws; then
    echo -e "\n\033[1;32m[✔] El servicio Websocket (SSHWS) está ACTIVO y operativo.\033[0m"
    echo -e "Puerto de escucha actual: \033[1;33m8080\033[0m"
else
    echo -e "\n\033[1;33m[!] El servicio no estaba activo. Reiniciando...\033[0m"
    systemctl restart sshws >/dev/null 2>&1
    echo -e "\033[1;32m[✔] Servicio reiniciado correctamente.\033[0m"
fi

sleep 2
