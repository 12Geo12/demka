#!/bin/bash

# ==============================================================================
# 1. АВТОМАТИЧЕСКИЙ ВЫБОР ФИЗИЧЕСКОГО ИНТЕРФЕЙСА
# ==============================================================================

# Ищем физические интерфейсы в системе
INTERFACES=()
for iface in /sys/class/net/*; do
    name=$(basename "$iface")
    # Фильтруем: не lo, не vlan (без точки), и есть папка device (физическое железо)
    if [[ "$name" != "lo" && "$name" != *.* && -d "$iface/device" ]]; then
        INTERFACES+=("$name")
    fi
done

if [ ${#INTERFACES[@]} -eq 0 ]; then
    echo "Ошибка: Физические интерфейсы не найдены."
    exit 1
fi

# Предлагаем выбор (сохраняем интерактивность оригинала)
echo "Доступные сетевые интерфейсы:"
select IFACE in "${INTERFACES[@]}"; do
    if [ -n "$IFACE" ]; then
        echo "Выбран интерфейс: $IFACE"
        break
    else
        echo "Неверный ввод. Пожалуйста, выберите номер из списка."
    fi
done

# ==============================================================================
# 2. НАСТРОЙКА ФИЗИЧЕСКОГО ИНТЕРФЕЙСА (КОРРЕКТИРОВКА ОРИГИНАЛА)
# ==============================================================================

# Создаем конфигурацию для физического интерфейса
mkdir -p /etc/net/ifaces/$IFACE

# Записываем параметры, которые вы передали
cat > /etc/net/ifaces/$IFACE/options <<EOF
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

# Создаем пустой файл ipv4address для корректной работы static режима без IP
touch /etc/net/ifaces/$IFACE/ipv4address

# ==============================================================================
# 3. НАСТРОЙКА VLAN (ОРИГИНАЛЬНАЯ ЛОГИКА)
# ==============================================================================

read -p "Введите список VLAN ID (через пробел, например: 10 20 30): " VLANS

for VLAN_ID in $VLANS; do
    VLAN_IF="${IFACE}.${VLAN_ID}"
    mkdir -p /etc/net/ifaces/${VLAN_IF}
    
    cat > /etc/net/ifaces/${VLAN_IF}/options <<EOF
TYPE=vlan
HOST=$IFACE
VID=$VLAN_ID
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
ONBOOT=yes
EOF
    
    echo "Настроен VLAN: $VLAN_IF"
done

# ==============================================================================
# 4. АВТОМАТИЧЕСКОЕ ПОДНЯТИЕ ПОРТОВ (ЗАКРЫТЫХ/ОТКРЫТЫХ)
# ==============================================================================

echo ""
echo "Применение настроек и поднятие интерфейсов..."

# Сначала поднимаем физический интерфейс ("открываем порт")
ifup $IFACE

# Затем поднимаем все созданные VLAN
for VLAN_ID in $VLANS; do
    VLAN_IF="${IFACE}.${VLAN_ID}"
    ifup ${VLAN_IF}
done

echo "Готово. Интерфейсы подняты."
