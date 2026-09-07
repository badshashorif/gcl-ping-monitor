# python:3.12 and not newer on purpose: icmplib 3.0.4 declares support up to
# 3.12, and this container's whole job is to ping reliably.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY gclpm/ ./gclpm/

# Runs as a normal user. ICMP still works because docker-compose.yml sets
# net.ipv4.ping_group_range, which lets any user open a SOCK_DGRAM ICMP socket -
# no root, no CAP_NET_RAW.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin gclpm
USER 10001

EXPOSE 8080
ENTRYPOINT ["python", "-m", "gclpm"]
