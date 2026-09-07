# Self-hosted ntfy for the phone alarm

The Ping Monitor's **Phone (ntfy)** channel can post to the public
`https://ntfy.sh` with no setup at all. This directory is for when that is not
good enough:

| | ntfy.sh (public) | This |
|---|---|---|
| Setup | none | a VM, a DNS record, 10 minutes |
| Who can read your alerts | anyone who guesses the topic | only accounts you create |
| Who can send fake alerts | anyone who guesses the topic | only the `monitor` token |
| Outage history | on someone else's server | on yours |

Start with ntfy.sh to prove the phone rings, then move here. Only the **Server**
and **Token** fields in the tool change.

## What it deploys

`ntfy` alone, behind a Caddy that **already runs on the host** — the same shape
as the ping monitor server: a separate compose project that joins that stack's
network from the outside, so nothing here can break what is already running
there, and `docker compose down` in this directory cannot take it with it.

ntfy publishes no port. Caddy is the only thing facing the world, and it reaches
ntfy by container name, so there is no plaintext way in from outside.

Two accounts are created, least privilege:

| Account | Access | Used by |
|---|---|---|
| `monitor` | **write-only** on the topic | the ping monitor, via a token |
| `phone` | **read-only** on the topic | the handsets |

Write-only for the sender is the point: if the desk PC is stolen, its token can
raise alarms but cannot read a single past outage.

`auth-default-access` is `deny-all`, so the topic name is no longer the only
thing standing between your outage log and the internet.

## Deploy

```bash
# on the server
git clone https://github.com/badshashorif/gcl-ping-monitor.git
cd gcl-ping-monitor/ntfy-server
cp .env.example .env
openssl rand -base64 24     # do this twice, for the two passwords
vi .env                     # domain, topic, the two passwords
./deploy.sh                 # brings ntfy up and creates the accounts
./add-caddy-site.sh         # publishes it through the host's Caddy
```

Both halves are needed. `deploy.sh` alone leaves ntfy running and unreachable.

**The DNS record must exist and point at this server before you run it.**
`deploy.sh` checks and refuses to start otherwise — a wrong record means
Let's Encrypt failing in a loop, and enough failures rate-limits the domain for
a week.

Ports **80 and 443 must be reachable from the internet** — that is the host's
existing Caddy, already listening. 80 is not optional: it is how ACME issues
the certificate.

## Wiring it up

**On the server** — in `server/.env` (secrets) and `server/config/config.yml`:

```
# server/.env
GCLPM_NTFY_TOPIC=<NTFY_TOPIC>
GCLPM_NTFY_TOKEN=<contents of ntfy-server/monitor.token>
```
```yaml
# server/config/config.yml
notify:
  ntfy:
    server: https://ntfy.yourdomain
```
```bash
cd ../server && docker compose up -d --force-recreate
```

`--force-recreate` is needed: Compose does not notice a changed `.env` on a
plain `up -d`, and the container keeps the old environment.

**On the Windows tool** (if it is still sending) — Settings → Notifications… →
Phone (ntfy): the same Server, Topic and Token.

**On the phone** — install ntfy, then:

1. Settings → **Manage users** → add `https://ntfy.yourdomain`, user `phone`.
2. Subscribe to the topic, with **Use another server** ticked.
3. Set the alarm sound — **in Android, not in the ntfy app**:
   Settings → Apps → ntfy → Notifications → the **Max priority** channel →
   Sound.
4. Battery → **Unrestricted**, or the phone will sleep the app and the alert
   arrives late.

Step 3 is the one people skip, and it is the one that turns a notification into
an alarm. It is set per **priority channel**, not per topic — a DOWN alert is
sent at priority 5, so it is the Max channel that has to make the noise. There
is no per-topic sound setting to find, and looking for one is how an afternoon
disappears.

Leave **"Keep alerting" / insistent** switched **off**. ntfy has no way to
cancel a notification it has already delivered, so an insistent alarm cannot be
stopped by the host coming back. Repeating while something is still down is the
server's job instead (`notify.repeat_min`), because the server is the only thing
that knows when it recovers.

## Checking it

```bash
docker compose ps
docker compose logs -f ntfy
docker exec gcl-ntfy ntfy access          # who can do what
curl -s https://ntfy.yourdomain/v1/health # {"healthy":true}
```

## Notes worth keeping

- **`flush_interval -1` and `read_timeout 0` in the site block are not
  decoration.** ntfy's app holds a long streaming connection for instant
  delivery; a proxy that buffers or times it out silently downgrades the whole
  thing to polling, and the alarm arrives minutes late. That failure looks like
  "ntfy is unreliable", not like a proxy setting.
- **`NTFY_BEHIND_PROXY=true` matters for more than logging.** Without it every
  request appears to come from Caddy's container IP, so ntfy's rate limiter sees
  one client hammering it and starts refusing messages.
- The token is written to `monitor.token`, mode 600. It is gitignored. Back it up
  with your other secrets — losing it means creating a new one and re-entering
  it on the PC.
- ntfy is pinned to `v2.28.0`. Change the tag deliberately, not by switching to
  `latest`.
