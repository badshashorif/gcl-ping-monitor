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

## Layers

`groups:` in `config.yml` is the network's hierarchy - upstream first, edge
last - and the dashboard draws the groups in exactly that order:

```yaml
groups: [UPSTREAM_PEER, CORE_RTR, CORE_SWITCH, NAT_RTR, ACCESS_RTR, POP_RTR]
hosts:
  - { label: NCS540, target: 172.30.100.1, group: CORE_RTR }
```

A group is **presentation only**. It never changes what is pinged, when a host
alarms, or who is told, and moving a device between layers costs it neither its
ping history nor its acknowledgement.

Three rules keep it from ever hiding anything:

- **Trouble rises.** A layer with a DOWN or WARN host is lifted above the
  healthy ones, and inside every layer the worst host is at the top -
  unacknowledged before acknowledged.
- **Headings count the whole layer**, never the filtered subset, and they add
  up to the banner. A heading that quietly recounted itself to match a search
  would be the page lying in a smaller font.
- **Folds do not persist.** *Focus* collapses the healthy layers, but only
  while something is actually wrong somewhere - on a quiet day the whole estate
  stays open. A hand-folded layer reopens on reload rather than surviving to
  hide a device from the next person.

A group a host names but `groups:` omits still gets a heading, at the bottom:
a typo must be visible, not swallow the device. Hosts with no group land under
`Ungrouped`, a reserved name no host can join.

The `/hosts` editor sets a host's layer and can add a new one. Re-ordering the
layers is an edit to `groups:`, because the order is the hierarchy.

## Behaviour worth knowing

- **`web.public_url`** - set it, and tapping a phone alert opens the dashboard
  already authorised. The token is appended at send time rather than written
  into `config.yml`. Note what that means: the link, token and all, travels
  through whichever ntfy server you use. On the public ntfy.sh that is a third
  party, which is one more reason to self-host (see `ntfy-server/`).
- **`fail_threshold`** consecutive misses before a host is called DOWN. One
  missed ping is a WARN, not an outage.
- **`batch_seconds`** - a link failure that takes five hosts down is *one*
  message, not five.
- **`max_per_hour`** - a hard cap, so a flapping circuit cannot spam a phone.
- **`repeat_min`** - re-send while a host is still down *and* un-acknowledged.
  0 sends once and stops. This is where repetition belongs: ntfy has no way to
  cancel a notification it has already delivered, so an insistent alert set on
  the phone can never be stopped by the host coming back.
- **`<channel>.delay_seconds` and `alarm.delay_seconds`** - how long a host
  must *stay* down before that channel, or the alarm, is triggered. Detection
  never waits: the host goes DOWN in the table immediately either way. What
  these tune is the **interruption**.

  The shipped default assumes somebody is at the desk and the rest of the
  estate is asleep:

  ```yaml
  alarm:
    delay_seconds: 0       # desk: banner and noise, instantly
  notify:
    telegram: { delay_seconds: 0 }    # the running record - every blip
    ntfy:     { delay_seconds: 60 }   # only ring a pocket for a real outage
    email:    { delay_seconds: 60 }   # an inbox that holds only real outages
  ```

  A link that blips for twenty seconds then alarms the desk, appears in
  Telegram, and reaches nobody's phone or inbox.

  **The one people get wrong:** `alarm.delay_seconds` is the noise at the
  *desk*. The sound coming out of a **phone** is ntfy arriving at priority 5.
  Delaying the alarm does nothing to the phone - delay `ntfy` instead.

  A host that recovers inside its window is never mailed about at all, and
  neither is its recovery: no "RECOVERED" for a "DOWN" nobody received. A
  channel is likewise only reminded (`repeat_min`) about outages it was
  actually told about. A host **deleted** from the config mid-window is
  dropped too, rather than mailed about a minute after it stopped being
  monitored.

  One flush still costs one slot of `max_per_hour` even when the channels are
  carrying different sets of events, so splitting the fan-out does not
  quietly multiply the send rate.
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
