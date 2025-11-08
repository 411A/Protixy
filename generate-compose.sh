#!/usr/bin/env bash
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <number_of_proxies>"
  exit 1
fi

COUNT=$1
BASE_PORT=6100

# Detect host country to pass to containers
echo "🌍 Detecting host location..."
HOST_COUNTRY=$(timeout 10 curl -s https://ipinfo.io/country 2>/dev/null || echo "UNKNOWN")
if [ "$HOST_COUNTRY" = "UNKNOWN" ]; then
  echo "⚠️  Warning: Could not detect host country. VPN leak detection will be disabled."
else
  echo "📍 Host country detected: $HOST_COUNTRY"
fi

cat > docker-compose.yml <<EOF
services:
  monitor:
    image: docker:cli
    container_name: vpn_proxy_leak_monitor
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./monitor.sh:/monitor.sh
    environment:
      - HOST_COUNTRY=${HOST_COUNTRY}
      - CHECK_INTERVAL=300
      - CONTAINER_PREFIX=vpn_proxy_
    entrypoint: /bin/sh
    command: -c "apk add --no-cache bash curl jq && bash /monitor.sh"
    networks:
      - vpn_proxy_network
    restart: unless-stopped
    depends_on:
      - vpn_proxy_1

EOF

for i in $(seq 1 "$COUNT"); do
  port=$((BASE_PORT + i))
  cat >> docker-compose.yml <<EOF
  vpn_proxy_${i}:
    container_name: vpn_proxy_${i}
    build: .
    cap_add:
      - NET_ADMIN
    devices:
      - "/dev/net/tun"
    volumes:
      - ./ovpn_configs:/etc/openvpn:ro
    environment:
      - PROXY_PORT=${port}
      - HOST_COUNTRY=${HOST_COUNTRY}
    ports:
      - "${port}:${port}"
    networks:
      - vpn_proxy_network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "/bin/bash", "/usr/local/bin/healthcheck.sh"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 60s

EOF
done

cat >> docker-compose.yml <<EOF
networks:
  vpn_proxy_network:
    name: vpn_proxy_network
    driver: bridge
EOF

echo "✅ Generated docker-compose.yml for ${COUNT} proxies on ports $((BASE_PORT+1))–$((BASE_PORT+COUNT))."
echo "📡 Network: vpn_proxy_network - Other containers can connect to this network to use the proxies."
