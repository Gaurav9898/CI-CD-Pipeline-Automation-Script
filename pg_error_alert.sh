#!/bin/bash
# ======================================================
# PostgreSQL Error Tracker + Mailer
# Tracks active errors and auto-resolves fixed ones
# ======================================================

set -e

PGUSER="rsoftnetmanager"
PGPASSWORD="Rel!@blE@1279#"
PGDB="postgres"
PGHOST="localhost"
PGPORT="5432"
export PGPASSWORD

LOG_DIR="/var/lib/postgresql/data/pgdata/log"
REPORT_DIR="$HOME/reports"
HTML_REPORT="$REPORT_DIR/pg_error_report.html"
OFFSET_FILE="$REPORT_DIR/pg_error.offset"

mkdir -p "$REPORT_DIR"

# -----------------------
# Email
# -----------------------
SMTP_SERVER="smtp.zeptomail.in"
SMTP_PORT=587
EMAIL_FROM="helpdesk@relipay.net"
EMAIL_TO="umesh.lakhani@reliablesoft.co.in"
EMAIL_CC1="hardik.trivedi@reliablesoft.co.in"
EMAIL_CC2="engineering@reliablesoft.co.in"
EMAIL_CC3="prateek.dadhich@reliablesoft.co.in"
SMTP_PASS="PHtE6r1ZEe3jimUq9BRSsfSwR8CgZIh79ONnLwFO5IhCWaUCHk0Gr4x6x2W3rhgoBqNHRfHNmolq4LzJu+3UJmfrNT5FDWqyqK3sx/VYSPOZsbq6x00VsV4Sc0LbVYLvdtZv0S3VudbSNA=="
SUBJECT="PostgreSQL Active Errors Report - $(hostname)"

# -----------------------
# Ensure table - Updated for compatibility
# -----------------------
psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" <<SQL
CREATE TABLE IF NOT EXISTS error_registry (
  id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  signature TEXT NOT NULL,
  database_name TEXT NOT NULL,
  message TEXT NOT NULL,
  query TEXT,
  last_seen TIMESTAMP NOT NULL,
  resolved BOOLEAN DEFAULT false
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_error_signature
ON error_registry(signature);
SQL

# -----------------------
# Latest log
# -----------------------
LOG_FILE=$(ls -1t "$LOG_DIR"/postgresql-*.log 2>/dev/null | head -1)
[ -z "$LOG_FILE" ] && exit 0

if [ ! -f "$OFFSET_FILE" ]; then
    echo "0" > "$OFFSET_FILE"
fi

LAST_OFFSET=$(cat "$OFFSET_FILE")

FILE_SIZE=$(stat -c%s "$LOG_FILE")

# Log rotated or first run
if [ "$LAST_OFFSET" -gt "$FILE_SIZE" ]; then
  LAST_OFFSET=0
fi

# =============================
# Read only new logs
# =============================
TMP=$(mktemp)
# Create a copy for the nested grep command to fix EOF error
TMP_SEARCH=$(mktemp)

tail -c +$((LAST_OFFSET+1)) "$LOG_FILE" > "$TMP"
cp "$TMP" "$TMP_SEARCH"
echo "$FILE_SIZE" > "$OFFSET_FILE"

# =============================
# Parse Errors
# =============================
while IFS= read -r LINE; do
  [[ ! "$LINE" =~ ERROR:|FATAL:|PANIC: ]] && continue

  DB=$(echo "$LINE" | grep -o 'db=[^ ]*' | cut -d= -f2)
  [ -z "$DB" ] && DB="postgres"

  MSG=$(echo "$LINE" | sed -E 's/^.*(ERROR|FATAL|PANIC): ?//')
  SIG="$DB|$MSG"

  QUERY=""
  # Read next lines to find the statement in the copied file
  while IFS= read -r NEXT_LINE; do
      if [[ "$NEXT_LINE" =~ statement: ]]; then
          QUERY=$(echo "$NEXT_LINE" | sed -E 's/^.*statement: ?//')
          break
      elif [[ "$NEXT_LINE" =~ ERROR:|FATAL:|PANIC:|LOG:|DETAIL:|LOCATION:|CONTEXT: ]]; then
          # If we hit a new log entry type, no statement found
          break
      fi
  done < <(tail -n +$(grep -nF "$LINE" "$TMP_SEARCH" | head -1 | cut -d: -f1) "$TMP_SEARCH" | tail -n +2)

  SAFE_SIG=$(echo "$SIG" | sed "s/'/''/g")
  SAFE_MSG=$(echo "$MSG" | sed "s/'/''/g")
  SAFE_QUERY=$(echo "$QUERY" | sed "s/'/''/g")

  psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" <<SQL
INSERT INTO error_registry(signature,database_name,message,query,last_seen,resolved)
VALUES ('$SAFE_SIG','$DB','$SAFE_MSG','$SAFE_QUERY',now(),false)
ON CONFLICT(signature)
DO UPDATE SET last_seen=now(), resolved=false, query='$SAFE_QUERY';
SQL

done < "$TMP"

rm -f "$TMP" "$TMP_SEARCH"
# -----------------------
# Auto-resolve missing errors
# -----------------------
# Resolve errors not seen in last 1 hour
psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" <<SQL
UPDATE error_registry
SET resolved = true
WHERE last_seen < now() - interval '1 hour'
AND resolved = false;
SQL


# -----------------------
# Fetch active errors
# -----------------------
RESULTS=$(psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" \
  -A -t -F '|' -c \
"SELECT id, last_seen, database_name, message FROM error_registry WHERE resolved=false ORDER BY last_seen DESC;")

TOTAL=$(echo "$RESULTS" | sed '/^\s*$/d' | wc -l)
[ "$TOTAL" -eq 0 ] && exit 0

echo "Active PostgreSQL errors: $TOTAL"

# -----------------------
# HTML Mail
# -----------------------
{
cat <<HTML
<html>
<body style="font-family:Arial;">

<h3>PostgreSQL Active Errors</h3>
<p><b>Database:</b> $PGDB</p>
<p><code>SELECT * FROM error_registry WHERE id = &lt;ID&gt;;</code></p>

<table border="1" cellpadding="6" cellspacing="0">
<tr style="background:#e74c3c;color:white;">
<th>Id</th><th>Last Seen</th><th>Database</th><th>Error</th>
</tr>
HTML

# Fixed: Added QUERY variable to match SQL output
echo "$RESULTS" | while IFS='|' read -r EID TS DB MSG; do
cat <<HTML
<tr>
<td style="text-align:center;">$EID</td>
<td>$TS</td>
<td>$DB</td>
<td style="font-family:monospace;">$MSG</td>
</tr>
HTML
done

cat <<HTML
</table>
</body>
</html>
HTML
} > "$HTML_REPORT"

# -----------------------
# Send mail
# -----------------------
MSMTP_LOG="$HOME/msmtp.log"
MSMTP_CONF=$(mktemp)
touch "$MSMTP_LOG"
chmod 777 "$MSMTP_CONF"
chmod 777 "$MSMTP_LOG"

cat > "$MSMTP_CONF" <<EOF
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile $MSMTP_LOG

account zeptomail
host $SMTP_SERVER
port $SMTP_PORT
from $EMAIL_FROM
user $EMAIL_FROM
password $SMTP_PASS

account default : zeptomail
EOF

{
echo "From: $EMAIL_FROM"
echo "To: $EMAIL_TO"
echo "Cc: $EMAIL_CC1, $EMAIL_CC2, $EMAIL_CC3"
echo "Subject: $SUBJECT"
echo "MIME-Version: 1.0"
echo "Content-Type: text/html"
echo ""
cat "$HTML_REPORT"
} | msmtp --file="$MSMTP_CONF" "$EMAIL_TO" "$EMAIL_CC1" "$EMAIL_CC2" "$EMAIL_CC3"

rm -f "$MSMTP_CONF"