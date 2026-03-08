#!/usr/bin/env sh
# Ferrite Restore Script
#
# Restores Ferrite data from a backup archive.
# Supports local and S3 sources with integrity verification.
#
# Usage:
#   ./scripts/restore.sh /path/to/ferrite-backup-20240115_020000.tar.gz
#   RESTORE_S3_BUCKET=my-bucket ./scripts/restore.sh ferrite-backup-20240115_020000.tar.gz
#   ./scripts/restore.sh /path/to/backup.tar.gz --pitr "2024-01-15T10:30:00Z"
#
# Environment variables:
#   FERRITE_HOST         - Ferrite hostname (default: localhost)
#   FERRITE_PORT         - Ferrite port (default: 6379)
#   FERRITE_DATA_DIR     - Data directory (default: /var/lib/ferrite/data)
#   FERRITE_CONFIG       - Config file path (default: /etc/ferrite/ferrite.toml)
#   RESTORE_S3_BUCKET    - S3 bucket to download from (empty = local file)
#   RESTORE_S3_REGION    - S3 region (default: us-east-1)
#   RESTORE_S3_PREFIX    - S3 key prefix (default: ferrite-backups/)
#   RESTORE_SKIP_STOP    - Skip server stop/start (default: false, for containers)

set -euo pipefail

# Configuration
FERRITE_HOST="${FERRITE_HOST:-localhost}"
FERRITE_PORT="${FERRITE_PORT:-6379}"
FERRITE_DATA_DIR="${FERRITE_DATA_DIR:-/var/lib/ferrite/data}"
FERRITE_CONFIG="${FERRITE_CONFIG:-/etc/ferrite/ferrite.toml}"
RESTORE_S3_BUCKET="${RESTORE_S3_BUCKET:-}"
RESTORE_S3_REGION="${RESTORE_S3_REGION:-us-east-1}"
RESTORE_S3_PREFIX="${RESTORE_S3_PREFIX:-ferrite-backups/}"
RESTORE_SKIP_STOP="${RESTORE_SKIP_STOP:-false}"

PITR_TARGET=""
BACKUP_SOURCE=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

usage() {
    echo "Usage: $0 <backup-file> [--pitr <timestamp>]"
    echo ""
    echo "Arguments:"
    echo "  backup-file    Path to backup archive (local) or filename (S3)"
    echo "  --pitr         Point-in-time recovery target (ISO 8601 timestamp)"
    echo ""
    echo "Examples:"
    echo "  $0 /backups/ferrite-backup-20240115_020000.tar.gz"
    echo "  $0 backup.tar.gz --pitr '2024-01-15T10:30:00Z'"
    echo "  RESTORE_S3_BUCKET=my-bucket $0 ferrite-backup-20240115.tar.gz"
    exit 1
}

cleanup() {
    if [ -d "${TMP_DIR:-}" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --pitr)
            shift
            PITR_TARGET="${1:-}"
            if [ -z "$PITR_TARGET" ]; then
                log "ERROR: --pitr requires a timestamp argument"
                usage
            fi
            ;;
        --help|-h)
            usage
            ;;
        *)
            if [ -z "$BACKUP_SOURCE" ]; then
                BACKUP_SOURCE="$1"
            else
                log "ERROR: Unexpected argument: $1"
                usage
            fi
            ;;
    esac
    shift
done

if [ -z "$BACKUP_SOURCE" ]; then
    log "ERROR: Backup source is required"
    usage
fi

TMP_DIR="$(mktemp -d)"

log "Starting restore from: $BACKUP_SOURCE"
if [ -n "$PITR_TARGET" ]; then
    log "Point-in-time recovery target: $PITR_TARGET"
fi

# Step 1: Obtain backup file
BACKUP_FILE=""
if [ -n "$RESTORE_S3_BUCKET" ]; then
    log "Downloading backup from S3..."
    if ! command -v aws >/dev/null 2>&1; then
        log "ERROR: aws CLI not found"
        exit 1
    fi
    S3_KEY="${RESTORE_S3_PREFIX}${BACKUP_SOURCE}"
    BACKUP_FILE="${TMP_DIR}/$(basename "$BACKUP_SOURCE")"
    aws s3 cp "s3://${RESTORE_S3_BUCKET}/${S3_KEY}" "$BACKUP_FILE" \
        --region "$RESTORE_S3_REGION"
    log "Downloaded: $BACKUP_FILE"
elif [ -f "$BACKUP_SOURCE" ]; then
    BACKUP_FILE="$BACKUP_SOURCE"
else
    log "ERROR: Backup file not found: $BACKUP_SOURCE"
    exit 1
fi

# Step 2: Verify backup integrity
log "Verifying backup integrity..."
case "$BACKUP_FILE" in
    *.tar.gz|*.tgz)
        if ! gzip -t "$BACKUP_FILE" 2>/dev/null; then
            log "ERROR: Backup file is corrupted (gzip integrity check failed)"
            exit 1
        fi
        EXTRACT_FLAGS="-xzf"
        ;;
    *.tar)
        EXTRACT_FLAGS="-xf"
        ;;
    *)
        log "ERROR: Unsupported backup format. Expected .tar.gz or .tar"
        exit 1
        ;;
esac
log "Backup integrity verified"

# Step 3: Extract backup to staging
STAGE_DIR="${TMP_DIR}/restore"
mkdir -p "$STAGE_DIR"
tar "$EXTRACT_FLAGS" "$BACKUP_FILE" -C "$STAGE_DIR"

# Find the backup content directory (may be nested in a named directory)
CONTENT_DIR="$STAGE_DIR"
if [ -f "$STAGE_DIR"/ferrite-backup-*/backup-metadata.json ] 2>/dev/null; then
    CONTENT_DIR="$(dirname "$STAGE_DIR"/ferrite-backup-*/backup-metadata.json)"
fi

# Display backup metadata if available
if [ -f "$CONTENT_DIR/backup-metadata.json" ]; then
    log "Backup metadata:"
    cat "$CONTENT_DIR/backup-metadata.json"
    echo ""
fi

# Verify we have restorable content
HAS_CHECKPOINT=false
HAS_AOF=false

for f in "$CONTENT_DIR"/*.fcpt "$CONTENT_DIR"/*.rdb "$CONTENT_DIR"/checkpoints/*; do
    if [ -f "$f" ] 2>/dev/null; then
        HAS_CHECKPOINT=true
        break
    fi
done

for f in "$CONTENT_DIR"/*.aof; do
    if [ -f "$f" ] 2>/dev/null; then
        HAS_AOF=true
        break
    fi
done

if [ "$HAS_CHECKPOINT" = false ] && [ "$HAS_AOF" = false ]; then
    log "ERROR: No checkpoint or AOF files found in backup"
    exit 1
fi

log "Found: checkpoint=$HAS_CHECKPOINT aof=$HAS_AOF"

# Step 4: Stop Ferrite server
if [ "$RESTORE_SKIP_STOP" != "true" ]; then
    log "Stopping Ferrite server..."
    if command -v ferrite-cli >/dev/null 2>&1; then
        ferrite-cli -h "$FERRITE_HOST" -p "$FERRITE_PORT" SHUTDOWN NOSAVE 2>/dev/null || true
        sleep 2
    fi
    # Verify server is stopped
    if command -v ferrite-cli >/dev/null 2>&1; then
        if ferrite-cli -h "$FERRITE_HOST" -p "$FERRITE_PORT" PING 2>/dev/null; then
            log "ERROR: Server is still running. Please stop it manually."
            exit 1
        fi
    fi
    log "Server stopped"
fi

# Step 5: Back up current data (safety net)
if [ -d "$FERRITE_DATA_DIR" ] && [ -n "$(ls -A "$FERRITE_DATA_DIR" 2>/dev/null)" ]; then
    PRE_RESTORE_BACKUP="${FERRITE_DATA_DIR}.pre-restore.$(date +%Y%m%d_%H%M%S)"
    log "Creating safety backup of current data: $PRE_RESTORE_BACKUP"
    cp -r "$FERRITE_DATA_DIR" "$PRE_RESTORE_BACKUP"
fi

# Step 6: Replace data files
log "Restoring data files to: $FERRITE_DATA_DIR"
mkdir -p "$FERRITE_DATA_DIR"

# Clear existing data
rm -f "$FERRITE_DATA_DIR"/*.fcpt "$FERRITE_DATA_DIR"/*.rdb "$FERRITE_DATA_DIR"/*.aof
if [ -d "$FERRITE_DATA_DIR/checkpoints" ]; then
    rm -rf "$FERRITE_DATA_DIR/checkpoints"
fi

# Copy checkpoint files
if [ "$HAS_CHECKPOINT" = true ]; then
    for f in "$CONTENT_DIR"/*.fcpt "$CONTENT_DIR"/*.rdb; do
        if [ -f "$f" ]; then
            cp "$f" "$FERRITE_DATA_DIR/"
            log "Restored: $(basename "$f")"
        fi
    done
    if [ -d "$CONTENT_DIR/checkpoints" ]; then
        cp -r "$CONTENT_DIR/checkpoints" "$FERRITE_DATA_DIR/"
        log "Restored: checkpoints/"
    fi
fi

# Copy AOF file
if [ "$HAS_AOF" = true ]; then
    for f in "$CONTENT_DIR"/*.aof; do
        if [ -f "$f" ]; then
            cp "$f" "$FERRITE_DATA_DIR/"
            log "Restored: $(basename "$f")"
        fi
    done
fi

# Step 7: Point-in-time recovery (truncate AOF)
if [ -n "$PITR_TARGET" ] && [ "$HAS_AOF" = true ]; then
    log "Applying point-in-time recovery..."
    AOF_FILE="$(find "$FERRITE_DATA_DIR" -name '*.aof' -type f | head -1)"
    if [ -n "$AOF_FILE" ] && command -v ferrite-check-aof >/dev/null 2>&1; then
        ferrite-check-aof --truncate-at "$PITR_TARGET" "$AOF_FILE"
        log "AOF truncated to: $PITR_TARGET"
    else
        log "WARNING: ferrite-check-aof not available, PITR truncation skipped"
        log "  Manually truncate AOF with: ferrite-check-aof --truncate-at '$PITR_TARGET' <aof-file>"
    fi
fi

# Step 8: Restart Ferrite server
if [ "$RESTORE_SKIP_STOP" != "true" ]; then
    log "Starting Ferrite server..."
    if command -v ferrite >/dev/null 2>&1; then
        if [ -f "$FERRITE_CONFIG" ]; then
            ferrite --config "$FERRITE_CONFIG" &
        else
            ferrite &
        fi

        # Wait for server to be ready
        WAIT_COUNT=0
        MAX_WAIT=30
        while [ "$WAIT_COUNT" -lt "$MAX_WAIT" ]; do
            if command -v ferrite-cli >/dev/null 2>&1 && \
               ferrite-cli -h "$FERRITE_HOST" -p "$FERRITE_PORT" PING 2>/dev/null; then
                break
            fi
            sleep 1
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done

        if [ "$WAIT_COUNT" -ge "$MAX_WAIT" ]; then
            log "WARNING: Server did not respond within ${MAX_WAIT}s"
        else
            log "Server is ready"
        fi
    else
        log "WARNING: ferrite binary not found, please start the server manually"
    fi
fi

log "Restore completed successfully"
if [ -n "${PRE_RESTORE_BACKUP:-}" ]; then
    log "Previous data backed up to: $PRE_RESTORE_BACKUP"
fi
