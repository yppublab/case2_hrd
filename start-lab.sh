#!/usr/bin/env bash
set -e
CMD="${1:-}"

if [ -z "$CMD" ]; then
  echo "Usage: ./start-lab.sh [init|up|down|logs|ps]"
  exit 1
fi

add_rule_if_missing() {
  local table="${1:-filter}" ; shift || true
  if [ "$table" = "nat" ]; then
    sudo iptables -t nat -C "$@" 2>/dev/null || sudo iptables -t nat -A "$@"
  else
    sudo iptables -C "$@" 2>/dev/null || sudo iptables -A "$@"
  fi
}

del_rule_if_exists() {
  local table="${1:-filter}" ; shift || true
  if [ "$table" = "nat" ]; then
    sudo iptables -t nat -C "$@" 2>/dev/null && sudo iptables -t nat -D "$@"
  else
    sudo iptables -C "$@" 2>/dev/null && sudo iptables -D "$@"
  fi
}

case "$CMD" in
  init)
    echo "[*] Инициализация: генерация WG конфигураций (если ещё не сгенерированы)..."
    ./generate_wg_keys.sh
    echo "[*] Инициализация завершена."
    ;;

  up)
    if [ ! -f "./secrets/wg.conf" ] || [ ! -f "./wg-server/config/wg0.conf" ]; then
      echo "[*] Не найдены wg-конфиги — генерируем..."
      ./generate_wg_keys.sh
    fi

    echo "[*] Запуск контейнеров..."
    docker compose up -d --build
    echo

    # Firewall хоста: трафик к 172.31.0.0/24 — только через wg0
    # разрешаем выход на внутреннюю сеть через wg0
    add_rule_if_missing filter OUTPUT -o wg0 -d 172.31.0.0/24 -j ACCEPT
    # всё остальное к 172.31.0.0/24 — запрещаем
    add_rule_if_missing filter OUTPUT -d 172.31.0.0/24 -j REJECT

    docker compose ps
    echo
    echo "Веб (Langflow) доступен ТОЛЬКО на хосте:   http://localhost:7860"
    echo "WireGuard server слушает:                  127.0.0.1:51820/udp"
    ;;

  down)
    echo "[*] Остановка окружения..."
    docker compose down -v

    # Снимаем наши правила
    del_rule_if_exists filter OUTPUT -d 172.31.0.0/24 -j REJECT
    del_rule_if_exists filter OUTPUT -o wg0 -d 172.31.0.0/24 -j ACCEPT
    ;;

  logs)
    docker compose logs -f
    ;;

  ps)
    docker compose ps
    ;;

  *)
    echo "Unknown command: $CMD"
    exit 2
    ;;
esac
