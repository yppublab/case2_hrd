#!/bin/bash

# Отдельный шебанг для переменных окружения, необходимый для образов на основе linuxserver.io
if [ -x /command/with-contenv ]; then
    exec /command/with-contenv bash "$0" "$@"
fi

set -euo pipefail

role="${1:---default}"

# Добавляем пользователей 
useradd -m "${AUDITOR_NAME}" && echo "${AUDITOR_NAME}:${AUDITOR_PASSWORD}" | chpasswd
useradd -m "${ADMIN_NAME}" && echo "${ADMIN_NAME}:${ADMIN_PASSWORD}" | chpasswd

# Настраиваем SSH
echo "[start.sh] SSH configuration ${ADMIN_NAME}"
mkdir -p /home/${ADMIN_NAME}/.ssh /home/${ADMIN_NAME}/.ssh/authorized_keys
cp /tmp/secrets/admin_id_rsa.pub /home/${ADMIN_NAME}/.ssh/authorized_keys/
chown -R ${ADMIN_NAME}:${ADMIN_NAME} /home/${ADMIN_NAME}/.ssh /home/${ADMIN_NAME}/.ssh/authorized_keys/admin_id_rsa.pub
chmod 700 /home/${ADMIN_NAME}/.ssh
chmod 600 /home/${ADMIN_NAME}/.ssh/authorized_keys

echo "[start.sh] SSH configuration ${AUDITOR_NAME}"
mkdir -p /home/${AUDITOR_NAME}/.ssh /home/${AUDITOR_NAME}/.ssh/authorized_keys
cp /tmp/secrets/auditor_id_rsa.pub /home/${AUDITOR_NAME}/.ssh/authorized_keys/
chown -R ${AUDITOR_NAME}:${AUDITOR_NAME} /home/${AUDITOR_NAME}/.ssh /home/${AUDITOR_NAME}/.ssh/authorized_keys/auditor_id_rsa.pub
chmod 700 /home/${AUDITOR_NAME}/.ssh 
chmod 600 /home/${AUDITOR_NAME}/.ssh/authorized_keys

# Стартуем SSH демон
echo "[start.sh] Starting SSH"
ssh-keygen -A
mkdir -p /run/sshd
chmod 755 /run/sshd
/usr/sbin/sshd

# Далее идут дополнительные действия, которые выполняются в зависимости от роли контейнера
echo "[start.sh] Choosing next step from args"
case "${role}" in
  admin)
    echo "[start] applying admin-specific bootstrap"
    cp /tmp/secrets/auditor_id_rsa /home/${AUDITOR_NAME}/.ssh/auditor_id_rsa
    chown ${AUDITOR_NAME}:${AUDITOR_NAME} /home/${AUDITOR_NAME}/.ssh/auditor_id_rsa
    chmod 0600 /home/${AUDITOR_NAME}/.ssh/auditor_id_rsa

    cp /tmp/secrets/admin_id_rsa /home/${ADMIN_NAME}/.ssh/admin_id_rsa
    chown ${ADMIN_NAME}:${ADMIN_NAME} /home/${ADMIN_NAME}/.ssh/admin_id_rsa
    chmod 0600 /home/${ADMIN_NAME}/.ssh/admin_id_rsa
    ;;
  fileserver)
    echo "[start] applying fileserver-specific bootstrap"
    service smbd restart || service samba restart
    ;;
  *)
    echo "[start] no role-specific actions for ${role}"
    ;;
esac

# Удаляем временные ключи SSH
rm -rf /tmp/secrets

# Действия по умолчанию: ставим iproute2 и настраиваем маршрут через FW
# Для WG сервер и FW маршруты настраиваются отдельно
echo "[start] Default route configuration (except wg-server & fw)"
if [[ ${role} != "wg-server" && ${role} != "fw" ]]; then
    # Устанавливаем пакет iproute2 (для ubuntu/alpine)
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y iproute2
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache iproute2
    else
        echo "[start] package manager not found for iproute2" >&2
    fi
    ip route del default || true
    ip route add default via "${GATEWAY_IP}" || true
else
    echo "[start.sh] Step skipped"
fi

if [[ ${role} == "web" ]]; then
    echo "[start] Done starting langflow"
    langflow run
else
    echo "[start] Done"
    exec tail -f /dev/null
fi