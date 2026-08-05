#!/bin/bash
# verify-backup.sh — prove an AppData archive is complete, not just present.
#
#   bash verify-backup.sh                    # check the newest archive
#   bash verify-backup.sh path/to/file.tar.gz
#
# The failure this catches: an archive made without root reads fine, has a
# believable size, and is missing every 0700 directory in it — certificates,
# tokens, auth databases. You find out at restore time. This script looks
# inside the archive for the files that only root could have read.
set -uo pipefail

DEST_DIR="${DEST_DIR:-/DATA/Backups}"
SRC_DIR="${SRC_DIR:-/DATA/AppData}"

ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ]; then
    ARCHIVE=$(ls -1t "$DEST_DIR"/appdata-*.tar.gz 2>/dev/null | head -1)
fi

if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
    echo "No archive found. Looked in: $DEST_DIR"
    exit 1
fi

echo "archive: $ARCHIVE"
ls -lh "$ARCHIVE" | awk '{print "size:    " $5 "   modified: " $6, $7, $8}'
echo

# 1. Is it a valid gzip stream at all? A truncated archive often still lists.
echo "== 1. integrity =="
if gzip -t "$ARCHIVE" 2>/dev/null; then
    echo "   OK — gzip stream is intact"
else
    echo "   FAILED — archive is corrupt or truncated"
    exit 1
fi
echo

# 2. How many entries, and does it contain the privileged material?
# List ONCE into a temp file. A multi-gigabyte archive is expensive to walk, and
# the naive version of this script decompressed it five separate times.
echo "== 2. completeness =="
LISTING=$(mktemp)
trap 'rm -f "$LISTING"' EXIT
tar -tzf "$ARCHIVE" > "$LISTING" 2>/dev/null

TOTAL=$(wc -l < "$LISTING")
echo "   entries: $TOTAL"

SENSITIVE=$(grep -icE '(^|/)(tls|certs?|secrets?)(/|$)|\.pem$|\.key$|\.crt$|token|credential' "$LISTING" || true)
echo "   entries that look privileged (certs/keys/tokens): $SENSITIVE"

if [ "$SENSITIVE" -eq 0 ]; then
    echo
    echo "   WARNING: none found. If your stack terminates TLS or uses tunnels,"
    echo "   this archive is probably INCOMPLETE — the classic symptom of a"
    echo "   backup taken without root. Re-run backup-appdata.sh."
else
    echo "   sample:"
    grep -iE '(^|/)(tls|certs?|secrets?)(/|$)|\.pem$|\.key$|\.crt$' "$LISTING" | head -5 | sed 's/^/     /'
fi
echo

# 2b. The check that actually matters. Counting cert-looking filenames is weak:
# many of them are world-readable (portainer's, for instance, are 0755), so an
# unprivileged tar would have caught them too — the test passes while proving
# nothing. The real question is whether the directories this user CANNOT read
# made it into the archive. Only a privileged backup can have captured those.
echo "== 2b. did the root-only directories make it in? =="
if [ -d "$SRC_DIR" ]; then
    PARENT=$(dirname "$SRC_DIR")
    # Two legitimate reasons a directory is absent, neither of them a fault:
    #   - it matches an exclude pattern (cache, logs) — deliberately not backed up
    #   - it is NEWER than the archive — it did not exist when the backup ran
    # Without these, the check reports false failures and gets ignored.
    SKIP_PATTERN="${SKIP_PATTERN:-/cache$|/cache/|/logs$|/logs/}"
    MISSED=0; CHECKED=0; SKIPPED=0
    while read -r d; do
        [ -n "$d" ] || continue
        [ -r "$d" ] && continue                      # readable: an ordinary tar gets it too

        if printf '%s' "$d" | grep -qE "$SKIP_PATTERN"; then
            echo "   skipped: ${d#"$PARENT"/}  (excluded from backups)"
            SKIPPED=$((SKIPPED + 1)); continue
        fi
        if [ "$d" -nt "$ARCHIVE" ]; then
            echo "   skipped: ${d#"$PARENT"/}  (created after this archive)"
            SKIPPED=$((SKIPPED + 1)); continue
        fi

        CHECKED=$((CHECKED + 1))
        REL="${d#"$PARENT"/}"
        if grep -qF "$REL" "$LISTING"; then
            echo "   present: $REL"
        else
            echo "   MISSING: $REL"
            MISSED=$((MISSED + 1))
        fi
    done <<< "$(find "$SRC_DIR" -type d 2>/dev/null)"

    echo
    if [ "$CHECKED" -eq 0 ]; then
        echo "   (nothing root-only left to check — $SKIPPED skipped)"
    elif [ "$MISSED" -eq 0 ]; then
        echo "   OK — all $CHECKED root-only director(ies) are in the archive."
        echo "   That is the proof the privileged backup worked: an ordinary tar"
        echo "   could not have read any of them."
        [ "$SKIPPED" -gt 0 ] && echo "   ($SKIPPED skipped for the reasons above.)"
    else
        echo "   FAILED — $MISSED of $CHECKED root-only directories are absent."
        echo "   This archive was probably taken WITHOUT root. Re-run backup-appdata.sh."
    fi
else
    echo "   (live AppData not readable here; skipping)"
fi
echo

# 3. Compare against what is on disk right now.
echo "== 3. compared with live AppData =="
if [ -d "$SRC_DIR" ]; then
    # BusyBox find (which ZimaOS ships) has no -printf, so strip the path with sed.
    LIVE_LIST=$(find "$SRC_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed 's#.*/##' | sort)
    ARCH_LIST=$(awk -F/ 'NF>=2 && $2!="" {print $2}' "$LISTING" | sort -u)
    LIVE_TOP=$(printf '%s\n' "$LIVE_LIST" | grep -c . || true)
    ARCH_TOP=$(printf '%s\n' "$ARCH_LIST" | grep -c . || true)
    echo "   app directories on disk:    $LIVE_TOP"
    echo "   app directories in archive: $ARCH_TOP"
    if [ "$ARCH_TOP" -lt "$LIVE_TOP" ]; then
        echo "   WARNING: archive has fewer apps than the live directory."
        echo "   Missing:"
        comm -23 <(printf '%s\n' "$LIVE_LIST") <(printf '%s\n' "$ARCH_LIST") \
            | head -10 | sed 's/^/     /'
    else
        echo "   OK — every app directory is represented"
    fi
else
    echo "   (live AppData not readable here; skipping comparison)"
fi
echo

# 4. Restore rehearsal: extract one app to a temp dir and show it.
echo "== 4. restore rehearsal =="
TMP=$(mktemp -d)
FIRST_APP=$(awk -F/ 'NF>=2 && $2!="" {print $2; exit}' "$LISTING")
if [ -n "$FIRST_APP" ]; then
    if tar -xzf "$ARCHIVE" -C "$TMP" --wildcards "*/$FIRST_APP/*" 2>/dev/null; then
        COUNT=$(find "$TMP" -type f | wc -l)
        echo "   extracted '$FIRST_APP' — $COUNT files"
        echo "   OK — the archive can actually be read back"
    else
        echo "   WARNING: extraction of '$FIRST_APP' failed"
    fi
else
    echo "   could not identify an app directory to test"
fi
rm -rf "$TMP"
echo
echo "Done."
