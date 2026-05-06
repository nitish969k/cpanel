#!/bin/bash

OLD_IP="148.113.0.0"
NEW_IP="148.113.0.1"
LOG="/root/change_ip2.log"

echo "Starting IP migration $OLD_IP -> $NEW_IP" > $LOG
echo "Time: $(date)" >> $LOG
echo "---------------------------------" >> $LOG

# Verify new IP exists
ip a | grep -q "$NEW_IP"
if [ $? -ne 0 ]; then
    echo "ERROR: $NEW_IP is not configured on this server." | tee -a $LOG
    exit 1
fi

echo "Fetching ACTIVE cPanel accounts..." | tee -a $LOG

# Get only active (non-suspended) users
ACTIVE_USERS=$(whmapi1 listaccts --output=json \
    | jq -r '.data.acct[] | select(.suspended==0) | .user')

for USER in $ACTIVE_USERS; do

    USERFILE="/var/cpanel/users/$USER"

    [ ! -f "$USERFILE" ] && continue

    CURRENT_IP=$(grep "^IP=" "$USERFILE" | cut -d= -f2)

    if [ "$CURRENT_IP" == "$OLD_IP" ]; then
        echo "Changing $USER from $OLD_IP to $NEW_IP" | tee -a $LOG

        /usr/local/cpanel/bin/whmapi1 setsiteip user=$USER ip=$NEW_IP >> $LOG 2>&1

        if [ $? -ne 0 ]; then
            echo "❌ Failed for $USER" | tee -a $LOG
        else
            echo "✅ Success for $USER" | tee -a $LOG
        fi
    fi
done

echo "---------------------------------" >> $LOG
echo "Rebuilding web server configs..." | tee -a $LOG

/scripts/rebuildhttpdconf >> $LOG 2>&1
/scripts/restartsrv_httpd >> $LOG 2>&1

# Restart LiteSpeed if exists
if [ -x /scripts/restartsrv_lsws ]; then
    /scripts/restartsrv_lsws >> $LOG 2>&1
fi

echo "DONE. Check log: $LOG"
