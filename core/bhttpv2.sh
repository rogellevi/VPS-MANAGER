#!/usr/bin/env bash
set -Euo pipefail

MANAGER_VERSION="2.5.4"
ENGINE_VERSION="2.4.1-btun-compat-keepalive"
TITLE="SUPERFLASH BHTTP - NEW GOLDEN"
DEFAULT_REPO="apksdemons/BHTTP"
DEFAULT_BRANCH="main"
REPO="${SUPERFLASH_BHTTP_REPO:-$DEFAULT_REPO}"
BRANCH="${SUPERFLASH_BHTTP_BRANCH:-$DEFAULT_BRANCH}"

SERVICE="superflash-bhttp.service"
BIN="/usr/local/bin/superflash-bhttp-server"
MANAGER_BIN="/usr/local/sbin/superflash-bhttp-manager"
MENU_BIN="/usr/local/bin/bhttp"
BASE="/etc/superflash-bhttp"
CONFIG="$BASE/config"
LEGACY_CONFIG="/etc/superflash-bhttp.conf"
UNIT="/etc/systemd/system/$SERVICE"
SYSCTL_FILE="/etc/sysctl.d/99-superflash-bhttp-performance.conf"
BACKUP_DIR="/var/backups/superflash-bhttp-new-golden"
EXTRA_UNIT_PREFIX="/etc/systemd/system/superflash-bhttp-port"

AMD64_FILE="superflash-bhttp-server-v2.4.1-btun-compat-keepalive-linux-amd64"
ARM64_FILE="superflash-bhttp-server-v2.4.1-btun-compat-keepalive-linux-arm64"
AMD64_SHA="6c539261249d79dd49f3ef0564bfd08f4c9bfcef7086eea36d645e027200e039"
ARM64_SHA="6154c82038496e56973064cd5166642de17313b7f11217991bef9f8805c85b5f"

red='\033[1;31m'; green='\033[1;32m'; cyan='\033[1;36m'; yellow='\033[1;33m'; blue='\033[1;34m'; dim='\033[2m'; reset='\033[0m'

ok(){ printf '%b✔%b %s\n' "$green" "$reset" "$*"; }
info(){ printf '%bℹ%b %s\n' "$cyan" "$reset" "$*"; }
warn(){ printf '%b⚠%b %s\n' "$yellow" "$reset" "$*"; }
fail(){ printf '%b✘%b %s\n' "$red" "$reset" "$*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { fail "Ejecuta como root/sudo."; exit 1; }; }
interactive_tty_ready(){ [ -c /dev/tty ] && { : </dev/tty; } 2>/dev/null; }
require_tty(){ interactive_tty_ready || { fail "Esta acción necesita una terminal interactiva (/dev/tty)."; return 1; }; }
prompt_read(){ local __v="$1" __p="$2"; require_tty || return 1; IFS= read -r -p "$__p" "$__v" </dev/tty; }
pause(){ echo; prompt_read _ "Presiona ENTER para continuar..." || true; }
valid_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_uint(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ]; }
normalize_ports(){
  local raw="${1:-}" p out=""
  raw="${raw//,/ }"
  for p in $raw; do
    valid_port "$p" || continue
    case " $out " in *" $p "*) ;; *) out="${out:+$out }$p";; esac
  done
  printf '%s' "$out"
}
list_has_port(){ case " ${1:-} " in *" $2 "*) return 0;; *) return 1;; esac; }
list_add_port(){
  local list; list="$(normalize_ports "${1:-}")"
  if list_has_port "$list" "$2"; then printf '%s' "$list"; else printf '%s' "${list:+$list }$2"; fi
}
list_remove_port(){
  local list p out=""; list="$(normalize_ports "${1:-}")"
  for p in $list; do [ "$p" = "$2" ] || out="${out:+$out }$p"; done
  printf '%s' "$out"
}
extra_unit_path(){ printf '%s-%s.service' "$EXTRA_UNIT_PREFIX" "$1"; }

raw_url(){ printf 'https://raw.githubusercontent.com/%s/%s/%s' "$REPO" "$BRANCH" "$1"; }
arch_name(){ case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; *) echo unsupported;; esac; }
engine_filename(){ case "$(arch_name)" in amd64) echo "$AMD64_FILE";; arm64) echo "$ARM64_FILE";; *) echo "";; esac; }
expected_sha(){ case "$(arch_name)" in amd64) echo "$AMD64_SHA";; arm64) echo "$ARM64_SHA";; *) echo "";; esac; }

mem_mb(){ awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024; }
adaptive_sessions(){
  local m; m="$(mem_mb)"
  if [ "$m" -lt 768 ]; then echo 512
  elif [ "$m" -lt 1536 ]; then echo 1024
  elif [ "$m" -lt 3072 ]; then echo 2048
  elif [ "$m" -lt 6144 ]; then echo 4096
  else echo 8192
  fi
}

load_config(){
  BHTTP_PORT=""; BACKEND_PORT=22; SESSION_TTL=180; MAX_SESSIONS="$(adaptive_sessions)"; PROFILE="performance"
  UFW_RULE_ADDED=0; UFW_RULE_PORT=""; FIREWALLD_RULE_ADDED=0; FIREWALLD_RULE_PORT=""
  EXTRA_PORTS=""; EXTRA_UFW_PORTS=""; EXTRA_FIREWALLD_PORTS=""
  if [ -r "$LEGACY_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$LEGACY_CONFIG" 2>/dev/null || true
  fi
  if [ -r "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG" 2>/dev/null || true
  fi
  if [ -n "${BHTTP_PORT:-}" ]; then valid_port "$BHTTP_PORT" || BHTTP_PORT=""; fi
  valid_port "${BACKEND_PORT:-}" || BACKEND_PORT=22
  valid_uint "${SESSION_TTL:-}" || SESSION_TTL=180
  valid_uint "${MAX_SESSIONS:-}" || MAX_SESSIONS="$(adaptive_sessions)"
  EXTRA_PORTS="$(normalize_ports "${EXTRA_PORTS:-}")"
  EXTRA_UFW_PORTS="$(normalize_ports "${EXTRA_UFW_PORTS:-}")"
  EXTRA_FIREWALLD_PORTS="$(normalize_ports "${EXTRA_FIREWALLD_PORTS:-}")"
  # Si venimos de la instalación antigua con su default 1024 y la VPS admite más,
  # elevamos solo el techo; no cambia el protocolo ni crea sesiones por sí mismo.
  local auto; auto="$(adaptive_sessions)"
  if [ "$MAX_SESSIONS" -eq 1024 ] && [ "$auto" -gt 1024 ]; then MAX_SESSIONS="$auto"; fi
}

save_config(){
  mkdir -p "$BASE"
  cat > "$CONFIG" <<EOF
BHTTP_PORT=$BHTTP_PORT
BACKEND_PORT=$BACKEND_PORT
SESSION_TTL=$SESSION_TTL
MAX_SESSIONS=$MAX_SESSIONS
PROFILE=$PROFILE
UFW_RULE_ADDED=$UFW_RULE_ADDED
UFW_RULE_PORT=${UFW_RULE_PORT:-}
FIREWALLD_RULE_ADDED=$FIREWALLD_RULE_ADDED
FIREWALLD_RULE_PORT=${FIREWALLD_RULE_PORT:-}
EXTRA_PORTS="${EXTRA_PORTS:-}"
EXTRA_UFW_PORTS="${EXTRA_UFW_PORTS:-}"
EXTRA_FIREWALLD_PORTS="${EXTRA_FIREWALLD_PORTS:-}"
EOF
  chmod 600 "$CONFIG"
  cat > "$LEGACY_CONFIG" <<EOF
BHTTP_PORT=$BHTTP_PORT
BACKEND_PORT=$BACKEND_PORT
SESSION_TTL=$SESSION_TTL
MAX_SESSIONS=$MAX_SESSIONS
EOF
  chmod 600 "$LEGACY_CONFIG"
}

pkg_install_fast(){
  local pkgs=("$@")
  if have apt-get; then
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}" >/dev/null 2>&1; then return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}" >/dev/null
  elif have dnf; then dnf install -y "${pkgs[@]}" >/dev/null
  elif have yum; then yum install -y "${pkgs[@]}" >/dev/null
  else fail "No se detectó apt, dnf ni yum."; return 1
  fi
}

ensure_deps(){
  local missing=0 c
  for c in curl sha256sum systemctl ss sysctl awk grep sed; do have "$c" || missing=1; done
  [ "$missing" -eq 0 ] && return 0
  info "Instalando dependencias mínimas faltantes..."
  if have apt-get; then pkg_install_fast ca-certificates curl coreutils iproute2 procps gawk grep sed
  else pkg_install_fast ca-certificates curl coreutils iproute procps-ng gawk grep sed
  fi
}

backup_current(){
  mkdir -p "$BACKUP_DIR"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  [ -x "$BIN" ] && cp -a "$BIN" "$BACKUP_DIR/engine-$stamp" || true
  [ -f "$UNIT" ] && cp -a "$UNIT" "$BACKUP_DIR/unit-$stamp" || true
  [ -f "$CONFIG" ] && cp -a "$CONFIG" "$BACKUP_DIR/config-$stamp" || true
  [ -f "$SYSCTL_FILE" ] && cp -a "$SYSCTL_FILE" "$BACKUP_DIR/sysctl-$stamp" || true
  # Mantener un rollback simple al último motor conocido.
  if [ -x "$BIN" ]; then cp -a "$BIN" "$BACKUP_DIR/engine.previous"; fi
}

download_engine(){
  local file exp tmp got
  file="$(engine_filename)"; exp="$(expected_sha)"
  [ -n "$file" ] && [ -n "$exp" ] || { fail "Arquitectura no soportada: $(uname -m). Solo amd64/arm64."; return 1; }
  tmp="$(mktemp /tmp/superflash-bhttp-engine.XXXXXX)"
  info "Descargando motor BHTTP exacto para $(arch_name)..."
  curl -fL --retry 3 --connect-timeout 12 "$(raw_url "$file")" -o "$tmp"
  got="$(sha256sum "$tmp" | awk '{print $1}')"
  [ "$got" = "$exp" ] || { rm -f "$tmp"; fail "SHA-256 incorrecto del motor descargado."; return 1; }
  chmod 755 "$tmp"
  "$tmp" --self-test >/dev/null
  install -m 755 "$tmp" "$BIN"
  rm -f "$tmp"
  ok "Motor $ENGINE_VERSION verificado por SHA-256 y self-test."
}

install_manager_copy(){
  local src tmp src_real manager_real
  mkdir -p "$(dirname "$MANAGER_BIN")" "$(dirname "$MENU_BIN")"
  src="${BASH_SOURCE[0]:-}"
  src_real="$(readlink -f "$src" 2>/dev/null || true)"
  manager_real="$(readlink -f "$MANAGER_BIN" 2>/dev/null || echo "$MANAGER_BIN")"
  if [ -n "$src" ] && [ -f "$src" ] && [[ "$src" != /dev/fd/* ]] && [[ "$src" != /proc/*/fd/* ]] && [ "$src_real" != "$manager_real" ]; then
    install -m 755 "$src" "$MANAGER_BIN"
  else
    tmp="$(mktemp /tmp/superflash-bhttp-manager.XXXXXX)"
    curl -fL --retry 3 --connect-timeout 12 "$(raw_url install.sh)" -o "$tmp"
    bash -n "$tmp"
    install -m 755 "$tmp" "$MANAGER_BIN"
    rm -f "$tmp"
  fi
  ln -sfn "$MANAGER_BIN" "$MENU_BIN"
}

sysctl_supported(){ sysctl -N "$1" >/dev/null 2>&1; }
append_sysctl(){ local key="$1" val="$2"; sysctl_supported "$key" && printf '%s = %s\n' "$key" "$val" >> "$SYSCTL_FILE"; }

apply_performance_tuning(){
  need_root
  info "Aplicando perfil BHTTP HIGH PERFORMANCE + STABILITY..."
  mkdir -p /etc/sysctl.d
  cat > "$SYSCTL_FILE" <<'EOF'
# SuperFlash BHTTP NEW GOLDEN - ajustes reversibles creados por el manager.
# No cambia BHP1 ni SSH; optimiza colas, buffers, puertos efímeros y estabilidad TCP.
EOF
  append_sysctl fs.file-max 1048576
  append_sysctl net.core.somaxconn 16384
  append_sysctl net.core.netdev_max_backlog 16384
  append_sysctl net.core.rmem_max 16777216
  append_sysctl net.core.wmem_max 16777216
  append_sysctl net.ipv4.tcp_rmem "4096 131072 16777216"
  append_sysctl net.ipv4.tcp_wmem "4096 131072 16777216"
  append_sysctl net.ipv4.ip_local_port_range "10240 65535"
  append_sysctl net.ipv4.tcp_max_syn_backlog 16384
  append_sysctl net.ipv4.tcp_max_tw_buckets 262144
  append_sysctl net.ipv4.tcp_fin_timeout 15
  append_sysctl net.ipv4.tcp_tw_reuse 1
  append_sysctl net.ipv4.tcp_slow_start_after_idle 0
  append_sysctl net.ipv4.tcp_fastopen 3
  append_sysctl net.ipv4.tcp_keepalive_time 60
  append_sysctl net.ipv4.tcp_keepalive_intvl 15
  append_sysctl net.ipv4.tcp_keepalive_probes 4
  append_sysctl net.ipv4.tcp_mtu_probing 1

  # fq + BBR solo si el kernel los soporta. Nunca se fuerza un algoritmo inexistente.
  if have modprobe; then modprobe tcp_bbr >/dev/null 2>&1 || true; fi
  if sysctl_supported net.core.default_qdisc; then append_sysctl net.core.default_qdisc fq; fi
  if sysctl_supported net.ipv4.tcp_available_congestion_control && \
     sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    append_sysctl net.ipv4.tcp_congestion_control bbr
  fi
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
  ok "Perfil de red aplicado. BHP1 permanece byte/protocolo compatible con BTUN."
}

remove_performance_tuning(){
  rm -f "$SYSCTL_FILE"
  # No intentamos adivinar/restaurar valores globales previos; al borrar nuestro archivo,
  # el siguiente boot usa el resto de la configuración del sistema.
  ok "Archivo de tuning BHTTP eliminado."
}

write_unit(){
  load_config; save_config
  if [ -z "${BHTTP_PORT:-}" ]; then
    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    rm -f "$UNIT"
    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
  fi
  cat > "$UNIT" <<EOF
[Unit]
Description=SuperFlash BHTTP NEW GOLDEN - engine $ENGINE_VERSION
After=network-online.target ssh.service sshd.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
EnvironmentFile=-$CONFIG
ExecStart=$BIN --listen 0.0.0.0 --port \${BHTTP_PORT} --backend-host 127.0.0.1 --backend-port \${BACKEND_PORT} --session-ttl \${SESSION_TTL} --max-sessions \${MAX_SESSIONS} --request-timeout 30 --read-wait-ms 2 --sequence-wait 6 --max-requests-per-conn 2048
Restart=always
RestartSec=1
TimeoutStopSec=15
KillSignal=SIGTERM
LimitNOFILE=524288
LimitNPROC=131072
TasksMax=infinity
OOMScoreAdjust=-300

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
}

write_extra_unit(){
  local p="$1" unit
  unit="$(extra_unit_path "$p")"
  cat > "$unit" <<EOF
[Unit]
Description=SuperFlash BHTTP NEW GOLDEN extra port $p - engine $ENGINE_VERSION
After=network-online.target ssh.service sshd.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
EnvironmentFile=-$CONFIG
ExecStart=$BIN --listen 0.0.0.0 --port $p --backend-host 127.0.0.1 --backend-port \${BACKEND_PORT} --session-ttl \${SESSION_TTL} --max-sessions \${MAX_SESSIONS} --request-timeout 30 --read-wait-ms 2 --sequence-wait 6 --max-requests-per-conn 2048
Restart=always
RestartSec=1
TimeoutStopSec=15
KillSignal=SIGTERM
LimitNOFILE=524288
LimitNPROC=131072
TasksMax=infinity
OOMScoreAdjust=-300

[Install]
WantedBy=multi-user.target
EOF
}

stop_extra_services(){
  local p
  for p in ${EXTRA_PORTS:-}; do systemctl stop "$(basename "$(extra_unit_path "$p")")" >/dev/null 2>&1 || true; done
}

sync_extra_units(){
  local p unit
  EXTRA_PORTS="$(normalize_ports "${EXTRA_PORTS:-}")"
  for p in $EXTRA_PORTS; do
    [ "$p" = "$BHTTP_PORT" ] && continue
    write_extra_unit "$p"
  done
  systemctl daemon-reload
  for p in $EXTRA_PORTS; do
    [ "$p" = "$BHTTP_PORT" ] && continue
    unit="$(basename "$(extra_unit_path "$p")")"
    systemctl enable "$unit" >/dev/null 2>&1 || true
    systemctl restart "$unit"
    firewall_open_port "$p" extra
  done
}

remove_orphan_extra_units(){
  local f p unit
  for f in ${EXTRA_UNIT_PREFIX}-*.service; do
    [ -e "$f" ] || continue
    p="${f#${EXTRA_UNIT_PREFIX}-}"; p="${p%.service}"
    if ! list_has_port "${EXTRA_PORTS:-}" "$p"; then
      unit="$(basename "$f")"
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
      rm -f "$f"
    fi
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
}

port_owner(){
  local p="$1"
  ss -lntp 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {print; found=1} END{if(!found) exit 1}' || true
}
port_busy_by_other(){
  local p="$1"
  if ! ss -lntp 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {found=1} END{exit !found}'; then return 1; fi
  if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then return 1; fi
  return 0
}

firewall_open_port(){
  local p="$1" kind="${2:-extra}"
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ! ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${p}/tcp([[:space:]]|$)"; then
      ufw allow "${p}/tcp" comment 'SuperFlash BHTTP' >/dev/null
      if [ "$kind" = "main" ]; then
        UFW_RULE_ADDED=1; UFW_RULE_PORT="$p"
      else
        EXTRA_UFW_PORTS="$(list_add_port "${EXTRA_UFW_PORTS:-}" "$p")"
      fi
      save_config
      ok "UFW: puerto $p/tcp abierto por este manager."
    else info "UFW: el puerto $p/tcp ya estaba permitido."; fi
  elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    if ! firewall-cmd --query-port="${p}/tcp" >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null
      firewall-cmd --reload >/dev/null
      if [ "$kind" = "main" ]; then
        FIREWALLD_RULE_ADDED=1; FIREWALLD_RULE_PORT="$p"
      else
        EXTRA_FIREWALLD_PORTS="$(list_add_port "${EXTRA_FIREWALLD_PORTS:-}" "$p")"
      fi
      save_config
      ok "firewalld: puerto $p/tcp abierto por este manager."
    else info "firewalld: el puerto $p/tcp ya estaba permitido."; fi
  else
    info "Firewall local no activo/detectado. Si tu proveedor usa firewall externo, permite TCP $p."
  fi
}

firewall_open(){
  load_config
  if [ -z "${BHTTP_PORT:-}" ]; then
    info "No hay puerto BHTTP principal configurado. Usa la opción 16 para abrir el puerto que quieras."
    return 0
  fi
  firewall_open_port "$BHTTP_PORT" main
}

firewall_remove_main_tracked(){
  if [ "${UFW_RULE_ADDED:-0}" = "1" ] && [ -n "${UFW_RULE_PORT:-}" ] && have ufw; then
    ufw delete allow "${UFW_RULE_PORT}/tcp" >/dev/null 2>&1 || true
    UFW_RULE_ADDED=0; UFW_RULE_PORT=""
  fi
  if [ "${FIREWALLD_RULE_ADDED:-0}" = "1" ] && [ -n "${FIREWALLD_RULE_PORT:-}" ] && have firewall-cmd; then
    firewall-cmd --permanent --remove-port="${FIREWALLD_RULE_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    FIREWALLD_RULE_ADDED=0; FIREWALLD_RULE_PORT=""
  fi
  save_config
}

firewall_remove_extra_tracked(){
  local p="$1"
  if list_has_port "${EXTRA_UFW_PORTS:-}" "$p" && have ufw; then
    ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
    EXTRA_UFW_PORTS="$(list_remove_port "$EXTRA_UFW_PORTS" "$p")"
  fi
  if list_has_port "${EXTRA_FIREWALLD_PORTS:-}" "$p" && have firewall-cmd; then
    firewall-cmd --permanent --remove-port="${p}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    EXTRA_FIREWALLD_PORTS="$(list_remove_port "$EXTRA_FIREWALLD_PORTS" "$p")"
  fi
  save_config
}

firewall_remove_all_tracked(){
  load_config
  firewall_remove_main_tracked
  local p
  for p in $(normalize_ports "${EXTRA_UFW_PORTS:-} ${EXTRA_FIREWALLD_PORTS:-}"); do
    firewall_remove_extra_tracked "$p"
  done
}

ssh_backend_ready(){ ss -lnt 2>/dev/null | awk -v p=":$BACKEND_PORT" '$4 ~ p"$" {f=1} END{exit !f}'; }

engine_hash(){ [ -x "$BIN" ] && sha256sum "$BIN" 2>/dev/null | awk '{print $1}' || true; }
engine_exact(){ [ "$(engine_hash)" = "$(expected_sha)" ]; }
service_state(){ systemctl is-active "$SERVICE" 2>/dev/null || true; }
boot_state(){ systemctl is-enabled "$SERVICE" 2>/dev/null || true; }
listener_up(){
  load_config
  [ -n "${BHTTP_PORT:-}" ] || return 1
  ss -lnt 2>/dev/null | awk -v p=":$BHTTP_PORT" '$4 ~ p"$" {f=1} END{exit !f}'
}
connected_tcp(){
  load_config
  [ -n "${BHTTP_PORT:-}" ] || { echo 0; return 0; }
  ss -Htan 2>/dev/null | awk -v p=":$BHTTP_PORT" '$1=="ESTAB" && $4 ~ p"$" {n++} END{print n+0}'
}
connected_tcp_all(){
  load_config
  local ports="$(normalize_ports "${BHTTP_PORT:-} ${EXTRA_PORTS:-}")"
  [ -n "$ports" ] || { echo 0; return 0; }
  ss -Htan 2>/dev/null | awk -v ps="$ports" '
    BEGIN{n=split(ps,a," ")} $1=="ESTAB" {for(i=1;i<=n;i++) if(a[i]!="" && $4 ~ (":" a[i] "$") ){c++; break}} END{print c+0}'
}
managed_ports_text(){
  load_config
  local ports; ports="$(normalize_ports "${BHTTP_PORT:-} ${EXTRA_PORTS:-}")"
  [ -n "$ports" ] && printf '%s' "$ports" || printf 'ninguno'
}
any_listener_active(){
  load_config
  if [ -n "${BHTTP_PORT:-}" ] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then return 0; fi
  local p
  for p in ${EXTRA_PORTS:-}; do systemctl is-active --quiet "$(basename "$(extra_unit_path "$p")")" 2>/dev/null && return 0; done
  return 1
}
any_listener_enabled(){
  load_config
  if [ -n "${BHTTP_PORT:-}" ] && systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then return 0; fi
  local p
  for p in ${EXTRA_PORTS:-}; do systemctl is-enabled --quiet "$(basename "$(extra_unit_path "$p")")" 2>/dev/null && return 0; done
  return 1
}

status_compact(){
  load_config
  local installed="NO" active="SIN PUERTOS" boot="SIN PUERTOS" exact="NO" tune="OFF" ports
  [ -x "$BIN" ] && installed="SÍ"
  ports="$(managed_ports_text)"
  if [ "$ports" != "ninguno" ]; then
    any_listener_active && active="ACTIVO" || active="APAGADO"
    any_listener_enabled && boot="SÍ" || boot="NO"
  fi
  engine_exact && exact="SÍ"
  [ -f "$SYSCTL_FILE" ] && tune="HIGH PERFORMANCE"
  printf 'Instalado: %s | Listeners: %s | Boot: %s | Motor exacto: %s
' "$installed" "$active" "$boot" "$exact"
  printf 'Puertos BHTTP: %s -> SSH 127.0.0.1:%s | Max sesiones: %s | Perfil: %s
' "$ports" "$BACKEND_PORT" "$MAX_SESSIONS" "$tune"
}

status_all(){
  need_root; load_config
  echo "============================================================"
  echo " $TITLE"
  echo "============================================================"
  echo "Manager        : v$MANAGER_VERSION"
  echo "Engine         : $ENGINE_VERSION"
  echo "Arquitectura   : $(uname -m)"
  echo "RAM            : $(mem_mb) MB"
  echo "Motor SHA      : $(engine_hash)"
  echo "Motor exacto   : $(engine_exact && echo SÍ || echo NO)"
  echo "Listeners      : $(any_listener_active && echo ACTIVO || echo APAGADO/SIN PUERTOS)"
  echo "Inicio al boot : $(any_listener_enabled && echo SÍ || echo NO/SIN PUERTOS)"
  echo "Puertos BHTTP  : $(managed_ports_text) -> SSH 127.0.0.1:$BACKEND_PORT"
  echo "Max sesiones   : $MAX_SESSIONS"
  echo "TCP ESTAB ahora: $(connected_tcp_all) (suma de puertos BHTTP gestionados; no equivale exactamente a usuarios)"
  echo "Tuning         : $([ -f "$SYSCTL_FILE" ] && echo 'HIGH PERFORMANCE + STABILITY' || echo 'OFF')"
  if sysctl_supported net.ipv4.tcp_congestion_control; then echo "Congestión TCP : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"; fi
  echo
  local ep allp; allp="$(normalize_ports "${BHTTP_PORT:-} ${EXTRA_PORTS:-}")"
  if [ -n "$allp" ]; then
    echo "Listeners BHTTP gestionados:"
    for ep in $allp; do port_owner "$ep"; done
  else
    echo "Listeners BHTTP gestionados: ninguno (abre los que quieras desde el menú)."
  fi
  echo "SSH local:"; port_owner "$BACKEND_PORT"
  echo
  if [ -n "${BHTTP_PORT:-}" ]; then systemctl --no-pager --full status "$SERVICE" 2>/dev/null | sed -n '1,18p' || true; fi
}

self_test(){
  need_root; load_config
  echo "===== AUTOPRUEBA BHTTP NEW GOLDEN ====="
  [ -x "$BIN" ] || { fail "Motor no instalado."; return 1; }
  engine_exact || { fail "El SHA-256 del motor no coincide con $ENGINE_VERSION."; return 1; }
  "$BIN" --self-test
  ssh_backend_ready || { fail "SSH backend no escucha en :$BACKEND_PORT."; return 1; }
  ok "Motor/BHP1 original PASS"
  ok "SSH backend 127.0.0.1:$BACKEND_PORT PASS"
  local allp ep eu; allp="$(normalize_ports "${BHTTP_PORT:-} ${EXTRA_PORTS:-}")"
  if [ -z "$allp" ]; then
    info "No hay puertos BHTTP abiertos por el manager. Esto es correcto en una VPS nueva."
    info "Usa la opción 16 para abrir únicamente los puertos que tú quieras."
    return 0
  fi
  if [ -n "${BHTTP_PORT:-}" ]; then
    systemctl is-enabled --quiet "$SERVICE" || { fail "Listener :$BHTTP_PORT no está habilitado para boot."; return 1; }
    systemctl is-active --quiet "$SERVICE" || { fail "Listener :$BHTTP_PORT no está activo."; return 1; }
    listener_up || { fail "No escucha en :$BHTTP_PORT."; return 1; }
    ok "Listener :$BHTTP_PORT + autostart PASS"
  fi
  for ep in ${EXTRA_PORTS:-}; do
    eu="$(basename "$(extra_unit_path "$ep")")"
    systemctl is-enabled --quiet "$eu" || { fail "Puerto :$ep no está habilitado para boot."; return 1; }
    systemctl is-active --quiet "$eu" || { fail "Puerto :$ep no está activo."; return 1; }
    ss -lnt 2>/dev/null | awk -v p=":$ep" '$4 ~ p"$" {f=1} END{exit !f}' || { fail "Puerto :$ep no está escuchando."; return 1; }
    ok "Listener :$ep + autostart PASS"
  done
  echo "BTUN/SuperFlash: usa cualquiera de los puertos mostrados arriba | DNS 1.1.1.1 | Upload 16 | Download 32"
}

install_or_update(){
  need_root; ensure_deps
  [ "$(arch_name)" != unsupported ] || { fail "Arquitectura no soportada."; return 1; }
  local had_existing=0
  if [ -r "$CONFIG" ] || [ -r "$LEGACY_CONFIG" ] || [ -f "$UNIT" ]; then had_existing=1; fi
  load_config
  local auto; auto="$(adaptive_sessions)"
  if [ "$auto" -gt "$MAX_SESSIONS" ]; then MAX_SESSIONS="$auto"; fi
  info "Instalación/actualización segura: motor BHP1 NO cambia; solo capacidad, boot, menú y tuning."
  if [ "$had_existing" -eq 0 ] && [ -z "${BHTTP_PORT:-}" ] && [ -z "${EXTRA_PORTS:-}" ]; then
    info "VPS nueva: NO se abrirá ningún puerto BHTTP automáticamente."
    info "Después entra a 'sudo bhttp' y usa la opción 16 para abrir los puertos que tú quieras."
  else
    info "Puertos BHTTP existentes conservados: $(managed_ports_text) | SSH: $BACKEND_PORT"
  fi
  backup_current
  [ -n "${BHTTP_PORT:-}" ] && systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  stop_extra_services
  if [ -n "${BHTTP_PORT:-}" ] && port_busy_by_other "$BHTTP_PORT"; then
    fail "El puerto $BHTTP_PORT está ocupado por otro servicio. No se detuvo ni modificó ese servicio."
    port_owner "$BHTTP_PORT"
    return 1
  fi
  download_engine
  save_config
  write_unit
  apply_performance_tuning
  install_manager_copy
  if [ -n "${BHTTP_PORT:-}" ]; then firewall_open; fi
  remove_orphan_extra_units
  sync_extra_units
  if [ -n "${BHTTP_PORT:-}" ]; then
    systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE"
  fi
  sleep .5
  if [ -n "${BHTTP_PORT:-}" ] && { ! systemctl is-active --quiet "$SERVICE" || ! listener_up; }; then
    fail "BHTTP no quedó activo; revisa logs con: sudo bhttp"
    return 1
  fi
  ok "Motor BHTTP instalado/actualizado."
  ok "Perfil HIGH PERFORMANCE + STABILITY activo."
  ok "Menú instalado: sudo bhttp"
  if [ "$(managed_ports_text)" = "ninguno" ]; then
    ok "Ningún puerto BHTTP fue abierto automáticamente."
    info "Abre solamente los que quieras con la opción 16."
  else
    ok "Puertos existentes conservados y habilitados para reinicios: $(managed_ports_text)"
  fi
  echo
  self_test
}

set_bhttp_port(){
  load_config; local old="${BHTTP_PORT:-}" p
  if [ -z "$old" ]; then
    info "No hay puerto principal configurado todavía. Usa la opción 16 para abrir el primer puerto BHTTP."
    return 0
  fi
  prompt_read p "Nuevo puerto externo BHTTP [$BHTTP_PORT]: "; p="${p:-$BHTTP_PORT}"
  valid_port "$p" || { fail "Puerto inválido."; return 1; }
  [ "$p" = "$BHTTP_PORT" ] && return 0
  if list_has_port "${EXTRA_PORTS:-}" "$p"; then fail "El puerto $p ya está configurado como BHTTP adicional."; return 1; fi
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  if ss -lntp 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {f=1} END{exit !f}'; then
    fail "El puerto $p está ocupado."; systemctl start "$SERVICE" >/dev/null 2>&1 || true; return 1
  fi
  firewall_remove_main_tracked
  BHTTP_PORT="$p"; save_config; write_unit; firewall_open
  systemctl restart "$SERVICE"
  ok "Puerto BHTTP cambiado: $old -> $BHTTP_PORT"
}

add_extra_port(){
  load_config; local p unit
  echo "Puertos BHTTP actuales: $(managed_ports_text)"
  prompt_read p "Nuevo puerto BHTTP que quieres ABRIR: "
  valid_port "$p" || { fail "Puerto inválido."; return 1; }
  if [ -n "${BHTTP_PORT:-}" ] && [ "$p" = "$BHTTP_PORT" ]; then info "El puerto $p ya está abierto por BHTTP."; return 0; fi
  if list_has_port "${EXTRA_PORTS:-}" "$p"; then info "El puerto $p ya está abierto por BHTTP."; return 0; fi
  if ss -lntp 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {f=1} END{exit !f}'; then
    fail "El puerto $p ya está ocupado por otro listener. No se modificó nada."
    port_owner "$p"
    return 1
  fi
  if [ -z "${BHTTP_PORT:-}" ]; then
    BHTTP_PORT="$p"
    save_config
    write_unit
    systemctl enable --now "$SERVICE" >/dev/null
    firewall_open_port "$p" main
    sleep .5
    if ss -lnt 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {f=1} END{exit !f}'; then
      ok "Primer puerto BHTTP :$p abierto y habilitado para reinicios."
    else
      fail "El listener :$p no quedó activo; revisa: journalctl -u $SERVICE"
      return 1
    fi
  else
    EXTRA_PORTS="$(list_add_port "${EXTRA_PORTS:-}" "$p")"
    save_config
    write_extra_unit "$p"
    systemctl daemon-reload
    unit="$(basename "$(extra_unit_path "$p")")"
    systemctl enable --now "$unit" >/dev/null
    firewall_open_port "$p" extra
    sleep .5
    if ss -lnt 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {f=1} END{exit !f}'; then
      ok "Puerto BHTTP :$p abierto y habilitado para reinicios."
    else
      fail "El listener :$p no quedó activo; revisa logs: journalctl -u $unit"
      return 1
    fi
  fi
  info "Puertos BHTTP ahora: $(managed_ports_text)"
}

close_extra_port(){
  load_config; local p unit
  local allp; allp="$(normalize_ports "${BHTTP_PORT:-} ${EXTRA_PORTS:-}")"
  [ -n "$allp" ] || { info "No hay puertos BHTTP abiertos por el manager."; return 0; }
  echo "Puertos BHTTP actuales: $allp"
  prompt_read p "Puerto BHTTP que quieres CERRAR/ELIMINAR: "
  valid_port "$p" || { fail "Puerto inválido."; return 1; }
  list_has_port "$allp" "$p" || { fail "El puerto $p no está registrado como BHTTP."; return 1; }
  prompt_read c "Escribe CERRAR para confirmar el puerto $p: "
  [ "$c" = "CERRAR" ] || { info "Sin cambios."; return 0; }
  if [ -n "${BHTTP_PORT:-}" ] && [ "$p" = "$BHTTP_PORT" ]; then
    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    rm -f "$UNIT"
    firewall_remove_main_tracked
    BHTTP_PORT=""
    save_config
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
    ok "Puerto BHTTP :$p cerrado y eliminado del auto-boot."
  else
    unit="$(basename "$(extra_unit_path "$p")")"
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -f "$(extra_unit_path "$p")"
    firewall_remove_extra_tracked "$p"
    EXTRA_PORTS="$(list_remove_port "${EXTRA_PORTS:-}" "$p")"
    save_config
    systemctl daemon-reload
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
    ok "Puerto BHTTP :$p cerrado y eliminado del auto-boot."
  fi
  info "Puertos BHTTP restantes: $(managed_ports_text)"
}

show_managed_ports(){
  load_config; local p unit state boot allp
  allp="$(normalize_ports "${BHTTP_PORT:-} ${EXTRA_PORTS:-}")"
  echo "===== PUERTOS BHTTP GESTIONADOS ====="
  if [ -z "$allp" ]; then
    echo "Ninguno. Usa la opción 16 para abrir los puertos que quieras."
    return 0
  fi
  if [ -n "${BHTTP_PORT:-}" ]; then
    echo "Principal : $BHTTP_PORT | $(systemctl is-active "$SERVICE" 2>/dev/null || true) | boot=$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
    port_owner "$BHTTP_PORT"
  fi
  for p in ${EXTRA_PORTS:-}; do
    unit="$(basename "$(extra_unit_path "$p")")"
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    boot="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    printf 'Puerto    : %-5s | %-8s | boot=%s
' "$p" "$state" "$boot"
    port_owner "$p"
  done
  echo
  info "Todos usan el mismo engine $ENGINE_VERSION y SSH backend 127.0.0.1:$BACKEND_PORT."
}

set_backend_port(){
  load_config; local p
  prompt_read p "Puerto SSH backend local [$BACKEND_PORT]: "; p="${p:-$BACKEND_PORT}"
  valid_port "$p" || { fail "Puerto inválido."; return 1; }
  BACKEND_PORT="$p"; save_config; [ -n "${BHTTP_PORT:-}" ] && write_unit || true
  local ep
  for ep in ${EXTRA_PORTS:-}; do write_extra_unit "$ep"; done
  systemctl daemon-reload
  restart_service
  ssh_backend_ready || warn "No detecto un listener SSH en :$BACKEND_PORT. Revisa antes de probar la app."
}

set_max_sessions(){
  load_config; local p auto; auto="$(adaptive_sessions)"
  prompt_read p "Max sesiones simultáneas [$MAX_SESSIONS] (recomendado para esta VPS: $auto): "; p="${p:-$MAX_SESSIONS}"
  valid_uint "$p" || { fail "Valor inválido."; return 1; }
  [ "$p" -le 32768 ] || { fail "Por seguridad el manager limita este valor a 32768."; return 1; }
  MAX_SESSIONS="$p"; save_config; [ -n "${BHTTP_PORT:-}" ] && write_unit || true
  local ep
  for ep in ${EXTRA_PORTS:-}; do write_extra_unit "$ep"; done
  systemctl daemon-reload
  restart_service
  ok "Techo de sesiones BHTTP por listener: $MAX_SESSIONS"
}

restart_service(){
  load_config; local p any=0
  if [ -n "${BHTTP_PORT:-}" ]; then systemctl restart "$SERVICE"; any=1; fi
  for p in ${EXTRA_PORTS:-}; do systemctl restart "$(basename "$(extra_unit_path "$p")")"; any=1; done
  [ "$any" -eq 1 ] || info "No hay puertos BHTTP configurados para reiniciar."
  sleep .5; status_compact
}
start_service(){
  load_config; local p any=0
  if [ -n "${BHTTP_PORT:-}" ]; then systemctl enable --now "$SERVICE"; any=1; fi
  for p in ${EXTRA_PORTS:-}; do systemctl enable --now "$(basename "$(extra_unit_path "$p")")"; any=1; done
  [ "$any" -eq 1 ] || info "No hay puertos BHTTP configurados. Usa la opción 16 para abrir uno."
  status_compact
}
stop_service(){
  load_config; local any=0
  if [ -n "${BHTTP_PORT:-}" ]; then systemctl stop "$SERVICE"; any=1; fi
  [ -n "${EXTRA_PORTS:-}" ] && any=1
  stop_extra_services
  [ "$any" -eq 1 ] && warn "Todos los listeners BHTTP fueron detenidos manualmente. Siguen habilitados para el próximo boot salvo que los elimines." || info "No había listeners BHTTP configurados."
}
logs(){
  load_config; local p any=0
  if [ -n "${BHTTP_PORT:-}" ]; then journalctl -u "$SERVICE" -n 80 --no-pager || true; any=1; fi
  for p in ${EXTRA_PORTS:-}; do echo "===== :$p ====="; journalctl -u "$(basename "$(extra_unit_path "$p")")" -n 60 --no-pager || true; any=1; done
  [ "$any" -eq 1 ] || info "No hay listeners BHTTP configurados; todavía no hay logs de puertos."
}

ssh_capacity_diag(){
  load_config
  echo "===== CAPACIDAD SSH BACKEND (solo diagnóstico) ====="
  local out
  out="$(sshd -T 2>/dev/null || /usr/sbin/sshd -T 2>/dev/null || true)"
  if [ -z "$out" ]; then warn "No pude leer sshd -T."; return 0; fi
  echo "$out" | grep -Ei '^(maxstartups|maxsessions|allowtcpforwarding|disableforwarding|permitopen) ' || true
  echo
  echo "Nota: BHTTP abre una conexión SSH backend por sesión. MaxStartups puede limitar ráfagas de autenticaciones simultáneas."
  echo "Este diagnóstico NO cambia sshd para evitar afectar tu acceso administrativo."
}

rollback_engine(){
  need_root
  [ -x "$BACKUP_DIR/engine.previous" ] || { fail "No hay motor previo guardado."; return 1; }
  [ -n "${BHTTP_PORT:-}" ] && systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  stop_extra_services
  cp -a "$BACKUP_DIR/engine.previous" "$BIN"; chmod 755 "$BIN"
  restart_service
  ok "Motor previo restaurado."
  status_all
}

uninstall_all(){
  load_config
  warn "Esto elimina SOLO SuperFlash BHTTP. SSH, H2/XHTTP y otros servicios no se tocan."
  prompt_read c "Escribe BHTTP para confirmar: "
  [ "$c" = "BHTTP" ] || return 0
  firewall_remove_all_tracked
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  local p
  for p in ${EXTRA_PORTS:-}; do systemctl disable --now "$(basename "$(extra_unit_path "$p")")" >/dev/null 2>&1 || true; rm -f "$(extra_unit_path "$p")"; done
  rm -f "$UNIT" "$BIN" "$MENU_BIN" "$MANAGER_BIN"
  remove_performance_tuning
  rm -rf "$BASE"; rm -f "$LEGACY_CONFIG"
  systemctl daemon-reload
  ok "BHTTP eliminado. SSH y los demás protocolos permanecen intactos."
}

header(){
  clear 2>/dev/null || true; load_config
  local installed_icon="✘" service_icon="—" boot_icon="—" tune_icon="✘" ports
  [ -x "$BIN" ] && installed_icon="✔"
  ports="$(managed_ports_text)"
  if [ "$ports" != "ninguno" ]; then
    any_listener_active && service_icon="✔" || service_icon="✘"
    any_listener_enabled && boot_icon="✔" || boot_icon="✘"
  fi
  [ -f "$SYSCTL_FILE" ] && tune_icon="✔"
  echo -e "${blue}╔══════════════════════════════════════════════════════════╗${reset}"
  echo -e "${blue}║${reset}  ${cyan}$TITLE${reset}                                  ${blue}║${reset}"
  echo -e "${blue}╚══════════════════════════════════════════════════════════╝${reset}"
  echo " Manager v$MANAGER_VERSION | Engine $ENGINE_VERSION"
  echo
  echo -e " [$installed_icon] Instalado    [$service_icon] Activo    [$boot_icon] Auto-boot    [$tune_icon] Performance"
  echo -e " [✔] BHP1 Original  [✔] TCP Keep-Alive BHTTP"
  local display_ports="ninguno"
  if [ "$ports" != "ninguno" ]; then display_ports="${ports// /, }"; fi
  echo -e " Puerto BHTTP : ${green}$display_ports${reset}"
  echo -e " SSH backend  : ${green}$BACKEND_PORT${reset}"
  echo -e " Max sesiones : ${green}$MAX_SESSIONS${reset}     TCP activas : ${green}$(connected_tcp_all)${reset}"
  if sysctl_supported net.ipv4.tcp_congestion_control; then echo -e " Congestión   : ${green}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)${reset}"; fi
  if [ "$ports" = "ninguno" ]; then echo -e " ${dim}Abre los puertos que quieras con la opción 16.${reset}"; fi
  echo
}

menu(){
  need_root; require_tty || return 1
  while true; do
    header
    echo " 1) INSTALAR / ACTUALIZAR + OPTIMIZAR (recomendado)"
    echo " 2) Estado completo"
    echo " 3) Autoprueba completa"
    echo " 4) Cambiar puerto BHTTP principal (si existe)"
    echo " 5) Cambiar puerto SSH backend"
    echo " 6) Ajustar máximo de sesiones"
    echo " 7) Reaplicar HIGH PERFORMANCE + STABILITY"
    echo " 8) Diagnóstico de capacidad SSH"
    echo " 9) Reiniciar BHTTP"
    echo "10) Ver logs"
    echo "11) Iniciar BHTTP"
    echo "12) Detener BHTTP"
    echo "13) Abrir puerto en firewall local"
    echo "14) Rollback del motor anterior"
    echo "15) DESINSTALAR BHTTP"
    echo "16) Abrir/agregar puerto BHTTP"
    echo "17) Cerrar/eliminar puerto BHTTP"
    echo " 0) Salir"
    echo
    local op; prompt_read op "Opción: "
    case "$op" in
      1) install_or_update; pause;;
      2) status_all; pause;;
      3) self_test; pause;;
      4) set_bhttp_port; pause;;
      5) set_backend_port; pause;;
      6) set_max_sessions; pause;;
      7) apply_performance_tuning; restart_service; pause;;
      8) ssh_capacity_diag; pause;;
      9) restart_service; pause;;
      10) logs; pause;;
      11) start_service; pause;;
      12) stop_service; pause;;
      13) firewall_open; pause;;
      14) rollback_engine; pause;;
      15) uninstall_all; pause;;
      16) add_extra_port; pause;;
      17) close_extra_port; pause;;
      0) exit 0;;
      *) echo "Opción inválida"; sleep .5;;
    esac
  done
}

usage(){
  cat <<EOF
$TITLE - Manager v$MANAGER_VERSION
Uso:
  sudo bash install.sh install
  sudo bash install.sh menu
  sudo bash install.sh status
  sudo bash install.sh self-test
  sudo bash install.sh restart
  sudo bash install.sh logs
  sudo bash install.sh add-port
  sudo bash install.sh close-port
  sudo bash install.sh ports

Después de instalar también puedes usar:
  sudo bhttp
EOF
}

main(){
  need_root
  local action="${1:-menu}"
  # Compatibilidad con la forma: bash -s -- apksdemons/BHTTP menu
  if [[ "$action" == */* ]] && [ "${2:-}" != "" ]; then REPO="$action"; action="$2"; fi
  case "$action" in
    menu|--menu|"") menu;;
    install|quick|--install|--quick) install_or_update;;
    status|--status) status_all;;
    self-test|test|--self-test) self_test;;
    restart|--restart) restart_service;;
    start|--start) start_service;;
    stop|--stop) stop_service;;
    logs|--logs) logs;;
    tuning|performance|--tuning) apply_performance_tuning;;
    ssh-diag|--ssh-diag) ssh_capacity_diag;;
    rollback|--rollback) rollback_engine;;
    add-port|--add-port) require_tty; add_extra_port;;
    close-port|remove-port|--close-port|--remove-port) require_tty; close_extra_port;;
    ports|--ports) show_managed_ports;;
    uninstall|--uninstall) require_tty; uninstall_all;;
    help|-h|--help) usage;;
    *) usage; exit 2;;
  esac
}

main "$@"
