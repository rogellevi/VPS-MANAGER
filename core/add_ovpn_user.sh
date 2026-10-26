#!/bin/bash
# Función para generar perfiles .ovpn para un usuario nuevo
USER_NAME=$1
IP_SERV=$(curl -s ipv4.icanhazip.com)
OVPN_DIR="/etc/vps-manager/openvpn_files/$USER_NAME"
mkdir -p "$OVPN_DIR"

# Aquí defines la estructura base de tus archivos .ovpn
cat << EOF > "$OVPN_DIR/cliente-tcp-1194.ovpn"
client
dev tun
proto tcp
remote $IP_SERV 1194
resolv-retry infinite
nobind
persist-key
persist-tun
auth-user-pass
remote-cert-tls server
cipher AES-256-CBC
verb 3
<cert>
# [Certificado del servidor]
</cert>
<key>
# [Llave del servidor]
</key>
<ca>
# [CA certificado]
</ca>
EOF

# Haces lo mismo para udp, ssl, ohp, etc., y el usuario los tendrá listos en su web.
