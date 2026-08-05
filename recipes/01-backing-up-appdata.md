# 01 · Backing up AppData properly

**If you back up `AppData` the obvious way, your archive is missing your certificates — and it still looks fine.**

`tar` does warn, on stderr, and exits with code 2. But it *keeps going* and *still writes the archive*. So you end up with a file of a believable size, containing almost everything, missing the handful of things you cannot recreate: TLS certificates, tunnel tokens, auth databases. If your backup is a one-liner in a cron job with output redirected — and most are — nothing ever surfaces that warning.

You find out at restore time. This repo is the fix, plus a script that proves your archive is actually complete.

Measured on a stock ZimaBlade 7700, backing up as the normal SSH user:

```console
$ tar -cf /dev/null /DATA/AppData
tar: /DATA/AppData/nginxproxymanager/data/tls: Cannot open: Permission denied
tar: /DATA/AppData/nginxproxymanager/data/access: Cannot open: Permission denied
tar: /DATA/AppData/portainer/backups: Cannot open: Permission denied
...
$ echo $?
2

$ ls -ld /DATA/AppData/nginxproxymanager/data/tls
drwx------ 1 root root 90 Jun 13 00:56    # 0700, owned by root
```

That `tls` directory is every certificate your reverse proxy serves.

**For beginners:** you don't need to understand any of this to use it. Skip to [Quick start](#quick-start) — it's three commands.

---

## Why the obvious way fails

Everything your apps *remember* lives in one place — `/DATA/AppData`. Immich's database, Home Assistant's config, your reverse proxy's certificates. Lose it and you're rebuilding every app from scratch.

So you SSH in and do the natural thing:

```bash
tar -czf backup.tar.gz /DATA/AppData
```

Here's the problem. Three facts that are individually fine and collectively bite:

1. **AppData is owned by `root`**, and the sensitive parts are mode `0700` — readable *only* by root. That's correct security: your TLS private key should not be world-readable.
2. **The ZimaOS SSH user is not root**, and `sudo` wants a password you were never given. ZimaOS is an appliance OS, not a general-purpose Linux box.
3. **`tar` keeps going when it can't read something.** It reports what it skipped on stderr and carries on. In a terminal you might notice. In a scheduled job with output redirected, nobody ever does.

The result is an archive that looks healthy and is missing exactly the irreplaceable files. Everything else — the bulk, the file count, the size — looks normal, because the vast majority of AppData *is* readable.

> **The general lesson, worth more than this script:** a backup you have never restored is not a backup. Size is not completeness. See [Step 2](#2-check-it-is-actually-complete) — checking takes ten seconds.

## The fix: borrow root from Docker

*(Full explanation in [recipe 00](00-borrowing-root-from-docker.md) — the short version:)*

You can't `sudo`, but you *can* run containers — and a container can be given the whole host filesystem. That's the sanctioned way to become root on an immutable OS:

```bash
docker run --rm --privileged --pid=host -v /:/host alpine \
    chroot /host /bin/bash -c 'tar czf ... /DATA/AppData'
```

Reading it left to right: run a throwaway (`--rm`) Alpine container, give it full privileges, mount the host's root filesystem at `/host`, then `chroot` into it and run the host's own `tar` as root.

Nothing gets installed. Nothing survives the run. An OS update can't break it.

> **Do think about what you just did.** `--privileged` with the host filesystem mounted *is* root on the machine. That's fine for a backup script you have read. Do not paste that pattern from a random forum post without reading it first.

---

## Quick start

**You need:** a ZimaBlade (or any ZimaOS/CasaOS box) and SSH access to it.

**1. Get the scripts onto the Zima**

```bash
ssh YOUR_USER@YOUR_ZIMA_IP
cd /DATA/Documents          # a writable directory that survives updates
curl -fsSLO https://raw.githubusercontent.com/casareanderson/zimablade-recipes/main/scripts/backup-appdata.sh
curl -fsSLO https://raw.githubusercontent.com/casareanderson/zimablade-recipes/main/scripts/verify-backup.sh
```

**2. See what a plain tar would miss** *(optional, but it makes the point)*

```bash
bash backup-appdata.sh --dry-run
```

This writes nothing. It lists the directories your user cannot read — every one of those is silently absent from a naive backup.

**3. Back up**

```bash
bash backup-appdata.sh
```

You'll get `/DATA/Backups/appdata-YYYYMMDD_HHMMSS.tar.gz`. Expect a few minutes and a file of a gigabyte or two, depending on your apps.

---

## Then: check it

### 1. Does it exist?

```bash
ls -lh /DATA/Backups/
```

### 2. Check it is actually complete

```bash
bash verify-backup.sh
```

This is the part people skip, and it's the part that matters. It runs four checks:

| Check | What it catches |
|---|---|
| **Integrity** | truncated or corrupt archives — common when a disk fills mid-backup |
| **Completeness** | the silent-skip failure: are certs, keys and tokens actually in there? |
| **Coverage** | apps on disk vs apps in the archive, and names the missing ones |
| **Restore rehearsal** | extracts one app to a temp dir, proving the archive can be read back |

If check 2 says it found no privileged entries and you run anything with TLS or a tunnel, your archive is incomplete. That is the whole reason this repo exists.

### 3. Restore (when you need it)

Restoring is just extraction, but it must be done **as root**, or you'll recreate the same permissions problem in reverse:

```bash
# stop the app first, so nothing is writing while you replace its data
docker stop immich-server

docker run --rm --privileged -v /:/host alpine \
    chroot /host /bin/bash -c \
    'tar -xzf /DATA/Backups/appdata-20260805_030000.tar.gz -C /DATA --strip-components=0'

docker start immich-server
```

Practise this **before** you need it. Restore one unimportant app today; you'll learn more in five minutes than from any guide.

---

## Running it automatically

A backup you have to remember to run is not a backup.

ZimaOS makes this awkward on purpose: the root filesystem is read-only, `cron` isn't enabled, and anything you install can be replaced by an OS update. Two honest options:

### Option A — drive it from another machine *(recommended)*

Keep the schedule on something already always-on: a Pi, another NAS, a small VM. It SSHes in and streams the script across, so **nothing is installed on the Zima at all**.

```bash
# on the other machine, once:
ssh-keygen -t ed25519 -f ~/.ssh/zima
ssh-copy-id -i ~/.ssh/zima.pub YOUR_USER@YOUR_ZIMA_IP

# then, weekly:
crontab -e
0 3 * * 0  ZIMA=YOUR_USER@YOUR_ZIMA_IP /path/to/remote-trigger.sh
```

`remote-trigger.sh` logs each run and can post to a webhook — set `WEBHOOK=` to any URL taking `{"content": "..."}` (Discord, ntfy, a Slack workflow) and you'll be told when a backup fails. **Alert on failure, or you will not find out.**

### Option B — a systemd timer on the Zima

Possible, but you'd be writing units into an overlay an OS update can replace. Option A ages better.

---

## Where the archives should live

This script writes to `/DATA/Backups` by default — **on the same machine as the data**.

That protects you from the common disasters: a bad update, a broken app, a config change you can't undo, an accidental delete. It does **not** protect you from theft, fire, or the disk dying. That's not a flaw, it's a scope: local snapshots and offsite copies are different jobs.

When you're ready for offsite, point something like [rclone](https://rclone.org/) or [restic](https://restic.net/) at `/DATA/Backups` and push to cheap object storage. Back up the *archives*, not AppData directly — you've already solved the permissions problem here.

---

## Options

Every setting is an environment variable:

```bash
RETENTION_DAYS=60 bash backup-appdata.sh      # keep archives for 60 days (default 30)
DEST_DIR=/media/big-disk/backups bash backup-appdata.sh
SRC_DIR=/DATA/AppData bash backup-appdata.sh
```

| Variable | Default | |
|---|---|---|
| `SRC_DIR` | `/DATA/AppData` | what to back up |
| `DEST_DIR` | `/DATA/Backups` | where archives go |
| `RETENTION_DAYS` | `30` | archives older than this are deleted |
| `EXCLUDES` | `--exclude=*/cache --exclude=*/logs` | skipped patterns |

---

## Troubleshooting

**`cannot talk to Docker`** — your SSH user isn't in the `docker` group. On stock ZimaOS it is; if you've customised, check `id`.

**`tar: ... file changed as we read it`** — normal. Containers write while you back up. The script treats tar's exit code 1 as success and anything ≥ 2 as failure, which is the correct reading.

**The archive is much smaller than expected** — run `verify-backup.sh`. Usually either the excludes are catching more than you meant, or an earlier run failed partway.

**`No space left on device`** — check `df -h /DATA`. Archives accumulate until `RETENTION_DAYS` clears them; on a small internal disk, point `DEST_DIR` at a larger volume.

**A script you found elsewhere fails with `find: unrecognized: -readable`** — see below.

---

## One ZimaOS quirk worth knowing

ZimaOS ships **GNU `tar` but BusyBox `find`**. That combination catches people out, because most guides assume both are GNU:

| | |
|---|---|
| `tar --warning=`, `tar --exclude=` | work (GNU tar 1.35) |
| `find -mtime`, `find -delete` | work |
| `find -readable`, `find -printf` | **do not exist** — BusyBox errors out |

It bit me while writing this. An early version of the dry-run used `find ! -readable` to list what a plain tar would miss, with stderr sent to `/dev/null`. On ZimaOS that prints `find: unrecognized: -readable` and returns nothing — so the check reported a *clean* result on a box that demonstrably had unreadable directories. A test that can only pass is worse than no test.

The scripts here use a shell `[ -r "$dir" ]` loop instead, which is portable and matches what `tar` can actually open.

---

## Where the scripts live

[`scripts/backup-appdata.sh`](../scripts/backup-appdata.sh) · [`scripts/verify-backup.sh`](../scripts/verify-backup.sh) · [`scripts/remote-trigger.sh`](../scripts/remote-trigger.sh)

---

*Verified on a ZimaBlade 7700 running ZimaOS: the permission errors, the archive contents, and the tooling versions were all read off the machine.*

Back to the [recipe index](../README.md) · previous: [00 · Borrowing root from Docker](00-borrowing-root-from-docker.md)
