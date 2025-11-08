#!/usr/bin/env bash
# monitor.sh - External VPN leak monitor
# This script runs in a separate container and monitors ALL proxy containers for IP leaks

set -e

: "${HOST_COUNTRY:?Need to set HOST_COUNTRY}"
: "${CHECK_INTERVAL:=300}"  # Default: check every 5 minutes
: "${CONTAINER_PREFIX:=vpn_proxy_}"

echo "[monitor] 🔍 VPN Leak Monitor starting..."
echo "[monitor] 📍 Host country: $HOST_COUNTRY"
echo "[monitor] ⏱️ Check interval: ${CHECK_INTERVAL}s"
echo "[monitor] 👀 Will monitor all containers starting with: ${CONTAINER_PREFIX}"

# Wait a bit for VPN containers to start
sleep 60

while true; do
    # Get all running containers starting with the prefix (exclude the monitor itself)
    containers=$(docker ps --filter "name=${CONTAINER_PREFIX}" --format "{{.Names}}" | grep -v "leak_monitor" | sort)
    
    if [ -z "$containers" ]; then
        echo "[monitor] ⚠️  No VPN containers found with prefix '${CONTAINER_PREFIX}'"
        sleep "$CHECK_INTERVAL"
        continue
    fi
    
    echo "[monitor] 🔎 Checking $(echo "$containers" | wc -l) container(s)..."
    
    # Check each container individually
    while IFS= read -r container_name; do
        # Extract port number from container name (e.g., vpn_proxy_1 -> 6101)
        index=$(echo "$container_name" | grep -o '[0-9]*$')
        proxy_port=$((6100 + index))
        
        echo "[monitor] 📡 Checking $container_name (port $proxy_port)..."
        
        # Get the country through this proxy
        vpn_country=$(timeout 30 curl -s --proxy "http://${container_name}:${proxy_port}" https://ipinfo.io/country 2>/dev/null || echo "")
        
        if [ -z "$vpn_country" ]; then
            echo "[monitor]   ⚠️  Could not determine VPN country (proxy may be starting up)"
        elif [ "$vpn_country" = "$HOST_COUNTRY" ]; then
            echo "[monitor]   🚨 VPN LEAK DETECTED in $container_name! Country is $vpn_country (expected: NOT $HOST_COUNTRY)"
            echo "[monitor]   🔄 Restarting: $container_name"
            
            # Restart only this VPN container
            docker restart "$container_name"
            
            echo "[monitor]   ⏳ Waiting 60 seconds for $container_name to restart..."
            sleep 60
        else
            echo "[monitor]   ✅ $container_name is working correctly (Country: $vpn_country)"
        fi
    done <<< "$containers"
    
    # Wait before next check cycle
    echo "[monitor] ⏱️  Sleeping ${CHECK_INTERVAL}s until next check..."
    sleep "$CHECK_INTERVAL"
done
