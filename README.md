[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/411A/Protixy)

# 🐳 OpenVPN Proxy Setup Guide (Docker + ProtonVPN + Tinyproxy)

## 🌟 Features

- ✅ **Self-Repairing**: Automatically recovers from connection failures
- ✅ **Zero Manual Intervention**: No need to manually restart containers
- ✅ **Health Monitoring**: Continuous VPN connection monitoring with auto-restart
- ✅ **Smart Config Rotation**: Automatically tries different VPN servers until one works
- ✅ **Docker Health Checks**: Built-in Docker healthcheck for container orchestration
- ✅ **Production Ready**: Handles network instability, timeout issues, and reconnections

## 0. Prerequisites

- Install **Docker** on your machine.

## 1. Download ProtonVPN OpenVPN Configs

1. Visit: [ProtonVPN OpenVPN Downloads](https://account.protonvpn.com/downloads#openvpn-configuration-files)
2. Log in to your ProtonVPN account.
3. Choose a protocol (UDP/TCP) and download the `.ovpn` configuration files.
4. Place all `.ovpn` files into the `ovpn_configs` directory.

⚠️ The `jp-free-1.protonvpn.udp.ovpn` file included is a **sample placeholder** and will **not work** for actual connections. Replace it with a real `.ovpn` file from your ProtonVPN account.

5. Inside the `ovpn_configs` directory, open the existing `proton_openvpn_userpass.txt` file and add your ProtonVPN login credentials, You can obtain your username and password from [ProtonVPN's account page](https://account.protonvpn.com/account-password#openvpn):
```
Username
Password
```

## 2. Deploy to VPS

1. Move the project folder to your VPS.
2. SSH into your VPS and `cd` into the project folder.
3. **(Optional)** Fix OpenVPN warnings by patching the configs:

```bash
chmod +x fix-ovpn-warnings.sh && ./fix-ovpn-warnings.sh
```

4. Run the following command to generate and start 1 proxy container:

```bash
chmod +x generate-compose.sh && ./generate-compose.sh 1 && sudo docker compose up -d --build
````

> 📝 **Note:** If you want multiple proxies (e.g., 3), change `1` to `3`. Proxies will start on ports `6101`, `6102`, `6103`, etc.

> ⚠️ ProtonVPN's Free plan allows only 1 connection.

5. Check the OpenVPN connection and proxy status by viewing container logs:

```bash
docker compose logs -f vpn_proxy_1
```

---

## 🔄 Self-Repair Mechanism

The container is now **fully autonomous** and will handle failures automatically:

### Automatic Recovery Features:

1. **Health Monitoring**: Checks VPN connection every 60 seconds
   - Verifies `tun0` interface is up
   - Confirms internet connectivity through VPN
   - Tests proxy functionality

2. **Auto-Restart on Failure**: 
   - Detects connection drops (3 consecutive failures)
   - Automatically restarts OpenVPN
   - Tries different VPN servers from your configs

3. **Retry Loop**:
   - If all configs fail, waits 5 minutes and tries again
   - Never gives up - keeps attempting to reconnect
   - No manual intervention required

4. **Docker Health Check**:
   - Container marked as unhealthy if VPN fails
   - Docker can automatically restart unhealthy containers
   - Integrates with orchestration tools (Kubernetes, Swarm, etc.)

### Monitor Container Health:

```bash
# Check health status
docker compose ps

# View detailed health check logs
docker inspect vpn_proxy_1 --format='{{.State.Health.Status}}'

# Watch real-time logs
docker compose logs -f vpn_proxy_1
```

---

## 🌐 Using VPN Proxies from Other Docker Containers

**Note:** The proxy is always accessible from the host at `http://127.0.0.1:6101`. The Docker network is an **optional** feature for container-to-container communication.

The proxies are on a Docker network called `vpn_proxy_network`. Other containers can connect to use them by service name instead of localhost.

### Connect Existing Container

```bash
docker network connect vpn_proxy_network your_container
# Then use: http://vpn_proxy_1:6101 as proxy
```

### Use in Docker Compose

```yaml
services:
  your_app:
    image: your-app:latest
    networks:
      - vpn_proxy_network
    environment:
      - HTTP_PROXY=http://vpn_proxy_1:6101
      - HTTPS_PROXY=http://vpn_proxy_1:6101

networks:
  vpn_proxy_network:
    external: true
```

### Network Container Mode (transparent routing)

```bash
docker run --net=container:vpn_proxy_1 your-image
# All traffic automatically goes through VPN
```

---

## ✅ Test Your Proxy

### From Host Machine (or any external application)

The proxy is accessible at `http://127.0.0.1:6101` - no Docker network needed!

### 🔹 With `curl` (requires `jq`):

📝 Make sure the `jq` is installed.
```bash
sudo apt install jq -y
```

```bash
curl -s --proxy http://127.0.0.1:6101 https://ipinfo.io/json | jq -r '"IP: \(.ip) 🔸 City: \(.city) 🔸 Region: \(.region) 🔸 Country: \(.country) 🔸 TimeZone: \(.timezone)"'
```

### 🔹 With Python:

```bash
python3 -c "import requests; info = requests.get('https://ipinfo.io/json', proxies={'http':'http://127.0.0.1:6101','https':'http://127.0.0.1:6101'}).json(); print(f\"IP: {info['ip']} 🔸 City: {info['city']} 🔸 Region: {info['region']} 🔸 Country: {info['country']} 🔸 TimeZone: {info['timezone']}\")"
```

---

## 🛠️ Troubleshooting

### Quick Diagnostic

```bash
chmod +x diagnose.sh && ./diagnose.sh
```

### Container keeps restarting?
This is normal during initial connection attempts. The container will:
1. Try all available VPN configs in random order
2. Wait 5 minutes if all fail
3. Try again indefinitely until successful

### Connection seems slow?
Check the logs to see which VPN server you're connected to:
```bash
docker compose logs vpn_proxy_1 | grep "Connection successful"
```

### Want to force a server change?
Simply restart the container:
```bash
docker compose restart vpn_proxy_1
```

### Check if container is healthy:
```bash
docker compose exec vpn_proxy_1 /usr/local/bin/healthcheck.sh
```

---

## 📊 Configuration Options

You can customize the behavior by editing `start.sh`:

- `VPN_CONNECT_TIMEOUT=20` - Seconds to wait for VPN connection
- `HEALTH_CHECK_INTERVAL=60` - Seconds between health checks
- `MAX_FAILURES=3` - Consecutive failures before restart
- `RETRY_DELAY=300` - Seconds to wait after all configs fail

---

## 🔧 Advanced: Manual Config Patching

If you want to permanently fix OpenVPN warnings in your config files:

```bash
./fix-ovpn-warnings.sh
```

This will add compatibility options to all `.ovpn` files. Backups are created automatically.

To restore originals:
```bash
cd ovpn_configs && for f in *.ovpn.bak; do mv "$f" "${f%.bak}"; done
```
