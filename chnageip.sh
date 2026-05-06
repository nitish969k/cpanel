#!/bin/bash

NEW_IP="148.113.26.51"
LOG="/root/change_ip_148.113.26.51.log"

echo "Starting IP change to $NEW_IP" > $LOG
echo "Time: $(date)" >> $LOG
echo "---------------------------------" >> $LOG

for USER in $(ls /var/cpanel/users); do
    # Skip system users just in case
    if [[ "$USER" =~ ^(root|nobody|cpanel|mysql)$ ]]; then
        continue
    fi

    echo "Changing IP for $USER" | tee -a $LOG

    /usr/local/cpanel/bin/whmapi1 setsiteip user=$USER ip=$NEW_IP >> $LOG 2>&1

    if [ $? -ne 0 ]; then
        echo "❌ Failed for $USER" | tee -a $LOG
    else
        echo "✅ Success for $USER" | tee -a $LOG
    fi
done

echo "---------------------------------" >> $LOG
echo "Rebuilding web server configs..." | tee -a $LOG

/scripts/rebuildhttpdconf >> $LOG 2>&1
/scripts/restartsrv_httpd >> $LOG 2>&1

if [ -x /scripts/restartsrv_lsws ]; then
    /scripts/restartsrv_lsws >> $LOG 2>&1
fi

echo "DONE. Check log: $LOG"
