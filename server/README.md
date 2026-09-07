# GCL Ping Monitor - Linux server

The same monitor as the Windows tool, with the engine on a server instead of a
PC. It pings, it decides what is down, it sends the alerts, and it serves the
**same dashboard page** over the **same JSON contract** - so a phone that has the
dashboard on its home screen cannot tell which engine is answering.

The reason it exists is the obvious one: a monitor that only runs while someone's
desktop is switched on is not a monitor.

```
config.yml ──► pinger ──► state ──► notifier ──► email / telegram / ntfy
                            │
                            └────► web  ──► dashboard  +  /hosts editor
```

## What runs where

| | |
|---|---|
| Host | `monitor.grameencybernet.net` (203.191.33.29) |
| Path | `/root/data/gcl-ping-monitor/server` |
| Network | joins the existing `monitoring-stack` network from the outside |
| Port | none published - Caddy reaches it by container name |
| User | uid 10001, no root, no `CAP_NET_RAW` |

It is a **separate compose project** on purpose. Nothing here is added to the
monitoring-stack's own `docker-compose.yml`, so `docker compose down` in this
directory cannot take Cacti, Pritunl, Uptime Kuma or Nagios with it.

> **Not on `netauto`.** A docker bridge there occupies `172.18.0.0/16`, which is
> the OLT range. Every OLT would show as permanently down and the cause would be
> invisible from inside the container.

## Deploy

```bash
git clone https://github.com/badshashorif/gcl-ping-monitor.git /root/data/gcl-ping-monitor
cd /root/data/gcl-ping-monitor/server
./deploy.sh
```

`deploy.sh` finds the monitoring-stack network, writes a starter `config/config.yml`
and a `.env` with a freshly generated dashboard token, builds, starts, and then
proves the container can actually send an ICMP packet as a non-root user. Running
it again never overwrites an existing config or `.env` - a second run is just
"rebuild and restart".

Then put your notification secrets in `.env` and enable the channels you want in
`config/config.yml`.

## Adding hosts

Open the dashboard, click **Edit hosts** at the bottom, or go straight to `/hosts`.

Add, rename, remove, and toggle two switches per host:

- **Watching** off - not pinged at all. Greyed out, can never raise an alarm.
- **Alarm** off - no *noise*. The host still goes red, still needs an
  acknowledgement, and still sends its notifications.

Save writes the list straight into `config.yml`. The running monitor picks it up
within a few seconds without restarting, and hosts that stay in the list keep
their ping history and their acknowledgements.

Editing by hand over SSH still works and is still the fallback. Saving from the
browser **keeps every comment in the file** - it round-trips the YAML rather than
re-writing it - and keeps the version it replaced as `config.yml.bak`.

Set `web.allow_edit: false` to turn the editor off entirely, for a box whose
dashboard link has been handed to people who should only be looking at it.

### Why the whole directory is mounted, not just the file

Saving writes `config.yml.tmp` and renames it over `config.yml`, so a crash
mid-write can never leave a half-written config behind. A rename replaces the
inode - and a single-file bind mount follows the *original* inode. Mount the file
and the container would carry on reading the old, deleted one for ever: every
save would appear to work and nothing would ever change. This is the same trap
the Caddyfile mount on this box already has.

## Secrets

Only in `.env`, never in `config.yml`:

| | |
|---|---|
| `GCLPM_WEB_TOKEN` | dashboard access token - `openssl rand -hex 16` |
| `GCLPM_NTFY_TOPIC` | on public ntfy.sh the topic name **is** the password |
| `GCLPM_NTFY_TOKEN` | only for a self-hosted ntfy with auth |
| `GCLPM_TELEGRAM_TOKEN` | bot token from @BotFather |
| `GCLPM_EMAIL_PASSWORD` | SMTP password |

`config.yml` is therefore safe to read over someone's shoulder, which matters
because it is the file people actually open.

## Behaviour worth knowing

- **`fail_threshold`** consecutive misses before a host is called DOWN. One
  missed ping is a WARN, not an outage.
- **`batch_seconds`** - a link failure that takes five hosts down is *one*
  message, not five.
- **`max_per_hour`** - a hard cap, so a flapping circuit cannot spam a phone.
- **`repeat_min`** - re-send while a host is still down *and* un-acknowledged.
  0 sends once and stops. This is where repetition belongs: ntfy has no way to
  cancel a notification it has already delivered, so an insistent alert set on
  the phone can never be stopped by the host coming back.
- A recovery clears a stale acknowledgement, so the *next* outage alarms
  properly instead of starting pre-silenced.
- A broken `config.yml` does not take the monitor down. It logs the error and
  keeps running on the last good configuration.
- One dead notification channel does not swallow the others.

## Development

```bash
pip install -r requirements-dev.txt
python -m pytest -q
python -m gclpm -c config.example.yml        # needs GCLPM_WEB_TOKEN set
```

CI is the real gate - it runs the tests, starts the app and exercises the HTTP
contract and the host editor against a real file, builds the image, and proves
unprivileged ICMP works inside it.
