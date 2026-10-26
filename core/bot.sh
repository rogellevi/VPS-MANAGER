#!/bin/bash
# ==========================================
# Módulo: Bot de Telegram (Sistema Vendedores + V2Ray)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'

BOT_DIR="/etc/vps-manager/telegram_bot"
mkdir -p "$BOT_DIR"
touch "$BOT_DIR/resellers.txt"

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}    CONFIGURACIÓN DE BOT (VENDEDORES Y V2RAY)   ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

if [ -f "$BOT_DIR/config.env" ]; then
    echo -e "${C_YELLOW}[+] Bot ya configurado.${C_NC}"
    read -p "¿Deseas reconfigurar Token y Admin ID? (s/n): " reconf
    if [[ "$reconf" == "s" || "$reconf" == "S" ]]; then
        rm -f "$BOT_DIR/config.env"
    else
        echo -e "${C_GREEN}Actualizando el sistema del bot actual...${C_NC}"
    fi
fi

if [ ! -f "$BOT_DIR/config.env" ]; then
    read -p "Ingresa el Token del Bot: " TELEGRAM_TOKEN
    read -p "Ingresa tu Admin ID de Telegram: " ADMIN_ID
    TELEGRAM_TOKEN=$(echo "$TELEGRAM_TOKEN" | tr -d ' ' | tr -d '"')
    ADMIN_ID=$(echo "$ADMIN_ID" | tr -d ' ' | tr -d '"')
    echo "TOKEN=\"$TELEGRAM_TOKEN\"" > "$BOT_DIR/config.env"
    echo "ADMIN=\"$ADMIN_ID\"" >> "$BOT_DIR/config.env"
fi

apt update -y && apt install -y python3 python3-venv python3-pip jq uuid-runtime >/dev/null 2>&1

cd "$BOT_DIR"
if [ ! -d "venv" ]; then
    python3 -m venv venv
    source venv/bin/activate
    pip install pyTelegramBotAPI >/dev/null 2>&1
fi

# ==========================================
# SCRIPT DE PYTHON (EL CEREBRO DEL BOT)
# ==========================================
cat << 'EOF' > "$BOT_DIR/bot.py"
import os
import subprocess
import telebot
from telebot import types
import time
import uuid

# Cargar configuración
BOT_DIR = "/etc/vps-manager/telegram_bot"
RESELLERS_FILE = os.path.join(BOT_DIR, "resellers.txt")
TOKEN = ""
ADMIN_ID = ""

with open(os.path.join(BOT_DIR, "config.env"), "r") as f:
    for line in f:
        if line.startswith("TOKEN="):
            TOKEN = line.split("=")[1].strip().strip('"')
        elif line.startswith("ADMIN="):
            ADMIN_ID = line.split("=")[1].strip().strip('"')

bot = telebot.TeleBot(TOKEN)

# Funciones de Vendedores (Resellers)
def load_resellers():
    resellers = {}
    if os.path.exists(RESELLERS_FILE):
        with open(RESELLERS_FILE, "r") as f:
            for line in f:
                if ":" in line:
                    uid, creds = line.strip().split(":")
                    resellers[uid] = int(creds)
    return resellers

def save_resellers(resellers):
    with open(RESELLERS_FILE, "w") as f:
        for uid, creds in resellers.items():
            f.write(f"{uid}:{creds}\n")

def is_admin(user_id):
    return str(user_id) == str(ADMIN_ID)

def is_reseller(user_id):
    return str(user_id) in load_resellers()

def get_credits(user_id):
    return load_resellers().get(str(user_id), 0)

def deduct_credit(user_id):
    if is_admin(user_id): return True
    resellers = load_resellers()
    uid = str(user_id)
    if uid in resellers and resellers[uid] > 0:
        resellers[uid] -= 1
        save_resellers(resellers)
        return True
    return False

@bot.message_handler(commands=['start', 'help'])
def send_welcome(message):
    uid = str(message.from_user.id)
    if is_admin(uid):
        markup = types.ReplyKeyboardMarkup(row_width=2, resize_keyboard=True)
        markup.add("👤 Crear SSH", "❌ Eliminar SSH")
        markup.add("🛡️ Crear V2Ray (Xray)", "📋 Lista SSH")
        markup.add("👥 Panel Vendedores", "📊 Info Servidor")
        bot.reply_to(message, "👑 <b>Panel ADMIN VPS Activo</b>", parse_mode="HTML", reply_markup=markup)
    elif is_reseller(uid):
        markup = types.ReplyKeyboardMarkup(row_width=2, resize_keyboard=True)
        markup.add("👤 Crear SSH", "💰 Mis Créditos")
        bot.reply_to(message, f"🤝 <b>Panel VENDEDOR Activo</b>\nCréditos Disponibles: {get_credits(uid)}", parse_mode="HTML", reply_markup=markup)
    else:
        bot.reply_to(message, f"⚠️ <b>Acceso Denegado.</b>\nNo estás registrado como vendedor.\nTu ID es: <code>{uid}</code>", parse_mode="HTML")

@bot.message_handler(func=lambda message: True)
def handle_message(message):
    uid = str(message.from_user.id)
    if not (is_admin(uid) or is_reseller(uid)):
        return

    text = message.text

    # ==========================
    # MENÚ ADMIN EXCLUSIVO
    # ==========================
    if is_admin(uid):
        if text == "📊 Info Servidor":
            ip = subprocess.getoutput("curl -s ipv4.icanhazip.com")
            ram = subprocess.getoutput("free -m | awk 'NR==2{printf \"%s / %s MB\", $3,$2}'")
            bot.reply_to(message, f"🌐 <b>IP:</b> {ip}\n⚡ <b>RAM:</b> {ram}", parse_mode="HTML")
            return
            
        elif text == "❌ Eliminar SSH":
            bot.reply_to(message, "Formato:\n<code>/deluser [usuario]</code>", parse_mode="HTML")
            return
            
        elif text.startswith("/deluser"):
            try:
                user = text.split()[1]
                subprocess.getoutput(f"userdel -f {user}")
                subprocess.getoutput(f"rm -f /etc/vps-manager/banner_{user}.net")
                subprocess.getoutput(f"sed -i '/Match User {user}/,+1d' /etc/ssh/sshd_config")
                subprocess.getoutput("systemctl restart ssh")
                bot.reply_to(message, f"✅ <b>{user}</b> eliminado.", parse_mode="HTML")
            except:
                bot.reply_to(message, "❌ Error.")
            return

        elif text == "👥 Panel Vendedores":
            msg = "👥 <b>GESTIÓN DE REVENDEDORES</b>\n\n"
            msg += "Añadir vendedor (Ej: 10 créditos):\n<code>/addvend ID_TELEGRAM 10</code>\n\n"
            msg += "Eliminar vendedor:\n<code>/delvend ID_TELEGRAM</code>\n\n"
            msg += "<b>Vendedores Actuales:</b>\n"
            res = load_resellers()
            for r_id, cred in res.items():
                msg += f"ID: <code>{r_id}</code> - Créditos: {cred}\n"
            bot.reply_to(message, msg, parse_mode="HTML")
            return

        elif text.startswith("/addvend"):
            try:
                parts = text.split()
                r_id = parts[1]
                creds = int(parts[2])
                res = load_resellers()
                res[r_id] = creds
                save_resellers(res)
                bot.reply_to(message, f"✅ Vendedor <code>{r_id}</code> agregado con {creds} créditos.", parse_mode="HTML")
            except:
                bot.reply_to(message, "❌ Formato: /addvend ID CREDITOS")
            return

        elif text.startswith("/delvend"):
            try:
                r_id = text.split()[1]
                res = load_resellers()
                if r_id in res:
                    del res[r_id]
                    save_resellers(res)
                    bot.reply_to(message, f"✅ Vendedor eliminado.", parse_mode="HTML")
            except:
                pass
            return
            
        elif text == "🛡️ Crear V2Ray (Xray)":
            bot.reply_to(message, "Generador V2Ray (VMess):\n<code>/addvmess [usuario] [dias]</code>\nEjemplo: <code>/addvmess carlos 30</code>", parse_mode="HTML")
            return
            
        elif text.startswith("/addvmess"):
            try:
                parts = text.split()
                v_user = parts[1]
                v_days = parts[2]
                v_uuid = str(uuid.uuid4())
                ip = subprocess.getoutput("curl -s ipv4.icanhazip.com")
                dom = subprocess.getoutput("[ -f /etc/vps-manager/dominio ] && cat /etc/vps-manager/dominio || echo '" + ip + "'")
                
                # Formato Vmess Básico
                vmess_json = f'{{"v":"2","ps":"{v_user}","add":"{dom}","port":"443","id":"{v_uuid}","aid":"0","scy":"auto","net":"ws","type":"none","host":"{dom}","path":"/vmess","tls":"tls","sni":"{dom}","alpn":""}}'
                import base64
                vmess_base64 = base64.b64encode(vmess_json.encode('utf-8')).decode('utf-8')
                vmess_link = f"vmess://{vmess_base64}"
                
                msg = f"✅ <b>V2RAY VMESS CREADO</b> ✅\n\n👤 <b>Usuario:</b> {v_user}\n🔑 <b>UUID:</b> <code>{v_uuid}</code>\n📅 <b>Días:</b> {v_days}\n\n🔗 <b>Enlace Vmess:</b>\n<code>{vmess_link}</code>"
                bot.reply_to(message, msg, parse_mode="HTML")
            except Exception as e:
                bot.reply_to(message, "❌ Error al generar V2Ray.")
            return

    # ==========================
    # FUNCIONES GENERALES (Admin y Revendedor)
    # ==========================
    if text == "💰 Mis Créditos":
        bot.reply_to(message, f"💰 <b>Créditos disponibles:</b> {get_credits(uid)}", parse_mode="HTML")
        return

    elif text == "👤 Crear SSH":
        bot.reply_to(message, "Comando para crear:\n<code>/adduser [usuario] [clave] [dias]</code>", parse_mode="HTML")
        return
        
    elif text.startswith("/adduser"):
        if get_credits(uid) <= 0 and not is_admin(uid):
            bot.reply_to(message, "❌ <b>No tienes créditos suficientes.</b> Contacta al administrador.", parse_mode="HTML")
            return
            
        try:
            parts = text.split()
            user = parts[1]
            pwd = parts[2]
            days = parts[3]
            
            cmd = f"useradd -e $(date -d '+{days} days' +'%Y-%m-%d') -s /bin/false -M {user} && echo '{user}:{pwd}' | chpasswd"
            res_cmd = subprocess.getoutput(cmd)
            
            if "already exists" in res_cmd:
                bot.reply_to(message, "❌ El usuario ya existe.")
                return

            ip = subprocess.getoutput("curl -s ipv4.icanhazip.com")
            dom = subprocess.getoutput("[ -f /etc/vps-manager/dominio ] && cat /etc/vps-manager/dominio || echo '" + ip + "'")
            exp_date = subprocess.getoutput(f"date -d '+{days} days' +'%Y-%m-%d'")
            
            # Banner
            subprocess.getoutput(f"cat /etc/issue.net > /etc/vps-manager/banner_{user}.net && echo \"<br><font color='cyan'>=======================</font><br><font color='yellow'>👤 Usuario:</font> <font color='white'>{user}</font><br><font color='yellow'>📅 Expira:</font> <font color='white'>{exp_date} ({days} Días)</font><br><font color='cyan'>=======================</font><br>\" >> /etc/vps-manager/banner_{user}.net && sed -i '/Match User {user}/d' /etc/ssh/sshd_config && echo -e '\\nMatch User {user}\\nBanner /etc/vps-manager/banner_{user}.net' >> /etc/ssh/sshd_config && systemctl restart ssh")
            
            # Descontar crédito si es vendedor
            deduct_credit(uid)
            
            respuesta = f"✅ <b>CUENTA CREADA</b> ✅\n\n👤 <b>Usuario:</b> {user}\n🔑 <b>Clave:</b> {pwd}\n📅 <b>Expira:</b> {exp_date} ({days} días)\n🌐 <b>Host:</b> {dom}\n\n"
            if not is_admin(uid):
                respuesta += f"💰 <i>Créditos restantes: {get_credits(uid)}</i>"
                
            bot.reply_to(message, respuesta, parse_mode="HTML")
        except:
            bot.reply_to(message, "❌ <b>Error.</b> Formato: /adduser usuario clave dias", parse_mode="HTML")

if __name__ == "__main__":
    while True:
        try:
            bot.infinity_polling(timeout=10, long_polling_timeout=5)
        except Exception as e:
            time.sleep(3)
EOF

cat << EOF > /etc/systemd/system/vps-bot.service
[Unit]
Description=Telegram Bot Golbert VPS
After=network.target

[Service]
User=root
WorkingDirectory=$BOT_DIR
ExecStart=$BOT_DIR/venv/bin/python $BOT_DIR/bot.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vps-bot >/dev/null 2>&1
systemctl restart vps-bot

echo -e "\n${C_GREEN}[✔] ¡Bot de Telegram Aislado configurado e iniciado con éxito!${C_NC}"
read -p "Presione Enter para regresar..."
