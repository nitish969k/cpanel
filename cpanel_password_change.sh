#!/bin/bash

LOG="/root/cpanel_password_change_$(date +%F).log"

echo "cPanel Password Change Log - $(date)" > "$LOG"
echo "------------------------------------" >> "$LOG"

for user in $(awk -F: '{print $1}' /etc/trueuserdomains); do

    # Generate random password (not stored)
    pass=$(openssl rand -base64 12)

    # Change password
    if whmapi1 passwd user="$user" password="$pass" >/dev/null 2>&1; then
        
        # Disable forced password reset
        whmapi1 modifyacct user="$user" require_password_change=0 >/dev/null 2>&1

        echo "[OK] $user password changed" | tee -a "$LOG"
    else
        echo "[FAIL] $user password change failed" | tee -a "$LOG"
    fi

    # Immediately unset password variable (extra safety)
    unset pass

done

echo "Done. Log saved at $LOG"
