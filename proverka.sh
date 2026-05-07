#!/bin/bash
# 1.7.dhcpserv.sh (Улучшенная версия с полной очисткой)
# 
# Логика:
# 1. Полностью удаляет все VLAN на интерфейсе (Hard Reset).
# 2. Создает нужный VLAN (ens37.10) заново с нуля (гарантия правильности).
# 3. Настраивает DHCP на этом VLAN.

# === КОНФИГУРАЦИЯ ===
LAN_IFACE="ens37"          # Физический интерфейс
VLAN_ID=10                 # ID VLAN
VLAN_IFACE="${LAN_IFACE}.${VLAN_ID}"

# Параметры сети (создаются заново после очистки)
IP_ADDR="192.168.10.1/26"  # IP Шлюза (на роутере)
NETWORK="192.168.10.0"
NETMASK="255.255.255.192"
DNS_SRV="192.168.10.10"

DHCP_CONF="/etc/dhcp/dhcpd.conf"
DHCPD_ARGS="/etc/sysconfig/dhcpd"
IFACES_DIR="/etc/net/ifaces"

echo "------------------------------------------------"
echo "Запуск скрипта с ПОЛНОЙ ОЧИСТКОЙ VLAN"
echo "------------------------------------------------"

# === ШАГ 1: ПОЛНАЯ ОЧИСТКА (HARD RESET) ===
echo "[1/4] Полная очистка старых VLAN на $LAN_IFACE..."
# Удаляем файлы конфигурации ifaces
for vlan_dir in $IFACES_DIR/${LAN_IFACE}.*; do
    if [ -d "$vlan_dir" ]; then
        echo "   Удаляю конфиг: $vlan_dir"
        rm -rf "$vlan_dir"
    fi
done

# Удаляем интерфейсы из ядра
for vlan_name in $(ip link show | grep -o "${LAN_IFACE}\.[0-9]*"); do
    echo "   Удаляю интерфейс: $vlan_name"
    ip link set "$vlan_name" down 2>/dev/null
    ip link del "$vlan_name" 2>/dev/null
done

echo "   Очистка завершена."

# === ШАГ 2: СОЗДАНИЕ VLAN ЗАНОВО ===
# Так как мы всё удалили, нужно создать чистую конфигурацию для нашего VLAN
echo "[2/4] Создание VLAN $VLAN_IFACE с нуля..."

# Создаем папку интерфейса
mkdir -p "$IFACES_DIR/${VLAN_IFACE}"

# Пишем options
cat > "$IFACES_DIR/${VLAN_IFACE}/options" << EOF
BOOTPROTO=static
TYPE=vlan
ONBOOT=yes
HOST=$LAN_IFACE
VID=$VLAN_ID
CONFIG_IPV4=yes
EOF

# Пишем IP адрес
echo "$IP_ADDR" > "$IFACES_DIR/${VLAN_IFACE}/ipv4address"

# Поднятие интерфейса через network (или вручную для быстродействия)
ifup "$VLAN_IFACE" 2>/dev/null || (ip link add link "$LAN_IFACE" name "$VLAN_IFACE" type vlan id "$VLAN_ID" && ip addr add "$IP_ADDR" dev "$VLAN_IFACE" && ip link set "$VLAN_IFACE" up)

echo "   VLAN $VLAN_IFACE поднят с IP $IP_ADDR"

# === ШАГ 3: НАСТРОЙКА DHCP ===
echo "[3/4] Настройка DHCP-сервера..."
apt-get update -qq
apt-get install -y dhcp-server

# Генерация конфига
cat > "$DHCP_CONF" << EOF
default-lease-time 600;
max-lease-time 7200;
authoritative;
ddns-update-style none;

subnet $NETWORK netmask $NETMASK {
    range 192.168.10.10 192.168.10.60;
    option routers 192.168.10.1;
    option subnet-mask $NETMASK;
    option broadcast-address 192.168.10.63;
    option domain-name "au-team.irpo";
    option domain-name-servers $DNS_SRV;
}
EOF

# Настройка прослушивания
if [ -f "$DHCPD_ARGS" ]; then
    sed -i '/^DHCPDARGS/d' "$DHCPD_ARGS"
fi
echo "DHCPDARGS=\"$VLAN_IFACE\"" >> "$DHCPD_ARGS"

# === ШАГ 4: ЗАПУСК ===
echo "[4/4] Перезапуск DHCP..."
systemctl enable dhcpd
systemctl restart dhcpd

if systemctl is-active --quiet dhcpd; then
    echo "------------------------------------------------"
    echo "УСПЕХ: Система сброшена, VLAN пересоздан, DHCP работает на $VLAN_IFACE"
    echo "------------------------------------------------"
else
    echo "ОШИБКА запуска DHCP. Проверьте логи."
fi
