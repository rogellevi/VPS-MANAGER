#!/bin/bash
# ==========================================
# Migración Screen → systemd
# CheckUser (Estándar + Conecta4G) + Online App
# Compatible con VPS Manager v5.x
# ==========================================

C_RST='\033[0m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'
C_NEON_BLUE='\033[38;5;39m'
C_NEON_GREEN='\033[38;5;46m'

clear
echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}   🔄 MIGRACIÓN SCREEN → SYSTEMD (v5)        ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "  Este script convertirá a systemd:"
echo -e "  • CheckUser Estándar"
echo -e "  • CheckUser Conecta4G"
echo -e "  • Online App"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
echo ""

# Asegurar directorio
mkdir -p /etc/vps-manager

# ----------------------------------------
# 1. CHECKUSER ESTÁNDAR
# ----------------------------------------
PORT_STD=""
FORMAT_STD="1"

# Buscar en /etc/autostart
if [ -f /etc/autostart ]; then
    LINE=$(grep -E "check\.py [0-9]+" /etc/autostart 2>/dev/null | head -1)
    if [ -n "$LINE" ]; then
        PORT_STD=$(echo "$LINE" | grep -oE "check\.py [0-9]+" | awk '{print $2}')
        # Formato (segundo argumento numérico)
        FMT=$(echo "$LINE" | grep -oE "check\.py [0-9]+ [0-9]+" | awk '{print $3}')
        [ -n "$FMT" ] && FORMAT_STD="$FMT"
    fi
fi

# Buscar proceso screen vivo
if [ -z "$PORT_STD" ]; then
    # Intentar extraer del proceso
    PID=$(screen -ls 2>/dev/null | grep -E "\.checkuser" | head -1 | awk '{print $1}' | cut -d. -f1)
    if [ -n "$PID" ]; then
        # Leer cmdline del proceso hijo python
        CMDLINE=$(ps -o args= -p $(pgrep -P "$PID" 2>/dev/null | head -1) 2>/dev/null)
        if [ -z "$CMDLINE" ]; then
            CMDLINE=$(ps -o args= -p "$PID" 2>/dev/null)
        fi
        PORT_STD=$(echo "$CMDLINE" | grep -oE "check\.py [0-9]+" | awk '{print $2}')
        FMT=$(echo "$CMDLINE" | grep -oE "check\.py [0-9]+ [0-9]+" | awk '{print $3}')
        [ -n "$FMT" ] && FORMAT_STD="$FMT"
    fi
fi

# Archivo de puerto ya guardado (si se usó el menú nuevo alguna vez)
[ -z "$PORT_STD" ] && [ -f /etc/vps-manager/checkuser_port ] && PORT_STD=$(cat /etc/vps-manager/checkuser_port)
[ -f /etc/vps-manager/checkuser_format ] && FORMAT_STD=$(cat /etc/vps-manager/checkuser_format)

if [ -n "$PORT_STD" ] && [ -f /etc/vps-manager/check.py ]; then
    echo -e "${C_YELLOW}[+] Detectado CheckUser Estándar → puerto $PORT_STD (formato $FORMAT_STD)${C_RST}"

    # Detener screen antiguo
    screen -S checkuser -X quit 2>/dev/null
    screen -wipe >/dev/null 2>&1
    pkill -f "python3 /etc/vps-manager/check.py" 2>/dev/null

    echo "$PORT_STD" > /etc/vps-manager/checkuser_port
    echo "$FORMAT_STD" > /etc/vps-manager/checkuser_format

    cat > /etc/systemd/system/checkuser.service << EOF
[Unit]
Description=VPS-Manager CheckUser (Estándar)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vps-manager/check.py $PORT_STD $FORMAT_STD
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable checkuser.service >/dev/null 2>&1
    systemctl restart checkuser.service

    if systemctl is-active --quiet checkuser.service; then
        echo -e "${C_GREEN}[✔] checkuser.service activo y habilitado al arranque${C_RST}"
    else
        echo -e "${C_RED}[!] Error al iniciar checkuser.service${C_RST}"
        systemctl status checkuser.service --no-pager | head -15
    fi
else
    echo -e "${C_CYAN}[-] CheckUser Estándar no detectado (o falta check.py)${C_RST}"
fi

echo ""

# ----------------------------------------
# 2. CHECKUSER CONECTA4G
# ----------------------------------------
PORT_4G=""

if [ -f /etc/autostart ]; then
    LINE=$(grep -E "4gcheck\.py [0-9]+" /etc/autostart 2>/dev/null | head -1)
    if [ -n "$LINE" ]; then
        PORT_4G=$(echo "$LINE" | grep -oE "4gcheck\.py [0-9]+" | awk '{print $2}')
    fi
fi

if [ -z "$PORT_4G" ]; then
    PID=$(screen -ls 2>/dev/null | grep -E "\.4gcheck" | head -1 | awk '{print $1}' | cut -d. -f1)
    if [ -n "$PID" ]; then
        CMDLINE=$(ps -o args= -p $(pgrep -P "$PID" 2>/dev/null | head -1) 2>/dev/null)
        [ -z "$CMDLINE" ] && CMDLINE=$(ps -o args= -p "$PID" 2>/dev/null)
        PORT_4G=$(echo "$CMDLINE" | grep -oE "4gcheck\.py [0-9]+" | awk '{print $2}')
    fi
fi

[ -z "$PORT_4G" ] && [ -f /etc/vps-manager/checkuser4g_port ] && PORT_4G=$(cat /etc/vps-manager/checkuser4g_port)

if [ -n "$PORT_4G" ] && [ -f /etc/vps-manager/4gcheck.py ]; then
    echo -e "${C_YELLOW}[+] Detectado CheckUser Conecta4G → puerto $PORT_4G${C_RST}"

    screen -S 4gcheck -X quit 2>/dev/null
    screen -wipe >/dev/null 2>&1
    pkill -f "python3 /etc/vps-manager/4gcheck.py" 2>/dev/null

    echo "$PORT_4G" > /etc/vps-manager/checkuser4g_port

    cat > /etc/systemd/system/checkuser-4g.service << EOF
[Unit]
Description=VPS-Manager CheckUser (Conecta4G)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vps-manager/4gcheck.py $PORT_4G
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable checkuser-4g.service >/dev/null 2>&1
    systemctl restart checkuser-4g.service

    if systemctl is-active --quiet checkuser-4g.service; then
        echo -e "${C_GREEN}[✔] checkuser-4g.service activo y habilitado al arranque${C_RST}"
    else
        echo -e "${C_RED}[!] Error al iniciar checkuser-4g.service${C_RST}"
        systemctl status checkuser-4g.service --no-pager | head -15
    fi
else
    echo -e "${C_CYAN}[-] CheckUser Conecta4G no detectado (o falta 4gcheck.py)${C_RST}"
fi

echo ""

# ----------------------------------------
# 3. ONLINE APP
# ----------------------------------------
ONLINE_FOUND=0

# ¿Existe el script?
if [ -f /etc/vps-manager/onlineapp.sh ]; then
    ONLINE_FOUND=1
elif [ -d /var/www/html/server ]; then
    ONLINE_FOUND=1
fi

# ¿Hay sesión screen?
if screen -ls 2>/dev/null | grep -q "onlineapp"; then
    ONLINE_FOUND=1
fi

# ¿Hay línea en autostart?
if [ -f /etc/autostart ] && grep -q "onlineapp" /etc/autostart 2>/dev/null; then
    ONLINE_FOUND=1
fi

if [ "$ONLINE_FOUND" -eq 1 ]; then
    echo -e "${C_YELLOW}[+] Detectado Online App → migrando a systemd${C_RST}"

    # Detener screen antiguo
    screen -S onlineapp -X quit 2>/dev/null
    screen -wipe >/dev/null 2>&1
    pkill -f "onlineapp.sh" 2>/dev/null

    # Asegurar script
    if [ ! -f /etc/vps-manager/onlineapp.sh ]; then
        mkdir -p /var/www/html/server
        cat > /etc/vps-manager/onlineapp.sh << 'EOF'
#!/bin/bash
OUT_DIR="/var/www/html/server"
mkdir -p "$OUT_DIR"
fun_online() {
local ssh_count=0 vpn_count=0 drp_count=0
ssh_count=$(pgrep -f "sshd:.*priv" 2>/dev/null | wc -l)
if [[ -r /etc/openvpn/openvpn-status.log ]]; then
vpn_count=$(grep -c "10.8.0" /etc/openvpn/openvpn-status.log 2>/dev/null || echo 0)
fi
if [[ -e /etc/default/dropbear ]]; then
local drp=$(pgrep -f "dropbear" 2>/dev/null | wc -l)
drp_count=$(( drp > 0 ? drp - 1 : 0 ))
fi
local online=$(( ssh_count + vpn_count + drp_count ))
printf '{"onlines":"%s","limite":"2500"}\n' "$online" > "$OUT_DIR/online_app"
printf '%s\n' "$online" > "$OUT_DIR/online"
}
while true; do
fun_online
sleep 15
done
EOF
        chmod +x /etc/vps-manager/onlineapp.sh
    fi

    # Asegurar apache escuchando 8888 (si está instalado)
    if command -v apache2 >/dev/null 2>&1; then
        if ! grep -q "Listen 8888" /etc/apache2/ports.conf 2>/dev/null; then
            sed -i "s/Listen 80/Listen 8888/g" /etc/apache2/ports.conf 2>/dev/null
            sed -i "s/<VirtualHost \*:80>/<VirtualHost *:8888>/g" /etc/apache2/sites-available/000-default.conf 2>/dev/null
            systemctl restart apache2 2>/dev/null
        fi
    fi

    cat > /etc/systemd/system/onlineapp.service << EOF
[Unit]
Description=VPS-Manager Online App (usuarios online)
After=network-online.target apache2.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash /etc/vps-manager/onlineapp.sh
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable onlineapp.service >/dev/null 2>&1
    systemctl restart onlineapp.service

    if systemctl is-active --quiet onlineapp.service; then
        echo -e "${C_GREEN}[✔] onlineapp.service activo y habilitado al arranque${C_RST}"
    else
        echo -e "${C_RED}[!] Error al iniciar onlineapp.service${C_RST}"
        systemctl status onlineapp.service --no-pager | head -15
    fi
else
    echo -e "${C_CYAN}[-] Online App no detectado${C_RST}"
fi

echo ""

# ----------------------------------------
# 4. LIMPIEZA DE /etc/autostart
# ----------------------------------------
if [ -f /etc/autostart ]; then
    echo -e "${C_YELLOW}[+] Limpiando entradas antiguas de /etc/autostart...${C_RST}"
    sed -i '/check\.py/d' /etc/autostart 2>/dev/null
    sed -i '/4gcheck\.py/d' /etc/autostart 2>/dev/null
    sed -i '/onlineapp/d' /etc/autostart 2>/dev/null
    echo -e "${C_GREEN}[✔] Limpieza completada${C_RST}"
fi

echo ""
echo -e "${C_NEON_BLUE}══════════════════════════════════════════════${C_RST}"
echo -e "${C_GREEN}  Resumen final de servicios:${C_RST}"
echo -e "${C_NEON_BLUE}══════════════════════════════════════════════${C_RST}"

for svc in checkuser checkuser-4g onlineapp; do
    if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "${svc}.service"; then
        STATUS=$(systemctl is-active "${svc}.service" 2>/dev/null || echo "inactive")
        ENABLED=$(systemctl is-enabled "${svc}.service" 2>/dev/null || echo "disabled")
        if [ "$STATUS" = "active" ]; then
            echo -e "  ${C_GREEN}✔ ${svc}.service${C_RST}  →  $STATUS / $ENABLED"
        else
            echo -e "  ${C_RED}✘ ${svc}.service${C_RST}  →  $STATUS / $ENABLED"
        fi
    fi
done

echo ""
echo -e "${C_CYAN}Comandos útiles:${C_RST}"
echo -e "  systemctl status checkuser.service"
echo -e "  systemctl status checkuser-4g.service"
echo -e "  systemctl status onlineapp.service"
echo -e "  journalctl -u checkuser.service -f"
echo ""
echo -e "${C_GREEN}[✔] Migración finalizada. Los servicios se reiniciarán solos al arrancar el VPS.${C_RST}"
echo ""
