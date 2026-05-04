#!/bin/bash

LOG="/root/cpanel_password_change_$(date +%F).log"

echo "cPanel Password Change Log - $(date)" > "$LOG"
echo "------------------------------------" >> "$LOG"

# Ensure directory exists
[ -d /var/cpanel/users ] || { echo "Directory not found"; exit 1; }

for file in /var/cpanel/users/*; do

    # Skip if not a regular file
    [ -f "$file" ] || continue

    user=$(basename "$file")

    # Skip invalid/system usernames (extra safety)
    [[ "$user" =~ ^(system|cpanel|nobody)$ ]] && continue

    # Generate password (not stored)
    pass=$(openssl rand -base64 12)

    # Change password
    if whmapi1 passwd user="$user" password="$pass" >/dev/null 2>&1; then

        # Disable forced password reset
        whmapi1 modifyacct user="$user" require_password_change=0 >/dev/null 2>&1

        echo "[OK] $user updated" | tee -a "$LOG"
    else
        echo "[FAIL] $user failed" | tee -a "$LOG"
    fi

    unset pass

done

echo "Done. Log saved at $LOG"
