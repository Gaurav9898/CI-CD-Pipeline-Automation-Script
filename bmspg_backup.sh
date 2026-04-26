#!/bin/bash
set -e

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOGFILE="/home/netmanazer/bmspg_maintenance.log"

DB_CONTAINER="postgres"
DB_NAME="BMSPG"
DB_USER="rsoftnetmanager"
DB_PASS='Rel!@blE@1279#'

BACKUP_ROOT="/mnt/public/bmspg-backups"
LOCAL_TMP="/tmp"

DATE=$(date +"%Y-%m-%d_%H-%M-%S")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")

BACKUP_DIR="$BACKUP_ROOT/$YEAR/$MONTH"
DUMP_FILE="bmspg_$DATE.sql"
ARCHIVE_FILE="bmspg_$DATE.sql.gz"

echo "[$(date)] ===== MAINTENANCE JOB STARTED =====" >> "$LOGFILE"

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

echo "[$(date)] Creating DB dump..." >> "$LOGFILE"

docker exec -e PGPASSWORD=$DB_PASS $DB_CONTAINER \
pg_dump -U $DB_USER -d $DB_NAME -f /tmp/$DUMP_FILE

echo "[$(date)] Copying dump to host..." >> "$LOGFILE"
docker cp $DB_CONTAINER:/tmp/$DUMP_FILE "$LOCAL_TMP/$DUMP_FILE"

echo "[$(date)] Compressing dump..." >> "$LOGFILE"
gzip "$LOCAL_TMP/$DUMP_FILE"

echo "[$(date)] Moving archive to backup storage..." >> "$LOGFILE"
mv "$LOCAL_TMP/$ARCHIVE_FILE" "$BACKUP_DIR/"

echo "[$(date)] Cleaning container temp file..." >> "$LOGFILE"
docker exec $DB_CONTAINER rm -f /tmp/$DUMP_FILE

echo "[$(date)] Backup completed: $BACKUP_DIR/$ARCHIVE_FILE" >> "$LOGFILE"

echo "[$(date)] Deleting DB logs older than 30 days..." >> "$LOGFILE"

docker exec -e PGPASSWORD=$DB_PASS -i $DB_CONTAINER \
psql -U $DB_USER -d $DB_NAME <<EOF >> "$LOGFILE" 2>&1
DELETE FROM payment.reqlog WHERE modifytimestamp < NOW() - INTERVAL '30 days';
DELETE FROM payment.reslog WHERE modifytimestamp < NOW() - INTERVAL '30 days';
VACUUM ANALYZE payment.reqlog;
VACUUM ANALYZE payment.reslog;
EOF

echo "[$(date)] Old DB logs cleaned." >> "$LOGFILE"

echo "[$(date)] Removing backups older than 15 days..." >> "$LOGFILE"
find "$BACKUP_ROOT" -type f -name "*.gz" -mtime +15 -exec rm -f {} \;

echo "[$(date)] Old backups removed." >> "$LOGFILE"

echo "[$(date)] ===== MAINTENANCE JOB FINISHED SUCCESSFULLY =====" >> "$LOGFILE"
echo "" >> "$LOGFILE"


#file path : /usr/local/bin/bmspg_backup.sh
#Log File path : /home/netmanazer/bmspg_maintenance.log
#crontab : 0 2 * * * /usr/local/bin/bmspg_backup.sh >> /home/netmanazer/bmspg_maintenance.log 2>&1