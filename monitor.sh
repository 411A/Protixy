#!/usr/bin/env bash
# monitor.sh - External VPN leak monitor
# This script runs in a separate container and monitors ALL proxy containers for IP leaks

set -e

: "${HOST_COUNTRY:?Need to set HOST_COUNTRY}"
: "${CHECK_INTERVAL:=900}"  # Default: check every 15 minutes
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
        
        # Get the country through this proxy - use multiple services for reliability
        vpn_country=""
        
        # Try multiple IP detection services in order
        services=(
            "https://httpbin.org/ip|jq -r '.origin' | head -c2"
            "https://api.ipify.org"
            "https://checkip.amazonaws.com"
            "https://icanhazip.com"
            "https://ident.me"
        )
        
        # First get IP address from any available service
        vpn_ip=""
        for service_cmd in "${services[@]}"; do
            if [[ "$service_cmd" == *"|"* ]]; then
                # Complex command with pipe
                service_url=$(echo "$service_cmd" | cut -d'|' -f1)
                pipe_cmd=$(echo "$service_cmd" | cut -d'|' -f2-)
                vpn_ip=$(timeout 15 bash -c "curl -s --proxy 'http://${container_name}:${proxy_port}' '$service_url' | $pipe_cmd" 2>/dev/null | tr -d '\n\r' | head -c15)
            else
                # Simple curl command
                vpn_ip=$(timeout 15 curl -s --proxy "http://${container_name}:${proxy_port}" "$service_cmd" 2>/dev/null | tr -d '\n\r' | head -c15)
            fi
            
            if [[ -n "$vpn_ip" && "$vpn_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                break
            fi
            vpn_ip=""
        done
        
        # If we got an IP, determine country using geolocation services
        if [[ -n "$vpn_ip" ]]; then
            # If IPinfo.io token is available, use it first (more reliable)
            if [[ -n "$IPINFO_TOKEN" ]]; then
                vpn_country=$(timeout 10 curl -s -H "Authorization: Bearer $IPINFO_TOKEN" "https://ipinfo.io/${vpn_ip}/country" 2>/dev/null | tr -d '\n\r')
            fi
            
            # If no token or token failed, use free services
            if [[ -z "$vpn_country" || "$vpn_country" == *"error"* ]]; then
                # Try multiple free geolocation services
                geo_services=(
                    "http://ip-api.com/json/${vpn_ip}?fields=countryCode|jq -r '.countryCode'"
                    "https://freeipapi.com/api/json/${vpn_ip}|jq -r '.countryCode'"
                )
                
                for geo_service in "${geo_services[@]}"; do
                    service_url=$(echo "$geo_service" | cut -d'|' -f1)
                    parse_cmd=$(echo "$geo_service" | cut -d'|' -f2-)
                    vpn_country=$(timeout 10 bash -c "curl -s '$service_url' | $parse_cmd" 2>/dev/null | tr -d '\n\r')
                    
                    if [[ -n "$vpn_country" && "$vpn_country" != "null" ]]; then
                        break
                    fi
                    vpn_country=""
                done
            fi
        fi
        
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
