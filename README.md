# 🐳 OpenVPN Proxy Setup Guide (Docker + ProtonVPN + Tinyproxy)

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
3. Run the following command to generate and start 1 proxy container:

```bash
chmod +x generate-compose.sh && ./generate-compose.sh 1 && sudo docker compose up -d --build
````

> 📝 **Note:** If you want multiple proxies (e.g., 3), change `1` to `3`. Proxies will start on ports `6101`, `6102`, `6103`, etc.

4. Check the OpenVPN connection and proxy status by viewing container logs:

```bash
docker compose logs -f vpn_proxy_1
```

---

## ✅ Test Your Proxy

### 🔹 With `curl` (requires `jq`):

```bash
sudo apt install jq -y
curl -s --proxy http://127.0.0.1:6101 https://ipinfo.io/json | jq -r '"IP: \(.ip) 🔸 City: \(.city) 🔸 Region: \(.region) 🔸 Country: \(.country) 🔸 TimeZone: \(.timezone)"'
```

### 🔹 With Python:

```bash
python3 -c "import requests; info = requests.get('https://ipinfo.io/json', proxies={'http':'http://127.0.0.1:6101','https':'http://127.0.0.1:6101'}).json(); print(f\"IP: {info['ip']} 🔸 City: {info['city']} 🔸 Region: {info['region']} 🔸 Country: {info['country']} 🔸 TimeZone: {info['timezone']}\")"
```
