#!/usr/bin/env bash
set -euo pipefail

OUT_SERVER_DIR="./wg-server/config"
OUT_SECRETS_DIR="./secrets"

INT_SUBNET="172.31.0.0/24"   # внутренняя сеть (lab_net)
WG_SERVER_IP="10.99.0.1/24"
WG_CLIENT_IP="10.99.0.50/32"
WG_ENDPOINT="127.0.0.1:51820"

mkdir -p "$OUT_SERVER_DIR" "$OUT_SECRETS_DIR"

gen_wg_pair() {
  local prefix="$1" tmp; tmp=$(mktemp -d)
  docker run --rm -v "$tmp":/out alpine:3.19 sh -lc \
    "apk add --no-cache wireguard-tools >/dev/null 2>&1; wg genkey >/out/priv; cat /out/priv | wg pubkey >/out/pub"
  cat "$tmp/priv" > "${prefix}.private"
  cat "$tmp/pub"  > "${prefix}.public"
  chmod 600 "${prefix}.private"; chmod 644 "${prefix}.public"
  rm -rf "$tmp"
}

if [ ! -f "$OUT_SERVER_DIR/server.private" ] || [ ! -f "$OUT_SERVER_DIR/client.private" ]; then
  echo "[*] Генерирую WG ключи..."
  gen_wg_pair "$OUT_SERVER_DIR/server"
  gen_wg_pair "$OUT_SERVER_DIR/client"
fi

SERVER_PRIV=$(cat "$OUT_SERVER_DIR/server.private")
SERVER_PUB=$(cat "$OUT_SERVER_DIR/server.public")
CLIENT_PRIV=$(cat "$OUT_SERVER_DIR/client.private")
CLIENT_PUB=$(cat "$OUT_SERVER_DIR/client.public")

# --- wg0.conf (сервер в контейнере lab_wg_server) ---
# ВАЖНО: wg-server подключён к двум сетям: ext_net (eth0: 172.24.0.0/16) и lab_net (eth1: 172.31.0.0/24).
# Ниже автодетект именно ИНТЕРФЕЙСА lab_net (172.31.*) для FORWARD/NAT.
cat > "$OUT_SERVER_DIR/wg0.conf" <<EOF
[Interface]
Address = ${WG_SERVER_IP}
ListenPort = 51820
PrivateKey = ${SERVER_PRIV}

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = IFACE=\$(ip -o -4 addr | awk '\$4 ~ /^172\\.31\\.0\\./ {print \$2; exit}'); iptables -A FORWARD -i wg0 -o \$IFACE -d ${INT_SUBNET} -j ACCEPT
PostUp = IFACE=\$(ip -o -4 addr | awk '\$4 ~ /^172\\.31\\.0\\./ {print \$2; exit}'); iptables -A FORWARD -i \$IFACE -o wg0 -s ${INT_SUBNET} -j ACCEPT
PostUp = IFACE=\$(ip -o -4 addr | awk '\$4 ~ /^172\\.31\\.0\\./ {print \$2; exit}'); iptables -t nat -A POSTROUTING -s ${WG_CLIENT_IP} -d ${INT_SUBNET} -o \$IFACE -j MASQUERADE

PostDown = IFACE=\$(ip -o -4 addr | awk '\$4 ~ /^172\\.31\\.0\\./ {print \$2; exit}'); iptables -D FORWARD -i wg0 -o \$IFACE -d ${INT_SUBNET} -j ACCEPT
PostDown = IFACE=\$(ip -o -4 addr | awk '\$4 ~ /^172\\.31\\.0\\./ {print \$2; exit}'); iptables -D FORWARD -i \$IFACE -o wg0 -s ${INT_SUBNET} -j ACCEPT
PostDown = IFACE=\$(ip -o -4 addr | awk '\$4 ~ /^172\\.31\\.0\\./ {print \$2; exit}'); iptables -t nat -D POSTROUTING -s ${WG_CLIENT_IP} -d ${INT_SUBNET} -o \$IFACE -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${WG_CLIENT_IP}
EOF

# --- wg.conf (клиент/артефакт на вебе) ---
cat > "$OUT_SECRETS_DIR/wg.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${WG_CLIENT_IP}
DNS = 10.99.0.1

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${WG_ENDPOINT}
AllowedIPs = ${INT_SUBNET}
PersistentKeepalive = 25
EOF

# --- SSH ключи для admin (приватный -> user_pc:/root/id_rsa, публичный -> admin_pc:authorized_keys) ---
if [ ! -f "$OUT_SECRETS_DIR/admin_id_rsa" ]; then
  docker run --rm -u "$(id -u):$(id -g)" -v "$(pwd)/$OUT_SECRETS_DIR":/out alpine:3.19 \
    sh -lc "apk add --no-cache openssh >/dev/null 2>&1; ssh-keygen -t rsa -b 2048 -f /out/admin_id_rsa -N '' >/dev/null 2>&1"
  chmod 600 "$OUT_SECRETS_DIR/admin_id_rsa"; chmod 644 "$OUT_SECRETS_DIR/admin_id_rsa.pub"
fi

echo "[*] Готово:
 - Сервер WG: $OUT_SERVER_DIR/wg0.conf
 - Клиентский конфиг: $OUT_SECRETS_DIR/wg.conf
 - SSH ключи: $OUT_SECRETS_DIR/admin_id_rsa(.pub)"
