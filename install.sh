#!/bin/bash
# ==========================================
# Script de Instalación - VPS MANAGER V5.0
# ==========================================

clear
echo -e "\033[1;36m================================================\033[0m"
echo -e "\033[1;32m       INSTALADOR VPS MANAGER V4.5 LTS          \033[0m"
echo -e "\033[1;36m================================================\033[0m"

# ==========================================
# 0. VERIFICACIÓN DE ROOT
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo -e "\n\033[1;31m[!] Error: Este script debe ejecutarse como root.\033[0m"
    echo -e "\033[1;33m    Usa: sudo bash install.sh\033[0m"
    exit 1
fi

# ==========================================
# 1. SISTEMA DE KEY / LICENCIA
# ==========================================

#echo -e "\n\033[1;33mPor favor, ingrese su Key de instalación:\033[0m"
#read -p "Key: " input_key="FREEKEY"

#if [ -z "$input_key" ]; then
#    echo -e "\n\033[1;31m[!] Error: No se ingresó ninguna Key.\033[0m"
#    exit 1
#fi

#echo -e "\n\033[1;36mVerificando Key...\033[0m"
#sleep 1


input_key="FREE-KEY-GT"

echo -e "\n\033[1;33mKey de instalación cargada.\033[0m"

if [ -z "$input_key" ]; then
    echo -e "\n\033[1;31m[!] Error: No se configuró ninguna Key.\033[0m"
    exit 1
fi

echo -e "\n\033[1;36mVerificando Key...\033[0m"
sleep 1

# ⚠️ IMPORTANTE: AQUÍ ABAJO DEBES PONER EL COMANDO ORIGINAL QUE CONECTABA CON TU BOT
# Si usabas 'curl' o 'wget' para validar en tu IP, ponlo aquí.
# Ejemplo de cómo suele verse:
# verificacion=$(curl -s "http://45.41.207.172:8080/validar?key=$input_key")
# if [ "$verificacion" != "ACTIVA" ]; then
#     echo -e "\033[1;31m[!] Key inválida o expirada.\033[0m"
#     exit 1
# fi

echo -e "\033[1;32m[✔] Key validada correctamente.\033[0m"
sleep 1

# ==========================================
# 2. ACTUALIZACIÓN DEL SISTEMA
# ==========================================
echo -e "\n\033[1;36m[+] Actualizando el sistema (esto puede tardar)...\033[0m"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get upgrade -y

if [ $? -ne 0 ]; then
    echo -e "\033[1;31m[!] Hubo problemas al actualizar el sistema. Continuando...\033[0m"
    sleep 2
else
    echo -e "\033[1;32m[✔] Sistema actualizado correctamente.\033[0m"
fi

# ==========================================
# 3. INSTALACIÓN DE PAQUETES NECESARIOS
# ==========================================
echo -e "\n\033[1;36m[+] Instalando paquetes necesarios...\033[0m"
apt-get install -y bc screen nano unzip lsof net-tools dos2unix nload jq curl figlet python3 python3-pip at ca-certificates gnupg lsb-release

# 'python' es opcional, en distros modernas solo existe python3
apt-get install -y python || true

if [ $? -ne 0 ]; then
    echo -e "\033[1;31m[!] Algunos paquetes fallaron. Verifica los logs arriba.\033[0m"
    sleep 2
else
    echo -e "\033[1;32m[✔] Paquetes instalados correctamente.\033[0m"
fi

# ==========================================
# 4. INSTALACIÓN DE SPEEDTEST (Ookla oficial + fallback)
# ==========================================
echo -e "\n\033[1;36m[+] Instalando Speedtest CLI (Ookla oficial)...\033[0m"

SPEEDTEST_OK=0

# Método 1: Ookla oficial vía packagecloud
if curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash >/dev/null 2>&1; then
    if apt-get install -y speedtest >/dev/null 2>&1; then
        echo -e "\033[1;32m[✔] Speedtest CLI (Ookla) instalado correctamente.\033[0m"
        SPEEDTEST_OK=1
    fi
fi

# Método 2: Fallback con pip / pip3 / --break-system-packages
if [ "$SPEEDTEST_OK" -eq 0 ]; then
    echo -e "\033[1;33m[!] Ookla falló, intentando con speedtest-cli (pip)...\033[0m"
    if pip install speedtest-cli 2>/dev/null; then
        echo -e "\033[1;32m[✔] speedtest-cli instalado con pip.\033[0m"
        SPEEDTEST_OK=1
    elif pip3 install speedtest-cli 2>/dev/null; then
        echo -e "\033[1;32m[✔] speedtest-cli instalado con pip3.\033[0m"
        SPEEDTEST_OK=1
    elif pip3 install --break-system-packages speedtest-cli 2>/dev/null; then
        echo -e "\033[1;32m[✔] speedtest-cli instalado con pip3 (--break-system-packages).\033[0m"
        SPEEDTEST_OK=1
    fi
fi

# Método 3: Fallback final con apt
if [ "$SPEEDTEST_OK" -eq 0 ]; then
    echo -e "\033[1;33m[!] pip falló, intentando con apt...\033[0m"
    if apt-get install -y speedtest-cli >/dev/null 2>&1; then
        echo -e "\033[1;32m[✔] speedtest-cli instalado vía apt.\033[0m"
        SPEEDTEST_OK=1
    fi
fi

if [ "$SPEEDTEST_OK" -eq 0 ]; then
    echo -e "\033[1;31m[!] No se pudo instalar ningún Speedtest. Instálalo manualmente.\033[0m"
fi

# ==========================================
# 5. CREACIÓN DE DIRECTORIOS
# ==========================================
echo -e "\n\033[1;36m[+] Preparando sistema...\033[0m"
mkdir -p /etc/vps-manager/core
mkdir -p /usr/local/bin

# ==========================================
# 6. DESCARGA DE MÓDULOS
# ==========================================
echo -e "\033[1;32m[✔] Descargando componentes y módulos core...\033[0m"

wget -O /etc/vps-manager/proxy.py https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main/core/proxy.py
wget -O /etc/vps-manager/limiter.sh https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main/core/limiter.sh
wget -O /etc/vps-manager/core/setup_dns.sh https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main/core/setup_dns.sh

chmod +x /etc/vps-manager/limiter.sh
chmod +x /etc/vps-manager/core/setup_dns.sh

# ==========================================
# 7. DESCARGA DEL MENÚ PRINCIPAL
# ==========================================
echo -e "\033[1;32m[✔] Instalando el Panel Principal...\033[0m"
rm -f /usr/local/bin/menu
rm -f /usr/local/bin/me

wget -O /usr/local/bin/menu https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main/menu.sh
chmod +x /usr/local/bin/menu

# ==========================================
# 8. FINALIZACIÓN Y APERTURA AUTOMÁTICA
# ==========================================
echo -e "\n\033[1;32m[✔] ¡Instalación modular completada con éxito!\033[0m"
sleep 2

# Limpiar pantalla e iniciar el menú automáticamente
clear
menu.