# 03 · Apps CasaOS can't eat

**My Homepage dashboard vanished from CasaOS twice. The second time, the file I'd used to bring it back had gone too.**

Both times the data was fine: every tile, widget and theme file was still in `AppData`. What disappeared was the app
itself. The fix that stuck was to stop installing it as a CasaOS app at all, and run it as a plain `docker run`
container with a restart policy. It has stayed up since.

This recipe is that move, for any app you'd be upset to lose, plus the two things that broke along the way.

---

## What happened

[Homepage](https://gethomepage.dev) went on the Zima from the BigBear CasaOS app store, as `big-bear-homepage`.

**The first time**, the dashboard stopped loading. There was no container, and CasaOS no longer knew the app
(`casaos-cli` returned a 404 for it). But two things had survived:

- the config, at `/DATA/AppData/big-bear-homepage/config/`
- the compose file CasaOS had installed it from, at `/DATA/.casaos/apps/big-bear-homepage/docker-compose.yml`

So it came back by reinstalling from that leftover file:

```bash
casaos-cli app-management install -f /DATA/.casaos/apps/big-bear-homepage/docker-compose.yml
```

That compose file is root-owned and mode 0600, so reading it needs the root trick from
[recipe 00](00-borrowing-root-from-docker.md). The reinstall reused the existing config folder, so nothing on the
dashboard was lost.

**The second time**, about two months later, the same thing happened, except `/DATA/.casaos/apps/big-bear-homepage/`
had gone as well. No container, no app, no compose file. Only the config folder was left.

I never found out what removed it. I don't have to know, because the fix doesn't depend on it.

---

## The fix: take it out of CasaOS

A container you start yourself with `docker run` isn't a CasaOS app, so there's no app record for CasaOS to drop.
Docker restarts it on its own after a reboot or a crash, because of `--restart unless-stopped`.

Point it at the config folder that survived:

```bash
docker run -d --name homepage --restart unless-stopped -p 3000:3000 \
  -v /DATA/AppData/big-bear-homepage/config:/app/config \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -e HOMEPAGE_ALLOWED_HOSTS=192.0.2.10:3000,localhost:3000,127.0.0.1:3000 \
  ghcr.io/gethomepage/homepage:v2.4.0
```

Swap `192.0.2.10` for your Zima's address. Every tile came back, because the config was never the problem.

Keep the command somewhere that isn't the Zima: a text file in your notes, a password manager entry, a repo. That
command *is* the app now, and it's the thing you'd need first after a disaster.

---

## Trap 1: a blank page and a 400

Homepage 1.x and later refuse any request whose `Host` header isn't in `HOMEPAGE_ALLOWED_HOSTS`. Leave it out and
every browser visit gets a blank `400`, which looks exactly like a broken container.

Put every name and address you'll type in the browser in that list, with the port. If you later reach it by a new
name (a reverse proxy, say), add that name too, then recreate the container.

## Trap 2: the restart policy can drift

When I upgraded it this October, the running container had `restart=no`, not `unless-stopped`. Something along the
way had recreated it without the flag, and the next reboot would have left it off.

Check it, and check it again after anything else has touched the container:

```bash
docker inspect homepage --format '{{.Config.Image}} {{.HostConfig.RestartPolicy.Name}}'
```

```
ghcr.io/gethomepage/homepage:v2.4.0 unless-stopped
```

If it says `no`, `docker update --restart unless-stopped homepage` fixes the running container. It only lasts until
the container is next recreated, so make sure the command you keep has the flag in it too.

---

## Upgrading a plain container

There's no "update" button any more, which is the point. Upgrade on purpose:

```bash
docker pull ghcr.io/gethomepage/homepage:v2.4.0          # the new tag
docker stop homepage && docker rename homepage homepage-old
# the same docker run command as above, with the new tag
docker run -d --name homepage --restart unless-stopped ...
```

Leave `homepage-old` stopped for a week as your rollback, then `docker rm homepage-old`. A copy of the config folder
before the upgrade costs a few kilobytes.

Going from 1.8.0 to 2.4.0 took exactly that and nothing else. Version 2's "breaking" change is a login gate
(`HOMEPAGE_AUTH_ENABLED`) that stays off unless you turn it on.

---

## Which apps to move

Not all of them. CasaOS installs are fine for things you could reinstall in two minutes with nothing to lose. Move
the ones where losing the *app* would hurt:

- anything you've configured by hand (dashboards, monitoring, reverse proxies)
- anything other machines depend on, so a missing container breaks more than one thing
- anything you'd struggle to set up again from memory

For each one, find its data folder under `/DATA/AppData/<app>/` and its compose file under `/DATA/.casaos/apps/<app>/`,
copy the image, ports, volumes and environment into a `docker run` (or your own compose file kept off the Zima), then
remove the CasaOS app. Back up the data folder first ([recipe 01](01-backing-up-appdata.md)).

[Recipe 04](04-uptime-kuma-on-the-zima.md) does the same for Uptime Kuma.

---

*Verified on a ZimaBlade running ZimaOS: the two disappearances, the recovery from the leftover compose file, the
`HOMEPAGE_ALLOWED_HOSTS` 400 and the drifted restart policy all happened on this machine. Image tags and the
`docker inspect` output were read off it on 11 October 2026.*

Back to the [recipe index](../README.md) · previous: [02 · Offsite backup for a photo library](02-offsite-photo-backup.md) · next: [04 · Uptime Kuma on the Zima](04-uptime-kuma-on-the-zima.md)
