#!/usr/bin/env bash
#
# Deploy the ping monitor onto the monitoring-stack box.
#
# Safe to run again: it never overwrites a config.yml or a .env that already
# exists, so a second run is just "rebuild and restart".
#
#   cd /root/data/gcl-ping-monitor/server
#   ./deploy.sh
#
# It deliberately does NOT touch the monitoring-stack compose project or the
# Caddyfile. This is a separate compose project that joins the existing network
# from the outside; `docker compose down` in this directory cannot take Cacti,
# Pritunl, Uptime Kuma or Nagios with it. The Caddy site block is printed at the
# end for you to add by hand, because editing that file needs care on this box.

set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\n\033[1;36m==\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

UID_IN_IMAGE=10001

# ---- prerequisites --------------------------------------------------------
command -v docker >/dev/null || die "docker is not installed"
docker compose version >/dev/null 2>&1 || die "this needs Docker Compose v2 (docker compose, not docker-compose)"

# ---- which network is the stack actually on? ------------------------------
# Compose prefixes network names with the project directory name, so this is
# usually monitoring-stack_monitor_net - but guessing wrong means the container
# starts, Caddy cannot see it, and nothing says why.
say "Looking for the monitoring-stack network"
mapfile -t NETS < <(docker network ls --format '{{.Name}}' | grep -i 'monitor' || true)
if [ "${#NETS[@]}" -eq 0 ]; then
  die "no docker network with 'monitor' in the name. Is the monitoring stack up? (docker network ls)"
elif [ "${#NETS[@]}" -eq 1 ]; then
  NET="${NETS[0]}"
else
  printf '  more than one candidate:\n'
  printf '    %s\n' "${NETS[@]}"
  read -rp "  which one? " NET
fi
docker network inspect "$NET" >/dev/null || die "network '$NET' does not exist"
echo "  using $NET"

# ---- config.yml -----------------------------------------------------------
mkdir -p config
if [ -f config/config.yml ]; then
  say "config/config.yml already exists - leaving it alone"
else
  say "Creating config/config.yml from the example"
  cp config.example.yml config/config.yml
  sed -i "s|^monitor_name: .*|monitor_name: $(hostname)|" config/config.yml
  # The example ships with example hosts. Drop them and start empty, so nobody
  # ends up monitoring 192.0.2.1 and wondering why it is down - the real list
  # gets added in the browser, which is the point of the /hosts editor.
  sed -i '/^hosts:/,$d' config/config.yml       # the comments above it survive
  echo 'hosts: []' >> config/config.yml
  echo "  starter config written - add your hosts from the browser afterwards"
fi

# The container runs as an unprivileged user and has to be able to replace this
# file when you save from the browser.
chown -R "$UID_IN_IMAGE:$UID_IN_IMAGE" config
chmod 755 config

# ---- .env -----------------------------------------------------------------
if [ -f .env ]; then
  say ".env already exists - leaving your secrets alone"
else
  say "Creating .env"
  cp .env.example .env
  TOKEN="$(openssl rand -hex 16)"
  sed -i "s|^GCLPM_WEB_TOKEN=.*|GCLPM_WEB_TOKEN=${TOKEN}|" .env
  chmod 600 .env
  warn "Now put your notification secrets in .env before anything can alert you:"
  echo "     GCLPM_NTFY_TOPIC      your ntfy topic"
  echo "     GCLPM_TELEGRAM_TOKEN  the bot token"
  echo "     GCLPM_EMAIL_PASSWORD  the SMTP password"
  echo "   then enable the channels you want in config/config.yml"
fi

grep -q '^MONITOR_NET_NAME=' .env \
  && sed -i "s|^MONITOR_NET_NAME=.*|MONITOR_NET_NAME=${NET}|" .env \
  || echo "MONITOR_NET_NAME=${NET}" >> .env

# ---- build and start ------------------------------------------------------
say "Building and starting"
docker compose up -d --build

say "Waiting for it to come up"
for i in $(seq 1 30); do
  state="$(docker inspect -f '{{.State.Health.Status}}' gcl-pingmon 2>/dev/null || echo starting)"
  [ "$state" = "healthy" ] && break
  sleep 2
done
[ "${state:-}" = "healthy" ] || {
  warn "not healthy after 60s. Logs:"
  docker compose logs --tail 40
  die "start it by hand once you have fixed it: docker compose up -d"
}

# The one thing worth proving out loud: this container can actually ping as a
# non-root user. If the sysctl did not take, every host goes red at once and it
# looks like a total outage rather than a permissions problem.
say "Checking that ICMP works inside the container"
docker compose exec -T pingmon python -c \
  "from icmplib import ping; r=ping('127.0.0.1',count=1,privileged=False); print('  ICMP ok, rtt', r.avg_rtt,'ms')" \
  || die "the container cannot ping. Check that net.ipv4.ping_group_range is allowed on this host."

TOKEN="$(grep '^GCLPM_WEB_TOKEN=' .env | cut -d= -f2-)"

say "Up - but not reachable yet."
cat <<EOF

  No port is published, on purpose: nothing here faces the world directly. Right
  now only other containers on ${NET} can reach it, so there is one more step
  before you can open it in a browser at all.

  Next        ./add-caddy-site.sh      publishes it through the stack's Caddy
              then                     https://ping.monitor.grameencybernet.net/?t=${TOKEN}

  Hosts       add them at  /hosts  - the link is at the bottom of the dashboard
  Token       ${TOKEN}
              This is the ONLY lock on the dashboard. Treat the link as the
              password it is, and do not paste it anywhere public.
  Logs        docker compose logs -f
  Restart     docker compose restart

EOF
