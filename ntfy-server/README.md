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

`ntfy` behind `caddy` (automatic Let's Encrypt). ntfy is **not** published on the
host — only Caddy is — so there is no plaintext way in from outside.

Two accounts are created, least privilege:

| Account | Access | Used by |
|---|---|---|
| `monitor` | **write-only** on the topic | the Windows tool, via a token |
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
vi .env                     # domain, email, topic, the two passwords
./deploy.sh
```

**The DNS A record must exist and point at this server before you run it.**
`deploy.sh` checks and refuses to start otherwise — a wrong record means
Let's Encrypt failing in a loop, and enough failures rate-limits the domain for
a week.

Ports **80 and 443 must be reachable from the internet**. 80 is not optional:
that is how ACME issues the certificate.

## Wiring it up

**On the PC** — Settings → Notifications... → Phone (ntfy):

| Field | Value |
|---|---|
| Server | `https://ntfy.yourdomain` |
| Topic | whatever you put in `NTFY_TOPIC` |
| Token | the contents of `ntfy-server/monitor.token` |

Then **Send a test to my phone**.

**On the phone** — install ntfy, then:

1. Settings → **Manage users** → add `https://ntfy.yourdomain`, user `phone`.
2. Subscribe to the topic.
3. Open the topic → its settings → set a **custom sound**.

Step 3 is the one people skip, and it is the one that turns a notification into
an alarm.

## Checking it

```bash
docker compose ps
docker compose logs -f ntfy
docker exec gcl-ntfy ntfy access          # who can do what
curl -s https://ntfy.yourdomain/v1/health # {"healthy":true}
```

## Notes worth keeping

- **`flush_interval -1` and `read_timeout 0` in the Caddyfile are not
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
