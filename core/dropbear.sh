#!/bin/bash
# ==========================================
# DROPBEAR - VPS MANAGER V5.2
# Logica adaptada de SSHPlus (fun_drop)
# ==========================================
C_RST='\033[0m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'
C_NEON_BLUE='\033[38;5;39m'
C_NEON_GREEN='\033[38;5;46m'
C_NEON_YELLOW='\033[38;5;226m'

CONF="/etc/default/dropbear"
BANNER="/etc/dropbear/banner"

[[ "$EUID" -ne 0 ]] && { echo -e "${C_RED}[!] Ejecuta como root.${C_RST}"; sleep 2; exit 1; }

# ------------------------------------------
# FUNCIONES BASE (equivalentes a SSHPlus)
# ------------------------------------------
dp_running() {
    pgrep -x dropbear >/dev/null 2>&1 && return 0
    netstat -nltp 2>/dev/null | grep -w dropbear >/dev/null 2>&1
}

dp_ports() {
    local p1 p2
    p1=$(grep -E '^DROPBEAR_PORT=' "$CONF" 2>/dev/null | cut -d= -f2)
    p2=$(grep -E '^DROPBEAR_EXTRA_ARGS=' "$CONF" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [[ -z "$p1" ]] && p1="22"
    [[ -n "$p2" ]] && echo "$p1 $p2" || echo "$p1"
}

# Equivalente a verif_ptrs $porta
verif_ptrs() {
    local p="$1"
    [[ ! "$p" =~ ^[0-9]+$ || "$p" -lt 1 || "$p" -gt 65535 ]] && return 1
    # Ignora puertos que ya son de dropbear (para reconfigurar)
    if ss -lntp 2>/dev/null | grep -E ":$p\s" | grep -vq dropbear; then
        return 1
    fi
    return 0
}

dp_restart() {
    mkdir -p /etc/dropbear
    [[ ! -f "$BANNER" ]] && touch "$BANNER"
    sed -i 's/^NO_START=1/NO_START=0/' "$CONF"
    systemctl enable dropbear >/dev/null 2>&1
    systemctl restart dropbear >/dev/null 2>&1
    # Fallback para sistemas sin systemd activo
    if ! dp_running; then
        /etc/init.d/dropbear restart >/dev/null 2>&1
        service dropbear start >/dev/null 2>&1
    fi
}

dp_ufw() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -q "active" || return 0
    for p in "$@"; do
        ufw allow "$p/tcp" >/dev/null 2>&1
    done
}

# sshd: asegura login por clave/password y tunel (igual que SSHPlus)
dp_sshd() {
    [[ ! -f /etc/ssh/sshd_config ]] && return 0
    cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.dp 2>/dev/null
    sed -i '/^PasswordAuthentication /d' /etc/ssh/sshd_config
    sed -i '/^PermitTunnel /d' /etc/ssh/sshd_config
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
    echo "PermitTunnel yes" >> /etc/ssh/sshd_config
    if sshd -t >/dev/null 2>&1; then
        systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1
    else
        echo -e "${C_YELLOW}[!] sshd_config no validado, se mantiene sin recargar.${C_RST}"
    fi
}

# ------------------------------------------
# INSTALADOR (equivale a fun_instdrop + fun_ports)
# ------------------------------------------
inst_dropbear() {
    clear
    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}        🐻 INSTALADOR DROPBEAR - V5.2          ${C_NEON_BLUE} ${C_RST}"
    echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
    echo -e "${C_YELLOW}[!] Puerto recomendado: 22 80 81 82 85 90 110${C_RST}"
    echo -ne "${C_GREEN}¿Deseas continuar? [s/n]: ${C_RST}"
    read resp
    [[ "$resp" != @(s|S) ]] && { echo -e "${C_RED}[!] Cancelado.${C_RST}"; sleep 1; return; }

    local porta
    echo -ne "${C_GREEN}¿Qué puerto quieres usar? ${C_RST}"
    read porta
    if ! verif_ptrs "$porta"; then
        echo -e "${C_RED}[!] Puerto no valido o en uso.${C_RST}"; sleep 2; return
    fi

    # Puerto secundario (SSHPlus usa 110 por defecto)
    local porta2="110"
    echo -ne "${C_GREEN}¿Segundo puerto de escucha? [Default 110 / Enter]: ${C_RST}"
    read extra
    [[ -n "$extra" ]] && porta2="$extra"
    if [[ "$porta2" == "$porta" ]] || ! verif_ptrs "$porta2"; then
        echo -e "${C_YELLOW}[!] Segundo puerto no valido, se omite.${C_RST}"
        porta2=""
    fi

    echo -e "${C_YELLOW}[+] Instalando DROPBEAR...${C_RST}"
    apt-get update -y >/dev/null 2>&1
    grep -qs universe /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null || \
        add-apt-repository universe -y >/dev/null 2>&1
    apt-get install -y dropbear netstat-nat >/dev/null 2>&1
    apt-get install -y net-tools >/dev/null 2>&1

    if [[ ! -f "$CONF" ]]; then
        echo -e "${C_RED}[!] No se pudo instalar dropbear.${C_RST}"; sleep 2; return
    fi

    echo -e "${C_YELLOW}[+] Configurando PUERTO DROPBEAR...${C_RST}"
    sed -i 's/^NO_START=.*/NO_START=0/' "$CONF"
    sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=$porta/" "$CONF"
    sed -i '/^DROPBEAR_EXTRA_ARGS=/d' "$CONF"
    [[ -n "$porta2" ]] && echo "DROPBEAR_EXTRA_ARGS=\"-p $porta2\"" >> "$CONF"
    sed -i '/^DROPBEAR_BANNER=/d' "$CONF"
    echo "DROPBEAR_BANNER=\"$BANNER\"" >> "$CONF"
    grep -qs '^DROPBEAR_RECEIVE_WINDOW=' "$CONF" || \
        echo "DROPBEAR_RECEIVE_WINDOW=65536" >> "$CONF"

    touch "$BANNER"
    dp_sshd
    dp_restart
    dp_ufw "$porta" $porta2

    echo ""
    if dp_running; then
        echo -e "${C_GREEN}[✔] Instalacion CONCLUIDA. Puertos: $(dp_ports)${C_RST}"
    else
        echo -e "${C_RED}[!] Dropbear no inicio. Revisa: journalctl -u dropbear${C_RST}"
    fi
    sleep 3
}

# ------------------------------------------
# MODIFICAR PUERTO (equivale a resposta = '2')
# ------------------------------------------
mod_dropbear() {
    echo -e "${C_CYAN}Puertos actuales: $(dp_ports)${C_RST}"
    echo -ne "${C_GREEN}¿Qué nuevo puerto quieres usar? ${C_RST}"
    read pt
    if ! verif_ptrs "$pt"; then
        echo -e "${C_RED}[!] Puerto no valido o en uso.${C_RST}"; sleep 2; return
    fi
    local var1
    var1=$(grep '^DROPBEAR_PORT=' "$CONF" | cut -d= -f2)
    sed -i "s/\b${var1}\b/${pt}/g" "$CONF"
    dp_restart
    dp_ufw "$pt"
    echo -e "${C_GREEN}[✔] Puerto cambiado correctamente: $pt${C_RST}"
    sleep 2
}

# ------------------------------------------
# ELIMINAR (equivale a fun_dropunistall)
# ------------------------------------------
del_dropbear() {
    echo -ne "${C_YELLOW}¿Eliminar Dropbear completamente? [s/n]: ${C_RST}"
    read r
    [[ "$r" != @(s|S) ]] && return
    systemctl stop dropbear >/dev/null 2>&1
    systemctl disable dropbear >/dev/null 2>&1
    service dropbear stop >/dev/null 2>&1
    apt-get remove -y dropbear >/dev/null 2>&1
    apt-get purge -y dropbear dropbear-run >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
    rm -f "$CONF"
    echo -e "${C_GREEN}[✔] Dropbear eliminado correctamente.${C_RST}"
    sleep 2
}

# ------------------------------------------
# MENU PRINCIPAL (equivale a fun_drop)
# ------------------------------------------
while true; do
clear
echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}          🐻 ADMINISTRAR DROPBEAR             ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"

if dp_running && [[ -f "$CONF" ]]; then
    echo -e "  Estado: ${C_GREEN}🟢 ACTIVO${C_RST}"
    echo -e "  ${C_CYAN}Puertos:${C_RST} ${C_NEON_YELLOW}$(dp_ports)${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🔌 Modificar puerto Dropbear"
    echo -e "  ${C_NEON_YELLOW}2.${C_RST} 🔄 Reiniciar Dropbear"
    echo -e "  ${C_NEON_YELLOW}3.${C_RST} 🗑️ Eliminar Dropbear"
else
    echo -e "  Estado: ${C_RED}🔴 INACTIVO / NO INSTALADO${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚀 Instalar Dropbear"
fi
echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menu Anterior"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
read -p "Selecciona una opcion: " resposta

case "$resposta" in
1)
    if dp_running && [[ -f "$CONF" ]]; then mod_dropbear; else inst_dropbear; fi
    ;;
2)
    if dp_running && [[ -f "$CONF" ]]; then
        echo -e "${C_YELLOW}[+] Reiniciando Dropbear...${C_RST}"
        dp_restart
        echo -e "${C_GREEN}[✔] Reiniciado. Puertos: $(dp_ports)${C_RST}"
        sleep 2
    else
        echo -e "${C_RED}[!] Dropbear no esta activo.${C_RST}"; sleep 2
    fi
    ;;
3)
    if dp_running || [[ -f "$CONF" ]]; then del_dropbear; fi
    ;;
0) break ;;
*) echo -e "${C_RED}[!] Opcion no valida.${C_RST}"; sleep 1 ;;
esac
done
exit 0