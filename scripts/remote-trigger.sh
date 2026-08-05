#!/usr/bin/env bash
# remote-trigger.sh — run the backup on your Zima from another machine.
#
# Why bother? ZimaOS is an appliance OS: its root filesystem is read-only, cron
# is not enabled, and anything you install can be wiped by an OS update. Rather
# than fight that, keep the schedule on a machine that is already always-on (a
# Raspberry Pi, a NAS, a small VM) and let it drive the Zima over SSH.
#
# Setup, once:
#   ssh-keygen -t ed25519 -f ~/.ssh/zima          # if you don't have a key
#   ssh-copy-id -i ~/.ssh/zima.pub USER@ZIMA_IP   # so this runs unattended
#
# Usage:
#   ZIMA=user@192.0.2.10 bash remote-trigger.sh
#
# Optional: set WEBHOOK to any URL that accepts {"content": "..."} JSON
# (Discord, Slack via a workflow, ntfy, …) and you get a pass/fail message.
set -uo pipefail

ZIMA="${ZIMA:?set ZIMA=user@host, e.g. ZIMA=alice@192.0.2.10}"
PAYLOAD="${PAYLOAD:-$(dirname "$0")/backup-appdata.sh}"
LOG="${LOG:-$HOME/.local/state/zima-backup.log}"
WEBHOOK="${WEBHOOK:-}"

mkdir -p "$(dirname "$LOG")"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

if [ ! -f "$PAYLOAD" ]; then
    echo "cannot find backup-appdata.sh (set PAYLOAD=/path/to/it)" >&2
    exit 1
fi

echo "[$(ts)] === backup start ===" >> "$LOG"

# Stream the script over SSH and run it there. Nothing is installed on the Zima,
# so an OS update cannot break it and there is nothing to keep in sync.
OUT=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$ZIMA" 'bash -s' < "$PAYLOAD" 2>&1)
RC=$?

printf '%s\n' "$OUT" >> "$LOG"
SIZE=$(printf '%s\n' "$OUT" | sed -n 's/.*SIZE=\([^ ]*\).*/\1/p' | tail -1)
echo "[$(ts)] === backup end rc=$RC size=${SIZE:-?} ===" >> "$LOG"

printf '%s\n' "$OUT" | tail -3

# Notification is best-effort: a failed webhook must never mark a good backup bad.
if [ -n "$WEBHOOK" ]; then
    python3 - "$WEBHOOK" "$RC" "${SIZE:-?}" <<'PY' || true
import json, sys, urllib.request
url, rc, size = sys.argv[1], sys.argv[2], sys.argv[3]
msg = (f"AppData backup OK — {size}" if rc == "0"
       else f"AppData backup FAILED (exit {rc})")
req = urllib.request.Request(
    url,
    data=json.dumps({"content": msg}).encode(),
    headers={"Content-Type": "application/json", "User-Agent": "zima-backup/1.0"},
)
try:
    urllib.request.urlopen(req, timeout=10)
except Exception as e:
    print("notify failed:", e)
PY
fi

exit "$RC"
