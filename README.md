# Running a ZimaBlade like a server, not an appliance

ZimaOS is deliberately appliance-shaped: the root filesystem is read-only, the SSH user can't `sudo`, `cron` isn't enabled, and an OS update can replace anything you installed. That's good engineering — it's why the thing is hard to break.

It also means most homelab advice you'll find doesn't apply, and some of it fails *quietly*. This is a collection of recipes for working with that design instead of against it, written from a ZimaBlade 7700 that runs a real photo library, a reverse proxy, SSO and a document stack.

**Every command here was run on the machine.** Where something didn't behave the way the docs implied, that's written down too — including the parts where my first attempt was wrong.

---

## Start here

New to this? Read **[00 · Borrowing root from Docker](recipes/00-borrowing-root-from-docker.md)** first — it's short, and every other recipe depends on it.

Then **[01 · Backing up AppData properly](recipes/01-backing-up-appdata.md)**, because right now your backups are probably missing your TLS certificates and nothing has told you.

## The recipes

| | What it solves | The bit nobody mentions |
|---|---|---|
| **[00 · Borrowing root from Docker](recipes/00-borrowing-root-from-docker.md)** | You need root on a box where `sudo` wants a password you don't have | A privileged container with the host filesystem mounted *is* root — powerful, and worth understanding before you paste it |
| **[01 · Backing up AppData properly](recipes/01-backing-up-appdata.md)** | Your app data — Immich's database, your certificates, your tokens | A plain `tar` exits 2 and **still writes the archive**. It looks fine and your certs aren't in it |

More recipes are being added as each one is verified on the machine rather than written from memory.

## The scripts

| | |
|---|---|
| [`scripts/backup-appdata.sh`](scripts/backup-appdata.sh) | Complete AppData backup, with `--dry-run` to show what a plain tar would miss |
| [`scripts/verify-backup.sh`](scripts/verify-backup.sh) | Proves an archive is complete and restorable — four checks, including one that only a privileged backup can pass |
| [`scripts/remote-trigger.sh`](scripts/remote-trigger.sh) | Runs the backup from another machine over SSH, so nothing is installed on the Zima |

All plain bash, commented, no dependencies beyond what ZimaOS ships. Read them before running them — including these.

---

## What makes ZimaOS different

Worth internalising before you troubleshoot anything. These are the four that cost me the most time:

**You can't `sudo`, but you can run containers.** The SSH user is in the `docker` group, and Docker can be told to give a container the whole host. That's the escalation path — see recipe 00.

**`/` is read-only, and `/usr` is an overlay.** Anything you install into a system directory can vanish on an OS update. Put your own files in `/DATA/Documents`, or better, don't put them on the Zima at all — drive it over SSH from a machine that isn't immutable.

**`cron` isn't running.** Schedules live either in systemd timers or, more sensibly, on some other always-on box that SSHes in.

**GNU tar, BusyBox find.** This combination catches people out because most guides assume both are GNU:

| Works | Doesn't exist |
|---|---|
| `tar --warning=`, `tar --exclude=` (GNU tar 1.35) | `find -readable` |
| `find -mtime`, `find -delete` | `find -printf` |

That one bit me while writing recipe 01: my first version of the "what would a plain tar miss?" check used `find ! -readable` with stderr discarded. On ZimaOS that prints `find: unrecognized: -readable` and returns nothing — so it reported a clean result on a box with eight unreadable directories. **A check that can only pass is worse than no check at all.**

---

## Hardware and versions

ZimaBlade 7700 (Intel N3350) · ZimaOS · GNU tar 1.35 · BusyBox find · Docker, running the usual homelab mix: a photo library, a reverse proxy, an identity provider and a document stack.

Recipes should apply to any ZimaOS or CasaOS box. Where something is specific to this hardware, it says so.
