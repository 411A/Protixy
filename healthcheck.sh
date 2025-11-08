#!/usr/bin/env bash
# Health check script to verify VPN and proxy are working

# Check if tun0 interface exists and has an IP
if ! ip addr show tun0 &>/dev/null; then
    echo "[healthcheck] ❌ tun0 interface not found"
    exit 1
fi

# Check if tun0 has an IP address assigned
if ! ip addr show tun0 | grep -q "inet "; then
    echo "[healthcheck] ❌ tun0 has no IP address"
    exit 1
fi

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

# Try to make an actual connection through the proxy to verify it works
# Use a quick timeout to avoid hanging
if ! curl -s --max-time 5 --proxy "http://127.0.0.1:${PROXY_PORT}" https://ipinfo.io/ip >/dev/null 2>&1; then
    echo "[healthcheck] ❌ Cannot reach internet through proxy"
    exit 1
fi

echo "[healthcheck] ✅ All systems operational"
exit 0
