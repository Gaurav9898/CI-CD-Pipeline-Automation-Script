#!/bin/bash
set -e

# Set PATH explicitly for cron
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOGFILE="/home/netmanazer/mongo_backup.log"

# Mongo container name
CONTAINER_NAME="mongodb"

# Mongo credentials
MONGO_USER="mongo"
MONGO_PASS="mongo123"
MONGO_AUTH_DB="admin"

# Backup locations
BACKUP_ROOT="/mnt/public/mongo-backups"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")

BACKUP_DIR="$BACKUP_ROOT/$YEAR/$MONTH"
BACKUP_FILE="mongo_${DATE}.archive.gz"

echo "[$(date)] Starting MongoDB backup..." >> "$LOGFILE"

# Check mount
if ! mount | grep -q /mnt/public; then
    echo "[$(date)] ERROR: /mnt/public not mounted!" >> "$LOGFILE"
    exit 1
fi

mkdir -p "$BACKUP_DIR"

echo "[$(date)] Running mongodump..." >> "$LOGFILE"

docker exec "$CONTAINER_NAME" mongodump \
    -u "$MONGO_USER" \
    -p "$MONGO_PASS" \
    --authenticationDatabase "$MONGO_AUTH_DB" \
    --archive --gzip \
    > "$BACKUP_DIR/$BACKUP_FILE"

echo "[$(date)] Mongo archive created: $BACKUP_FILE" >> "$LOGFILE"

echo "[$(date)] Backing up Docker logs..." >> "$LOGFILE"

docker logs "$CONTAINER_NAME" \
    > "$BACKUP_DIR/mongodb_docker_${DATE}.log" 2>&1

echo "[$(date)] Backup completed successfully." >> "$LOGFILE"

# Delete backups older than 15 days
find "$BACKUP_ROOT" -type f -name "mongo_*.archive.gz" -mtime +15 \
    -exec rm -f {} \; \
    -exec echo "[$(date)] Deleted old backup: {}" >> "$LOGFILE" \;

# Remove empty folders
find "$BACKUP_ROOT" -type d -empty -delete

echo "[$(date)] Cleanup completed." >> "$LOGFILE"

#filepath - /usr/local/bin/mongo_backup.sh
#logfile - /home/netmanazer/mongo_backup.log
#crontab - 0 3 * * * /usr/local/bin/mongo_backup.sh >> /home/netmanazer/mongo_backup.log 2>&1

#to restore backup without droping table run : ----
#cat /mnt/public/mongo-backups/2026/02/mongo_2026-02-13_12-54-29.archive.gz | \
#docker exec -i mongodb mongorestore \
#  -u mongo \
#  -p mongo123 \
#  --authenticationDatabase admin \
#  --archive \
#  --gzip
