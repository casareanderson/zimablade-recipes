#!/bin/bash
# photo-offsite-backup.sh — incremental offsite backup of an Immich library.
#
# Uploads each original photo ONCE. Skips everything the server can regenerate.
# Dumps the database first, and refuses to overwrite a good dump with a bad one.
#
# Run it ON the machine that holds the photos.
#
#   bash photo-offsite-backup.sh                 # back up
#   DRY_RUN=1 bash photo-offsite-backup.sh       # show what would transfer
#
# CREDENTIALS — never put them in this file.
# rclone reads them from the environment, so either configure a remote once
# with `rclone config`, or export them just before running:
#
#   export RCLONE_CONFIG_OFFSITE_TYPE=b2
#   export RCLONE_CONFIG_OFFSITE_ACCOUNT=your_key_id
#   export RCLONE_CONFIG_OFFSITE_KEY=your_application_key
#
# If a scheduler on another machine drives this, pipe those exports into the
# script's stdin ahead of the script itself. Passing secrets as arguments puts
# them in `ps` output for every user on the box; environment-via-stdin doesn't.
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RCLONE="${RCLONE:-$(command -v rclone)}"
REMOTE="${REMOTE:-offsite:my-photo-backup}"       # rclone remote:bucket
UPLOAD_DIR="${UPLOAD_DIR:-/DATA/Gallery/immich}"  # Immich's storage root
DB_CONTAINER="${DB_CONTAINER:-immich-postgres}"
DB_NAME="${DB_NAME:-immich}"
DB_USER="${DB_USER:-postgres}"
LOCAL_DB_DIR="${LOCAL_DB_DIR:-/DATA/Backups/immich-db}"
KEEP_LOCAL="${KEEP_LOCAL:-3}"                     # local dumps to retain
KEEP_DB_DAYS="${KEEP_DB_DAYS:-7}"                 # remote dumps: keep N days + 1st-of-month
TRANSFERS="${TRANSFERS:-8}"
DRY_RUN="${DRY_RUN:-0}"

[ -n "$RCLONE" ] || { echo "rclone not found — install it first"; exit 1; }

DATE=$(date +%Y%m%d_%H%M%S)
DUMP="$LOCAL_DB_DIR/immich-db-$DATE.sql"
mkdir -p "$LOCAL_DB_DIR"
status=ok; errors=""

# ---------------------------------------------------------------------------
# 1. Database dump, guarded.
# ---------------------------------------------------------------------------
# Write to .partial and promote only on success AND non-empty. Without this, a
# dump that fails halfway happily overwrites last night's good one, and you
# don't find out until you need it.
#
# The excluded tables are all DERIVED: place names, face vectors, search
# embeddings. Immich rebuilds them by re-running its ML jobs. Keeping them out
# makes the dump far smaller — at the cost of having to run those jobs after a
# restore. That trade is worth making consciously.
TMP="$DUMP.partial"
if docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" \
        --exclude-table=geodata_places \
        --exclude-table=face_search \
        --exclude-table=asset_face \
        > "$TMP" 2>/tmp/pgdump.err; then
    if [ -s "$TMP" ]; then
        mv "$TMP" "$DUMP"
        echo "database dump: $(du -h "$DUMP" | cut -f1)"
    else
        status=fail; errors+="pg_dump produced an empty file; "; rm -f "$TMP"
    fi
else
    status=fail; errors+="pg_dump failed: $(tail -1 /tmp/pgdump.err 2>/dev/null); "; rm -f "$TMP"
fi

# ---------------------------------------------------------------------------
# 2. Upload originals only.
# ---------------------------------------------------------------------------
# `copy`, NOT `sync`. sync mirrors deletions: lose a photo locally — to a bad
# import, a mistake, ransomware — and the next run deletes it offsite too.
# copy only ever adds, so the remote is a safety net rather than a mirror.
#
# The excludes are Immich's regenerable derivatives. On the box this was
# written from: 815 GB of originals against 693 GB of transcoded video and
# 19 GB of thumbnails. Excluding them nearly halves what you pay to store.
DRY=""
[ "$DRY_RUN" = "1" ] && DRY="--dry-run"

NEW_FILES=0
if [ "$status" = ok ]; then
    OUT=$("$RCLONE" copy "$UPLOAD_DIR" "$REMOTE/upload" \
        --exclude "encoded-video/**" \
        --exclude "thumbs/**" \
        --exclude "backups/**" \
        --transfers "$TRANSFERS" --ignore-errors -v $DRY 2>&1)
    NEW_FILES=$(printf '%s\n' "$OUT" | grep -c "Copied (new)")

    "$RCLONE" copy "$DUMP" "$REMOTE/database" --transfers 4 $DRY >/dev/null 2>&1 \
        || { status=fail; errors+="database upload failed; "; }
fi

# ---------------------------------------------------------------------------
# 3. Retention
# ---------------------------------------------------------------------------
# Local: keep the last few dumps.
ls -t "$LOCAL_DB_DIR"/immich-db-*.sql 2>/dev/null | tail -n +$((KEEP_LOCAL + 1)) \
    | while IFS= read -r f; do rm -f "$f"; done

# Remote: keep N days, but never delete a 1st-of-month dump — cheap long-term
# history. --b2-hard-delete matters on Backblaze: without it, deleted files
# become hidden versions that you continue to be billed for.
if [ "$DRY_RUN" != "1" ]; then
    "$RCLONE" delete "$REMOTE/database" \
        --min-age "${KEEP_DB_DAYS}d" \
        --exclude "immich-db-??????01_*.sql" \
        --b2-hard-delete >/dev/null 2>&1 || true
fi

LIB_SIZE=$(du -sh "$UPLOAD_DIR/library" 2>/dev/null | cut -f1)

# One machine-readable line, so a scheduler can alert on it without parsing prose.
echo "SUMMARY status=$status new_files=${NEW_FILES:-0} lib_size=${LIB_SIZE:-?} dump=$(basename "$DUMP") errors=${errors:-none}"
[ "$status" = ok ]
