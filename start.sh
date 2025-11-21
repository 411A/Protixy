#!/usr/bin/env bash
set -e

# --- Configuration ---
: "${PROXY_PORT:?Need to set PROXY_PORT (e.g. 6101)}"
OVPN_DIR="/etc/openvpn"
CREDS_FILE="$OVPN_DIR/proton_openvpn_userpass.txt"
TINYPROXY_CONF_TEMPLATE="/etc/tinyproxy/tinyproxy.conf.template"
TINYPROXY_CONF="/etc/tinyproxy/tinyproxy.conf"
VPN_CONNECT_TIMEOUT=20
RETRY_DELAY=300

# Use HOST_COUNTRY from environment variable (set by docker-compose)
# If not set, try to detect it (fallback)
if [ -z "$HOST_COUNTRY" ]; then
    echo "[init] 🌍 Detecting host location..." >&2
    sleep 10
    
    # Try multiple IP detection services
    vpn_ip=""
    services=(
        "https://api.ipify.org"
        "https://checkip.amazonaws.com" 
        "https://icanhazip.com"
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
        HOST_COUNTRY=$(timeout 10 curl -s "http://ip-api.com/json/${vpn_ip}?fields=countryCode" 2>/dev/null | grep -o '"countryCode":"[A-Z]*"' | cut -d'"' -f4 || echo "UNKNOWN")
    fi
fi
echo "[init] 📍 Host country: $HOST_COUNTRY" >&2

# --- Cleanup ---
function cleanup {
    echo "[main] Received exit signal, cleaning up..." >&2
    killall openvpn 2>/dev/null || true
    killall tinyproxy 2>/dev/null || true
}
trap cleanup EXIT

# --- Find a working OpenVPN configuration ---
function find_working_vpn_config {
    # Shuffle the array of configs to try a different one each time
    mapfile -t configs < <(shuf -e "$OVPN_DIR"/*.ovpn)

    for cfg in "${configs[@]}"; do
        echo "[vpn] 🎯 Attempting to connect with $(basename "$cfg")..." >&2

        # Create a temporary config file with fixes for warnings
        local temp_cfg
        temp_cfg="/tmp/$(basename "$cfg")"
        
        # Remove problematic directives and add compatibility options
        sed '/^up /d;/^down /d' "$cfg" > "$temp_cfg"
        
        # Add options to fix warnings and improve stability
        cat >> "$temp_cfg" <<EOF

# Auto-generated stability improvements
ping 10
ping-restart 120
resolv-retry infinite
persist-key
persist-tun
mute-replay-warnings
verb 3
# Fix cipher warnings
data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
data-ciphers-fallback AES-256-CBC
EOF

        # Start OpenVPN in the background to test the connection
        openvpn --config "$temp_cfg" --auth-user-pass "$CREDS_FILE" \
                --auth-nocache --daemon 2>&1 | grep -v "is group or others accessible" >&2 || true

        # Wait for the tun0 interface to appear and get an IP
        for ((i=1; i<=VPN_CONNECT_TIMEOUT; i++)); do
            if ip link show tun0 &>/dev/null && ip addr show tun0 | grep -q "inet "; then
                echo "[vpn] ✅ Connection successful with $(basename "$cfg")." >&2
                killall openvpn # Stop the temporary daemon
                sleep 2 # Give it a moment to die
                echo "$cfg" # Return the ORIGINAL working config file path
                return 0
            fi
            sleep 1
        done

        echo "[vpn] ❌ Connection timed out for $(basename "$cfg"). Cleaning up and trying next." >&2
        killall openvpn 2>/dev/null || true
        sleep 2
    done

    echo "[vpn] 🚨 All OpenVPN configurations failed. Could not establish a connection." >&2
    return 1
}

# --- Main Execution ---
echo "[main] 🚀 Starting VPN-Proxy container..." >&2

# 1. Prepare directories for Tinyproxy
mkdir -p /var/log/tinyproxy /var/run/tinyproxy
chown nobody:nogroup /var/log/tinyproxy /var/run/tinyproxy
chmod 755 /var/log/tinyproxy /var/run/tinyproxy

# Configure and start Tinyproxy in the background
echo "[proxy] ✍️  Generating tinyproxy.conf for port $PROXY_PORT" >&2
envsubst < "$TINYPROXY_CONF_TEMPLATE" > "$TINYPROXY_CONF"
echo "[proxy] 🚀 Starting Tinyproxy in the background." >&2
tinyproxy -c "$TINYPROXY_CONF"

# Main loop with automatic retry
while true; do
    echo "[main] 🔍 Finding a working VPN configuration..." >&2
    
    # 2. Find a working config
    if ! WORKING_CONFIG_PATH=$(find_working_vpn_config); then
        echo "[main] ⏳ All configs failed. Waiting $RETRY_DELAY seconds before retry..." >&2
        sleep "$RETRY_DELAY"
        continue
    fi

    # 3. Start OpenVPN in the FOREGROUND with a cleaned-up config
    echo "[main] ✅ Starting OpenVPN with $(basename "$WORKING_CONFIG_PATH"). Container is now live on port $PROXY_PORT." >&2
    TEMP_CONFIG_FINAL="/tmp/$(basename "$WORKING_CONFIG_PATH")_final"
    
    # Prepare final config with all fixes
    sed '/^up /d;/^down /d' "$WORKING_CONFIG_PATH" > "$TEMP_CONFIG_FINAL"
    
    # Add stability options
    cat >> "$TEMP_CONFIG_FINAL" <<EOF

# Auto-generated stability improvements
ping 10
ping-restart 120
resolv-retry infinite
persist-key
persist-tun
mute-replay-warnings
verb 3
# Fix cipher warnings
data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
data-ciphers-fallback AES-256-CBC
EOF

    # Run OpenVPN in foreground. It will be supervised by the main loop.
    openvpn --config "$TEMP_CONFIG_FINAL" --auth-user-pass "$CREDS_FILE" \
            --auth-nocache 2>&1 | grep -v "is group or others accessible" || true
    
    # If we reach here, OpenVPN exited
    echo "[main] ⚠️  OpenVPN exited unexpectedly. Cleaning up..." >&2
    killall openvpn 2>/dev/null || true
    
    # Wait a bit before restarting
    echo "[main] ⏳ Waiting 30 seconds before attempting reconnection..." >&2
    sleep 30
done
