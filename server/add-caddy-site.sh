#!/usr/bin/env bash
#
# Publish the ping monitor at ping.monitor.grameencybernet.net through the
# monitoring stack's existing Caddy.
#
#   ./add-caddy-site.sh
#
# This is the one script here that edits a file belonging to another stack, so
# it is deliberately careful about it:
#
#   * it refuses to run twice - the block is added only if it is not there
#   * it timestamps a backup of the Caddyfile first
#   * it APPENDS with >> rather than rewriting the file. That matters: the
#     Caddyfile is bind-mounted into the container as a single file, so a tool
#     that writes a new file and renames it over the old one (sed -i, git pull,
#     an editor with atomic save) leaves the container reading the old inode for
#     ever. Appending keeps the inode, so the container really does see it.
#   * it asks Caddy to VALIDATE the result before restarting anything, and puts
#     the backup back if the config is bad. A broken Caddyfile here would take
#     Cacti, Nagios, Smokeping, Uptime Kuma and the VPN portal down with it.
#
# Recreating Caddy - rather than reloading it - is deliberate for the same
# single-file-mount reason: a reload is the step that silently does nothing.

set -euo pipefail

STACK=/root/data/monitoring-stack
CADDYFILE="$STACK/Caddyfile"
SITE=ping.monitor.grameencybernet.net
UPSTREAM=gcl-pingmon:8080

say()  { printf '\n\033[1;36m==\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$CADDYFILE" ] || die "no Caddyfile at $CADDYFILE"
docker ps --format '{{.Names}}' | grep -qx caddy || die "the caddy container is not running"
docker ps --format '{{.Names}}' | grep -qx gcl-pingmon || die "gcl-pingmon is not running - run ./deploy.sh first"

# A whole-line match, not a substring: "ping.monitor.grameencybernet.net" is
# also the tail of "smokeping.monitor.grameencybernet.net", which is already in
# this file - a plain grep reports the site as present and the script does
# nothing at all.
if grep -qxF "${SITE} {" "$CADDYFILE"; then
  say "$SITE is already in the Caddyfile - nothing to do"
  exit 0
fi

BACKUP="$CADDYFILE.bak-$(date +%Y%m%d-%H%M%S)"
say "Backing up to $BACKUP"
cp -a "$CADDYFILE" "$BACKUP"

say "Adding the site block"
cat >> "$CADDYFILE" <<EOF

${SITE} {
    # The ping monitor's engine - see /root/data/gcl-ping-monitor.
    # A separate compose project that joins monitor_net from the outside, so it
    # can be rebuilt or removed without touching this stack.
    #
    # The only lock on this is the access token in the URL (GCLPM_WEB_TOKEN in
    # that project's .env). There is no login page behind it.
    reverse_proxy ${UPSTREAM}
    encode gzip
    log {
        output file /data/caddy-pingmon.log
    }
}
EOF

say "Validating before restarting anything"
if ! docker exec caddy caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile; then
  cp -a "$BACKUP" "$CADDYFILE"
  die "the Caddyfile did not validate - it has been put back exactly as it was"
fi

say "Recreating caddy (a reload would silently do nothing on a single-file mount)"
cd "$STACK"
docker compose up -d --force-recreate caddy

say "Checking it answers"
sleep 5
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "https://${SITE}/" || echo 000)"
echo "  https://${SITE}/  ->  $code   (401 is correct: no token in that URL)"
[ "$code" = "401" ] || [ "$code" = "200" ] || die "unexpected response - check: docker compose logs caddy"

say "Done. The dashboard is at https://${SITE}/?t=<the token in gcl-ping-monitor/server/.env>"
