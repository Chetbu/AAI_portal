#!/bin/bash
# backup.sh — daily backup of all AAI platform data
#
# Backs up shared.env, infrastructure/, and all projects/ to a dated tar.gz.
# Keeps the last 7 backups and prunes older ones automatically.
#
# Recommended cron (run as aai user):
#   0 3 * * * /opt/aai/infrastructure/scripts/backup.sh >> /var/log/aai-backup.log 2>&1

set -e

AAI_ROOT="${AAI_ROOT:-/opt/aai}"
BACKUP_DIR="${AAI_ROOT}/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/aai-backup-${DATE}.tar.gz"

mkdir -p "$BACKUP_DIR"

echo "[backup] Starting backup: ${DATE}"

tar czf "$BACKUP_FILE" \
    --exclude='*/node_modules' \
    --exclude='*/__pycache__' \
    --exclude='*.pyc' \
    --exclude='*/venv' \
    --exclude='*/\.git' \
    "${AAI_ROOT}/shared.env" \
    "${AAI_ROOT}/infrastructure/" \
    "${AAI_ROOT}/projects/"

echo "[backup] Created: ${BACKUP_FILE} ($(du -sh "$BACKUP_FILE" | cut -f1))"

# Keep only the last 7 backups
ls -t "${BACKUP_DIR}"/aai-backup-*.tar.gz | tail -n +8 | xargs -r rm --
echo "[backup] Cleanup done. Current backups:"
ls -lh "${BACKUP_DIR}"/aai-backup-*.tar.gz
