#!/usr/bin/env bash
#
# Publish ntfy through the Caddy that is already running on this host.
#
#   ./add-caddy-site.sh
#
# Same care as the ping monitor's version, because this edits a file belonging
# to another stack: whole-line idempotency check, timestamped backup, APPEND
# rather than rewrite (the Caddyfile is bind-mounted as a single file, so a
# rename would strand the container on the old inode), validate before
# restarting, and put the backup back if the config is bad.
#
# The proxy settings in the block below are not decoration. The ntfy app holds
# one long-lived streaming connection for instant delivery; a proxy that
# buffers it or times it out turns "instant" into "whenever the phone next
# polls" - which is the single thing this server exists to avoid, and it fails
# in a way that looks like ntfy being flaky rather than a proxy setting.

set -euo pipefail
cd "$(dirname "$0")"

STACK=${STACK:-/root/data/monitoring-stack}
CADDYFILE="$STACK/Caddyfile"
CADDY_CONTAINER=${CADDY_CONTAINER:-caddy}

say() { printf '\n\033[1;36m==\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[ -f .env ] || die "no .env - copy .env.example to .env and fill it in"
set -a; . ./.env; set +a
: "${NTFY_DOMAIN:?NTFY_DOMAIN is not set in .env}"

[ -f "$CADDYFILE" ] || die "no Caddyfile at $CADDYFILE (set STACK= if it lives elsewhere)"
docker ps --format '{{.Names}}' | grep -qx "$CADDY_CONTAINER" || die "the $CADDY_CONTAINER container is not running"
docker ps --format '{{.Names}}' | grep -qx gcl-ntfy || die "gcl-ntfy is not running - run ./deploy.sh first"

# Whole line, not a substring: site names are routinely suffixes of each other
# (ping.example.net is the tail of smokeping.example.net), and a substring
# match reports the block as present so this script silently does nothing.
if grep -qxF "${NTFY_DOMAIN} {" "$CADDYFILE"; then
  say "${NTFY_DOMAIN} is already in the Caddyfile - nothing to do"
  exit 0
fi

BACKUP="$CADDYFILE.bak-$(date +%Y%m%d-%H%M%S)"
say "Backing up to $BACKUP"
cp -a "$CADDYFILE" "$BACKUP"

say "Adding the site block"
cat >> "$CADDYFILE" <<EOF

${NTFY_DOMAIN} {
    encode gzip

    # The phone app holds a long-lived stream for instant delivery.
    # flush_interval -1 stops Caddy buffering it, and read_timeout 0 stops it
    # being cut off. Without both, delivery quietly degrades to polling.
    reverse_proxy gcl-ntfy:80 {
        flush_interval -1
        header_up X-Forwarded-For {remote_host}
        transport http {
            read_timeout 0
        }
    }

    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        -Server
    }

    log {
        output file /data/caddy-ntfy.log
    }
}
EOF

say "Validating before restarting anything"
if ! docker exec "$CADDY_CONTAINER" caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile; then
  cp -a "$BACKUP" "$CADDYFILE"
  die "the Caddyfile did not validate - it has been put back exactly as it was"
fi

say "Recreating caddy (a reload would silently do nothing on a single-file mount)"
cd "$STACK"
docker compose up -d --force-recreate "$CADDY_CONTAINER"

say "Checking it answers"
sleep 5
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 "https://${NTFY_DOMAIN}/v1/health" || echo 000)"
echo "  https://${NTFY_DOMAIN}/v1/health  ->  $code"
[ "$code" = "200" ] || die "not answering yet - a first certificate can take a few seconds; check: docker logs $CADDY_CONTAINER"

say "Done. Server URL for the phones: https://${NTFY_DOMAIN}"
