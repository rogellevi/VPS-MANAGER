#!/bin/bash
# Módulo de instalación Hysteria2 para Golbert VPS

mkdir -p /etc/hysteria
wget -O /usr/local/bin/hysteria "https://github.com/apernet/hysteria/releases/download/v2.2.1/hysteria-linux-amd64" 2>/dev/null
chmod +x /usr/local/bin/hysteria

cat <<EOF > /etc/hysteria/config.yaml
listen: :36712
tls:
  cert: /etc/stunnel/stunnel.pem
  key: /etc/stunnel/stunnel.pem
auth:
  type: password
  password: golbert123
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
EOF

cat <<EOF > /etc/systemd/system/hysteria.service
[Unit]
Description=Hysteria2 Server by GolbertVPS
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria
systemctl restart hysteria
echo "[✔] Módulo Hysteria2 instalado y configurado correctamente."
