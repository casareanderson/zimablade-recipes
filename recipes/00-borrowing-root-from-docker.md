# 00 · Borrowing root from Docker

**The problem:** you need to read a root-owned file, edit a system config, or run something as root — and on ZimaOS, `sudo` asks for a password you were never given.

**The answer:** you're in the `docker` group, and Docker can hand a container the entire host.

---

## The one-liner

```bash
docker run --rm --privileged --pid=host -v /:/host alpine \
    chroot /host /bin/bash -c 'whoami; ls -ld /root'
```

Read it left to right:

| Part | What it does |
|---|---|
| `docker run --rm` | start a container, delete it when it exits — nothing is left behind |
| `--privileged` | drop the restrictions that normally keep a container away from the host |
| `--pid=host` | share the host's process list (needed if you want to signal host processes) |
| `-v /:/host` | mount the host's entire filesystem at `/host` inside the container |
| `alpine` | a 5 MB image, pulled once, that exists purely to be a shell |
| `chroot /host` | make `/host` the new `/`, so you're now running the **host's** binaries as root |

That last step matters more than it looks. After `chroot`, you're not using Alpine's tools — you're using the host's own `tar`, `find`, `systemctl`. Same versions, same behaviour, same paths as if you'd logged in as root.

## Understand what you just did

`--privileged` plus the host filesystem **is root on the machine**. Not "a bit like root" — actually root. It can read every secret, modify any file, and reboot the box.

That's fine for a command you've read and understood. It is not fine pasted from a forum post you skimmed. If a tutorial tells you to run that pattern and doesn't explain it, close the tab.

There's no way around this on an immutable appliance OS: either you have root or you don't, and this is the sanctioned door. Just walk through it deliberately.

## Things it's good for

**Reading root-only files** — TLS keys, tokens, auth databases:

```bash
docker run --rm --privileged -v /:/host alpine \
    chroot /host /bin/bash -c 'ls -l /DATA/AppData/nginxproxymanager/data/tls'
```

**Running host systemd** — because the container has no init of its own:

```bash
docker run --rm --privileged --pid=host -v /:/host alpine \
    chroot /host /bin/bash -c 'systemctl status docker'
```

**Making complete backups** — the reason recipe 01 exists. A plain `tar` as the SSH user silently omits every directory it can't read.

## Two gotchas

**Quoting gets painful fast.** You're nesting a shell inside a shell inside SSH. Anything with quotes, `$` or parentheses will eventually bite you. Push a script and run that instead of building ever-longer one-liners:

```bash
cat > /tmp/job.sh <<'EOF'
# ... your commands, quoted however you like ...
EOF
docker run --rm --privileged -v /:/host alpine chroot /host /bin/bash /tmp/job.sh
```

The `<<'EOF'` quoting is deliberate — it stops the *outer* shell expanding anything.

**`HOME` isn't writable**, so tools that write to `~` fail in confusing ways. `docker build` is the common one:

```
mkdir /DATA/.docker/buildx: permission denied
```

Fix by pointing it somewhere writable:

```bash
DOCKER_CONFIG=/tmp/.docker docker build ...
```

## Check it worked

```bash
docker run --rm --privileged -v /:/host alpine chroot /host /bin/bash -c 'id'
```

You want `uid=0(root)`. If you get a permission error instead, your user isn't in the `docker` group — check with `id`. On stock ZimaOS it is.

---

Next: **[01 · Backing up AppData properly](01-backing-up-appdata.md)**, which puts this to work.
