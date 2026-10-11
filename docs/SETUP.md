# Setting up the ZimaBlade recipes

The recipes are things to read, and the scripts are what you run. This guide gets the backup scripts going in three
steps: a **practice run** on any Linux machine with Docker, then the **real thing on your Zima**, then a **schedule**
from another machine. About 20 minutes, plus however long your first real backup takes.

The practice run is marked as tested: it runs on a fresh Ubuntu runner every week in
[`setup-check`](../.github/workflows/setup-check.yml), so the scripts' core trick (root through a privileged
container) and the verify script are proven on every change. CI has no Zima, so the steps on the Zima itself aren't
marked.

## What you need

- A ZimaBlade, ZimaBoard or another ZimaOS / CasaOS box, with SSH access as a user in the `docker` group (the default
  on ZimaOS).
- Read **[recipe 00 · Borrowing root from Docker](../recipes/00-borrowing-root-from-docker.md)** first. The backup
  script runs a privileged container, which is root on the machine. Know what that means before you run it.
- For the schedule: another always-on Linux machine (a Raspberry Pi, another NAS, a small VM) that can SSH to the Zima.
- For the offsite photo backup (recipe 02): [rclone](https://rclone.org) and a storage account.

## 1. Practice on any Linux machine with Docker

Before pointing anything at your real `AppData`, watch the problem and the fix happen on a throwaway folder. This
builds a fake `AppData` with one ordinary app and one root-only 0700 `tls` folder, like a reverse proxy's
certificates.

```sh setup-check
git clone -q https://github.com/casareanderson/zimablade-recipes
cd zimablade-recipes
P=/tmp/zima-practice
sudo mkdir -p $P/AppData/notes $P/AppData/proxy/data/tls $P/apps/proxy
echo hello | sudo tee $P/AppData/notes/note.txt > /dev/null
echo "pretend certificate" | sudo tee $P/AppData/proxy/data/tls/site.pem > /dev/null
echo "services: {}" | sudo tee $P/apps/proxy/docker-compose.yml > /dev/null
sudo chmod 700 $P/AppData/proxy/data/tls
export SRC_DIR=$P/AppData DEST_DIR=$P/Backups CONFIG_DIRS=$P/apps
```

The three `export`s point the scripts at the practice folder instead of `/DATA`. Every setting is an environment
variable like this; see the [README](../README.md#configuration) for the full list.

**The trap.** A plain `tar` as your normal user can't read the `tls` folder. It complains, exits 2, and writes the
archive anyway, without the certificate in it:

```sh setup-check
tar -czf /tmp/plain.tar.gz -C $P AppData || echo "tar exit code $?"
tar -tzf /tmp/plain.tar.gz
! tar -tzf /tmp/plain.tar.gz | grep -q site.pem
```

**The dry run** lists exactly the folders a plain tar would miss, and changes nothing:

```sh setup-check
bash scripts/backup-appdata.sh --dry-run | tee /tmp/dry-run.txt
grep -q "proxy/data/tls" /tmp/dry-run.txt
```

**The real backup** runs the host's own `tar` as root through a privileged Alpine container, so the `tls` folder
gets in. It writes two archives: AppData, and the app definitions (compose files):

```sh setup-check
bash scripts/backup-appdata.sh
ls -l $P/Backups
```

The output ends with `RESULT ARCHIVE=... RC=0`, `RESULT CONFIG=...` and `Backup finished. Now check it is actually
complete`.

**The proof.** `verify-backup.sh` checks the newest archive four ways: gzip integrity, whether the root-only folders
made it in, coverage against the live folder, and a test restore of one app:

```sh setup-check
bash scripts/verify-backup.sh | tee /tmp/verify.txt
grep -q "present: AppData/proxy/data/tls" /tmp/verify.txt
grep -q "root-only director(ies) are in the archive" /tmp/verify.txt
```

That's the line that matters: `OK — all 1 root-only director(ies) are in the archive`. An ordinary `tar` couldn't
have read it, so its presence proves the privileged backup worked.

Tidy up the practice folder when you're done (it's in `/tmp`, nowhere near your real data):

```
sudo rm -rf /tmp/zima-practice /tmp/plain.tar.gz
unset SRC_DIR DEST_DIR CONFIG_DIRS
```

## 2. On your Zima

Not tested in CI from here.

Copy the scripts over and log in:

```
scp scripts/backup-appdata.sh scripts/verify-backup.sh you@zima:~/
ssh you@zima
```

Do a dry run against the real `AppData`. It changes nothing:

```
bash backup-appdata.sh --dry-run
```

You'll see your source (`/DATA/AppData`) and destination (`/DATA/Backups`), the app-definition folder
(`/DATA/.casaos/apps`) and its size, and the list of folders a plain tar would miss, or `(none — every directory is
readable by <you>)`. "None" is a real result on some boxes; the dry run is how you find out about yours.

Then the backup and the proof:

```
bash backup-appdata.sh
bash verify-backup.sh
```

Read the scripts before you run them. `backup-appdata.sh` runs `docker run --privileged -v /:/host`, which is root.

**Where the archives go.** `/DATA/Backups` is on the Zima's small eMMC by default. If your `AppData` is big, point it
at the array: `DEST_DIR=/media/ZM-Data/Backups bash backup-appdata.sh` (and the same `DEST_DIR` for
`verify-backup.sh`). [Recipe 05](../recipes/05-disk-pressure-and-a-coldstore.md) has the eMMC-versus-array numbers.

## 3. Run it on a schedule, from another machine

ZimaOS doesn't run `cron`, and anything you install on its system folders can vanish on an update. So run the backup
*from* a machine that's always on anyway. `remote-trigger.sh` streams `backup-appdata.sh` over SSH, so nothing is
installed on the Zima.

On the other machine:

```
git clone https://github.com/casareanderson/zimablade-recipes
cd zimablade-recipes
ssh-copy-id you@zima                    # once, so it can run unattended
ZIMA=you@zima bash scripts/remote-trigger.sh
```

It logs to `~/.local/state/zima-backup.log`. Add `WEBHOOK=https://...` (anything that accepts `{"content": "..."}`,
such as a Discord webhook) to get a pass or fail message; that part needs Python 3 on this machine.

Then a cron line, for 03:00 every night:

```cron
0 3 * * *  cd /home/you/zimablade-recipes && ZIMA=you@zima bash scripts/remote-trigger.sh
```

Run `verify-backup.sh` on the Zima now and then too. A backup you've never checked is a hope, not a backup.

## 4. Offsite photos (optional)

[Recipe 02](../recipes/02-offsite-photo-backup.md) covers the Immich library: originals only, `rclone copy` and never
`sync`, after a database dump that refuses to replace a good dump with a bad one. Set up an rclone remote first, then:

```
DRY_RUN=1 bash scripts/photo-offsite-backup.sh    # what would transfer
bash scripts/photo-offsite-backup.sh
```

Credentials go in rclone's config or `RCLONE_CONFIG_OFFSITE_*` variables, never in the script; its header explains
why.

## Common problems

| you see | what it means | what to do |
|---|---|---|
| `ERROR: docker not found.` | no Docker on this machine | run it on the Zima, where Docker is the way in |
| `ERROR: cannot talk to Docker as <you>.` | your user isn't in the `docker` group | on ZimaOS it normally is; elsewhere, add yourself and log in again |
| `tar: ...: Cannot open: Permission denied` and exit 2 from your own tar | the trap in step 1 | use `backup-appdata.sh` |
| `Backup FAILED (exit 2)` | tar inside the container hit a real error | read the lines above it; exit 1 ("file changed as we read it") is normal and isn't a failure |
| `No archive found. Looked in: /DATA/Backups` | no backup yet, or you used a different `DEST_DIR` | pass the same `DEST_DIR`, or the archive path: `bash verify-backup.sh path/to/appdata-*.tar.gz` |
| `FAILED — N of M root-only directories are absent.` | the archive was made without root | re-run `backup-appdata.sh` |
| `WARNING: none found.` under privileged entries | no cert-, key- or token-looking files in the archive | fine if you run no TLS or tunnels; otherwise suspect a non-root backup |
| `find: unrecognized: -readable` in your own scripts | ZimaOS ships BusyBox `find` | use a shell `[ -r "$d" ]` test, as these scripts do |

## Update

```
cd zimablade-recipes && git pull
```

Copy the scripts to the Zima again if you keep copies there. `remote-trigger.sh` always streams the current one.

## Uninstall

Remove the cron line on the other machine, delete the scripts from the Zima, and keep (or delete) the archives in
your `DEST_DIR`. Nothing else was installed anywhere: the backup container is removed with `--rm` every time it runs.
