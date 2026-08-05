# ZimaSpace "Share a Server Tutorial" — submission notes

**Campaign:** https://shop.zimaspace.com/pages/share-a-server-tutorial-with-zimaspace
**Window:** 4–30 August 2026 · **Winners announced:** 4 September 2026
**Prizes:** ZimaBoard 2 832 (grand) · ZimaBlade 7700 Dual Bay NAS Kit (second) · $50 gift cards · ZimaOS+

**How to submit:** there is no email address. The "Share a Tutorial" button is an anchor to the
`#giveaway` section further down the same page, which renders an inline form asking for your
email, the tutorial link, and a few words on why you recommend it. **One tutorial per participant.**

**Primary link:** https://github.com/casareanderson/zimablade-recipes
**Companion (linked from the README):** https://github.com/casareanderson/zimablade-gpu-immich

Both are original and written from the same machine. Because only one entry is allowed, the
recipes repo is the entry and cross-links the GPU report from its README, so a judge following
the link finds both.

---

## Why I recommend it

I'm recommending this because it covers the thing every beginner gets wrong on a ZimaBlade and
nobody warns them about: your backups are probably incomplete, and nothing tells you.

ZimaOS is an appliance OS — the root filesystem is read-only, the SSH user can't `sudo`, and cron
isn't running. That's good design, but it means most homelab advice you find online doesn't apply,
and some of it fails quietly. If you back up `AppData` the obvious way, `tar` can't read the
root-owned directories, warns on a stream you never see, and still writes the archive. You get a
file of a believable size that's missing your TLS certificates and your tunnel tokens. You find out
on the day you restore.

The guide shows why that happens, how to escalate properly using a privileged container (the
sanctioned way to get root on an immutable OS), and — the part I think matters most — it ships a
verifier that proves your archive contains the directories an ordinary backup couldn't read. A
backup you've never checked isn't a backup.

It also covers something I rarely see written down: backing up the app *definitions*, not just the
data. On CasaOS the compose files live outside `AppData`, so an AppData-only backup restores every
byte of your photo library and leaves you with no idea how to rebuild the services that serve it.
That's 52 KB of files that turn a disaster into an inconvenience.

And there's a recipe for getting a large photo library offsite affordably: upload each original once
with `rclone copy` rather than `sync` (sync mirrors deletions — lose a photo locally and your backup
deletes it too), and skip the transcodes and thumbnails the server can regenerate. On my box that's
693 GB of video and 19 GB of thumbnails that never leave the house, and a nightly run that uploads a
handful of new files against an 815 GB library.

Everything in it was run on a real ZimaBlade rather than written from documentation — including the
parts where my first attempt was wrong. One check I wrote reported a clean result on a box that
demonstrably had eight unreadable directories, because ZimaOS ships GNU tar but BusyBox `find`, and
`find -readable` doesn't exist there. That's in the guide too, because a check that can only pass is
worse than no check at all.

It's written for someone who has just got their first server running and doesn't yet know what they
don't know.

## Short version (if the field is small)

Beginner-focused, and it fixes a problem most ZimaOS users don't know they have: back up `AppData`
the obvious way and `tar` silently omits every root-owned directory — your TLS certificates and
tokens aren't in the archive, which still looks perfectly healthy. The guide explains why, shows the
privileged-container escalation that fixes it, and includes a verifier that proves your archive is
actually complete. It also covers backing up the compose files (which live outside AppData, so an
AppData backup leaves you unable to rebuild your services) and getting a large photo library offsite
cheaply by uploading each original once. Everything was tested on a real ZimaBlade, including the
parts where my first attempt was wrong.

---

## Notes to self

- Both entries are **original**, which the rules say gets priority for hardware prizes.
- The GPU report ends in a documented failure. Kept deliberately — a working Immich write-up
  competes with dozens of entries; an Xid 79 diagnosis competes with none.
- Hardware prize winners are invited to collaborate with the ZimaSpace team on a blog post.
- The GPU report is also worth posting to community.zimaspace.com, where people ask about
  GPU support directly. That's separate from the giveaway and doesn't use up the one entry.
