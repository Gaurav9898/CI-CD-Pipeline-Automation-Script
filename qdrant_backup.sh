#!/bin/bash
set -e

# Set PATH explicitly for cron
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOGFILE="/home/netmanazer/qdrant_backup.log"

QDRANT_DATA="/home/netmanazer/qdrant_storage"
BACKUP_ROOT="/mnt/public/qdrant-backups"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")

BACKUP_DIR="$BACKUP_ROOT/$YEAR/$MONTH"
BACKUP_FILE="qdrant_$DATE.tar.gz"

echo "[$(date)] Starting backup..." >> "$LOGFILE" 2>&1

# Log mount status
mount | grep /mnt/public >> "$LOGFILE" 2>&1 || echo "[$(date)] Mount point /mnt/public not found" >> "$LOGFILE"

mkdir -p "$BACKUP_DIR" || { echo "[$(date)] Failed to create backup dir $BACKUP_DIR" >> "$LOGFILE"; exit 1; }

tar -czf "$BACKUP_DIR/$BACKUP_FILE" "$QDRANT_DATA" || { echo "[$(date)] Tar command failed" >> "$LOGFILE"; exit 1; }

echo "[$(date)] Qdrant backup completed: $BACKUP_DIR/$BACKUP_FILE" >> "$LOGFILE"

find "$BACKUP_ROOT" -type f -name "qdrant_*.tar.gz" -mtime +15 -exec rm -f {} \; -exec echo "[$(date)] Deleted old backup: {}" >> "$LOGFILE" \;

find "$BACKUP_ROOT" -type d -empty -delete -exec echo "[$(date)] Removed empty folder: {}" >> "$LOGFILE" \;

echo "[$(date)] Old backup cleanup and empty folder removal completed" >> "$LOGFILE"

#sudo mount -v -t cifs //10.0.10.10/Public /mnt/public -o credentials=/root/.smbcredentials,uid=1000,gid=1000,file_mode=0775,dir_mode=0775,vers=3.1.1
#mount | grep /mnt/public

#sudo systemctl daemon-reload
#sudo mount -a

#sudo nano /etc/fstab
#//10.0.10.10/Public  /mnt/public  cifs  credentials=/root/.smbcredentials,uid=1001,gid=1001,file_mode=0775,dir_mode=0775,_netdev,nofail  0  0

#crontab -e
#0 4 * * * /usr/local/bin/qdrant_backup.sh >> /home/netmanazer/qdrant_backup.log 2>&1

#for restoring all files in qdrant do this
#docker stop qdrant
#rm -rf /var/lib/qdrant/*
#tar -xzf qdrant_YYYY-MM-DD.tar.gz -C /
#docker start qdrant

#for restoring a single collection do this
#sudo systemctl stop qdrant
#tar -xzf qdrant_YYYY-MM-DD_HH-MM-SS.tar.gz path/to/collection_folder -C /path/to/restore/location
#sudo systemctl start qdrant
