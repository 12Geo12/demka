#!/bin/bash
# ==============================================================================
# VLAN Script for ALT Linux 10.4 (etcnet) - FIXED
# ==============================================================================

set -e

# Цвета (исправлено экранирование)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

IFACES_DIR="/etc/net/ifaces"

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Ошибка: Запустите от root${NC}"
    exit 1
fi

# Проверка etcnet
if [ ! -d "$IFACES_DIR" ]; then
    echo -e "${RED}Ошибка: $IFACES_DIR не найдена (ALT Linux)${NC}"
    exit 1
fi

# ==============================================================================
# ФУНКЦИИ
# ==============================================================================

# Расчёт CIDR по количеству хостов
calculate_cidr() {
    local hosts=$1
    local bits=0
    [ "$hosts" -lt 1 ] && hosts=1
    [ "$hosts" -gt 254 ] && hosts=254
    while [ $(( (1 << bits) - 2 )) -lt "$hosts" ]; do
        bits=$((bits + 1))
        [ $bits -gt 30 ] && { bits=30; break; }
    done
    echo $((32 - bits))
}

# Статус интерфейса
get_iface_status() {
    local iface=$1
    [ -f "/sys/class/net/${iface}/operstate" ] && cat "/sys/class/net/${iface}/operstate" || echo "UNKNOWN"
}

# MAC адрес
get_iface_mac() {
    local iface=$1
    [ -f "/sys/class/net/${iface}/address" ] && cat "/sys/class/net/${iface}/address" || echo "N/A"
}

# IP адрес
get_iface_ip() {
    local iface=$1
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1 || echo ""
}

# Показать VLAN
show_existing_vlans() {
    local iface=$1
    echo -e "\n${CYAN}=== VLAN на $iface ===${NC}"
    local found=0
    for dir in "$IFACES_DIR"/${iface}.*; do
        [ -d "$dir" ] || continue
        found=1
        local vlan_name=$(basename "$dir")
        local vlan_ip=$(cat "$dir/ipv4address" 2>/dev/null || echo "не назначен")
        local vlan_id=$(grep "^VLAN_ID=" "$dir/options" 2>/dev/null | cut -d= -f2 || echo "?")
        local status=$(get_iface_status "$vlan_name")
        local status_out=$([ "$status" = "UP" ] && echo -e "${GREEN}UP${NC}" || echo -e "${YELLOW}$status${NC}")
        printf " %-20s VLAN: %-4s IP: %-20s %s\n" "$vlan_name" "$vlan_id" "$vlan_ip" "$status_out"
    done
    [ $found -eq 0 ] && echo -e " ${YELLOW}VLAN не найдены${NC}"
}

# Создание VLAN конфига
create_vlan_config() {
    local vlan_name=$1 vlan_id=$2 iface=$3 net_octet=$4 hosts=$5 base_net=$6
    local cidr=$(calculate_cidr "$hosts")
    local vlan_iface="${iface}.${vlan_id}"
    local vlan_dir="$IFACES_DIR/${vlan_iface}"
    
    echo -e " ${GREEN}→${NC} Создание $vlan_iface..."
    mkdir -p "$vlan_dir"
    
    # options
    cat > "$vlan_dir/options" << EOF
TYPE=vlan
BOOTPROTO=static
ONBOOT=yes
NM_CONTROLLED=no
VLAN=yes
PHYSDEV=$iface
VLAN_ID=$vlan_id
EOF
    
    # ipv4address
    echo "${base_net}.${net_octet}.1/${cidr}" > "$vlan_dir/ipv4address"
    
    echo -e "   Сеть: ${CYAN}${base_net}.${net_octet}.0/${cidr}${NC}"
    echo -e "   Шлюз: ${CYAN}${base_net}.${net_octet}.1${NC}"
}

# Список интерфейсов
get_iface_list() {
    ls /sys/class/net/ 2>/dev/null | grep -vE "^(lo|docker|veth|virbr|sit|br-|flannel|cni)"
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================

echo -e "${CYAN}╔════ VLAN для ALT Linux ════╗${NC}"
echo ""
echo "1) Создать VLAN"
echo "2) Показать VLAN"  
echo "3) Удалить VLAN"
echo "4) Выход"
read -p "Выбор [1]: " action
action=${action:-1}

case "$action" in
    2)
        echo "Интерфейсы:"
        select iface in $(get_iface_list); do
            [ -n "$iface" ] && { show_existing_vlans "$iface"; break; }
            echo "Неверный выбор"
        done
        exit 0
        ;;
    3)
        echo "Интерфейсы:"
        select iface in $(get_iface_list); do
            [ -n "$iface" ] || continue
            show_existing_vlans "$iface"
            read -p "VLAN для удаления (например, $iface.100): " vlan_del
            [ -n "$vlan_del" ] || { echo "Отменено"; exit 0; }
            read -p "Подтвердить? (y/n): " conf
            [[ "$conf" =~ ^[Yy] ]] || { echo "Отменено"; exit 0; }
            ip link del "$vlan_del" 2>/dev/null || true
            rm -rf "$IFACES_DIR/$vlan_del"
            echo -e "${GREEN}Удалено${NC}"
            break
        done
        exit 0
        ;;
    4) exit 0 ;;
esac

# ==============================================================================
# СОЗДАНИЕ VLAN
# ==============================================================================

echo "Интерфейсы:"
PS3="Выберите интерфейс: "
select PHYS_IFACE in $(get_iface_list); do
    [ -n "$PHYS_IFACE" ] && break
    echo "Неверный выбор"
done

echo -e "\n${GREEN}Интерфейс: $PHYS_IFACE${NC}"
show_existing_vlans "$PHYS_IFACE"

read -p "Базовая сеть [192.168]: " base_input
BASE_NET=${base_input:-192.168}

echo ""
echo "Добавьте VLAN (название|ID|октет|хосты), пустая строка - завершить:"
echo "Пример: HQ-SRV|100|100|64"

VLANS_FILE=$(mktemp)
while true; do
    read -p "VLAN: " line
    [ -z "$line" ] && break
    echo "$line" >> "$VLANS_FILE"
done

if [ ! -s "$VLANS_FILE" ]; then
    echo "Нет VLAN для создания"
    rm -f "$VLANS_FILE"
    exit 0
fi

# Подтверждение
echo -e "\n${CYAN}Будет создано:${NC}"
while IFS='|' read -r name id oct hosts; do
    cidr=$(calculate_cidr "$hosts")
    echo "  $name.$id → ${BASE_NET}.$oct.0/$cidr ($hosts хостов)"
done < "$VLANS_FILE"

read -p "Применить? (y/n): " conf
[[ "$conf" =~ ^[Yy] ]] || { rm -f "$VLANS_FILE"; echo "Отменено"; exit 0; }

# Применение
echo -e "\n${CYAN}Создание...${NC}"
while IFS='|' read -r name id oct hosts; do
    create_vlan_config "$name" "$id" "$PHYS_IFACE" "$oct" "$hosts" "$BASE_NET"
done < "$VLANS_FILE"
rm -f "$VLANS_FILE"

# Перезапуск сети
read -p "Перезапустить сеть? (y/n): " restart_net
if [[ "$restart_net" =~ ^[Yy] ]]; then
    systemctl restart network 2>/dev/null || /etc/init.d/network restart 2>/dev/null || true
    echo -e "${GREEN}Сеть перезагружена${NC}"
fi

echo -e "\n${GREEN}Готово!${NC}"
echo "Проверка: ip -br addr | grep $PHYS_IFACE"
