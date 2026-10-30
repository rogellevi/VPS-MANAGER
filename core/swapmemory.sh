#!/bin/bash
# ==========================================
# MEMORIA VIRTUAL (SWAP) - VPS-MANAGER
# Base: kiritosshxd | Adaptado al menú
# Archivo swap: /bin/ram.img
# ==========================================

SWAPFILE="/bin/ram.img"
SYSCTL_FILE="/etc/sysctl.d/99-vps-swap.conf"

# Paleta del menú principal
C_RST='\033[0m'; C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
C_NEON_BLUE='\033[38;5;39m'; C_NEON_GREEN='\033[38;5;46m'; C_NEON_YELLOW='\033[38;5;226m'
LINEA="══════════════════════════════════════════════"

if [ "$EUID" -ne 0 ]; then
    echo -e "${C_RED}[!] Ejecuta este gestor como root.${C_RST}"
    exit 1
fi

pausa() { echo ""; read -rp "Presiona Enter para continuar..." _; }

cabecera() {
    echo -e "${C_NEON_BLUE}╔${LINEA}╗${C_RST}"
    echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}$1${C_NEON_BLUE} ${C_RST}"
    echo -e "${C_NEON_BLUE}╚${LINEA}╝${C_RST}"
}

# ¿Está activo nuestro archivo swap? (el kernel lo registra con la ruta real)
swap_activo() { grep -q "^$(readlink -f "$SWAPFILE") " /proc/swaps 2>/dev/null; }

# KB que nuestro swap tiene en uso
swap_usado_kb() { awk -v f="$(readlink -f "$SWAPFILE")" '$1==f {print $4}' /proc/swaps 2>/dev/null; }

mostrar_estado() {
    local ram swap disco archivo
    ram=$(LC_ALL=C free -h | awk '/^Mem:/ {print $2" total, "$7" disponible"}')
    swap=$(LC_ALL=C free -h | awk '/^Swap:/ {print $2" total, "$3" usado"}')
    disco=$(df -Ph "$(dirname "$SWAPFILE")" | awk 'NR==2 {print $4" libres"}')
    if [ -f "$SWAPFILE" ]; then
        archivo="$(du -h "$SWAPFILE" 2>/dev/null | cut -f1) $(swap_activo && echo '(activo)' || echo '(inactivo)')"
    else
        archivo="no creado"
    fi
    echo -e "  ${C_NEON_GREEN}RAM     :${C_RST} $ram"
    echo -e "  ${C_NEON_GREEN}Swap    :${C_RST} $swap"
    echo -e "  ${C_NEON_GREEN}Disco   :${C_RST} $disco"
    echo -e "  ${C_NEON_GREEN}Archivo :${C_RST} $archivo"
}

# Quita el swap del gestor solo si hay RAM libre para absorber lo que tiene en uso
# (evita que el kernel mate procesos por falta de memoria al hacer swapoff)
liberar_swap() {
    if swap_activo; then
        local usado avail
        usado=$(swap_usado_kb); usado=${usado:-0}
        avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
        if [ "$usado" -gt $(( avail * 9 / 10 )) ]; then
            echo -e "${C_RED}[!] No hay RAM libre suficiente para desactivar el swap sin riesgo.${C_RST}"
            echo -e "    Swap en uso: $(( usado / 1024 )) MB | RAM disponible: $(( avail / 1024 )) MB"
            echo -e "    Cierra procesos o reinicia el VPS e inténtalo de nuevo."
            return 1
        fi
        swapoff "$SWAPFILE" 2>/dev/null || { echo -e "${C_RED}[!] No se pudo desactivar el swap actual.${C_RST}"; return 1; }
    fi
    rm -f "$SWAPFILE"
    return 0
}

# Crea el archivo y lo activa; si fallocate no sirve en el sistema de archivos, usa dd
crear_swap() {
    local gigas="$1" metodo
    for metodo in fallocate dd; do
        rm -f "$SWAPFILE"
        if [ "$metodo" = "fallocate" ]; then
            fallocate -l "${gigas}G" "$SWAPFILE" 2>/dev/null || continue
        else
            echo -e "${C_YELLOW}[+] Creando con dd (puede tardar unos minutos)...${C_RST}"
            dd if=/dev/zero of="$SWAPFILE" bs=1M count=$(( gigas * 1024 )) status=none 2>/dev/null || continue
        fi
        chmod 600 "$SWAPFILE"
        if mkswap "$SWAPFILE" >/dev/null 2>&1 && swapon "$SWAPFILE" 2>/dev/null; then
            return 0
        fi
    done
    rm -f "$SWAPFILE"
    return 1
}

quitar_fstab() { sed -i "\|^${SWAPFILE} |d" /etc/fstab 2>/dev/null; }

activar_swap() {
    clear
    cabecera "MEMORIA VIRTUAL - ACTIVAR / MODIFICAR"
    echo ""
    echo -n -e "${C_YELLOW}¿Cuántos GB quieres usar?${C_RST} "
    read -r gigas

    if ! [[ "$gigas" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "${C_RED}[!] Valor no válido: escribe un número entero mayor que 0.${C_RST}"
        pausa; return
    fi

    # Espacio en disco: libre actual + lo que ya ocupa el archivo (se va a reemplazar), dejando 1 GB de margen
    local libre_mb actual_mb max_gb
    libre_mb=$(df -Pm "$(dirname "$SWAPFILE")" | awk 'NR==2 {print $4}')
    actual_mb=0
    [ -f "$SWAPFILE" ] && actual_mb=$(( $(stat -c %s "$SWAPFILE") / 1048576 ))
    max_gb=$(( (libre_mb + actual_mb - 1024) / 1024 ))
    if [ "$gigas" -gt "$max_gb" ]; then
        echo -e "${C_RED}[!] Espacio insuficiente en disco.${C_RST}"
        if [ "$max_gb" -ge 1 ]; then
            echo -e "    El máximo recomendado ahora es ${C_NEON_YELLOW}${max_gb} GB${C_RST} (se deja 1 GB libre)."
        else
            echo -e "    No hay espacio libre suficiente para crear swap."
        fi
        pausa; return
    fi

    echo ""
    echo -e "${C_YELLOW}[+] Iniciando memoria virtual de ${gigas} GB...${C_RST}"
    liberar_swap || { pausa; return; }

    if ! crear_swap "$gigas"; then
        echo -e "${C_RED}[!] No se pudo crear o activar el swap en este sistema.${C_RST}"
        quitar_fstab
        pausa; return
    fi

    # Persistente tras reinicio (sin duplicar la línea en fstab)
    quitar_fstab
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
    echo "vm.swappiness=50" > "$SYSCTL_FILE"
    sysctl -q -p "$SYSCTL_FILE" >/dev/null 2>&1 || echo 50 > /proc/sys/vm/swappiness

    echo -e "${C_GREEN}[✔] Memoria virtual de ${gigas} GB activada con éxito.${C_RST}"
    pausa
}

desactivar_swap() {
    clear
    cabecera "MEMORIA VIRTUAL - DESACTIVAR"
    echo ""
    if [ ! -f "$SWAPFILE" ] && ! swap_activo; then
        echo -e "${C_YELLOW}[!] No hay swap creada por este gestor.${C_RST}"
        pausa; return
    fi

    liberar_swap || { pausa; return; }
    quitar_fstab
    rm -f "$SYSCTL_FILE"

    echo -e "${C_GREEN}[✔] Memoria virtual desactivada con éxito.${C_RST}"
    if [ "$(awk 'NR>1' /proc/swaps | wc -l)" -gt 0 ]; then
        echo -e "${C_YELLOW}[i] El sistema aún tiene otra swap propia que este gestor no modifica.${C_RST}"
    fi
    pausa
}

while true; do
    clear
    echo -e "${C_NEON_BLUE}╔${LINEA}╗${C_RST}"
    echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}      💾 ADMINISTRAR MEMORIA VIRTUAL (SWAP)   ${C_NEON_BLUE} ${C_RST}"
    echo -e "${C_NEON_BLUE}╠${LINEA}╣${C_RST}"
    mostrar_estado
    echo -e "${C_NEON_BLUE}╠${LINEA}╣${C_RST}"
    echo -e "  ${C_YELLOW}Swap amplía la RAM (recomendado en VPS con poca RAM).${C_RST}"
    echo -e "  ${C_YELLOW}Deja siempre espacio libre en disco para evitar problemas.${C_RST}"
    echo -e "${C_NEON_BLUE}╠${LINEA}╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} Activar Swap / Modificar valor de Swap"
    echo -e "  ${C_NEON_YELLOW}2.${C_RST} Desactivar Swap"
    echo -e "${C_NEON_BLUE}╠${LINEA}╣${C_RST}"
    echo -e "  ${C_RED}0.${C_RST} Regresar"
    echo -e "${C_NEON_BLUE}╚${LINEA}╝${C_RST}"
    echo -n -e "${C_YELLOW}Seleccione una opción:${C_RST} "
    read -r opcion
    case "$opcion" in
        1) activar_swap ;;
        2) desactivar_swap ;;
        0) exit 0 ;;
        *) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
    esac
done
