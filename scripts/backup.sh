#!/usr/bin/env sh
# Ferrite Backup Script
#
# Creates compressed backups of Ferrite checkpoint and AOF files.
# Supports local and S3 destinations with rotation.
#
# Usage:
#   ./scripts/backup.sh                           # Local backup to /var/lib/ferrite/backups
#   BACKUP_DEST=/mnt/nfs/backups ./scripts/backup.sh  # Custom destination
#   BACKUP_S3_BUCKET=my-bucket ./scripts/backup.sh     # S3 upload
#
# Environment variables:
#   FERRITE_HOST         - Ferrite hostname (default: localhost)
#   FERRITE_PORT         - Ferrite port (default: 6379)
#   FERRITE_DATA_DIR     - Data directory (default: /var/lib/ferrite/data)
#   BACKUP_DEST          - Local backup directory (default: /var/lib/ferrite/backups)
#   BACKUP_RETENTION     - Number of backups to keep (default: 7)
#   BACKUP_S3_BUCKET     - S3 bucket name (empty = no S3 upload)
#   BACKUP_S3_REGION     - S3 region (default: us-east-1)
#   BACKUP_S3_PREFIX     - S3 key prefix (default: ferrite-backups/)
#   BACKUP_COMPRESS      - Compression: gzip or none (default: gzip)

set -euo pipefail

# Configuration
FERRITE_HOST="${FERRITE_HOST:-localhost}"
FERRITE_PORT="${FERRITE_PORT:-6379}"
FERRITE_DATA_DIR="${FERRITE_DATA_DIR:-/var/lib/ferrite/data}"
BACKUP_DEST="${BACKUP_DEST:-/var/lib/ferrite/backups}"
BACKUP_RETENTION="${BACKUP_RETENTION:-7}"
BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET:-}"
BACKUP_S3_REGION="${BACKUP_S3_REGION:-us-east-1}"
BACKUP_S3_PREFIX="${BACKUP_S3_PREFIX:-ferrite-backups/}"
BACKUP_COMPRESS="${BACKUP_COMPRESS:-gzip}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_NAME="ferrite-backup-${TIMESTAMP}"
EXIT_CODE=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

cleanup() {
    if [ -d "${TMP_DIR:-}" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Validate data directory
if [ ! -d "$FERRITE_DATA_DIR" ]; then
    log "ERROR: Data directory not found: $FERRITE_DATA_DIR"
    exit 1
fi

# Create backup destination
mkdir -p "$BACKUP_DEST"

# Create temporary staging directory
TMP_DIR="$(mktemp -d)"

log "Starting backup: $BACKUP_NAME"
log "Data directory: $FERRITE_DATA_DIR"
log "Backup destination: $BACKUP_DEST"

# Step 1: Trigger a checkpoint (BGSAVE equivalent)
log "Triggering checkpoint..."
if command -v ferrite-cli >/dev/null 2>&1; then
    if ferrite-cli -h "$FERRITE_HOST" -p "$FERRITE_PORT" BGSAVE 2>/dev/null; then
        log "Checkpoint triggered, waiting for completion..."
        WAIT_COUNT=0
        MAX_WAIT=300
        while [ "$WAIT_COUNT" -lt "$MAX_WAIT" ]; do
            STATUS=$(ferrite-cli -h "$FERRITE_HOST" -p "$FERRITE_PORT" INFO persistence 2>/dev/null || echo "")
            if echo "$STATUS" | grep -q "checkpoint_in_progress:0"; then
                break
            fi
            sleep 1
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done
        if [ "$WAIT_COUNT" -ge "$MAX_WAIT" ]; then
            log "WARNING: Checkpoint did not complete within ${MAX_WAIT}s, proceeding anyway"
        else
            log "Checkpoint completed"
        fi
    else
        log "WARNING: Could not trigger checkpoint (server may be unavailable), backing up existing files"
    fi
else
    log "WARNING: ferrite-cli not found, skipping checkpoint trigger"
fi

# Step 2: Copy data files to staging
log "Copying data files..."
STAGE_DIR="${TMP_DIR}/${BACKUP_NAME}"
mkdir -p "$STAGE_DIR"

# Copy checkpoint files
if [ -d "$FERRITE_DATA_DIR/checkpoints" ]; then
    cp -r "$FERRITE_DATA_DIR/checkpoints" "$STAGE_DIR/"
    log "Copied checkpoint directory"
fi

# Copy checkpoint file (single-file format)
for f in "$FERRITE_DATA_DIR"/*.fcpt "$FERRITE_DATA_DIR"/*.rdb; do
    if [ -f "$f" ]; then
        cp "$f" "$STAGE_DIR/"
        log "Copied: $(basename "$f")"
    fi
done

# Copy AOF file
for f in "$FERRITE_DATA_DIR"/*.aof; do
    if [ -f "$f" ]; then
        cp "$f" "$STAGE_DIR/"
        log "Copied: $(basename "$f")"
    fi
done

# Verify we have something to back up
if [ -z "$(ls -A "$STAGE_DIR" 2>/dev/null)" ]; then
    log "ERROR: No data files found to back up"
    exit 1
fi

# Record backup metadata
cat > "$STAGE_DIR/backup-metadata.json" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "backup_name": "${BACKUP_NAME}",
  "source_host": "${FERRITE_HOST}",
  "source_port": ${FERRITE_PORT},
  "data_dir": "${FERRITE_DATA_DIR}"
}
EOF

# Step 3: Compress
if [ "$BACKUP_COMPRESS" = "gzip" ]; then
    BACKUP_FILE="${BACKUP_DEST}/${BACKUP_NAME}.tar.gz"
    log "Compressing backup..."
    tar -czf "$BACKUP_FILE" -C "$TMP_DIR" "$BACKUP_NAME"
else
    BACKUP_FILE="${BACKUP_DEST}/${BACKUP_NAME}.tar"
    tar -cf "$BACKUP_FILE" -C "$TMP_DIR" "$BACKUP_NAME"
fi

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
log "Backup created: $BACKUP_FILE ($BACKUP_SIZE)"

# Step 4: Upload to S3 if configured
if [ -n "$BACKUP_S3_BUCKET" ]; then
    log "Uploading to S3: s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}"
    if command -v aws >/dev/null 2>&1; then
        S3_KEY="${BACKUP_S3_PREFIX}$(basename "$BACKUP_FILE")"
        aws s3 cp "$BACKUP_FILE" "s3://${BACKUP_S3_BUCKET}/${S3_KEY}" \
            --region "$BACKUP_S3_REGION"
        log "Uploaded to: s3://${BACKUP_S3_BUCKET}/${S3_KEY}"
    else
        log "ERROR: aws CLI not found, skipping S3 upload"
        EXIT_CODE=1
    fi
fi

# Step 5: Rotate old backups (keep last N)
if [ "$BACKUP_RETENTION" -gt 0 ]; then
    log "Rotating backups (keeping last $BACKUP_RETENTION)..."
    cd "$BACKUP_DEST"
    # shellcheck disable=SC2012
    ls -t ferrite-backup-*.tar.gz ferrite-backup-*.tar 2>/dev/null | \
        tail -n +"$((BACKUP_RETENTION + 1))" | \
        while read -r old_backup; do
            rm -f "$old_backup"
            log "Removed old backup: $old_backup"
        done
fi

log "Backup completed successfully: $BACKUP_NAME"
exit "$EXIT_CODE"
