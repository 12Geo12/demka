#!/bin/bash

# 1. Проверка прав root
[ "$(id -u)" -ne 0 ] && echo "Требуются права root." && exit 1

# 2. Автоматический поиск и выбор физического интерфейса
IFACES=()
for i in /sys/class/net/*; do
    name=$(basename "$i")
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

# 4. Ввод базовых данных
read -p "Введите первые два октета подсети (например 192.168): " BASE_IP
read -p "Введите последний октет IP хоста (например 1): " HOST_ID
read -p "Введите список VLAN ID (через пробел: 100 200 999): " VLANS

# 5. Настройка VLAN в цикле
for VID in $VLANS; do
    [[ ! "$VID" =~ ^[0-9]+$ ]] && echo "Пропуск неверного ID: $VID" && continue
    
    # Автоматический расчет 3-го октета: VLAN 100 -> 10, VLAN 999 -> 99
    # (целочисленное деление на 10)
    OCTET_3=$((VID / 10))
    FULL_IP="${BASE_IP}.${OCTET_3}.${HOST_ID}"

    # Запрос маски для каждого VLAN (так как они разные в вашем примере)
    read -p "Введите маску для VLAN $VID (например 26, 28, 29): " MASK
    
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

    # Запись IP адреса (ИСПРАВЛЕНО: путь к файлу без ошибок)
    echo "${FULL_IP}/${MASK}" > "/etc/net/ifaces/$VLAN_IF/ipv4address"
    
    # Вывод в требуемом формате (Таблица)
    # Пример: HQ-RTR (VLAN100) 192.168.10.1/26 192.168.10.1
    echo "$(hostname) (VLAN${VID}) ${FULL_IP}/${MASK} ${FULL_IP}"
done

# 6. Автоматическое поднятие портов
echo ""
echo "Применение настроек и поднятие интерфейсов..."

ifdown "$IFACE" 2>/dev/null
ifup "$IFACE" 2>/dev/null

for VID in $VLANS; do
    if [[ "$VID" =~ ^[0-9]+$ ]]; then
        VLAN_IF="${IFACE}.${VID}"
        ifdown "$VLAN_IF" 2>/dev/null
        ifup "$VLAN_IF" 2>/dev/null
    fi
done

echo "Готово."
