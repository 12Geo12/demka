#!/bin/bash

# Проверка прав root
[ "$(id -u)" -ne 0 ] && echo "Запустите скрипт от root." && exit 1

# --- 1. АВТОМАТИЧЕСКИЙ ВЫБОР ИНТЕРФЕЙСА ---

# Сбор списка физических интерфейсов (исключаем lo и vlan)
IFACES=()
for i in /sys/class/net/*; do
    name=$(basename "$i")
    # Физическое устройство имеет папку 'device', vlan содержит '.', lo - loopback
    if [[ "$name" != "lo" && "$name" != *.* && -d "$i/device" ]]; then
        IFACES+=("$name")
    fi
done

if [ ${#IFACES[@]} -eq 0 ]; then echo "Ошибка: Интерфейсы не найдены."; exit 1; fi

echo "Выберите физический интерфейс:"
PS3="Номер интерфейса > "
select IFACE in "${IFACES[@]}"; do
    [ -n "$IFACE" ] && break || echo "Неверный выбор."
done

# --- 2. НАСТРОЙКА ФИЗИЧЕСКОГО ПОРТА ---

# Создание конфигурации родительского интерфейса (TYPE=eth)
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

# Создаем пустой файл адреса для корректной работы static
touch "/etc/net/ifaces/$IFACE/ipv4address"

# --- 3. НАСТРОЙКА VLAN ---

read -p "Введите VLAN ID (через пробел): " VLANS

for VID in $VLANS; do
    # Проверка на число
    [[ ! "$VID" =~ ^[0-9]+$ ]] && echo "Пропуск неверного ID: $VID" && continue
    
    VLAN_IF="${IFACE}.${VID}"
    mkdir -p "/etc/net/ifaces/$VLAN_IF"
    
    cat > "/etc/net/ifaces/$VLAN_IF/options" <<EOF
TYPE=vlan
HOST=$IFACE
VID=$VID
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
ONBOOT=yes
EOF
    
    # Упрощенный вывод
    echo "VLAN $VID настроен."
done

# --- 4. АВТОМАТИЧЕСКОЕ ПОДНЯТИЕ ПОРТОВ ---

echo "Применение настроек..."

# Поднимаем физический интерфейс
ifup "$IFACE" 2>/dev/null

# Поднимаем все созданные VLAN
for VID in $VLANS; do
    [[ "$VID" =~ ^[0-9]+$ ]] && ifup "${IFACE}.${VID}" 2>/dev/null
done

echo "Готово. Интерфейсы подняты."
