#!/bin/bash
# ==========================================
# Script de Instalación - VPS MANAGER V5.0
# ==========================================

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

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
# Ejemplo (con timeout para evitar cuelgues):
# verificacion=$(curl -s --max-time 10 "http://45.41.207.172:8080/validar?key=$input_key")
# if [ "$verificacion" != "ACTIVA" ]; then
#     echo -e "\033[1;31m[!] Key inválida o expirada.\033[0m"
#     exit 1
# fi

echo -e "\033[1;32m[✔] Key validada correctamente.\033[0m"
sleep 1

# ==========================================
# 2. ESPERAR LIBERACIÓN DEL LOCK DE APT
# ==========================================
echo -e "\n\033[1;36m[+] Verificando disponibilidad de apt...\033[0m"
for i in $(seq 1 60); do
    if ! fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then
        break
    fi
    echo -e "\033[1;33m    Esperando lock de apt... ($i/60)\033[0m"
    sleep 5
done

# ==========================================
# 3. ACTUALIZACIÓN DEL SISTEMA (sin upgrade para evitar cuelgues)
# ==========================================
echo -e "\n\033[1;36m[+] Actualizando índices del sistema...\033[0m"
if ! apt-get update -y; then
    echo -e "\033[1;31m[!] Falló 'apt-get update'. Revisa tu conexión o repos.\033[0m"
    sleep 2
else
    echo -e "\033[1;32m[✔] Índices actualizados correctamente.\033[0m"
fi

# ==========================================
# 4. INSTALACIÓN DE PAQUETES NECESARIOS
# ==========================================
echo -e "\n\033[1;36m[+] Instalando paquetes necesarios...\033[0m"
if ! apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        bc screen nano unzip lsof net-tools dos2unix nload jq curl figlet \
        python3 python3-pip at ca-certificates gnupg lsb-release; then
    echo -e "\033[1;31m[!] Falló la instalación de paquetes base. Abortando.\033[0m"
    exit 1
fi
echo -e "\033[1;32m[✔] Paquetes base instalados correctamente.\033[0m"

# 'python' es opcional, en distros modernas solo existe python3
apt-get install -y python || true

# ==========================================
# 5. CREACIÓN DE DIRECTORIOS
# ==========================================
echo -e "\n\033[1;36m[+] Preparando sistema...\033[0m"
mkdir -p /etc/vps-manager/core
mkdir -p /usr/local/bin

# ==========================================
# 6. FUNCIÓN DE DESCARGA CON REINTENTOS Y VALIDACIÓN
# ==========================================
descargar() {
    local url="$1" dest="$2"
    for i in 1 2 3; do
        if wget -q --timeout=20 --tries=2 -O "$dest" "$url" \
           && [ -s "$dest" ] && ! grep -qi "<html" "$dest"; then
            return 0
        fi
        echo -e "\033[1;33m    Reintento $i/3 para: $url\033[0m"
        sleep 3
    done
    echo -e "\033[1;31m[!] No se pudo descargar: $url\033[0m"
    return 1
}

# ==========================================
# 7. DESCARGA DE MÓDULOS
# ==========================================
echo -e "\033[1;32m[✔] Descargando componentes y módulos core...\033[0m"

descargar "https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main/core/proxy.py" \
    /etc/vps-manager/proxy.py || exit 1

descargar "https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main/core/limiter.sh" \
    /etc/vps-manager/limiter.sh || exit 1

descargar "https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main/core/setup_dns.sh" \
    /etc/vps-manager/core/setup_dns.sh || exit 1

chmod +x /etc/vps-manager/limiter.sh
chmod +x /etc/vps-manager/core/setup_dns.sh

# ==========================================
# 8. DESCARGA DEL MENÚ PRINCIPAL
# ==========================================
echo -e "\033[1;32m[✔] Instalando el Panel Principal...\033[0m"
rm -f /usr/local/bin/menu
rm -f /usr/local/bin/me

descargar "https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main/menu.sh" \
    /usr/local/bin/menu || exit 1

chmod +x /usr/local/bin/menu

# ==========================================
# 9. VERIFICACIÓN FINAL Y APERTURA AUTOMÁTICA
# ==========================================
echo -e "\n\033[1;32m[✔] ¡Instalación modular completada con éxito!\033[0m"
sleep 2

if [ -x /usr/local/bin/menu ]; then
    clear
    /usr/local/bin/menu
else
    echo -e "\033[1;31m[!] El menú no se instaló correctamente. Revisa tu conexión.\033[0m"
    exit 1
fi