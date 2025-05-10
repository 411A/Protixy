#!/usr/bin/env bash
set -e

: "${PROXY_PORT:?Need to set PROXY_PORT (e.g. 6101)}"
: "${VPN_MAX_RETRIES:=3}"
: "${VPN_RETRY_DELAY:=5}"

OVPN_DIR="/etc/openvpn"
CREDS_FILE="$OVPN_DIR/proton_openvpn_userpass.txt"

function cleanup {
  killall openvpn 2>/dev/null || true
  killall tinyproxy 2>/dev/null || true
}
trap cleanup EXIT

function try_config {
  local cfg="$1"
  local base=$(basename "$cfg")
  echo "[vpn] 🎯 Trying $base"

  local temp_cfg="/tmp/$base"
  sed '/^up /d;/^down /d' "$cfg" > "$temp_cfg"
  openvpn --config "$temp_cfg" --auth-user-pass "$CREDS_FILE" --daemon
  sleep 2

  for ((i=1; i<=VPN_MAX_RETRIES; i++)); do
    if ip link show tun0 &>/dev/null; then
      echo "[vpn] ✅ tun0 is up"
      ip route del default 2>/dev/null || true
      ip route add default dev tun0
      return 0
    fi
    echo "[vpn] ⏳ Waiting for tun0 ($i/$VPN_MAX_RETRIES)..."
    sleep 2
  done

  echo "[vpn] ❌ tun0 never came up for $base"
  killall openvpn 2>/dev/null || true
  return 1
}

function connect_best_vpn {
  local configs=("$OVPN_DIR"/*.ovpn)
  while true; do
    for cfg in "${configs[@]}"; do
      if try_config "$cfg"; then
        echo "[vpn] 🚀 Connected via $(basename "$cfg")"
        return
      fi
      echo "[vpn] 🔄 Retrying next config in $VPN_RETRY_DELAY s..."
      sleep "$VPN_RETRY_DELAY"
    done
    echo "[vpn] 🔁 All configs failed—looping back..."
  done
}

function start_proxy {
  echo "[proxy] ✍️  Generating tinyproxy.conf for port $PROXY_PORT"
  envsubst '$PROXY_PORT' < /etc/tinyproxy/tinyproxy.conf.template \
    > /etc/tinyproxy/tinyproxy.conf

  echo "---- tinyproxy.conf ----"
  cat /etc/tinyproxy/tinyproxy.conf
  echo "------------------------"

  echo "[proxy] 🚀 Starting Tinyproxy in foreground"
  tinyproxy -d -c /etc/tinyproxy/tinyproxy.conf
}

# Generate a log directory writable by Tinyproxy
mkdir -p /var/log/tinyproxy /var/run
chown nobody:nogroup /var/log/tinyproxy /var/run
chmod 755 /var/log/tinyproxy /var/run

# Main loop
while true; do
  connect_best_vpn
  start_proxy
  echo "[main] 🔄 tinyproxy exited—restarting in $VPN_RETRY_DELAY s..."
  sleep "$VPN_RETRY_DELAY"
done
