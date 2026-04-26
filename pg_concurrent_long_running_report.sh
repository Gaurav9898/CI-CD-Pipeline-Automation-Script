#!/bin/bash
# ======================================================
# PostgreSQL Concurrent & Long Running Query HTML Report
# ======================================================

set -e

# -----------------------
# PostgreSQL
# -----------------------
PGHOST="localhost"
PGPORT="5432"
PGUSER="rsoftnetmanager"
PGDB="postgres"

# -----------------------
# Paths
# -----------------------
BASE_DIR="$HOME/scripts"
REPORT_DIR="$HOME/reports"
HTML_REPORT="$REPORT_DIR/concurrent_query_report.html"
LOG_REPORT="$REPORT_DIR/pg_concurrent_long_running_report_log.txt"
MSMTP_LOG="$BASE_DIR/msmtp_pg_concurrent.log"

mkdir -p "$BASE_DIR"
mkdir -p "$REPORT_DIR"
touch "$LOG_REPORT"
chmod 640 "$LOG_REPORT"
# -----------------------
# Email
# -----------------------
SMTP_SERVER="smtp.zeptomail.in"
SMTP_PORT=587
EMAIL_FROM="helpdesk@relipay.net"
EMAIL_TO="umesh.lakhani@reliablesoft.co.in"
EMAIL_CC1="hardik.trivedi@reliablesoft.co.in"
EMAIL_CC2="engineering@reliablesoft.co.in"
SMTP_PASS="PHtE6r1ZEe3jimUq9BRSsfSwR8CgZIh79ONnLwFO5IhCWaUCHk0Gr4x6x2W3rhgoBqNHRfHNmolq4LzJu+3UJmfrNT5FDWqyqK3sx/VYSPOZsbq6x00VsV4Sc0LbVYLvdtZv0S3VudbSNA=="
SUBJECT="Monitoring - Concurrent & Long Running Queries"

# -----------------------
# Query
# -----------------------

QUERY=$(cat <<'EOF'
WITH active AS (
    SELECT
        pid,
        datname,
        usename,
        now() - query_start AS duration,
        query
    FROM pg_stat_activity
    WHERE state = 'active'
     AND backend_type <> 'walsender'
     AND query IS NOT NULL
     AND query <> ''
     AND query NOT ILIKE 'START_REPLICATION%'
     AND query NOT ILIKE '%pg_stat_activity%'
     AND query NOT ILIKE '%pg_stat_statements%'
     AND query NOT ILIKE '%pg_catalog%'
     AND query NOT ILIKE '%information_schema%'
     AND query NOT ILIKE 'SET %'
     AND query NOT ILIKE 'SHOW %'
     AND query NOT ILIKE 'BEGIN%'
     AND query NOT ILIKE 'COMMIT%'
     AND query NOT ILIKE 'ROLLBACK%'
)
SELECT
    (SELECT count(*) FROM active) AS total_active,
    pid,
    datname,
    usename,
    EXTRACT(EPOCH FROM duration)::int AS duration_sec,
    LEFT(regexp_replace(query, '\s+', ' ', 'g'), 500) AS query
FROM active
ORDER BY duration DESC;
EOF
)

RESULTS=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" \
  -A -t -F $'\t' -c "$QUERY")

TOTAL_ACTIVE=$(echo "$RESULTS" | head -n1 | cut -f1)

# Default to 0 if empty
if ! [[ "$TOTAL_ACTIVE" =~ ^[0-9]+$ ]]; then
  TOTAL_ACTIVE=0
fi

if [ "$TOTAL_ACTIVE" -ge 25 ]; then
  CONCURRENCY_ALERT="YES"
  CONCURRENCY_COLOR="#e74c3c"
else
  CONCURRENCY_ALERT="NO"
  CONCURRENCY_COLOR="#2ecc71"
fi

{
  echo "===================================================="
  echo "Run Time        : $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Total Active    : $TOTAL_ACTIVE"
  echo "Concurrency>=25 : $CONCURRENCY_ALERT"
} >> "$LOG_REPORT"

# -----------------------
# Build HTML
# -----------------------
SEND_MAIL=0
LONG_RUNNING_FOUND=0

if [ "$TOTAL_ACTIVE" -gt 0 ] && \
   { [ "$TOTAL_ACTIVE" -ge "$CONCURRENT_THRESHOLD" ] || [ "$LONG_RUNNING_FOUND" -eq 1 ]; }
then
    SEND_MAIL=1
fi

[ "$SEND_MAIL" -eq 0 ] && exit 0

{
cat <<HTML
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
</head>
<body>

<h4>Dear Team,</h4>

<h4 style="font-family:Trebuchet MS;">
Current PostgreSQL Active Query Snapshot
</h4>

<p><b>Total Active Queries:</b> $TOTAL_ACTIVE</p>
<p>
<b>Concurrency Alert (>=25):</b>
<span style="color:white;background:$CONCURRENCY_COLOR;padding:4px 8px;">
$CONCURRENCY_ALERT
</span>
</p>

<br>

<table style="font-family:Trebuchet MS,Arial,Helvetica,sans-serif;
              border-collapse:collapse;width:95%;">

<tr>
<th style="background:#0e72c3;color:white;border:1px solid #ddd;padding:10px;">PID</th>
<th style="background:#0e72c3;color:white;border:1px solid #ddd;padding:10px;">Database</th>
<th style="background:#0e72c3;color:white;border:1px solid #ddd;padding:10px;">User</th>
<th style="background:#0e72c3;color:white;border:1px solid #ddd;padding:10px;">Duration (sec)</th>
<th style="background:#0e72c3;color:white;border:1px solid #ddd;padding:10px;">> 5 mins</th>
<th style="background:#0e72c3;color:white;border:1px solid #ddd;padding:10px;">Query</th>
</tr>
HTML

tail -n +2 <<< "$RESULTS" | while IFS=$'\t' read -r TOTAL PID DB USER DURATION SQL; do

  if [[ "$DURATION" =~ ^[0-9]+$ ]] && [ "$DURATION" -ge 300 ]; then
    F5="YES"
    COLOR="#e74c3c"
  else
    F5="NO"
    COLOR="#2ecc71"
  fi

  {
    echo "PID=$PID | DB=$DB | USER=$USER | DURATION=${DURATION}s | >5min=$F5"
    echo "QUERY: $SQL"
    echo "----------------------------------------------------"
  } >> "$LOG_REPORT"

cat <<HTML
<tr>
<td style="border:1px solid #ddd;padding:8px;text-align:center;">$PID</td>
<td style="border:1px solid #ddd;padding:8px;text-align:center;">$DB</td>
<td style="border:1px solid #ddd;padding:8px;text-align:center;">$USER</td>
<td style="border:1px solid #ddd;padding:8px;text-align:center;">$DURATION</td>
<td style="border:1px solid #ddd;padding:8px;color:white;background:$COLOR;text-align:center;">$F5</td>
<td style="border:1px solid #ddd;padding:8px;font-family:monospace;">$SQL</td>
</tr>
HTML

done

cat <<'HTML'
</table>

<br>
<p>This is an automated monitoring alert. Please review and take action if required.</p>

</body>
</html>
HTML
} > "$HTML_REPORT"

# -----------------------
# msmtp
# -----------------------
MSMTP_CONF=$(mktemp)
chmod 600 "$MSMTP_CONF"

cat > "$MSMTP_CONF" <<EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        $LOG_PATH

account zeptomail
host           $SMTP_SERVER
port           $SMTP_PORT
from           $EMAIL_FROM
user           $EMAIL_FROM
password       $SMTP_PASS

account default : zeptomail
EOF

{
  echo "From: $EMAIL_FROM"
  echo "To: $EMAIL_TO"
  echo "Cc: $EMAIL_CC1, $EMAIL_CC2"
  echo "Subject: $SUBJECT"
  echo "MIME-Version: 1.0"
  echo "Content-Type: text/html; charset=UTF-8"
  echo ""
  cat "$HTML_REPORT"
} | msmtp --file="$MSMTP_CONF" "$EMAIL_TO" "$EMAIL_CC1" "$EMAIL_CC2"