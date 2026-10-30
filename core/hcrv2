#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BINARY_PATH="$SCRIPT_DIR/hcr-server"
UNIT_SOURCE_PATH="$SCRIPT_DIR/hcr-server.service"
UNIT_LINK_PATH=/etc/systemd/system/hcr-server.service
TLS_CERT_PATH=fullchain.pem
TLS_KEY_PATH=privkey.pem
ACTION=install
PORT=8080
TRANSPORT=auto
TARGET=127.0.0.1:22
SESSION_STATS_INTERVAL=0
DIAGNOSTICS_INTERVAL=0
DEFAULT_DOWNLOAD_FRAME=16384
MAX_DOWNLOAD_FRAME="$DEFAULT_DOWNLOAD_FRAME"
DOWNLOAD_POLL_TIMEOUT=8s
MAX_CONNECTIONS=""
MAX_SESSIONS=""
MAX_SESSIONS_PER_IP=""
TEMP_UNIT=""

fail() {
	echo "Error: $*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
HCR Server

  sudo ./install.sh [options]
  sudo ./install.sh --uninstall
  ./install.sh --version

  --port NUMBER                 Port (8080)
  --transport auto|tls|plain     Transport (auto)
  --target HOST:PORT            SSH server (127.0.0.1:22)
  --tls-cert FILE               Certificate (fullchain.pem)
  --tls-key FILE                Private key (privkey.pem)
  --max-connections NUMBER      Request limit; 0 uses the server default
  --max-sessions NUMBER         Session limit; 0 uses the server default
  --max-sessions-per-ip NUMBER  Per-IP limit; 0 uses the server default
  --session-stats-interval TIME Session stats, e.g. 10s; 0 turns them off
  --diagnostics-interval TIME   Path diagnostics, 10s to 5m; 0 turns them off
  --max-download-frame BYTES    Range: 1-262140 bytes. Default: 16384.
  --download-poll-timeout TIME  Poll timeout (8s)
  --uninstall                  Stop and remove the service link; keep files
  --version, -version          Show the binary version
  --help, -h                   Show help

Keep hcr-server in the same directory as install.sh. For auto/tls, also provide the TLS files.
Relative TLS paths use this folder.
Frames above 16384 bytes require updated HC. Frame values are checked before any service changes.
Run again with all your options to change them; this restarts the service.
Uninstall keeps the binary and certificates.
EOF
}

parse_args() {
	local options_set=false
	while [ "$#" -gt 0 ]; do
		case "$1" in
			-h|--help) usage; exit 0 ;;
			--uninstall|--version|-version)
				[ "$#" -eq 1 ] && [ "$options_set" = false ] || fail "Use $1 on its own."
				if [ "$1" = --uninstall ]; then ACTION=uninstall; else ACTION=version; fi
				return
				;;
		esac
		[ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || fail "$1 needs a value."
		[[ "$2" != *[[:space:]\"\'\\%\$]* ]] || fail "Unsupported characters in $1."
		case "$1" in
			--port) PORT="$2" ;;
			--transport) TRANSPORT="$2" ;;
			--target) TARGET="$2" ;;
			--tls-cert) TLS_CERT_PATH="$2" ;;
			--tls-key) TLS_KEY_PATH="$2" ;;
			--max-connections) MAX_CONNECTIONS="$2" ;;
			--max-sessions) MAX_SESSIONS="$2" ;;
			--max-sessions-per-ip) MAX_SESSIONS_PER_IP="$2" ;;
			--session-stats-interval) SESSION_STATS_INTERVAL="$2" ;;
			--diagnostics-interval) DIAGNOSTICS_INTERVAL="$2" ;;
			--max-download-frame) MAX_DOWNLOAD_FRAME="$2" ;;
			--download-poll-timeout) DOWNLOAD_POLL_TIMEOUT="$2" ;;
			*) fail "Unknown option: $1" ;;
		esac
		options_set=true
		shift 2
	done
}

normalize_frame_decimal() {
	local value="$1" error_message="$2"
	case "$value" in
		""|*[!0-9]*) fail "$error_message" ;;
	esac
	# Buang nol di depan; periksa panjang sebelum membandingkan agar tidak overflow.
	while [ "${#value}" -gt 1 ] && [ "${value:0:1}" = 0 ]; do value="${value:1}"; done
	if [ "${#value}" -gt 10 ] || [ "$value" -lt 1 ] || [ "$value" -gt 2147483647 ]; then
		fail "$error_message"
	fi
	NORMALIZED_FRAME_DECIMAL="$value"
}

validate_download_frame() {
	local help_output
	normalize_frame_decimal "$MAX_DOWNLOAD_FRAME" \
		'--max-download-frame must be a whole number from 1 through 262140 bytes.'
	MAX_DOWNLOAD_FRAME="$NORMALIZED_FRAME_DECIMAL"
	[ "$MAX_DOWNLOAD_FRAME" -gt "$DEFAULT_DOWNLOAD_FRAME" ] || return 0
	# Binary tetap menentukan plafon; binary lama masih bisa memakai ukuran bawaan.
	help_output="$("$BINARY_PATH" --help 2>&1)" || fail 'The binary could not report its download frame limit.'
	[[ "$help_output" =~ frame\ range:\ 1-([0-9]+) ]] || \
		fail 'The binary does not advertise support for larger download frames.'
	normalize_frame_decimal "${BASH_REMATCH[1]}" 'The binary reported an invalid download frame limit.'
	[ "$MAX_DOWNLOAD_FRAME" -le "$NORMALIZED_FRAME_DECIMAL" ] || \
		fail "--max-download-frame exceeds the binary limit ($NORMALIZED_FRAME_DECIMAL)."
}

render_unit() {
	local args
	args="--listen :$PORT --target $TARGET --transport $TRANSPORT"
	if [ "$TRANSPORT" != plain ]; then args+=" --tls-cert $TLS_CERT_PATH --tls-key $TLS_KEY_PATH"; fi
	args+=" --max-download-frame $MAX_DOWNLOAD_FRAME --download-poll-timeout $DOWNLOAD_POLL_TIMEOUT"
	if [ "$SESSION_STATS_INTERVAL" != 0 ]; then args+=" --session-stats-interval $SESSION_STATS_INTERVAL"; fi
	if [ -n "$MAX_CONNECTIONS" ]; then args+=" --max-connections $MAX_CONNECTIONS"; fi
	if [ -n "$MAX_SESSIONS" ]; then args+=" --max-sessions $MAX_SESSIONS"; fi
	if [ -n "$MAX_SESSIONS_PER_IP" ]; then args+=" --max-sessions-per-ip $MAX_SESSIONS_PER_IP"; fi
	if [ "$DIAGNOSTICS_INTERVAL" != 0 ]; then args+=" --diagnostics-interval $DIAGNOSTICS_INTERVAL"; fi
	TEMP_UNIT="$(mktemp "$SCRIPT_DIR/.hcr-server.XXXXXX.service")"
	cat >"$TEMP_UNIT" <<EOF
[Unit]
Description=HCR relay
After=network.target

[Service]
WorkingDirectory=$SCRIPT_DIR
ExecStart=$BINARY_PATH $args
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
	chmod 0644 "$TEMP_UNIT"
}

install_service() {
	[ -f "$BINARY_PATH" ] && [ -x "$BINARY_PATH" ] || fail "Place an executable hcr-server in the same directory as install.sh."
	validate_download_frame
	if [[ "$TLS_CERT_PATH" != /* ]]; then TLS_CERT_PATH="$SCRIPT_DIR/${TLS_CERT_PATH#./}"; fi
	if [[ "$TLS_KEY_PATH" != /* ]]; then TLS_KEY_PATH="$SCRIPT_DIR/${TLS_KEY_PATH#./}"; fi
	if [ "$TRANSPORT" != plain ]; then
		[ -f "$TLS_CERT_PATH" ] && [ -f "$TLS_KEY_PATH" ] || fail "TLS files are missing."
	fi
	render_unit
	mv -fT -- "$TEMP_UNIT" "$UNIT_SOURCE_PATH"
	TEMP_UNIT=""
	ln -sfnT -- "$UNIT_SOURCE_PATH" "$UNIT_LINK_PATH"
	systemctl daemon-reload
	systemctl enable hcr-server.service
	systemctl reset-failed hcr-server.service >/dev/null 2>&1 || true
	systemctl restart hcr-server.service || fail "Start failed. Check journalctl -u hcr-server."
	sleep 3
	systemctl is-active --quiet hcr-server.service || fail "Service stopped. Check journalctl -u hcr-server."
	echo "HCR Server installed on port $PORT ($TRANSPORT)."
}

uninstall_service() {
	systemctl disable --now hcr-server.service
	rm -f -- "$UNIT_LINK_PATH"
	systemctl daemon-reload
	echo "HCR Server uninstalled. Files kept in $SCRIPT_DIR"
}

main() {
	trap 'if [ -n "$TEMP_UNIT" ]; then rm -f -- "$TEMP_UNIT"; fi' EXIT
	parse_args "$@"
	if [ "$ACTION" = version ]; then "$BINARY_PATH" -version; return; fi
	[ "$(uname -s)" = Linux ] && [ "$(id -u)" = 0 ] || fail "Run as root on Linux."
	command -v systemctl >/dev/null || fail "systemd is required."
	[[ "$SCRIPT_DIR" != *[[:space:]\"\'\\%\$]* ]] || fail "Use a folder without spaces or special characters."
	if [ "$ACTION" = uninstall ]; then uninstall_service; else install_service; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
