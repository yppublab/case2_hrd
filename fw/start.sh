#!/usr/bin/env bash
set -euo pipefail

# Enable IPv4 forwarding (privileged container)
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# Prepare PATH
echo 'export PATH=/usr/sbin:/sbin:$PATH' > /etc/profile.d/00-sbin.sh

# Rename interfaces to stable names by subnet (нужно чтобы обеспечить стабильность привязки названий интерфейсов подсетям)
echo "[fw] Renaming interfaces by subnet..."
# Collect non-loopback IPv4 interfaces
while read -r line; do
  dev=$(echo "$line" | awk '{print $2}')
  cidr=$(echo "$line" | awk '{print $4}')
  [ "$dev" = "lo" ] && continue
  ip=${cidr%/*}
  # Derive /24 subnet x.y.z.0/24
  subnet=$(echo "$ip" | awk -F. '{printf "%s.%s.%s.0/24\n", $1,$2,$3}')
  new=""
  case "$subnet" in
    172.31.1.0/24)   new="eth_users"  ;;
    172.31.2.0/24)  new="eth_admin"  ;;
    172.31.0.0/24)  new="eth_dmz" ;;
    172.31.4.0/24)  new="eth_servers" ;;
  esac
  [ -z "$new" ] && continue
  [ "$dev" = "$new" ] && continue
  # Skip if target name is already taken
  if ip link show "$new" >/dev/null 2>&1; then
    echo "[fw] Target name '$new' already exists, skipping $dev"
    continue
  fi
  echo "[fw] renaming $dev ($cidr) -> $new"
  ip link set dev "$dev" down || true
  ip link set dev "$dev" name "$new" || true
  ip link set dev "$new" up || true
done < <(ip -o -4 addr show)

# Задаем дефолтный маршрут на NAT
ip route add default via 172.31.0.12 dev eth_dmz || true
echo "Set default route via 172.31.0.12 / eth_dmz"

# Load nftables rules
nft -f /etc/nftables.conf

#/usr/local/bin/start.sh fw

exec tail -f /dev/null
