#!/bin/bash
# Módulo de instalación ZIVPN para Golbert VPS

mkdir -p /etc/zivpn
wget -O /usr/local/bin/zivpn "https://github.com/zahidbd2/zivpn/releases/download/v1.0.8/zivpn-linux-amd64" 2>/dev/null || true
chmod +x /usr/local/bin/zivpn 2>/dev/null || true

cat <<EOF > /etc/zivpn/config.json
{
  "listen": ":20000",
  "udp_ports": "20000-29999",
  "password": "golbertvps"
}
EOF

cat <<EOF > /etc/systemd/system/zivpn.service
[Unit]
Description=ZIVPN UDP Server by GolbertVPS
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/zivpn -c /etc/zivpn/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zivpn 2>/dev/null || true
systemctl restart zivpn 2>/dev/null || true
echo "[✔] Módulo ZIVPN instalado y configurado correctamente."
