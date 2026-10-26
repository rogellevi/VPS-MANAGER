#!/bin/bash
# ==========================================
# Instalador Real de OpenVPN + Certificados
# ==========================================
clear
echo -e "\033[1;33m[+] Instalando y configurando OpenVPN...\033[0m"
apt update -y && apt install -y openvpn iptables python3 curl openssl >/dev/null 2>&1

# Encontrar el plugin de autenticación PAM automáticamente
PAM_PLUGIN=$(find /usr/lib -type f -name "openvpn-plugin-auth-pam.so" | head -n 1)

# 1. Generar Certificados (CA y Server)
cd /etc/openvpn
if [ ! -f "ca.crt" ]; then
    openssl req -nodes -new -x509 -keyout ca.key -out ca.crt -days 3650 -subj "/CN=GolbertVPN" >/dev/null 2>&1
    openssl req -nodes -new -keyout server.key -out server.csr -subj "/CN=GolbertServer" >/dev/null 2>&1
    openssl x509 -req -in server.csr -out server.crt -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 >/dev/null 2>&1
    openssl dhparam -out dh.pem 2048 >/dev/null 2>&1
fi

# 2. Configurar servidor OpenVPN (TCP 1194)
cat <<EOF > /etc/openvpn/server-tcp.conf
port 1194
proto tcp
dev tun
ca /etc/openvpn/ca.crt
cert /etc/openvpn/server.crt
key /etc/openvpn/server.key
dh /etc/openvpn/dh.pem
plugin $PAM_PLUGIN login
verify-client-cert none
username-as-common-name
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-CBC
persist-key
persist-tun
verb 3
EOF

# Activar enrutamiento de red (IP Forwarding y NAT)
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j MASQUERADE
iptables-save > /etc/iptables.up.rules

# Reiniciar OpenVPN Server
systemctl restart openvpn@server-tcp
systemctl enable openvpn@server-tcp >/dev/null 2>&1

# 3. Generar archivo .ovpn legítimo con el Certificado <ca> incluido
IP_ACTUAL=$(curl -s ipv4.icanhazip.com)
DOM=$( [ -f /etc/vps-manager/dominio ] && cat /etc/vps-manager/dominio || echo "$IP_ACTUAL" )
OVPN_DIR="/etc/vps-manager/openvpn_files"
mkdir -p "$OVPN_DIR"
CA_CERT=$(cat /etc/openvpn/ca.crt)

cat <<EOF > "$OVPN_DIR/cliente-tcp-1194.ovpn"
client
dev tun
proto tcp
remote $DOM 1194
resolv-retry infinite
nobind
persist-key
persist-tun
auth-user-pass
cipher AES-256-CBC
verb 3
<ca>
$CA_CERT
</ca>
EOF

# 4. Iniciar Servidor Web en puerto 2081
cat << 'EOF' > /etc/vps-manager/server_web.py
import http.server
import socketserver
PORT = 2081
DIRECTORY = "/etc/vps-manager/openvpn_files"
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)
with socketserver.TCPServer(("0.0.0.0", PORT), Handler) as httpd:
    httpd.serve_forever()
EOF

cat << 'EOF' > /etc/systemd/system/openvpn-web.service
[Unit]
Description=Web OpenVPN
After=network.target
[Service]
ExecStart=/usr/bin/python3 /etc/vps-manager/server_web.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openvpn-web >/dev/null 2>&1
systemctl restart openvpn-web

echo -e "\033[1;32m[✔] Servidor OpenVPN y Certificados configurados exitosamente.\033[0m"
