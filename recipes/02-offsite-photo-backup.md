# 02 · Offsite backup for a photo library, without paying twice

A photo library is the hardest thing in a homelab to back up. It's large, it grows slowly, and it's the one dataset nobody can recreate. The usual advice — nightly archive, push it somewhere — falls apart the moment the library is bigger than your upload allowance.

This recipe uploads **each original once** and skips everything the server can rebuild.

Real numbers from the machine this was written on:

```console
$ du -sh /DATA/Gallery/immich/*
815G    library          ← originals, uploaded
693G    encoded-video    ← transcodes, NOT uploaded
 19G    thumbs           ← previews, NOT uploaded
161M    upload
703M    backups
```

```
SUMMARY status=ok new_files=13 lib_size=815G
SUMMARY status=ok new_files=3  lib_size=815G
SUMMARY status=ok new_files=8  lib_size=815G
```

Three consecutive nights against an 815 GB library: **thirteen files, then three, then eight.** The first run is a long haul. Every run after it costs minutes and pennies.

And **712 GB never leaves the house** — nearly half the total — because Immich regenerates thumbnails and transcodes on demand.

---

## The four decisions that matter

### 1. `copy`, never `sync`

This is the one to get right.

```bash
rclone copy  /photos remote:bucket    # only ever adds
rclone sync  /photos remote:bucket    # makes the remote match — including deletions
```

`sync` mirrors. Delete a photo locally — a bad import, a slipped click, ransomware encrypting your library — and the next run faithfully deletes it offsite too. Your backup helpfully destroys itself.

`copy` only adds. The remote becomes a safety net rather than a mirror. It costs you storage for things you deleted on purpose; that is a very cheap price.

### 2. Don't back up what the server can rebuild

Immich stores originals *and* derivatives: transcoded video, thumbnails, previews. Derivatives are large — here, more than the originals — and every one can be regenerated from the source file.

```bash
--exclude "encoded-video/**" --exclude "thumbs/**" --exclude "backups/**"
```

After a restore, Immich rebuilds them. You wait; you don't pay to store them for years.

### 3. A dump that fails must not overwrite one that worked

The classic backup disaster is not "no backup", it's "a backup that was overwritten by a broken one".

```bash
if pg_dump ... > "$DUMP.partial"; then
    if [ -s "$DUMP.partial" ]; then mv "$DUMP.partial" "$DUMP"   # promote
    else rm -f "$DUMP.partial"; fi                                # empty: discard
else
    rm -f "$DUMP.partial"                                         # failed: discard
fi
```

Write to `.partial`, promote only on success **and** non-empty. Yesterday's good dump survives today's failure. This pattern is worth using for every backup you ever write.

The dump also excludes derived tables — `geodata_places`, `face_search`, `asset_face`. They're ML output, rebuilt by re-running Immich's jobs, and they dominate the dump size.

> **The honest trade-off:** after restoring, you must re-run face recognition and smart search, which takes hours on a small box. You get a much smaller nightly dump in exchange. Decide deliberately — if you'd rather restore instantly, drop the `--exclude-table` flags.

### 4. On Backblaze, delete properly

```bash
rclone delete remote:bucket/database --min-age 7d \
    --exclude "immich-db-??????01_*.sql" --b2-hard-delete
```

Two things:

- **`--b2-hard-delete`** — without it, B2 keeps deleted files as hidden versions **and bills you for them**. People discover this from the invoice.
- **The `??????01_` exclusion** keeps every 1st-of-month dump forever. Seven days of recent history plus a monthly spine, at negligible cost.

---

## Doing it

**1. Get an offsite account.** Backblaze B2 is the usual choice for this (roughly $6/TB/month). Any rclone-supported provider works.

**2. Configure rclone**, once, on the machine holding the photos:

```bash
rclone config     # follow the prompts; name the remote "offsite"
```

**3. See what would happen** — this transfers nothing:

```bash
DRY_RUN=1 REMOTE=offsite:my-photo-backup bash photo-offsite-backup.sh
```

**4. Run it.** The first run uploads everything and may take days. That's fine; `copy` is resumable, so an interrupted run picks up where it stopped.

```bash
REMOTE=offsite:my-photo-backup bash photo-offsite-backup.sh
```

**5. Schedule it** from a machine that isn't the Zima — see [recipe 01](01-backing-up-appdata.md#running-it-automatically) for why, and `remote-trigger.sh` for how.

### Keeping the credentials out of the way

Don't put keys in the script. rclone reads them from the environment:

```bash
export RCLONE_CONFIG_OFFSITE_TYPE=b2
export RCLONE_CONFIG_OFFSITE_ACCOUNT=your_key_id
export RCLONE_CONFIG_OFFSITE_KEY=your_application_key
```

If a scheduler on another machine drives this over SSH, pipe those exports into the remote shell's **stdin**, ahead of the script:

```bash
{ printf 'export RCLONE_CONFIG_OFFSITE_KEY=%q\n' "$KEY"; cat photo-offsite-backup.sh; } \
    | ssh user@zima bash -s
```

**Why stdin and not arguments:** anything passed on a command line is visible in `ps` to every user on the box, and often lands in shell history. Environment-via-stdin avoids both, and leaves no file on the remote machine to forget about.

Use a **restricted application key** scoped to the one bucket, not your master key.

---

## Knowing it worked

The script ends with one machine-readable line:

```
SUMMARY status=ok new_files=8 lib_size=815G dump=immich-db-20260805_030002.sql errors=none
```

Have your scheduler grep that and alert on `status=fail`. **A backup nobody checks isn't a backup** — and unlike a broken service, a broken backup produces no symptoms until the day it matters.

Watch `new_files` too. A sudden zero on a library you're actively adding to means the source path moved or a mount is missing, not that you took no photos.

## Restoring

1. Restore the database dump into a fresh Postgres container: `psql -U postgres immich < immich-db-*.sql`
2. `rclone copy remote:bucket/upload /DATA/Gallery/immich` to bring the originals back
3. Start Immich and let it rebuild thumbnails and transcodes
4. Re-run the ML jobs (face recognition, smart search) — the tables you excluded

Rehearse steps 1 and 2 with a handful of files **before** you need them.

---

*Verified on a ZimaBlade 7700: the sizes, the nightly counts and the storage layout were read off the running machine.*

Back to the [recipe index](../README.md) · previous: [01 · Backing up AppData properly](01-backing-up-appdata.md)
