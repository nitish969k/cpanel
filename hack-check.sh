#!/bin/bash
set -euo pipefail

TS="$(date +%F-%H%M%S)"
Q="/root/quarantine-hacker/emergency-$TS"
LOG="$Q/actions.log"

mkdir -p "$Q"/{evidence,quarantine}

exec > >(tee -a "$LOG") 2>&1

echo "===== INCIDENT RESPONSE STARTED: $TS ====="
echo "Hostname: $(hostname)"
echo "Date: $(date)"
echo

# ==============================
# 1. BASIC ENV FIX
# ==============================
echo "[+] Fixing root shell prompt safely"
cat >/root/.bashrc <<'EOF'
export PS1='[\u@\h \W]\# '
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
EOF

cat >/root/.bash_profile <<'EOF'
[ -f ~/.bashrc ] && . ~/.bashrc
EOF

# ==============================
# 2. EVIDENCE COLLECTION (SAFE)
# ==============================
echo "[+] Collecting evidence"

ps auxwwf > "$Q/evidence/ps.txt"
pstree -ap > "$Q/evidence/pstree.txt" || true
ss -tulpn > "$Q/evidence/network.txt"
lsof -nP > "$Q/evidence/lsof.txt" || true
last -a > "$Q/evidence/last.txt" || true
lastb -a > "$Q/evidence/lastb.txt" || true

crontab -l > "$Q/evidence/root_cron.txt" 2>&1 || true

for u in $(cut -d: -f1 /etc/passwd); do
  crontab -l -u "$u" > "$Q/evidence/cron_$u.txt" 2>/dev/null || true
done

echo "[+] Evidence saved to $Q/evidence"
echo

# ==============================
# 3. DETECT SUSPICIOUS PROCESSES
# ==============================
echo "[+] Checking suspicious processes"

SUSPICIOUS=$(ps aux | grep -E 'xmrig|kinsing|kdevtmpfsi|masscan|pnscan|miner|crypt' | grep -v grep || true)

if [[ -n "$SUSPICIOUS" ]]; then
    echo "⚠ Suspicious processes found:"
    echo "$SUSPICIOUS"
else
    echo "✔ No obvious malicious processes found"
fi
echo

# ==============================
# 4. SAFE CONTAINMENT (INTERACTIVE)
# ==============================
if [[ -n "$SUSPICIOUS" ]]; then
    echo "[!] Review above processes carefully."
    read -p "Kill suspicious processes? (y/N): " confirm

    if [[ "$confirm" == "y" ]]; then
        echo "$SUSPICIOUS" | awk '{print $2}' | while read pid; do
            echo "Killing PID: $pid"
            kill -9 "$pid" || true
        done
    else
        echo "[!] Skipping process termination"
    fi
fi
echo

# ==============================
# 5. SAFE FILE SCAN (NO AUTO DELETE)
# ==============================
echo "[+] Scanning for suspicious files"

find /root /tmp /var/tmp /dev/shm -xdev \
  \( -iname '*xmrig*' -o -iname '*kinsing*' -o -iname '*kdevtmpfsi*' \) \
  > "$Q/evidence/suspicious_files.txt" 2>/dev/null || true

if [[ -s "$Q/evidence/suspicious_files.txt" ]]; then
    echo "⚠ Suspicious files found:"
    cat "$Q/evidence/suspicious_files.txt"

    read -p "Move these files to quarantine? (y/N): " confirm
    if [[ "$confirm" == "y" ]]; then
        while read f; do
            dest="$Q/quarantine$(dirname "$f")"
            mkdir -p "$dest"
            mv "$f" "$dest/" 2>/dev/null || cp -a "$f" "$dest/"
        done < "$Q/evidence/suspicious_files.txt"
    fi
else
    echo "✔ No suspicious files found"
fi
echo

# ==============================
# 6. CRON CHECK (NO AUTO DISABLE)
# ==============================
echo "[+] Checking cron jobs"

grep -R "wget\|curl\|/tmp\|/dev/shm" /var/spool/cron /etc/cron* 2>/dev/null \
  > "$Q/evidence/suspicious_cron.txt" || true

if [[ -s "$Q/evidence/suspicious_cron.txt" ]]; then
    echo "⚠ Suspicious cron entries:"
    cat "$Q/evidence/suspicious_cron.txt"
else
    echo "✔ No suspicious cron jobs"
fi
echo

# ==============================
# 7. USER CHECK
# ==============================
echo "[+] Checking UID 0 users"
awk -F: '$3==0{print}' /etc/passwd | tee "$Q/evidence/uid0_users.txt"

echo "[+] Checking shell users"
awk -F: '$7 ~ /(bash|sh)$/ {print}' /etc/passwd > "$Q/evidence/shell_users.txt"
echo

# ==============================
# 8. SSH SAFETY CHECK (NO BREAKAGE)
# ==============================
echo "[+] Validating SSH config"
if sshd -t 2>/dev/null; then
    echo "✔ SSH config OK"
else
    echo "❌ SSH config INVALID — FIX BEFORE RESTART"
fi
echo

# ==============================
# 9. OPTIONAL FIREWALL LOCKDOWN
# ==============================
read -p "Block outgoing connections temporarily? (y/N): " fw

if [[ "$fw" == "y" ]]; then
    iptables -P OUTPUT DROP
    echo "⚠ Outgoing traffic blocked"
fi
echo

# ==============================
# DONE
# ==============================
echo "===== INCIDENT RESPONSE COMPLETE ====="
echo "All logs saved at: $Q"
