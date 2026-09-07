#!/usr/bin/env bash
#
# Point the ping monitor at this ntfy instead of the public ntfy.sh.
#
#   ./link-to-monitor.sh
#
# Run it on the box, after ./deploy.sh and ./add-caddy-site.sh. It does the
# wiring itself so the token never has to be copied out of the file, pasted
# through a terminal, or read aloud - it goes straight from monitor.token into
# the monitor's .env, which is the only other place it belongs.

set -euo pipefail
cd "$(dirname "$0")"

MON=${MON:-../server}

say() { printf '\n\033[1;36m==\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[ -f .env ]            || die "no .env here - run ./deploy.sh first"
[ -s ./monitor.token ] || die "no monitor.token - run ./deploy.sh first"
[ -f "$MON/.env" ]     || die "no $MON/.env - deploy the ping monitor first"
[ -f "$MON/config/config.yml" ] || die "no $MON/config/config.yml"

set -a; . ./.env; set +a
: "${NTFY_DOMAIN:?}" "${NTFY_TOPIC:?}"

TOKEN="$(cat ./monitor.token)"
case "$TOKEN" in tk_*) ;; *) die "monitor.token does not look like a token" ;; esac

say "Backing up what we are about to change"
cp -a "$MON/.env"             "$MON/.env.bak-$(date +%Y%m%d-%H%M%S)"
cp -a "$MON/config/config.yml" "$MON/config/config.yml.bak-$(date +%Y%m%d-%H%M%S)"

setvar() {   # key value file
  if grep -q "^$1=" "$3"; then
    # the value can contain / and +, so use a delimiter that a base64 token and
    # a URL cannot both contain
    sed -i "s|^$1=.*|$1=$2|" "$3"
  else
    printf '%s=%s\n' "$1" "$2" >> "$3"
  fi
}

say "Pointing $MON/.env at this server"
setvar GCLPM_NTFY_TOPIC "$NTFY_TOPIC" "$MON/.env"
setvar GCLPM_NTFY_TOKEN "$TOKEN"      "$MON/.env"

say "Setting the ntfy server in config.yml"
# Anchored to the indented key inside notify.ntfy - a bare "server:" would also
# match smtp_server and anything else that ends in it.
sed -i "s|^\( *\)server: https\?://ntfy\..*|\1server: https://${NTFY_DOMAIN}|" "$MON/config/config.yml"
grep -n "server: https://${NTFY_DOMAIN}" "$MON/config/config.yml" >/dev/null \
  || die "could not find the ntfy server line in config.yml - set notify.ntfy.server by hand"

say "Restarting the monitor"
# --force-recreate: Compose does not notice a changed .env on a plain up -d,
# and the container would keep the old topic and no token at all.
docker compose -f "$MON/docker-compose.yml" up -d --force-recreate

say "Done. The next alert goes to https://${NTFY_DOMAIN}/${NTFY_TOPIC}"
echo "  Every phone must re-subscribe: the old ntfy.sh topic is now dead."
