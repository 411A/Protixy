#!/usr/bin/env bash
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <number_of_proxies>"
  exit 1
fi

COUNT=$1
BASE_PORT=6100

cat > docker-compose.yml <<EOF
services:
EOF

for i in $(seq 1 "$COUNT"); do
  port=$((BASE_PORT + i))
  cat >> docker-compose.yml <<EOF
  vpn_proxy_${i}:
    build: .
    cap_add:
      - NET_ADMIN
    devices:
      - "/dev/net/tun"
    volumes:
      - ./ovpn_configs:/etc/openvpn:ro
    environment:
      - PROXY_PORT=${port}
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
