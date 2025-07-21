#!/usr/bin/env bash
set -e

# --- Configuration ---
: "${PROXY_PORT:?Need to set PROXY_PORT (e.g. 6101)}"
OVPN_DIR="/etc/openvpn"
CREDS_FILE="$OVPN_DIR/proton_openvpn_userpass.txt"
TINYPROXY_CONF_TEMPLATE="/etc/tinyproxy/tinyproxy.conf.template"
TINYPROXY_CONF="/etc/tinyproxy/tinyproxy.conf"
# Seconds to wait for tun0 interface
VPN_CONNECT_TIMEOUT=15

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
        # Redirect status messages to stderr (>&2) so they don't get captured by command substitution
        echo "[vpn] 🎯 Attempting to connect with $(basename "$cfg")..." >&2

        # Create a temporary config file, stripping problematic directives
        local temp_cfg
        temp_cfg="/tmp/$(basename "$cfg")"
        sed '/^up /d;/^down /d' "$cfg" > "$temp_cfg"

        # Start OpenVPN in the background to test the connection
        openvpn --config "$temp_cfg" --auth-user-pass "$CREDS_FILE" --daemon

        # Wait for the tun0 interface to appear
        for ((i=1; i<=VPN_CONNECT_TIMEOUT; i++)); do
            if ip link show tun0 &>/dev/null; then
                echo "[vpn] ✅ Connection successful with $(basename "$cfg")." >&2
                killall openvpn # Stop the temporary daemon
                sleep 1 # Give it a moment to die
                echo "$cfg" # Return the ORIGINAL working config file path
                return
            fi
            sleep 1
        done

        echo "[vpn] ❌ Connection timed out for $(basename "$cfg"). Cleaning up and trying next." >&2
        killall openvpn 2>/dev/null || true
        sleep 1
    done

    echo "[vpn] 🚨 All OpenVPN configurations failed. Could not establish a connection." >&2
    exit 1
}

# --- Main Execution ---
echo "[main] 🚀 Starting VPN-Proxy container..." >&2

# 1. Prepare directories for Tinyproxy
mkdir -p /var/log/tinyproxy /var/run/tinyproxy
chown nobody:nogroup /var/log/tinyproxy /var/run/tinyproxy
chmod 755 /var/log/tinyproxy /var/run/tinyproxy

# 2. Find a working config. It captures ONLY the filename.
WORKING_CONFIG_PATH=$(find_working_vpn_config)
if [ -z "$WORKING_CONFIG_PATH" ]; then
    exit 1
fi

# 3. Configure and start Tinyproxy in the background
echo "[proxy] ✍️  Generating tinyproxy.conf for port $PROXY_PORT" >&2
envsubst "$PROXY_PORT" < "$TINYPROXY_CONF_TEMPLATE" > "$TINYPROXY_CONF"
echo "[proxy] 🚀 Starting Tinyproxy in the background." >&2
tinyproxy -c "$TINYPROXY_CONF"

# 4. Start OpenVPN in the FOREGROUND with a cleaned-up config
#    This makes OpenVPN the main process of the container.
echo "[main] ✅ Handing over control to OpenVPN. Container is now live on port $PROXY_PORT." >&2
TEMP_CONFIG_FINAL="/tmp/$(basename "$WORKING_CONFIG_PATH")_final"
sed '/^up /d;/^down /d' "$WORKING_CONFIG_PATH" > "$TEMP_CONFIG_FINAL"
exec openvpn --config "$TEMP_CONFIG_FINAL" --auth-user-pass "$CREDS_FILE"
