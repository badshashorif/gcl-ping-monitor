#!/usr/bin/env bash
# Brings up ntfy and creates the two accounts the Ping Monitor needs.
#
#   ./deploy.sh            then     ./add-caddy-site.sh
#
# Idempotent: safe to run again after a change. It refuses to start rather than
# start something broken - DNS that does not point here would mean Let's
# Encrypt failing over and over and eventually rate-limiting the domain for a
# week.
#
# This deploys ntfy ALONE, behind a Caddy that already runs on the host.
# add-caddy-site.sh is the second half and carries the proxy settings ntfy
# needs; running this without it leaves ntfy unreachable from outside.
set -euo pipefail

cd "$(dirname "$0")"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

[ -f .env ] || die "no .env - copy .env.example to .env and fill it in"
# shellcheck disable=SC1091
set -a; . ./.env; set +a

: "${NTFY_DOMAIN:?NTFY_DOMAIN is not set in .env}"
: "${NTFY_TOPIC:?NTFY_TOPIC is not set in .env}"

case "$NTFY_DOMAIN" in
  *CHANGE_ME*|"") die "NTFY_DOMAIN still has the placeholder in it" ;;
esac

# ---- preflight -------------------------------------------------------------
say "preflight"

command -v docker >/dev/null || die "docker is not installed"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"

# Resolve with a public resolver, not the local one: Ubuntu's /etc/hosts often
# carries a "127.0.1.1 <fqdn>" line that shadows the real record and makes this
# check pass on a box where the outside world still cannot resolve the name.
resolved="$(getent hosts "$NTFY_DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)"
if command -v dig >/dev/null 2>&1; then
  resolved="$(dig +short @1.1.1.1 "$NTFY_DOMAIN" A | tail -1 || true)"
fi
if [ -z "$resolved" ]; then
  die "$NTFY_DOMAIN does not resolve. Create the DNS record first - Let's Encrypt will fail without it."
fi
say "  $NTFY_DOMAIN resolves to $resolved"

# Which network is the host's Caddy on? Guessing wrong means ntfy starts, Caddy
# cannot see it, and nothing anywhere says why.
if [ -z "${NTFY_NET_NAME:-}" ]; then
  mapfile -t NETS < <(docker network ls --format '{{.Name}}' | grep -i 'monitor' || true)
  case "${#NETS[@]}" in
    0) die "no docker network with 'monitor' in the name - set NTFY_NET_NAME in .env" ;;
    1) NTFY_NET_NAME="${NETS[0]}" ;;
    *) printf '  more than one candidate:\n'; printf '    %s\n' "${NETS[@]}"
       read -rp "  which one? " NTFY_NET_NAME ;;
  esac
  grep -q '^NTFY_NET_NAME=' .env \
    && sed -i "s|^NTFY_NET_NAME=.*|NTFY_NET_NAME=${NTFY_NET_NAME}|" .env \
    || echo "NTFY_NET_NAME=${NTFY_NET_NAME}" >> .env
fi
docker network inspect "$NTFY_NET_NAME" >/dev/null || die "network '$NTFY_NET_NAME' does not exist"
say "  using network $NTFY_NET_NAME"

# ---- up --------------------------------------------------------------------
say "pulling images"
docker compose pull -q

say "starting"
docker compose up -d

say "waiting for ntfy to report healthy"
for i in $(seq 1 30); do
  state="$(docker inspect -f '{{.State.Health.Status}}' gcl-ntfy 2>/dev/null || echo starting)"
  [ "$state" = "healthy" ] && break
  sleep 2
done
[ "${state:-}" = "healthy" ] || die "ntfy did not become healthy - check: docker compose logs ntfy"
say "  ntfy is healthy"

# ---- accounts --------------------------------------------------------------
# Two accounts on purpose, least privilege:
#   monitor - write only. This is the account whose token the ping monitor
#             holds. If that box is compromised the token can publish alarms
#             and can NOT read the outage history.
#   phone   - read only, for the handsets.
nt() { docker exec gcl-ntfy ntfy "$@"; }

ensure_user() {
  local user="$1" pass="$2"
  # -e, not a shell prefix: "NTFY_PASSWORD=x docker exec ..." sets the variable
  # on the docker CLIENT, which the container never sees, and ntfy then drops
  # into an interactive password prompt that has no terminal.
  # --ignore-exists makes re-running this a no-op instead of an error.
  say "  ensuring user $user"
  docker exec -e "NTFY_PASSWORD=$pass" gcl-ntfy ntfy user add --ignore-exists "$user" >/dev/null
}

[ -n "${NTFY_MONITOR_PASS:-}" ] || die "NTFY_MONITOR_PASS is not set in .env"
[ -n "${NTFY_PHONE_PASS:-}"   ] || die "NTFY_PHONE_PASS is not set in .env"

say "accounts"
ensure_user monitor "$NTFY_MONITOR_PASS"
ensure_user phone   "$NTFY_PHONE_PASS"

say "permissions on topic '$NTFY_TOPIC'"
nt access monitor "$NTFY_TOPIC" write-only >/dev/null
nt access phone   "$NTFY_TOPIC" read-only  >/dev/null
nt access | sed 's/^/    /'

# ---- token for the ping monitor -------------------------------------------
# A token, not the password: it can be revoked on its own without changing an
# account the phones may also be using.
if [ ! -s ./monitor.token ]; then
  say "creating an access token for the monitor account"
  # "ntfy token add <user>" with no --expires is the never-expiring form; there
  # is no --expires=never. A label makes it identifiable in "ntfy token list"
  # when there is more than one.
  nt token add --label="gcl-ping-monitor" monitor > ./monitor.token.raw
  umask 077
  grep -oE 'tk_[A-Za-z0-9]+' ./monitor.token.raw > ./monitor.token || {
    cat ./monitor.token.raw >&2
    rm -f ./monitor.token.raw ./monitor.token
    die "could not parse a token out of the output above"
  }
  rm -f ./monitor.token.raw
  chmod 600 ./monitor.token
fi
say "  token is in $(pwd)/monitor.token (mode 600)"

echo
say "ntfy is up, but NOT reachable from outside yet"
cat <<EOF

  Next        ./add-caddy-site.sh     publishes it through the host's Caddy

  Then point the ping monitor at it, in server/.env:
      GCLPM_NTFY_TOPIC=$NTFY_TOPIC
      GCLPM_NTFY_TOKEN=\$(cat $(pwd)/monitor.token)
  and in server/config/config.yml:
      notify.ntfy.server: https://$NTFY_DOMAIN
  then: docker compose up -d --force-recreate

  On each phone: install ntfy, Settings -> Manage users -> Add user
      https://$NTFY_DOMAIN   user 'phone'
  then subscribe to '$NTFY_TOPIC' with "Use another server" ticked.

EOF
