#!/usr/bin/env bash
# Quick diagnostic script for VPN Proxy containers

echo "🔍 VPN Proxy Diagnostic Report"
echo "=============================="
echo ""

# Check if docker-compose.yml exists
if [ ! -f "docker-compose.yml" ]; then
    echo "❌ No docker-compose.yml found. Run generate-compose.sh first."
    exit 1
fi

# Check network
echo "🌐 Docker Network Status:"
if docker network inspect vpn_proxy_network >/dev/null 2>&1; then
    echo "   ✅ vpn_proxy_network exists"
    connected_containers=$(docker network inspect vpn_proxy_network --format='{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)
    if [ -n "$connected_containers" ]; then
        echo "   📡 Connected containers: $connected_containers"
    fi
else
    echo "   ⚠️  vpn_proxy_network not found (will be created on first run)"
fi
echo ""

# Get list of proxy containers
containers=$(docker compose ps --services 2>/dev/null | grep vpn_proxy)

if [ -z "$containers" ]; then
    echo "❌ No proxy containers found. Start them with: docker compose up -d"
    exit 1
fi

echo "📦 Container Status:"
docker compose ps
echo ""

for container in $containers; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 Diagnostics for: $container"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Check if container is running
    container_status=$(docker compose ps --format json | grep "$container" | grep -o '"State":"[^"]*"' | cut -d'"' -f4)
    if [ "$container_status" != "running" ]; then
        echo "❌ Container is not running (status: $container_status)"
        echo ""
        continue
    fi
    
    # Health check status
    echo "🏥 Health Status:"
    health=$(docker inspect "$container" --format='{{.State.Health.Status}}' 2>/dev/null || echo "no healthcheck")
    if [ "$health" = "healthy" ]; then
        echo "   ✅ $health"
    elif [ "$health" = "unhealthy" ]; then
        echo "   ❌ $health"
    else
        echo "   ⚠️  $health"
    fi
    echo ""
    
    # Run internal health check
    echo "🔬 Internal Health Check:"
    docker compose exec -T "$container" /usr/local/bin/healthcheck.sh 2>&1 | sed 's/^/   /'
    echo ""
    
    # Check processes
    echo "⚙️  Running Processes:"
    docker compose exec -T "$container" bash -c "pgrep -a openvpn | head -1" 2>/dev/null | sed 's/^/   OpenVPN: /'
    docker compose exec -T "$container" bash -c "pgrep -a tinyproxy | head -1" 2>/dev/null | sed 's/^/   Tinyproxy: /'
    echo ""
    
    # Check tun0 interface
    echo "🌐 Network Interface (tun0):"
    docker compose exec -T "$container" bash -c "ip addr show tun0 2>/dev/null | grep 'inet '" 2>/dev/null | sed 's/^/   /' || echo "   ❌ tun0 not found or no IP"
    echo ""
    
    # Get current VPN server
    echo "🌍 Connected VPN Server:"
    server=$(docker compose logs "$container" 2>/dev/null | grep "Connection successful" | tail -1 | sed -n 's/.*with \(.*\)\.$/\1/p')
    if [ -n "$server" ]; then
        echo "   ✅ $server"
    else
        echo "   ⚠️  Not yet connected or log unavailable"
    fi
    echo ""
    
    # Get proxy port
    echo "🔌 Proxy Port:"
    port=$(docker compose exec -T "$container" bash -c 'echo $PROXY_PORT' 2>/dev/null | tr -d '\r')
    if [ -n "$port" ]; then
        echo "   Port: $port"
        
        # Test proxy using alternative services
        echo "   Testing proxy..."
        services=("https://api.ipify.org" "https://checkip.amazonaws.com" "https://icanhazip.com")
        external_ip=""
        
        for service in "${services[@]}"; do
            if timeout 5 curl -s --proxy "http://127.0.0.1:$port" "$service" >/dev/null 2>&1; then
                external_ip=$(timeout 5 curl -s --proxy "http://127.0.0.1:$port" "$service" 2>/dev/null | tr -d '\n\r')
                break
            fi
        done
        
        if [ -n "$external_ip" ]; then
            echo "   ✅ Proxy working - External IP: $external_ip"
        else
            echo "   ❌ Proxy not responding"
        fi
    fi
    echo ""
    
    # Recent log errors
    echo "📋 Recent Errors (last 5):"
    recent_errors=$(docker compose logs "$container" 2>/dev/null | grep -E "ERROR|FAIL|timeout|❌" | tail -5)
    if [ -n "$recent_errors" ]; then
        echo "$recent_errors" | sed 's/^/   /'
    else
        echo "   ✅ No recent errors"
    fi
    echo ""
    
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "💡 Quick Actions:"
echo "   Restart all:     docker compose restart"
echo "   View logs:       docker compose logs -f"
echo "   Rebuild:         docker compose up -d --build"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
