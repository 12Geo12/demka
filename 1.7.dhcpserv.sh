#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

echo -e "${CYAN}Установка DHCP сервера...${NC}"
apt-get update -y
apt-get install -y dhcp-server ipcalc

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${WHITE}  Автонастройка DHCP сервера${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# Массивы для интерфейсов
INTERFACES=()
IPS=()
STATUSES=()

# Получение интерфейсов (включая VLAN)
get_interfaces() {
    echo -e "${WHITE}Доступные сетевые интерфейсы:${NC}"
    echo "------------------------------"

    local INDEX=1
    local TMPFILE=$(mktemp)
    
    # Сохраняем вывод во временный файл
    ip -4 -o addr show 2>/dev/null > "$TMPFILE"
    
    while IFS= read -r line; do
        local iface=$(echo "$line" | awk '{print $2}' | cut -d@ -f1)
        local ip_cidr=$(echo "$line" | awk '{print $4}')
        local ip=$(echo "$ip_cidr" | cut -d/ -f1)
        
        # Пропускаем lo
        [ "$iface" = "lo" ] && continue
        
        # Получаем статус
        local status
        if [ -f "/sys/class/net/${iface}/operstate" ]; then
            status=$(cat "/sys/class/net/${iface}/operstate")
        else
            status="unknown"
        fi
        
        # Приводим статус к верхнему регистру
        status=$(echo "$status" | tr '[:lower:]' '[:upper:]')
        
        if [ -n "$ip" ]; then
            INTERFACES+=("$iface")
            IPS+=("$ip")
            STATUSES+=("$status")
            
            # Цвет статуса
            local status_colored
            if [ "$status" = "UP" ]; then
                status_colored="${GREEN}UP${NC}"
            else
                status_colored="${YELLOW}$status${NC}"
            fi
            
            printf "%2d) %-15s [%s] (IP: %s)\n" "$INDEX" "$iface" "$status_colored" "$ip"
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
                echo -e "${GREEN}Выбран: $SELECTED_IFACE ($SELECTED_IP)${NC}"
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

    # Диапазон DHCP
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
echo -e "${WHITE}Сколько интерфейсов настроить для DHCP?${NC}"
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

# Выбор интерфейсов
i=1
while [ $i -le $IFACE_COUNT ]; do
    select_interface "Выберите интерфейс #$i: "
    
    # Проверка на дубликаты
    local already_selected=0
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
    i=$((i + 1))
done

echo -e "${GREEN}Используем:${NC} ${SELECTED_IFACES[*]}"
echo ""

# Получаем параметры сети для каждого интерфейса
NETWORKS=()

echo -e "${WHITE}Определение параметров сети...${NC}"
echo ""

for iface in "${SELECTED_IFACES[@]}"; do
    NET_INFO=($(get_network_info "$iface"))
    NETWORKS+=("${NET_INFO[*]}")
    
    echo -e "${CYAN}$iface${NC} -> ${NET_INFO[0]} / ${NET_INFO[1]}"
    echo "   DHCP диапазон: ${NET_INFO[3]} - ${NET_INFO[4]}"
    echo ""
done

# Подтверждение
read -p "Продолжить настройку? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo "Отменено"
    exit 0
fi

# Конфиг DHCP
echo -e "${CYAN}Создание /etc/dhcp/dhcpd.conf...${NC}"

cat > /etc/dhcp/dhcpd.conf <<EOF
# DHCP Configuration
# Generated by auto-config script
# $(date)

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
    
    cat >> /etc/dhcp/dhcpd.conf <<EOF

# Network for $iface
subnet ${NET_INFO[0]} netmask ${NET_INFO[1]} {
  range ${NET_INFO[3]} ${NET_INFO[4]};
  option routers ${NET_INFO[5]};
  option broadcast-address ${NET_INFO[2]};
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

# Перезапуск
echo -e "${CYAN}Перезапуск DHCP...${NC}"
systemctl enable dhcpd > /dev/null 2>&1
systemctl restart dhcpd

if [ $? -eq 0 ]; then
    echo -e "${GREEN}[OK] DHCP сервер запущен${NC}"
else
    echo -e "${RED}[ERROR] Не удалось запустить DHCP сервер${NC}"
    echo "Проверьте: journalctl -u dhcpd -n 50"
fi

# Итоговый вывод
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Настройка завершена!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${WHITE}Интерфейсы DHCP:${NC} $IFACES_STR"
echo ""

# Показываем статус
echo -e "${WHITE}Статус службы:${NC}"
systemctl status dhcpd --no-pager -l 2>/dev/null || service dhcpd status 2>/dev/null

echo ""
echo -e "${CYAN}Полезные команды:${NC}"
echo "  systemctl status dhcpd     - статус службы"
echo "  journalctl -u dhcpd -f     - логи в реальном времени"
echo "  cat /etc/dhcp/dhcpd.conf   - конфигурация"
echo ""
