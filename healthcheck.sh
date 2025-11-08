#!/usr/bin/env bash
# Health check script to verify VPN and proxy processes are running

# Check if OpenVPN process is running
if ! pgrep -x openvpn >/dev/null; then
    echo "[healthcheck] ❌ OpenVPN process not running"
    exit 1
fi

# Check if Tinyproxy is running
if ! pgrep -x tinyproxy >/dev/null; then
    echo "[healthcheck] ❌ Tinyproxy process not running"
    exit 1
fi

echo "[healthcheck] ✅ All processes operational"
exit 0
