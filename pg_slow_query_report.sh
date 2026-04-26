#!/bin/bash
# ======================================================
# PostgreSQL Slow Query HTML Report (Single Table)
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
HTML_REPORT="$REPORT_DIR/slow_query_report.html"
SLOW_LOG="$REPORT_DIR/pg_slow_query_report_log.txt"

mkdir -p "$BASE_DIR"
mkdir -p "$REPORT_DIR"
touch "$SLOW_LOG"
chmod 640 "$SLOW_LOG"
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
SUBJECT="Daily PostgreSQL Expensive Query Report"

# -----------------------
# Verify extension
# -----------------------
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" \
  -c "SELECT 1 FROM pg_stat_statements LIMIT 1;" &>/dev/null

# -----------------------
# Query
# -----------------------
QUERY=$(cat <<'EOF'
SELECT
    d.datname,
    s.calls,
    ROUND(s.mean_exec_time::numeric, 2) AS avg_ms,
    ROUND(s.total_exec_time::numeric, 2) AS total_ms,
    CASE
        WHEN s.mean_exec_time > 5000 THEN 'CRITICAL'
        WHEN s.mean_exec_time > 1000 THEN 'EXPENSIVE'
        ELSE 'SLOW'
    END AS severity,
    LEFT(
        regexp_replace(s.query, '\s+', ' ', 'g'),
        500
    ) AS query
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid
WHERE
    s.mean_exec_time > 200
    AND s.calls >= 1
    AND s.total_exec_time > 500
    AND s.query NOT ILIKE '%pg_stat_statements%'
    AND s.query NOT ILIKE '%pg_catalog%'
    AND s.query NOT ILIKE 'SET %'
    AND s.query NOT ILIKE 'SHOW %'
ORDER BY s.total_exec_time DESC
LIMIT 10;
EOF
)

RESULTS=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" \
  -A -t -F $'\t' -c "$QUERY")

TOTAL_ROWS=$(echo "$RESULTS" | sed '/^\s*$/d' | wc -l)

{
  echo "===================================================="
  echo "Run Time      : $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Total Queries : $TOTAL_ROWS"
} >> "$SLOW_LOG"

if [ "$TOTAL_ROWS" -eq 0 ]; then
  echo "No slow queries detected. Skipping email."
  exit 0
fi
# -----------------------
# Build HTML
# -----------------------
{
cat <<'HTML'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
</head>
<body>

<h4>Dear Team,</h4>

<h4 style="font-family: Trebuchet MS;">
Below are the Current DB Snapshot :-
</h4>

<br>

<table style="font-family:Trebuchet MS,Arial,Helvetica,sans-serif;
              border-collapse:collapse;width:95%;">

<tr>
<th style="background:#0e72c3;color:white;border:1px solid #ddd;padding:10px;">Database</th>
<th style="background:#0e72c3;color:white;border:1px solid #ddd;padding:10px;">Severity</th>
<th style="background:#0e72c3;color:white;border:1px solid #ddd;padding:10px;">Avg Time (ms)</th>
<th style="background:#0e72c3;color:white;border:1px solid #ddd;padding:10px;">Calls (Txn ID)</th>
<th style="background:#0e72c3;color:white;border:1px solid #ddd;padding:10px;">> 5 mins</th>
<th style="background:#0e72c3;color:white;border:1px solid #ddd;padding:10px;">Query</th>
</tr>
HTML

while IFS=$'\t' read -r DB CALLS AVG_MS TOTAL_MS SEVERITY SQL; do

  # Map severity to color
  case "$SEVERITY" in
    CRITICAL)
      COLOR="#e74c3c"
      ;;
    EXPENSIVE)
      COLOR="#f39c12"
      ;;
    SLOW)
      COLOR="#2ecc71"
      ;;
    *)
      COLOR="#95a5a6"
      ;;
  esac

  # > 5 mins check (300000 ms)
  if awk "BEGIN {exit !($AVG_MS > 300000)}"; then
    F5="YES"
  else
    F5="NO"
  fi

  {
    echo "DB=$DB | Severity=$SEVERITY | Avg=${AVG_MS}ms | Calls=$CALLS | >5min=$F5"
    echo "Query: $SQL"
    echo "----------------------------------------------------"
  } >> "$SLOW_LOG"

cat <<HTML
<tr>
<td style="border:1px solid #ddd;padding:8px;text-align:center;">$DB</td>
<td style="border:1px solid #ddd;padding:8px;color:white;background:$COLOR;text-align:center;">$SEVERITY</td>
<td style="border:1px solid #ddd;padding:8px;text-align:center;">$AVG_MS</td>
<td style="border:1px solid #ddd;padding:8px;text-align:center;">$CALLS</td>
<td style="border:1px solid #ddd;padding:8px;text-align:center;">$F5</td>
<td style="border:1px solid #ddd;padding:8px;font-family:monospace;">$SQL</td>
</tr>
HTML

done <<< "$RESULTS"

cat <<'HTML'
</table>

<br>
<p>Please review and take necessary action. This is an automated alert.</p>

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