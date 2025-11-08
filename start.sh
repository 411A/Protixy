#!/usr/bin/env bash
set -e

# --- Configuration ---
: "${PROXY_PORT:?Need to set PROXY_PORT (e.g. 6101)}"
OVPN_DIR="/etc/openvpn"
CREDS_FILE="$OVPN_DIR/proton_openvpn_userpass.txt"
TINYPROXY_CONF_TEMPLATE="/etc/tinyproxy/tinyproxy.conf.template"
TINYPROXY_CONF="/etc/tinyproxy/tinyproxy.conf"
# Seconds to wait for tun0 interface
VPN_CONNECT_TIMEOUT=20
# Health check interval (seconds)
HEALTH_CHECK_INTERVAL=60
# Max consecutive failures before restart
MAX_FAILURES=3
# Retry delay on complete failure (seconds)
RETRY_DELAY=300

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

# --- Health monitoring function ---
function monitor_vpn_health {
    local consecutive_failures=0
    
    # Give VPN time to fully establish routing before first check
    echo "[monitor] ⏳ Waiting 30 seconds for VPN to fully stabilize..." >&2
    sleep 30
    
    while true; do
        # Check if tun0 exists and has an IP
        if ! ip link show tun0 &>/dev/null || ! ip addr show tun0 | grep -q "inet "; then
            consecutive_failures=$((consecutive_failures + 1))
            echo "[monitor] ⚠️  VPN interface issue detected (failure $consecutive_failures/$MAX_FAILURES)" >&2
            
            if [ "$consecutive_failures" -ge "$MAX_FAILURES" ]; then
                echo "[monitor] 🔄 Max failures reached. Triggering restart..." >&2
                killall openvpn 2>/dev/null || true
                return 1
            fi
        else
            # Check if OpenVPN process is still running
            if ! pgrep -x openvpn >/dev/null; then
                consecutive_failures=$((consecutive_failures + 1))
                echo "[monitor] ⚠️  OpenVPN process died (failure $consecutive_failures/$MAX_FAILURES)" >&2
                
                if [ "$consecutive_failures" -ge "$MAX_FAILURES" ]; then
                    echo "[monitor] 🔄 Max failures reached. Triggering restart..." >&2
                    return 1
                fi
            else
                # Check if Tinyproxy process is still running and listening
                if pgrep -x tinyproxy >/dev/null && nc -z 127.0.0.1 "$PROXY_PORT" 2>/dev/null; then
                    if [ "$consecutive_failures" -gt 0 ]; then
                        echo "[monitor] ✅ Connection recovered" >&2
                    fi
                    consecutive_failures=0
                else
                    consecutive_failures=$((consecutive_failures + 1))
                    echo "[monitor] ⚠️  Proxy not responding (failure $consecutive_failures/$MAX_FAILURES)" >&2
                    
                    if [ "$consecutive_failures" -ge "$MAX_FAILURES" ]; then
                        echo "[monitor] 🔄 Max failures reached. Triggering restart..." >&2
                        killall openvpn 2>/dev/null || true
                        return 1
                    fi
                fi
            fi
        fi
        
        # Wait before next check
        sleep "$HEALTH_CHECK_INTERVAL"
    done
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

    # Start health monitor in background
    monitor_vpn_health &
    MONITOR_PID=$!
    
    # Run OpenVPN in foreground (but allow it to be interrupted)
    openvpn --config "$TEMP_CONFIG_FINAL" --auth-user-pass "$CREDS_FILE" \
            --auth-nocache 2>&1 | grep -v "is group or others accessible" || true
    
    # If we reach here, OpenVPN exited
    echo "[main] ⚠️  OpenVPN exited unexpectedly. Cleaning up..." >&2
    kill "$MONITOR_PID" 2>/dev/null || true
    killall openvpn 2>/dev/null || true
    
    # Wait a bit before restarting
    echo "[main] ⏳ Waiting 30 seconds before attempting reconnection..." >&2
    sleep 30
done
