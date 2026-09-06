#!/usr/bin/env bash
# Brings up ntfy and creates the two accounts the Ping Monitor needs.
#
# Idempotent: safe to run again after a change. It refuses to start rather than
# start something broken - DNS that does not point here would mean Let's Encrypt
# failing over and over and eventually rate-limiting the domain for a week.
set -euo pipefail

cd "$(dirname "$0")"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

[ -f .env ] || die "no .env - copy .env.example to .env and fill it in"
# shellcheck disable=SC1091
set -a; . ./.env; set +a

: "${NTFY_DOMAIN:?NTFY_DOMAIN is not set in .env}"
: "${ACME_EMAIL:?ACME_EMAIL is not set in .env}"
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
  die "$NTFY_DOMAIN does not resolve. Create the DNS A record first - Let's Encrypt will fail without it."
fi
say "  $NTFY_DOMAIN resolves to $resolved"

for p in 80 443; do
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$"; then
    # our own Caddy re-running is fine, anything else is a conflict
    if ! docker ps --format '{{.Names}}' | grep -qx gcl-ntfy-caddy; then
      die "port $p is already in use by something else"
    fi
  fi
done
say "  ports 80 and 443 are free (or already ours)"

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
#   monitor - write only. This is the one whose token sits in config.json on the
#             desk PC. If that PC is lost, the token can publish alarms and can
#             NOT read the outage history.
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

# ---- token for the Windows tool -------------------------------------------
# A token, not the password: it can be revoked on its own without changing an
# account that the phones may also be using.
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
say "  token is in $(pwd)/monitor.token (mode 600) - paste it into the tool's Phone (ntfy) tab"

echo
say "done"
echo "    Server : https://$NTFY_DOMAIN"
echo "    Topic  : $NTFY_TOPIC"
echo "    Token  : $(pwd)/monitor.token"
echo
echo "  On the phone: install ntfy, Settings -> Manage users -> add"
echo "  https://$NTFY_DOMAIN as user 'phone', then subscribe to '$NTFY_TOPIC'."
