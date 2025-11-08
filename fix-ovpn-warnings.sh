#!/usr/bin/env bash
# Script to patch OpenVPN configs to fix common warnings

OVPN_DIR="./ovpn_configs"

if [ ! -d "$OVPN_DIR" ]; then
    echo "Error: $OVPN_DIR directory not found"
    exit 1
fi

echo "🔧 Patching OpenVPN configs to fix warnings..."

for config in "$OVPN_DIR"/*.ovpn; do
    if [ ! -f "$config" ]; then
        continue
    fi
    
    echo "  📝 Processing $(basename "$config")"
    
    # Create backup
    cp "$config" "$config.bak"
    
    # Add compatibility options if not present
    if ! grep -q "^# Patched for compatibility" "$config"; then
        cat >> "$config" <<'EOF'

# Patched for compatibility and stability
auth SHA1
cipher AES-256-CBC
ping 10
ping-restart 120
resolv-retry infinite
persist-key
persist-tun
mute-replay-warnings
auth-nocache
EOF
        echo "    ✅ Patched"
    else
        echo "    ⏭️  Already patched"
    fi
done

echo "✅ All configs processed. Backups saved with .bak extension"
echo "💡 You can restore originals with: for f in $OVPN_DIR/*.ovpn.bak; do mv \"\$f\" \"\${f%.bak}\"; done"
