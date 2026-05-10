#!/bin/bash
# ============================================================
# Server Load Investigation Script
# Platform : AlmaLinux 8 + WHM/cPanel Shared Hosting
# Author   : Server Admin Tool
# Usage    : bash server_load_investigate.sh
#            bash server_load_investigate.sh --output /root/report.txt
# ============================================================

# ---------- Colors ----------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------- Output file (optional) ----------
OUTPUT_FILE=""
if [[ "$1" == "--output" && -n "$2" ]]; then
    OUTPUT_FILE="$2"
fi

# ---------- Helper: print + optionally tee to file ----------
log() {
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo -e "$@" | tee -a "$OUTPUT_FILE"
    else
        echo -e "$@"
    fi
}

section() {
    log "\n${CYAN}${BOLD}================================================================${NC}"
    log "${CYAN}${BOLD}  $1${NC}"
    log "${CYAN}${BOLD}================================================================${NC}"
}

warn() { log "${YELLOW}[!] $1${NC}"; }
alert() { log "${RED}[!!] ALERT: $1${NC}"; }
ok() { log "${GREEN}[OK] $1${NC}"; }

# ---------- Root check ----------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Please run this script as root.${NC}"
    exit 1
fi

# ---------- Init output file ----------
if [[ -n "$OUTPUT_FILE" ]]; then
    echo "" > "$OUTPUT_FILE"
    log "Report saved to: $OUTPUT_FILE"
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
log "\n${BOLD}Server Load Investigation Report — $TIMESTAMP${NC}"

# ============================================================
section "1. LOAD AVERAGE & UPTIME"
# ============================================================
UPTIME_OUT=$(uptime)
log "$UPTIME_OUT"

LOAD1=$(uptime | awk -F'load average:' '{print $2}' | cut -d',' -f1 | tr -d ' ')
CORES=$(nproc)
log "\nCPU Cores : $CORES"
log "Load (1m) : $LOAD1"

# Check if load is high relative to cores
LOAD_INT=$(echo "$LOAD1" | cut -d'.' -f1)
if (( LOAD_INT > CORES )); then
    alert "Load ($LOAD1) exceeds CPU core count ($CORES) — server is overloaded!"
elif (( LOAD_INT > CORES / 2 )); then
    warn "Load ($LOAD1) is moderately high for $CORES cores."
else
    ok "Load ($LOAD1) is normal for $CORES cores."
fi

# ============================================================
section "2. TOP CPU-CONSUMING PROCESSES"
# ============================================================
log "${BOLD}Top 15 processes by CPU usage:${NC}"
ps aux --sort=-%cpu | awk 'NR<=16 {printf "%-10s %-8s %-6s %-6s %s\n", $1,$2,$3,$4,$11}' | head -16

# ============================================================
section "3. TOP MEMORY-CONSUMING PROCESSES"
# ============================================================
log "${BOLD}Top 15 processes by Memory usage:${NC}"
ps aux --sort=-%mem | awk 'NR<=16 {printf "%-10s %-8s %-6s %-6s %s\n", $1,$2,$3,$4,$11}' | head -16

# ============================================================
section "4. PER-USER CPU & MEMORY USAGE (cPanel Accounts)"
# ============================================================
log "${BOLD}CPU & Memory per system user (top consumers):${NC}\n"
log "$(printf '%-20s %-10s %-10s %-10s\n' 'USER' 'CPU(%)' 'MEM(%)' 'PROCESSES')"
log "$(printf '%-20s %-10s %-10s %-10s\n' '----' '------' '------' '---------')"

ps aux --no-headers | awk '
{
    user=$1; cpu=$3; mem=$4
    user_cpu[user]  += cpu
    user_mem[user]  += mem
    user_proc[user] += 1
}
END {
    for (u in user_cpu)
        printf "%-20s %-10.1f %-10.1f %-10d\n", u, user_cpu[u], user_mem[u], user_proc[u]
}' | sort -k2 -rn | head -20

# ============================================================
section "5. PHP PROCESSES — WHICH USER IS RUNNING WHAT"
# ============================================================
log "${BOLD}Active PHP processes per user:${NC}\n"
PHP_COUNT=$(ps aux | grep -E 'php|php-fpm' | grep -v grep | wc -l)
log "Total PHP processes: $PHP_COUNT"

if [[ $PHP_COUNT -gt 0 ]]; then
    log "\n$(printf '%-15s %-8s %-6s %-6s %s\n' 'USER' 'PID' 'CPU' 'MEM' 'COMMAND')"
    ps aux | grep -E 'php|php-fpm' | grep -v grep | \
        awk '{printf "%-15s %-8s %-6s %-6s %s\n", $1,$2,$3,$4,$11}' | sort -k3 -rn | head -30

    # PHP per user summary
    log "\n${BOLD}PHP process count per user:${NC}"
    ps aux | grep -E 'php|php-fpm' | grep -v grep | awk '{print $1}' | sort | uniq -c | sort -rn
fi

# ============================================================
section "6. APACHE / HTTPD STATUS"
# ============================================================
APACHE_PROC=$(ps aux | grep -E 'httpd|apache2' | grep -v grep | wc -l)
log "Apache/httpd processes running: $APACHE_PROC"

# Apache connections
HTTP_CONN=$(ss -tn | grep ':80 ' | wc -l 2>/dev/null || netstat -an 2>/dev/null | grep ':80 ' | wc -l)
HTTPS_CONN=$(ss -tn | grep ':443 ' | wc -l 2>/dev/null || netstat -an 2>/dev/null | grep ':443 ' | wc -l)
log "Active HTTP  connections : $HTTP_CONN"
log "Active HTTPS connections : $HTTPS_CONN"

TOTAL_CONN=$((HTTP_CONN + HTTPS_CONN))
if (( TOTAL_CONN > 500 )); then
    alert "Very high connection count: $TOTAL_CONN — possible DDoS or traffic spike!"
elif (( TOTAL_CONN > 200 )); then
    warn "High connection count: $TOTAL_CONN"
else
    ok "Connection count looks normal: $TOTAL_CONN"
fi

# Apache status (if mod_status enabled)
if command -v apachectl &>/dev/null; then
    log "\n${BOLD}Apache workers summary:${NC}"
    apachectl status 2>/dev/null | grep -E 'requests|BusyWorkers|IdleWorkers' | head -5 || \
        log "(mod_status not enabled or localhost access required)"
fi

# ============================================================
section "7. MYSQL / MARIADB STATUS"
# ============================================================
if command -v mysqladmin &>/dev/null; then
    log "${BOLD}MySQL server status:${NC}"
    mysqladmin status 2>/dev/null || warn "Could not connect to MySQL (check credentials)"

    log "\n${BOLD}Current MySQL processlist (active queries):${NC}"
    mysql -e "SHOW FULL PROCESSLIST;" 2>/dev/null | grep -v "Sleep" | head -30 || \
        warn "Could not fetch processlist"

    log "\n${BOLD}MySQL connections count:${NC}"
    mysql -e "SHOW STATUS LIKE 'Threads_connected';" 2>/dev/null

    log "\n${BOLD}Slow query count (since last restart):${NC}"
    mysql -e "SHOW STATUS LIKE 'Slow_queries';" 2>/dev/null

    log "\n${BOLD}Top databases by size:${NC}"
    mysql -e "SELECT table_schema AS 'Database',
        ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
        FROM information_schema.tables
        GROUP BY table_schema
        ORDER BY SUM(data_length + index_length) DESC
        LIMIT 10;" 2>/dev/null
else
    warn "mysqladmin not found — skipping MySQL checks"
fi

# ============================================================
section "8. CRON JOBS RUNNING RIGHT NOW"
# ============================================================
log "${BOLD}Currently running cron-related processes:${NC}"
CRON_PROCS=$(ps aux | grep -E 'cron|CRON' | grep -v grep)
if [[ -n "$CRON_PROCS" ]]; then
    echo "$CRON_PROCS"
else
    ok "No heavy cron processes detected at this moment."
fi

# List cPanel user cron jobs
log "\n${BOLD}cPanel user crontabs (all accounts):${NC}"
if [[ -d /var/spool/cron ]]; then
    for cronfile in /var/spool/cron/*; do
        USER=$(basename "$cronfile")
        LINES=$(grep -v '^#' "$cronfile" 2>/dev/null | grep -v '^$' | wc -l)
        if [[ $LINES -gt 0 ]]; then
            log "\n  ${BOLD}User: $USER ($LINES active cron jobs)${NC}"
            grep -v '^#' "$cronfile" 2>/dev/null | grep -v '^$' | sed 's/^/    /'
        fi
    done
fi

# ============================================================
section "9. MAIL QUEUE (EXIM)"
# ============================================================
if command -v exim &>/dev/null; then
    QUEUE_COUNT=$(exim -bpc 2>/dev/null || echo "0")
    log "Exim mail queue size: $QUEUE_COUNT"

    if (( QUEUE_COUNT > 500 )); then
        alert "Mail queue is very large ($QUEUE_COUNT)! Possible spam or mail flood."
        log "\n${BOLD}Top senders in queue:${NC}"
        exim -bp 2>/dev/null | grep '<' | awk '{print $4}' | sort | uniq -c | sort -rn | head -10
    elif (( QUEUE_COUNT > 100 )); then
        warn "Mail queue is elevated: $QUEUE_COUNT messages"
    else
        ok "Mail queue is normal: $QUEUE_COUNT messages"
    fi
else
    warn "Exim not found — skipping mail queue check"
fi

# ============================================================
section "10. NETWORK CONNECTIONS — TOP IPs HITTING SERVER"
# ============================================================
log "${BOLD}Top 20 IPs by connection count:${NC}\n"
ss -tn 2>/dev/null | awk 'NR>1 {print $5}' | cut -d: -f1 | \
    grep -v '^$' | sort | uniq -c | sort -rn | head -20

# Check for potential brute force
log "\n${BOLD}IPs with >50 connections (possible DDoS/brute force):${NC}"
DDOS=$(ss -tn 2>/dev/null | awk 'NR>1 {print $5}' | cut -d: -f1 | \
    sort | uniq -c | sort -rn | awk '$1>50 {print}')
if [[ -n "$DDOS" ]]; then
    alert "High connection IPs detected:\n$DDOS"
else
    ok "No single IP with excessive connections."
fi

# ============================================================
section "11. DISK I/O USAGE"
# ============================================================
log "${BOLD}Disk usage per partition:${NC}"
df -hT | grep -v tmpfs | grep -v devtmpfs

# Check if iostat available
if command -v iostat &>/dev/null; then
    log "\n${BOLD}Disk I/O stats (1 sample):${NC}"
    iostat -xz 1 1 | grep -v '^$'
else
    warn "iostat not available. Install with: dnf install sysstat"
fi

# ============================================================
section "12. MEMORY USAGE"
# ============================================================
log "${BOLD}Memory overview:${NC}"
free -h

MEM_TOTAL=$(free | grep Mem | awk '{print $2}')
MEM_USED=$(free | grep Mem | awk '{print $3}')
MEM_PCT=$(( MEM_USED * 100 / MEM_TOTAL ))
log "\nMemory used: ${MEM_PCT}%"

if (( MEM_PCT > 90 )); then
    alert "Memory usage is critically high: ${MEM_PCT}%!"
elif (( MEM_PCT > 75 )); then
    warn "Memory usage is high: ${MEM_PCT}%"
else
    ok "Memory usage is acceptable: ${MEM_PCT}%"
fi

# Swap
SWAP_USED=$(free | grep Swap | awk '{print $3}')
if (( SWAP_USED > 0 )); then
    warn "Swap is being used: $(free -h | grep Swap | awk '{print $3}') — system may be under memory pressure."
else
    ok "No swap usage."
fi

# ============================================================
section "13. TOP WORDPRESS SITES (RESOURCE ABUSERS)"
# ============================================================
log "${BOLD}Scanning for WordPress installs under /home:${NC}\n"
WP_COUNT=0
while IFS= read -r -d '' wpconfig; do
    SITE_DIR=$(dirname "$wpconfig")
    SITE_USER=$(stat -c '%U' "$wpconfig")
    # Try to get domain from the path
    DOMAIN=$(echo "$SITE_DIR" | awk -F'/public_html' '{print $1}' | xargs basename)
    log "  User: ${SITE_USER} | Path: ${SITE_DIR}"
    WP_COUNT=$((WP_COUNT + 1))
done < <(find /home -maxdepth 5 -name "wp-config.php" -print0 2>/dev/null)

if (( WP_COUNT == 0 )); then
    log "  No WordPress installs found."
else
    log "\nTotal WordPress installs found: $WP_COUNT"
fi

# ============================================================
section "14. RECENT ERROR LOGS — TOP OFFENDERS"
# ============================================================
# Apache error log
APACHE_LOG="/usr/local/apache/logs/error_log"
if [[ -f "$APACHE_LOG" ]]; then
    log "${BOLD}Last 20 Apache errors:${NC}"
    tail -20 "$APACHE_LOG"
else
    warn "Apache error log not found at $APACHE_LOG"
fi

# PHP errors (search in home dirs)
log "\n${BOLD}Recent PHP fatal errors across accounts (last 50):${NC}"
find /home -maxdepth 5 -name "error_log" 2>/dev/null | while read -r errfile; do
    LINES=$(grep -c 'PHP Fatal\|PHP Parse\|PHP Warning' "$errfile" 2>/dev/null || echo 0)
    if (( LINES > 0 )); then
        OWNER=$(stat -c '%U' "$errfile")
        log "  [User: $OWNER] $errfile — $LINES PHP error lines"
        grep -E 'PHP Fatal|PHP Parse' "$errfile" 2>/dev/null | tail -3 | sed 's/^/    /'
    fi
done

# ============================================================
section "15. CSF/FIREWALL BLOCKED IPS (if CSF installed)"
# ============================================================
if command -v csf &>/dev/null; then
    BLOCKED=$(csf -l 2>/dev/null | wc -l)
    log "CSF currently has $BLOCKED blocked entries."
    log "\n${BOLD}Recent CSF blocks (last 10):${NC}"
    csf -l 2>/dev/null | tail -10
else
    warn "CSF firewall not installed or not in PATH."
fi

# ============================================================
section "16. SUMMARY & RECOMMENDATIONS"
# ============================================================
log "${BOLD}Quick Summary:${NC}\n"

# Load
log "  Load Average : $(uptime | awk -F'load average:' '{print $2}')"
log "  CPU Cores    : $CORES"
log "  Memory Used  : ${MEM_PCT}%"
log "  HTTP Conns   : $TOTAL_CONN"
log "  PHP Procs    : $PHP_COUNT"
[[ -n "$QUEUE_COUNT" ]] && log "  Mail Queue   : $QUEUE_COUNT"

log "\n${BOLD}Common Fixes:${NC}"
log "  1. High PHP procs   → Limit PHP-FPM pool size per user in WHM"
log "  2. MySQL slow        → Run: pt-query-digest /var/lib/mysql/slow.log"
log "  3. Mail queue flood  → Run: exim -bp | exiqsumm (find spam account)"
log "  4. WordPress abuse   → Install WP Toolkit in WHM, limit wp-cron.php"
log "  5. DDoS/brute force → Block IPs via CSF: csf -d <IP>"
log "  6. Disk I/O high     → Check with: iotop -ao"
log "  7. Memory full       → Check swap + tune Apache MaxRequestWorkers"

log "\n${GREEN}${BOLD}Investigation complete — $TIMESTAMP${NC}"
[[ -n "$OUTPUT_FILE" ]] && log "\n${GREEN}Full report saved to: $OUTPUT_FILE${NC}"
