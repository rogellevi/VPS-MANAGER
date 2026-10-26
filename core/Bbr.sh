#!/bin/bash
# ==========================================
# Módulo: Optimizador y Activador TCP BBR
# ==========================================

clear
echo -e "\033[1;36m[+] Verificando e instalando TCP BBR...\033[0m"

# Comprobar si ya está activo
if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf && grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    echo -e "\n\033[1;32m[✔] ¡TCP BBR ya se encuentra activo en este VPS!\033[0m"
    sleep 2
    return 2>/dev/null || exit 0
fi

# Aplicar configuraciones al kernel
cat << 'EOF' >> /etc/sysctl.conf

# --- Optimización TCP BBR Golbert VPS ---
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl -p > /dev/null 2>&1

if grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    echo -e "\n\033[1;32m[✔] ¡TCP BBR activado y configurado con éxito!\033[0m"
else
    echo -e "\n\033[1;31m[!] No se pudo aplicar BBR automáticamente en este kernel.\033[0m"
fi
sleep 2
