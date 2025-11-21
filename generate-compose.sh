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

# Try multiple IP detection services
vpn_ip=""
services=(
    "https://api.ipify.org"
    "https://checkip.amazonaws.com" 
    "https://icanhazip.com"
    "https://ident.me"
)

for service in "${services[@]}"; do
    vpn_ip=$(timeout 10 curl -s "$service" 2>/dev/null | tr -d '\n\r' | head -c15)
    if [[ -n "$vpn_ip" && "$vpn_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        break
    fi
    vpn_ip=""
done

# Get country from IP using free geolocation services
HOST_COUNTRY="UNKNOWN"
if [[ -n "$vpn_ip" ]]; then
    # Try multiple geolocation services
    geo_services=(
        "http://ip-api.com/json/${vpn_ip}?fields=countryCode|jq -r '.countryCode'"
        "https://freeipapi.com/api/json/${vpn_ip}|jq -r '.countryCode'"
    )
    
    for geo_service in "${geo_services[@]}"; do
        service_url=$(echo "$geo_service" | cut -d'|' -f1)
        parse_cmd=$(echo "$geo_service" | cut -d'|' -f2-)
        HOST_COUNTRY=$(timeout 10 bash -c "curl -s '$service_url' | $parse_cmd" 2>/dev/null | tr -d '\n\r')
        
        if [[ -n "$HOST_COUNTRY" && "$HOST_COUNTRY" != "null" && "$HOST_COUNTRY" != "UNKNOWN" ]]; then
            break
        fi
        HOST_COUNTRY="UNKNOWN"
    done
fi

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
      - CHECK_INTERVAL=900
      - CONTAINER_PREFIX=vpn_proxy_
      - IPINFO_TOKEN=${IPINFO_TOKEN:-}
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
