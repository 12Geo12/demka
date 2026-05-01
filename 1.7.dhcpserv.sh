#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${WHITE}     Установка DHCP сервера${NC}"
echo -e "${CYAN}========================================${NC}"

echo -e "${CYAN}Установка пакетов...${NC}"
apt-get update -y > /dev/null 2>&1
apt-get install -y dhcp-server ipcalc > /dev/null 2>&1

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${WHITE}  Автонастройка DHCP сервера${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# Массивы для интерфейсов
INTERFACES=()
IPS=()
VLAN_IDS=()

# Получение интерфейсов (включая VLAN)
get_interfaces() {
    echo -e "${WHITE}Доступные сетевые интерфейсы:${NC}"
    echo "--------------------------------------------------"
    printf "%-4s %-18s %-10s %-18s %-10s\n" "№" "Интерфейс" "VLAN ID" "IP адрес" "Статус"
    echo "--------------------------------------------------"
    
    local INDEX=1
    local TMPFILE=$(mktemp)
    
    ip -4 -o addr show 2>/dev/null > "$TMPFILE"
    
    while IFS= read -r line; do
        local iface=$(echo "$line" | awk '{print $2}' | cut -d@ -f1)
        local ip_cidr=$(echo "$line" | awk '{print $4}')
        local ip=$(echo "$ip_cidr" | cut -d/ -f1)
        
        # Пропускаем lo
        [ "$iface" = "lo" ] && continue
        
        # Определяем VLAN ID
        local vlan_id="-"
        if [[ "$iface" =~ \.([0-9]+)$ ]]; then
            vlan_id="${BASH_REMATCH[1]}"
        fi
        
        # Получаем статус
        local status
        if [ -f "/sys/class/net/${iface}/operstate" ]; then
            status=$(cat "/sys/class/net/${iface}/operstate")
        else
            status="unknown"
        fi
        status=$(echo "$status" | tr '[:lower:]' '[:upper:]')
        
        if [ -n "$ip" ]; then
            INTERFACES+=("$iface")
            IPS+=("$ip")
            VLAN_IDS+=("$vlan_id")
            
            # Цвет статуса
            local status_out
            if [ "$status" = "UP" ]; then
                status_out="${GREEN}UP${NC}"
            else
                status_out="${YELLOW}$status${NC}"
            fi
            
            # Выделяем VLAN интерфейсы
            if [ "$vlan_id" != "-" ]; then
                printf "${MAGENTA}%2d)${NC} %-18s ${CYAN}%-10s${NC} %-18s %b\n" "$INDEX" "$iface" "VLAN $vlan_id" "$ip" "$status_out"
            else
                printf "%2d) %-18s %-10s %-18s %b\n" "$INDEX" "$iface" "$vlan_id" "$ip" "$status_out"
            fi
            INDEX=$((INDEX + 1))
        fi
    done < "$TMPFILE"
    
    rm -f "$TMPFILE"
    echo ""
}

# Выбор интерфейса
select_interface() {
    local prompt="$1"
    local selected_index

    while true; do
        read -p "$prompt" selection

        if [[ "$selection" =~ ^[0-9]+$ ]]; then
            if [ "$selection" -ge 1 ] && [ "$selection" -le ${#INTERFACES[@]} ]; then
                selected_index=$((selection - 1))
                SELECTED_IFACE="${INTERFACES[$selected_index]}"
                SELECTED_IP="${IPS[$selected_index]}"
                SELECTED_VLAN="${VLAN_IDS[$selected_index]}"
                echo -e "${GREEN}Выбран: $SELECTED_IFACE ($SELECTED_IP)${NC}"
                if [ "$SELECTED_VLAN" != "-" ]; then
                    echo -e "${CYAN}Это VLAN $SELECTED_VLAN интерфейс${NC}"
                fi
                echo ""
                return 0
            else
                echo -e "${RED}Ошибка: введите число от 1 до ${#INTERFACES[@]}${NC}"
            fi
        else
            echo -e "${RED}Ошибка: неверный ввод${NC}"
        fi
    done
}

# Получение параметров сети
get_network_info() {
    local iface=$1

    local CIDR=$(ip -4 -o addr show "$iface" | awk '{print $4}')
    local IP=$(echo "$CIDR" | cut -d/ -f1)

    # Используем ipcalc для получения параметров сети
    local NETWORK=$(ipcalc "$CIDR" 2>/dev/null | grep -E "^Network:" | awk '{print $2}' | cut -d/ -f1)
    local NETMASK=$(ipcalc "$CIDR" 2>/dev/null | grep -E "^Netmask:" | awk '{print $2}')
    local BROADCAST=$(ipcalc "$CIDR" 2>/dev/null | grep -E "^Broadcast:" | awk '{print $2}')

    # Диапазон DHCP (оставляем место для шлюза и других устройств)
    local START=$(echo "$NETWORK" | awk -F. '{print $1"."$2"."$3"."$4+10}')
    local END=$(echo "$BROADCAST" | awk -F. '{print $1"."$2"."$3"."$4-5}')

    echo "$NETWORK $NETMASK $BROADCAST $START $END $IP"
}

# --- Запуск ---
get_interfaces

if [ ${#INTERFACES[@]} -lt 1 ]; then
    echo -e "${RED}Ошибка: нет интерфейсов с IP адресом${NC}"
    exit 1
fi

# Спрашиваем количество интерфейсов
echo -e "${WHITE}Сколько интерфейсов (VLAN) настроить для DHCP?${NC}"
read -p "Введите число [1]: " IFACE_COUNT
IFACE_COUNT=${IFACE_COUNT:-1}

# Проверка
if ! [[ "$IFACE_COUNT" =~ ^[0-9]+$ ]] || [ "$IFACE_COUNT" -lt 1 ]; then
    echo -e "${RED}Ошибка: некорректное число${NC}"
    exit 1
fi

if [ "$IFACE_COUNT" -gt ${#INTERFACES[@]} ]; then
    echo -e "${RED}Ошибка: нельзя выбрать больше интерфейсов, чем доступно (${#INTERFACES[@]})${NC}"
    exit 1
fi

# Массив для выбранных интерфейсов
SELECTED_IFACES=()
SELECTED_IPS=()
SELECTED_VLANS=()

# Выбор интерфейсов
i=1
while [ $i -le $IFACE_COUNT ]; do
    select_interface "Выберите интерфейс #$i: "
    
    # Проверка на дубликаты
    already_selected=0
    for prev_iface in "${SELECTED_IFACES[@]}"; do
        if [ "$prev_iface" = "$SELECTED_IFACE" ]; then
            already_selected=1
            break
        fi
    done
    
    if [ $already_selected -eq 1 ]; then
        echo -e "${RED}Ошибка: этот интерфейс уже выбран${NC}"
        continue
    fi
    
    SELECTED_IFACES+=("$SELECTED_IFACE")
    SELECTED_IPS+=("$SELECTED_IP")
    SELECTED_VLANS+=("$SELECTED_VLAN")
    i=$((i + 1))
done

echo -e "${GREEN}Выбранные интерфейсы:${NC} ${SELECTED_IFACES[*]}"
echo ""

# Получаем параметры сети для каждого интерфейса
NETWORKS=()

echo -e "${WHITE}Определение параметров сети...${NC}"
echo ""

for iface in "${SELECTED_IFACES[@]}"; do
    NET_INFO=($(get_network_info "$iface"))
    NETWORKS+=("${NET_INFO[*]}")
    
    echo -e "${CYAN}$iface${NC} -> Сеть: ${NET_INFO[0]} / ${NET_INFO[1]}"
    echo "   Шлюз: ${NET_INFO[5]}"
    echo "   DHCP диапазон: ${NET_INFO[3]} - ${NET_INFO[4]}"
    echo "   Broadcast: ${NET_INFO[2]}"
    echo ""
done

# Подтверждение
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  ВАЖНО! Для работы DHCP по VLAN:${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo "1. Клиенты должны быть в той же VLAN (через коммутатор или VMware)"
echo "2. В VMware используйте LAN Segments для каждой VLAN"
echo "3. Или настройте VLAN tagging на клиентах"
echo ""
read -p "Продолжить настройку? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo "Отменено"
    exit 0
fi

# Конфиг DHCP
echo ""
echo -e "${CYAN}Создание /etc/dhcp/dhcpd.conf...${NC}"

cat > /etc/dhcp/dhcpd.conf <<EOF
# DHCP Configuration for VLAN networks
# Generated by auto-config script
# $(date)

ddns-update-style none;
default-lease-time 600;
max-lease-time 7200;
authoritative;

# DNS серверы
option domain-name-servers 8.8.8.8, 8.8.4.4;

EOF

# Добавляем подсети
idx=0
for iface in "${SELECTED_IFACES[@]}"; do
    NET_INFO=(${NETWORKS[$idx]})
    vlan_id="${SELECTED_VLANS[$idx]}"
    
    # Комментарий с VLAN ID
    if [ "$vlan_id" != "-" ]; then
        echo "" >> /etc/dhcp/dhcpd.conf
        echo "# VLAN $vlan_id - $iface" >> /etc/dhcp/dhcpd.conf
    fi
    
    cat >> /etc/dhcp/dhcpd.conf <<EOF

# Network for $iface
subnet ${NET_INFO[0]} netmask ${NET_INFO[1]} {
  range ${NET_INFO[3]} ${NET_INFO[4]};
  option routers ${NET_INFO[5]};
  option broadcast-address ${NET_INFO[2]};
  default-lease-time 600;
  max-lease-time 7200;
}

EOF
    idx=$((idx + 1))
done

# Интерфейсы DHCP
IFACES_STR="${SELECTED_IFACES[*]}"
echo -e "${CYAN}Настройка /etc/sysconfig/dhcpd...${NC}"

cat > /etc/sysconfig/dhcpd <<EOF
# DHCP Server Arguments
# Interfaces: $IFACES_STR
DHCPDARGS="$IFACES_STR"
EOF

# Включение маршрутизации
echo -e "${CYAN}Включение IP forwarding...${NC}"
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1

# Открытие портов DHCP в firewall
echo -e "${CYAN}Настройка firewall для DHCP...${NC}"
iptables -I INPUT -p udp --dport 67 -j ACCEPT 2>/dev/null
iptables -I INPUT -p udp --dport 68 -j ACCEPT 2>/dev/null
iptables -I INPUT -p udp --sport 67 --dport 68 -j ACCEPT 2>/dev/null

# Перезапуск
echo -e "${CYAN}Перезапуск DHCP...${NC}"
systemctl enable dhcpd > /dev/null 2>&1
systemctl restart dhcpd

if [ $? -eq 0 ]; then
    echo -e "${GREEN}[OK] DHCP сервер запущен${NC}"
else
    echo -e "${RED}[ERROR] Не удалось запустить DHCP сервер${NC}"
    echo "Проверьте: journalctl -u dhcpd -n 50"
    exit 1
fi

# Итоговый вывод
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  НАСТРОЙКА ЗАВЕРШЕНА!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${WHITE}Интерфейсы DHCP:${NC}"
for i in "${!SELECTED_IFACES[@]}"; do
    iface="${SELECTED_IFACES[$i]}"
    vlan="${SELECTED_VLANS[$i]}"
    if [ "$vlan" != "-" ]; then
        echo "  - $iface (VLAN $vlan)"
    else
        echo "  - $iface"
    fi
done
echo ""

# Показываем конфигурацию
echo -e "${WHITE}Конфигурация DHCP:${NC}"
echo "----------------------------------------"
cat /etc/dhcp/dhcpd.conf | grep -E "^(subnet|range|option routers|option broadcast|# VLAN)"
echo "----------------------------------------"
echo ""

# Статус
echo -e "${WHITE}Статус службы:${NC}"
systemctl status dhcpd --no-pager 2>/dev/null | head -10

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  КАК ПОДКЛЮЧИТЬ КЛИЕНТОВ${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo -e "${YELLOW}Вариант 1: Через LAN Segment в VMware${NC}"
echo "  1. Создайте LAN Segment для каждой VLAN"
echo "  2. Подключите клиентскую ВМ к нужному сегменту"
echo "  3. На клиенте запустите: dhcpcd"
echo ""
echo -e "${YELLOW}Вариант 2: Через VLAN tagging на клиенте${NC}"
echo "  На клиенте выполните:"
echo "    ip link add link ens33 name ens33.<VLAN_ID> type vlan id <VLAN_ID>"
echo "    ip link set ens33.<VLAN_ID> up"
echo "    dhcpcd ens33.<VLAN_ID>"
echo ""
echo -e "${YELLOW}Вариант 3: Через управляемый коммутатор${NC}"
echo "  Настройте access port для нужной VLAN"
echo ""
echo -e "${CYAN}Полезные команды:${NC}"
echo "  systemctl status dhcpd     - статус службы"
echo "  journalctl -u dhcpd -f     - логи в реальном времени"
echo "  dhcp-lease-list            - список выданных адресов"
echo ""
