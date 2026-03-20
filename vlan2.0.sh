#!/bin/bash

# 1. Проверка прав root
[ "$(id -u)" -ne 0 ] && echo "Требуются права root." && exit 1

# 2. Автоматический поиск и выбор физического интерфейса
IFACES=()
for i in /sys/class/net/*; do
    name=$(basename "$i")
    # Фильтр: физическое устройство (есть папка device), не loopback, не vlan
    if [[ "$name" != "lo" && "$name" != *.* && -d "$i/device" ]]; then
        IFACES+=("$name")
    fi
done

[ ${#IFACES[@]} -eq 0 ] && echo "Ошибка: Интерфейсы не найдены." && exit 1

echo "Выберите физический интерфейс:"
PS3="Номер > "
select IFACE in "${IFACES[@]}"; do
    [ -n "$IFACE" ] && break || echo "Неверный выбор."
done

# 3. Настройка физического интерфейса (TYPE=eth)
mkdir -p "/etc/net/ifaces/$IFACE"
cat > "/etc/net/ifaces/$IFACE/options" <<EOF
TYPE=eth
CONFIG_WIRELESS=no
BOOTPROTO=static
SYSTEMD_BOOTPROTO=static
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
ONBOOT=yes
EOF
touch "/etc/net/ifaces/$IFACE/ipv4address"

# 4. Ввод данных для IP-адресации
while true; do
    read -p "Введите первые два октета подсети (например 192.168): " BASE_IP
    # Простая проверка формата
    if [[ "$BASE_IP" =~ ^[0-9]+\.[0-9]+$ ]]; then
        break
    else
        echo "Ошибка формата. Введите два числа через точку (например: 10.10)."
    fi
done

read -p "Введите последний октет IP хоста (например 1 или 254): " HOST_ID
read -p "Введите маску (нажмите Enter для 24): " MASK
MASK=${MASK:-24}

# 5. Ввод и настройка VLAN
read -p "Введите список VLAN ID (через пробел): " VLANS

for VID in $VLANS; do
    # Проверка на число
    [[ ! "$VID" =~ ^[0-9]+$ ]] && echo "Пропуск неверного ID: $VID" && continue
    
    VLAN_IF="${IFACE}.${VID}"
    mkdir -p "/etc/net/ifaces/$VLAN_IF"
    
    # Конфигурация VLAN
    cat > "/etc/net/ifaces/$VLAN_IF/options" <<EOF
TYPE=vlan
HOST=$IFACE
VID=$VID
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
ONBOOT=yes
EOF

    # ИСПРАВЛЕНИЕ: Убрана опечатка, путь теперь верный
    # Автоматическая установка IP адреса: BASE_IP.VID.HOST_ID
    echo "${BASE_IP}.${VID}.${HOST_ID}/${MASK}" > "/etc/net/ifaces/$VLAN_IF/ipv4address"
    
    echo "VLAN $VID настроен: IP ${BASE_IP}.${VID}.${HOST_ID}/${MASK}"
done

# 6. Автоматическое поднятие портов
echo "Применение настроек..."
ifdown "$IFACE" 2>/dev/null
ifup "$IFACE" 2>/dev/null

for VID in $VLANS; do
    if [[ "$VID" =~ ^[0-9]+$ ]]; then
        VLAN_IF="${IFACE}.${VID}"
        # Сначала отключаем, потом включаем для применения нового IP
        ifdown "$VLAN_IF" 2>/dev/null
        ifup "$VLAN_IF" 2>/dev/null
    fi
done

echo "Готово. Проверка статуса:"
ip -br a | grep "$IFACE"
