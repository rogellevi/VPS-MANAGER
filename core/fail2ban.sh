#!/usr/bin/env bash
#
# install-fail2ban.sh
# Instalador automático de Fail2ban para VPS (Debian/Ubuntu/RHEL/CentOS/Rocky/Alma)
# Uso: sudo bash install-fail2ban.sh
#
# Repositorio: https://github.com/TU_USUARIO/TU_REPO
# Autor: Tu Nombre
# Licencia: MIT
#

set -euo pipefail

# ============================================================
# CONFIGURACIÓN (puedes sobreescribir con variables de entorno)
# ============================================================
SSH_PORT="${SSH_PORT:-22}"
BANTIME="${BANTIME:-1h}"
FINDTIME="${FINDTIME:-10m}"
MAXRETRY="${MAXRETRY:-5}"
IGNORE_IP="${IGNORE_IP:-127.0.0.1/8 ::1}"   # Añade tu IP: IGNORE_IP="127.0.0.1/8 ::1 203.0.113.5"
ENABLE_RECIDIVE="${ENABLE_RECIDIVE:-true}"

# ============================================================
# COLORES
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

# ============================================================
# VALIDACIONES INICIALES
# ============================================================
if [[ $EUID -ne 0 ]]; then
    error "Este script debe ejecutarse como root (usa sudo)."
    exit 1
fi

if ! command -v systemctl &>/dev/null; then
    error "systemd no está disponible. Este script requiere systemd."
    exit 1
fi

# Detectar gestor de paquetes
if command -v apt-get &>/dev/null; then
    PKG_MGR="apt"
elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
else
    error "Gestor de paquetes no soportado."
    exit 1
fi

info "Gestor de paquetes detectado: $PKG_MGR"
info "Puerto SSH configurado: $SSH_PORT"

# ============================================================
# INSTALACIÓN
# ============================================================
install_fail2ban() {
    info "Actualizando índices de paquetes..."
    case "$PKG_MGR" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq fail2ban
            ;;
        dnf)
            dnf install -y -q fail2ban fail2ban-firewalld
            ;;
        yum)
            yum install -y -q epel-release || true
            yum install -y -q fail2ban
            ;;
    esac
    log "Fail2ban instalado."
}

# ============================================================
# CONFIGURACIÓN
# ============================================================
configure_fail2ban() {
    local JAIL_LOCAL="/etc/fail2ban/jail.local"

    if [[ -f "$JAIL_LOCAL" ]]; then
        local BACKUP="${JAIL_LOCAL}.bak.$(date +%s)"
        cp "$JAIL_LOCAL" "$BACKUP"
        warn "jail.local existente respaldado en: $BACKUP"
    fi

    info "Escribiendo configuración en $JAIL_LOCAL ..."
    cat > "$JAIL_LOCAL" <<EOF
#
# Configuración generada automáticamente por install-fail2ban.sh
# Fecha: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
#

[DEFAULT]
# Lista blanca de IPs que nunca serán baneadas
ignoreip = ${IGNORE_IP}

# Tiempo de bloqueo (aumenta progresivamente con recidive)
bantime  = ${BANTIME}
findtime = ${FINDTIME}
maxretry = ${MAXRETRY}

# Backend: systemd (más fiable que auto en distros modernas)
backend = systemd

# Acción por defecto (usa nftables si está disponible, si no iptables)
banaction = %(banaction_allports)s

# Notificaciones por email (opcional, descomenta si configuras MTA)
# destemail = root@localhost
# sender    = fail2ban@localhost
# action    = %(action_mwl)s

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s

# Protección agresiva contra recidivistas
[recidive]
enabled  = ${ENABLE_RECIDIVE}
logpath  = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime  = 1w
findtime = 1d
maxretry = 3
EOF

    log "Configuración aplicada."
}

# ============================================================
# SERVICIO
# ============================================================
enable_service() {
    info "Habilitando y reiniciando el servicio..."
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban
    sleep 2

    if systemctl is-active --quiet fail2ban; then
        log "Fail2ban está activo y habilitado en el arranque."
    else
        error "Fail2ban no arrancó correctamente. Revisa: journalctl -u fail2ban -n 50"
        exit 1
    fi
}

# ============================================================
# VERIFICACIÓN
# ============================================================
verify() {
    info "Estado de las jails:"
    fail2ban-client status || true
    echo
    info "Estado de la jail sshd:"
    fail2ban-client status sshd || warn "La jail sshd aún no reporta información."
    echo
    log "¡Instalación completada!"
    echo
    echo -e "${BLUE}Comandos útiles:${NC}"
    echo "  fail2ban-client status              # Ver jails"
    echo "  fail2ban-client status sshd         # Ver IPs baneadas"
    echo "  fail2ban-client set sshd unbanip X  # Desbanear IP"
    echo "  tail -f /var/log/fail2ban.log       # Ver actividad en vivo"
    echo
    warn "IMPORTANTE: Si cambiaste el puerto SSH ($SSH_PORT), verifica que coincida con tu sshd_config."
}

# ============================================================
# MAIN
# ============================================================
main() {
    echo -e "${BLUE}"
    echo "==============================================="
    echo "   Instalador automático de Fail2ban"
    echo "==============================================="
    echo -e "${NC}"

    install_fail2ban
    configure_fail2ban
    enable_service
    verify
}

main "$@"