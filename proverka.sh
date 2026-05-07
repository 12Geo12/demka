#!/bin/bash
#
# Скрипт настройки DHCP сервера (ИСПРАВЛЕННЫЙ)
# Исходник: https://github.com/12Geo12/demka/blob/main/1.7.dhcpserv.sh
# 
# ИЗМЕНЕНИЯ:
# 1. Удален блок "ОЧИСТКА VLAN", чтобы не удалять существующие интерфейсы.
# 2. Настройка DHCP переведена на VLAN-интерфейс (ens37.10).

# === ПЕРЕМЕННЫЕ ===
LAN_IFACE="ens37"
VLAN_IFACE="ens37.10"
DOMAIN="au-team.irpo"
# Сеть SRV-Net (настроенная в скрипте VLAN)
NETWORK="192.168.10.0"
NETMASK="255.255.255.192" # /26
BROADCAST="192.168.10.63"
GATEWAY="192.168.10.1"
DNS_SRV="192.168.10.10"

DHCP_CONF="/etc/dhcp/dhcpd.conf"
SYSdhcpd="/etc/sysconfig/dhcpd"

echo "------------------------------------------------"
echo "Настройка DHCP-сервера для сети SRV-Net (VLAN 10)"
echo "------------------------------------------------"

# 1. Установка DHCP-сервера
apt-get update -qq
apt-get install -y dhcp-server

# 2. ПРОВЕРКА НАЛИЧИЯ VLAN
# Мы не создаем VLAN здесь, мы проверяем, есть ли он (от 1.3.vlans.sh)
if ! ip link show "$VLAN_IFACE" &>/dev/null; then
    echo "ВНИМАНИЕ: Интерфейс $VLAN_IFACE не найден."
    echo "Проверьте, выполнен ли скрипт 1.3.vlans.sh."
    echo "Продолжаем настройку конфига..."
fi

# 3. Формирование конфигурационного файла DHCP
# Резервная копия старого конфига
[ -f "$DHCP_CONF" ] && cp "$DHCP_CONF" "${DHCP_CONF}.bak"

cat > "$DHCP_CONF" << EOF
# DHCP Configuration
default-lease-time 600;
max-lease-time 7200;
authoritative;
ddns-update-style none;

# Сеть для серверов (SRV-Net)
subnet $NETWORK netmask $NETMASK {
    range 192.168.10.10 192.168.10.60;
    option routers $GATEWAY;
    option subnet-mask $NETMASK;
    option broadcast-address $BROADCAST;
    option domain-name "$DOMAIN";
    option domain-name-servers $DNS_SRV;
}
EOF

# 4. Настройка интерфейса запуска (DHCPDARGS)
# В оригинале здесь скрипт удалял VLAN и прописывал физический интерфейс.
# Мы же указываем слушать на VLAN-подынтерфейсе.

if [ -f "$SYSdhcpd" ]; then
    # Удаляем старые параметры если есть
    sed -i '/^DHCPDARGS/d' "$SYSdhcpd"
fi
echo "DHCPDARGS=\"$VLAN_IFACE\"" >> "$SYSdhcpd"

echo "------------------------------------------------"
echo "Готово. Конфигурация применена:"
echo "  - Интерфейс: $VLAN_IFACE"
echo "  - Сеть: $NETWORK/$NETMASK"
echo "------------------------------------------------"

# 5. Перезапуск службы
systemctl enable dhcpd
systemctl restart dhcpd

if systemctl is-active --quiet dhcpd; then
    echo "DHCP-сервер запущен успешно."
else
    echo "ОШИБКА: DHCP-сервер не запустился. Проверьте логи (journalctl -u dhcpd)."
fi
