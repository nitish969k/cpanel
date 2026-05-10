#!/bin/bash
# ============================================================
# Server Load Investigation Script
# Platform : AlmaLinux 8 + WHM/cPanel Shared Hosting
# Mode     : Silent collection → Summary on screen + Full report file
# Usage    : bash server_load_investigate.sh
#            bash server_load_investigate.sh --output /root/report.txt
# ============================================================

# ---------- Colors (screen only) ----------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- Report file ----------
REPORT_FILE="/root/load_report_$(date '+%Y%m%d_%H%M%S').txt"
# Allow custom path via --output flag
if [[ "$1" == "--output" && -n "$2" ]]; then
    REPORT_FILE="$2"
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME_VAL=$(hostname)

# ---------- Root check ----------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Please run this script as root.${NC}"
    exit 1
fi

# ---------- Silent report writer (no screen output) ----------
rpt() { echo -e "$@" >> "$REPORT_FILE"; }

# ---------- Screen summary helpers ----------
sum_ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
sum_warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
sum_alert(){ echo -e "  ${RED}✘${NC}  ${BOLD}$1${NC}"; }
sum_info() { echo -e "     $1"; }

# ---------- Init report file ----------
> "$REPORT_FILE"
rpt "================================================================"
rpt "  SERVER LOAD INVESTIGATION REPORT"
rpt "  Generated : $TIMESTAMP"
rpt "  Host      : $HOSTNAME_VAL"
rpt "================================================================"

# ---------- Progress indicator ----------
show_progress() { echo -ne "  ${CYAN}Investigating${NC} $1 ...\r"; }
clear_progress() { echo -ne "\033[2K"; }

# ============================================================
# SILENT DATA COLLECTION
# ============================================================

# ---- 1. Load & CPU ----
show_progress "load average"
CORES=$(nproc)
LOAD_RAW=$(uptime)
LOAD1=$(echo "$LOAD_RAW"  | awk -F'load average:' '{print $2}' | cut -d',' -f1 | tr -d ' ')
LOAD5=$(echo "$LOAD_RAW"  | awk -F'load average:' '{print $2}' | cut -d',' -f2 | tr -d ' ')
LOAD15=$(echo "$LOAD_RAW" | awk -F'load average:' '{print $2}' | cut -d',' -f3 | tr -d ' ')
LOAD_INT=$(echo "$LOAD1" | cut -d'.' -f1)
LOAD_INT=${LOAD_INT:-0}
UPTIME_SINCE=$(uptime -s 2>/dev/null || echo "N/A")

rpt ""
rpt "================================================================"
rpt "  1. LOAD AVERAGE & UPTIME"
rpt "================================================================"
rpt "Uptime since    : $UPTIME_SINCE"
rpt "Raw uptime      : $LOAD_RAW"
rpt "CPU Cores       : $CORES"
rpt "Load 1m/5m/15m  : $LOAD1 / $LOAD5 / $LOAD15"

# ---- 2. Top CPU processes ----
show_progress "CPU processes"
TOP_CPU=$(ps aux --sort=-%cpu --no-headers | awk 'NR<=20 {printf "%-15s %-7s %-6s %-6s %s\n", $1,$2,$3,$4,$11}')

rpt ""
rpt "================================================================"
rpt "  2. TOP CPU-CONSUMING PROCESSES"
rpt "================================================================"
rpt "$(printf '%-15s %-7s %-6s %-6s %s\n' 'USER' 'PID' 'CPU%' 'MEM%' 'COMMAND')"
rpt "$TOP_CPU"

# ---- 3. Top memory processes ----
show_progress "memory processes"
TOP_MEM=$(ps aux --sort=-%mem --no-headers | awk 'NR<=20 {printf "%-15s %-7s %-6s %-6s %s\n", $1,$2,$3,$4,$11}')

rpt ""
rpt "================================================================"
rpt "  3. TOP MEMORY-CONSUMING PROCESSES"
rpt "================================================================"
rpt "$(printf '%-15s %-7s %-6s %-6s %s\n' 'USER' 'PID' 'CPU%' 'MEM%' 'COMMAND')"
rpt "$TOP_MEM"

# ---- 4. Per-user resource usage ----
show_progress "per-user CPU & memory"
USER_STATS=$(ps aux --no-headers | awk '
{
    user=$1; cpu=$3; mem=$4
    user_cpu[user]  += cpu
    user_mem[user]  += mem
    user_proc[user] += 1
}
END {
    for (u in user_cpu)
        printf "%-20s %-10.1f %-10.1f %-10d\n", u, user_cpu[u], user_mem[u], user_proc[u]
}' | sort -k2 -rn | head -20)

# Capture top offender for summary
TOP_USER=$(echo "$USER_STATS" | head -1 | awk '{print $1}')
TOP_USER_CPU=$(echo "$USER_STATS" | head -1 | awk '{print $2}')
TOP_USER_MEM=$(echo "$USER_STATS" | head -1 | awk '{print $3}')

rpt ""
rpt "================================================================"
rpt "  4. PER-USER CPU & MEMORY USAGE (cPanel Accounts)"
rpt "================================================================"
rpt "$(printf '%-20s %-10s %-10s %-10s\n' 'USER' 'CPU(%)' 'MEM(%)' 'PROCESSES')"
rpt "$(printf '%-20s %-10s %-10s %-10s\n' '----' '------' '------' '---------')"
rpt "$USER_STATS"

# ---- 5. PHP processes ----
show_progress "PHP processes"
PHP_COUNT=$(ps aux | grep -E 'php|php-fpm' | grep -v grep | wc -l)
PHP_DETAIL=$(ps aux | grep -E 'php|php-fpm' | grep -v grep | \
    awk '{printf "%-15s %-8s %-6s %-6s %s\n", $1,$2,$3,$4,$11}' | sort -k3 -rn | head -30)
PHP_PER_USER=$(ps aux | grep -E 'php|php-fpm' | grep -v grep | \
    awk '{print $1}' | sort | uniq -c | sort -rn)
TOP_PHP_USER=$(echo "$PHP_PER_USER" | head -1)

rpt ""
rpt "================================================================"
rpt "  5. PHP PROCESSES"
rpt "================================================================"
rpt "Total PHP processes : $PHP_COUNT"
rpt ""
rpt "PHP process count per user:"
rpt "$PHP_PER_USER"
rpt ""
rpt "Detailed PHP process list:"
rpt "$(printf '%-15s %-8s %-6s %-6s %s\n' 'USER' 'PID' 'CPU%' 'MEM%' 'COMMAND')"
rpt "$PHP_DETAIL"

# ---- 6. Apache ----
show_progress "Apache connections"
APACHE_PROC=$(ps aux | grep -E 'httpd|apache2' | grep -v grep | wc -l)
HTTP_CONN=$(ss -tn 2>/dev/null | grep -c ':80 ' || echo 0)
HTTPS_CONN=$(ss -tn 2>/dev/null | grep -c ':443 ' || echo 0)
# Sanitize to plain integers
HTTP_CONN=$(echo "$HTTP_CONN" | grep -oP '^\d+' || echo 0)
HTTPS_CONN=$(echo "$HTTPS_CONN" | grep -oP '^\d+' || echo 0)
HTTP_CONN=${HTTP_CONN:-0}
HTTPS_CONN=${HTTPS_CONN:-0}
TOTAL_CONN=$((HTTP_CONN + HTTPS_CONN))

rpt ""
rpt "================================================================"
rpt "  6. APACHE / HTTPD STATUS"
rpt "================================================================"
rpt "Apache worker processes : $APACHE_PROC"
rpt "HTTP  connections       : $HTTP_CONN"
rpt "HTTPS connections       : $HTTPS_CONN"
rpt "Total connections       : $TOTAL_CONN"

# ---- 7. MySQL ----
show_progress "MySQL status"
MYSQL_STATUS=""
MYSQL_THREADS=""
MYSQL_SLOW=""
MYSQL_PROCESSLIST=""
MYSQL_DB_SIZES=""
if command -v mysqladmin &>/dev/null; then
    MYSQL_STATUS=$(mysqladmin status 2>/dev/null)
    MYSQL_THREADS=$(mysql -e "SHOW STATUS LIKE 'Threads_connected';" 2>/dev/null | tail -1)
    MYSQL_SLOW=$(mysql -e "SHOW STATUS LIKE 'Slow_queries';" 2>/dev/null | tail -1)
    MYSQL_PROCESSLIST=$(mysql -e "SHOW FULL PROCESSLIST;" 2>/dev/null | grep -v "Sleep" | head -30)
    MYSQL_DB_SIZES=$(mysql -e "SELECT table_schema AS 'Database',
        ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size_MB'
        FROM information_schema.tables
        GROUP BY table_schema
        ORDER BY SUM(data_length + index_length) DESC
        LIMIT 10;" 2>/dev/null)
fi

rpt ""
rpt "================================================================"
rpt "  7. MYSQL / MARIADB STATUS"
rpt "================================================================"
if [[ -n "$MYSQL_STATUS" ]]; then
    rpt "$MYSQL_STATUS"
    rpt ""
    rpt "Threads connected : $MYSQL_THREADS"
    rpt "Slow queries      : $MYSQL_SLOW"
    rpt ""
    rpt "Active queries (non-sleep processlist):"
    rpt "${MYSQL_PROCESSLIST:-(none)}"
    rpt ""
    rpt "Top databases by size:"
    rpt "$MYSQL_DB_SIZES"
else
    rpt "MySQL not accessible or mysqladmin not found."
fi

# Extract slow query count for summary — strip to plain integer safely
SLOW_Q_COUNT=$(echo "$MYSQL_SLOW" | awk '{print $2}' | tr -d '[:space:]')
SLOW_Q_COUNT=${SLOW_Q_COUNT:-0}

# ---- 8. Cron jobs ----
show_progress "cron jobs"
CRON_RUNNING=$(ps aux | grep -E 'cron|CRON' | grep -v grep)
CRON_USER_LIST=""
if [[ -d /var/spool/cron ]]; then
    for cronfile in /var/spool/cron/*; do
        [[ -f "$cronfile" ]] || continue
        CRON_USER=$(basename "$cronfile")
        CRON_LINES=$(grep -v '^#' "$cronfile" 2>/dev/null | grep -v '^$' | wc -l)
        CRON_LINES=${CRON_LINES:-0}
        if (( CRON_LINES > 0 )); then
            CRON_USER_LIST+="  User: $CRON_USER ($CRON_LINES active jobs)\n"
            CRON_USER_LIST+="$(grep -v '^#' "$cronfile" 2>/dev/null | grep -v '^$' | sed 's/^/    /')\n"
        fi
    done
fi

rpt ""
rpt "================================================================"
rpt "  8. CRON JOBS"
rpt "================================================================"
rpt "Currently running cron processes:"
rpt "${CRON_RUNNING:-(none running right now)}"
rpt ""
rpt "User crontabs:"
rpt "${CRON_USER_LIST:-(no user crontabs found)}"

# ---- 9. Mail queue ----
show_progress "Exim mail queue"
QUEUE_COUNT=0
QUEUE_TOP_SENDERS=""
if command -v exim &>/dev/null; then
    QUEUE_COUNT=$(exim -bpc 2>/dev/null || echo 0)
    QUEUE_COUNT=$(echo "$QUEUE_COUNT" | grep -oP '^\d+' || echo 0)
    QUEUE_COUNT=${QUEUE_COUNT:-0}
    if (( QUEUE_COUNT > 100 )); then
        QUEUE_TOP_SENDERS=$(exim -bp 2>/dev/null | grep '<' | \
            awk '{print $4}' | sort | uniq -c | sort -rn | head -10)
    fi
fi

rpt ""
rpt "================================================================"
rpt "  9. MAIL QUEUE (EXIM)"
rpt "================================================================"
rpt "Queue size : $QUEUE_COUNT"
if [[ -n "$QUEUE_TOP_SENDERS" ]]; then
    rpt ""
    rpt "Top senders in queue:"
    rpt "$QUEUE_TOP_SENDERS"
fi

# ---- 10. Network / IPs ----
show_progress "network connections"
TOP_IPS=$(ss -tn 2>/dev/null | awk 'NR>1 {print $5}' | \
    grep -oP '^\d+\.\d+\.\d+\.\d+' | sort | uniq -c | sort -rn | head -20)
DDOS_IPS=$(echo "$TOP_IPS" | awk '$1>50 {print}')

rpt ""
rpt "================================================================"
rpt "  10. NETWORK — TOP IPs BY CONNECTION COUNT"
rpt "================================================================"
rpt "$(printf '%-8s %s\n' 'COUNT' 'IP')"
rpt "${TOP_IPS:-(no connections found)}"
rpt ""
rpt "IPs with >50 connections (DDoS/brute-force risk):"
rpt "${DDOS_IPS:-(none)}"

# ---- 11. Disk ----
show_progress "disk usage & I/O"
DISK_USAGE=$(df -hT | grep -v tmpfs | grep -v devtmpfs)
DISK_IO=""
if command -v iostat &>/dev/null; then
    DISK_IO=$(iostat -xz 1 1 2>/dev/null | grep -v '^$')
fi
# Any partition over 85% full
DISK_WARN=$(df -h | awk 'NR>1 && $5+0 > 85 {print $0}')

rpt ""
rpt "================================================================"
rpt "  11. DISK USAGE"
rpt "================================================================"
rpt "$DISK_USAGE"
if [[ -n "$DISK_IO" ]]; then
    rpt ""
    rpt "Disk I/O stats (iostat):"
    rpt "$DISK_IO"
fi

# ---- 12. Memory ----
show_progress "memory & swap"
MEM_FREE=$(free -h)
MEM_TOTAL=$(free | grep Mem | awk '{print $2}')
MEM_USED=$(free  | grep Mem | awk '{print $3}')
MEM_TOTAL=${MEM_TOTAL:-1}
MEM_PCT=$(( MEM_USED * 100 / MEM_TOTAL ))
SWAP_TOTAL=$(free | grep Swap | awk '{print $2}')
SWAP_USED=$(free  | grep Swap | awk '{print $3}')
SWAP_TOTAL=${SWAP_TOTAL:-0}
SWAP_USED=${SWAP_USED:-0}
SWAP_PCT=0
if (( SWAP_TOTAL > 0 )); then
    SWAP_PCT=$(( SWAP_USED * 100 / SWAP_TOTAL ))
fi

rpt ""
rpt "================================================================"
rpt "  12. MEMORY & SWAP"
rpt "================================================================"
rpt "$MEM_FREE"
rpt ""
rpt "Memory used : ${MEM_PCT}%"
rpt "Swap used   : ${SWAP_PCT}% (${SWAP_USED} KB of ${SWAP_TOTAL} KB)"

# ---- 13. WordPress sites ----
show_progress "WordPress installs"
WP_LIST=""
WP_COUNT=0
while IFS= read -r -d '' wpconfig; do
    SITE_DIR=$(dirname "$wpconfig")
    SITE_USER=$(stat -c '%U' "$wpconfig")
    WP_LIST+="  User: $SITE_USER | Path: $SITE_DIR\n"
    WP_COUNT=$((WP_COUNT + 1))
done < <(find /home -maxdepth 5 -name "wp-config.php" -print0 2>/dev/null)

rpt ""
rpt "================================================================"
rpt "  13. WORDPRESS INSTALLS"
rpt "================================================================"
rpt "Total found: $WP_COUNT"
rpt "${WP_LIST:-(none found)}"

# ---- 14. Error logs ----
show_progress "error logs"
APACHE_LOG="/usr/local/apache/logs/error_log"
APACHE_ERRORS=""
if [[ -f "$APACHE_LOG" ]]; then
    APACHE_ERRORS=$(tail -30 "$APACHE_LOG" 2>/dev/null)
fi

# FIX: grep -c can return "0\n0\n0" across multiple files in a subshell.
# We read line-by-line and sanitize ERR_LINES to a plain integer before (( )).
PHP_ERROR_SUMMARY=""
while IFS= read -r errfile; do
    ERR_LINES=$(grep -c 'PHP Fatal\|PHP Parse\|PHP Warning' "$errfile" 2>/dev/null)
    # Strip everything except digits; default to 0 if empty
    ERR_LINES="${ERR_LINES//[^0-9]/}"
    ERR_LINES="${ERR_LINES:-0}"
    if (( ERR_LINES > 0 )); then
        OWNER=$(stat -c '%U' "$errfile")
        PHP_ERROR_SUMMARY+="  [User: $OWNER] $errfile — $ERR_LINES error lines\n"
        PHP_ERROR_SUMMARY+="$(grep -E 'PHP Fatal|PHP Parse' "$errfile" 2>/dev/null | tail -3 | sed 's/^/    /')\n"
    fi
done < <(find /home -maxdepth 5 -name "error_log" 2>/dev/null)

rpt ""
rpt "================================================================"
rpt "  14. ERROR LOGS"
rpt "================================================================"
rpt "Apache error log (last 30 lines):"
rpt "${APACHE_ERRORS:-(log not found at $APACHE_LOG)}"
rpt ""
rpt "PHP errors across accounts:"
rpt "${PHP_ERROR_SUMMARY:-(none found)}"

# ---- 15. CSF firewall ----
show_progress "CSF firewall"
CSF_COUNT=0
CSF_BLOCKED=""
if command -v csf &>/dev/null; then
    CSF_COUNT=$(csf -l 2>/dev/null | wc -l)
    CSF_COUNT=${CSF_COUNT:-0}
    CSF_BLOCKED=$(csf -l 2>/dev/null | tail -15)
fi

rpt ""
rpt "================================================================"
rpt "  15. CSF FIREWALL"
rpt "================================================================"
if command -v csf &>/dev/null; then
    rpt "Total blocked entries : $CSF_COUNT"
    rpt ""
    rpt "Recent blocks (last 15):"
    rpt "$CSF_BLOCKED"
else
    rpt "CSF not installed."
fi

# ---- Recommendations ----
rpt ""
rpt "================================================================"
rpt "  16. RECOMMENDATIONS"
rpt "================================================================"
rpt "  1. High PHP procs    -> Limit PHP-FPM pool size per user in WHM"
rpt "  2. MySQL slow        -> Run: pt-query-digest /var/lib/mysql/slow.log"
rpt "  3. Mail queue flood  -> Run: exim -bp | exiqsumm"
rpt "  4. WordPress abuse   -> Disable wp-cron.php, use system cron instead"
rpt "  5. DDoS/brute force  -> Block IPs via CSF: csf -d <IP>"
rpt "  6. Disk I/O high     -> Check with: iotop -ao"
rpt "  7. Memory pressure   -> Tune Apache MaxRequestWorkers in WHM"
rpt ""
rpt "================================================================"
rpt "  END OF REPORT — $TIMESTAMP"
rpt "================================================================"

# ============================================================
# SCREEN — CLEAN SUMMARY ONLY
# ============================================================
clear_progress
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║         SERVER LOAD INVESTIGATION — SUMMARY                 ║${NC}"
# FIX: pre-compute hostname length — bash does not support ${#$(cmd)} inline
_HOST="${HOSTNAME_VAL:0:30}"
_HLEN=${#_HOST}
_PAD=$(( 30 - _HLEN ))
echo -e "${CYAN}${BOLD}║         Host: ${_HOST}$(printf '%*s' $_PAD '')         ║${NC}"
echo -e "${CYAN}${BOLD}║         ${TIMESTAMP}                       ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Load
echo -e "${BOLD}  LOAD & CPU${NC}"
if (( LOAD_INT > CORES )); then
    sum_alert "Load ${LOAD1} / ${LOAD5} / ${LOAD15}  <-  OVERLOADED! ($CORES cores)"
elif (( LOAD_INT > CORES / 2 )); then
    sum_warn  "Load ${LOAD1} / ${LOAD5} / ${LOAD15}  <-  Elevated ($CORES cores)"
else
    sum_ok    "Load ${LOAD1} / ${LOAD5} / ${LOAD15}  <-  Normal ($CORES cores)"
fi

# Top user
echo ""
echo -e "${BOLD}  TOP RESOURCE USER${NC}"
if [[ -n "$TOP_USER" ]]; then
    sum_info "${BOLD}${TOP_USER}${NC}  ->  CPU: ${TOP_USER_CPU}%   MEM: ${TOP_USER_MEM}%"
fi

# PHP
echo ""
echo -e "${BOLD}  PHP PROCESSES${NC}"
if (( PHP_COUNT > 50 )); then
    sum_alert "$PHP_COUNT PHP processes — very high!"
elif (( PHP_COUNT > 20 )); then
    sum_warn  "$PHP_COUNT PHP processes — elevated"
else
    sum_ok    "$PHP_COUNT PHP processes"
fi
[[ -n "$TOP_PHP_USER" ]] && sum_info "Top PHP user: ${TOP_PHP_USER}"

# Memory
echo ""
echo -e "${BOLD}  MEMORY${NC}"
if (( MEM_PCT > 90 )); then
    sum_alert "RAM: ${MEM_PCT}% used — CRITICAL"
elif (( MEM_PCT > 75 )); then
    sum_warn  "RAM: ${MEM_PCT}% used — High"
else
    sum_ok    "RAM: ${MEM_PCT}% used"
fi
if (( SWAP_PCT > 0 )); then
    sum_warn  "Swap: ${SWAP_PCT}% in use — memory pressure"
else
    sum_ok    "Swap: not in use"
fi

# Apache
echo ""
echo -e "${BOLD}  APACHE${NC}"
if (( TOTAL_CONN > 500 )); then
    sum_alert "Connections: $TOTAL_CONN — possible DDoS!"
elif (( TOTAL_CONN > 200 )); then
    sum_warn  "Connections: $TOTAL_CONN — elevated"
else
    sum_ok    "Connections: $TOTAL_CONN (HTTP: $HTTP_CONN  HTTPS: $HTTPS_CONN)"
fi
sum_info "Worker processes: $APACHE_PROC"

# MySQL
echo ""
echo -e "${BOLD}  MYSQL${NC}"
if [[ -n "$MYSQL_STATUS" ]]; then
    if [[ "$SLOW_Q_COUNT" =~ ^[0-9]+$ ]] && (( SLOW_Q_COUNT > 100 )); then
        sum_warn "Slow queries since restart: $SLOW_Q_COUNT"
    else
        sum_ok   "Reachable. Slow queries: ${SLOW_Q_COUNT:-N/A}"
    fi
else
    sum_warn "Not accessible — check /root/.my.cnf"
fi

# Mail queue
echo ""
echo -e "${BOLD}  MAIL QUEUE (EXIM)${NC}"
if (( QUEUE_COUNT > 500 )); then
    sum_alert "Queue: $QUEUE_COUNT messages — spam flood likely!"
elif (( QUEUE_COUNT > 100 )); then
    sum_warn  "Queue: $QUEUE_COUNT messages — elevated"
else
    sum_ok    "Queue: $QUEUE_COUNT messages"
fi

# Network
echo ""
echo -e "${BOLD}  NETWORK${NC}"
if [[ -n "$DDOS_IPS" ]]; then
    sum_alert "IPs with >50 connections (DDoS/brute-force risk):"
    echo "$DDOS_IPS" | while read -r line; do sum_info "$line"; done
else
    sum_ok "No IP with excessive connections"
fi

# Disk
echo ""
echo -e "${BOLD}  DISK${NC}"
if [[ -n "$DISK_WARN" ]]; then
    sum_warn "Partitions over 85% full:"
    echo "$DISK_WARN" | while read -r line; do sum_info "$line"; done
else
    sum_ok "All partitions below 85%"
fi

# WordPress
echo ""
echo -e "${BOLD}  WORDPRESS${NC}"
sum_info "Installs found: $WP_COUNT"

# CSF
echo ""
echo -e "${BOLD}  CSF FIREWALL${NC}"
if command -v csf &>/dev/null; then
    sum_info "Blocked entries: $CSF_COUNT"
else
    sum_info "CSF not installed"
fi

# Report location
echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}Full report saved to:${NC}"
echo -e "  ${GREEN}${REPORT_FILE}${NC}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""
