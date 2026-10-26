#!/bin/bash

DB_USERS="/etc/vps-manager/users.db"
LOG_FILE="/var/log/vps-limiter.log"

while true; do
    if [[ -f "$DB_USERS" ]]; then
        hoy=$(date +%s)
        while IFS='|' read -r user pass exp limite; do
            [[ -z "$user" ]] && continue

            if id "$user" &>/dev/null; then
                exp_sec=$(date -d "$exp" +%s 2>/dev/null)
                if [[ -n "$exp_sec" && $hoy -ge $exp_sec ]]; then
                    pkill -u "$user" 2>/dev/null
                    userdel -f "$user" 2>/dev/null
                    sed -i "/^$user|/d" "$DB_USERS"
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Expirado y eliminado: $user" >> "$LOG_FILE"
                    continue
                fi

                con=$(ps -u "$user" 2>/dev/null | grep sshd | wc -l)
                if [[ "$con" -gt "$limite" ]]; then
                    pkill -u "$user" 2>/dev/null
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Multi-login bloqueado ($con/$limite): $user" >> "$LOG_FILE"
                fi
            fi
        done < "$DB_USERS"
    fi
    sleep 15
done
