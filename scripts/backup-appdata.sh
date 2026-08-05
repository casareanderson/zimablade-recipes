#!/bin/bash
# backup-appdata.sh — back up ZimaOS / CasaOS AppData, including the parts a
# normal tar silently misses.
#
# Run it ON the Zima (SSH in, or paste it into a file and run it).
#
#   bash backup-appdata.sh              # make a backup
#   bash backup-appdata.sh --dry-run    # show what it would do, change nothing
#
# WHY THIS ISN'T JUST `tar czf backup.tar.gz AppData`:
# AppData is owned by root and parts of it are mode 0700 — TLS certificates,
# tunnel tokens, auth databases. The ZimaOS SSH user is not root and has no
# usable sudo, so a plain tar cannot read those directories. You still get an
# archive, of a plausible size, that is missing exactly the files you cannot
# recreate. This script escalates properly first, so the archive is complete.
#
# Settings can be overridden from the environment, e.g.
#   RETENTION_DAYS=60 bash backup-appdata.sh
set -uo pipefail

SRC_DIR="${SRC_DIR:-/DATA/AppData}"                  # what to back up
DEST_DIR="${DEST_DIR:-/DATA/Backups}"                # where archives go
RETENTION_DAYS="${RETENTION_DAYS:-30}"               # delete archives older than this
EXCLUDES="${EXCLUDES:---exclude=*/cache --exclude=*/logs}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Sanity checks, with plain-English failures
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    say "ERROR: docker not found. This script uses Docker to gain root access,"
    say "       which is how you escalate on an immutable OS like ZimaOS."
    exit 1
fi

if ! docker ps >/dev/null 2>&1; then
    say "ERROR: cannot talk to Docker as $(id -un)."
    say "       On ZimaOS the SSH user is normally in the docker group already."
    exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
    say "DRY RUN — nothing will be written."
    say "  source:     $SRC_DIR"
    say "  destination:$DEST_DIR"
    say "  retention:  ${RETENTION_DAYS} days"
    say "  excludes:   $EXCLUDES"
    say
    say "Directories the current user CANNOT read (these are the ones a plain"
    say "tar would leave out of the archive):"
    # NOTE: ZimaOS ships BusyBox find, which has no -readable and no -printf.
    # Test with the shell instead — portable, and it matches what tar can open.
    UNREADABLE=$(find "$SRC_DIR" -type d 2>/dev/null | while read -r d; do
        [ -r "$d" ] || printf '%s\n' "$d"
    done)
    if [ -z "$UNREADABLE" ]; then
        say "  (none — every directory is readable by $(id -un))"
    else
        printf '%s\n' "$UNREADABLE" | head -20 | sed 's/^/  /'
        say "  ...$(printf '%s\n' "$UNREADABLE" | wc -l) unreadable director(ies) in total"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. The backup itself, run as real root inside a privileged container
# ---------------------------------------------------------------------------
# --privileged + -v /:/host + chroot /host gives us the HOST's own tar running
# as root. Nothing is installed on the host, and the container is removed when
# it exits (--rm), which suits an immutable OS.
docker run --rm --privileged --pid=host -v /:/host alpine \
    chroot /host /bin/bash -c "
        set -uo pipefail
        SRC='$SRC_DIR'
        DEST='$DEST_DIR'
        mkdir -p \"\$DEST\"
        STAMP=\$(date +%Y%m%d_%H%M%S)
        ARCHIVE=\"\$DEST/appdata-\$STAMP.tar.gz\"

        # tar exits 1 for 'file changed as we read it', which is normal when
        # containers are running. Only exit >= 2 is a real failure.
        tar --warning=no-file-changed $EXCLUDES \
            -czf \"\$ARCHIVE\" -C \"\$(dirname \"\$SRC\")\" \"\$(basename \"\$SRC\")\"
        RC=\$?

        SIZE=\$(du -h \"\$ARCHIVE\" 2>/dev/null | cut -f1)
        find \"\$DEST\" -name 'appdata-*.tar.gz' -mtime +$RETENTION_DAYS -delete

        echo \"RESULT ARCHIVE=\$ARCHIVE SIZE=\${SIZE:-?} RC=\$RC\"
        [ \"\$RC\" -le 1 ] && exit 0 || exit \"\$RC\"
    "
RC=$?

if [ "$RC" -eq 0 ]; then
    say
    say "Backup finished. Now check it is actually complete:"
    say "  bash verify-backup.sh"
else
    say "Backup FAILED (exit $RC)"
fi
exit "$RC"
